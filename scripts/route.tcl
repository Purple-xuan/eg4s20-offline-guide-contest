import_device eagle_s20.db -package EG4S20BG256
cd [file join $root prj]
open_project [file join $root prj official_example.prj] -noanalyze
import_db [file join $root build synthesis official_example_gate.db]
clear_sdc -user
read_sdc [file join $root prj official_example.sdc]
read_adc [file join $root prj official_example.adc]
cd $output
set_param place effort high
set_param place seed 50
set_param place opt_timing off
set_param place post_place_opt off
set_param place logic_level_opt off
set_param place crit_path_opt off
set_param place shifter_opt off
set_param place enhanced_gp on
set_param route effort routability
set_param route timing greedy
set_param route post_route_opt high
set_param route postrt_opt_extra_round 1
set_param route fix_hold off
set_param flow qor_monitor off
read_sdc [file join $root constraints implementation_margin.sdc]
place
read_sdc [file join $root constraints video_margin.sdc]
read_sdc [file join $root constraints serial_margin.sdc]
route
fix_hold
report_area -io_info -file official_example.area
export_db official_example_pr.db
