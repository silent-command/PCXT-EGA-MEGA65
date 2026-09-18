#!/bin/bash
# Runs the REAL internal-floppy-drive firmware (CORE/m2m-rom/flpdrv.asm) in
# the QNICE emulator against a scripted model of the sector engine's
# registers and of the framework's vdrive calls (flp_ondemand.asm) and checks
# the decisions it takes: no engine command while idle, one PROBE per access
# attempt (rate-limited), DETECT only with a disk in, the mount size and
# read-only flag, the LBA -> C/H/R arguments of READ_TRACK / WRITE_SECTOR
# with the sectors-per-track of the mount, and which requests are refused
# with the block-error flag (docs/floppy.md, "Disk detection on demand").
#
#   wsl -d Ubuntu bash tools/vdrive-latency-bench/run_flp_ondemand.sh
set -e
D="$(dirname "$(readlink -f "$0")")"
Q="$D/../../M2M/QNICE"
cd "$D"
[ -x ./qasm ]  || cc "$Q/assembler/qasm.c" -O2 -o qasm 2>/dev/null
[ -x ./qnice ] || cc "$Q/emulator/qnice.c" "$Q/emulator/uart.c" "$Q/emulator/sd.c" "$Q/emulator/timer.c" \
                    -O3 -fcommon -DUSE_SD -DUSE_UART -DUSE_TIMER -UUSE_VGA -UUSE_IDE -U__EMSCRIPTEN__ -UDEBUG \
                    -lpthread -o qnice 2>/dev/null
MON="$Q/monitor/monitor.out"
cc -xc -E flp_ondemand.asm 2>/dev/null | sed '/^#.*/d' > _pp_flpod.asm
./qasm _pp_flpod.asm flp_ondemand.out >/dev/null
printf "LOAD $MON\nLOAD flp_ondemand.out\nRUN 8000\nQUIT\n" | ./qnice 2>/dev/null \
  | sed -e 's/^\(\[[0-9A-F]*\] Q> \)*//' | tr -d '\r' > flp_ondemand.txt || true
grep -E '^(ok|FAIL): |^FLP: ' flp_ondemand.txt
ok=$(grep -c '^ok: ' flp_ondemand.txt || true)
bad=$(grep -c '^FAIL: ' flp_ondemand.txt || true)
sum=$(grep '^flp_ondemand: ' flp_ondemand.txt || true)
echo "flp_ondemand: $ok checks passed, $bad failed ($sum)"
if [ "$bad" = 0 ] && [ "$ok" -gt 0 ] && [ -n "$sum" ]; then echo "RESULT: PASS"; else echo "RESULT: FAIL"; exit 1; fi
