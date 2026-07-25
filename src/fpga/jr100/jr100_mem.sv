//============================================================================
//
//  JR-100 memory subsystem (JR100_MiSTer): on-chip BRAMs + address map.
//
//  Synchronous-read BRAMs behind the CPU/video ports. Both the CPU
//  (system clock / 64) and the video pipeline (system clock / 8) hold
//  their addresses stable for many system-clock cycles, so the one-
//  cycle BRAM latency is invisible at their clock-enable granularity.
//
//  Map (pyjr100emu JR100Computer, extended RAM disabled):
//    0000-3FFF  Main RAM     16 KiB  BRAM (CPU r/w)
//    C000-C0FF  CGRAM        256 B   BRAM (CPU r/w, video r)
//    C100-C3FF  VRAM         768 B   BRAM (CPU r/w, video r)
//    CC00-CFFF  extended I/O         CC02 register, others read 00
//    D000       unmapped quirk       reads AA
//    E000-E3FF  character ROM 1 KiB  BRAM (CPU r, video r, loader w)
//    E400-FFFF  BASIC ROM    7 KiB   BRAM (CPU r, loader w)
//    elsewhere  unmapped             reads 00, writes ignored
//
//  The C800-C80F VIA window is handled inside jr100_core; this module
//  returns don't-care data there and never sees a write (jr100_core
//  masks ext_we).
//
//  Loader port: 8 KiB ROM image stream, offset 0000-03FF -> char ROM,
//  0400-1FFF -> BASIC ROM (AGENTS.md §7: single 8 KiB image split).
//
//  Copyright (C) 2026 Zabaglione
//  SPDX-License-Identifier: GPL-2.0-or-later
//
//============================================================================

