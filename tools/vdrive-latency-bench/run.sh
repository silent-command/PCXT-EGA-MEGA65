#!/bin/bash
# Measures the QNICE cost of one SD-direct vdrive block read (M2M/rom/shell.asm
# HANDLE_DRV_RD) in the QNICE emulator that ships with M2M/QNICE, and checks
# the fast block path of M2M/rom/sdblock.asm byte for byte against it.
#
#   wsl -d Ubuntu bash tools/vdrive-latency-bench/run.sh
#
# Prints, per 512-byte block: instructions, memory reads, memory writes and the
# resulting hardware cycle estimate (cycles ~= 3*I + 2*R + 2*W; see the CPU FSM
# in M2M/QNICE/vhdl/qnice_cpu.vhd: fetch/decode/execute/prepfetch plus one
# block-RAM wait state per bus access) at the 50 MHz QNICE clock.
#
# Variants 4 and 5 and the correctness section run the REAL firmware code:
# M2M/rom/sdblock.asm is included verbatim and only the handful of shell.asm
# variables it needs is stubbed (bench_env.asm).
set -e
D="$(dirname "$(readlink -f "$0")")"
Q="$D/../../M2M/QNICE"
cd "$D"
[ -x ./qasm ]  || cc "$Q/assembler/qasm.c" -O2 -o qasm 2>/dev/null
[ -x ./qnice ] || cc "$Q/emulator/qnice.c" "$Q/emulator/uart.c" "$Q/emulator/sd.c" "$Q/emulator/timer.c" \
                    -O3 -fcommon -DUSE_SD -DUSE_UART -DUSE_TIMER -UUSE_VGA -UUSE_IDE -U__EMSCRIPTEN__ -UDEBUG \
                    -lpthread -o qnice 2>/dev/null
[ -f sd.img ] || python3 mk_sd_image.py
# the write tests and variant 5 modify the card: always start from a fresh copy
cp -f sd.img sd_rw.img
MON="$Q/monitor/monitor.out"

# -DSDB_NODEBUG turns the serial log off no matter how M2M/rom/sdblock_cfg.asm
# is set, so that the cycle counts below are always those of the shipping
# build. $3 can override it to build the logging variant.
build () { cc -xc -E ${3:--DSDB_NODEBUG} "$1" 2>/dev/null | sed '/^#.*/d' > _pp.asm; ./qasm _pp.asm "$2" >/dev/null; }

# ---------------------------------------------------------------------------
build fastpath.asm fastpath.out
echo "=== correctness: fast path vs. f32_fread, byte for byte ==="
printf "LOAD $MON\nLOAD fastpath.out\nRUN 8000\nQUIT\n" | ./qnice -a sd_rw.img \
  | sed -e 's/^\(\[[0-9A-F]*\] Q> \)*//' -e '/^HALT instruction/d' -e '/^$/d' -e '/^\[/d'
cp -f sd.img sd_rw.img

# the same checks again, but with the serial log compiled in, so that the
# logging code itself is known to assemble and not to disturb the results
build fastpath.asm fastpath_dbg.out -DFORCE_LOG
printf "LOAD $MON\nLOAD fastpath_dbg.out\nRUN 8000\nQUIT\n" | ./qnice -a sd_rw.img \
  | sed -e 's/^\(\[[0-9A-F]*\] Q> \)*//' | grep -E "summary|FAIL" | sed 's/^/with SDB_DEBUG: /'
cp -f sd.img sd_rw.img

# ---------------------------------------------------------------------------
build loop_variants.asm loop_variants.out
echo
echo "=== per 512-byte block (one vdrive block request) ==="
for V in 0 1 2 3 4 5 6; do
  IMG=sd.img
  [ "$V" -ge 5 ] && IMG=sd_rw.img
  A=$(printf "LOAD $MON\nLOAD loop_variants.out\nSET 0xA000 0x0200\nSET 0xA001 $V\nRUN 8000\nSTAT\nQUIT\n" | ./qnice -a $IMG | grep -E "memory reads" -A1 | tr '\n' ' ')
  B=$(printf "LOAD $MON\nLOAD loop_variants.out\nSET 0xA000 0x0400\nSET 0xA001 $V\nRUN 8000\nSTAT\nQUIT\n" | ./qnice -a $IMG | grep -E "memory reads" -A1 | tr '\n' ' ')
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
       '3':'V3 FIX3  (SD hw buffer byte + push register)',
       '4':'V4 NEW   (sdblock.asm read: map + SD blk + copy)',
       '5':'V5 NEW   (sdblock.asm write: copy + SD blk write)',
       '6':'V6 current write (f32_fwrite + f32_fflush)'}
ms=c/50e6*1000
print("%-48s I=%7d R=%7d W=%6d  cycles=%8d  %6.3f ms @50MHz  %7.1f KB/s"
      % (names[v],I,R,W,c,ms,0.5/(ms/1000.0)))
PY
done

# ---------------------------------------------------------------------------
build romload.asm romload.out
echo
echo "=== CRT/ROM auto load, one 16 KB ROM file ==="
for M in 0 1 2; do
  printf "LOAD $MON\nLOAD romload.out\nSET 0xA000 $M\nRUN 8000\nSTAT\nQUIT\n" | ./qnice -a sd.img \
    | grep -E "memory reads" -A1 | tr '\n' ' ' > _rl_$M.txt
done
python3 - <<'PY'
import re
def p(f):
    s=open(f).read()
    return [int(x) for x in re.findall(r'(\d+) memory reads, (\d+) memory writes and (\d+) instructions', s)[0]]
b=p('_rl_0.txt')
for m,name in ((1,'byte loop (crts-and-roms.asm _CRMA_3)'),
               (2,'SDB_FREAD_FAST + byte-wise tail    ')):
    v=p('_rl_%d.txt'%m)
    R,W,I=v[0]-b[0],v[1]-b[1],v[2]-b[2]
    c=3*I+2*R+2*W
    ms=c/50e6*1000
    print("%-38s I=%8d  cycles=%9d  %7.2f ms @50MHz  %7.1f KB/s" % (name,I,c,ms,16.0/(ms/1000.0)))
PY
rm -f _rl_0.txt _rl_1.txt _rl_2.txt

# ---------------------------------------------------------------------------
build seek_and_read.asm seek_and_read.out
echo
echo "=== f32_fseek cost vs. block number (cycle counter, lo/mid words) ==="
printf "LOAD $MON\nLOAD seek_and_read.out\nRUN 8000\nDUMP 0xA000, 0xA014\nQUIT\n" | ./qnice -a sd.img | grep -E "^a0"
echo "slots: [0]mnt err [1]open err [2]cal [4]512x fread [6]full loop [8]seek LBA100"
echo "       [10]seek LBA1000 [12]seek LBA10000 [14]seek LBA80000 [16]bulk [18]SD\$READ_BLOCK"
