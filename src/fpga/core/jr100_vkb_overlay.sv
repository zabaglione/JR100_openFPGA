//============================================================================
//
//  Virtual keyboard overlay renderer (scanout domain, one-pixel pipeline).
//
//  Draws a 240x70 keyboard panel over the bottom of the 320x240 active
//  area: four rows of ten 24x14 cells and one row of five 48x14 cells,
//  mirroring the JR-100's own key rows.
//
//  Labels are drawn with the machine's own character generator: core_top
//  shadows the first 1 KiB of the boot.rom stream into the dual-clock BRAM
//  inside this module, so every legend - letters, symbols, card suits,
//  semigraphics - is pixel-identical to what the machine will type.
//
//  The label planes follow the ROM's measured behaviour (docs/KEYBOARD.md):
//      normal  : the keycap character
//      shift   : the ROM's shift table; keys it maps to nothing go blank
//      graph   : same codes with bit 6 set (the ROM's own GRAPH rule),
//                so GRAPH+SHIFT on the digits shows the card suits
//  Until the ROM has loaded, the shadow BRAM is zero and labels are blank.
//
//  The BRAM read costs one clock, so the module is fed NEXT-pixel
//  coordinates and registers everything else one stage to match; outputs
//  line up with the caller's current pixel exactly like the framebuffer
//  prefetch in core_top.
//
//  Copyright (C) 2026 Zabaglione
//  SPDX-License-Identifier: GPL-2.0-or-later
//
//============================================================================

