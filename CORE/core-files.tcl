# Source file lists of the PCXT-EGA core for Vivado, shared by synth-ooc.tcl
# (out-of-context checks) and add-core-sources.tcl (the project).
#
# Everything the Quartus .qip files list, except:
#   rtl/hps_ext.v                     MiSTer ARM bridge (replaced by the mgmt bridge)
#   rtl/pll*                          Altera PLL IP (replaced by MMCMs in clk.vhd)
#   rtl/uart/slib_fifo_cyclone2.vhd   Altera FIFO, not in uart.qip anyway
#   */*_inst.sv                       stand-alone demo tops of the vendored peripherals
#   TESTBENCH/* and DOC/*             not synthesised
# plus CORE/rtl/*.sv (the wrapper) and CORE/rtl/overlay/* replacing upstream
# files of the same basename.
#
# Usage: source core-files.tcl; set lists [core_file_lists $core_dir]
#   returns a dict with keys sv, v, vhd, incdirs, defines

proc core_collect {dir patterns} {
    set files {}
    foreach p $patterns {
        foreach f [glob -nocomplain -directory $dir $p] { lappend files $f }
    }
    return [lsort $files]
}

proc core_apply_overlay {files overlay_dir} {
    set result {}
    foreach f $files {
        set o [file join $overlay_dir [file tail $f]]
        if {[file exists $o]} { lappend result $o } else { lappend result $f }
    }
    return $result
}

proc core_file_lists {core_dir} {
    set src     [file join $core_dir PCXT-EGA_MiSTer]
    set rtl     [file join $src rtl]
    set overlay [file join $core_dir rtl overlay]

    set sv_files {}
    set v_files  {}
    set vhd_files {}

    foreach d [list [file join $rtl KFPC-XT HDL] \
                    [file join $rtl KFPC-XT HDL KF8237 HDL] \
                    [file join $rtl KFPC-XT HDL KF8253 HDL] \
                    [file join $rtl KFPC-XT HDL KF8255 HDL] \
                    [file join $rtl KFPC-XT HDL KF8259 HDL] \
                    [file join $rtl KFPC-XT HDL KF8288 HDL] \
                    [file join $rtl KFPC-XT HDL KFPS2KB HDL] \
                    [file join $rtl KFPC-XT HDL KFSDRAM HDL] \
                    [file join $rtl KFPC-XT HDL KFMMC HDL]] {
        lappend sv_files {*}[core_collect $d {*.sv}]
        lappend v_files  {*}[core_collect $d {*.v}]
    }
    lappend sv_files  {*}[core_collect [file join $rtl common] {*.sv}]
    lappend v_files   {*}[core_collect [file join $rtl common] {*.v}]
    lappend vhd_files {*}[core_collect [file join $rtl common] {*.vhd}]
    lappend sv_files  {*}[core_collect [file join $rtl video]  {*.sv}]
    lappend v_files   {*}[core_collect [file join $rtl video]  {*.v}]
    lappend sv_files  {*}[core_collect [file join $rtl sound]  {*.sv}]
    lappend v_files   {*}[core_collect [file join $rtl sound jtopl hdl] {*.v}]
    lappend v_files   {*}[core_collect [file join $rtl sound jt89 hdl]  {*.v}]
    lappend sv_files  {*}[core_collect [file join $rtl 8088] {*.sv}]
    lappend sv_files  {*}[core_collect [file join $rtl 8088 wrappers] {*.sv}]
    lappend vhd_files {*}[core_collect [file join $rtl uart] {*.vhd}]
    lappend v_files   {*}[core_collect [file join $rtl uart] {*.v}]
    lappend sv_files  {*}[core_collect [file join $rtl uart] {*.sv}]
    # the MEGA65 wrapper
    lappend sv_files  {*}[core_collect [file join $core_dir rtl] {*.sv}]

    set sv_files  [core_apply_overlay $sv_files  $overlay]
    set v_files   [core_apply_overlay $v_files   $overlay]
    set vhd_files [core_apply_overlay $vhd_files $overlay]

    set vhd_files [lsearch -all -inline -not -glob $vhd_files *slib_fifo_cyclone2.vhd]
    set v_files   [lsearch -all -inline -not -glob $v_files *hps_ext.v]
    set sv_files  [lsearch -all -inline -not -glob $sv_files *_inst.sv]

    set incdirs {}
    foreach d [glob -nocomplain -directory [file join $rtl KFPC-XT HDL] -type d *] {
        set h [file join $d HDL]
        if {[llength [glob -nocomplain [file join $h *.svh]]] > 0} { lappend incdirs $h }
    }

    # Feature macros: the shipped MiSTer build sets all seven through config.tcl
    set defines {ENABLE_OPL2=1 ENABLE_CMS=1 ENABLE_EMS=1 ENABLE_UMB=1 ENABLE_TANDY_AUDIO=1 ENABLE_MIDI=1 ENABLE_SB=1}

    return [dict create sv $sv_files v $v_files vhd $vhd_files incdirs $incdirs defines $defines]
}
