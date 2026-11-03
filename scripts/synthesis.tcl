import_device eagle_s20.db -package EG4S20BG256
cd [file join $root prj]
open_project [file join $root prj official_example.prj]
elaborate -top top
read_adc [file join $root prj official_example.adc]
read_sdc [file join $root prj official_example.sdc]
cd $output
set_param gate area_option performance
set_param rtl infer_fsm one_hot
set_param rtl min_ripple_len 18
set_param gate map_mode balance_explore
set_param gate mapmacro_opt_timing high
set_param gate map_opt_area high
set_param gate mapper_lut_delay 2200
set_param gate merge_tiny_lut on
optimize_rtl
optimize_gate
export_db official_example_gate.db
report_area -file official_example_gate.area
