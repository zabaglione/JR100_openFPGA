// JR-100 system clock PLL for the Analogue Pocket's 74.25 MHz input.
//
// 57.272727 MHz = 4x the NTSC colour burst (14.31818 MHz x 4), which is the
// JR-100's crystal chain. The core divides it down with clock enables exactly
// as the real machine does:
//     / 8  -> 7.159091 MHz pixel clock
//     / 64 -> 894.886 kHz CPU clock
//
// 74.25 MHz cannot reach 57.272727 MHz with integer counters inside the VCO's
// legal range, so the fractional multiplier is required. Its 32-bit fraction
// puts the residual error in the parts-per-billion range, which is far below
// what the CMT's 600 baud FSK timing or the audio stage can notice.
//
// SPDX-License-Identifier: GPL-2.0-or-later

`default_nettype none

module jr100_pll (
    input  wire refclk,
    input  wire rst,
    output wire outclk_0,   // 57.272727 MHz system clock
    output wire locked
);

jr100_pll_0002 jr100_pll_inst (
    .refclk   ( refclk ),
    .rst      ( rst ),
    .outclk_0 ( outclk_0 ),
    .locked   ( locked )
);

endmodule

`default_nettype wire
