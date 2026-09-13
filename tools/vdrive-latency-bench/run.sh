#!/bin/bash
# Measures the QNICE cost of one SD-direct vdrive block read (M2M/rom/shell.asm
# HANDLE_DRV_RD) in the QNICE emulator that ships with M2M/QNICE.
#
#   wsl -d Ubuntu bash tools/vdrive-latency-bench/run.sh
#
# Prints, per 512-byte block: instructions, memory reads, memory writes and the
# resulting hardware cycle estimate (cycles ~= 3*I + 2*R + 2*W; see the CPU FSM
# in M2M/QNICE/vhdl/qnice_cpu.vhd: fetch/decode/execute/prepfetch plus one
# block-RAM wait state per bus access) at the 50 MHz QNICE clock.
set -e
D="$(dirname "$(readlink -f "$0")")"
Q="$D/../../M2M/QNICE"
cd "$D"
[ -x ./qasm ]  || cc "$Q/assembler/qasm.c" -O2 -o qasm 2>/dev/null
[ -x ./qnice ] || cc "$Q/emulator/qnice.c" "$Q/emulator/uart.c" "$Q/emulator/sd.c" "$Q/emulator/timer.c" \
                    -O3 -fcommon -DUSE_SD -DUSE_UART -DUSE_TIMER -UUSE_VGA -UUSE_IDE -U__EMSCRIPTEN__ -UDEBUG \
                    -lpthread -o qnice 2>/dev/null
[ -f sd.img ] || python3 mk_sd_image.py
MON="$Q/monitor/monitor.out"

build () { cc -xc -E "$1" 2>/dev/null | sed '/^#.*/d' > _pp.asm; ./qasm _pp.asm "$2" >/dev/null; }

build loop_variants.asm loop_variants.out
echo "=== per 512-byte block (one vdrive block request) ==="
for V in 0 1 2 3; do
  A=$(printf "LOAD $MON\nLOAD loop_variants.out\nSET 0xA000 0x0200\nSET 0xA001 $V\nRUN 8000\nSTAT\nQUIT\n" | ./qnice -a sd.img | grep -E "memory reads" -A1 | tr '\n' ' ')
  B=$(printf "LOAD $MON\nLOAD loop_variants.out\nSET 0xA000 0x0400\nSET 0xA001 $V\nRUN 8000\nSTAT\nQUIT\n" | ./qnice -a sd.img | grep -E "memory reads" -A1 | tr '\n' ' ')
  python3 - "$V" "$A" "$B" <<'PY'
import sys,re
v=sys.argv[1]
def p(s):
    n=[int(x) for x in re.findall(r'(\d+) memory reads, (\d+) memory writes and (\d+) instructions', s)[0]]
    return n
ra,wa,ia=p(sys.argv[2]); rb,wb,ib=p(sys.argv[3])
R,W,I=rb-ra,wb-wa,ib-ia
c=3*I+2*R+2*W
names={'0':'V0 current (f32_fread + 4x VD_CAD_WRITE)',
       '1':'V1 FIX1  (f32_fread, window select hoisted)',
       '2':'V2 FIX2  (SD hw buffer byte, window hoisted)',
       '3':'V3 FIX3  (SD hw buffer byte + push register)'}
print("%-46s I=%7d R=%7d W=%6d  cycles=%8d  %6.3f ms @50MHz  (%5.1f instr/byte)"
      % (names[v],I,R,W,c,c/50e6*1000,I/512.0))
PY
done

build seek_and_read.asm seek_and_read.out
echo
echo "=== f32_fseek cost vs. block number (instructions) ==="
printf "LOAD $MON\nLOAD seek_and_read.out\nRUN 8000\nDUMP 0xA000, 0xA014\nQUIT\n" | ./qnice -a sd.img | grep -E "^a0"
echo "slots: [0]mnt err [1]open err [2]cal [4]512x fread [6]full loop [8]seek LBA100"
echo "       [10]seek LBA1000 [12]seek LBA10000 [14]seek LBA80000 [16]bulk [18]SD\$READ_BLOCK"
