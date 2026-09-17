# Out-of-context synthesis of one CORE/vhdl entity (quick syntax/inference check).
#   vivado.bat -mode batch -source synth-vhdl-ooc.tcl -tclargs <TOP> [<DEP> ...]
# Dependencies (other CORE/vhdl entities the top instantiates) are read first.
set top [lindex $argv 0]
set deps [lrange $argv 1 end]
set core_dir [file normalize [file dirname [info script]]]
set out [file join $core_dir ooc $top]
file mkdir $out
cd $out
create_project -in_memory -part xc7a200tfbg484-2
set_property XPM_LIBRARIES {XPM_CDC XPM_MEMORY XPM_FIFO} [current_project]
foreach d $deps { read_vhdl -vhdl2008 -library work [file join $core_dir vhdl $d.vhd] }
read_vhdl -vhdl2008 -library work [file join $core_dir vhdl $top.vhd]
puts "OOC: top=$top"
if {[catch { synth_design -top $top -mode out_of_context -flatten_hierarchy none } err]} {
    puts "OOC: SYNTH FAILED for $top"; puts $err; exit 2
}
report_utilization -file [file join $out $top-util.rpt]
puts "OOC: finished $top"
