# Add (or refresh) the PCXT-EGA core sources in the Vivado project.
#   vivado.bat -mode batch -source add-core-sources.tcl -tclargs CORE-R6.xpr
# Idempotent: files already in the project are skipped; overlays win over the
# upstream file of the same name (core-files.tcl).

set xpr [lindex $argv 0]
if {$xpr eq ""} { set xpr CORE-R6.xpr }
set core_dir [file normalize [file dirname [info script]]]
source [file join $core_dir core-files.tcl]

open_project [file join $core_dir $xpr]
set fs [current_fileset]
set lists [core_file_lists $core_dir]

# CORE/vhdl additions of the port (the template files are already listed)
set vhd_extra [list [file join $core_dir vhdl mem_bram.vhd] [file join $core_dir vhdl rom_loader.vhd] [file join $core_dir vhdl ps2_tx.vhd] [file join $core_dir vhdl vd_glue.vhd] [file join $core_dir vhdl mem_backend.vhd] [file join $core_dir vhdl analog_video_ctl.vhd] [file join $core_dir vhdl analog_line_doubler.vhd] [file join $core_dir vhdl m65_mouse_ps2.vhd] [file join $core_dir vhdl eth_mac.vhd] [file join $core_dir vhdl floppy_drive_if.vhd] [file join $core_dir vhdl floppy_mfm_reader.vhd] [file join $core_dir vhdl floppy_phy_spike.vhd] [file join $core_dir vhdl floppy_sector_engine.vhd] [file join $core_dir .. M2M vhdl memory avm_cache.vhd]]

proc add_if_missing {files} {
    set added 0
    foreach f $files {
        set n [file normalize $f]
        # an overlay (same basename, other directory) replaces the upstream file
        foreach d [get_files -quiet "*/[file tail $n]"] {
            set dn [file normalize $d]
            if {$dn ne $n} {
                puts "PROJECT: replacing $dn"
                remove_files [get_files $dn]
            }
        }
        if {[llength [get_files -quiet $n]] == 0} {
            add_files -norecurse $n
            incr added
        }
    }
    return $added
}

set n_sv  [add_if_missing [dict get $lists sv]]
set n_v   [add_if_missing [dict get $lists v]]
set n_vhd [add_if_missing [concat [dict get $lists vhd] $vhd_extra]]

# all Verilog of the core is SystemVerilog (Quartus autodetects, Vivado does not)
foreach f [concat [dict get $lists sv] [dict get $lists v]] {
    set_property file_type SystemVerilog [get_files [file normalize $f]]
}
foreach f [concat [dict get $lists vhd] $vhd_extra] {
    set_property file_type {VHDL 2008} [get_files [file normalize $f]]
}

# vendored *.svh packages and the feature macros
set_property include_dirs [dict get $lists incdirs] $fs
set_property verilog_define [dict get $lists defines] $fs

# memory initialisation files ($readmemh in mcl86_ucode.sv, jtframe synfile)
foreach f [glob -nocomplain [file join $core_dir PCXT-EGA_MiSTer rtl 8088 *.mem] \
                            [file join $core_dir PCXT-EGA_MiSTer rtl common *.hex] \
                            [file join $core_dir PCXT-EGA_MiSTer rtl common *.bin]] {
    if {[llength [get_files -quiet [file normalize $f]]] == 0} { add_files -norecurse [file normalize $f] }
}

update_compile_order -fileset $fs
puts "PROJECT: added sv=$n_sv v=$n_v vhd=$n_vhd; total files [llength [get_files]]; top [get_property TOP $fs]"
close_project
