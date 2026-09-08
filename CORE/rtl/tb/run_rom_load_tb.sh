#!/usr/bin/env bash
# Verilator run of rom_load_tb against the full pcxt_core wrapper.
# The VHDL pieces the core instantiates from Verilog (bram.vhd's dpram, the
# 16750 UART) and the modules Verilator cannot digest (saa1099, XT2IDE,
# vga_dac) are replaced by rtl/tb/sim_stubs.sv.
#   REBUILD=0 ./run_rom_load_tb.sh   reuses the last Verilator build
set -uo pipefail
here=$(cd "$(dirname "$0")" && pwd)
core=$(cd "$here/../.." && pwd)
src=$core/PCXT-EGA_MiSTer/rtl
ovl=$core/rtl/overlay
build=${TB_BUILD:-$HOME/.cache/pcxt-mega65-tb/rom_load}
mkdir -p "$build"

# same lists as core-files.tcl, minus VHDL, plus overlays by basename
files=()
for d in "$src/KFPC-XT/HDL" "$src/KFPC-XT/HDL"/KF8237/HDL "$src/KFPC-XT/HDL"/KF8253/HDL "$src/KFPC-XT/HDL"/KF8255/HDL \
         "$src/KFPC-XT/HDL"/KF8259/HDL "$src/KFPC-XT/HDL"/KF8288/HDL "$src/KFPC-XT/HDL"/KFPS2KB/HDL \
         "$src/KFPC-XT/HDL"/KFSDRAM/HDL "$src/KFPC-XT/HDL"/KFMMC/HDL "$src/common" "$src/video" "$src/sound" \
         "$src/sound/jtopl/hdl" "$src/sound/jt89/hdl" "$src/8088" "$src/8088/wrappers" "$src/uart"; do
  for f in "$d"/*.sv "$d"/*.v; do
    [ -f "$f" ] || continue
    case "$(basename "$f")" in *_inst.sv|hps_ext.v|saa1099.sv|XT2IDE.sv|vga_dac.v) continue;; esac
    if [ -f "$ovl/$(basename "$f")" ]; then f="$ovl/$(basename "$f")"; fi
    files+=("$f")
  done
done
files+=("$core/rtl/pcxt_core.sv" "$here/sim_stubs.sv" "$here/rom_load_tb.sv")

incs=()
for d in "$src"/KFPC-XT/HDL/*/HDL; do ls "$d"/*.svh >/dev/null 2>&1 && incs+=("-I$d"); done

# memory init files: the credits text is longer than its RAM (Vivado truncates,
# Verilator aborts), so only the first 8192 lines go in; the splash hex lives
# under SW/
cp "$src/8088/mcl86_ucode.mem" "$src/common/font0.hex" "$build/" 2>/dev/null
head -8192 "$src/common/msg.bin" > "$build/msg.bin"
splash=$(find "$core/PCXT-EGA_MiSTer" -name splash_ega_320x200.hex | head -1)
[ -n "$splash" ] && cp "$splash" "$build/"

cd "$build" || exit 1
if [ "${REBUILD:-1}" = 1 ]; then
  verilator --binary --timing --public-flat-rw -Wno-fatal -Wno-lint -Wno-style -j 8 \
      -DENABLE_OPL2=1 -DENABLE_CMS=0 -DENABLE_EMS=1 -DENABLE_UMB=1 -DENABLE_TANDY_AUDIO=1 -DENABLE_MIDI=1 -DENABLE_SB=1 \
      "${incs[@]}" --top-module rom_load_tb --Mdir obj -o rom_load_tb "${files[@]}" > build.log 2>&1
  if [ $? -ne 0 ]; then
    echo "BUILD FAILED, see $build/build.log"
    grep -E "%Error" build.log | head -20
    exit 1
  fi
fi
timeout 900 ./obj/rom_load_tb
