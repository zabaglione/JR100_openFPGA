//============================================================================
//
//  JR-100 BASIC text (.bas) loader (JR100_MiSTer).
//
//  Streaming parser mirroring pyjr100emu load_basic_text (emulator/
//  file/program.py):
//    - per line: decimal line number -> 16-bit big-endian, content
//      bytes (uppercased ASCII, \xx hex escapes), 0x00 terminator
//    - leading whitespace skipped, trailing whitespace dropped
//      (canonicalize: strip + upper), blank lines skipped
//    - always finalised like the PROG loader: three 0xDF terminators
//      and the BASIC workspace pointers
//
//  Flow control: a single pending-byte register replays the byte that
//  triggered a multi-write step (line-number flush, buffered-space
//  flush); wait_req (ioctl_wait) is asserted while a pending byte or
//  a flush is outstanding, so hps_io never overruns the parser.
//
//  Best-effort deviation (documented): the reference rejects malformed
//  files entirely (missing line number, bad escape, overlong line);
//  this parser skips malformed lines. Valid files load byte-identically.
//
//  Copyright (C) 2026 Zabaglione
//  SPDX-License-Identifier: GPL-2.0-or-later
//
//============================================================================

module jr100_bas_loader
(
    input  logic        clk,
    input  logic        rst,

    input  logic        download,
    input  logic        wr,
    input  logic [7:0]  data,
    output logic        wait_req,
    output logic        busy,

    output logic        mem_we,
    output logic [15:0] mem_addr,
    output logic [7:0]  mem_data
);

    localparam logic [15:0] BASIC_START = 16'h0246;

    typedef enum logic [3:0] {
        S_IDLE,
        S_LSTART,      // skip ws/newlines, expect a digit
        S_SKIPLN,      // malformed line: consume to newline
        S_NUMBER,      // accumulate decimal line number
        S_NUMLO,       // write line number low byte
        S_LWS,         // consume pending/streamed byte, skip lead ws
        S_CONTENT,
        S_SPFLUSH,     // write one buffered space per cycle
        S_ESC1,
        S_ESC2,
        S_TERM,        // write the 0x00 line terminator
        S_FINALIZE,
        S_DONE
    } state_t;

    state_t      state /* verilator public_flat_rd */;
    logic [15:0] line_no;
    logic [15:0] wr_ptr;
    logic [15:0] final_addr;
    logic        pend_valid;
    logic [7:0]  pend_byte;
    logic [7:0]  spaces;
    logic [3:0]  esc_hi;
    logic [3:0]  fin_step;
    logic        eos_term;     // TERM triggered by end of stream

    function automatic logic is_nl(input logic [7:0] c);
        is_nl = (c == 8'h0D) || (c == 8'h0A);
    endfunction

    function automatic logic is_sp(input logic [7:0] c);
        is_sp = (c == 8'h20) || (c == 8'h09);
    endfunction

    function automatic logic is_digit(input logic [7:0] c);
        is_digit = (c >= 8'h30) && (c <= 8'h39);
    endfunction

    function automatic logic [7:0] upcase(input logic [7:0] c);
        upcase = (c >= 8'h61 && c <= 8'h7A) ? (c - 8'h20) : c;
    endfunction

    function automatic logic [3:0] hexval(input logic [7:0] c);
        if (c >= 8'h30 && c <= 8'h39)      hexval = c[3:0];
        else if (c >= 8'h41 && c <= 8'h46) hexval = c[3:0] + 4'd9;
        else if (c >= 8'h61 && c <= 8'h66) hexval = c[3:0] + 4'd9;
        else                               hexval = 4'h0;
    endfunction

    assign wait_req = pend_valid ||
                      (state == S_NUMLO) || (state == S_SPFLUSH) ||
                      (state == S_TERM) || (state == S_FINALIZE);
    assign busy = download || (state == S_TERM) || (state == S_FINALIZE) ||
                  mem_we;

    logic [15:0] fp0, fp1, fp2, fp3;
    assign fp0 = final_addr + 16'd2;
    assign fp1 = final_addr + 16'd3;
    assign fp2 = final_addr + 16'd4;
    assign fp3 = final_addr + 16'd5;

    // byte available this cycle (pending replays first)
    logic        have;
    logic [7:0]  c;
    always_comb begin
        have = pend_valid | wr;
        c = pend_valid ? pend_byte : data;
    end

    logic eos;
    assign eos = !download && !pend_valid && !wr;

    always_ff @(posedge clk) begin
        mem_we <= 1'b0;

        if (rst) begin
            state <= S_IDLE;
            pend_valid <= 1'b0;
        end else begin
            unique case (state)
            S_IDLE: begin
                if (download) begin
                    state <= S_LSTART;
                    wr_ptr <= BASIC_START;
                    pend_valid <= 1'b0;
                    spaces <= '0;
                end
            end

            S_LSTART: begin
                if (eos) begin
                    final_addr <= wr_ptr - 16'd1;
                    fin_step <= '0;
                    state <= S_FINALIZE;
                end else if (have) begin
                    pend_valid <= 1'b0;
                    if (is_digit(c)) begin
                        line_no <= {12'b0, c[3:0]};
                        state <= S_NUMBER;
                    end else if (!is_sp(c) && !is_nl(c)) begin
                        state <= S_SKIPLN;
                    end
                end
            end

            S_SKIPLN: begin
                if (eos) begin
                    final_addr <= wr_ptr - 16'd1;
                    fin_step <= '0;
                    state <= S_FINALIZE;
                end else if (have) begin
                    pend_valid <= 1'b0;
                    if (is_nl(c)) state <= S_LSTART;
                end
            end

            S_NUMBER: begin
                if (eos) begin
                    // last line is a bare number: flush it, then terminate
                    mem_we <= 1'b1;
                    mem_addr <= wr_ptr;
                    mem_data <= line_no[15:8];
                    wr_ptr <= wr_ptr + 16'd1;
                    pend_byte <= 8'h0A;
                    pend_valid <= 1'b1;
                    state <= S_NUMLO;
                end else if (have) begin
                    if (is_digit(c)) begin
                        pend_valid <= 1'b0;
                        line_no <= line_no * 16'd10 + {12'b0, c[3:0]};
                    end else begin
                        mem_we <= 1'b1;
                        mem_addr <= wr_ptr;
                        mem_data <= line_no[15:8];
                        wr_ptr <= wr_ptr + 16'd1;
                        pend_byte <= c;
                        pend_valid <= 1'b1;
                        state <= S_NUMLO;
                    end
                end
            end

            S_NUMLO: begin
                mem_we <= 1'b1;
                mem_addr <= wr_ptr;
                mem_data <= line_no[7:0];
                wr_ptr <= wr_ptr + 16'd1;
                spaces <= '0;
                state <= S_LWS;
            end

            S_LWS: begin
                if (eos) begin
                    eos_term <= 1'b1;
                    state <= S_TERM;
                end else if (have) begin
                    pend_valid <= 1'b0;
                    if (is_nl(c)) begin
                        eos_term <= 1'b0;
                        state <= S_TERM;
                    end else if (is_sp(c)) begin
                        // leading whitespace (or post-flush impossible:
                        // pend is never a space after S_SPFLUSH)
                    end else if (c == 8'h5C) begin
                        state <= S_ESC1;
                    end else begin
                        mem_we <= 1'b1;
                        mem_addr <= wr_ptr;
                        mem_data <= upcase(c);
                        wr_ptr <= wr_ptr + 16'd1;
                        state <= S_CONTENT;
                    end
                end
            end

            S_CONTENT: begin
                if (eos) begin
                    eos_term <= 1'b1;
                    state <= S_TERM;
                end else if (have) begin
                    pend_valid <= 1'b0;
                    if (is_nl(c)) begin
                        eos_term <= 1'b0;
                        state <= S_TERM;
                    end else if (is_sp(c)) begin
                        spaces <= spaces + 8'd1;   // maybe trailing
                    end else if (spaces != 0) begin
                        pend_byte <= c;
                        pend_valid <= 1'b1;
                        state <= S_SPFLUSH;
                    end else if (c == 8'h5C) begin
                        state <= S_ESC1;
                    end else begin
                        mem_we <= 1'b1;
                        mem_addr <= wr_ptr;
                        mem_data <= upcase(c);
                        wr_ptr <= wr_ptr + 16'd1;
                    end
                end
            end

            S_SPFLUSH: begin
                mem_we <= 1'b1;
                mem_addr <= wr_ptr;
                mem_data <= 8'h20;
                wr_ptr <= wr_ptr + 16'd1;
                spaces <= spaces - 8'd1;
                if (spaces == 8'd1) state <= S_LWS;   // LWS replays pend
            end

            S_ESC1: begin
                if (eos) begin
                    eos_term <= 1'b1;
                    state <= S_TERM;
                end else if (have) begin
                    pend_valid <= 1'b0;
                    esc_hi <= hexval(c);
                    state <= S_ESC2;
                end
            end

            S_ESC2: begin
                if (eos) begin
                    eos_term <= 1'b1;
                    state <= S_TERM;
                end else if (have) begin
                    pend_valid <= 1'b0;
                    mem_we <= 1'b1;
                    mem_addr <= wr_ptr;
                    mem_data <= {esc_hi, hexval(c)};
                    wr_ptr <= wr_ptr + 16'd1;
                    state <= S_CONTENT;
                end
            end

            S_TERM: begin
                mem_we <= 1'b1;
                mem_addr <= wr_ptr;
                mem_data <= 8'h00;
                wr_ptr <= wr_ptr + 16'd1;
                spaces <= '0;
                if (eos_term) begin
                    final_addr <= wr_ptr;   // this terminator's address
                    fin_step <= '0;
                    state <= S_FINALIZE;
                end else begin
                    state <= S_LSTART;
                end
            end

            S_FINALIZE: begin
                mem_we <= 1'b1;
                case (fin_step)
                    4'd0:  begin mem_addr <= final_addr + 16'd1; mem_data <= 8'hDF; end
                    4'd1:  begin mem_addr <= final_addr + 16'd2; mem_data <= 8'hDF; end
                    4'd2:  begin mem_addr <= final_addr + 16'd3; mem_data <= 8'hDF; end
                    4'd3:  begin mem_addr <= 16'h0004; mem_data <= BASIC_START[15:8]; end
                    4'd4:  begin mem_addr <= 16'h0005; mem_data <= BASIC_START[7:0]; end
                    4'd5:  begin mem_addr <= 16'h0006; mem_data <= fp0[15:8]; end
                    4'd6:  begin mem_addr <= 16'h0007; mem_data <= fp0[7:0]; end
                    4'd7:  begin mem_addr <= 16'h0008; mem_data <= fp1[15:8]; end
                    4'd8:  begin mem_addr <= 16'h0009; mem_data <= fp1[7:0]; end
                    4'd9:  begin mem_addr <= 16'h000A; mem_data <= fp2[15:8]; end
                    4'd10: begin mem_addr <= 16'h000B; mem_data <= fp2[7:0]; end
                    4'd11: begin mem_addr <= 16'h000C; mem_data <= fp3[15:8]; end
                    default: begin mem_addr <= 16'h000D; mem_data <= fp3[7:0]; end
                endcase
                if (fin_step == 4'd12) state <= S_DONE;
                else                   fin_step <= fin_step + 4'd1;
            end

            S_DONE: begin
                if (!download) state <= S_IDLE;
            end

            default: state <= S_IDLE;
            endcase
        end
    end

endmodule
