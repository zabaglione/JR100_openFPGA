//============================================================================
//
//  Analogue Pocket inputs -> JR-100 key matrix and joystick.
//
//  Runs in the 57.27 MHz machine domain; the cont* buses (clk_74a domain)
//  are synchronised on entry and the dock keyboard fields additionally pass
//  a two-consecutive-samples stability filter before they are decoded.
//
//  Two sources feed the 45-bit key matrix (9 rows x 5 cols, index row*5+col,
//  same encoding as jr100_keyboard.sv):
//
//  1. Dock USB keyboard. APF delivers HID boot-keyboard reports on cont3:
//     modifier byte in cont3_key[15:8], six key usage codes packed in
//     cont3_joy and cont3_trig. Because the matrix is level-based, the
//     currently-pressed set decodes combinationally - no PS/2 event
//     synthesis, no edge tracking.
//
//  2. Virtual keyboard. Select toggles it; the D-pad moves the cursor with
//     auto-repeat, A presses the key under the cursor, B is Space, X is
//     Return, L1 holds Shift and R1 holds Ctrl. While it is open the
//     joystick is masked so navigation does not leak into games.
//
//  The visual grid mirrors the real JR-100 rows:
//      1 2 3 4 5 6 7 8 9 0
//      Q W E R T Y U I O P
//      A S D F G H J K L ;
//      Z X C V B N M , . :
//      CTL SHFT SPC - RET     (five double-width cells)
//
//  Copyright (C) 2026 Zabaglione
//  SPDX-License-Identifier: GPL-2.0-or-later
//
//============================================================================

