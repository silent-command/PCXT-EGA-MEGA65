; Variant loops for the SD-direct block read.  VARIANT at 0xA002:
;   0 = current shell.asm loop (f32_fread + 4x VD_CAD_WRITE)
;   1 = FIX1: f32_fread + inlined 4 window writes (device/window hoisted)
;   2 = FIX2: SD hardware buffer byte + inlined 4 window writes
;   3 = FIX3: SD hardware buffer byte + auto-increment push register
;   4 = NEW:  the real M2M/rom/sdblock.asm read path
;             (SDB_VD_RDBLK + SDB_SD2VD), one call per 512 byte block
;   5 = NEW:  the real M2M/rom/sdblock.asm write path (SDB_VD_WRBLK);
;             needs a writable image, run.sh points it at sd_rw.img
;   6 = current shell.asm write loop (f32_fwrite per byte + f32_fflush)
#include "../../M2M/rom/sdblock_cfg.asm"
#include "../../M2M/QNICE/dist_kit/sysdef.asm"
#include "../../M2M/QNICE/dist_kit/monitor.def"
#include "../../M2M/rom/sysdef.asm"
                .ORG    0x8000
                MOVE    0xFEFF, SP
                MOVE    HANDLE_DEV, R8
                MOVE    1, R9
                SYSCALL(f32_mnt_sd, 1)
                MOVE    HANDLE_DEV, R8
                MOVE    HANDLE_FILE, R9
                MOVE    STR_FILE, R10
                XOR     R11, R11
                SYSCALL(f32_fopen, 1)
                MOVE    512, R5
_W1             MOVE    HANDLE_FILE, R8
                SYSCALL(f32_fread, 1)
                SUB     1, R5
                RBRA    _W1, !Z

                MOVE    NBYTES, R0
                MOVE    @R0, R0
                XOR     R6, R6
                MOVE    VARIANT, R1
                MOVE    @R1, R1
                CMP     0, R1
                RBRA    _V0, Z
                CMP     1, R1
                RBRA    _V1, Z
                CMP     2, R1
                RBRA    _V2, Z
                CMP     3, R1
                RBRA    _V3, Z
                CMP     4, R1
                RBRA    _V4, Z
                CMP     5, R1
                RBRA    _V5, Z
                RBRA    _V6, 1

; ---------- V0: current code
_V0             CMP     R6, R0
                RBRA    _DONE, Z
                MOVE    HANDLE_FILE, R8
                SYSCALL(f32_fread, 1)
                MOVE    R9, R12
                MOVE    SIM_B_ADDR, R8
                MOVE    R6, R9
                RSUB    CAD_WRITE, 1
                MOVE    SIM_B_DOUT, R8
                MOVE    R12, R9
                RSUB    CAD_WRITE, 1
                MOVE    SIM_B_WREN, R8
                MOVE    1, R9
                RSUB    CAD_WRITE, 1
                XOR     R9, R9
                RSUB    CAD_WRITE, 1
                ADD     1, R6
                RBRA    _V0, 1

; ---------- V1: hoist the device/window selection, inline the 4 writes
_V1             MOVE    SIM_RAMROM_DEV, R7      ; select device once
                MOVE    SIM_VDRIVES_DEV, R2
                MOVE    @R2, @R7
                MOVE    SIM_RAMROM_4KWIN, R7    ; select CAD window once
                MOVE    0x0100, @R7
                MOVE    SIM_B_ADDR, R2
                MOVE    SIM_B_DOUT, R3
                MOVE    SIM_B_WREN, R4
_V1L            CMP     R6, R0
                RBRA    _DONE, Z
                MOVE    HANDLE_FILE, R8
                SYSCALL(f32_fread, 1)
                MOVE    R6, @R2
                MOVE    R9, @R3
                MOVE    1, @R4
                MOVE    0, @R4
                ADD     1, R6
                RBRA    _V1L, 1

; ---------- V2: SD hardware buffer byte, inlined window writes
_V2             MOVE    SIM_RAMROM_DEV, R7
                MOVE    SIM_VDRIVES_DEV, R8
                MOVE    @R8, @R7
                MOVE    SIM_RAMROM_4KWIN, R7
                MOVE    0x0100, @R7
                MOVE    SIM_B_ADDR, R2
                MOVE    SIM_B_DOUT, R3
                MOVE    SIM_B_WREN, R4
                MOVE    IO$SD_DATA_POS, R8
                MOVE    IO$SD_DATA, R9
_V2L            CMP     R6, R0
                RBRA    _DONE, Z
                MOVE    R6, @R8
                MOVE    @R9, R12
                MOVE    R6, @R2
                MOVE    R12, @R3
                MOVE    1, @R4
                MOVE    0, @R4
                ADD     1, R6
                RBRA    _V2L, 1

; ---------- V3: SD hardware buffer byte + auto-increment push register
_V3             MOVE    SIM_RAMROM_DEV, R7
                MOVE    SIM_VDRIVES_DEV, R8
                MOVE    @R8, @R7
                MOVE    SIM_RAMROM_4KWIN, R7
                MOVE    0x0100, @R7
                MOVE    SIM_B_PUSH, R3
                MOVE    IO$SD_DATA_POS, R8
                MOVE    IO$SD_DATA, R9
