#!/bin/bash
# Checks the LBA -> C/H/R conversion of the internal floppy drive path
# (CORE/m2m-rom/flpdrv_calc.asm FLP_LBA2CHS) by running the real routine in
# the QNICE emulator for every LBA of a 1.44 MB (18 SPT) and a 720 KB (9 SPT)
# disk and comparing against lba = (c*2 + h)*spt + r - 1 (docs/floppy.md).
#
#   wsl -d Ubuntu bash tools/vdrive-latency-bench/run_flp_chs.sh
set -e
D="$(dirname "$(readlink -f "$0")")"
Q="$D/../../M2M/QNICE"
cd "$D"
[ -x ./qasm ]  || cc "$Q/assembler/qasm.c" -O2 -o qasm 2>/dev/null
[ -x ./qnice ] || cc "$Q/emulator/qnice.c" "$Q/emulator/uart.c" "$Q/emulator/sd.c" "$Q/emulator/timer.c" \
                    -O3 -fcommon -DUSE_SD -DUSE_UART -DUSE_TIMER -UUSE_VGA -UUSE_IDE -U__EMSCRIPTEN__ -UDEBUG \
                    -lpthread -o qnice 2>/dev/null
MON="$Q/monitor/monitor.out"
cc -xc -E flp_chs.asm 2>/dev/null | sed '/^#.*/d' > _pp_flp.asm
./qasm _pp_flp.asm flp_chs.out >/dev/null
printf "LOAD $MON\nLOAD flp_chs.out\nRUN 8000\nQUIT\n" | ./qnice 2>/dev/null \
  | sed -e 's/^\(\[[0-9A-F]*\] Q> \)*//' | tr -d '\r' | grep -E '^[0-9A-F]{4} [0-9A-F]{4} [0-9A-F]{4} [0-9A-F]{4} [0-9A-F]{4}$' > flp_chs.txt || true
python3 - <<'PY'
import sys
rows=[l.split() for l in open('flp_chs.txt')]
n=0; bad=0; seen={}
for spt,lba,c,h,r in rows:
    spt=int(spt,16); lba=int(lba,16); c=int(c,16); h=int(h,16); r=int(r,16)
    n+=1
    seen[(spt,lba)]=(c,h,r)
    if (c*2+h)*spt+r-1 != lba or not (1<=r<=spt) or h not in (0,1) or not (0<=c<80):
        bad+=1
        if bad<=10: print("FAIL spt=%d lba=%d -> C%d H%d R%d"%(spt,lba,c,h,r))
exp={(18,0):(0,0,1),(18,17):(0,0,18),(18,18):(0,1,1),(18,35):(0,1,18),(18,36):(1,0,1),(18,2879):(79,1,18),
     (9,0):(0,0,1),(9,8):(0,0,9),(9,9):(0,1,1),(9,17):(0,1,9),(9,18):(1,0,1),(9,1439):(79,1,9)}
for k,v in exp.items():
    if seen.get(k)!=v:
        bad+=1; print("FAIL corner spt=%d lba=%d -> %s (expected %s)"%(k[0],k[1],seen.get(k),v))
want=160*18+160*9
if n!=want:
    bad+=1; print("FAIL: %d conversions printed (%d expected)"%(n,want))
print("flp_chs: %d conversions, %d corner cases, %d failures"%(n,len(exp),bad))
print("RESULT: PASS" if bad==0 else "RESULT: FAIL")
PY