`default_nettype none

module jr100_vkb_overlay (
    input  wire        clk,          // scanout clock (12.288 MHz)

    input  wire [9:0]  nx,           // NEXT pixel, active-area coords
    input  wire [9:0]  ny,
    input  wire        in_active_n,  // next pixel is inside the active area

    input  wire        active,
    input  wire [2:0]  cur_row,
    input  wire [3:0]  cur_col,
    input  wire        pressed,
    input  wire        shift_held,
    input  wire        ctl_held,
    input  wire        graph_mode,

    // shadow character-ROM write port (clk_sys domain, boot.rom bytes)
    input  wire        crom_clk,
    input  wire        crom_wr,
    input  wire [9:0]  crom_addr,
    input  wire [7:0]  crom_data,

    output reg         hit,
    output reg  [23:0] rgb
);

    localparam [9:0] X0 = 10'd40;
    localparam [9:0] Y0 = 10'd166;

    wire [9:0] ox = nx - X0;                    // 0..239
    wire [9:0] oy = ny - Y0;                    // 0..69

    wire in_box = in_active_n && active &&
                  (nx >= X0) && (nx < X0 + 10'd240) &&
                  (ny >= Y0) && (ny < Y0 + 10'd70);

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

    wire [9:0] cell_x0 = wide ? (({6'd0, col48} << 5) + ({6'd0, col48} << 4))
                              : (({6'd0, col24} << 4) + ({6'd0, col24} << 3));
    wire [9:0] lx = ox - cell_x0;

    // ------------------------------------------------------------------
    // Labels as JR-100 display codes (character-generator indices).
    //
    // Base codes measured from the ROM (docs/KEYBOARD.md). Zero = blank.
    // ------------------------------------------------------------------
    function automatic [6:0] base_code(input [2:0] vr, input [3:0] vc,
                                       input shifted);
        case (vr)
            // 1 2 3 4 5 6 7 8 9 0  /  ! " # $ % & ' ( ) ^
            3'd0: base_code = shifted ? ((vc == 4'd9) ? 7'h3E
                                                      : (7'h01 + {3'd0, vc}))
                                      : ((vc == 4'd9) ? 7'h10
                                                      : (7'h11 + {3'd0, vc}));
            // Q W E R T Y U I O P  /  . . . . . . @ yen [ ]
            3'd1: case (vc)
                4'd0: base_code = shifted ? 7'h00 : 7'h31;  // Q
                4'd1: base_code = shifted ? 7'h00 : 7'h37;  // W
                4'd2: base_code = shifted ? 7'h00 : 7'h25;  // E
                4'd3: base_code = shifted ? 7'h00 : 7'h32;  // R
                4'd4: base_code = shifted ? 7'h00 : 7'h34;  // T
                4'd5: base_code = shifted ? 7'h00 : 7'h39;  // Y
                4'd6: base_code = shifted ? 7'h20 : 7'h35;  // U  -> @
                4'd7: base_code = shifted ? 7'h3C : 7'h29;  // I  -> yen
                4'd8: base_code = shifted ? 7'h3B : 7'h2F;  // O  -> [
                default: base_code = shifted ? 7'h3D : 7'h30; // P -> ]
            endcase
            // A S D F G H J K L ;  /  . . . . . . . ? / +
            3'd2: case (vc)
                4'd0: base_code = shifted ? 7'h00 : 7'h21;  // A
                4'd1: base_code = shifted ? 7'h00 : 7'h33;  // S
                4'd2: base_code = shifted ? 7'h00 : 7'h24;  // D
                4'd3: base_code = shifted ? 7'h00 : 7'h26;  // F
                4'd4: base_code = shifted ? 7'h00 : 7'h27;  // G
                4'd5: base_code = shifted ? 7'h00 : 7'h28;  // H
                4'd6: base_code = shifted ? 7'h00 : 7'h2A;  // J
                4'd7: base_code = shifted ? 7'h1F : 7'h2B;  // K  -> ?
                4'd8: base_code = shifted ? 7'h0F : 7'h2C;  // L  -> /
                default: base_code = shifted ? 7'h0B : 7'h1B; // ; -> +
            endcase
            // Z X C V B N M , . :  /  . . . . . . _ < > *
            3'd3: case (vc)
                4'd0: base_code = shifted ? 7'h00 : 7'h3A;  // Z
                4'd1: base_code = shifted ? 7'h00 : 7'h38;  // X
                4'd2: base_code = shifted ? 7'h00 : 7'h23;  // C
                4'd3: base_code = shifted ? 7'h00 : 7'h36;  // V
                4'd4: base_code = shifted ? 7'h00 : 7'h22;  // B
                4'd5: base_code = shifted ? 7'h00 : 7'h2E;  // N
                4'd6: base_code = shifted ? 7'h3F : 7'h2D;  // M  -> _
                4'd7: base_code = shifted ? 7'h1C : 7'h0C;  // ,  -> <
                4'd8: base_code = shifted ? 7'h1E : 7'h0E;  // .  -> >
                default: base_code = shifted ? 7'h0A : 7'h1A; // : -> *
            endcase
            default: base_code = 7'h00;  // row 4 handled by label4
        endcase
    endfunction

    // row-4 labels: CTL / SHFT / SPC / - / RET as display-code letters
    function automatic [6:0] label4(input [3:0] vc, input [1:0] idx,
                                    input shifted);
        case (vc)
            4'd0: case (idx)                     // CTL
                2'd0: label4 = 7'h23;  // C
                2'd1: label4 = 7'h34;  // T
                2'd2: label4 = 7'h2C;  // L
                default: label4 = 7'h00;
            endcase
            4'd1: case (idx)                     // SHFT
                2'd0: label4 = 7'h33;  // S
                2'd1: label4 = 7'h28;  // H
                2'd2: label4 = 7'h26;  // F
                default: label4 = 7'h34; // T
            endcase
            4'd2: case (idx)                     // SPC
                2'd0: label4 = 7'h33;  // S
                2'd1: label4 = 7'h30;  // P
                2'd2: label4 = 7'h23;  // C
                default: label4 = 7'h00;
            endcase
            4'd3: label4 = (idx == 2'd0) ? (shifted ? 7'h1D : 7'h0D)
                                         : 7'h00;  // -  ->  =
            default: case (idx)                  // RET
                2'd0: label4 = 7'h32;  // R
                2'd1: label4 = 7'h25;  // E
                2'd2: label4 = 7'h34;  // T
                default: label4 = 7'h00;
            endcase
        endcase
    endfunction

    // With CTL held before GRAPH is entered, the V key shows "GR" - the one
    // non-obvious combination (CTRL+V toggles the ROM's GRAPH mode).
    wire v_gr = ctl_held && !wide && (vrow == 3'd3) && (vcol == 4'd3);

    // glyph origin inside the cell
    wire [9:0] text_x0  = wide ? ((vcol == 4'd1) ? 10'd8 :        // SHFT (4 ch)
                                  (vcol == 4'd3) ? 10'd20 :       // -    (1 ch)
                                                   10'd12)        // 3 ch
                               : (v_gr ? 10'd4 : 10'd8);          // 2 ch / 1 ch
    wire [9:0] gx    = lx - text_x0;
    wire       gvalid = (ly >= 10'd3) && (ly < 10'd11) &&
                        (gx < (wide ? 10'd32 : v_gr ? 10'd16 : 10'd8));
    wire [1:0] gidx  = gx[4:3];
    wire [2:0] gcol  = gx[2:0];
    wire [3:0] grow4 = ly[3:0] - 4'd3;
    wire [2:0] grow  = grow4[2:0];

    // plane selection: the '-' key cell is a real key, so it follows the
    // GRAPH rule too; the CTL/SHFT/SPC/RET name labels do not.
    wire [6:0] base = wide ? label4(vcol, gidx, shift_held) :
                      v_gr ? ((gidx == 2'd0) ? 7'h27 : 7'h32) :  // G, R
                             base_code(vrow, vcol, shift_held);
    wire       graph_applies = (base != 7'h00) &&
                               (!wide || (vcol == 4'd3)) && !v_gr;
    wire [6:0] code = (graph_mode && graph_applies) ? (base | 7'h40) : base;

    // ------------------------------------------------------------------
    // Shadow character generator: written with boot.rom bytes on the
    // machine clock, read here every pixel.
    // ------------------------------------------------------------------
    wire [7:0] glyph_q;

bram_block_dp #(
    .DATA ( 8 ),
    .ADDR ( 10 )
) shadow_crom (
    .a_clk  ( crom_clk ),
    .a_wr   ( crom_wr ),
    .a_addr ( crom_addr ),
    .a_din  ( crom_data ),
    .a_dout (  ),

    .b_clk  ( clk ),
    .b_wr   ( 1'b0 ),
    .b_addr ( {code, grow} ),
    .b_din  ( 8'd0 ),
    .b_dout ( glyph_q )
);

    // ------------------------------------------------------------------
    // Colours (computed for the next pixel, registered one stage)
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
                          graph_mode                 ? 24'h383060 :
                                                       24'h283048;
    wire highlighted = is_cursor || (is_shift && shift_held) ||
                       (is_ctl && ctl_held);

    reg         hit_d, gap_d, gvalid_d, hl_d;
    reg  [2:0]  gcol_d;
    reg  [23:0] bg_d;

always @(posedge clk) begin
    hit_d    <= in_box;
    gap_d    <= in_gap;
    gvalid_d <= gvalid;
    hl_d     <= highlighted;
    gcol_d   <= gcol;
    bg_d     <= cell_bg;
end

    wire glyph_on = gvalid_d && glyph_q[3'd7 - gcol_d];

always @(*) begin
    hit = hit_d;
    if (gap_d)
        rgb = 24'h101018;
    else if (glyph_on)
        rgb = hl_d ? 24'h000000 : 24'hFFFFFF;
    else
        rgb = bg_d;
end

endmodule

`default_nettype wire
