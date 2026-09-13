; CRT/ROM auto load cost: the byte loop of M2M/rom/crts-and-roms.asm
; (_CRMA_3) against the block path of M2M/rom/sdblock.asm, for one 16 KB
; ROM file. MODE at 0xA000:
;   0 = mount and open only (baseline, subtracted by run.sh)
;   1 = the original byte loop: f32_fread plus a device/window select per byte
;   2 = SDB_FREAD_FAST plus the byte-wise tail
#include "../../M2M/rom/sdblock_cfg.asm"
#include "../../M2M/QNICE/dist_kit/sysdef.asm"
#include "../../M2M/QNICE/dist_kit/monitor.def"
#include "../../M2M/rom/sysdef.asm"
                .ORG    0x8000
                MOVE    0xFEE0, SP
                MOVE    HANDLE_DEV, R8
                MOVE    1, R9
                SYSCALL(f32_mnt_sd, 1)
                MOVE    HANDLE_DEV, R8
                MOVE    HANDLE_FILE, R9
                MOVE    STR_FILE, R10
                XOR     R11, R11
                SYSCALL(f32_fopen, 1)

                MOVE    0x00AB, R2              ; R2: target device
                XOR     R3, R3                  ; R3: target 4k window
                MOVE    M2M$RAMROM_DATA, R4     ; R4: next 4k win indicator
                ADD     0x1000, R4
                MOVE    M2M$RAMROM_DATA, R5     ; R5: target address

                MOVE    MODE, R1
                MOVE    @R1, R1
                CMP     0, R1
                RBRA    _DONE, Z
                CMP     1, R1
                RBRA    _OLD, Z

                ; ---- the new path
                MOVE    HANDLE_FILE, R8
                MOVE    SDB_RM_MAP, R9
                RSUB    SDB_MAP_BUILD, 1
                MOVE    HANDLE_FILE, R8
                MOVE    SDB_RM_MAP, R9
                MOVE    R2, R10
                MOVE    R3, R11
                MOVE    R5, R12
                RSUB    SDB_FREAD_FAST, 1
                RBRA    _OLD, !C
                MOVE    R11, R3
                MOVE    R12, R5

                ; ---- the byte loop, verbatim from crts-and-roms.asm
_OLD            MOVE    HANDLE_FILE, R8
                SYSCALL(f32_fread, 1)
                CMP     FAT32$EOF, R10
                RBRA    _DONE, Z
                MOVE    M2M$RAMROM_DEV, R8
                MOVE    R2, @R8
                MOVE    M2M$RAMROM_4KWIN, R8
                MOVE    R3, @R8
                MOVE    R9, @R5++
                CMP     R4, R5
                RBRA    _OLD, !Z
                MOVE    M2M$RAMROM_DATA, R5
                ADD     1, R3
                RBRA    _OLD, 1

_DONE           HALT

#include "../../M2M/rom/sdblock.asm"

HANDLE_FILE     .BLOCK FAT32$FDH_STRUCT_SIZE
STR_FILE        .ASCII_W "/testrom.bin"
#include "bench_env.asm"
                .ORG 0xA000
MODE            .DW 0
