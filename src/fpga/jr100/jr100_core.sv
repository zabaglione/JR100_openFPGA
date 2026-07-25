//============================================================================
//
//  JR-100 system integration: MB8861 CPU + R6522 VIA + address decode.
//
//  Memory map (pyjr100emu JR100Computer, extended RAM disabled):
//    0000-3FFF  Main RAM                (external, read/write)
//    4000-BFFF  unmapped                (external image: reads 00, writes masked)
//    C000-C0FF  CGRAM                   (external, read/write)
//    C100-C3FF  VRAM                    (external, read/write)
//    C800-C80F  R6522 VIA               (internal)
//    CC00-CFFF  extended I/O            (external; only CC02 writable,
//                                        mirrors ExtendedIOPort semantics)
//    D000       unmapped quirk          (image holds 0xAA)
//    E000-FFFF  BASIC ROM (+font)       (external, writes masked)
//
//  For Phase D simulation, RAM/ROM live in the harness as the 64 KiB
//  image exported by pyjr100emu (--save-initial-memory), which already
//  encodes the unmapped-read values. The MiSTer build replaces the
//  external bus with BRAMs and HPS loading (Phase E).
//
//  Copyright (C) 2026 Zabaglione
//  SPDX-License-Identifier: GPL-2.0-or-later
//
//============================================================================

module jr100_core
(
    input  logic        clk,
    input  logic        rst,
    input  logic        cen,

    // reset mode and initial CPU state injection (see mb8861.sv)
    input  logic        vector_reset,
    input  logic [15:0] init_pc,
    input  logic [15:0] init_sp,
    input  logic [15:0] init_ix,
    input  logic [7:0]  init_a,
    input  logic [7:0]  init_b,
    input  logic [7:0]  init_cc,

    // external memory image (harness / BRAM)
    output logic [15:0] ext_addr,
    output logic [7:0]  ext_wdata,
    output logic        ext_we,      // already masked to writable regions
    input  logic [7:0]  ext_rdata,

    // JR-100 inputs
    input  logic [44:0] key_matrix,  // 9 rows x 5 bits, 1 = pressed
    input  logic        ext_ram_en,  // extended RAM 4000-7FFF present

    // audio source
    output logic        pb7,
    output logic        snd,

    // cassette line (input feeds VIA CA1+CB1, output is VIA CB2)
    input  logic        cmt_in,
    output logic        cmt_out,

    // video (second read port into the shared address space)
    input  logic        cen_vid,
    output logic [15:0] vid_addr,
    input  logic [7:0]  vid_rdata,
    output logic        vid_pixel,
    output logic        vid_de,
    output logic        vid_hs,
    output logic        vid_vs,
    output logic [8:0]  vid_hcnt,
    output logic [8:0]  vid_vcnt,

    // trace/debug
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

    logic [15:0] bus_addr;
    logic [7:0]  bus_wdata;
    logic        bus_we;
    logic [7:0]  bus_rdata;
    logic        via_irq;
    logic [7:0]  via_rdata;
    logic        via_font_user;

    logic via_sel;
    assign via_sel = (bus_addr[15:4] == 12'hC80);

    // Writable regions (everything else silently ignores writes,
    // mirroring UnmappedMemory / ROM / ExtendedIOPort semantics)
    logic ext_writable;
    assign ext_writable =
        (bus_addr < 16'h4000) ||
        (ext_ram_en && bus_addr[15:14] == 2'b01) ||
        (bus_addr >= 16'hC000 && bus_addr <= 16'hC3FF) ||
        (bus_addr == 16'hCC02);

    assign ext_addr  = bus_addr;
    assign ext_wdata = bus_wdata;
    assign ext_we    = bus_we & ~via_sel & ext_writable;

    assign bus_rdata = via_sel ? via_rdata : ext_rdata;

    mb8861 cpu
    (
        .clk       (clk),
        .rst       (rst),
        .cen       (cen),
        .vector_reset (vector_reset),
        .init_pc   (init_pc),
        .init_sp   (init_sp),
        .init_ix   (init_ix),
        .init_a    (init_a),
        .init_b    (init_b),
        .init_cc   (init_cc),
        .nmi_set   (1'b0),
        .irq_level (via_irq),
        .bus_addr  (bus_addr),
        .bus_wdata (bus_wdata),
        .bus_we    (bus_we),
        .bus_rdata (bus_rdata),
        .boundary  (boundary),
        .dbg_pc    (dbg_pc),
        .dbg_sp    (dbg_sp),
        .dbg_ix    (dbg_ix),
        .dbg_a     (dbg_a),
        .dbg_b     (dbg_b),
        .dbg_cc    (dbg_cc)
    );

    jr100_via via
    (
        .clk        (clk),
        .rst        (rst),
        .cen        (cen),
        .sel        (via_sel),
        .reg_addr   (bus_addr[3:0]),
        .we         (bus_we),
        .wdata      (bus_wdata),
        .rdata      (via_rdata),
        .key_matrix (key_matrix),
        .irq        (via_irq),
        .pb7_out    (pb7),
        .snd_out    (snd),
        .ca1_in     (cmt_in),
        .cb1_in     (cmt_in),
        .cb2        (cmt_out),
        .font_user  (via_font_user),
        .dbg_pb6    (),
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

    jr100_video video
    (
        .clk       (clk),
        .rst       (rst),
        .cen_pix   (cen_vid),
        .font_user (via_font_user),
        .vid_addr  (vid_addr),
        .vid_rdata (vid_rdata),
        .pixel     (vid_pixel),
        .de        (vid_de),
        .hs        (vid_hs),
        .vs        (vid_vs),
        .hcnt      (vid_hcnt),
        .vcnt      (vid_vcnt)
    );

endmodule
