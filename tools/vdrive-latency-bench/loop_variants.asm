; Variant loops for the SD-direct block read.  VARIANT at 0xA002:
;   0 = current shell.asm loop (f32_fread + 4x VD_CAD_WRITE)
;   1 = FIX1: f32_fread + inlined 4 window writes (device/window hoisted)
;   2 = FIX2: SD hardware buffer byte + inlined 4 window writes
;   3 = FIX3: SD hardware buffer byte + auto-increment push register
#include "../../M2M/QNICE/dist_kit/sysdef.asm"
#include "../../M2M/QNICE/dist_kit/monitor.def"
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
                RBRA    _V3, 1

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

_DONE           HALT

CAD_WRITE       INCRB
                MOVE    SIM_RAMROM_DEV, R0
                MOVE    SIM_VDRIVES_DEV, R1
                MOVE    @R1, @R0
                MOVE    SIM_RAMROM_4KWIN, R0
                MOVE    0x0100, @R0
                MOVE    R9, @R8
                DECRB
                RET

HANDLE_DEV      .BLOCK FAT32$DEV_STRUCT_SIZE
HANDLE_FILE     .BLOCK FAT32$FDH_STRUCT_SIZE
STR_FILE        .ASCII_W "/freedos.vhd"
SIM_RAMROM_DEV   .DW 0
SIM_RAMROM_4KWIN .DW 0
SIM_VDRIVES_DEV  .DW 0x0102
SIM_B_ADDR       .DW 0
SIM_B_DOUT       .DW 0
SIM_B_WREN       .DW 0
SIM_B_PUSH       .DW 0
                 .ORG 0xA000
NBYTES           .DW 512
VARIANT          .DW 0
