//============================================================================
//
//  JR-100 R6522 VIA (JR100_MiSTer)
//
//  Mirrors pyjr100emu via/r6522.py + jr100/r6522.py (compatibility
//  baseline, AGENTS.md §1): per-cycle timer/shift evolution follows
//  R6522._execute() statement order exactly, including the JR-100
//  wiring (keyboard row scan on ORA writes, PB7->PB6 jumper on ORB
//  writes and Timer1 timeouts in modes 2/3).
//
//  The reference syncs the VIA one tick ahead of the CPU clock, so this
//  module performs one extra "priming" tick on the first enabled cycle.
//  Known model difference: the reference applies CPU accesses at
//  instruction-start time while this hardware applies them at the real
//  bus cycle; programs that read live timer counters or start timers
//  see a fixed intra-instruction offset (docs/DEVELOPMENT.md).
//
//  NOTE: this sequential block deliberately uses BLOCKING assignments
//  so that the within-cycle ordering (timer1 -> PB6 edge -> timer2 ->
//  shift -> CPU access) matches the reference statement order.
//
//  Copyright (C) 2026 Zabaglione
//  SPDX-License-Identifier: GPL-2.0-or-later
//
//============================================================================

module jr100_via
(
    input  logic        clk,
    input  logic        rst,
    input  logic        cen,

    // CPU bus access (one cen cycle per access)
    input  logic        sel,        // address decodes to C800-C80F
    input  logic [3:0]  reg_addr,
    input  logic        we,
    input  logic [7:0]  wdata,
    output logic [7:0]  rdata,      // combinational

    // JR-100 keyboard matrix: 9 rows x 5 bits, 1 = pressed
    input  logic [44:0] key_matrix,

    output logic        irq,        // level to CPU
    // cassette interface: the CMT input line feeds CA1 (falling edge)
    // and CB1 (rising edge) per the JR-100 wiring; CB2 carries the SR
    // shift-out waveform (the CMT output).
    input  logic        ca1_in,
    input  logic        cb1_in,
    output logic        cb2,

    output logic        pb7_out,    // raw Port B bit 7 view
    output logic        snd_out,    // sound source: toggles on every
                                    // Timer 1 reload, like the reference
                                    // sound-line model (store_t1ch_option
                                    // runs on each reload, so a tone
                                    // appears even when ACR is written
                                    // after T1 already timed out one-shot)
    output logic        font_user,  // Port B bit 5 view (display font select)
    output logic        dbg_pb6,    // Port B bit 6 view (cycle unit tests)

    // trace/debug (raw register values, TRACE_FORMAT v1)
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

    // IFR bits
    localparam logic [6:0] IFR_CA2 = 7'h01;
    localparam logic [6:0] IFR_CA1 = 7'h02;
    localparam logic [6:0] IFR_SR  = 7'h04;
    localparam logic [6:0] IFR_CB2 = 7'h08;
    localparam logic [6:0] IFR_CB1 = 7'h10;
    localparam logic [6:0] IFR_T2  = 7'h20;
    localparam logic [6:0] IFR_T1  = 7'h40;

    // Registers (names follow VIAState)
    logic [6:0]         ifr, ier;
    logic [7:0]         pcr, acr;
    logic [7:0]         ira, ora, ddra;
    logic [7:0]         irb, orb, ddrb;
    // Reset-exempt storage (R6522 datasheet: RES clears all registers
    // except T1/T2 counters+latches and the shift register). Power-up
    // initialisers cover the FPGA-configuration cold start, where the
    // boot comparison convention expects zeros.
    logic [7:0]         sr = '0;
    logic [7:0]         port_a, port_b;
    logic               prev_pb6;
    logic [15:0]        latch1 = '0, latch2 = '0;
    logic signed [16:0] timer1 = '0, timer2 = '0;
    logic               t1_init, t1_en, t2_init, t2_en;
    logic               snd = 1'b0;   // output model only, not a VIA register
    logic               shift_tick, shift_started;
    logic [2:0]         shift_cnt;
    logic               cb1_out, cb2_out, ca2_out;
    logic               ca1_prev = 1'b0, cb1_prev = 1'b0;
    logic signed [2:0]  ca2_timer;   // -1 = inactive
    logic               primed;

    // ------------------------------------------------------------------
    // Port views (R6522.input_port_a/b)
    // ------------------------------------------------------------------
    function automatic logic [7:0] in_a
        (input logic [7:0] f_ira, f_pa, f_ddra);
        in_a = (f_ira & ~f_ddra) | (f_pa & f_ddra);
    endfunction

    function automatic logic [7:0] in_b
        (input logic [7:0] f_irb, f_orb, f_ddrb);
        in_b = (f_irb & ~f_ddrb) | (f_orb & f_ddrb);
    endfunction

    assign irq = |(ifr & ier);

    // Quartus 17.0 does not accept bit-selects on function call results,
    // so the Port B view is materialised as a signal.
    logic [7:0] port_b_view;
    assign port_b_view = (irb & ~ddrb) | (orb & ddrb);
    assign pb7_out   = port_b_view[7];
    assign snd_out   = snd;
    assign font_user = port_b_view[5];
    assign dbg_pb6   = port_b_view[6];

    assign dbg_ora  = ora;
    assign dbg_orb  = orb;
    assign dbg_ddra = ddra;
    assign dbg_ddrb = ddrb;
    assign dbg_acr  = acr;
    assign dbg_pcr  = pcr;
    assign dbg_ifr  = {irq, ifr};
    assign dbg_ier  = {1'b0, ier};
    assign dbg_sr   = sr;
    assign dbg_t1   = timer1[15:0];
    assign dbg_t1l  = latch1;
    assign dbg_t2   = timer2[15:0];
    assign dbg_t2l  = latch2;

    // ------------------------------------------------------------------
    // Combinational read data (no side effects here; those apply on cen)
    // ------------------------------------------------------------------
    always_comb begin
        case (reg_addr)
            4'h0: rdata = (acr[1] == 1'b0) ? in_b(irb, orb, ddrb) : irb;   // IORB
            4'h1: rdata = (acr[0] == 1'b0) ? in_a(ira, port_a, ddra) : ira; // IORA
            4'h2: rdata = ddrb;
            4'h3: rdata = ddra;
            4'h4: rdata = timer1[7:0];    // T1CL
            4'h5: rdata = timer1[15:8];   // T1CH
            4'h6: rdata = latch1[7:0];    // T1LL
            4'h7: rdata = latch1[15:8];   // T1LH
            4'h8: rdata = timer2[7:0];    // T2CL
            4'h9: rdata = timer2[15:8];   // T2CH
            4'hA: rdata = sr;
            4'hB: rdata = acr;
            4'hC: rdata = pcr;
            4'hD: rdata = {irq, ifr};
            4'hE: rdata = {1'b0, ier} | 8'h80;
            default: rdata = (acr[0] == 1'b0) ? in_a(ira, port_a, ddra) : ira; // IORANH
        endcase
    end

    // ------------------------------------------------------------------
    // Sequential model. Blocking assignments: order mirrors the Python
    // reference statement-for-statement.
    // ------------------------------------------------------------------

    // R6522.set_port_b(bit, state): input bits only, updates IRB unless latched
    task automatic set_port_b_bit(input int bit_index, input logic value);
        if (!ddrb[bit_index]) begin
            port_b[bit_index] = value;
            if (!acr[1]) irb = port_b;
        end
    endtask

    // R6522.invert_port_b(bit)
    task automatic invert_port_b_bit(input int bit_index);
        if (!ddrb[bit_index]) begin
            port_b[bit_index] = ~port_b[bit_index];
            if (!acr[1]) irb = port_b;
        end
    endtask

    // R6522.set_port_b_value(value)
    task automatic set_port_b_value(input logic [7:0] value);
        port_b = (port_b & ddrb) | (value & ~ddrb);
        if (!acr[1]) irb = port_b;
    endtask

    // JR100R6522._jumper_pb7_pb6
    task automatic jumper_pb7_pb6();
        logic [7:0] view;
        view = in_b(irb, orb, ddrb);
        set_port_b_bit(6, view[7]);
    endtask

    // JR100R6522.store_iora_option: keyboard row scan
    task automatic keyboard_scan();
        logic [7:0] value;
        logic [3:0] row;
        logic [4:0] row_bits;
        value = in_b(irb, orb, ddrb) & 8'hE0;
        row = ora[3:0];
        if (row < 4'd9) begin
            row_bits = key_matrix[row*5 +: 5];
            value[4:0] = ~row_bits;
        end
        set_port_b_value(value);
    endtask

    // R6522._process_shift_in / _process_shift_out
    task automatic process_shift_in();
        if (shift_started) begin
            if (shift_tick) begin
                cb1_out = 1'b1;
                sr = {sr[6:0], 1'b0};           // CB2_in is tied low
                shift_cnt = shift_cnt + 3'd1;
                if (shift_cnt == 3'd0) begin
                    ifr = ifr | IFR_SR;
                    shift_started = 1'b0;
                end
            end else begin
                cb1_out = 1'b0;
            end
            shift_tick = ~shift_tick;
        end
    endtask

    task automatic process_shift_out();
        if (shift_started) begin
            if (shift_tick) begin
                cb1_out = 1'b1;
                cb2_out = sr[7];
                sr = {sr[6:0], sr[7]};
                if ((acr & 8'h1C) != 8'h10) begin
                    shift_cnt = shift_cnt + 3'd1;
                    if (shift_cnt == 3'd0) begin
                        ifr = ifr | IFR_SR;
                        shift_started = 1'b0;
                    end
                end
            end else begin
                cb1_out = 1'b0;
            end
            shift_tick = ~shift_tick;
        end
    endtask

    // R6522._initialize_shift_in/_out (SR access side effect)
    task automatic initialize_shift_in();
        shift_tick = 1'b0;
        shift_cnt = 3'd0;
        if ((ifr & IFR_SR) != 0) begin
            ifr = ifr & ~IFR_SR;
            process_shift_in();
        end
        shift_started = 1'b1;
    endtask

    task automatic initialize_shift_out();
        shift_tick = 1'b0;
        shift_cnt = 3'd0;
        if ((ifr & IFR_SR) != 0) begin
            ifr = ifr & ~IFR_SR;
            process_shift_out();
        end
        shift_started = 1'b1;
    endtask

    // One cycle of R6522._execute()
    task automatic via_tick();
        logic pb6_now, pb6_negative;

        // CA2 handshake timer
        if (ca2_timer >= 0) begin
            ca2_timer = ca2_timer - 3'sd1;
            if (ca2_timer < 0) ca2_out = 1'b1;
        end

        // Timer 1
        if (t1_init) begin
            t1_init = 1'b0;
        end else if (!timer1[16]) begin
            timer1 = timer1 - 17'sd1;
        end else begin
            if (t1_en) begin
                ifr = ifr | IFR_T1;
                case (acr[7:6])
                    2'b00: t1_en = 1'b0;
                    2'b01: invert_port_b_bit(7);
                    2'b10: begin
                        t1_en = 1'b0;
                        set_port_b_bit(7, 1'b1);
                        jumper_pb7_pb6();          // timer1_timeout_mode2_option
                    end
                    default: begin
                        invert_port_b_bit(7);
                        jumper_pb7_pb6();          // timer1_timeout_mode3_option
                    end
                endcase
            end
            timer1 = {1'b0, latch1};
            snd = ~snd;   // reference: store_t1ch_option on every reload
        end

        // Timer 2 (PB6 edge computed after Timer 1, as in the reference)
        begin
            logic [7:0] view;
            view = in_b(irb, orb, ddrb);
            pb6_now = view[6];
        end
        pb6_negative = prev_pb6 && !pb6_now;
        prev_pb6 = pb6_now;

        if (!timer2[16]) begin
            if (!acr[5]) begin
                if (t2_init) t2_init = 1'b0;
                else timer2 = timer2 - 17'sd1;
            end else begin
                if (t2_init) t2_init = 1'b0;
                else if (pb6_negative) timer2 = timer2 - 17'sd1;
            end
        end else begin
            if (t2_en) begin
                ifr = ifr | IFR_T2;
                t2_en = 1'b0;
            end
            if (shift_started && timer2[7:0] == 8'hFF) begin
                case (acr & 8'h1C)
                    8'h04:        process_shift_in();
                    8'h10, 8'h14: process_shift_out();
                    default: ;
                endcase
            end
            timer2 = {1'b0, latch2};
        end

        // System-clock shift modes
        case (acr & 8'h1C)
            8'h08: process_shift_in();
            8'h18: process_shift_out();
            default: ;
        endcase
    endtask

    // CPU write side effects (R6522.store8 + JR-100 hooks)
    task automatic via_store(input logic [3:0] adr, input logic [7:0] value);
        case (adr)
            4'h0: begin                                     // IORB
                orb = value;
                // font select handled by the display (Phase D video);
                // jumper runs on every ORB store (store_orb_option)
                ifr = ifr & ~(IFR_CB1 | (((pcr & 8'hA0) == 8'h20) ? 7'h00 : IFR_CB2));
                if (cb2_out && ((pcr & 8'hC0) == 8'h80)) cb2_out = 1'b0;
                jumper_pb7_pb6();
            end
            4'h1: begin                                     // IORA
                ora = value;
                ifr = ifr & ~(IFR_CA1 | (((pcr & 8'h0A) == 8'h02) ? 7'h00 : IFR_CA2));
                if (ca2_out && (((pcr & 8'h0E) == 8'h0A) || ((pcr & 8'h0C) == 8'h08)))
                    ca2_out = 1'b0;
                if ((pcr & 8'h0E) == 8'h0A) ca2_timer = 3'sd1;
                keyboard_scan();                            // store_iora_option
            end
            4'h2: ddrb = value;
            4'h3: ddra = value;
            4'h4, 4'h6: latch1 = {latch1[15:8], value};     // T1CL / T1LL
            4'h5: begin                                     // T1CH
                latch1 = {value, latch1[7:0]};
                timer1 = {1'b0, latch1};
                ifr = ifr & ~IFR_T1;
                t1_init = 1'b1;
                t1_en = 1'b1;
                set_port_b_bit(7, 1'b0);
            end
            4'h7: latch1 = {value, latch1[7:0]};            // T1LH
            4'h8: latch2 = {latch2[15:8], value};           // T2CL
            4'h9: begin                                     // T2CH
                latch2 = {value, latch2[7:0]};
                timer2 = {1'b0, value, latch2[7:0]};
                ifr = ifr & ~IFR_T2;
                t2_init = 1'b1;
                t2_en = 1'b1;
            end
            4'hA: begin                                     // SR
                ifr = ifr & ~IFR_SR;
                case (acr & 8'h1C)
                    8'h04, 8'h08, 8'h0C: initialize_shift_in();
                    8'h10, 8'h14, 8'h18, 8'h1C: initialize_shift_out();
                    default: ;
                endcase
                sr = value;
            end
            4'hB: begin                                     // ACR
                acr = value;
                if ((value & 8'h1C) == 8'h00) begin
                    shift_started = 1'b0;
                    ifr = ifr & ~IFR_SR;
                end
            end
            4'hC: pcr = value;
            4'hD: ifr = ifr & ~(value[6:0]);                // IFR
            4'hE: begin                                     // IER
                if (value[7]) ier = ier | value[6:0];
                else          ier = ier & ~value[6:0];
            end
            default: ora = value;                           // IORANH (no keyboard scan)
        endcase
    endtask

    // CPU read side effects (R6522.load8)
    task automatic via_read_effects(input logic [3:0] adr);
        case (adr)
            4'h0: ifr = ifr & ~(IFR_CB1 | (((pcr & 8'hA0) == 8'h20) ? 7'h00 : IFR_CB2));
            4'h1: begin
                ifr = ifr & ~(IFR_CA1 | (((pcr & 8'h0A) == 8'h02) ? 7'h00 : IFR_CA2));
                if (ca2_out && (((pcr & 8'h0E) == 8'h0A) || ((pcr & 8'h0E) == 8'h08))) begin
                    ca2_out = 1'b0;
                    if ((pcr & 8'h0E) == 8'h08) ca2_timer = 3'sd1;
                end
            end
            4'h4: ifr = ifr & ~IFR_T1;                      // T1CL
            4'h8: ifr = ifr & ~IFR_T2;                      // T2CL
            4'hA: begin                                     // SR
                ifr = ifr & ~IFR_SR;
                case (acr & 8'h1C)
                    8'h04, 8'h08, 8'h0C: initialize_shift_in();
                    8'h10, 8'h14, 8'h18, 8'h1C: initialize_shift_out();
                    default: ;
                endcase
            end
            default: ;
        endcase
    endtask

    // R6522.set_ca1 / set_cb1: external line edges (called by devices
    // between ticks in the reference; applied after this cycle's tick)
    task automatic apply_ca1_edge();
        if (ca1_in != ca1_prev) begin
            ca1_prev = ca1_in;
            if ((ca1_in && pcr[0]) || (!ca1_in && !pcr[0])) begin
                if (acr[0]) ira = in_a(ira, port_a, ddra);
                ifr = ifr | IFR_CA1;
                if (!ca2_out && (pcr & 8'h0E) == 8'h08) ca2_out = 1'b1;
            end
        end
    endtask

    task automatic apply_cb1_edge();
        if (cb1_in != cb1_prev) begin
            cb1_prev = cb1_in;
            if ((cb1_in && pcr[4]) || (!cb1_in && !pcr[4])) begin
                if (acr[1]) irb = in_b(irb, orb, ddrb);
                if (shift_started && (acr & 8'h1C) == 8'h0C) process_shift_in();
                if (shift_started && (acr & 8'h1C) == 8'h1C) process_shift_out();
                ifr = ifr | IFR_CB1;
                if (!cb2_out && (pcr & 8'hA0) == 8'h20) cb2_out = 1'b1;
            end
        end
    endtask

    always_ff @(posedge clk) begin
        if (rst) begin
            // T1/T2 counters+latches and SR are reset-exempt (R6522 RES);
            // they keep their power-up zeros on the cold start.
            ifr = '0; ier = '0; pcr = '0; acr = '0;
            ira = '0; ora = '0; ddra = '0;
            irb = '0; orb = '0; ddrb = '0;
            port_a = '0; port_b = '0;
            prev_pb6 = 1'b0;
            t1_init = 1'b0; t1_en = 1'b0;
            t2_init = 1'b0; t2_en = 1'b0;
            shift_tick = 1'b0; shift_started = 1'b0; shift_cnt = '0;
            cb1_out = 1'b0; cb2_out = 1'b0; ca2_out = 1'b0;
            ca2_timer = -3'sd1;
            primed = 1'b0;
        end else if (cen) begin
            // The reference runs one tick ahead of the CPU clock.
            if (!primed) begin
                via_tick();
                primed = 1'b1;
            end
            via_tick();
            // external line edges and the CPU access apply after this
            // cycle's tick, like the reference's between-tick calls
            apply_ca1_edge();
            apply_cb1_edge();
            if (sel) begin
                if (we) via_store(reg_addr, wdata);
                else    via_read_effects(reg_addr);
            end
        end
    end

    assign cb2 = cb2_out;

endmodule
