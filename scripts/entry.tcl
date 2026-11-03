set root [file normalize [file join [file dirname [info script]] ..]]
set mode $::env(SUBMISSION_MODE)
set output [file join $root build $mode]
file mkdir $output
cd $output
if {[catch {source [file join $root scripts ${mode}.tcl]} message]} {
    puts stderr "SUBMISSION_FAILED: $message"
    exit 1
}
puts "SUBMISSION_PASS: $mode"
exit 0
