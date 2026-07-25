//============================================================================
//
//  JR-100 BASIC saver (JR100_MiSTer).
//
//  Serialises the current BASIC program area into the image file mounted
//  on the framework's S0 slot, as a PROG v2 container:
//      PROG + version 2
//      PBAS section: current program bytes ($0246 .. end)
//      CMNT section: zero comment + padding to the exact file size
//  The CMNT padding makes the container consume the whole mounted file,
//  so stale bytes from an earlier, longer save can never trail behind
//  the last section (both parsers read sections to end-of-file). The
//  result is loadable through the normal "Load PRG" slot and by
//  pyjr100emu's load_prog.
//
//  The program extent comes from the BASIC workspace: $0004/5 must hold
//  the text start $0246 and $0006/7 (big-endian) holds end+3, exactly
//  what the ROM maintains and what the PRG/BAS loaders finalise, so
//  length = ptr($0006) - $0247. The save is aborted, leaving the file
//  untouched, when the workspace does not look like that, when no image
//  (or a read-only one) is mounted, when the file size is not a
//  multiple of 512, or when the program does not fit.
//
//  Memory is read through the CPU port (the CPU is frozen via busy,
//  like the loaders). The sd interface is the hps_io byte-level block
//  protocol: one 512-byte sector per sd_wr/sd_ack handshake, data
//  served from a buffer BRAM addressed by sd_buff_addr.
//
//  Copyright (C) 2026 Zabaglione
//  SPDX-License-Identifier: GPL-2.0-or-later
//
//============================================================================