module jr100_mem
(
    input  logic        clk,
    input  logic        rst,

    // CPU port (address stable between CPU clock enables)
    input  logic [15:0] cpu_addr,
    input  logic [7:0]  cpu_wdata,
    input  logic        cpu_we,
    output logic [7:0]  cpu_rdata,

    // video read port (address stable between pixel clock enables)
    input  logic [15:0] vid_addr,
    output logic [7:0]  vid_rdata,

    // ROM loader (active while the core is held in reset)
    input  logic        loader_we,
    input  logic [12:0] loader_addr,
    input  logic [7:0]  loader_data,

    // joystick status for CC02 (AGENTS.md §4 bit layout, active high)
    input  logic [7:0]  joy_status,

    // extended RAM 4000-7FFF (AGENTS.md §3.2, OSD-selectable)
    input  logic        ext_ram_en
);

    // vram/basic_rom are padded to powers of two for clean indexing
    // (the decode gates keep accesses inside the architectural ranges)
    logic [7:0] main_ram [0:16383] /* verilator public_flat_rd */;
    logic [7:0] ext_ram  [0:16383] /* verilator public_flat_rd */;
    logic [7:0] cgram    [0:255] /* verilator public_flat_rd */;
    logic [7:0] vram     [0:1023] /* verilator public_flat_rd */;
    logic [7:0] char_rom [0:1023] /* verilator public_flat_rd */;
    logic [7:0] basic_rom[0:8191] /* verilator public_flat_rd */;

    // ------------------------------------------------------------------
    // CPU port decode
    // ------------------------------------------------------------------
    logic sel_ram, sel_xram, sel_cgram, sel_vram, sel_cc02, sel_d000;
    logic sel_crom, sel_brom;
    assign sel_ram   = (cpu_addr < 16'h4000);
    assign sel_xram  = ext_ram_en && (cpu_addr[15:14] == 2'b01);   // 4000-7FFF
    assign sel_cgram = (cpu_addr[15:8] == 8'hC0);
    assign sel_vram  = (cpu_addr >= 16'hC100 && cpu_addr <= 16'hC3FF);
    assign sel_cc02  = (cpu_addr == 16'hCC02);
    assign sel_d000  = (cpu_addr == 16'hD000);
    assign sel_crom  = (cpu_addr[15:10] == 6'b111000);          // E000-E3FF
    assign sel_brom  = (cpu_addr >= 16'hE400);

    logic [7:0] q_ram, q_xram, q_cgram, q_vram, q_crom, q_brom;
    logic r_ram, r_xram, r_cgram, r_vram, r_cc02, r_d000, r_crom, r_brom;
    logic [7:0] cc02_reg;
    logic [7:0] joy_prev;

    always_ff @(posedge clk) begin
        // Main RAM
        if (cpu_we && sel_ram) main_ram[cpu_addr[13:0]] <= cpu_wdata;
        q_ram <= main_ram[cpu_addr[13:0]];

        // extended RAM (writes ignored while disabled, as unmapped)
        if (cpu_we && sel_xram) ext_ram[cpu_addr[13:0]] <= cpu_wdata;
        q_xram <= ext_ram[cpu_addr[13:0]];

        // CGRAM
        if (cpu_we && sel_cgram) cgram[cpu_addr[7:0]] <= cpu_wdata;
        q_cgram <= cgram[cpu_addr[7:0]];

        // VRAM
        if (cpu_we && sel_vram) vram[10'(cpu_addr - 16'hC100)] <= cpu_wdata;
        q_vram <= vram[10'(cpu_addr - 16'hC100)];

        // ROMs (loader writes, CPU reads)
        if (loader_we && !loader_addr[12] && !loader_addr[11] && !loader_addr[10])
            char_rom[loader_addr[9:0]] <= loader_data;
        if (loader_we && (loader_addr >= 13'h0400))
            basic_rom[13'(loader_addr - 13'h0400)] <= loader_data;
        q_crom <= char_rom[cpu_addr[9:0]];
        q_brom <= basic_rom[13'(cpu_addr - 16'hE400)];

        // extended I/O register: tracks the host joystick and stays
        // CPU-writable until the next host change (ExtendedIOPort
        // semantics: set_gamepad_state overwrites, store8 overwrites)
        joy_prev <= joy_status;
        if (rst) cc02_reg <= joy_status;   // host state persists over reset
        else if (cpu_we && sel_cc02) cc02_reg <= cpu_wdata;
        else if (joy_status != joy_prev) cc02_reg <= joy_status;

        // registered region select, aligned with BRAM read latency
        r_ram   <= sel_ram;
        r_xram  <= sel_xram;
        r_cgram <= sel_cgram;
        r_vram  <= sel_vram;
        r_cc02  <= sel_cc02;
        r_d000  <= sel_d000;
        r_crom  <= sel_crom;
        r_brom  <= sel_brom;
    end

    always_comb begin
        if (r_ram)        cpu_rdata = q_ram;
        else if (r_xram)  cpu_rdata = q_xram;
        else if (r_cgram) cpu_rdata = q_cgram;
        else if (r_vram)  cpu_rdata = q_vram;
        else if (r_cc02)  cpu_rdata = cc02_reg;
        else if (r_d000)  cpu_rdata = 8'hAA;
        else if (r_crom)  cpu_rdata = q_crom;
        else if (r_brom)  cpu_rdata = q_brom;
        else              cpu_rdata = 8'h00;    // unmapped
    end

    // ------------------------------------------------------------------
    // Video read port (CGRAM / VRAM / char ROM only)
    // ------------------------------------------------------------------
    logic [7:0] vq_cgram, vq_vram, vq_crom;
    logic vr_cgram, vr_vram;

    always_ff @(posedge clk) begin
        vq_cgram <= cgram[vid_addr[7:0]];
        vq_vram  <= vram[10'(vid_addr - 16'hC100)];
        vq_crom  <= char_rom[vid_addr[9:0]];
        vr_cgram <= (vid_addr[15:8] == 8'hC0);
        vr_vram  <= (vid_addr >= 16'hC100 && vid_addr <= 16'hC3FF);
    end

    always_comb begin
        if (vr_cgram)     vid_rdata = vq_cgram;
        else if (vr_vram) vid_rdata = vq_vram;
        else              vid_rdata = vq_crom;
    end

endmodule
