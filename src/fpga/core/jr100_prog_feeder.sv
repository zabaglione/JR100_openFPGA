//============================================================================
//
//  Program feeder: buffers a host-pushed data slot, then replays it into
//  jr100_top's ioctl-style program ports.
//
//  APF's host-push has no backpressure - the bridge streams the file at
//  its own pace - while jr100_loader/jr100_bas_loader throttle their input
//  with wait_req (MiSTer's ioctl_wait contract). This module separates the
//  two worlds: data_loader instances drop the incoming bytes into a 64 KiB
//  BRAM at bridge speed, and once the host signals all slots complete, a
//  drain FSM replays the bytes one strobe at a time, pausing whenever the
//  consumer asserts wait.
//
//  Only one program slot loads at a time (the Pocket UI is modal), so one
//  buffer serves both the .prg and .bas paths; which output port replays
//  is chosen by the slot id latched at request time.
//
//  Copyright (C) 2026 Zabaglione
//  SPDX-License-Identifier: GPL-2.0-or-later
//
//============================================================================

`default_nettype none

module jr100_prog_feeder #(
    parameter [15:0] SLOT_PRG = 16'd1,
    parameter [15:0] SLOT_BAS = 16'd2
) (
    input  wire        clk,           // machine clock
    input  wire        rst,

    // slot bookkeeping, clk_74a domain (synchronised here)
    input  wire        clk_74a,
    input  wire        dataslot_requestwrite,
    input  wire [15:0] dataslot_requestwrite_id,
    input  wire [31:0] dataslot_requestwrite_size,
    input  wire        dataslot_allcomplete,

    // buffered bytes from the data_loader instances (clk domain)
    input  wire        buf_wr,
    input  wire [15:0] buf_addr,
    input  wire [7:0]  buf_data,

    // replay ports (jr100_top ioctl-style)
    output reg         prg_download,
    output reg         prg_wr,
    output reg  [7:0]  prg_data,
    input  wire        prg_wait,

    output reg         bas_download,
    output reg         bas_wr,
    output reg  [7:0]  bas_data,
    input  wire        bas_wait,

    output wire        feeding
);

    // ------------------------------------------------------------------
    // Latch which program slot the host is writing, and its size.
    //
    // The id/size registers are written once per request on clk_74a and
    // stay stable for the whole transfer, so the machine side reads them
    // quasi-statically after synchronising the completion edge.
    // ------------------------------------------------------------------
    reg [15:0] req_id_74   = 16'd0;
    reg [31:0] req_size_74 = 32'd0;
    reg        req_is_prog_74 = 1'b0;

    always @(posedge clk_74a) begin
        if (dataslot_requestwrite) begin
            req_id_74      <= dataslot_requestwrite_id;
            req_size_74    <= dataslot_requestwrite_size;
            req_is_prog_74 <= (dataslot_requestwrite_id == SLOT_PRG) ||
                              (dataslot_requestwrite_id == SLOT_BAS);
        end
    end

    wire allcomplete_s, is_prog_s;
    synch_3 s_complete (dataslot_allcomplete, allcomplete_s, clk);
    synch_3 s_isprog   (req_is_prog_74,       is_prog_s,     clk);

    // ------------------------------------------------------------------
    // 64 KiB replay buffer (single clock domain: data_loader already
    // crossed the bytes into the machine clock)
    // ------------------------------------------------------------------
    reg  [15:0] rd_addr;
    wire [7:0]  rd_data;

bram_block_dp #(
    .DATA ( 8 ),
    .ADDR ( 16 )
) replay_buffer (
    .a_clk  ( clk ),
    .a_wr   ( buf_wr ),
    .a_addr ( buf_addr ),
    .a_din  ( buf_data ),
    .a_dout (  ),

    .b_clk  ( clk ),
    .b_wr   ( 1'b0 ),
    .b_addr ( rd_addr ),
    .b_din  ( 8'd0 ),
    .b_dout ( rd_data )
);

    // ------------------------------------------------------------------
    // Drain FSM: waits for the transfer to finish, then replays.
    // ------------------------------------------------------------------
    localparam [2:0] ST_IDLE   = 3'd0;
    localparam [2:0] ST_ARM    = 3'd1;   // transfer in progress
    localparam [2:0] ST_FETCH  = 3'd2;   // rd_data valid next cycle
    localparam [2:0] ST_STROBE = 3'd3;   // one-cycle wr pulse
    localparam [2:0] ST_GAP    = 3'd4;   // honour wait before the next byte
    localparam [2:0] ST_TAIL   = 3'd5;   // deassert download after the end

    reg [2:0]  state = ST_IDLE;
    reg        to_bas;                   // replay target
    reg [16:0] remaining;
    reg [3:0]  tail_cnt;

    wire       cur_wait = to_bas ? bas_wait : prg_wait;

    assign feeding = (state != ST_IDLE) && (state != ST_ARM);

    always @(posedge clk) begin
        if (rst) begin
            state        <= ST_IDLE;
            prg_download <= 1'b0;
            prg_wr       <= 1'b0;
            bas_download <= 1'b0;
            bas_wr       <= 1'b0;
        end else begin
            prg_wr <= 1'b0;
            bas_wr <= 1'b0;

            case (state)
                ST_IDLE: begin
                    // a program slot write has started (allcomplete drops
                    // while the latched id says .prg/.bas)
                    if (!allcomplete_s && is_prog_s)
                        state <= ST_ARM;
                end

                ST_ARM: begin
                    if (allcomplete_s) begin
                        // req_* are stable now (latched at request time,
                        // read after the completion edge). The is_prog
                        // recheck guards the arm-time race where a stale
                        // flag overlapped the completion synchroniser.
                        to_bas    <= (req_id_74 == SLOT_BAS);
                        remaining <= (req_size_74 > 32'd65536)
                                     ? 17'd65536 : req_size_74[16:0];
                        rd_addr   <= 16'd0;
                        if (!is_prog_s || req_size_74 == 32'd0)
                            state <= ST_IDLE;
                        else begin
                            state <= ST_FETCH;
                            if (req_id_74 == SLOT_BAS) bas_download <= 1'b1;
                            else                       prg_download <= 1'b1;
                        end
                    end
                end

                ST_FETCH: state <= ST_STROBE;   // BRAM read latency

                ST_STROBE: begin
                    if (!cur_wait) begin
                        if (to_bas) begin
                            bas_data <= rd_data;
                            bas_wr   <= 1'b1;
                        end else begin
                            prg_data <= rd_data;
                            prg_wr   <= 1'b1;
                        end
                        rd_addr   <= rd_addr + 16'd1;
                        remaining <= remaining - 17'd1;
                        state     <= (remaining == 17'd1) ? ST_TAIL : ST_GAP;
                        tail_cnt  <= 4'd15;
                    end
                end

                ST_GAP: begin
                    // one idle cycle between strobes, matching the pace the
                    // MiSTer ioctl path presents at its fastest
                    if (!cur_wait)
                        state <= ST_FETCH;
                end

                ST_TAIL: begin
                    // keep download asserted briefly past the last byte so
                    // the consumer sees the stream end cleanly, then drop it
                    // (the finaliser runs on its own with wait asserted)
                    if (!cur_wait) begin
                        if (tail_cnt == 4'd0) begin
                            prg_download <= 1'b0;
                            bas_download <= 1'b0;
                            state        <= ST_IDLE;
                        end else begin
                            tail_cnt <= tail_cnt - 4'd1;
                        end
                    end
                end

                default: state <= ST_IDLE;
            endcase
        end
    end

endmodule

`default_nettype wire
