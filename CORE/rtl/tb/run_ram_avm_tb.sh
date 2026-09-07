#!/usr/bin/env bash
# Icarus run of the RAM.sv lookahead bench against the MEGA65 KFSDRAM overlay.
set -uo pipefail
here=$(cd "$(dirname "$0")" && pwd)
core=$(cd "$here/../.." && pwd)
up=$core/PCXT-EGA_MiSTer/rtl/KFPC-XT/HDL
build=${TB_BUILD:-$HOME/.cache/pcxt-mega65-tb}
mkdir -p "$build"
iverilog -g2012 -o "$build/ram_lookahead_avm_tb.vvp" \
    "$here/ram_lookahead_avm_tb.sv" "$up/RAM.sv" "$core/rtl/overlay/KFSDRAM.sv" \
    && (cd "$build" && timeout 300 vvp "$build/ram_lookahead_avm_tb.vvp")
