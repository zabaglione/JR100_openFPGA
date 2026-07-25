//============================================================================
//
//  Save bridge: jr100_saver's MiSTer sector-write protocol -> APF
//  target_dataslot_write.
//
//  The saver emits the BASIC program as a PROG container in 512-byte
//  sectors over the hps_io block protocol: it raises sd_wr with sd_lba,
//  expects the host to sweep sd_buff_addr and collect sd_buff_din, and
//  treats the fall of sd_ack as sector-complete. Here the "host" is this
//  module: it captures the sector into a dual-clock buffer, then asks APF
//  to pull those 512 bytes over the bridge (reads served straight from the
//  buffer's other port, PocketCPC-style) and write them into the mounted
//  save file at lba*512.
//
//  The mount itself is the data.json slot: when the user picks a file the
//  host pushes its content (ignored - only the metadata matters) and this
//  module turns the completion into the img_mounted pulse and img_size the
//  saver expects.
//
//  Copyright (C) 2026 Zabaglione
//  SPDX-License-Identifier: GPL-2.0-or-later
//
//============================================================================

`default_nettype none

module jr100_save_bridge #(
    parameter [15:0] SLOT_ID    = 16'd3,
    parameter [31:0] BRIDGEADDR = 32'h30000000
) (
    input  wire        clk,           // machine clock
    input  wire        rst,
    input  wire        clk_74a,

    // slot bookkeeping (clk_74a domain)
    input  wire        dataslot_requestwrite,
    input  wire [15:0] dataslot_requestwrite_id,
    input  wire [31:0] dataslot_requestwrite_size,
    input  wire        dataslot_allcomplete,

    // saver-side (machine clock), hps_io block-write emulation
    output reg         img_mounted,   // one-clk pulse
    output wire        img_readonly,
    output reg  [63:0] img_size,
    input  wire [31:0] sd_lba,
    input  wire        sd_wr,
    output reg         sd_ack,
    output reg  [8:0]  sd_buff_addr,
    input  wire [7:0]  sd_buff_din,

    // bridge read serving (clk_74a domain)
    input  wire [31:0] bridge_addr,
    output wire [31:0] bridge_rd_data,

    // APF target command interface (clk_74a domain)
    output reg         target_dataslot_write,
    output reg  [15:0] target_dataslot_id,
    output reg  [31:0] target_dataslot_slotoffset,
    output reg  [31:0] target_dataslot_bridgeaddr,
    output reg  [31:0] target_dataslot_length,
    input  wire        target_dataslot_ack,
    input  wire        target_dataslot_done,
    input  wire [2:0]  target_dataslot_err
);

    assign img_readonly = 1'b0;

    // ------------------------------------------------------------------
    // Mount detection: the slot's push completing = a file is mounted.
    // ------------------------------------------------------------------
    reg        slot_is_save_74 = 1'b0;
    reg [31:0] slot_size_74    = 32'd0;
    always @(posedge clk_74a) begin
        if (dataslot_requestwrite) begin
            slot_is_save_74 <= (dataslot_requestwrite_id == SLOT_ID);
            if (dataslot_requestwrite_id == SLOT_ID)
                slot_size_74 <= dataslot_requestwrite_size;
        end
    end

    wire allcomplete_s, is_save_s;
    synch_3 s_complete (dataslot_allcomplete, allcomplete_s, clk);
    synch_3 s_issave   (slot_is_save_74,      is_save_s,     clk);

    reg allcomplete_q;
    always @(posedge clk) begin
        allcomplete_q <= allcomplete_s;
        img_mounted   <= 1'b0;
        if (allcomplete_s & ~allcomplete_q & is_save_s) begin
            img_mounted <= 1'b1;
            img_size    <= {32'd0, slot_size_74};   // quasi-static by now
        end
    end

    // ------------------------------------------------------------------
    // Sector buffer: written by the capture sweep (machine clock), read
    // by the host's bridge fetches (clk_74a). 128 x 32, big-endian bytes
    // so the file sees offset order.
    // ------------------------------------------------------------------
    reg         buf_wr;
    reg  [6:0]  buf_waddr;
    reg  [31:0] buf_wdata;

bram_block_dp #(
    .DATA ( 32 ),
    .ADDR ( 7 )
) sector_buffer (
    .a_clk  ( clk_74a ),
    .a_wr   ( 1'b0 ),
    .a_addr ( bridge_addr[8:2] ),
    .a_din  ( 32'd0 ),
    .a_dout ( bridge_rd_data ),

    .b_clk  ( clk ),
    .b_wr   ( buf_wr ),
    .b_addr ( buf_waddr ),
    .b_din  ( buf_wdata ),
    .b_dout (  )
);

    // ------------------------------------------------------------------
    // Command handshake toggles between the domains
    // ------------------------------------------------------------------
    reg        req_t = 1'b0;      // machine -> 74a: sector ready, write it
    reg        done_t_74 = 1'b0;  // 74a -> machine: host finished
    reg [31:0] req_lba;           // quasi-static parameter for the command

    wire req_t_74, done_t_s;
    synch_3 s_req  (req_t,     req_t_74, clk_74a);
    synch_3 s_done (done_t_74, done_t_s, clk);

    // ------------------------------------------------------------------
    // Machine-side FSM: capture the sector, hand it to the host
    // ------------------------------------------------------------------
    localparam [2:0] MS_IDLE   = 3'd0;
    localparam [2:0] MS_SWEEP  = 3'd1;   // drive addr, din arrives 1 late
    localparam [2:0] MS_REQ    = 3'd2;
    localparam [2:0] MS_WAIT   = 3'd3;
    localparam [2:0] MS_FINISH = 3'd4;

    reg [2:0]  mstate = MS_IDLE;
    reg [9:0]  sweep;             // 0..513 (two-cycle pipeline tail)
    reg        done_q;

    always @(posedge clk) begin
        if (rst) begin
            mstate       <= MS_IDLE;
            sd_ack       <= 1'b0;
            buf_wr       <= 1'b0;
            sd_buff_addr <= 9'd0;
            done_q       <= done_t_s;
        end else begin
            buf_wr <= 1'b0;
            done_q <= done_t_s;

            case (mstate)
                MS_IDLE: begin
                    if (sd_wr) begin
                        sd_ack       <= 1'b1;   // transfer begins
                        req_lba      <= sd_lba;
                        sweep        <= 10'd0;
                        sd_buff_addr <= 9'd0;
                        mstate       <= MS_SWEEP;
                    end
                end

                // sd_buff_din is registered in the saver, so byte N arrives
                // one cycle after address N is presented: at sweep cycle s,
                // din carries byte s-1. A word's last byte (b%4 == 3) lands
                // at s = b+1, so the completed shift register is written on
                // the FOLLOWING cycle - s%4 == 1, s >= 5 - covering words 0
                // through 127 uniformly (s = 5, 9, ..., 513).
                MS_SWEEP: begin
                    sweep        <= sweep + 10'd1;
                    sd_buff_addr <= (sweep < 10'd511) ? sweep[8:0] + 9'd1
                                                      : 9'd0;
                    if (sweep != 10'd0 && sweep <= 10'd512)
                        buf_wdata <= {buf_wdata[23:0], sd_buff_din};

                    if (sweep[1:0] == 2'd1 && sweep >= 10'd5) begin
                        buf_wr    <= 1'b1;
                        buf_waddr <= sweep[8:2] - 7'd1;   // (s-5)/4
                    end

                    if (sweep == 10'd513)
                        mstate <= MS_REQ;
                end

                MS_REQ: begin
                    req_t  <= ~req_t;
                    mstate <= MS_WAIT;
                end

                MS_WAIT: begin
                    if (done_q != done_t_s)
                        mstate <= MS_FINISH;
                end

                MS_FINISH: begin
                    sd_ack <= 1'b0;   // sector complete, saver advances
                    mstate <= MS_IDLE;
                end

                default: mstate <= MS_IDLE;
            endcase
        end
    end

    // ------------------------------------------------------------------
    // Host-side FSM: one target_dataslot_write per sector
    // ------------------------------------------------------------------
    localparam [1:0] HS_IDLE = 2'd0;
    localparam [1:0] HS_CMD  = 2'd1;
    localparam [1:0] HS_BUSY = 2'd2;

    reg [1:0] hstate = HS_IDLE;
    reg       req_q_74;

    always @(posedge clk_74a) begin
        req_q_74 <= req_t_74;

        case (hstate)
            HS_IDLE: begin
                target_dataslot_write <= 1'b0;
                if (req_q_74 != req_t_74) begin
                    target_dataslot_id         <= SLOT_ID;
                    target_dataslot_slotoffset <= {req_lba[22:0], 9'd0};
                    target_dataslot_bridgeaddr <= BRIDGEADDR;
                    target_dataslot_length     <= 32'd512;
                    target_dataslot_write      <= 1'b1;
                    hstate                     <= HS_CMD;
                end
            end

            HS_CMD: begin
                if (target_dataslot_ack) begin
                    target_dataslot_write <= 1'b0;
                    hstate                <= HS_BUSY;
                end
            end

            HS_BUSY: begin
                if (target_dataslot_done) begin
                    done_t_74 <= ~done_t_74;
                    hstate    <= HS_IDLE;
                end
            end

            default: hstate <= HS_IDLE;
        endcase
    end

endmodule

`default_nettype wire
