//============================================================================
//
//  JR-100 tape image sector bridge (JR100_MiSTer).
//
//  Serves jr100_cmt's byte read/write interface from the image mounted
//  on the framework's S1 slot through the hps_io 512-byte block
//  protocol. One shared buffer BRAM backs both directions; playback
//  and recording are mutually exclusive in the deck, and a recording
//  invalidates the read cache.
//
//  Reads: a miss fetches the sector (sd_rd handshake; hps_io streams
//  the sector into the buffer with sd_buff_wr strobes), then the byte
//  is served registered. Reads past the image size return $FF.
//
//  Writes: bytes land in the buffer; crossing into a new sector first
//  flushes the previous one (sd_wr handshake; hps_io pulls sd_buff_din
//  addressed by sd_buff_addr) and clears the buffer. `flush` (pulsed
//  when the deck's recording session ends) writes out the final
//  partial sector. Writes past the image size are acknowledged and
//  dropped.
//
//  Copyright (C) 2026 Zabaglione
//  SPDX-License-Identifier: GPL-2.0-or-later
//
//============================================================================

module jr100_tape_buf
(
    input  logic        clk,
    input  logic        rst,

    input  logic        img_mounted,   // pulse
    input  logic        img_readonly,
    input  logic [63:0] img_size,
    output logic        tape_ok,
    output logic        tape_writable,

    // deck byte side
    input  logic        rd_req,
    input  logic [31:0] rd_pos,
    output logic [7:0]  rd_data,
    output logic        rd_ack,
    input  logic        wr_req,
    input  logic [31:0] wr_pos,
    input  logic [7:0]  wr_data,
    output logic        wr_ack,
    input  logic        flush,         // pulse: end of recording session

    // hps_io block interface (slot 1)
    output logic [31:0] sd_lba,
    output logic        sd_rd,
    output logic        sd_wr,
    input  logic        sd_ack,
    input  logic [8:0]  sd_buff_addr,
    input  logic [7:0]  sd_buff_dout,
    input  logic        sd_buff_wr,
    output logic [7:0]  sd_buff_din
);

    logic [31:0] size;
    always_ff @(posedge clk) begin
        if (rst) begin
            tape_ok       <= 1'b0;
            tape_writable <= 1'b0;
        end else if (img_mounted) begin
            tape_ok       <= (img_size != 0) && (img_size[63:32] == 32'd0);
            tape_writable <= (img_size != 0) && !img_readonly;
            size          <= img_size[31:0];
        end
    end

    logic [7:0] buffer[512];
    logic       cache_valid;
    logic [22:0] cache_sec;
    logic       wsec_valid;
    logic [22:0] wsec;

    always_ff @(posedge clk) sd_buff_din <= buffer[sd_buff_addr];

    typedef enum logic [2:0] {
        B_IDLE, B_RD_SD, B_SERVE_A, B_SERVE_B,
        B_FLUSH, B_FLUSH_END, B_ZERO
    } bstate_t;

    bstate_t    bstate /* verilator public_flat_rd */;
    logic [9:0] zcnt;
    logic       flush_pend;
    logic       flush_only;    // flush without a pending byte write
    logic       req_hold;      // wr_req accepted, waiting for release
    logic [15:0] dbg_stores /* verilator public_flat_rd */;
    logic [15:0] dbg_drops /* verilator public_flat_rd */;
    logic [7:0]  dbg_flushes /* verilator public_flat_rd */;
    logic [8:0] serve_addr;

    always_ff @(posedge clk) begin
        if (rst) begin
            bstate      <= B_IDLE;
            sd_rd       <= 1'b0;
            sd_wr       <= 1'b0;
            rd_ack      <= 1'b0;
            wr_ack      <= 1'b0;
            cache_valid <= 1'b0;
            wsec_valid  <= 1'b0;
            flush_pend  <= 1'b0;
            req_hold    <= 1'b0;
            dbg_stores  <= '0;
            dbg_drops   <= '0;
            dbg_flushes <= '0;
        end else begin
            rd_ack <= 1'b0;
            wr_ack <= 1'b0;
            if (flush) flush_pend <= 1'b1;
            if (!wr_req) req_hold <= 1'b0;

            if (img_mounted) begin
                cache_valid <= 1'b0;
                wsec_valid  <= 1'b0;
            end

            // hps_io streams a sector into the buffer during a read ack
            if (sd_buff_wr && sd_ack) buffer[sd_buff_addr] <= sd_buff_dout;

            unique case (bstate)
            B_IDLE: begin
                if (flush_pend) begin
                    flush_pend <= 1'b0;
                    if (wsec_valid) begin
                        dbg_flushes <= dbg_flushes + 8'd1;
                        flush_only <= 1'b1;
                        sd_lba     <= {9'b0, wsec};
                        sd_wr      <= 1'b1;
                        bstate     <= B_FLUSH;
                    end
                end else if (rd_req) begin
                    if (rd_pos >= size) begin
                        rd_data <= 8'hFF;
                        rd_ack  <= 1'b1;
                    end else if (cache_valid && rd_pos[31:9] == cache_sec) begin
                        serve_addr <= rd_pos[8:0];
                        bstate     <= B_SERVE_A;
                    end else begin
                        sd_lba     <= {9'b0, rd_pos[31:9]};
                        sd_rd      <= 1'b1;
                        serve_addr <= rd_pos[8:0];
                        bstate     <= B_RD_SD;
                    end
                end else if (wr_req && !req_hold) begin
                    if (wr_pos >= size || !tape_writable) begin
                        req_hold <= 1'b1;
                        wr_ack <= 1'b1;             // dropped
                        dbg_drops <= dbg_drops + 16'd1;
                    end else if (wsec_valid && wr_pos[31:9] != wsec) begin
                        flush_only <= 1'b0;
                        sd_lba     <= {9'b0, wsec};
                        sd_wr      <= 1'b1;
                        bstate     <= B_FLUSH;
                    end else begin
                        buffer[wr_pos[8:0]] <= wr_data;
                        wsec       <= wr_pos[31:9];
                        wsec_valid <= 1'b1;
                        cache_valid <= 1'b0;
                        wr_ack     <= 1'b1;
                        req_hold   <= 1'b1;
                        dbg_stores <= dbg_stores + 16'd1;
                    end
                end
            end

            B_RD_SD: begin
                if (sd_ack) sd_rd <= 1'b0;
                if (!sd_rd && !sd_ack) begin
                    cache_valid <= 1'b1;
                    cache_sec   <= rd_pos[31:9];
                    bstate      <= B_SERVE_A;
                end
            end

            B_SERVE_A: bstate <= B_SERVE_B;   // registered buffer read

            B_SERVE_B: begin
                rd_data <= buffer[serve_addr];
                rd_ack  <= 1'b1;
                bstate  <= B_IDLE;
            end

            B_FLUSH: begin
                if (sd_ack) sd_wr <= 1'b0;
                if (!sd_wr && !sd_ack) begin
                    wsec_valid <= 1'b0;
                    zcnt       <= 10'd0;
                    bstate     <= B_ZERO;
                end
            end

            B_ZERO: begin
                buffer[zcnt[8:0]] <= 8'h00;
                zcnt <= zcnt + 10'd1;
                if (zcnt == 10'd511) begin
                    bstate <= flush_only ? B_IDLE : B_FLUSH_END;
                end
            end

            B_FLUSH_END: begin
                // resume the byte write that triggered the flush
                buffer[wr_pos[8:0]] <= wr_data;
                wsec       <= wr_pos[31:9];
                wsec_valid <= 1'b1;
                cache_valid <= 1'b0;
                wr_ack     <= 1'b1;
                req_hold   <= 1'b1;
                bstate     <= B_IDLE;
            end

            default: bstate <= B_IDLE;
            endcase
        end
    end

endmodule
