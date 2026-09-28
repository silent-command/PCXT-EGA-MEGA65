# Batch build of the R3 project: synthesis, implementation, bitstream.
# Usage (PowerShell, from the CORE directory):
#   & 'C:\AMDDesignTools\2026.1\Vivado\bin\vivado.bat' -mode batch -source build-r3.tcl -log build-r3.log -journal build-r3.jou
# The synth_1 pre-hook (m2m-rom/synth_pre.tcl) rebuilds the QNICE ROM via WSL.

set proj_dir [file normalize [file dirname [info script]]]
# Pick up sources added to core-files.tcl / add-core-sources.tcl since the last
# build (idempotent; opens and closes the project itself).
# add-core-sources.tcl reads the project name from argv and defaults to R6
set argv [list CORE-R3.xpr]
source [file join $proj_dir add-core-sources.tcl]
open_project [file join $proj_dir CORE-R3.xpr]

set jobs 16
puts "BUILD: part [get_property PART [current_project]]"
puts "BUILD: top [get_property TOP [current_fileset]]"

reset_run synth_1
launch_runs synth_1 -jobs $jobs
wait_on_run synth_1
if {[get_property PROGRESS [get_runs synth_1]] ne "100%"} {
    puts "BUILD: synth_1 did not complete: [get_property STATUS [get_runs synth_1]]"
    exit 1
}
puts "BUILD: synth_1 done: [get_property STATUS [get_runs synth_1]]"

launch_runs impl_1 -to_step write_bitstream -jobs $jobs
wait_on_run impl_1
puts "BUILD: impl_1 status: [get_property STATUS [get_runs impl_1]]"
puts "BUILD: impl_1 progress: [get_property PROGRESS [get_runs impl_1]]"

open_run impl_1
report_timing_summary -file [file join $proj_dir build-r3-timing.rpt]
report_utilization -file [file join $proj_dir build-r3-util.rpt]
puts "BUILD: WNS [get_property STATS.WNS [get_runs impl_1]] TNS [get_property STATS.TNS [get_runs impl_1]]"
close_project
puts "BUILD: finished"
