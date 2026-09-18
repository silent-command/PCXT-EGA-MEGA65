; flp_chs.asm: runs the REAL FLP_LBA2CHS of CORE/m2m-rom/flpdrv_calc.asm (the
; LBA -> C/H/R conversion of the internal floppy drive path, docs/floppy.md)
; in the QNICE emulator for every LBA of a 1.44 MB disk (18 sectors per
; track) and of a 720 KB disk (9), and prints one line per LBA:
;    <spt> <lba> <c> <h> <r>   (all hex)
; run_flp_chs.sh compares the lines against the formula
;    lba = (c * 2 + h) * spt + r - 1
; and the classic corner cases (LBA 0 = C0 H0 R1, LBA 18 = C0 H1 R1 on
; 1.44 MB, LBA 36 = C1 H0 R1).

#include "../../M2M/QNICE/dist_kit/sysdef.asm"
#include "../../M2M/QNICE/dist_kit/monitor.def"

                .ORG    0x8000
                MOVE    0xFEE0, SP

START           MOVE    18, R12                 ; R12: sectors per track (R0..R7 are banked)
                RSUB    TABLE, 1
                MOVE    9, R12
                RSUB    TABLE, 1
                HALT

; print the conversion of every LBA 0 .. 160 * spt - 1
TABLE           INCRB
                XOR     R0, R0                  ; R0: LBA
                MOVE    R12, R1                 ; R1: spt
                MOVE    160, R8
                MOVE    R1, R9
                SYSCALL(mulu, 1)                ; R10 = 160 * spt = LBA count
                MOVE    R10, R2
_TABLE_1        MOVE    R1, R8
                SYSCALL(puthex, 1)
                MOVE    0x0020, R8
                SYSCALL(putc, 1)
                MOVE    R0, R8
                SYSCALL(puthex, 1)
                MOVE    0x0020, R8
                SYSCALL(putc, 1)
                MOVE    R0, R8
                MOVE    R1, R9
                RSUB    FLP_LBA2CHS, 1          ; R8 = C, R9 = H, R10 = R
                MOVE    R9, R3
                MOVE    R10, R4
                SYSCALL(puthex, 1)              ; C
                MOVE    0x0020, R8
                SYSCALL(putc, 1)
                MOVE    R3, R8
                SYSCALL(puthex, 1)              ; H
                MOVE    0x0020, R8
                SYSCALL(putc, 1)
                MOVE    R4, R8
                SYSCALL(puthex, 1)              ; R
                SYSCALL(crlf, 1)
                ADD     1, R0
                CMP     R2, R0
                RBRA    _TABLE_1, !Z
                DECRB
                RET

#include "../../CORE/m2m-rom/flpdrv_calc.asm"
