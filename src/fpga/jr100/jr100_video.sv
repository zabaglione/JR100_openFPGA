//============================================================================
//
//  JR-100 character video pipeline (JR100_MiSTer)
//
//  32x24 characters, 8x8 glyphs, 256x192 active pixels, monochrome.
//  Glyph source rules (pyjr100emu display.py + real-hardware shared
//  CGRAM per AGENTS.md §3.3):
//    code < 0x80              : character ROM  E000 + code*8 + line
//    code >= 0x80, font normal: character ROM glyph, inverted
//    0x80-0x9F,   font user   : CGRAM  C000 + (code-0x80)*8 + line
//    0xA0-0xFF,   font user   : VRAM   C100 + (code-0xA0)*8 + line
//                               (shared-VRAM glyphs; real-hardware
//                               behaviour, not present in pyjr100emu)
//  Bit 7 of the glyph byte is the leftmost pixel.
//
//  Memory access: one combinational read port into the unified address
//  space (VRAM/CGRAM/char ROM), two fetch slots per 8-pixel cell
//  (code at phase 6, glyph byte at phase 7, shifter load at phase 0).
//  In the MiSTer core this becomes the second port of dual-port BRAMs.
//
//  Frame timing follows the real machine (JR-100 technical material,
//  asamomiji.jp): dot clock 7.15909 MHz (14.31818/2), 448 dots/line
//  (fH = 15.980 kHz), 256 lines/frame (fV = 62.4 Hz), H sync 64 dots,
//  V sync 8 lines. The output is deliberately NOT NTSC standard; the
//  real machine's composite output uses this custom format. Blanking
//  porch splits around the sync pulses are estimated (the material
//  gives rates and pulse widths, not porch positions).
//
//  Copyright (C) 2026 Zabaglione
//  SPDX-License-Identifier: GPL-2.0-or-later
//
//============================================================================

module jr100_video
(
    input  logic        clk,
    input  logic        rst,
    input  logic        cen_pix,

    input  logic        font_user,   // VIA Port B bit 5 view

    // combinational read port into the shared address space
    output logic [15:0] vid_addr,
    input  logic [7:0]  vid_rdata,

    output logic        pixel,       // 1 = foreground (white)
    output logic        de,          // active 256x192 window
    output logic        hs,
    output logic        vs,
    output logic [8:0]  hcnt,
    output logic [8:0]  vcnt
);

    localparam int H_TOTAL     = 448;     // fD/448 = 15.980 kHz
    localparam int V_TOTAL     = 256;     // fH/256 = 62.4 Hz
    localparam int H_ACT_START = 64;      // multiple of 8 (fetch alignment)
    localparam int H_ACT_END   = H_ACT_START + 256;
    localparam int V_ACT_START = 35;
    localparam int V_ACT_END   = V_ACT_START + 192;
    localparam int H_SYNC_START = 352;    // 64-dot pulse (8.94 us)
    localparam int H_SYNC_END   = 416;
    localparam int V_SYNC_START = 240;    // 8-line pulse (500.6 us)
    localparam int V_SYNC_END   = 248;

    logic [7:0] code_lat;    // VRAM code fetched two pixels ahead of the cell
    logic [7:0] shifter;

    logic h_active, v_active;
    assign h_active = (hcnt >= H_ACT_START[8:0]) && (hcnt < H_ACT_END[8:0]);
    assign v_active = (vcnt >= V_ACT_START[8:0]) && (vcnt < V_ACT_END[8:0]);
    assign de = h_active && v_active;
    assign hs = (hcnt >= H_SYNC_START[8:0]) && (hcnt < H_SYNC_END[8:0]);
    assign vs = (vcnt >= V_SYNC_START[8:0]) && (vcnt < V_SYNC_END[8:0]);
    assign pixel = de & shifter[7];

    // Lookahead pixel position (2 cycles ahead, same scan line: the
    // first fetch of a line happens at hcnt 62/63 < H_ACT_START).
    logic [8:0] la;
    assign la = hcnt + 9'd2;

    logic la_active;
    assign la_active = v_active &&
                       (la >= H_ACT_START[8:0]) && (la < H_ACT_END[8:0]);

    logic [4:0] la_col;
    logic [4:0] row;
    logic [2:0] line;
    assign la_col = 5'((la - H_ACT_START[8:0]) >> 3);
    assign row    = 5'((vcnt - V_ACT_START[8:0]) >> 3);
    assign line   = 3'(vcnt - V_ACT_START[8:0]);

    // Glyph byte address for the latched code
    function automatic logic [15:0] glyph_addr(input logic [7:0] code,
                                               input logic [2:0] gline);
        if (!code[7])
            glyph_addr = 16'hE000 + {6'b0, code[6:0], gline};
        else if (!font_user)
            glyph_addr = 16'hE000 + {6'b0, code[6:0], gline};
        else if (code[6:5] == 2'b00)                       // 0x80-0x9F
            glyph_addr = 16'hC000 + {8'b0, code[4:0], gline};
        else                                               // 0xA0-0xFF
            glyph_addr = 16'hC100 + {5'b0, (code - 8'hA0), gline};
    endfunction

    always_comb begin
        vid_addr = 16'h0000;
        if (la_active && la[2:0] == 3'd0)
            // phase 6: fetch the cell code two pixels ahead
            vid_addr = 16'hC100 + {6'b0, row, la_col};
        else if (la_active && la[2:0] == 3'd1)
            // phase 7: fetch the glyph byte for the latched code
            vid_addr = glyph_addr(code_lat, line);
    end

    always_ff @(posedge clk) begin
        if (rst) begin
            hcnt      <= '0;
            vcnt      <= '0;
            code_lat  <= '0;
            shifter   <= '0;
        end else if (cen_pix) begin
            if (la_active && la[2:0] == 3'd0)
                code_lat <= vid_rdata;

            // Glyph fetch cycle doubles as the shifter load (the cell
            // starts on the next pixel), otherwise shift left.
            if (la_active && la[2:0] == 3'd1)
                shifter <= (code_lat[7] && !font_user) ? ~vid_rdata
                                                       : vid_rdata;
            else
                shifter <= {shifter[6:0], 1'b0};

            if (hcnt == H_TOTAL[8:0] - 9'd1) begin
                hcnt <= '0;
                vcnt <= (vcnt == V_TOTAL[8:0] - 9'd1) ? 9'd0 : vcnt + 9'd1;
            end else begin
                hcnt <= hcnt + 9'd1;
            end
        end
    end

endmodule
