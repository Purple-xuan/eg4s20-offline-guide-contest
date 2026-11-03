# Implementation only; independently verify using the unchanged project SDC.
set_clock_uncertainty -setup 1.8 [get_clocks {sd_card_clk}]
set_clock_uncertainty -setup 1.0 [get_clocks {video_clk}]
set_clock_uncertainty -setup 1.5 [get_clocks {ext_mem_clk}]
