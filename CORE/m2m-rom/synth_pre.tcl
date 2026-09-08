# Pre-synthesis hook: rebuild the QNICE firmware ROM (m2m-rom.rom).
# Vivado runs this from ../../CORE/CORE-Rx.runs/synth_1/, so locate the
# m2m-rom directory from this script's own path instead of relying on cwd.
set cur_dir [pwd]
set rom_dir [file normalize [file dirname [info script]]]

if {$tcl_platform(platform) eq "windows"} {
    # Vivado on Windows has no bash; run make_rom.sh inside WSL (Ubuntu).
    # Judge success by the ROM file being rewritten, not by the exit code:
    # tools in the chain may print harmless errors (e.g. no X display).
    set rom_file [file join $rom_dir m2m-rom.rom]
    set before [expr {[file exists $rom_file] ? [file mtime $rom_file] : 0}]
    catch { exec wsl -d Ubuntu --cd [file nativename $rom_dir] -- bash ./make_rom.sh >@stdout 2>@stderr } msg
    if {![file exists $rom_file] || [file mtime $rom_file] < $before || [file size $rom_file] == 0} {
        error "make_rom.sh did not produce $rom_file: $msg"
    }
    puts "synth_pre: m2m-rom.rom rebuilt ([file size $rom_file] bytes)"
} else {
    cd $rom_dir
    exec ./make_rom.sh <@stdin >@stdout 2>@stderr
    cd $cur_dir
}

