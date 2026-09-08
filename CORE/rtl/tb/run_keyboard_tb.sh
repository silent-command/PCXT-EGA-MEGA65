#!/usr/bin/env bash
# GHDL run of keyboard_tb (keyboard.vhd + ps2_tx.vhd).
set -uo pipefail
here=$(cd "$(dirname "$0")" && pwd)
core=$(cd "$here/../.." && pwd)
build=${TB_BUILD:-$HOME/.cache/pcxt-mega65-tb/keyboard}
mkdir -p "$build" && cd "$build" || exit 1
ghdl -a --std=08 "$core/vhdl/ps2_tx.vhd" "$core/vhdl/keyboard.vhd" "$here/keyboard_tb.vhd" || exit 1
ghdl -e --std=08 keyboard_tb || exit 1
ghdl -r --std=08 keyboard_tb --stop-time=200ms 2>&1 | grep -v "^ghdl:info" | tail -30
