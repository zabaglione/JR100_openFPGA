//============================================================================
//
//  Virtual keyboard overlay renderer (combinational, scanout domain).
//
//  Draws a 240x70 keyboard panel over the bottom of the 320x240 active
//  area: four rows of ten 24x14 cells and one row of five 48x14 cells,
//  mirroring the JR-100's own key rows. Labels come from jr100_vkb_font.
//
//  The cursor cell is amber, turning orange while its key is pressed;
//  the SHIFT/CTL cells turn green while their modifier is held.
//
//  All inputs are quasi-static (they change at human speed), so they are
//  synchronised into the scanout clock outside this module and any
//  single-frame incoherence is invisible.
//
//  Copyright (C) 2026 Zabaglione
//  SPDX-License-Identifier: GPL-2.0-or-later
//
//============================================================================

`default_nettype none

module jr100_vkb_overlay (
    input  wire [9:0]  vx,          // active-area coordinates (0..319, 0..239)
    input  wire [9:0]  vy,
    input  wire        in_active,

    input  wire        active,
    input  wire [2:0]  cur_row,
    input  wire [3:0]  cur_col,
    input  wire        pressed,
    input  wire        shift_held,
    input  wire        ctl_held,

    output wire        hit,
    output reg  [23:0] rgb
);

    localparam [9:0] X0 = 10'd40;
    localparam [9:0] Y0 = 10'd166;

    wire [9:0] ox = vx - X0;                    // 0..239
    wire [9:0] oy = vy - Y0;                    // 0..69

    wire in_box = in_active && active &&
                  (vx >= X0) && (vx < X0 + 10'd240) &&
                  (vy >= Y0) && (vy < Y0 + 10'd70);
    assign hit = in_box;

    // row: five 14-pixel bands
    wire [2:0] vrow = (oy < 10'd14) ? 3'd0 :
                      (oy < 10'd28) ? 3'd1 :
                      (oy < 10'd42) ? 3'd2 :
                      (oy < 10'd56) ? 3'd3 : 3'd4;
    wire [9:0] row_base = (vrow == 3'd0) ? 10'd0  :
                          (vrow == 3'd1) ? 10'd14 :
                          (vrow == 3'd2) ? 10'd28 :
                          (vrow == 3'd3) ? 10'd42 : 10'd56;
    wire [9:0] ly = oy - row_base;               // 0..13 inside the cell

    // column: ten 24-pixel cells (rows 0-3) or five 48-pixel cells (row 4)
    wire [3:0] col24 = (ox < 10'd24)  ? 4'd0 :
                       (ox < 10'd48)  ? 4'd1 :
                       (ox < 10'd72)  ? 4'd2 :
                       (ox < 10'd96)  ? 4'd3 :
                       (ox < 10'd120) ? 4'd4 :
                       (ox < 10'd144) ? 4'd5 :
                       (ox < 10'd168) ? 4'd6 :
                       (ox < 10'd192) ? 4'd7 :
                       (ox < 10'd216) ? 4'd8 : 4'd9;
    wire [3:0] col48 = (ox < 10'd48)  ? 4'd0 :
                       (ox < 10'd96)  ? 4'd1 :
                       (ox < 10'd144) ? 4'd2 :
                       (ox < 10'd192) ? 4'd3 : 4'd4;

    wire       wide = (vrow == 3'd4);
    wire [3:0] vcol = wide ? col48 : col24;

    // x inside the cell: ox - col*24 or ox - col*48
    wire [9:0] cell_x0 = wide ? (({6'd0, col48} << 5) + ({6'd0, col48} << 4))
                              : (({6'd0, col24} << 4) + ({6'd0, col24} << 3));
    wire [9:0] lx = ox - cell_x0;

    // ------------------------------------------------------------------
    // Labels
    // ------------------------------------------------------------------
    // codes: 0 blank, 1-26 A-Z, 27-36 0-9, 37 ';' 38 ',' 39 '.' 40 ':' 41 '-'
    function automatic [5:0] label0(input [2:0] vr, input [3:0] vc);
        case (vr)
            3'd0: label0 = (vc == 4'd9) ? 6'd27 : (6'd28 + {2'd0, vc}); // 1..9,0
            3'd1: case (vc)
                4'd0: label0 = 6'd17;  // Q
                4'd1: label0 = 6'd23;  // W
                4'd2: label0 = 6'd5;   // E
                4'd3: label0 = 6'd18;  // R
                4'd4: label0 = 6'd20;  // T
                4'd5: label0 = 6'd25;  // Y
                4'd6: label0 = 6'd21;  // U
                4'd7: label0 = 6'd9;   // I
                4'd8: label0 = 6'd15;  // O
                default: label0 = 6'd16; // P
            endcase
            3'd2: case (vc)
                4'd0: label0 = 6'd1;   // A
                4'd1: label0 = 6'd19;  // S
                4'd2: label0 = 6'd4;   // D
                4'd3: label0 = 6'd6;   // F
                4'd4: label0 = 6'd7;   // G
                4'd5: label0 = 6'd8;   // H
                4'd6: label0 = 6'd10;  // J
                4'd7: label0 = 6'd11;  // K
                4'd8: label0 = 6'd12;  // L
                default: label0 = 6'd37; // ;
            endcase
            default: case (vc)
                4'd0: label0 = 6'd26;  // Z
                4'd1: label0 = 6'd24;  // X
                4'd2: label0 = 6'd3;   // C
                4'd3: label0 = 6'd22;  // V
                4'd4: label0 = 6'd2;   // B
                4'd5: label0 = 6'd14;  // N
                4'd6: label0 = 6'd13;  // M
                4'd7: label0 = 6'd38;  // ,
                4'd8: label0 = 6'd39;  // .
                default: label0 = 6'd40; // :
            endcase
        endcase
    endfunction

    // row-4 labels: CTL / SHFT / SPC / - / RET, up to four glyphs
    function automatic [5:0] label4(input [3:0] vc, input [1:0] idx);
        case (vc)
            4'd0: case (idx)                     // CTL
                2'd0: label4 = 6'd3;   // C
                2'd1: label4 = 6'd20;  // T
                2'd2: label4 = 6'd12;  // L
                default: label4 = 6'd0;
            endcase
            4'd1: case (idx)                     // SHFT
                2'd0: label4 = 6'd19;  // S
                2'd1: label4 = 6'd8;   // H
                2'd2: label4 = 6'd6;   // F
                default: label4 = 6'd20; // T
            endcase
            4'd2: case (idx)                     // SPC
                2'd0: label4 = 6'd19;  // S
                2'd1: label4 = 6'd16;  // P
                2'd2: label4 = 6'd3;   // C
                default: label4 = 6'd0;
            endcase
            4'd3: label4 = (idx == 2'd0) ? 6'd41 : 6'd0;  // -
            default: case (idx)                  // RET
                2'd0: label4 = 6'd18;  // R
                2'd1: label4 = 6'd5;   // E
                2'd2: label4 = 6'd20;  // T
                default: label4 = 6'd0;
            endcase
        endcase
    endfunction

    // glyph origin inside the cell
    wire [9:0] text_x0  = wide ? ((vcol == 4'd1) ? 10'd8 :        // SHFT (4 ch)
                                  (vcol == 4'd3) ? 10'd20 :       // -    (1 ch)
                                                   10'd12)        // 3 ch
                               : 10'd8;                           // 1 ch centred
    wire [9:0] gx    = lx - text_x0;
    wire       gvalid = (ly >= 10'd3) && (ly < 10'd11) &&
                        (gx < (wide ? 10'd32 : 10'd8));
    wire [1:0] gidx  = gx[4:3];                  // glyph number in the cell
    wire [2:0] gcol  = gx[2:0];
    wire [3:0] grow4 = ly[3:0] - 4'd3;           // ly is 3..10 while gvalid
    wire [2:0] grow  = grow4[2:0];

    wire [5:0] code = wide ? label4(vcol, gidx) : label0(vrow, vcol);
    wire [7:0] font_bits;

    jr100_vkb_font font (
        .code ( gvalid ? code : 6'd0 ),
        .row  ( grow ),
        .bits ( font_bits )
    );

    wire glyph_on = gvalid && font_bits[3'd7 - gcol];

    // ------------------------------------------------------------------
    // Colours
    // ------------------------------------------------------------------
    wire is_cursor = (vrow == cur_row) && (vcol == cur_col);
    wire is_shift  = (vrow == 3'd4) && (vcol == 4'd1);
    wire is_ctl    = (vrow == 3'd4) && (vcol == 4'd0);

    wire in_gap = (lx == 10'd0) || (lx == (wide ? 10'd47 : 10'd23)) ||
                  (ly == 10'd0) || (ly == 10'd13);

    wire [23:0] cell_bg = (is_cursor && pressed)     ? 24'hFF5010 :
                          is_cursor                  ? 24'hF0C000 :
                          (is_shift && shift_held)   ? 24'h00A040 :
                          (is_ctl   && ctl_held)     ? 24'h00A040 :
                                                       24'h283048;
    wire highlighted = is_cursor || (is_shift && shift_held) ||
                       (is_ctl && ctl_held);

    always @(*) begin
        if (in_gap)
            rgb = 24'h101018;
        else if (glyph_on)
            rgb = highlighted ? 24'h000000 : 24'hFFFFFF;
        else
            rgb = cell_bg;
    end

endmodule

`default_nettype wire
