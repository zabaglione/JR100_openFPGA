#
# JR-100 core constraints.
#
# The APF bridge and the controller inputs are clocked by clk_74a; the JR-100
# machine runs from the PLL's 57.272727 MHz output. The two domains are
# asynchronous - every signal that crosses is carried by an explicit
# synchronizer in core_top.
#
# apf_constraints.sdc already declares clk_74a/clk_74b/bridge_spiclk and calls
# derive_pll_clocks, so the PLL output clock exists by the time this runs.
#
# SPDX-License-Identifier: GPL-2.0-or-later
#

set jr100_divclk {ic|pll|jr100_pll_inst|altera_pll_i|general[0].gpll~PLL_OUTPUT_COUNTER|divclk}

set_clock_groups -asynchronous \
 -group { bridge_spiclk } \
 -group { clk_74a } \
 -group { clk_74b } \
 -group [list $jr100_divclk]

# The two scaler clocks are generated in fabric by the /8 divider in core_top,
# in step with jr100_top's own pixel clock enable. Declaring them as generated
# clocks lets Quartus see their phase relationship to the 57.272727 MHz domain
# rather than treating them as unrelated user clocks.
create_generated_clock \
 -name {video_rgb_clock} \
 -source [get_pins $jr100_divclk] \
 -divide_by 8 \
 [get_pins {ic|pix_clk|q}]

create_generated_clock \
 -name {video_rgb_clock_90} \
 -source [get_pins $jr100_divclk] \
 -divide_by 8 \
 -phase 90 \
 [get_pins {ic|pix_clk_90|q}]

derive_clock_uncertainty
