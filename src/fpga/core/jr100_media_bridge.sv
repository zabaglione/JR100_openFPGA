//============================================================================
//
//  Media bridge: the MiSTer hps_io sector protocol -> APF target commands,
//  for both media clients of jr100_top.
//
//  Clients:
//    - jr100_saver  (slot 3, "Save File", write-only): each 512-byte
//      sector is captured from its registered sd_buff_din sweep and pushed
//      with target_dataslot_write; the host fetches the bytes over bridge
//      reads at 0x3xxxxxxx, served straight from the sector buffer.
//    - jr100_tape_buf (slot 4, "Cassette", deferload, read/write): sector
//      reads issue target_dataslot_read into a chunk buffer the host fills
//      with bridge writes at 0x5xxxxxxx, then stream into the deck with
//      sd_buff_addr/dout/wr strobes; sector writes reuse the save capture
//      path with the tape's din and slot id.
//
//  One machine-side FSM services a single request at a time (save first),
//  so a single host-side command FSM suffices - no arbitration between
//  modules. Mounts: the save slot is host-pushed (its completion is the
//  img_mounted pulse); the cassette slot is deferload, so its
//  dataslot_update message provides the mount pulse and size.
//
//  Copyright (C) 2026 Zabaglione
//  SPDX-License-Identifier: GPL-2.0-or-later
//
//============================================================================

