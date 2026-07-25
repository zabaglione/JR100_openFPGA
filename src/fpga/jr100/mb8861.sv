//============================================================================
//
//  MB8861 (MC6800-compatible + JR-100 extension opcodes) CPU core
//  for the JR100_MiSTer project.
//
//  Compatibility baseline is the pyjr100emu reference implementation
//  (AGENTS.md §1): instruction results, flags and per-instruction cycle
//  counts mirror src/jr100emu/cpu/cpu.py (as of pyjr100emu 9b11a18:
//  level-sensitive IRQ, I-flag set on interrupt entry, WAI stacks
//  registers at execution and exits via a 4-cycle vector fetch).
//  SWI return address, ADC half-carry and STS flags follow M68PRM(D)
//  (fixed together with pyjr100emu 9c5245e). NIM/OIM/XIM flag rules are
//  MB8861-specific and correct as implemented; the TMM mask-bit flag
//  condition remains tracked in docs/DEVELOPMENT.md and must not be
//  "fixed" here without updating the reference first (AGENTS.md §7).
//
//  Timing model: one instruction consumes exactly the table cycle count
//  (docs/generated/opcode_cycles.txt). Bus reads return combinationally
//  within the CPU cycle; in the MiSTer core the CPU runs on a clock
//  enable (~894.886 kHz) over a fast system clock, which gives BRAM
//  ample time to behave combinationally at CPU-cycle granularity.
//  Bus-cycle waveforms are NOT modelled (AGENTS.md §5.2 does not
//  require them); comparison happens at instruction boundaries.
//
//  Copyright (C) 2026 Zabaglione
//
//  This program is free software; you can redistribute it and/or modify it
//  under the terms of the GNU General Public License as published by the Free
//  Software Foundation; either version 2 of the License, or (at your option)
//  any later version.
//
//============================================================================

