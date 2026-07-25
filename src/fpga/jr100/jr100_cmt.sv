//============================================================================
//
//  JR-100 virtual cassette deck (JR100_MiSTer).
//
//  Signal format, established from the BASIC ROM's cassette routines
//  and the JR-100 technical material:
//    - output: VIA CB2, SR shift-out under T2 (T2L=$5D): SR bit period
//      2*($5D+2) = 190 CPU cycles; tone patterns SR=$AA ('1', 2400Hz)
//      and SR=$66 ('0', 1200Hz); one data bit = 8 SR bits = 1520 cycles
//    - input: the same waveform into CA1 (falling) + CB1 (rising); the
//      ROM classifies half-periods with T2=$0107 (263) as the divider
//    - byte frame: start 0, 8 data bits LSB first, stop 1 1
//    - tape layout: leader 4080 '1' bits, 33-byte header block
//      (name 16, start BE 2, length BE 2, flag 1, pad 11, checksum 1),
//      gap 255 '1' bits, then length+1 data bytes (data + checksum)
//
//  The tape file holds exactly the decoded bytes (33 + N + 1); leader
//  and gap are regenerated on playback. Byte transport to the mounted
//  image goes through a request interface served by a sector-buffer
//  bridge (playback reads at ~66 bytes/s, so latency is uncritical).
//
//  Playback: play_req starts from byte 0 and stops after the data
//  block (length parsed from the header as it streams out).
//  Recording: armed whenever the deck is idle; CB2 half-periods are
//  classified (short < 285 < long), framed, and decoded bytes are
//  written sequentially from byte 0. rec_active falls ~0.2s after the
//  carrier stops, which the bridge uses to flush its buffer.
//
//  Copyright (C) 2026 Zabaglione
//  SPDX-License-Identifier: GPL-2.0-or-later
//
//============================================================================