_V3L            CMP     R6, R0
                RBRA    _DONE, Z
                MOVE    R6, @R8
                MOVE    @R9, @R3
                ADD     1, R6
                RBRA    _V3L, 1

; ---------- V4/V5: the real code from M2M/rom/sdblock.asm
; The map is built once (that is the mount time cost, which cancels out
; because run.sh differences a 1 block and a 2 block run) and then every
; block is one SDB_VD_RDBLK / SDB_VD_WRBLK plus the copy loop.
_V4             RSUB    _VSETUP, 1
_V4L            CMP     R3, R2
                RBRA    _DONE, Z
                RSUB    _VPOS, 1                ; R10/R11: byte position
                XOR     R8, R8                  ; virtual drive 0
                MOVE    HANDLE_FILE, R9
                MOVE    0x0200, R12
                RSUB    SDB_VD_RDBLK, 1
                RBRA    _VERR, !C
                XOR     R8, R8
                RSUB    SDB_SD2VD, 1
                RSUB    SDB_VD_RDDONE, 1
                ADD     1, R3
                RBRA    _V4L, 1

_V5             RSUB    _VSETUP, 1
_V5L            CMP     R3, R2
                RBRA    _DONE, Z
                RSUB    _VPOS, 1
                XOR     R8, R8
                MOVE    HANDLE_FILE, R9
                MOVE    0x0200, R12
                RSUB    SDB_VD_WRBLK, 1
                RBRA    _VERR, !C
                ADD     1, R3
                RBRA    _V5L, 1

; ---------- V6: the current shell.asm write loop, _HDW_SD_LOOP: one
;            VD_CAD_WRITE plus one VD_DRV_READ plus one f32_fwrite per byte,
;            and one f32_fflush (an extra SD block write) per block
_V6             MOVE    R0, R2
                AND     0xFFFB, SR
                SHR     9, R2                   ; R2: amount of blocks
                XOR     R3, R3
_V6L            CMP     R3, R2
                RBRA    _DONE, Z
                MOVE    R3, R9                  ; VD_SD_SEEK, sequential case
                XOR     R10, R10
                RSUB    SDB_BLK2B, 1
                MOVE    HANDLE_FILE, R8
                SYSCALL(f32_fseek, 1)
                XOR     R6, R6
_V6B            MOVE    SIM_B_ADDR, R8          ; address within drive buffer
                MOVE    R6, R9
                RSUB    CAD_WRITE, 1
                MOVE    SIM_B_DIN, R8           ; byte from the drive buffer
                RSUB    DRV_READ, 1
                MOVE    R8, R9
                MOVE    HANDLE_FILE, R8
                SYSCALL(f32_fwrite, 1)
                ADD     1, R6
                CMP     0x0200, R6
                RBRA    _V6B, !Z
                MOVE    HANDLE_FILE, R8
                SYSCALL(f32_fflush, 1)
                ADD     1, R3
                RBRA    _V6L, 1

_VERR           HALT                            ; the map did not work: the
                                                ; measurement would be bogus

; R2: amount of blocks (NBYTES / 512), R3: block counter
_VSETUP         MOVE    HANDLE_FILE, R8
                MOVE    SDB_VD_MAPS, R9
                RSUB    SDB_MAP_BUILD, 1
                MOVE    R0, R2
                AND     0xFFFB, SR
                SHR     9, R2
                XOR     R3, R3
                RET

; R3: block index -> R10/R11: byte position
_VPOS           MOVE    R3, R9
                XOR     R10, R10
                RSUB    SDB_BLK2B, 1
                MOVE    R10, R11
                MOVE    R9, R10
                RET

_DONE           HALT

#include "../../M2M/rom/sdblock.asm"

CAD_WRITE       INCRB
                MOVE    SIM_RAMROM_DEV, R0
                MOVE    SIM_VDRIVES_DEV, R1
                MOVE    @R1, @R0
                MOVE    SIM_RAMROM_4KWIN, R0
                MOVE    0x0100, @R0
                MOVE    R9, @R8
                DECRB
                RET

; replica of M2M/rom/vdrives.asm VD_DRV_READ for virtual drive 0
DRV_READ        INCRB
                MOVE    SIM_RAMROM_DEV, R0
                MOVE    SIM_VDRIVES_DEV, R1
                MOVE    @R1, @R0
                MOVE    SIM_RAMROM_4KWIN, R0
                MOVE    0x0101, @R0
                MOVE    @R8, R8
                DECRB
                RET

HANDLE_FILE     .BLOCK FAT32$FDH_STRUCT_SIZE
STR_FILE        .ASCII_W "/freedos.vhd"
#include "bench_env.asm"
SIM_RAMROM_DEV   .DW 0
SIM_RAMROM_4KWIN .DW 0
SIM_VDRIVES_DEV  .DW 0x0102
SIM_B_ADDR       .DW 0
SIM_B_DOUT       .DW 0
SIM_B_WREN       .DW 0
SIM_B_DIN        .DW 0
SIM_B_PUSH       .DW 0
                 .ORG 0xA000
NBYTES           .DW 512
VARIANT          .DW 0
