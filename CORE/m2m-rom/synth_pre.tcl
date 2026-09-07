# Pre-synthesis hook: rebuild the QNICE firmware ROM (m2m-rom.rom).
# Vivado runs this from ../../CORE/CORE-Rx.runs/synth_1/, so locate the
# m2m-rom directory from this script's own path instead of relying on cwd.
set cur_dir [pwd]
set rom_dir [file normalize [file dirname [info script]]]

if {$tcl_platform(platform) eq "windows"} {
    # Vivado on Windows has no bash; run make_rom.sh inside WSL (Ubuntu).
    exec wsl -d Ubuntu --cd [file nativename $rom_dir] -- bash ./make_rom.sh >@stdout 2>@stderr
} else {
    cd $rom_dir
    exec ./make_rom.sh <@stdin >@stdout 2>@stderr
    cd $cur_dir
}