`default_nettype none

module jr100_pocket_input (
    input  wire        clk,          // 57.27 MHz machine clock
    input  wire        rst,

    // clk_74a domain, synchronised here
    input  wire [31:0] cont1_key,
    input  wire [31:0] cont3_key,
    input  wire [31:0] cont3_joy,
    input  wire [15:0] cont3_trig,

    output reg  [44:0] key_matrix,   // 1 = pressed
    output reg  [7:0]  joy_status,   // CC02: bit0 R, 1 L, 2 U, 3 D, 4 fire

    // virtual keyboard state for the overlay renderer
    output reg         vkb_active,
    output reg  [2:0]  vkb_row,      // 0..4 visual grid row
    output reg  [3:0]  vkb_col,      // 0..9 (rows 0-3) / 0..4 (row 4)
    output wire        vkb_pressed,
    output wire        vkb_shift,
    output wire        vkb_ctl
);

    // ------------------------------------------------------------------
    // Synchronisers
    // ------------------------------------------------------------------
    wire [15:0] btn;
    wire [7:0]  hid_mods_raw;
    wire [47:0] hid_codes_raw;

    synch_3 #(.WIDTH(16)) s_cont1 (cont1_key[15:0], btn, clk);
    synch_3 #(.WIDTH(8))  s_mods  (cont3_key[15:8], hid_mods_raw, clk);
    synch_3 #(.WIDTH(48)) s_codes ({cont3_joy, cont3_trig}, hid_codes_raw, clk);

    // Multi-bit fields cross the domain unaligned, so only accept a dock
    // keyboard sample once two consecutive synchronised values agree.
    reg [7:0]  hid_mods_prev,  hid_mods;
    reg [47:0] hid_codes_prev, hid_codes;
    always @(posedge clk) begin
        hid_mods_prev  <= hid_mods_raw;
        hid_codes_prev <= hid_codes_raw;
        if (hid_mods_raw  == hid_mods_prev)  hid_mods  <= hid_mods_raw;
        if (hid_codes_raw == hid_codes_prev) hid_codes <= hid_codes_raw;
    end

    // Button indices per the APF key bitmap
    localparam BTN_UP = 0, BTN_DOWN = 1, BTN_LEFT = 2, BTN_RIGHT = 3;
    localparam BTN_A = 4, BTN_B = 5, BTN_X = 6, BTN_Y = 7;
    localparam BTN_L1 = 8, BTN_R1 = 9, BTN_SELECT = 14;

    reg [15:0] btn_q;
    always @(posedge clk) btn_q <= btn;
    wire [15:0] btn_edge = btn & ~btn_q;

    // ------------------------------------------------------------------
    // HID usage code -> matrix position ({valid, row[3:0], col[2:0]})
    // ------------------------------------------------------------------
    function automatic [7:0] hid_map(input [7:0] code);
        case (code)
            8'h04: hid_map = {1'b1, 4'd1, 3'd0};   // A
            8'h05: hid_map = {1'b1, 4'd7, 3'd1};   // B
            8'h06: hid_map = {1'b1, 4'd0, 3'd4};   // C
            8'h07: hid_map = {1'b1, 4'd1, 3'd2};   // D
            8'h08: hid_map = {1'b1, 4'd2, 3'd2};   // E
            8'h09: hid_map = {1'b1, 4'd1, 3'd3};   // F
            8'h0A: hid_map = {1'b1, 4'd1, 3'd4};   // G
            8'h0B: hid_map = {1'b1, 4'd6, 3'd0};   // H
            8'h0C: hid_map = {1'b1, 4'd5, 3'd2};   // I
            8'h0D: hid_map = {1'b1, 4'd6, 3'd1};   // J
            8'h0E: hid_map = {1'b1, 4'd6, 3'd2};   // K
            8'h0F: hid_map = {1'b1, 4'd6, 3'd3};   // L
            8'h10: hid_map = {1'b1, 4'd7, 3'd3};   // M
            8'h11: hid_map = {1'b1, 4'd7, 3'd2};   // N
            8'h12: hid_map = {1'b1, 4'd5, 3'd3};   // O
            8'h13: hid_map = {1'b1, 4'd5, 3'd4};   // P
            8'h14: hid_map = {1'b1, 4'd2, 3'd0};   // Q
            8'h15: hid_map = {1'b1, 4'd2, 3'd3};   // R
            8'h16: hid_map = {1'b1, 4'd1, 3'd1};   // S
            8'h17: hid_map = {1'b1, 4'd2, 3'd4};   // T
            8'h18: hid_map = {1'b1, 4'd5, 3'd1};   // U
            8'h19: hid_map = {1'b1, 4'd7, 3'd0};   // V
            8'h1A: hid_map = {1'b1, 4'd2, 3'd1};   // W
            8'h1B: hid_map = {1'b1, 4'd0, 3'd3};   // X
            8'h1C: hid_map = {1'b1, 4'd5, 3'd0};   // Y
            8'h1D: hid_map = {1'b1, 4'd0, 3'd2};   // Z
            8'h1E: hid_map = {1'b1, 4'd3, 3'd0};   // 1
            8'h1F: hid_map = {1'b1, 4'd3, 3'd1};   // 2
            8'h20: hid_map = {1'b1, 4'd3, 3'd2};   // 3
            8'h21: hid_map = {1'b1, 4'd3, 3'd3};   // 4
            8'h22: hid_map = {1'b1, 4'd3, 3'd4};   // 5
            8'h23: hid_map = {1'b1, 4'd4, 3'd0};   // 6
            8'h24: hid_map = {1'b1, 4'd4, 3'd1};   // 7
            8'h25: hid_map = {1'b1, 4'd4, 3'd2};   // 8
            8'h26: hid_map = {1'b1, 4'd4, 3'd3};   // 9
            8'h27: hid_map = {1'b1, 4'd4, 3'd4};   // 0
            8'h28: hid_map = {1'b1, 4'd8, 3'd3};   // Enter  -> RETURN
            8'h2C: hid_map = {1'b1, 4'd8, 3'd1};   // Space
            8'h2D: hid_map = {1'b1, 4'd8, 3'd4};   // -
            8'h33: hid_map = {1'b1, 4'd6, 3'd4};   // ;
            8'h34: hid_map = {1'b1, 4'd8, 3'd2};   // ' (JIS :) -> colon
            8'h36: hid_map = {1'b1, 4'd7, 3'd4};   // ,
            8'h37: hid_map = {1'b1, 4'd8, 3'd0};   // .
            default: hid_map = 8'h00;
        endcase
    endfunction

    // ------------------------------------------------------------------
    // Virtual keyboard grid -> matrix index (row*5 + col)
    // ------------------------------------------------------------------
    function automatic [5:0] vkb_target(input [2:0] vr, input [3:0] vc);
        case (vr)
            3'd0: vkb_target = (vc < 4'd5) ? (6'd15 + {2'd0, vc})        // 1-5
                                           : (6'd20 + {2'd0, vc} - 6'd5); // 6-0
            3'd1: vkb_target = (vc < 4'd5) ? (6'd10 + {2'd0, vc})        // Q-T
                                           : (6'd25 + {2'd0, vc} - 6'd5); // Y-P
            3'd2: vkb_target = (vc < 4'd5) ? (6'd5  + {2'd0, vc})        // A-G
                                           : (6'd30 + {2'd0, vc} - 6'd5); // H-;
            3'd3: case (vc)
                4'd0: vkb_target = 6'd2;    // Z (0,2)
                4'd1: vkb_target = 6'd3;    // X (0,3)
                4'd2: vkb_target = 6'd4;    // C (0,4)
                4'd3: vkb_target = 6'd35;   // V (7,0)
                4'd4: vkb_target = 6'd36;   // B (7,1)
                4'd5: vkb_target = 6'd37;   // N (7,2)
                4'd6: vkb_target = 6'd38;   // M (7,3)
                4'd7: vkb_target = 6'd39;   // , (7,4)
                4'd8: vkb_target = 6'd40;   // . (8,0)
                default: vkb_target = 6'd42; // : (8,2)
            endcase
            default: case (vc)
                4'd0: vkb_target = 6'd0;    // CTL   (0,0)
                4'd1: vkb_target = 6'd1;    // SHIFT (0,1)
                4'd2: vkb_target = 6'd41;   // SPACE (8,1)
                4'd3: vkb_target = 6'd44;   // -     (8,4)
                default: vkb_target = 6'd43; // RETURN (8,3)
            endcase
        endcase
    endfunction

    // ------------------------------------------------------------------
    // Virtual keyboard state: toggle, cursor, auto-repeat
    // ------------------------------------------------------------------
    // 300 ms initial delay / 70 ms repeat at 57.272727 MHz
    localparam [24:0] REPEAT_INITIAL = 25'd17_181_818;
    localparam [24:0] REPEAT_RATE    = 25'd4_009_091;

    reg [24:0] repeat_cnt;
    wire       any_dir  = vkb_active &&
                          (btn[BTN_UP] | btn[BTN_DOWN] |
                           btn[BTN_LEFT] | btn[BTN_RIGHT]);
    wire       dir_edge = btn_edge[BTN_UP] | btn_edge[BTN_DOWN] |
                          btn_edge[BTN_LEFT] | btn_edge[BTN_RIGHT];
    wire       repeat_fire = any_dir && (repeat_cnt == REPEAT_INITIAL);
    wire       move = vkb_active && (dir_edge || repeat_fire);

    wire [3:0] col_max = (vkb_row == 3'd4) ? 4'd4 : 4'd9;

    always @(posedge clk) begin
        if (rst) begin
            vkb_active <= 1'b0;
            vkb_row    <= 3'd1;
            vkb_col    <= 4'd0;
            repeat_cnt <= 25'd0;
        end else begin
            if (btn_edge[BTN_SELECT])
                vkb_active <= ~vkb_active;

            if (!any_dir || dir_edge)
                repeat_cnt <= 25'd0;
            else if (repeat_cnt == REPEAT_INITIAL)
                repeat_cnt <= REPEAT_INITIAL - REPEAT_RATE;
            else
                repeat_cnt <= repeat_cnt + 25'd1;

            if (move) begin
                // priority up > down > left > right
                if (btn[BTN_UP]) begin
                    if (vkb_row == 3'd0) begin
                        vkb_row <= 3'd4;
                        vkb_col <= {1'b0, vkb_col[3:1]};        // /2
                    end else begin
                        vkb_row <= vkb_row - 3'd1;
                        if (vkb_row == 3'd4)
                            vkb_col <= {vkb_col[2:0], 1'b0};    // *2
                    end
                end else if (btn[BTN_DOWN]) begin
                    if (vkb_row == 3'd4) begin
                        vkb_row <= 3'd0;
                        vkb_col <= {vkb_col[2:0], 1'b0};        // *2
                    end else begin
                        vkb_row <= vkb_row + 3'd1;
                        if (vkb_row == 3'd3)
                            vkb_col <= {1'b0, vkb_col[3:1]};    // /2
                    end
                end else if (btn[BTN_LEFT]) begin
                    vkb_col <= (vkb_col == 4'd0) ? col_max : vkb_col - 4'd1;
                end else if (btn[BTN_RIGHT]) begin
                    vkb_col <= (vkb_col == col_max) ? 4'd0 : vkb_col + 4'd1;
                end
            end
        end
    end

    assign vkb_pressed = vkb_active & btn[BTN_A];
    assign vkb_shift   = vkb_active & btn[BTN_L1];
    assign vkb_ctl     = vkb_active & btn[BTN_R1];

    // ------------------------------------------------------------------
    // Matrix assembly and joystick
    // ------------------------------------------------------------------
    reg [44:0] hid_matrix;
    integer i;
    reg [7:0] m;
    always @(*) begin
        hid_matrix = 45'd0;
        if (hid_mods[0] | hid_mods[4]) hid_matrix[0] = 1'b1;   // Ctrl
        if (hid_mods[1] | hid_mods[5]) hid_matrix[1] = 1'b1;   // Shift
        for (i = 0; i < 6; i = i + 1) begin
            m = hid_map(hid_codes[i*8 +: 8]);
            if (m[7])
                hid_matrix[{2'b0, m[6:3]} * 5 + {3'b0, m[2:0]}] = 1'b1;
        end
    end

    reg [44:0] vkb_matrix;
    always @(*) begin
        vkb_matrix = 45'd0;
        if (vkb_active) begin
            if (btn[BTN_A])  vkb_matrix[vkb_target(vkb_row, vkb_col)] = 1'b1;
            if (btn[BTN_B])  vkb_matrix[41] = 1'b1;   // SPACE
            if (btn[BTN_X])  vkb_matrix[43] = 1'b1;   // RETURN
            if (btn[BTN_L1]) vkb_matrix[1]  = 1'b1;   // SHIFT
            if (btn[BTN_R1]) vkb_matrix[0]  = 1'b1;   // CTL
        end
    end

    always @(posedge clk) begin
        if (rst) begin
            key_matrix <= 45'd0;
            joy_status <= 8'd0;
        end else begin
            key_matrix <= hid_matrix | vkb_matrix;
            joy_status <= vkb_active ? 8'd0
                                     : {3'b000,
                                        btn[BTN_A],       // fire
                                        btn[BTN_DOWN],    // down
                                        btn[BTN_UP],      // up
                                        btn[BTN_LEFT],    // left
                                        btn[BTN_RIGHT]};  // right
        end
    end

endmodule

`default_nettype wire
