import_device eagle_s20.db -package EG4S20BG256
cd [file join $root prj]
open_project [file join $root prj official_example.prj]
elaborate -top top
read_adc [file join $root prj official_example.adc]
read_sdc [file join $root prj official_example.sdc]
cd $output
