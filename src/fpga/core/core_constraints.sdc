#
# JR-100 core constraints.
#
# Four clock domains, all asynchronous to each other:
#   - clk_74a          bridge, controller inputs, audio MCLK accumulator
#   - jr100_pll[0]     57.272727 MHz, the JR-100 machine
#   - apf_video_pll[0] 12.288 MHz, scan counters, DDR data registers and the
#                      data/control DDIO cells
#   - apf_video_pll[1] 12.288 MHz +90deg, only drives the DDIO cell forming
#                      the scaler's clock pin (constant data, no real paths)
#
# Crossings are a dual-clock BRAM (framebuffer) and synch_3 instances; there
# are no direct paths that need timing across groups. This mirrors the
# core-template SDC, which also puts each PLL output in its own group.
#
# apf_constraints.sdc declares clk_74a/clk_74b/bridge_spiclk and calls
# derive_pll_clocks, so the PLL output clocks exist by the time this runs.
#
# SPDX-License-Identifier: GPL-2.0-or-later
#

set_clock_groups -asynchronous \
 -group { bridge_spiclk } \
 -group { clk_74a } \
 -group { clk_74b } \
 -group { ic|pll|jr100_pll_inst|altera_pll_i|general[0].gpll~PLL_OUTPUT_COUNTER|divclk } \
 -group { ic|vpll|apf_video_pll_inst|altera_pll_i|general[0].gpll~PLL_OUTPUT_COUNTER|divclk } \
 -group { ic|vpll|apf_video_pll_inst|altera_pll_i|general[1].gpll~PLL_OUTPUT_COUNTER|divclk }

derive_clock_uncertainty
