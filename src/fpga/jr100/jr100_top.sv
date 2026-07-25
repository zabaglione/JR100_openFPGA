//============================================================================
//
//  JR-100 real-core top (JR100_MiSTer): the structure the MiSTer emu
//  module wraps in Phase E.
//
//  Clocking: one system clock (nominally 57.27272 MHz = 4x NTSC burst,
//  8x pixel clock). Clock enables divide it exactly as the real
//  machine's 14.31818 MHz crystal chain does:
//      cen_cpu = clk / 64  (894.886 kHz, AGENTS.md §3.1)
//      cen_pix = clk / 8   (7.159 MHz)
//
//  Memories are on-chip BRAMs (jr100_mem). The BASIC ROM image
//  (8 KiB: char ROM 0000-03FF + BASIC E400-FFFF) is streamed in via
//  the loader port while `downloading` holds the core in reset; on
//  release the CPU performs the real MC6800 reset sequence
//  (vector_reset).
//
//  cpu_hold is a simulation aid that freezes CPU/VIA while the video
//  keeps scanning (frame capture); tie low in the MiSTer wrapper.
//
//  Copyright (C) 2026 Zabaglione
//  SPDX-License-Identifier: GPL-2.0-or-later
//
//============================================================================

module jr100_top
(
    input  logic        clk,         // system clock (8x pixel, 64x CPU)
    input  logic        rst,
    input  logic        downloading, // ROM upload in progress
    input  logic        cpu_hold,    // sim aid: freeze CPU/VIA

    // ROM loader (8 KiB image)
    input  logic        loader_we,
    input  logic [12:0] loader_addr,
    input  logic [7:0]  loader_data,

    // PROG container loader (user programs, CPU frozen while active)
    input  logic        prg_download,
    input  logic        prg_wr,
    input  logic [7:0]  prg_data,
    output logic        prg_wait,

    // BASIC text loader (.bas, CPU frozen while active)
    input  logic        bas_download,
    input  logic        bas_wr,
    input  logic [7:0]  bas_data,
    output logic        bas_wait,

    // BASIC saver (writes the mounted S0 image, CPU frozen while active)
    input  logic        save_req,
    input  logic        img_mounted,
    input  logic        img_readonly,
    input  logic [63:0] img_size,
    output logic [31:0] sd_lba,
    output logic        sd_wr,
    input  logic        sd_ack,
    input  logic [8:0]  sd_buff_addr,
    output logic [7:0]  sd_buff_din,

    // autostart (OSD): type RUN / A=USR($hhhh) after a load
    input  logic        autostart_en,

    // JR-100 inputs
    input  logic [44:0] key_matrix,
    input  logic [7:0]  joy_status,   // CC02 value (AGENTS.md §4)
    input  logic        ext_ram_en,   // sampled at reset (board fitted)

    // audio: raw PB7 and the band-limited output stage (AGENTS.md §3.4).
    // The gate only affects the output; VIA internals never stop.
    output logic        pb7,
    output logic        audio,

    // virtual tape deck (image on the framework's S1 slot)
    input  logic        tape_play,     // one-clk pulse: start playback
    input  logic        tape_mounted,  // img_mounted pulse for slot 1
    input  logic        tape_readonly,
    input  logic [63:0] tape_size,
    output logic        tape_playing,
    output logic        tape_recording,
    output logic [31:0] sd1_lba,
    output logic        sd1_rd,
    output logic        sd1_wr,
    input  logic        sd1_ack,
    output logic [7:0]  sd1_buff_din,
    input  logic [7:0]  sd_buff_dout,
    input  logic        sd_buff_wr,

    // video
    output logic        vid_pixel,
    output logic        vid_de,
    output logic        vid_hs,
    output logic        vid_vs,
    output logic [8:0]  vid_hcnt,
    output logic [8:0]  vid_vcnt,

    // clock enables (CE_PIXEL for the MiSTer video pipeline)
    output logic        cen_pix_out,

    // debug/trace (same set as jr100_core)
    output logic        cen_cpu_out,
    output logic        boundary,
    output logic [15:0] dbg_pc,
    output logic [15:0] dbg_sp,
    output logic [15:0] dbg_ix,
    output logic [7:0]  dbg_a,
    output logic [7:0]  dbg_b,
    output logic [7:0]  dbg_cc,
    output logic [7:0]  dbg_ora,
    output logic [7:0]  dbg_orb,
    output logic [7:0]  dbg_ddra,
    output logic [7:0]  dbg_ddrb,
    output logic [7:0]  dbg_acr,
    output logic [7:0]  dbg_pcr,
    output logic [7:0]  dbg_ifr,
    output logic [7:0]  dbg_ier,
    output logic [7:0]  dbg_sr,
    output logic [15:0] dbg_t1,
    output logic [15:0] dbg_t1l,
    output logic [15:0] dbg_t2,
    output logic [15:0] dbg_t2l
);

    // ------------------------------------------------------------------
    // Clock enables
    // ------------------------------------------------------------------
    logic [5:0] cen_cnt;
    logic cen_cpu, cen_pix;
    always_ff @(posedge clk) begin
        if (rst) cen_cnt <= '0;
        else     cen_cnt <= cen_cnt + 6'd1;
    end
    logic prg_busy, bas_busy, sav_busy;
    assign cen_cpu = (cen_cnt == 6'd63) && !cpu_hold && !prg_busy && !bas_busy &&
                     !sav_busy;

    // Output band limiting (AGENTS.md §3.4): the square wave frequency is
    // 894886.25/(latch1+2)/2 Hz. Against a 48 kHz PCM output (24 kHz
    // Nyquist) it aliases when latch1+2 <= 18, so mute below latch1=17.
    // The tone source is the VIA snd flop (toggled on every Timer 1
    // reload), matching the reference sound-line model: gated by
    // ACR[7:6]=11 it sounds even when ACR is written after T1 already
    // timed out in one-shot mode (BASIC POKE order), where PB7 itself
    // never toggles.
    logic snd;
    assign audio = snd && (dbg_acr[7:6] == 2'b11) && (dbg_t1l >= 16'd17);
    assign cen_pix = (cen_cnt[2:0] == 3'd7);
    assign cen_cpu_out = cen_cpu;
    assign cen_pix_out = cen_pix;

    logic core_rst;
    assign core_rst = rst | downloading;

    // Extended RAM presence is a physical-board property: latch the OSD
    // setting at reset so it does not appear or vanish mid-run.
    logic ext_ram_eff;
    always_ff @(posedge clk) if (rst) ext_ram_eff <= ext_ram_en;

    // ------------------------------------------------------------------
    // Core + memories
    // ------------------------------------------------------------------
    logic [15:0] ext_addr;
    logic [7:0]  ext_wdata;
    logic        ext_we;
    logic [7:0]  ext_rdata;
    logic [15:0] vid_addr;
    logic [7:0]  vid_rdata;

    jr100_core core
    (
        .clk        (clk),
        .rst        (core_rst),
        .cen        (cen_cpu),
        .vector_reset (1'b1),
        .init_pc    (16'h0000),
        .init_sp    (16'h0000),
        .init_ix    (16'h0000),
        .init_a     (8'h00),
        .init_b     (8'h00),
        .init_cc    (8'hD0),
        .ext_addr   (ext_addr),
        .ext_wdata  (ext_wdata),
        .ext_we     (ext_we),
        .ext_rdata  (ext_rdata),
        .key_matrix (key_matrix | at_overlay),
        .ext_ram_en (ext_ram_eff),
        .pb7        (pb7),
        .snd        (snd),
        .cmt_in     (deck_out),
        .cmt_out    (deck_in),
        .cen_vid    (cen_pix),
        .vid_addr   (vid_addr),
        .vid_rdata  (vid_rdata),
        .vid_pixel  (vid_pixel),
        .vid_de     (vid_de),
        .vid_hs     (vid_hs),
        .vid_vs     (vid_vs),
        .vid_hcnt   (vid_hcnt),
        .vid_vcnt   (vid_vcnt),
        .boundary   (boundary),
        .dbg_pc     (dbg_pc),
        .dbg_sp     (dbg_sp),
        .dbg_ix     (dbg_ix),
        .dbg_a      (dbg_a),
        .dbg_b      (dbg_b),
        .dbg_cc     (dbg_cc),
        .dbg_ora    (dbg_ora),
        .dbg_orb    (dbg_orb),
        .dbg_ddra   (dbg_ddra),
        .dbg_ddrb   (dbg_ddrb),
        .dbg_acr    (dbg_acr),
        .dbg_pcr    (dbg_pcr),
        .dbg_ifr    (dbg_ifr),
        .dbg_ier    (dbg_ier),
        .dbg_sr     (dbg_sr),
        .dbg_t1     (dbg_t1),
        .dbg_t1l    (dbg_t1l),
        .dbg_t2     (dbg_t2),
        .dbg_t2l    (dbg_t2l)
    );

    // PROG loader shares the CPU memory port (CPU frozen meanwhile),
    // so its writes see the same writable-region decode as the CPU.
    logic        prg_mem_we;
    logic [15:0] prg_mem_addr;
    logic [7:0]  prg_mem_data;

    logic        prg_has_bas, prg_usr_valid;
    logic [15:0] prg_usr_addr;

    jr100_loader prg_loader
    (
        .clk      (clk),
        .rst      (rst),
        .download (prg_download),
        .wr       (prg_wr),
        .data     (prg_data),
        .wait_req (prg_wait),
        .busy     (prg_busy),
        .mem_we   (prg_mem_we),
        .mem_addr (prg_mem_addr),
        .mem_data (prg_mem_data),
        .has_bas  (prg_has_bas),
        .usr_valid (prg_usr_valid),
        .usr_addr (prg_usr_addr)
    );

    // ------------------------------------------------------------------
    // Autostart: when enabled, type RUN (BASIC area loaded) or
    // A=USR($hhhh) (v2 comment "USR=$hhhh") once a load completes
    // ------------------------------------------------------------------
    // the load-done edge is detected one stage delayed so the loader's
    // end-of-stream usr_valid latch (same clock as the busy fall) has
    // settled before the mode is sampled
    logic        prg_busy_d, prg_busy_dd, bas_busy_d, bas_busy_dd;
    logic        at_start, at_usr;
    logic [15:0] at_addr;
    logic [44:0] at_overlay;

    always_ff @(posedge clk) begin
        prg_busy_d  <= prg_busy;
        prg_busy_dd <= prg_busy_d;
        bas_busy_d  <= bas_busy;
        bas_busy_dd <= bas_busy_d;
        at_start    <= 1'b0;
        if (autostart_en) begin
            if (prg_busy_dd && !prg_busy_d && (prg_usr_valid || prg_has_bas)) begin
                at_start <= 1'b1;
                at_usr   <= prg_usr_valid;
                at_addr  <= prg_usr_addr;
            end else if (bas_busy_dd && !bas_busy_d) begin
                at_start <= 1'b1;
                at_usr   <= 1'b0;
            end
        end
    end

    jr100_autotype autotype
    (
        .clk         (clk),
        .rst         (rst),
        .cen         (cen_cpu),
        .start       (at_start),
        .mode_usr    (at_usr),
        .usr_addr    (at_addr),
        .key_overlay (at_overlay),
        .busy        ()
    );

    logic        bas_mem_we;
    logic [15:0] bas_mem_addr;
    logic [7:0]  bas_mem_data;

    jr100_bas_loader bas_loader
    (
        .clk      (clk),
        .rst      (rst),
        .download (bas_download),
        .wr       (bas_wr),
        .data     (bas_data),
        .wait_req (bas_wait),
        .busy     (bas_busy),
        .mem_we   (bas_mem_we),
        .mem_addr (bas_mem_addr),
        .mem_data (bas_mem_data)
    );

    // ------------------------------------------------------------------
    // Virtual tape deck + image bridge (S1 slot)
    // ------------------------------------------------------------------
    logic deck_out /* verilator public_flat_rd */;
    logic deck_in /* verilator public_flat_rd */;
    logic        tape_ok, tape_writable;
    logic        t_rd_req, t_rd_ack, t_wr_req, t_wr_ack;
    logic [31:0] t_rd_pos, t_wr_pos;
    logic [7:0]  t_rd_data, t_wr_data;
    logic        rec_prev, rec_flush;

    jr100_cmt cmt_deck
    (
        .clk         (clk),
        .rst         (rst),
        .cen         (cen_cpu),
        .play_req    (tape_play),
        .tape_ok     (tape_ok),
        .cmt_out     (deck_out),
        .cmt_in      (deck_in),
        .play_active (tape_playing),
        .rec_active  (tape_recording),
        .rd_req      (t_rd_req),
        .rd_pos      (t_rd_pos),
        .rd_data     (t_rd_data),
        .rd_ack      (t_rd_ack),
        .wr_req      (t_wr_req),
        .wr_pos      (t_wr_pos),
        .wr_data     (t_wr_data),
        .wr_ack      (t_wr_ack)
    );

    always_ff @(posedge clk) begin
        rec_prev  <= tape_recording;
        rec_flush <= rec_prev & ~tape_recording;
    end

    jr100_tape_buf tape_buf
    (
        .clk          (clk),
        .rst          (rst),
        .img_mounted  (tape_mounted),
        .img_readonly (tape_readonly),
        .img_size     (tape_size),
        .tape_ok      (tape_ok),
        .tape_writable (tape_writable),
        .rd_req       (t_rd_req),
        .rd_pos       (t_rd_pos),
        .rd_data      (t_rd_data),
        .rd_ack       (t_rd_ack),
        .wr_req       (t_wr_req),
        .wr_pos       (t_wr_pos),
        .wr_data      (t_wr_data),
        .wr_ack       (t_wr_ack),
        .flush        (rec_flush),
        .sd_lba       (sd1_lba),
        .sd_rd        (sd1_rd),
        .sd_wr        (sd1_wr),
        .sd_ack       (sd1_ack),
        .sd_buff_addr (sd_buff_addr),
        .sd_buff_dout (sd_buff_dout),
        .sd_buff_wr   (sd_buff_wr),
        .sd_buff_din  (sd1_buff_din)
    );

    logic [15:0] sav_mem_addr;

    jr100_saver saver
    (
        .clk          (clk),
        .rst          (rst),
        .save_req     (save_req),
        .img_mounted  (img_mounted),
        .img_readonly (img_readonly),
        .img_size     (img_size),
        .busy         (sav_busy),
        .mem_addr     (sav_mem_addr),
        .mem_rdata    (ext_rdata),
        .sd_lba       (sd_lba),
        .sd_wr        (sd_wr),
        .sd_ack       (sd_ack),
        .sd_buff_addr (sd_buff_addr),
        .sd_buff_din  (sd_buff_din)
    );

    jr100_mem mem
    (
        .clk         (clk),
        .rst         (core_rst),
        .cpu_addr    (prg_busy ? prg_mem_addr : bas_busy ? bas_mem_addr :
                      sav_busy ? sav_mem_addr : ext_addr),
        .cpu_wdata   (prg_busy ? prg_mem_data : bas_busy ? bas_mem_data : ext_wdata),
        .cpu_we      (prg_busy ? prg_mem_we : bas_busy ? bas_mem_we :
                      sav_busy ? 1'b0 : ext_we),
        .cpu_rdata   (ext_rdata),
        .vid_addr    (vid_addr),
        .vid_rdata   (vid_rdata),
        .loader_we   (loader_we),
        .loader_addr (loader_addr),
        .loader_data (loader_data),
        .joy_status  (joy_status),
        .ext_ram_en  (ext_ram_eff)
    );

endmodule
