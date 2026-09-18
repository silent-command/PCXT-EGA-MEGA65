#!/usr/bin/env bash
# Icarus run of mgmt_bridge_tb: the MEGA65 storage bridge against the real
# ide.v from the pinned submodule and the floppy.v that is built (the overlay
# in CORE/rtl/overlay, docs/floppy.md).
#
#   ./run_mgmt_bridge_tb.sh          build and run
#   WAVE=1 ./run_mgmt_bridge_tb.sh   also dump mgmt_bridge_tb.vcd into the build dir
#
# From Windows:
#   wsl -d Ubuntu --cd "<path to CORE/rtl/tb>" -- bash ./run_mgmt_bridge_tb.sh
set -uo pipefail
here=$(cd "$(dirname "$0")" && pwd)
core=$(cd "$here/../.." && pwd)
src=$core/PCXT-EGA_MiSTer/rtl/common
build=${TB_BUILD:-$HOME/.cache/pcxt-mega65-tb/mgmt_bridge}
mkdir -p "$build"

defs=()
[ "${WAVE:-0}" = 1 ] && defs+=(-DDUMP)

iverilog -g2012 "${defs[@]}" -o "$build/mgmt_bridge_tb.vvp" \
    "$core/rtl/mgmt_bridge.sv" \
    "$here/mgmt_bridge_tb.sv" \
    "$src/ide.v" "$core/rtl/overlay/floppy.v" "$src/simple_fifo.v" > "$build/build.log" 2>&1
if [ $? -ne 0 ]; then
    echo "BUILD FAILED, see $build/build.log"
    grep -iE "error|sorry" "$build/build.log" | head -20
    exit 1
fi
grep -i warning "$build/build.log"

(cd "$build" && timeout 900 vvp -n mgmt_bridge_tb.vvp) | tee "$build/run.log"
grep -q "RESULT: PASS" "$build/run.log"