module mb8861
(
    input  logic        clk,
    input  logic        rst,        // synchronous, active high
    input  logic        cen,        // clock enable (1 CPU cycle per cen pulse)

    // Reset behaviour: with vector_reset=1 the CPU performs the real
    // MC6800 RESET sequence after rst deasserts (fetch PC from
    // FFFE/FFFF, set the I flag; other registers take the init_*
    // values). With vector_reset=0 the full initial state is injected
    // from init_* (lockstep harness mode).
    input  logic        vector_reset,
    input  logic [15:0] init_pc,
    input  logic [15:0] init_sp,
    input  logic [15:0] init_ix,
    input  logic [7:0]  init_a,
    input  logic [7:0]  init_b,
    input  logic [7:0]  init_cc,

    // Interrupts: NMI is edge-style (a pulse latches a pending request,
    // cleared on service); IRQ is a level-sensitive input owned by the
    // external device (pyjr100emu set_irq_line semantics).
    input  logic        nmi_set,
    input  logic        irq_level,

    // Memory bus: combinational read, registered write strobe.
    output logic [15:0] bus_addr,
    output logic [7:0]  bus_wdata,
    output logic        bus_we,
    input  logic [7:0]  bus_rdata,

    // Instruction-boundary marker for the trace harness: high while the
    // CPU is in a fetch (or WAI wait) cycle, i.e. the previous
    // instruction has fully completed.
    output logic        boundary,

    // Architectural state (trace/debug).
    output logic [15:0] dbg_pc,
    output logic [15:0] dbg_sp,
    output logic [15:0] dbg_ix,
    output logic [7:0]  dbg_a,
    output logic [7:0]  dbg_b,
    output logic [7:0]  dbg_cc
);

    // ------------------------------------------------------------------
    // Architectural registers
    // ------------------------------------------------------------------
    logic [15:0] pc, sp, ix;
    logic [7:0]  a, b;
    logic        fh, fi, fn, fz, fv, fc;

    logic        wai_mode;
    logic        nmi_pend;

    // ------------------------------------------------------------------
    // Sequencer state
    // ------------------------------------------------------------------
    typedef enum logic [4:0] {
        ST_RST_VH,     // real reset: vector high byte from FFFE
        ST_RST_VL,     // real reset: vector low byte from FFFF
        ST_FETCH,
        ST_OP1,
        ST_OP2,
        ST_LD1,
        ST_LD2,
        ST_EXEC,
        ST_WR1,
        ST_WR2,
        ST_PUSH_L,
        ST_PUSH_H,
        ST_RDS,       // PULA/PULB stack read
        ST_WRS,       // PSHA/PSHB stack write
        ST_STK_RD,    // RTI 7-byte pop
        ST_STK_WR,    // SWI / interrupt entry 7-byte push
        ST_VEC_H,
        ST_VEC_L,
        ST_PAD,
        ST_WAI_WAIT
    } state_t;

    state_t      state;
    logic [7:0]  ir;          // current opcode
    logic [3:0]  ucnt;        // cycles consumed in current instruction
    logic [3:0]  cyc_total;   // target cycle count for current instruction
    logic [7:0]  tmp;         // first operand byte (imm/hi/dir/NIM value)
    logic [7:0]  mdr;         // load data high byte / RMW result
    logic [15:0] ea;          // effective address
    logic [2:0]  stk;         // stack sequence index
    logic        in_int;      // executing NMI/IRQ entry (not SWI)
    logic        int_is_nmi;

    // ------------------------------------------------------------------
    // Cycle table (docs/generated/opcode_cycles.txt — pyjr100emu baseline)
    // Returns 0 for undefined opcodes (executed as a 1-cycle NOP).
    // ------------------------------------------------------------------
    function automatic logic [3:0] cycles_of(input logic [7:0] op);
        case (op)
            8'h01: cycles_of = 2;  8'h06: cycles_of = 2;  8'h07: cycles_of = 2;
            8'h08: cycles_of = 4;  8'h09: cycles_of = 4;  8'h0A: cycles_of = 2;
            8'h0B: cycles_of = 2;  8'h0C: cycles_of = 2;  8'h0D: cycles_of = 2;
            8'h0E: cycles_of = 2;  8'h0F: cycles_of = 2;  8'h10: cycles_of = 2;
            8'h11: cycles_of = 2;  8'h16: cycles_of = 2;  8'h17: cycles_of = 2;
            8'h19: cycles_of = 2;  8'h1B: cycles_of = 2;
            8'h20: cycles_of = 4;  8'h22: cycles_of = 4;  8'h23: cycles_of = 4;
            8'h24: cycles_of = 4;  8'h25: cycles_of = 4;  8'h26: cycles_of = 4;
            8'h27: cycles_of = 4;  8'h28: cycles_of = 4;  8'h29: cycles_of = 4;
            8'h2A: cycles_of = 4;  8'h2B: cycles_of = 4;  8'h2C: cycles_of = 4;
            8'h2D: cycles_of = 4;  8'h2E: cycles_of = 4;  8'h2F: cycles_of = 4;
            8'h30: cycles_of = 4;  8'h31: cycles_of = 4;  8'h32: cycles_of = 4;
            8'h33: cycles_of = 4;  8'h34: cycles_of = 4;  8'h35: cycles_of = 4;
            8'h36: cycles_of = 4;  8'h37: cycles_of = 4;
            8'h39: cycles_of = 5;  8'h3B: cycles_of = 10;
            8'h3E: cycles_of = 9;  8'h3F: cycles_of = 12;
            8'h40: cycles_of = 2;  8'h43: cycles_of = 2;  8'h44: cycles_of = 2;
            8'h46: cycles_of = 2;  8'h47: cycles_of = 2;  8'h48: cycles_of = 2;
            8'h49: cycles_of = 2;  8'h4A: cycles_of = 2;  8'h4C: cycles_of = 2;
            8'h4D: cycles_of = 2;  8'h4F: cycles_of = 2;
            8'h50: cycles_of = 2;  8'h53: cycles_of = 2;  8'h54: cycles_of = 2;
            8'h56: cycles_of = 2;  8'h57: cycles_of = 2;  8'h58: cycles_of = 2;
            8'h59: cycles_of = 2;  8'h5A: cycles_of = 2;  8'h5C: cycles_of = 2;
            8'h5D: cycles_of = 2;  8'h5F: cycles_of = 2;
            8'h60: cycles_of = 7;  8'h63: cycles_of = 7;  8'h64: cycles_of = 7;
            8'h66: cycles_of = 7;  8'h67: cycles_of = 7;  8'h68: cycles_of = 7;
            8'h69: cycles_of = 7;  8'h6A: cycles_of = 7;  8'h6C: cycles_of = 7;
            8'h6D: cycles_of = 7;  8'h6E: cycles_of = 4;  8'h6F: cycles_of = 7;
            8'h70: cycles_of = 6;  8'h71: cycles_of = 8;  8'h72: cycles_of = 8;
            8'h73: cycles_of = 6;  8'h74: cycles_of = 6;  8'h75: cycles_of = 8;
            8'h76: cycles_of = 6;  8'h77: cycles_of = 6;  8'h78: cycles_of = 6;
            8'h79: cycles_of = 6;  8'h7A: cycles_of = 6;  8'h7B: cycles_of = 7;
            8'h7C: cycles_of = 6;  8'h7D: cycles_of = 6;  8'h7E: cycles_of = 3;
            8'h7F: cycles_of = 6;
            8'h80: cycles_of = 2;  8'h81: cycles_of = 2;  8'h82: cycles_of = 2;
            8'h84: cycles_of = 2;  8'h85: cycles_of = 2;  8'h86: cycles_of = 2;
            8'h88: cycles_of = 2;  8'h89: cycles_of = 2;  8'h8A: cycles_of = 2;
            8'h8B: cycles_of = 2;  8'h8C: cycles_of = 3;  8'h8D: cycles_of = 8;
            8'h8E: cycles_of = 3;
            8'h90: cycles_of = 3;  8'h91: cycles_of = 3;  8'h92: cycles_of = 3;
            8'h94: cycles_of = 3;  8'h95: cycles_of = 3;  8'h96: cycles_of = 3;
            8'h97: cycles_of = 4;  8'h98: cycles_of = 3;  8'h99: cycles_of = 3;
            8'h9A: cycles_of = 3;  8'h9B: cycles_of = 3;  8'h9C: cycles_of = 4;
            8'h9E: cycles_of = 4;  8'h9F: cycles_of = 5;
            8'hA0: cycles_of = 5;  8'hA1: cycles_of = 5;  8'hA2: cycles_of = 5;
            8'hA4: cycles_of = 5;  8'hA5: cycles_of = 5;  8'hA6: cycles_of = 5;
            8'hA7: cycles_of = 6;  8'hA8: cycles_of = 5;  8'hA9: cycles_of = 5;
            8'hAA: cycles_of = 5;  8'hAB: cycles_of = 5;  8'hAC: cycles_of = 6;
            8'hAD: cycles_of = 8;  8'hAE: cycles_of = 6;  8'hAF: cycles_of = 7;
            8'hB0: cycles_of = 4;  8'hB1: cycles_of = 4;  8'hB2: cycles_of = 4;
            8'hB4: cycles_of = 4;  8'hB5: cycles_of = 4;  8'hB6: cycles_of = 4;
            8'hB7: cycles_of = 5;  8'hB8: cycles_of = 4;  8'hB9: cycles_of = 4;
            8'hBA: cycles_of = 4;  8'hBB: cycles_of = 4;  8'hBC: cycles_of = 5;
            8'hBD: cycles_of = 9;  8'hBE: cycles_of = 5;  8'hBF: cycles_of = 6;
            8'hC0: cycles_of = 2;  8'hC1: cycles_of = 2;  8'hC2: cycles_of = 2;
            8'hC4: cycles_of = 2;  8'hC5: cycles_of = 2;  8'hC6: cycles_of = 2;
            8'hC8: cycles_of = 2;  8'hC9: cycles_of = 2;  8'hCA: cycles_of = 2;
            8'hCB: cycles_of = 2;  8'hCE: cycles_of = 3;
            8'hD0: cycles_of = 3;  8'hD1: cycles_of = 3;  8'hD2: cycles_of = 3;
            8'hD4: cycles_of = 3;  8'hD5: cycles_of = 3;  8'hD6: cycles_of = 3;
            8'hD7: cycles_of = 4;  8'hD8: cycles_of = 3;  8'hD9: cycles_of = 3;
            8'hDA: cycles_of = 3;  8'hDB: cycles_of = 3;  8'hDE: cycles_of = 4;
            8'hDF: cycles_of = 5;
            8'hE0: cycles_of = 5;  8'hE1: cycles_of = 5;  8'hE2: cycles_of = 5;
            8'hE4: cycles_of = 5;  8'hE5: cycles_of = 5;  8'hE6: cycles_of = 5;
            8'hE7: cycles_of = 6;  8'hE8: cycles_of = 5;  8'hE9: cycles_of = 5;
            8'hEA: cycles_of = 5;  8'hEB: cycles_of = 5;  8'hEC: cycles_of = 4;
            8'hEE: cycles_of = 6;  8'hEF: cycles_of = 7;
            8'hF0: cycles_of = 4;  8'hF1: cycles_of = 4;  8'hF2: cycles_of = 4;
            8'hF4: cycles_of = 4;  8'hF5: cycles_of = 4;  8'hF6: cycles_of = 4;
            8'hF7: cycles_of = 5;  8'hF8: cycles_of = 4;  8'hF9: cycles_of = 4;
            8'hFA: cycles_of = 4;  8'hFB: cycles_of = 4;  8'hFC: cycles_of = 7;
            8'hFE: cycles_of = 5;  8'hFF: cycles_of = 6;
            default: cycles_of = 0;   // undefined -> 1-cycle NOP
        endcase
    endfunction

    // ------------------------------------------------------------------
    // Sign helpers matching Python's strict "> 0" semantics
    // (zero is neither positive nor negative).
    // ------------------------------------------------------------------
    function automatic logic pos8(input logic [7:0] v);
        pos8 = ~v[7] & (v != 8'h00);
    endfunction
    function automatic logic neg8(input logic [7:0] v);
        neg8 = v[7];
    endfunction
    function automatic logic pos16(input logic [15:0] v);
        pos16 = ~v[15] & (v != 16'h0000);
    endfunction
    function automatic logic neg16(input logic [15:0] v);
        neg16 = v[15];
    endfunction

    // ------------------------------------------------------------------
    // Two-operand 8-bit ALU group (opcodes x0..xB of rows 8x..Fx).
    // sel = ir[3:0]; returns result and flag updates.
    // ------------------------------------------------------------------
    typedef struct packed {
        logic [7:0] res;
        logic res_we;
        logic h, h_we;
        logic n, z, v;
        logic c, c_we;
    } alu2_t;

    function automatic alu2_t alu2(input logic [3:0] sel,
                                   input logic [7:0] x,
                                   input logic [7:0] y,
                                   input logic       cin);
        logic [8:0] sum;
        alu2_t r;
        r = '0;
        case (sel)
            4'h0, 4'h1: begin // SUB / CMP
                sum = {1'b0, x} - {1'b0, y};
                r.res = sum[7:0];
                r.res_we = (sel == 4'h0);
                r.n = sum[7]; r.z = (sum[7:0] == 0);
                r.v = (pos8(x) & neg8(y) & sum[7]) | (neg8(x) & pos8(y) & ~sum[7]);
                r.c = sum[8]; r.c_we = 1'b1;
            end
            4'h2: begin // SBC
                sum = {1'b0, x} - {1'b0, y} - {8'b0, cin};
                r.res = sum[7:0]; r.res_we = 1'b1;
                r.n = sum[7]; r.z = (sum[7:0] == 0);
                r.v = (pos8(x) & neg8(y) & sum[7]) | (neg8(x) & pos8(y) & ~sum[7]);
                r.c = sum[8]; r.c_we = 1'b1;
            end
            4'h4, 4'h5: begin // AND / BIT
                r.res = x & y;
                r.res_we = (sel == 4'h4);
                r.n = r.res[7]; r.z = (r.res == 0); r.v = 1'b0;
            end
            4'h6: begin // LDA
                r.res = y; r.res_we = 1'b1;
                r.n = y[7]; r.z = (y == 0); r.v = 1'b0;
            end
            4'h8: begin // EOR
                r.res = x ^ y; r.res_we = 1'b1;
                r.n = r.res[7]; r.z = (r.res == 0); r.v = 1'b0;
            end
            4'h9: begin // ADC (H includes carry-in: M68PRM H = f(X + M + C))
                sum = {1'b0, x} + {1'b0, y} + {8'b0, cin};
                r.res = sum[7:0]; r.res_we = 1'b1;
                r.h = (({1'b0, x[3:0]} + {1'b0, y[3:0]} + {4'b0, cin}) > 5'h0F);
                r.h_we = 1'b1;
                r.n = sum[7]; r.z = (sum[7:0] == 0);
                r.v = (pos8(x) & pos8(y) & sum[7]) | (neg8(x) & neg8(y) & ~sum[7]);
                r.c = sum[8]; r.c_we = 1'b1;
            end
            4'hA: begin // ORA
                r.res = x | y; r.res_we = 1'b1;
                r.n = r.res[7]; r.z = (r.res == 0); r.v = 1'b0;
            end
            4'hB: begin // ADD
                sum = {1'b0, x} + {1'b0, y};
                r.res = sum[7:0]; r.res_we = 1'b1;
                r.h = (({1'b0, x[3:0]} + {1'b0, y[3:0]}) > 5'h0F); r.h_we = 1'b1;
                r.n = sum[7]; r.z = (sum[7:0] == 0);
                r.v = (pos8(x) & pos8(y) & sum[7]) | (neg8(x) & neg8(y) & ~sum[7]);
                r.c = sum[8]; r.c_we = 1'b1;
            end
            default: ;
        endcase
        return r;
    endfunction

    // ------------------------------------------------------------------
    // Single-operand 8-bit ALU (rows 4x/5x implied, 6x/7x memory RMW).
    // sel = ir[3:0].
    // ------------------------------------------------------------------
    typedef struct packed {
        logic [7:0] res;
        logic wr_mem;      // RMW writes back (TST/TMM do not)
        logic n, z, v;
        logic c, c_we;
    } alu1_t;

    function automatic alu1_t alu1(input logic [3:0] sel,
                                   input logic [7:0] x,
                                   input logic       cin);
        alu1_t r;
        r = '0;
        r.wr_mem = 1'b1;
        case (sel)
            4'h0: begin // NEG
                r.res = (~x) + 8'h01;
                r.n = r.res[7]; r.z = (r.res == 0);
                r.v = (r.res == 8'h80);
                r.c = (x != 8'h00); r.c_we = 1'b1;
            end
            4'h3: begin // COM
                r.res = ~x;
                r.n = r.res[7]; r.z = (r.res == 0); r.v = 1'b0;
                r.c = 1'b1; r.c_we = 1'b1;
            end
            4'h4: begin // LSR
                r.res = {1'b0, x[7:1]};
                r.n = 1'b0; r.z = (r.res == 0);
                r.c = x[0]; r.c_we = 1'b1;
                r.v = r.n ^ r.c;
            end
            4'h6: begin // ROR
                r.res = {cin, x[7:1]};
                r.n = r.res[7]; r.z = (r.res == 0);
                r.c = x[0]; r.c_we = 1'b1;
                r.v = r.n ^ r.c;
            end
            4'h7: begin // ASR
                r.res = {x[7], x[7:1]};
                r.n = r.res[7]; r.z = (r.res == 0);
                r.c = x[0]; r.c_we = 1'b1;
                r.v = r.n ^ r.c;
            end
            4'h8: begin // ASL
                r.res = {x[6:0], 1'b0};
                r.n = r.res[7]; r.z = (r.res == 0);
                r.c = x[7]; r.c_we = 1'b1;
                r.v = r.n ^ r.c;
            end
            4'h9: begin // ROL
                r.res = {x[6:0], cin};
                r.n = r.res[7]; r.z = (r.res == 0);
                r.c = x[7]; r.c_we = 1'b1;
                r.v = r.n ^ r.c;
            end
            4'hA: begin // DEC (C unchanged)
                r.res = x - 8'h01;
                r.n = r.res[7]; r.z = (r.res == 0);
                r.v = (x == 8'h80);
            end
            4'hC: begin // INC (C unchanged)
                r.res = x + 8'h01;
                r.n = r.res[7]; r.z = (r.res == 0);
                r.v = (x == 8'h7F);
            end
            4'hD: begin // TST
                r.res = x; r.wr_mem = 1'b0;
                r.n = x[7]; r.z = (x == 0); r.v = 1'b0;
                r.c = 1'b0; r.c_we = 1'b1;
            end
            4'hF: begin // CLR
                r.res = 8'h00;
                r.n = 1'b0; r.z = 1'b1; r.v = 1'b0;
                r.c = 1'b0; r.c_we = 1'b1;
            end
            default: ;
        endcase
        return r;
    endfunction

    // Branch condition (ir = 0x20..0x2F)
    function automatic logic branch_taken(input logic [3:0] sel);
        case (sel)
            4'h0: branch_taken = 1'b1;                    // BRA
            4'h2: branch_taken = ~(fc | fz);              // BHI
            4'h3: branch_taken = fc | fz;                 // BLS
            4'h4: branch_taken = ~fc;                     // BCC
            4'h5: branch_taken = fc;                      // BCS
            4'h6: branch_taken = ~fz;                     // BNE
            4'h7: branch_taken = fz;                      // BEQ
            4'h8: branch_taken = ~fv;                     // BVC
            4'h9: branch_taken = fv;                      // BVS
            4'hA: branch_taken = ~fn;                     // BPL
            4'hB: branch_taken = fn;                      // BMI
            4'hC: branch_taken = ~(fn ^ fv);              // BGE
            4'hD: branch_taken = fn ^ fv;                 // BLT
            4'hE: branch_taken = ~(fz | (fn ^ fv));       // BGT
            4'hF: branch_taken = fz | (fn ^ fv);          // BLE
            default: branch_taken = 1'b0;
        endcase
    endfunction

    // ------------------------------------------------------------------
    // Instruction class decode
    // ------------------------------------------------------------------
    // 8x..Bx: accumulator A group, Cx..Fx: accumulator B group.
    // Low nibble 0,1,2,4,5,6,8,9,A,B => two-operand 8-bit ALU.
    function automatic logic is_alu2(input logic [7:0] op);
        logic [3:0] lo;
        lo = op[3:0];
        is_alu2 = op[7] &&
                  (lo == 4'h0 || lo == 4'h1 || lo == 4'h2 || lo == 4'h4 ||
                   lo == 4'h5 || lo == 4'h6 || lo == 4'h8 || lo == 4'h9 ||
                   lo == 4'hA || lo == 4'hB) &&
                  !(op == 8'h8D);   // BSR
    endfunction

    // amode for the alu2 group: ir[5:4] 00=imm 01=dir 10=idx 11=ext
    // 16-bit ops: CPX(8C/9C/AC/BC), LDS(8E/9E/AE/BE), LDX(CE/DE/EE/FE),
    //             STS(9F/AF/BF), STX(DF/EF/FF), ADX(EC imm8 / FC ext)
    function automatic logic is_ld16(input logic [7:0] op);
        is_ld16 = (op == 8'h8C || op == 8'h9C || op == 8'hAC || op == 8'hBC ||
                   op == 8'h8E || op == 8'h9E || op == 8'hAE || op == 8'hBE ||
                   op == 8'hCE || op == 8'hDE || op == 8'hEE || op == 8'hFE ||
                   op == 8'hFC);
    endfunction

    function automatic logic is_st16(input logic [7:0] op);
        is_st16 = (op == 8'h9F || op == 8'hAF || op == 8'hBF ||
                   op == 8'hDF || op == 8'hEF || op == 8'hFF);
    endfunction

    function automatic logic is_st8(input logic [7:0] op);
        is_st8 = (op == 8'h97 || op == 8'hA7 || op == 8'hB7 ||
                  op == 8'hD7 || op == 8'hE7 || op == 8'hF7);
    endfunction

    function automatic logic is_rmw(input logic [7:0] op);
        // 6x (indexed) / 7x (extended) single-operand memory ops,
        // excluding JMP (6E/7E) and the NIM/OIM/XIM/TMM extensions.
        is_rmw = (op[7:4] == 4'h6 || op[7:4] == 4'h7) &&
                 (op != 8'h6E && op != 8'h7E &&
                  op != 8'h71 && op != 8'h72 && op != 8'h75 && op != 8'h7B);
    endfunction

    function automatic logic is_nimlike(input logic [7:0] op);
        is_nimlike = (op == 8'h71 || op == 8'h72 || op == 8'h75 || op == 8'h7B);
    endfunction

    // ------------------------------------------------------------------
    // 16-bit ALU commit helper values
    // ------------------------------------------------------------------
    // (implemented inline in the sequential block)

    // ------------------------------------------------------------------
    // Bus address selection (combinational, depends on registered state only)
    // ------------------------------------------------------------------
    logic [15:0] vec_base;
    assign vec_base = in_int ? (int_is_nmi ? 16'hFFFC : 16'hFFF8) : 16'hFFFA;

    always_comb begin
        bus_addr  = pc;
        bus_wdata = 8'h00;
        bus_we    = 1'b0;
        case (state)
            ST_RST_VH: bus_addr = 16'hFFFE;
            ST_RST_VL: bus_addr = 16'hFFFF;
            ST_FETCH:  bus_addr = pc;
            ST_OP1:    bus_addr = pc;
            ST_OP2:    bus_addr = pc;
            ST_LD1:    bus_addr = ea;
            ST_LD2:    bus_addr = ea + 16'd1;
            ST_RDS:    bus_addr = sp + 16'd1;
            ST_STK_RD: bus_addr = sp + 16'd1 + {13'b0, stk};
            ST_WR1: begin
                bus_addr = ea;
                bus_we   = 1'b1;
                if (is_st8(ir))
                    bus_wdata = ir[6] ? b : a;
                else if (ir == 8'h9F || ir == 8'hAF || ir == 8'hBF)
                    bus_wdata = sp[15:8];                 // STS high
                else if (ir == 8'hDF || ir == 8'hEF || ir == 8'hFF)
                    bus_wdata = ix[15:8];                 // STX high
                else if (ir == 8'h6F || ir == 8'h7F)
                    bus_wdata = 8'h00;                    // CLR ind/ext
                else
                    bus_wdata = wr1_data;                 // RMW / NIM / OIM / XIM
            end
            ST_WR2: begin
                bus_addr = ea + 16'd1;
                bus_we   = 1'b1;
                if (ir == 8'h9F || ir == 8'hAF || ir == 8'hBF)
                    bus_wdata = sp[7:0];                  // STS low
                else
                    bus_wdata = ix[7:0];                  // STX low
            end
            ST_PUSH_L: begin
                bus_addr  = sp;
                bus_wdata = pc[7:0];
                bus_we    = 1'b1;
            end
            ST_PUSH_H: begin
                bus_addr  = sp - 16'd1;
                bus_wdata = pc[15:8];
                bus_we    = 1'b1;
            end
            ST_WRS: begin
                bus_addr  = sp;
                bus_wdata = (ir == 8'h36) ? a : b;
                bus_we    = 1'b1;
            end
            ST_STK_WR: begin
                // push order: pcl@sp, pch@sp-1, ixl@sp-2, ixh@sp-3,
                //             a@sp-4, b@sp-5, cc@sp-6
                bus_addr = sp - {13'b0, stk};
                bus_we   = 1'b1;
                case (stk)
                    3'd0: bus_wdata = pc[7:0];
                    3'd1: bus_wdata = pc[15:8];
                    3'd2: bus_wdata = ix[7:0];
                    3'd3: bus_wdata = ix[15:8];
                    3'd4: bus_wdata = a;
                    3'd5: bus_wdata = b;
                    default: bus_wdata = ccr_byte;
                endcase
            end
            ST_VEC_H:  bus_addr = vec_base;
            ST_VEC_L:  bus_addr = vec_base + 16'd1;
            default: ;
        endcase
    end

    // RMW result registered by ST_LD1 for the ST_WR1 bus write
    logic [7:0] wr1_data;

    logic [7:0] ccr_byte;
    assign ccr_byte = {2'b11, fh, fi, fn, fz, fv, fc};

    assign boundary = (state == ST_FETCH) || (state == ST_WAI_WAIT);

    assign dbg_pc = pc;
    assign dbg_sp = sp;
    assign dbg_ix = ix;
    assign dbg_a  = a;
    assign dbg_b  = b;
    assign dbg_cc = ccr_byte;

    // ------------------------------------------------------------------
    // Helper: end-of-instruction transition
    // ------------------------------------------------------------------
    // Instruction is complete after work; remaining cycles are padded.
    // Implemented inside the sequential block via `finish_or_pad`.

    logic int_pending;
    assign int_pending = nmi_pend | (irq_level & ~fi);

    // ==================================================================
    // Main sequencer
    // ==================================================================
    always_ff @(posedge clk) begin
        if (rst) begin
            pc  <= init_pc;
            sp  <= init_sp;
            ix  <= init_ix;
            a   <= init_a;
            b   <= init_b;
            fh  <= init_cc[5];
            fi  <= vector_reset ? 1'b1 : init_cc[4];   // MC6800 RESET sets I
            fn  <= init_cc[3];
            fz  <= init_cc[2];
            fv  <= init_cc[1];
            fc  <= init_cc[0];
            state     <= vector_reset ? ST_RST_VH : ST_FETCH;
            ucnt      <= 4'd0;
            cyc_total <= 4'd0;
            ir        <= 8'h01;
            tmp       <= 8'h00;
            mdr       <= 8'h00;
            ea        <= 16'h0000;
            stk       <= 3'd0;
            wai_mode  <= 1'b0;
            in_int    <= 1'b0;
            int_is_nmi<= 1'b0;
            nmi_pend  <= 1'b0;
            wr1_data  <= 8'h00;
        end else begin
            if (nmi_set) nmi_pend <= 1'b1;

            if (cen) begin
                ucnt <= ucnt + 4'd1;

                unique case (state)
                // --------------------------------------------------------
                ST_RST_VH: begin
                    mdr   <= bus_rdata;
                    state <= ST_RST_VL;
                    ucnt  <= 4'd0;
                end

                ST_RST_VL: begin
                    pc    <= {mdr, bus_rdata};
                    state <= ST_FETCH;
                    ucnt  <= 4'd0;
                end

                // --------------------------------------------------------
                ST_FETCH: begin
                    if (int_pending) begin
                        // NMI/IRQ entry: 12 cycles, no opcode fetch.
                        // I is set only after the registers (with the
                        // pre-entry CC) are stacked - see ST_VEC_L.
                        in_int     <= 1'b1;
                        int_is_nmi <= nmi_pend;
                        if (nmi_pend) nmi_pend <= 1'b0;
                        wai_mode  <= 1'b0;
                        cyc_total <= 4'd12;
                        stk       <= 3'd0;
                        state     <= ST_STK_WR;
                    end else begin
                        logic [7:0]  op;
                        logic [3:0]  cyc;
                        op  = bus_rdata;
                        cyc = cycles_of(bus_rdata);
                        ir  <= op;
                        pc  <= pc + 16'd1;
                        in_int <= 1'b0;
                        if (cyc == 4'd0) begin
                            // undefined opcode: 1-cycle NOP
                            cyc_total <= 4'd1;
                            state     <= ST_FETCH;
                            ucnt      <= 4'd0;
                        end else begin
                            cyc_total <= cyc;
                            // dispatch
                            if (op == 8'h3E) begin              // WAI
                                // stacks all registers, then waits
                                wai_mode <= 1'b1;
                                stk      <= 3'd0;
                                state    <= ST_STK_WR;
                            end else if (op == 8'h3F) begin     // SWI: stacks opcode+1
                                stk   <= 3'd0;                  // (M68PRM 3.3.3; the
                                state <= ST_STK_WR;             // fetch's pc+1 stands)
                            end else if (op == 8'h3B) begin     // RTI
                                stk   <= 3'd0;
                                state <= ST_STK_RD;
                            end else if (op == 8'h39) begin     // RTS
                                ea    <= sp + 16'd1;
                                state <= ST_LD1;
                            end else if (op == 8'h32 || op == 8'h33) begin // PUL
                                state <= ST_RDS;
                            end else if (op == 8'h36 || op == 8'h37) begin // PSH
                                state <= ST_WRS;
                            end else if (op[7:4] == 4'h0 || op[7:4] == 4'h1 ||
                                         (op[7:4] == 4'h3 && op != 8'h39 && op != 8'h3B &&
                                          op != 8'h3E && op != 8'h3F) ||
                                         op[7:4] == 4'h4 || op[7:4] == 4'h5) begin
                                // implied ops (rows 0x,1x,3x remainder,4x,5x)
                                state <= ST_EXEC;
                            end else begin
                                state <= ST_OP1;
                            end
                        end
                    end
                end

                // --------------------------------------------------------
                ST_OP1: begin
                    logic [7:0] d;
                    d  = bus_rdata;
                    pc <= pc + 16'd1;
                    tmp <= d;
                    if (ir[7:4] == 4'h2) begin
                        // branches
                        if (branch_taken(ir[3:0]))
                            pc <= pc + 16'd1 + {{8{d[7]}}, d};
                        state <= ST_PAD;
                    end else if (ir == 8'h8D) begin
                        // BSR: push return address, then branch
                        tmp   <= d;
                        state <= ST_PUSH_L;
                    end else if (is_nimlike(ir)) begin
                        state <= ST_OP2;               // d = immediate value
                    end else if (ir == 8'hEC) begin
                        // ADX imm: 16-bit add of zero-extended imm8
                        logic [16:0] sum17;
                        logic [15:0] res16;
                        sum17 = {1'b0, ix} + {9'b0, d};
                        res16 = sum17[15:0];
                        fn <= res16[15];
                        fz <= (res16 == 0);
                        fv <= (pos16(ix) & pos16({8'h00, d}) & res16[15]) |
                              (neg16(ix) & neg16({8'h00, d}) & ~res16[15]);
                        fc <= sum17[16];
                        ix <= res16;
                        state <= ST_PAD;
                    end else if (is_alu2(ir) && ir[5:4] == 2'b00) begin
                        // immediate 8-bit ALU: commit now
                        alu2_t r;
                        r = alu2(ir[3:0], ir[6] ? b : a, d, fc);
                        if (r.res_we) begin
                            if (ir[6]) b <= r.res; else a <= r.res;
                        end
                        if (r.h_we) fh <= r.h;
                        fn <= r.n; fz <= r.z; fv <= r.v;
                        if (r.c_we) fc <= r.c;
                        state <= ST_PAD;
                    end else if (ir == 8'h8C || ir == 8'h8E || ir == 8'hCE) begin
                        // CPX/LDS/LDX immediate: high byte first
                        state <= ST_OP2;
                    end else begin
                        // dir/idx address formation or ext high byte
                        case (ir[5:4])
                            2'b01: begin                        // direct
                                ea <= {8'h00, d};
                                state <= after_ea_state(ir);
                            end
                            2'b10: begin                        // indexed
                                ea <= ix + {8'h00, d};
                                if (ir == 8'h6E) begin          // JMP ind
                                    pc <= ix + {8'h00, d};
                                    state <= ST_PAD;
                                end else if (ir == 8'hAD) begin // JSR ind
                                    ea <= ix + {8'h00, d};
                                    state <= ST_PUSH_L;
                                end else begin
                                    state <= after_ea_state(ir);
                                end
                            end
                            default: state <= ST_OP2;           // extended: high byte in tmp
                        endcase
                    end
                end

                // --------------------------------------------------------
                ST_OP2: begin
                    logic [7:0] d;
                    d  = bus_rdata;
                    pc <= pc + 16'd1;
                    if (is_nimlike(ir)) begin
                        ea <= ix + {8'h00, d};
                        state <= ST_LD1;
                    end else if (ir == 8'h8C) begin             // CPX imm
                        commit_cpx({tmp, d});
                        state <= ST_PAD;
                    end else if (ir == 8'h8E) begin             // LDS imm
                        commit_lds({tmp, d});
                        state <= ST_PAD;
                    end else if (ir == 8'hCE) begin             // LDX imm
                        commit_ldx({tmp, d});
                        state <= ST_PAD;
                    end else if (ir == 8'h7E) begin             // JMP ext
                        pc <= {tmp, d};
                        state <= ST_PAD;
                    end else if (ir == 8'hBD) begin             // JSR ext
                        ea <= {tmp, d};
                        state <= ST_PUSH_L;
                    end else begin
                        ea <= {tmp, d};
                        state <= after_ea_state(ir);
                    end
                end

                // --------------------------------------------------------
                ST_LD1: begin
                    logic [7:0] d;
                    d = bus_rdata;
                    if (ir == 8'h39) begin
                        // RTS: high byte of return address
                        mdr <= d;
                        state <= ST_LD2;
                    end else if (is_rmw(ir)) begin
                        alu1_t r;
                        r = alu1(ir[3:0], d, fc);
                        fn <= r.n; fz <= r.z; fv <= r.v;
                        if (r.c_we) fc <= r.c;
                        if (r.wr_mem) begin
                            wr1_data <= r.res;
                            state <= ST_WR1;
                        end else begin
                            state <= ST_PAD;                    // TST ind/ext
                        end
                    end else if (is_nimlike(ir)) begin
                        // tmp = immediate value, d = memory byte
                        logic [7:0] res;
                        case (ir)
                            8'h71: begin                        // NIM
                                res = tmp & d;
                                fz <= (res == 0); fn <= (res != 0); fv <= 1'b0;
                                wr1_data <= res; state <= ST_WR1;
                            end
                            8'h72: begin                        // OIM
                                res = tmp | d;
                                fz <= (res == 0); fn <= (res != 0); fv <= 1'b0;
                                wr1_data <= res; state <= ST_WR1;
                            end
                            8'h75: begin                        // XIM (V unchanged)
                                res = tmp ^ d;
                                fz <= (res == 0); fn <= (res != 0);
                                wr1_data <= res; state <= ST_WR1;
                            end
                            default: begin                      // TMM
                                if (tmp == 8'h00 || d == 8'h00) begin
                                    fn <= 1'b0; fz <= 1'b1; fv <= 1'b0;
                                end else if (d == 8'hFF) begin
                                    fn <= 1'b0; fz <= 1'b0; fv <= 1'b1;
                                end else begin
                                    fn <= 1'b1; fz <= 1'b0; fv <= 1'b0;
                                end
                                state <= ST_PAD;
                            end
                        endcase
                    end else if (is_ld16(ir)) begin
                        mdr <= d;                               // high byte
                        state <= ST_LD2;
                    end else begin
                        // 8-bit ALU load commit
                        alu2_t r;
                        r = alu2(ir[3:0], ir[6] ? b : a, d, fc);
                        if (r.res_we) begin
                            if (ir[6]) b <= r.res; else a <= r.res;
                        end
                        if (r.h_we) fh <= r.h;
                        fn <= r.n; fz <= r.z; fv <= r.v;
                        if (r.c_we) fc <= r.c;
                        state <= ST_PAD;
                    end
                end

                // --------------------------------------------------------
                ST_LD2: begin
                    logic [15:0] w;
                    w = {mdr, bus_rdata};
                    if (ir == 8'h39) begin                      // RTS
                        pc <= w;
                        sp <= sp + 16'd2;
                        state <= ST_PAD;
                    end else if (ir == 8'h8C || ir == 8'h9C || ir == 8'hAC || ir == 8'hBC) begin
                        commit_cpx(w);
                        state <= ST_PAD;
                    end else if (ir == 8'h9E || ir == 8'hAE || ir == 8'hBE) begin
                        commit_lds(w);
                        state <= ST_PAD;
                    end else if (ir == 8'hFC) begin             // ADX ext
                        logic [16:0] sum17;
                        logic [15:0] res16;
                        sum17 = {1'b0, ix} + {1'b0, w};
                        res16 = sum17[15:0];
                        fn <= res16[15];
                        fz <= (res16 == 0);
                        fv <= (pos16(ix) & pos16(w) & res16[15]) |
                              (neg16(ix) & neg16(w) & ~res16[15]);
                        fc <= sum17[16];
                        ix <= res16;
                        state <= ST_PAD;
                    end else begin                              // LDX dir/idx/ext
                        commit_ldx(w);
                        state <= ST_PAD;
                    end
                end

                // --------------------------------------------------------
                ST_EXEC: begin
                    exec_implied();
                    state <= ST_PAD;
                end

                // --------------------------------------------------------
                ST_WR1: begin
                    // bus write happens combinationally this cycle
                    if (is_st8(ir)) begin
                        // STAA/STAB set N/Z from the stored value, V=0
                        logic [7:0] val;
                        val = ir[6] ? b : a;
                        fn <= val[7]; fz <= (val == 0); fv <= 1'b0;
                        state <= ST_PAD;
                    end else if (ir == 8'h6F || ir == 8'h7F) begin
                        // CLR ind/ext
                        fn <= 1'b0; fz <= 1'b1; fv <= 1'b0; fc <= 1'b0;
                        state <= ST_PAD;
                    end else if (is_st16(ir)) begin
                        state <= ST_WR2;
                    end else begin
                        state <= ST_PAD;                    // RMW result write
                    end
                end

                ST_WR2: begin
                    // N/Z/V from the stored value: STX from IX, STS from
                    // SP (M68PRM: N = SPH7).
                    if (ir == 8'h9F || ir == 8'hAF || ir == 8'hBF) begin
                        fn <= sp[15]; fz <= (sp == 0);
                    end else begin
                        fn <= ix[15]; fz <= (ix == 0);
                    end
                    fv <= 1'b0;
                    state <= ST_PAD;
                end

                // --------------------------------------------------------
                ST_PUSH_L: begin
                    state <= ST_PUSH_H;
                end

                ST_PUSH_H: begin
                    sp <= sp - 16'd2;
                    if (ir == 8'h8D)
                        pc <= pc + {{8{tmp[7]}}, tmp};          // BSR
                    else
                        pc <= ea;                               // JSR
                    state <= ST_PAD;
                end

                // --------------------------------------------------------
                ST_RDS: begin
                    if (ir == 8'h32) a <= bus_rdata; else b <= bus_rdata;
                    sp <= sp + 16'd1;
                    state <= ST_PAD;
                end

                ST_WRS: begin
                    sp <= sp - 16'd1;
                    state <= ST_PAD;
                end

                // --------------------------------------------------------
                ST_STK_RD: begin
                    // RTI pop order: cc@sp+1, b@sp+2, a@sp+3,
                    //                ixh@sp+4, ixl@sp+5, pch@sp+6, pcl@sp+7
                    case (stk)
                        3'd0: begin
                            fh <= bus_rdata[5]; fi <= bus_rdata[4];
                            fn <= bus_rdata[3]; fz <= bus_rdata[2];
                            fv <= bus_rdata[1]; fc <= bus_rdata[0];
                        end
                        3'd1: b <= bus_rdata;
                        3'd2: a <= bus_rdata;
                        3'd3: ix[15:8] <= bus_rdata;
                        3'd4: ix[7:0]  <= bus_rdata;
                        3'd5: pc[15:8] <= bus_rdata;
                        default: pc[7:0] <= bus_rdata;
                    endcase
                    if (stk == 3'd6) begin
                        sp <= sp + 16'd7;
                        state <= ST_PAD;
                    end else begin
                        stk <= stk + 3'd1;
                    end
                end

                ST_STK_WR: begin
                    if (stk == 3'd6) begin
                        sp <= sp - 16'd7;
                        if (!in_int && ir == 8'h3F) fi <= 1'b1;  // SWI sets I
                        if (!in_int && ir == 8'h3E)
                            state <= ST_PAD;                     // WAI: no vector fetch
                        else
                            state <= ST_VEC_H;
                    end else begin
                        stk <= stk + 3'd1;
                    end
                end

                ST_VEC_H: begin
                    mdr <= bus_rdata;
                    state <= ST_VEC_L;
                end

                ST_VEC_L: begin
                    pc <= {mdr, bus_rdata};
                    if (in_int) fi <= 1'b1;   // NMI/IRQ set I after stacking
                    state <= ST_PAD;
                end

                // --------------------------------------------------------
                ST_PAD: begin
                    // burn remaining cycles
                end

                ST_WAI_WAIT: begin
                    if (int_pending) begin
                        // Registers were already stacked by WAI itself:
                        // exit costs 4 cycles (detect + vector + pad)
                        // and sets the I flag (pyjr100emu 9b11a18).
                        in_int     <= 1'b1;
                        int_is_nmi <= nmi_pend;
                        if (nmi_pend) nmi_pend <= 1'b0;
                        wai_mode  <= 1'b0;
                        cyc_total <= 4'd4;
                        ucnt      <= 4'd1;   // this detect cycle counts as 1
                        state     <= ST_VEC_H;
                    end
                    // otherwise: 1-cycle boundary samples, stay here
                end

                default: state <= ST_FETCH;
                endcase

                // ----------------------------------------------------
                // Cycle padding / end-of-instruction handling.
                // Runs after the state case so it can override `state`.
                // ----------------------------------------------------
                if (state != ST_FETCH && state != ST_WAI_WAIT &&
                    state != ST_RST_VH && state != ST_RST_VL) begin
                    if (ucnt + 4'd1 >= cyc_total) begin
                        state <= wai_mode ? ST_WAI_WAIT : ST_FETCH;
                        ucnt  <= 4'd0;
                    end
                end else if (state == ST_FETCH) begin
                    if (!int_pending && cycles_of(bus_rdata) == 4'd0) begin
                        ucnt <= 4'd0;   // 1-cycle undefined NOP
                    end else if (!int_pending && cycles_of(bus_rdata) == 4'd1) begin
                        ucnt <= 4'd0;
                    end
                end else if (state == ST_WAI_WAIT) begin
                    if (!int_pending) ucnt <= 4'd0;  // each wait cycle stands alone
                end
            end
        end
    end

    // ------------------------------------------------------------------
    // Helper state selection after the effective address is known
    // ------------------------------------------------------------------
    function automatic state_t after_ea_state(input logic [7:0] op);
        if (is_st8(op) || is_st16(op)) after_ea_state = ST_WR1;
        else if (op == 8'h6F || op == 8'h7F) after_ea_state = ST_WR1; // CLR: no read
        else after_ea_state = ST_LD1;
    endfunction

    // ------------------------------------------------------------------
    // Commit tasks (called from the sequential block)
    // ------------------------------------------------------------------
    task automatic commit_cpx(input logic [15:0] value);
        logic [15:0] diff;
        diff = ix - value;
        fn <= diff[15];
        fz <= (diff == 0);
        fv <= (pos16(ix) & neg16(value) & diff[15]) |
              (neg16(ix) & pos16(value) & ~diff[15]);
        // C unchanged (pyjr100emu)
    endtask

    task automatic commit_ldx(input logic [15:0] value);
        ix <= value;
        fn <= value[15];
        fz <= (value == 0);
        fv <= 1'b0;
    endtask

    task automatic commit_lds(input logic [15:0] value);
        sp <= value;
        fn <= value[15];
        fz <= (value == 0);
        fv <= 1'b0;
    endtask

    // ------------------------------------------------------------------
    // Implied-mode execution (rows 0x/1x/3x-remainder/4x/5x)
    // ------------------------------------------------------------------
    task automatic exec_implied();
        alu1_t r1;
        alu2_t r2;
        logic [8:0] daa_t;
        logic [7:0] daa_res;
        case (ir)
            8'h01: ;                                            // NOP
            8'h06: begin                                        // TAP
                fh <= a[5]; fi <= a[4]; fn <= a[3];
                fz <= a[2]; fv <= a[1]; fc <= a[0];
            end
            8'h07: a <= ccr_byte;                               // TPA
            8'h08: begin ix <= ix + 16'd1; fz <= (ix + 16'd1) == 0; end // INX
            8'h09: begin ix <= ix - 16'd1; fz <= (ix - 16'd1) == 0; end // DEX
            8'h0A: fv <= 1'b0;                                  // CLV
            8'h0B: fv <= 1'b1;                                  // SEV
            8'h0C: fc <= 1'b0;                                  // CLC
            8'h0D: fc <= 1'b1;                                  // SEC
            8'h0E: fi <= 1'b0;                                  // CLI
            8'h0F: fi <= 1'b1;                                  // SEI
            8'h10: begin                                        // SBA
                r2 = alu2(4'h0, a, b, fc);
                a <= r2.res;
                fn <= r2.n; fz <= r2.z; fv <= r2.v; fc <= r2.c;
            end
            8'h11: begin                                        // CBA
                r2 = alu2(4'h1, a, b, fc);
                fn <= r2.n; fz <= r2.z; fv <= r2.v; fc <= r2.c;
            end
            8'h16: begin                                        // TAB
                b <= a; fn <= a[7]; fz <= (a == 0); fv <= 1'b0;
            end
            8'h17: begin                                        // TBA
                a <= b; fn <= b[7]; fz <= (b == 0); fv <= 1'b0;
            end
            8'h19: begin                                        // DAA (pyjr100emu formula)
                daa_t = {1'b0, a};
                if ((a[3:0] >= 4'hA) || fh) daa_t = daa_t + 9'h006;
                if ((daa_t[7:0] & 8'hF0) >= 8'hA0) daa_t = daa_t + 9'h060;
                daa_res = daa_t[7:0];
                fn <= daa_res[7];
                fz <= (daa_res == 0);
                fv <= (pos8(a) & daa_res[7]) | (neg8(a) & ~daa_res[7]);
                fc <= ((a & 8'hF0) >= 8'hA0) | fc;
                a  <= daa_res;
            end
            8'h1B: begin                                        // ABA
                r2 = alu2(4'hB, a, b, fc);
                a <= r2.res;
                fh <= r2.h; fn <= r2.n; fz <= r2.z; fv <= r2.v; fc <= r2.c;
            end
            8'h30: ix <= sp + 16'd1;                            // TSX
            8'h31: sp <= sp + 16'd1;                            // INS
            8'h34: sp <= sp - 16'd1;                            // DES
            8'h35: sp <= ix - 16'd1;                            // TXS
            default: begin
                // rows 4x (A) / 5x (B): single-operand accumulator ops
                if (ir[7:4] == 4'h4 || ir[7:4] == 4'h5) begin
                    r1 = alu1(ir[3:0], (ir[4]) ? b : a, fc);
                    fn <= r1.n; fz <= r1.z; fv <= r1.v;
                    if (r1.c_we) fc <= r1.c;
                    if (r1.wr_mem) begin
                        if (ir[4]) b <= r1.res; else a <= r1.res;
                    end
                end
            end
        endcase
    endtask

endmodule
