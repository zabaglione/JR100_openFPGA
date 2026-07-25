// APF scanout clock pair for the Analogue Pocket's 74.25 MHz input.
//
// 12.288 MHz at 0 and 90 degrees - the exact configuration core-template's
// mf_pllbase uses, which is proven on this hardware. The 0-degree output
// clocks the scan counters, the DDR data registers and the data DDIO cells;
// the 90-degree output drives the DDIO cell that forms the scaler's clock
// pin, centring the scaler's sampling edge in the data eye.
//
// SPDX-License-Identifier: GPL-2.0-or-later

`default_nettype none

module apf_video_pll (
    input  wire refclk,
    input  wire rst,
    output wire outclk_0,   // 12.288 MHz, 0 degrees
    output wire outclk_1,   // 12.288 MHz, 90 degrees
    output wire locked
);

apf_video_pll_0002 apf_video_pll_inst (
    .refclk   ( refclk ),
    .rst      ( rst ),
    .outclk_0 ( outclk_0 ),
    .outclk_1 ( outclk_1 ),
    .locked   ( locked )
);

endmodule

`default_nettype wire