`default_nettype none

module jr100_media_bridge #(
    parameter [15:0] SLOT_SAVE  = 16'd3,
    parameter [15:0] SLOT_TAPE  = 16'd4,
    parameter [31:0] RD_BRIDGE  = 32'h50000000,
    parameter [31:0] WR_BRIDGE  = 32'h30000000
) (
    input  wire        clk,           // machine clock
    input  wire        rst,
    input  wire        clk_74a,

    // slot bookkeeping (clk_74a domain)
    input  wire        dataslot_requestwrite,
    input  wire [15:0] dataslot_requestwrite_id,
    input  wire [31:0] dataslot_requestwrite_size,
    input  wire        dataslot_update,
    input  wire [15:0] dataslot_update_id,
    input  wire [31:0] dataslot_update_size,
    input  wire        dataslot_allcomplete,

    // saver client (machine clock)
    output reg         img_mounted,
    output wire        img_readonly,
    output reg  [63:0] img_size,
    input  wire [31:0] sd_lba,
    input  wire        sd_wr,
    output reg         sd_ack,
    input  wire [7:0]  save_din,

    // tape client (machine clock)
    output reg         tape_mounted,
    output wire        tape_readonly,
    output reg  [63:0] tape_size,
    input  wire [31:0] sd1_lba,
    input  wire        sd1_rd,
    input  wire        sd1_wr,
    output reg         sd1_ack,
    input  wire [7:0]  tape_din,

    // shared hps_io buffer bus into jr100_top
    output reg  [8:0]  buff_addr,
    output reg  [7:0]  buff_dout,
    output reg         buff_wr,

    // bridge (clk_74a domain)
    input  wire [31:0] bridge_addr,
    input  wire        bridge_wr,
    input  wire [31:0] bridge_wr_data,
    output wire [31:0] bridge_rd_data,

    // APF target command interface (clk_74a domain)
    output reg         target_dataslot_read,
    output reg         target_dataslot_write,
    output reg  [15:0] target_dataslot_id,
    output reg  [31:0] target_dataslot_slotoffset,
    output reg  [31:0] target_dataslot_bridgeaddr,
    output reg  [31:0] target_dataslot_length,
    input  wire        target_dataslot_ack,
    input  wire        target_dataslot_done,
    input  wire [2:0]  target_dataslot_err
);

    assign img_readonly  = 1'b0;
    assign tape_readonly = 1'b0;

    // ------------------------------------------------------------------
    // Mount bookkeeping
    // ------------------------------------------------------------------
    reg        slot_is_save_74 = 1'b0;
    reg [31:0] save_size_74    = 32'd0;
    reg        tape_upd_t_74   = 1'b0;
    reg [31:0] tape_size_74    = 32'd0;
    reg        upd_seen_74     = 1'b0;

    always @(posedge clk_74a) begin
        if (dataslot_requestwrite) begin
            slot_is_save_74 <= (dataslot_requestwrite_id == SLOT_SAVE);
            if (dataslot_requestwrite_id == SLOT_SAVE)
                save_size_74 <= dataslot_requestwrite_size;
        end
        // dataslot_update is a level until the next host command; toggle once
        upd_seen_74 <= dataslot_update;
        if (dataslot_update && !upd_seen_74 &&
            dataslot_update_id == SLOT_TAPE) begin
            tape_size_74  <= dataslot_update_size;
            tape_upd_t_74 <= ~tape_upd_t_74;
        end
    end

    wire allcomplete_s, is_save_s, tape_upd_t;
    synch_3 s_complete (dataslot_allcomplete, allcomplete_s, clk);
    synch_3 s_issave   (slot_is_save_74,      is_save_s,     clk);
    synch_3 s_tupd     (tape_upd_t_74,        tape_upd_t,    clk);

    reg allcomplete_q, tape_upd_q;
    always @(posedge clk) begin
        allcomplete_q <= allcomplete_s;
        tape_upd_q    <= tape_upd_t;
        img_mounted   <= 1'b0;
        tape_mounted  <= 1'b0;
        if (allcomplete_s & ~allcomplete_q & is_save_s) begin
            img_mounted <= 1'b1;
            img_size    <= {32'd0, save_size_74};
        end
        if (tape_upd_q != tape_upd_t) begin
            tape_mounted <= 1'b1;
            tape_size    <= {32'd0, tape_size_74};   // quasi-static by now
        end
    end

    // ------------------------------------------------------------------
    // Write sector buffer (machine -> host), read by bridge at 0x3xxxxxxx
    // ------------------------------------------------------------------
    reg         wbuf_wr;
    reg  [6:0]  wbuf_waddr;
    reg  [31:0] wbuf_wdata;

bram_block_dp #(
    .DATA ( 32 ),
    .ADDR ( 7 )
) wr_sector_buffer (
    .a_clk  ( clk_74a ),
    .a_wr   ( 1'b0 ),
    .a_addr ( bridge_addr[8:2] ),
    .a_din  ( 32'd0 ),
    .a_dout ( bridge_rd_data ),

    .b_clk  ( clk ),
    .b_wr   ( wbuf_wr ),
    .b_addr ( wbuf_waddr ),
    .b_din  ( wbuf_wdata ),
    .b_dout (  )
);

    // ------------------------------------------------------------------
    // Read chunk buffer (host -> machine), filled by bridge writes at
    // 0x5xxxxxxx during a target_dataslot_read
    // ------------------------------------------------------------------
    reg  [6:0]  rbuf_raddr;
    wire [31:0] rbuf_q;

bram_block_dp #(
    .DATA ( 32 ),
    .ADDR ( 7 )
) rd_chunk_buffer (
    .a_clk  ( clk_74a ),
    .a_wr   ( bridge_wr && (bridge_addr[31:28] == RD_BRIDGE[31:28]) ),
    .a_addr ( bridge_addr[8:2] ),
    .a_din  ( bridge_wr_data ),
    .a_dout (  ),

    .b_clk  ( clk ),
    .b_wr   ( 1'b0 ),
    .b_addr ( rbuf_raddr ),
    .b_din  ( 32'd0 ),
    .b_dout ( rbuf_q )
);

    // ------------------------------------------------------------------
    // Command handshake toggles
    // ------------------------------------------------------------------
    reg        req_t = 1'b0;
    reg        done_t_74 = 1'b0;
    reg [31:0] req_lba;
    reg [15:0] req_slot;
    reg        req_is_read;

    wire req_t_74, done_t_s;
    synch_3 s_req  (req_t,     req_t_74, clk_74a);
    synch_3 s_done (done_t_74, done_t_s, clk);

    // ------------------------------------------------------------------
    // Machine-side FSM
    // ------------------------------------------------------------------
    localparam [3:0] MS_IDLE     = 4'd0;
    localparam [3:0] MS_W_SWEEP  = 4'd1;
    localparam [3:0] MS_REQ      = 4'd2;
    localparam [3:0] MS_WAIT     = 4'd3;
    localparam [3:0] MS_W_FIN    = 4'd4;
    localparam [3:0] MS_R_REQ    = 4'd5;
    localparam [3:0] MS_R_WAIT   = 4'd6;
    localparam [3:0] MS_R_STREAM = 4'd7;
    localparam [3:0] MS_R_FIN    = 4'd8;

    reg [3:0]  mstate = MS_IDLE;
    reg        src_tape;          // write capture source / ack routing
    reg [9:0]  sweep;
    reg        done_q;
    wire [7:0] cur_din = src_tape ? tape_din : save_din;

    always @(posedge clk) begin
        if (rst) begin
            mstate    <= MS_IDLE;
            sd_ack    <= 1'b0;
            sd1_ack   <= 1'b0;
            wbuf_wr   <= 1'b0;
            buff_wr   <= 1'b0;
            buff_addr <= 9'd0;
            done_q    <= done_t_s;
        end else begin
            wbuf_wr <= 1'b0;
            buff_wr <= 1'b0;
            done_q  <= done_t_s;

            case (mstate)
                MS_IDLE: begin
                    if (sd_wr) begin                    // BASIC save sector
                        src_tape  <= 1'b0;
                        sd_ack    <= 1'b1;
                        req_lba   <= sd_lba;
                        req_slot  <= SLOT_SAVE;
                        req_is_read <= 1'b0;
                        sweep     <= 10'd0;
                        buff_addr <= 9'd0;
                        mstate    <= MS_W_SWEEP;
                    end else if (sd1_wr) begin          // tape record sector
                        src_tape  <= 1'b1;
                        sd1_ack   <= 1'b1;
                        req_lba   <= sd1_lba;
                        req_slot  <= SLOT_TAPE;
                        req_is_read <= 1'b0;
                        sweep     <= 10'd0;
                        buff_addr <= 9'd0;
                        mstate    <= MS_W_SWEEP;
                    end else if (sd1_rd) begin          // tape playback sector
                        src_tape  <= 1'b1;
                        sd1_ack   <= 1'b1;
                        req_lba   <= sd1_lba;
                        req_slot  <= SLOT_TAPE;
                        req_is_read <= 1'b1;
                        mstate    <= MS_R_REQ;
                    end
                end

                // ---- write path: capture 512 bytes from the client ----
                // The client's sd_buff_din is registered: byte N arrives one
                // cycle after address N, so words complete on s%4==1, s>=5
                // (see jr100_save_bridge history for the derivation).
                MS_W_SWEEP: begin
                    sweep     <= sweep + 10'd1;
                    buff_addr <= (sweep < 10'd511) ? sweep[8:0] + 9'd1 : 9'd0;
                    if (sweep != 10'd0 && sweep <= 10'd512)
                        wbuf_wdata <= {wbuf_wdata[23:0], cur_din};
                    if (sweep[1:0] == 2'd1 && sweep >= 10'd5) begin
                        wbuf_wr    <= 1'b1;
                        wbuf_waddr <= sweep[8:2] - 7'd1;
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
                        mstate <= MS_W_FIN;
                end

                MS_W_FIN: begin
                    if (src_tape) sd1_ack <= 1'b0;
                    else          sd_ack  <= 1'b0;
                    mstate <= MS_IDLE;
                end

                // ---- read path: fetch the chunk, then stream it out ----
                MS_R_REQ: begin
                    req_t  <= ~req_t;
                    mstate <= MS_R_WAIT;
                end

                MS_R_WAIT: begin
                    if (done_q != done_t_s) begin
                        sweep      <= 10'd0;
                        rbuf_raddr <= 7'd0;
                        mstate     <= MS_R_STREAM;
                    end
                end

                // At cycle s the word address for byte s is presented; the
                // BRAM output is a cycle behind, so cycle s strobes byte s-1
                // out of rbuf_q with a big-endian lane mux.
                MS_R_STREAM: begin
                    sweep      <= sweep + 10'd1;
                    rbuf_raddr <= sweep[8:2];
                    if (sweep != 10'd0) begin
                        buff_addr <= sweep[8:0] - 9'd1;
                        case (sweep[1:0] - 2'd1)          // (s-1) & 3
                            2'd0: buff_dout <= rbuf_q[31:24];
                            2'd1: buff_dout <= rbuf_q[23:16];
                            2'd2: buff_dout <= rbuf_q[15:8];
                            default: buff_dout <= rbuf_q[7:0];
                        endcase
                        buff_wr   <= 1'b1;
                    end
                    if (sweep == 10'd512)
                        mstate <= MS_R_FIN;
                end

                MS_R_FIN: begin
                    sd1_ack <= 1'b0;
                    mstate  <= MS_IDLE;
                end

                default: mstate <= MS_IDLE;
            endcase
        end
    end

    // ------------------------------------------------------------------
    // Host-side FSM: one target command per request
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
                target_dataslot_read  <= 1'b0;
                target_dataslot_write <= 1'b0;
                if (req_q_74 != req_t_74) begin
                    target_dataslot_id         <= req_slot;
                    target_dataslot_slotoffset <= {req_lba[22:0], 9'd0};
                    target_dataslot_bridgeaddr <= req_is_read ? RD_BRIDGE
                                                              : WR_BRIDGE;
                    target_dataslot_length     <= 32'd512;
                    if (req_is_read) target_dataslot_read  <= 1'b1;
                    else             target_dataslot_write <= 1'b1;
                    hstate <= HS_CMD;
                end
            end

            HS_CMD: begin
                if (target_dataslot_ack) begin
                    target_dataslot_read  <= 1'b0;
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
