#!/bin/bash
# Runs the REAL hard-disk-memory firmware (CORE/m2m-rom/hdmount.asm) in the
# QNICE emulator with the real FAT32 library of the monitor on a FAT32 card
# image (hdmount_bench.asm), then looks at the card image itself: the file
# must hold the path, keep its size, and nothing but its one sector may have
# changed anywhere on the card.
#
#   wsl -d Ubuntu bash tools/vdrive-latency-bench/run_hdmount.sh
set -e
D="$(dirname "$(readlink -f "$0")")"
Q="$D/../../M2M/QNICE"
cd "$D"
[ -x ./qasm ]  || cc "$Q/assembler/qasm.c" -O2 -o qasm 2>/dev/null
[ -x ./qnice ] || cc "$Q/emulator/qnice.c" "$Q/emulator/uart.c" "$Q/emulator/sd.c" "$Q/emulator/timer.c" \
                    -O3 -fcommon -DUSE_SD -DUSE_UART -DUSE_TIMER -UUSE_VGA -UUSE_IDE -U__EMSCRIPTEN__ -UDEBUG \
                    -lpthread -o qnice 2>/dev/null
# the image needs /M2M/HDMOUNT: regenerate one that predates it
if [ ! -f sd.img ] || ! grep -q "hdmount file at abs LBA" sd.layout 2>/dev/null; then
  python3 mk_sd_image.py > sd.layout
fi
cp -f sd.img sd_rw.img
MON="$Q/monitor/monitor.out"
cc -xc -E hdmount_bench.asm 2>/dev/null | sed '/^#.*/d' > _pp_hdm.asm
./qasm _pp_hdm.asm hdmount_bench.out >/dev/null
printf "LOAD $MON\nLOAD hdmount_bench.out\nRUN 8000\nQUIT\n" | ./qnice -a sd_rw.img 2>/dev/null \
  | sed -e 's/^\(\[[0-9A-F]*\] Q> \)*//' | tr -d '\r' > hdmount_bench.txt || true
grep -E '^(ok|FAIL): |^HDM: ' hdmount_bench.txt
ok=$(grep -c '^ok: ' hdmount_bench.txt || true)
bad=$(grep -c '^FAIL: ' hdmount_bench.txt || true)
sum=$(grep '^hdmount: ' hdmount_bench.txt || true)
echo "hdmount: $ok checks passed, $bad failed ($sum)"

# the card itself
LBA=$(sed -n 's/^hdmount file at abs LBA //p' sd.layout)
python3 - "$LBA" <<'PY'
import sys
lba = int(sys.argv[1]); BPS = 512
a = open('sd.img','rb').read(); b = open('sd_rw.img','rb').read()
bad = 0
def chk(ok, what):
    global bad
    print(("ok: " if ok else "FAIL: ") + what)
    bad += 0 if ok else 1
chk(len(a) == len(b), "card: image size unchanged")
changed = [i for i in range(len(a)//BPS) if a[i*BPS:(i+1)*BPS] != b[i*BPS:(i+1)*BPS]]
chk(changed == [lba], "card: only the sector of /M2M/HDMOUNT changed (changed: %s, file at %d)" % (changed[:8], lba))
want = b"/pcxt/freedos.vhd\0"
sec = b[lba*BPS:(lba+1)*BPS]
chk(sec[:len(want)] == want, "card: the file starts with the path and its terminator (%r)" % sec[:24])
chk(sec[128:] == bytes(BPS-128), "card: nothing written beyond the 128 bytes of the file")
sys.exit(1 if bad else 0)
PY
# The one thing the emulator cannot see is the address of the control and
# status register, because the bench supplies its own stand-in for it. The
# first hardware run read the SD card bit from 0xFFFF for exactly that reason
# (an .EQU of another symbol, which the assembler does not resolve). So look
# at the firmware listing: both accesses must be assembled with 0xFFE0.
LIS="$D/../../CORE/m2m-rom/m2m-rom.lis"
if [ -f "$LIS" ]; then
  n=$(grep -E "FFE0 +(MOVE|OR) +.*(still the card of start-up|POST with the disk present)|FFE0 +MOVE M2M\\$CSR, R[08] " "$LIS" | grep -cE "still the card of start-up|POST with the disk present" || true)
  if [ "$n" = 2 ] && ! grep -qE "^HDM_CSR +: " "$LIS"; then
    echo "ok: listing: both CSR accesses of hdmount.asm use 0xFFE0"
  else
    echo "FAIL: listing: CSR accesses of hdmount.asm not at 0xFFE0 ($n of 2)"; bad=$((bad+1))
  fi
fi

if [ "$bad" = 0 ] && [ "$ok" -gt 0 ] && [ -n "$sum" ]; then echo "RESULT: PASS"; else echo "RESULT: FAIL"; exit 1; fi
