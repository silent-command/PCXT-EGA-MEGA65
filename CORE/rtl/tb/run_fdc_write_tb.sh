#!/usr/bin/env bash
# Icarus run of fdc_write_tb: the REAL overlay floppy.v WRITE path driven at its
# CPU I/O ports (MSR-gated, like the BIOS), with a behavioural memory->device
# DMA (contract proven by fdc_dma_wr_tb.sv) and a behavioural mgmt drain of the
# write FIFO. Reproduces or clears the "floppy WRITE -> drive not ready" bug.
#
#   ./run_fdc_write_tb.sh
# From Windows:
#   wsl -d Ubuntu --cd "<path to CORE/rtl/tb>" -- bash ./run_fdc_write_tb.sh
set -uo pipefail
here=$(cd "$(dirname "$0")" && pwd)
core=$(cd "$here/../.." && pwd)
overlay=$core/rtl/overlay
src=$core/PCXT-EGA_MiSTer/rtl/common
build=${TB_BUILD:-$HOME/.cache/pcxt-mega65-tb/fdc_write}
mkdir -p "$build"

iverilog -g2012 -o "$build/fdc_write_tb.vvp" \
    "$here/fdc_write_tb.v" \
    "$overlay/floppy.v" \
    "$src/simple_fifo.v" > "$build/build.log" 2>&1
if [ $? -ne 0 ]; then
    echo "BUILD FAILED, see $build/build.log"
    grep -iE "error|sorry" "$build/build.log" | head -30
    exit 1
fi
grep -i warning "$build/build.log" | head -10

(cd "$build" && timeout 900 vvp -n fdc_write_tb.vvp) | tee "$build/run.log"
grep -q "RESULT: PASS" "$build/run.log"