module jr100_cmt
(
    input  logic        clk,
    input  logic        rst,
    input  logic        cen,          // CPU-rate clock enable (894.886 kHz)

    input  logic        play_req,     // one-clk pulse
    input  logic        tape_ok,      // an image is mounted and usable

    output logic        cmt_out,      // to VIA CA1/CB1
    input  logic        cmt_in,       // from VIA CB2

    output logic        play_active,
    output logic        rec_active,

    // byte read (playback)
    output logic        rd_req,
    output logic [31:0] rd_pos,
    input  logic [7:0]  rd_data,
    input  logic        rd_ack,

    // byte write (recording)
    output logic        wr_req,
    output logic [31:0] wr_pos /* verilator public_flat_rd */,
    output logic [7:0]  wr_data,
    input  logic        wr_ack
);

    localparam int HALF_SHORT = 190;   // 2400Hz half-period, CPU cycles
    localparam int HALF_LONG  = 380;   // 1200Hz half-period
    localparam int LEADER_BITS = 4080;
    localparam int GAP_BITS    = 255;
    localparam int REC_THRESH  = 285;  // short/long divider
    localparam int REC_IDLE    = 200000;  // carrier-loss timeout (~0.22s)

    // ------------------------------------------------------------------
    // Playback: tone generator + frame/block sequencer
    // ------------------------------------------------------------------
    typedef enum logic [2:0] {
        P_IDLE, P_FETCH, P_LEADER, P_START, P_DATA, P_STOP
    } pstate_t;

    pstate_t     pstate /* verilator public_flat_rd */;
    logic [8:0]  half_cnt;     // CPU cycles left in current half-wave
    logic [2:0]  halves;       // half-waves left in current tone bit
    logic        cur_bit;      // tone: 1=2400Hz, 0=1200Hz
    logic [12:0] lead_cnt;
    logic [2:0]  bit_idx;
    logic [7:0]  shreg;
    logic [1:0]  stop_cnt;
    logic [31:0] blk_end;      // file offset one past the current block
    logic [15:0] data_len;
    logic        in_data;      // 0 = header block, 1 = data block
    logic        level;

    assign cmt_out = level;
    assign play_active = (pstate != P_IDLE);

    // one tone bit = 8 SR half-waves for '1' (2400Hz), 4 for '0';
    // both last 1520 CPU cycles.
    task automatic load_tone(input logic b);
        cur_bit  = b;
        halves   = b ? 3'd7 : 3'd3;
        half_cnt = b ? 9'(HALF_SHORT - 1) : 9'(HALF_LONG - 1);
    endtask

    always_ff @(posedge clk) begin
        if (rst) begin
            pstate <= P_IDLE;
            level  <= 1'b0;
            rd_req <= 1'b0;
        end else begin
            rd_req <= 1'b0;

            if (pstate == P_IDLE) begin
                if (play_req && tape_ok) begin
                    pstate   <= P_LEADER;
                    lead_cnt <= 13'(LEADER_BITS);
                    rd_pos   <= 32'd0;
                    blk_end  <= 32'd33;
                    in_data  <= 1'b0;
                    level    <= 1'b0;
                    load_tone(1'b1);
                end
            end else if (pstate == P_FETCH) begin
                // waiting for the bridge to deliver the next byte; the
                // carrier keeps idling at 2400Hz meanwhile
                if (rd_ack) begin
                    shreg   <= rd_data;
                    bit_idx <= 3'd0;
                    // header length field (offsets 16/17, big-endian)
                    if (!in_data && rd_pos == 32'd16) data_len[15:8] <= rd_data;
                    if (!in_data && rd_pos == 32'd17) data_len[7:0]  <= rd_data;
                    pstate  <= P_START;
                end
            end

            if (pstate != P_IDLE && cen) begin
                if (half_cnt != 0) begin
                    half_cnt <= half_cnt - 9'd1;
                end else begin
                    level <= ~level;
                    if (halves != 0) begin
                        halves   <= halves - 3'd1;
                        half_cnt <= cur_bit ? 9'(HALF_SHORT - 1)
                                            : 9'(HALF_LONG - 1);
                    end else begin
                        // tone bit cell finished
                        unique case (pstate)
                        P_LEADER: begin
                            load_tone(1'b1);
                            if (lead_cnt != 0) lead_cnt <= lead_cnt - 13'd1;
                            else begin
                                rd_req <= 1'b1;
                                pstate <= P_FETCH;
                            end
                        end
                        P_FETCH: load_tone(1'b1);   // idle carrier
                        P_START: begin
                            load_tone(1'b0);        // start bit sent next
                            pstate <= P_DATA;
                        end
                        P_DATA: begin
                            // send data bits LSB first, then stops
                            load_tone(shreg[0]);
                            shreg <= {1'b0, shreg[7:1]};
                            if (bit_idx == 3'd7) begin
                                pstate   <= P_STOP;
                                stop_cnt <= 2'd2;
                            end else begin
                                bit_idx <= bit_idx + 3'd1;
                            end
                        end
                        P_STOP: begin
                            load_tone(1'b1);
                            if (stop_cnt != 0) stop_cnt <= stop_cnt - 2'd1;
                            else begin
                                rd_pos <= rd_pos + 32'd1;
                                if (rd_pos + 32'd1 == blk_end) begin
                                    if (!in_data) begin
                                        in_data  <= 1'b1;
                                        blk_end  <= 32'd33 + {16'b0, data_len}
                                                    + 32'd1;
                                        lead_cnt <= 13'(GAP_BITS);
                                        pstate   <= P_LEADER;
                                    end else begin
                                        pstate <= P_IDLE;   // tape done
                                    end
                                end else begin
                                    rd_req <= 1'b1;
                                    pstate <= P_FETCH;
                                end
                            end
                        end
                        default: ;
                        endcase
                    end
                end
            end
        end
    end

    // ------------------------------------------------------------------
    // Recording: run-length half-wave decoder + frame decoder.
    //
    // Consecutive half-waves of one class always belong to the same
    // tone, and a class change always falls on a bit-cell boundary, so
    // a run of K short halves is K/8 '1' bits and a run of K long
    // halves is K/4 '0' bits - no phase tracking needed. Pending run
    // bits drain into the frame decoder one per clk (a half-wave lasts
    // >= 190 CPU cycles = 12160 clks, so draining always keeps up
    // except for the huge leader run, which only re-arms R_IDLE).
    // ------------------------------------------------------------------
    typedef enum logic [1:0] { R_IDLE, R_DATA, R_STOP } rstate_t;

    rstate_t     rstate /* verilator public_flat_rd */;
    logic        in_prev;
    logic [17:0] dur;          // CPU cycles since the last CB2 edge
    logic        run_class;    // 1 = short halves ('1' tone)
    logic [15:0] run_cnt /* verilator public_flat_rd */;
    logic [12:0] pend_bits;
    logic        pend_val;
    logic [2:0]  rbits;
    logic [7:0]  rsh;
    logic [17:0] idle_cnt;
    logic        session /* verilator public_flat_rd */;
    // byte FIFO toward the bridge: absorbs the bridge's sector-flush
    // latency so the bit drain never stalls (a byte lasts ~18ms on
    // tape, a sector flush takes ~1ms on the HPS)
    logic [7:0]  fifo[4];
    logic [2:0]  f_wp, f_rp;
    // start-bit hunt: frames are accepted only after a long pure-'1'
    // leader (the ROM's pre-leader sync block 111111110 x28 must not
    // be framed as bytes; real LOAD hunts the same way)
    logic [6:0]  ones_run;
    logic        locked;

    assign rec_active = session && !play_active;

    always_ff @(posedge clk) begin
        if (rst) begin
            rstate   <= R_IDLE;
            in_prev  <= 1'b0;
            idle_cnt <= 18'(REC_IDLE);
            session  <= 1'b0;
            run_cnt  <= 16'd0;
            pend_bits <= 13'd0;
            wr_req   <= 1'b0;
            wr_pos   <= 32'd0;
            f_wp     <= 3'd0;
            f_rp     <= 3'd0;
            locked   <= 1'b0;
            ones_run <= 7'd0;
        end else begin
            if (wr_ack) begin
                wr_req <= 1'b0;
                wr_pos <= wr_pos + 32'd1;
            end else if (!wr_req && f_wp != f_rp) begin
                wr_data <= fifo[f_rp[1:0]];
                f_rp    <= f_rp + 3'd1;
                wr_req  <= 1'b1;
            end

            // drain one pending run bit per clk into the frame decoder
            if (pend_bits != 0) begin
                pend_bits <= pend_bits - 13'd1;
                if (pend_val) begin
                    if (!(&ones_run)) ones_run <= ones_run + 7'd1;
                    if (ones_run >= 7'd64) locked <= 1'b1;
                end else begin
                    ones_run <= 7'd0;
                end
                unique case (rstate)
                R_IDLE:
                    if (!pend_val && locked) begin  // start bit
                        rstate <= R_DATA;
                        rbits  <= 3'd0;
                    end
                R_DATA: begin
                    rsh <= {pend_val, rsh[7:1]};
                    if (rbits == 3'd7) rstate <= R_STOP;
                    else               rbits <= rbits + 3'd1;
                end
                R_STOP: begin
                    // first stop bit: queue the byte, back to idle
                    if ((f_wp - f_rp) < 3'd4) begin
                        fifo[f_wp[1:0]] <= rsh;
                        f_wp <= f_wp + 3'd1;
                    end
                    rstate <= R_IDLE;
                end
                default: rstate <= R_IDLE;
                endcase
            end

            if (play_active) begin
                rstate   <= R_IDLE;
                session  <= 1'b0;
                run_cnt  <= 16'd0;
                pend_bits <= 13'd0;
                locked   <= 1'b0;
                ones_run <= 7'd0;
                idle_cnt <= 18'(REC_IDLE);
            end else if (cen) begin
                in_prev <= cmt_in;
                if (cmt_in != in_prev) begin
                    // half-wave finished: classify
                    logic is_long;
                    is_long = (dur >= 18'(REC_THRESH));
                    dur      <= 18'd0;
                    idle_cnt <= 18'd0;
                    if (!session) begin
                        // new recording: rewind and start the first run
                        session   <= 1'b1;
                        wr_pos    <= 32'd0;
                        rstate    <= R_IDLE;
                        locked    <= 1'b0;
                        ones_run  <= 7'd0;
                        run_class <= ~is_long;
                        run_cnt   <= 16'd1;
                    end else if ((~is_long) == run_class) begin
                        run_cnt <= run_cnt + 16'd1;
                    end else begin
                        // class change = cell boundary: queue the run
                        pend_val  <= run_class;
                        pend_bits <= run_class ? 13'(run_cnt >> 3)
                                               : 13'(run_cnt >> 2);
                        run_class <= ~is_long;
                        run_cnt   <= 16'd1;
                    end
                end else if (idle_cnt < 18'(REC_IDLE)) begin
                    dur      <= dur + 18'd1;
                    idle_cnt <= idle_cnt + 18'd1;
                end else if (session) begin
                    // carrier lost: queue the final run, then keep the
                    // session open until the bit drain, the frame
                    // decoder and the byte FIFO have all emptied, so
                    // the last byte reaches the bridge before the
                    // session-end flush fires
                    if (run_cnt != 0) begin
                        pend_val  <= run_class;
                        pend_bits <= run_class ? 13'(run_cnt >> 3)
                                               : 13'(run_cnt >> 2);
                        run_cnt   <= 16'd0;
                    end else if (pend_bits == 0 && f_wp == f_rp && !wr_req) begin
                        session <= 1'b0;
                        dur     <= 18'd0;
                    end
                end
            end
        end
    end

endmodule
