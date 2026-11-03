# ============================================================
# 官方完赛工程 SDC 时序约束
# 器件：EG4S20BG256
# 时钟源：50MHz 晶振（引脚 R7）
# ============================================================

# 1. 主时钟：50MHz 输入晶振
create_clock -name clk_50m -period 20.000 [get_ports clk]

# 2. sys_pll outputs. Wrapper output ports are flattened by TD, so constrain
#    the physical PLL outputs that remain in the implemented netlist.
create_generated_clock -name ext_mem_clk \
    -source [get_ports {clk}] -master_clock clk_50m -multiply_by 2.5 \
    [get_pins {sys_pll_m0/pll_inst.clkc[1]}]
create_generated_clock -name ext_mem_clk_sft \
    -source [get_ports {clk}] -master_clock clk_50m -multiply_by 2.5 -phase 180 \
    [get_pins {sys_pll_m0/pll_inst.clkc[2]}]

# 3. Cascaded video PLL outputs. The first PLL creates 67.5 MHz from 50 MHz;
#    the second creates the exact CTA-861 720p clocks, 74.25 and 371.25 MHz.
create_generated_clock -name video_ref_clk \
    -source [get_ports {clk}] -master_clock clk_50m -multiply_by 1.35 \
    [get_pins {video_ref_pll_m0/pll_inst.clkc[0]}]
create_generated_clock -name video_clk \
    -source [get_pins {video_ref_pll_m0/pll_inst.clkc[0]}] \
    -master_clock video_ref_clk -multiply_by 1.1 \
    [get_pins {video_pll_m0/pll_inst.clkc[0]}]
create_generated_clock -name hdmi_5x_clk \
    -source [get_pins {video_ref_pll_m0/pll_inst.clkc[0]}] \
    -master_clock video_ref_clk -multiply_by 5.5 \
    [get_pins {video_pll_m0/pll_inst.clkc[1]}]

# The shared TMDS load toggle crosses from the pixel domain into the serial
# domain. Only its first synchronizer stage is intentionally asynchronous.
set_false_path -to [get_regs -hier {*/S_load_toggle_1d}]

# 4. 跨时钟域声明：这些时钟之间没有同步关系
#    - 视频链路（video_ref_clk + video_clk + hdmi_5x_clk）是一个组
#    - 50 MHz TF/控制域与 125 MHz SDRAM 域通过同步器、握手和异步 FIFO 交互
#    - 125 MHz SDRAM 时钟及其相移输出属于同一组
#    - 视频链路（video_ref_clk + video_clk + hdmi_5x_clk）属于一组
set_clock_groups -asynchronous \
    -group {clk_50m} \
    -group {ext_mem_clk ext_mem_clk_sft} \
    -group {video_ref_clk video_clk hdmi_5x_clk}

# 5. SD card data input delay. The push buttons are asynchronous inputs and
#    are synchronized inside ax_debounce, so they must not use this constraint.
set_input_delay  -clock clk_50m  -max 5.0 [get_ports {sd_miso}]
set_input_delay  -clock clk_50m  -min 1.0 [get_ports {sd_miso}]
set_false_path -from [get_ports {key1 key2 key_prev_n key_volume_n}]
set_false_path -from [get_ports {key_roi_mode_n key_roi_confirm_n key_roi_back_n key_roi_left_n key_roi_right_n key_roi_up_n key_roi_down_n}]
set_false_path -from [get_ports {key_gallery_n}]
set_false_path -to [get_regs -hier {u_page_switch_cdc/ack_sync1}]
set_false_path -to [get_regs -hier {u_page_switch_cdc/request_sync1}]
set_false_path -to [get_regs -hier {u_brightness_cdc/ack_sync1}]
set_false_path -to [get_regs -hier {u_brightness_cdc/request_sync1}]

# 6. 复位引脚为异步，不参与时序分析
set_false_path -from [get_ports rst_n]

# Reset synchronizers and the SDRAM-ready level synchronizer sample async data
# on their first stage; timing starts from the second stage.
set_false_path -to [get_regs -hier {*/s1}]

# First stages of the request/toggle synchronizers already present in the
# frame-buffer control logic. Later stages remain timed normally.
set_false_path -to [get_regs -hier {*/write_req_d0}]
set_false_path -to [get_regs -hier {*/write_len_d0[*]}]
set_false_path -to [get_regs -hier {*/write_addr_index_d0[*]}]
set_false_path -to [get_regs -hier {*/abort_sync[0]}]
set_false_path -to [get_regs -hier {*/wrfin_tgl_sync[0]}]
set_false_path -to [get_regs -hier {*/abort_ack_sync[0]}]

# The shifted SDRAM clock feeds the hard memory I/O window, not a fabric path.
set_false_path -from [get_clocks {ext_mem_clk}] -to [get_clocks {ext_mem_clk_sft}]
set_false_path -from [get_clocks {ext_mem_clk_sft}] -to [get_clocks {ext_mem_clk}]

# Bound the implemented serializer-to-pad paths.
set_max_delay -from [get_clocks {hdmi_5x_clk}] \
    -to [get_ports {HDMI_CLK_P HDMI_D0_P HDMI_D1_P HDMI_D2_P}] \
    8.000 -datapath_only
