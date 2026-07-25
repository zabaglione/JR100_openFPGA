//============================================================================
//
//  PS/2 scancode to JR-100 9x5 key matrix (JR100_MiSTer).
//
//  Matrix layout follows pyjr100emu app.py KEY_MATRIX_MAP (the
//  compatibility reference for the PC keymap, AGENTS.md §3.4).
//  ps2_key comes from the MiSTer framework: [10] toggles on every
//  event, [9] = pressed, [8] = extended, [7:0] = set-2 scancode.
//
//  Copyright (C) 2026 Zabaglione
//  SPDX-License-Identifier: GPL-2.0-or-later
//
//============================================================================

module jr100_keyboard
(
    input  logic        clk,
    input  logic        rst,
    input  logic [10:0] ps2_key,
    output logic [44:0] key_matrix   // 9 rows x 5 bits, 1 = pressed
);

    // {valid, row[3:0], col[2:0]}
    function automatic logic [7:0] map_key(input logic [7:0] code);
        case (code)
            8'h21: map_key = {1'b1, 4'd0, 3'd4};   // C
            8'h22: map_key = {1'b1, 4'd0, 3'd3};   // X
            8'h1A: map_key = {1'b1, 4'd0, 3'd2};   // Z
            8'h12: map_key = {1'b1, 4'd0, 3'd1};   // left shift
            8'h59: map_key = {1'b1, 4'd0, 3'd1};   // right shift
            8'h14: map_key = {1'b1, 4'd0, 3'd0};   // ctrl (left/right)
            8'h34: map_key = {1'b1, 4'd1, 3'd4};   // G
            8'h2B: map_key = {1'b1, 4'd1, 3'd3};   // F
            8'h23: map_key = {1'b1, 4'd1, 3'd2};   // D
            8'h1B: map_key = {1'b1, 4'd1, 3'd1};   // S
            8'h1C: map_key = {1'b1, 4'd1, 3'd0};   // A
            8'h2C: map_key = {1'b1, 4'd2, 3'd4};   // T
            8'h2D: map_key = {1'b1, 4'd2, 3'd3};   // R
            8'h24: map_key = {1'b1, 4'd2, 3'd2};   // E
            8'h1D: map_key = {1'b1, 4'd2, 3'd1};   // W
            8'h15: map_key = {1'b1, 4'd2, 3'd0};   // Q
            8'h2E: map_key = {1'b1, 4'd3, 3'd4};   // 5
            8'h25: map_key = {1'b1, 4'd3, 3'd3};   // 4
            8'h26: map_key = {1'b1, 4'd3, 3'd2};   // 3
            8'h1E: map_key = {1'b1, 4'd3, 3'd1};   // 2
            8'h16: map_key = {1'b1, 4'd3, 3'd0};   // 1
            8'h45: map_key = {1'b1, 4'd4, 3'd4};   // 0
            8'h46: map_key = {1'b1, 4'd4, 3'd3};   // 9
            8'h3E: map_key = {1'b1, 4'd4, 3'd2};   // 8
            8'h3D: map_key = {1'b1, 4'd4, 3'd1};   // 7
            8'h36: map_key = {1'b1, 4'd4, 3'd0};   // 6
            8'h4D: map_key = {1'b1, 4'd5, 3'd4};   // P
            8'h44: map_key = {1'b1, 4'd5, 3'd3};   // O
            8'h43: map_key = {1'b1, 4'd5, 3'd2};   // I
            8'h3C: map_key = {1'b1, 4'd5, 3'd1};   // U
            8'h35: map_key = {1'b1, 4'd5, 3'd0};   // Y
            8'h4C: map_key = {1'b1, 4'd6, 3'd4};   // ;
            8'h4B: map_key = {1'b1, 4'd6, 3'd3};   // L
            8'h42: map_key = {1'b1, 4'd6, 3'd2};   // K
            8'h3B: map_key = {1'b1, 4'd6, 3'd1};   // J
            8'h33: map_key = {1'b1, 4'd6, 3'd0};   // H
            8'h41: map_key = {1'b1, 4'd7, 3'd4};   // ,
            8'h3A: map_key = {1'b1, 4'd7, 3'd3};   // M
            8'h31: map_key = {1'b1, 4'd7, 3'd2};   // N
            8'h32: map_key = {1'b1, 4'd7, 3'd1};   // B
            8'h2A: map_key = {1'b1, 4'd7, 3'd0};   // V
            8'h4E: map_key = {1'b1, 4'd8, 3'd4};   // -
            8'h5A: map_key = {1'b1, 4'd8, 3'd3};   // Enter
            8'h52: map_key = {1'b1, 4'd8, 3'd2};   // : (JIS colon / ANSI quote)
            8'h29: map_key = {1'b1, 4'd8, 3'd1};   // Space
            8'h49: map_key = {1'b1, 4'd8, 3'd0};   // .
            default: map_key = 8'h00;
        endcase
    endfunction

    logic old_toggle;

    always_ff @(posedge clk) begin
        if (rst) begin
            key_matrix <= '0;
            old_toggle <= ps2_key[10];
        end else begin
            old_toggle <= ps2_key[10];
            if (old_toggle != ps2_key[10]) begin
                logic [7:0] m;
                m = map_key(ps2_key[7:0]);
                if (m[7]) begin
                    key_matrix[{2'b0, m[6:3]} * 5 + {3'b0, m[2:0]}] <= ps2_key[9];
                end
            end
        end
    end

endmodule