module jr100_saver
(
    input  logic        clk,
    input  logic        rst,

    input  logic        save_req,      // one-clk pulse from the OSD toggle
    input  logic        img_mounted,   // pulse: (re)mount / unmount
    input  logic        img_readonly,
    input  logic [63:0] img_size,

    output logic        busy,

    // memory read (shares the CPU port, CPU frozen while busy)
    output logic [15:0] mem_addr,
    input  logic [7:0]  mem_rdata,     // registered, valid 1 clk after addr

    // hps_io block write interface (slot 0)
    output logic [31:0] sd_lba,
    output logic        sd_wr,
    input  logic        sd_ack,
    input  logic [8:0]  sd_buff_addr,
    output logic [7:0]  sd_buff_din
);

    localparam logic [15:0] BASIC_START = 16'h0246;

    typedef enum logic [3:0] {
        S_IDLE,
        S_RD_A,        // workspace pointer reads: addr, BRAM wait, capture
        S_RD_W,
        S_RD_B,
        S_CHECK,
        S_FILL_A,      // sector buffer fill, same 3-cycle pattern
        S_FILL_W,
        S_FILL_B,
        S_REQ,         // sd_wr until ack
        S_ACK,         // wait ack fall
        S_DONE
    } state_t;

    state_t state /* verilator public_flat_rd */;

    logic        have_img;
    logic [31:0] total;        // mounted file size (bytes)
    logic [31:0] lba_count;

    always_ff @(posedge clk) begin
        if (rst) begin
            have_img <= 1'b0;
        end else if (img_mounted) begin
            have_img <= (img_size != 0) && !img_readonly &&
                        (img_size[8:0] == 9'd0) && (img_size[63:32] == 32'd0);
            total    <= img_size[31:0];
        end
    end

    logic [1:0]  ptr_idx;
    logic [15:0] ws_start;     // $0004/5
    logic [15:0] ws_end;       // $0006/7
    logic [15:0] len;          // PBAS payload length
    logic [31:0] t0;           // CMNT section offset = 20 + len
    logic [31:0] cmnt_len;     // CMNT section length field
    logic [31:0] lba;
    logic [8:0]  fill_j;
    logic [31:0] byte_idx;

    // sector buffer (2-port: fill write / hps_io read)
    logic [7:0] secbuf[512];
    always_ff @(posedge clk) sd_buff_din <= secbuf[sd_buff_addr];

    assign busy = (state != S_IDLE);

    // byte value for container offset idx (memory bytes use mem_rdata)
    function automatic logic [7:0] gen_byte(input logic [31:0] idx,
                                            input logic [7:0]  mem_byte);
        logic [31:0] pbas_len;
        pbas_len = {16'b0, len} + 32'd4;
        if      (idx == 0)  gen_byte = 8'h50;                 // "PROG"
        else if (idx == 1)  gen_byte = 8'h52;
        else if (idx == 2)  gen_byte = 8'h4F;
        else if (idx == 3)  gen_byte = 8'h47;
        else if (idx == 4)  gen_byte = 8'h02;                 // version 2 LE
        else if (idx < 8)   gen_byte = 8'h00;
        else if (idx == 8)  gen_byte = 8'h50;                 // "PBAS" id LE
        else if (idx == 9)  gen_byte = 8'h42;
        else if (idx == 10) gen_byte = 8'h41;
        else if (idx == 11) gen_byte = 8'h53;
        else if (idx == 12) gen_byte = pbas_len[7:0];
        else if (idx == 13) gen_byte = pbas_len[15:8];
        else if (idx == 14) gen_byte = pbas_len[23:16];
        else if (idx == 15) gen_byte = pbas_len[31:24];
        else if (idx == 16) gen_byte = len[7:0];              // payload len LE
        else if (idx == 17) gen_byte = len[15:8];
        else if (idx < 20)  gen_byte = 8'h00;
        else if (idx < t0)  gen_byte = mem_byte;              // program bytes
        else if (idx == t0 + 0) gen_byte = 8'h43;             // "CMNT" id LE
        else if (idx == t0 + 1) gen_byte = 8'h4D;
        else if (idx == t0 + 2) gen_byte = 8'h4E;
        else if (idx == t0 + 3) gen_byte = 8'h54;
        else if (idx == t0 + 4) gen_byte = cmnt_len[7:0];
        else if (idx == t0 + 5) gen_byte = cmnt_len[15:8];
        else if (idx == t0 + 6) gen_byte = cmnt_len[23:16];
        else if (idx == t0 + 7) gen_byte = cmnt_len[31:24];
        else                gen_byte = 8'h00;   // comment len 0 + padding
    endfunction

    always_ff @(posedge clk) begin
        if (rst) begin
            state <= S_IDLE;
            sd_wr <= 1'b0;
        end else begin
            unique case (state)
            S_IDLE: begin
                if (save_req && have_img) begin
                    ptr_idx <= 2'd0;
                    state   <= S_RD_A;
                end
            end

            S_RD_A: begin
                mem_addr <= 16'h0004 + {14'b0, ptr_idx};
                state    <= S_RD_W;
            end

            S_RD_W: state <= S_RD_B;

            S_RD_B: begin
                case (ptr_idx)
                    2'd0: ws_start[15:8] <= mem_rdata;
                    2'd1: ws_start[7:0]  <= mem_rdata;
                    2'd2: ws_end[15:8]   <= mem_rdata;
                    default: ws_end[7:0] <= mem_rdata;
                endcase
                if (ptr_idx == 2'd3) state <= S_CHECK;
                else begin
                    ptr_idx <= ptr_idx + 2'd1;
                    state   <= S_RD_A;
                end
            end

            S_CHECK: begin
                logic [15:0] l;
                l = ws_end - 16'h0247;
                // workspace sane, program inside main RAM, container
                // (20 + len + 12-byte minimum CMNT) fits in the file
                if (ws_start == BASIC_START &&
                    ws_end >= 16'h0247 && ws_end <= 16'h4001 &&
                    ({16'b0, l} + 32'd32) <= total) begin
                    len       <= l;
                    t0        <= {16'b0, l} + 32'd20;
                    cmnt_len  <= total - {16'b0, l} - 32'd28;
                    lba       <= 32'd0;
                    lba_count <= {9'b0, total[31:9]};
                    fill_j    <= 9'd0;
                    byte_idx  <= 32'd0;
                    state     <= S_FILL_A;
                end else begin
                    state <= S_IDLE;
                end
            end

            S_FILL_A: begin
                mem_addr <= BASIC_START + byte_idx[15:0] - 16'd20;
                state    <= S_FILL_W;
            end

            S_FILL_W: state <= S_FILL_B;

            S_FILL_B: begin
                secbuf[fill_j] <= gen_byte(byte_idx, mem_rdata);
                byte_idx <= byte_idx + 32'd1;
                if (fill_j == 9'd511) begin
                    fill_j <= 9'd0;
                    sd_wr  <= 1'b1;
                    state  <= S_REQ;
                end else begin
                    fill_j <= fill_j + 9'd1;
                    state  <= S_FILL_A;
                end
            end

            S_REQ: begin
                if (sd_ack) begin
                    sd_wr <= 1'b0;
                    state <= S_ACK;
                end
            end

            S_ACK: begin
                if (!sd_ack) begin
                    if (lba + 32'd1 == lba_count) state <= S_DONE;
                    else begin
                        lba   <= lba + 32'd1;
                        state <= S_FILL_A;
                    end
                end
            end

            S_DONE: state <= S_IDLE;

            default: state <= S_IDLE;
            endcase
        end
    end

    assign sd_lba = lba;

endmodule
