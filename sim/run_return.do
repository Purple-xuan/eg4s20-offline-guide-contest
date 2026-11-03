onerror {quit -code 1 -force}
onbreak {quit -code 1 -force}
set root [file normalize [pwd]]
if {![file exists [file join $root src top top_tf_hdmi_audio.v]]} {error "Run vsim from the submission root directory"}
file mkdir [file join $root build sim_return]
cd [file join $root build sim_return]
if {![file exists work]} {vlib work}
vmap work work
set sources [list [file join $root src memory resident_row_reader.v] [file join $root src memory resident_slot_writer.v] [file join $root src image resident_line_buffers.v] [file join $root src image resident_display_engine.v] [file join $root sim navigation_return_memory_model.v] [file join $root sim tb_resident_display_engine.v]]
vlog "+incdir+[file join $root src memory]" +define+NAV_FAST_MEMORY+NAV_RETURN_ONLY {*}$sources
vsim -c -voptargs=+acc work.tb_resident_display_engine
run -all
if {[examine -radix unsigned /tb_resident_display_engine/passed] != 1} {quit -code 2 -force}
quit -code 0 -force
