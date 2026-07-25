//============================================================================
//
//  JR-100 PROG container loader (JR100_MiSTer).
//
//  Streaming parser for the pyjr100emu PROG format (emulator/file/
//  program.py, the compatibility reference):
//
//    v1: "PROG" ver=1 nameLen name start len flag payload
//        flag==0 -> BASIC area at 0246 with workspace finalisation
//    v2: "PROG" ver=2 then sections {id, len, payload}:
//        PNAM/CMNT/unknown -> skipped
//        PBAS -> u32 progLen + data written at 0246, then finalised
//        PBIN -> u32 start + u32 len + data (+comment, skipped)
//
//  Finalisation (_finalize_basic): three 0xDF terminators after the
//  last data byte, BASIC start pointer at 0004/0005, and the four
//  workspace pointers at 0006-000D (final+2 .. final+5).
//
//  One memory write per streamed byte; the finaliser runs over
//  dedicated cycles with wait_req asserted so hps_io throttles the
//  stream (ioctl_wait).
//
//  Copyright (C) 2026 Zabaglione
//  SPDX-License-Identifier: GPL-2.0-or-later
//
//============================================================================

module jr100_loader
(
    input  logic        clk,
    input  logic        rst,

    input  logic        download,    // stream active (ioctl_download)
    input  logic        wr,          // byte strobe
    input  logic [7:0]  data,
    output logic        wait_req,
    output logic        busy,        // stream active or finaliser running

    output logic        mem_we,
    output logic [15:0] mem_addr,
    output logic [7:0]  mem_data,

    // autostart hints for the OSD option: a PBAS section was loaded
    // (RUN applies), or a v2 comment carried "USR=$hhhh"
    output logic        has_bas,
    output logic        usr_valid,
    output logic [15:0] usr_addr
);

    localparam logic [31:0] MAGIC        = 32'h474F5250;  // "PROG" LE
    localparam logic [31:0] SECTION_PNAM = 32'h4D414E50;
    localparam logic [31:0] SECTION_PBAS = 32'h53414250;
    localparam logic [31:0] SECTION_PBIN = 32'h4E494250;
    localparam logic [15:0] BASIC_START  = 16'h0246;

    typedef enum logic [4:0] {
        S_IDLE,
        S_MAGIC,
        S_VERSION,
        // v1
        S_V1_NAMELEN, S_V1_NAME, S_V1_START, S_V1_LEN, S_V1_FLAG, S_V1_DATA,
        // v2
        S_SEC_ID, S_SEC_LEN,
        S_PBAS_LEN, S_PBAS_DATA,
        S_PBIN_START, S_PBIN_LEN, S_PBIN_DATA,
        S_SKIP,
        // common
        S_FINALIZE,
        S_ERROR
    } state_t;

    state_t      state /* verilator public_flat_rd */, post_finalize;
    logic [31:0] wr_total /* verilator public_flat_rd */;
    logic [31:0] acc;
    logic [2:0]  nbyte;
    logic [31:0] count;        // bytes remaining in the current field
    logic [31:0] skip_count;   // remaining section bytes to skip
    logic [31:0] version;
    logic [31:0] sec_len;
    logic [15:0] wr_ptr;       // current write address
    logic [15:0] final_addr;   // last data byte of the BASIC area
    logic [3:0]  fin_step;
    logic        v1_flag_basic;
    // "USR=$hhhh" scanner over v2 skipped bytes (comments / names)
    logic [2:0]  m_idx;      // matched chars of "USR=$"
    logic [2:0]  hex_cnt;
    logic [15:0] hex_acc;

    function automatic logic is_hex(input logic [7:0] c);
        is_hex = (c >= "0" && c <= "9") || (c >= "A" && c <= "F") ||
                 (c >= "a" && c <= "f");
    endfunction

    function automatic logic [3:0] hex_val(input logic [7:0] c);
        if (c <= "9") hex_val = c[3:0];
        else          hex_val = c[3:0] + 4'd9;
    endfunction

    // Collect a little-endian u32; returns 1 when complete.
    function automatic logic u32_done(input logic [7:0] b);
        acc[8 * nbyte +: 8] = b;
        if (nbyte == 3'd3) begin
            nbyte = '0;
            u32_done = 1'b1;
        end else begin
            nbyte = nbyte + 3'd1;
            u32_done = 1'b0;
        end
    endfunction

    assign wait_req = (state == S_FINALIZE);
    // mem_we is registered (valid one cycle after the state that set it),
    // so busy must cover the trailing write after S_FINALIZE exits.
    assign busy = download || (state == S_FINALIZE) || mem_we;

    // workspace pointers (program.py _finalize_basic): final+2 .. final+5
    logic [15:0] fp0, fp1, fp2, fp3;
    assign fp0 = final_addr + 16'd2;
    assign fp1 = final_addr + 16'd3;
    assign fp2 = final_addr + 16'd4;
    assign fp3 = final_addr + 16'd5;

    always_ff @(posedge clk) begin
        mem_we <= 1'b0;
        if (mem_we) wr_total <= wr_total + 1;

        if (rst) begin
            state <= S_IDLE;
            nbyte <= '0;
            wr_total <= '0;
        end else begin
            unique case (state)
            // NOTE: download must lead the first wr strobe by at least
            // one clock (hps_io guarantees this; the harness mirrors it).
            S_IDLE: begin
                if (download) begin
                    state <= S_MAGIC;
                    nbyte <= '0;
                    count <= 32'd4;
                    has_bas   <= 1'b0;
                    usr_valid <= 1'b0;
                    m_idx     <= 3'd0;
                    hex_cnt   <= 3'd0;
                end
            end

            S_MAGIC: if (wr) begin
                if (u32_done(data)) begin
                    if (acc == MAGIC) state <= S_VERSION;
                    else              state <= S_ERROR;
                end
            end

            S_VERSION: if (wr) begin
                if (u32_done(data)) begin
                    version <= acc;
                    if (acc == 32'd1)      state <= S_V1_NAMELEN;
                    else if (acc == 32'd2) state <= S_SEC_ID;
                    else                   state <= S_ERROR;
                end
            end

            // ---------------- v1 ----------------
            S_V1_NAMELEN: if (wr) begin
                if (u32_done(data)) begin
                    skip_count <= acc;
                    state <= (acc == 0) ? S_V1_START : S_V1_NAME;
                end
            end

            S_V1_NAME: if (wr) begin
                skip_count <= skip_count - 32'd1;
                if (skip_count == 32'd1) state <= S_V1_START;
            end

            S_V1_START: if (wr) begin
                if (u32_done(data)) begin
                    wr_ptr <= acc[15:0];
                    state <= S_V1_LEN;
                end
            end

            S_V1_LEN: if (wr) begin
                if (u32_done(data)) begin
                    count <= acc;
                    state <= S_V1_FLAG;
                end
            end

            S_V1_FLAG: if (wr) begin
                if (u32_done(data)) begin
                    v1_flag_basic <= (acc == 32'd0);
                    if (count == 0) begin
                        final_addr <= wr_ptr - 16'd1;
                        fin_step <= '0;
                        post_finalize <= S_ERROR;   // v1: nothing follows
                        has_bas <= (acc == 32'd0);
                        state <= (acc == 32'd0) ? S_FINALIZE : S_ERROR;
                    end else begin
                        state <= S_V1_DATA;
                    end
                end
            end

            S_V1_DATA: if (wr) begin
                mem_we   <= 1'b1;
                mem_addr <= wr_ptr;
                mem_data <= data;
                wr_ptr   <= wr_ptr + 16'd1;
                count    <= count - 32'd1;
                if (count == 32'd1) begin
                    has_bas <= has_bas | v1_flag_basic;
                    if (v1_flag_basic) begin
                        final_addr <= wr_ptr;
                        fin_step <= '0;
                        post_finalize <= S_ERROR;   // consume any trailing bytes
                        state <= S_FINALIZE;
                    end else begin
                        state <= S_ERROR;           // done; ignore the rest
                    end
                end
            end

            // ---------------- v2 sections ----------------
            S_SEC_ID: if (wr) begin
                if (u32_done(data)) begin
                    count <= acc;                   // temporarily hold id
                    state <= S_SEC_LEN;
                end
            end

            S_SEC_LEN: if (wr) begin
                if (u32_done(data)) begin
                    sec_len <= acc;
                    if (count == SECTION_PBAS && acc >= 32'd4) begin
                        state <= S_PBAS_LEN;
                    end else if (count == SECTION_PBIN && acc >= 32'd8) begin
                        state <= S_PBIN_START;
                    end else begin
                        skip_count <= acc;
                        state <= (acc == 0) ? S_SEC_ID : S_SKIP;
                    end
                end
            end

            S_PBAS_LEN: if (wr) begin
                if (u32_done(data)) begin
                    has_bas <= 1'b1;
                    count <= acc;
                    skip_count <= sec_len - 32'd4 - acc;   // trailing bytes
                    wr_ptr <= BASIC_START;
                    if (acc == 0) begin
                        final_addr <= BASIC_START - 16'd1;
                        fin_step <= '0;
                        post_finalize <= S_SEC_ID;
                        state <= S_FINALIZE;
                    end else begin
                        state <= S_PBAS_DATA;
                    end
                end
            end

            S_PBAS_DATA: if (wr) begin
                mem_we   <= 1'b1;
                mem_addr <= wr_ptr;
                mem_data <= data;
                wr_ptr   <= wr_ptr + 16'd1;
                count    <= count - 32'd1;
                if (count == 32'd1) begin
                    final_addr <= wr_ptr;
                    fin_step <= '0;
                    post_finalize <= (skip_count == 0) ? S_SEC_ID : S_SKIP;
                    state <= S_FINALIZE;
                end
            end

            S_PBIN_START: if (wr) begin
                if (u32_done(data)) begin
                    wr_ptr <= acc[15:0];
                    state <= S_PBIN_LEN;
                end
            end

            S_PBIN_LEN: if (wr) begin
                if (u32_done(data)) begin
                    count <= acc;
                    skip_count <= sec_len - 32'd8 - acc;   // comment etc.
                    if (acc == 0) begin
                        state <= (sec_len == 32'd8) ? S_SEC_ID : S_SKIP;
                    end else begin
                        state <= S_PBIN_DATA;
                    end
                end
            end

            S_PBIN_DATA: if (wr) begin
                mem_we   <= 1'b1;
                mem_addr <= wr_ptr;
                mem_data <= data;
                wr_ptr   <= wr_ptr + 16'd1;
                count    <= count - 32'd1;
                if (count == 32'd1)
                    state <= (skip_count == 0) ? S_SEC_ID : S_SKIP;
            end

            S_SKIP: if (wr) begin
                skip_count <= skip_count - 32'd1;
                if (skip_count == 32'd1) state <= S_SEC_ID;
            end

            // ---------------- BASIC finalisation ----------------
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
                if (fin_step == 4'd12) state <= post_finalize;
                else                   fin_step <= fin_step + 4'd1;
            end

            S_ERROR: ;   // swallow the rest of the stream

            default: state <= S_IDLE;
            endcase

            // comment scanner: runs on the v2 skip path only
            if (wr && state == S_SKIP && !usr_valid) begin
                if (m_idx == 3'd5) begin
                    if (is_hex(data) && hex_cnt < 3'd4) begin
                        hex_acc <= {hex_acc[11:0], hex_val(data)};
                        hex_cnt <= hex_cnt + 3'd1;
                    end else if (hex_cnt != 0) begin
                        usr_valid <= 1'b1;
                        usr_addr  <= hex_acc;
                    end else begin
                        m_idx <= 3'd0;
                    end
                end else begin
                    case (m_idx)
                        3'd0: m_idx <= (data == "U") ? 3'd1 : 3'd0;
                        3'd1: m_idx <= (data == "S") ? 3'd2 :
                                       (data == "U") ? 3'd1 : 3'd0;
                        3'd2: m_idx <= (data == "R") ? 3'd3 :
                                       (data == "U") ? 3'd1 : 3'd0;
                        3'd3: m_idx <= (data == "=") ? 3'd4 :
                                       (data == "U") ? 3'd1 : 3'd0;
                        default: begin
                            if (data == "$") begin
                                m_idx   <= 3'd5;
                                hex_cnt <= 3'd0;
                                hex_acc <= '0;
                            end else m_idx <= (data == "U") ? 3'd1 : 3'd0;
                        end
                    endcase
                end
            end
            // stream ended while digits were pending: latch them
            if (!download && m_idx == 3'd5 && hex_cnt != 0 && !usr_valid) begin
                usr_valid <= 1'b1;
                usr_addr  <= hex_acc;
            end

            if (!download && state != S_FINALIZE && state != S_IDLE)
                state <= S_IDLE;
        end
    end

endmodule
