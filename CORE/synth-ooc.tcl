# Out-of-context synthesis of one module of the PCXT-EGA core under Vivado.
# Purpose: find SystemVerilog / Altera portability problems early (Phase 2).
#
#   vivado.bat -mode batch -source synth-ooc.tcl -tclargs <TOP> [extra defines...]
#
# Output goes to CORE/ooc/<TOP>/ : synth log, utilisation and a checkpoint.

set top [lindex $argv 0]
if {$top eq ""} { puts "usage: -tclargs <TOP>"; exit 1 }

set core_dir [file normalize [file dirname [info script]]]
set src      [file join $core_dir PCXT-EGA_MiSTer]
set rtl      [file join $src rtl]
set overlay  [file join $core_dir rtl overlay]
set out      [file join $core_dir ooc $top]
file mkdir $out
cd $out

# Memory initialisation files ($readmemh / jtframe synfile) resolve against
# the working directory, so copy the ones the core uses next to the run.
foreach f [glob -nocomplain [file join $rtl 8088 *.mem] [file join $rtl common *.hex] [file join $rtl common *.bin]] {
    file copy -force $f $out
}

set part xc7a200tfbg484-2
set_part $part

# ---------------------------------------------------------------- file list
# Everything the Quartus .qip files list, except:
#   rtl/hps_ext.v                     MiSTer ARM bridge (replaced by mgmt_bridge)
#   rtl/pll*                          Altera PLL IP (replaced by MMCMs in clk.vhd)
#   rtl/common/bram.vhd               altsyncram wrapper (replaced by overlay)
#   rtl/uart/slib_fifo_cyclone2.vhd   Altera FIFO, not in uart.qip anyway
#   TESTBENCH/* and DOC/*             not synthesised
proc collect {dir patterns} {
    set files {}
    foreach p $patterns {
        foreach f [glob -nocomplain -directory $dir $p] { lappend files $f }
    }
    return [lsort $files]
}

set sv_files {}
set v_files  {}
set vhd_files {}

# KFPC-XT chipset and vendored peripherals
foreach d [list [file join $rtl KFPC-XT HDL] \
                [file join $rtl KFPC-XT HDL KF8237 HDL] \
                [file join $rtl KFPC-XT HDL KF8253 HDL] \
                [file join $rtl KFPC-XT HDL KF8255 HDL] \
                [file join $rtl KFPC-XT HDL KF8259 HDL] \
                [file join $rtl KFPC-XT HDL KF8288 HDL] \
                [file join $rtl KFPC-XT HDL KFPS2KB HDL] \
                [file join $rtl KFPC-XT HDL KFSDRAM HDL] \
                [file join $rtl KFPC-XT HDL KFMMC HDL]] {
    lappend sv_files {*}[collect $d {*.sv}]
    lappend v_files  {*}[collect $d {*.v}]
}
# common, video, sound, 8088
lappend sv_files {*}[collect [file join $rtl common] {*.sv}]
lappend v_files  {*}[collect [file join $rtl common] {*.v}]
lappend vhd_files {*}[collect [file join $rtl common] {*.vhd}]
lappend sv_files {*}[collect [file join $rtl video]  {*.sv}]
lappend v_files  {*}[collect [file join $rtl video]  {*.v}]
lappend sv_files {*}[collect [file join $rtl sound]  {*.sv}]
lappend v_files  {*}[collect [file join $rtl sound jtopl hdl] {*.v}]
lappend v_files  {*}[collect [file join $rtl sound jt89 hdl]  {*.v}]
lappend sv_files {*}[collect [file join $rtl 8088] {*.sv}]
lappend sv_files {*}[collect [file join $rtl 8088 wrappers] {*.sv}]
# uart: VHDL library plus Verilog/SV front ends
lappend vhd_files {*}[collect [file join $rtl uart] {*.vhd}]
lappend v_files   {*}[collect [file join $rtl uart] {*.v}]
lappend sv_files  {*}[collect [file join $rtl uart] {*.sv}]

# Overlay: any file in CORE/rtl/overlay replaces the upstream file with the
# same basename (portability fixes live there, the submodule stays pristine).
proc apply_overlay {files overlay_dir} {
    set result {}
    foreach f $files {
        set o [file join $overlay_dir [file tail $f]]
        if {[file exists $o]} { puts "OOC: overlay [file tail $f]"; lappend result $o } else { lappend result $f }
    }
    return $result
}
set sv_files  [apply_overlay $sv_files  $overlay]
set v_files   [apply_overlay $v_files   $overlay]
set vhd_files [apply_overlay $vhd_files $overlay]

# drop the excluded ones
set vhd_files [lsearch -all -inline -not -glob $vhd_files *slib_fifo_cyclone2.vhd]
set v_files   [lsearch -all -inline -not -glob $v_files *hps_ext.v]
# *_inst.sv are the vendored peripherals' stand-alone demo tops (module TOP)
set sv_files  [lsearch -all -inline -not -glob $sv_files *_inst.sv]

# include dirs for the vendored *.svh packages
set incdirs {}
foreach d [glob -nocomplain -directory [file join $rtl KFPC-XT HDL] -type d *] {
    set h [file join $d HDL]
    if {[llength [glob -nocomplain [file join $h *.svh]]] > 0} { lappend incdirs $h }
}

puts "OOC: top=$top  sv=[llength $sv_files] v=[llength $v_files] vhd=[llength $vhd_files] incdirs=[llength $incdirs]"

# One read_verilog call per file: a `default_nettype none in one source must
# not leak into the next one (Quartus compiles each file separately).
read_vhdl -library work $vhd_files
foreach f $sv_files { read_verilog -sv $f }
# .v files are read as SystemVerilog too: several (floppy.v, ...) use SV syntax
# and Quartus autodetects that regardless of the extension.
foreach f $v_files  { read_verilog -sv $f }
set_property include_dirs $incdirs [current_fileset]

# ---------------------------------------------------------------- synthesis
set defines [lrange $argv 1 end]
set t0 [clock seconds]
if {[catch {
    synth_design -top $top -part $part -mode out_of_context -flatten_hierarchy none \
        -include_dirs $incdirs -verilog_define $defines
} err]} {
    puts "OOC: SYNTH FAILED for $top"
    puts $err
    exit 2
}
puts "OOC: synth_design done in [expr {[clock seconds]-$t0}] s"
write_checkpoint -force [file join $out $top.dcp]
report_utilization -file [file join $out $top-util.rpt]
report_utilization -hierarchical -file [file join $out $top-util-hier.rpt]
puts "OOC: finished $top"
