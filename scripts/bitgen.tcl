set input_db [file join $root implementation official_example_pr.db]
import_device eagle_s20.db -package EG4S20BG256
cd [file join $root prj]
open_project [file join $root prj official_example.prj] -noanalyze
import_db $input_db
clear_sdc -user
read_sdc [file join $root prj official_example.sdc]
cd $output
update_timing -mode final -ctr
report_timing_summary -file timing_original_sdc.timing
report_area -io_info -file resources.txt
set f [open timing_original_sdc.timing r]
set report [read $f]
close $f
if {![regexp {SWNS:\s*([-+0-9.]+)ns,\s*STNS:\s*([-+0-9.]+)ns} $report -> swns stns] ||
    ![regexp {HWNS:\s*([-+0-9.]+)ns,\s*HTNS:\s*([-+0-9.]+)ns} $report -> hwns htns] ||
    $swns < 0 || $stns != 0 || $hwns < 0 || $htns != 0} {
    error "Original SDC timing failed; no bit generated"
}
bitgen -bit official_example.bit
