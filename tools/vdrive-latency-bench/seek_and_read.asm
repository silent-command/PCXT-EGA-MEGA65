; PCXT-EGA-MEGA65: latency bench for the SD-direct vdrive block path.
; Counts QNICE instructions for the pieces of shell.asm HANDLE_DRV_RD.

#include "../../M2M/QNICE/dist_kit/sysdef.asm"
#include "../../M2M/QNICE/dist_kit/monitor.def"

                .ORG    0x8000

                MOVE    0xFEFF, SP

                MOVE    HANDLE_DEV, R8
                MOVE    1, R9
                SYSCALL(f32_mnt_sd, 1)
                MOVE    RESULTS, R0
                MOVE    R9, @R0

                MOVE    HANDLE_DEV, R8
                MOVE    HANDLE_FILE, R9
                MOVE    STR_FILE, R10
                XOR     R11, R11
                SYSCALL(f32_fopen, 1)
                MOVE    RESULTS, R0
                ADD     1, R0
                MOVE    R10, @R0

                ; ---- T0: calibration, empty measurement
                MOVE    IO$CYC_STATE, R7
                MOVE    1, @R7
                MOVE    2, R8
                RSUB    CYC_END, 1

                ; ---- warm up: read bytes 0..511 so a sector is buffered
                MOVE    512, R5
_W1             MOVE    HANDLE_FILE, R8
                SYSCALL(f32_fread, 1)
                SUB     1, R5
                RBRA    _W1, !Z

                ; ---- T1: 512 x f32_fread, sequential (one block, one SD read)
                MOVE    IO$CYC_STATE, R7
                MOVE    1, @R7
                MOVE    512, R5
_T1             MOVE    HANDLE_FILE, R8
                SYSCALL(f32_fread, 1)
                SUB     1, R5
                RBRA    _T1, !Z
                MOVE    4, R8
                RSUB    CYC_END, 1

                ; ---- T2: the real shell.asm per-byte loop (fread + 4 CAD writes)
                MOVE    IO$CYC_STATE, R7
                MOVE    1, @R7
                MOVE    512, R0
                XOR     R6, R6
_T2             CMP     R6, R0
                RBRA    _T2_DONE, Z
                MOVE    HANDLE_FILE, R8
                SYSCALL(f32_fread, 1)
                CMP     0, R10
                RBRA    _T2_OK, Z
                RBRA    _T2_DONE, 1
_T2_OK          MOVE    R9, R12
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
                RBRA    _T2, 1
_T2_DONE        MOVE    6, R8
                RSUB    CYC_END, 1

                ; ---- T3: f32_fseek to LBA 100
                MOVE    IO$CYC_STATE, R7
                MOVE    1, @R7
                MOVE    HANDLE_FILE, R8
                MOVE    0xC800, R9
                XOR     R10, R10
                SYSCALL(f32_fseek, 1)
                MOVE    8, R8
                RSUB    CYC_END, 1

                ; ---- T4: f32_fseek to LBA 1000
                MOVE    IO$CYC_STATE, R7
                MOVE    1, @R7
                MOVE    HANDLE_FILE, R8
                MOVE    0xD000, R9
                MOVE    0x0007, R10
                SYSCALL(f32_fseek, 1)
                MOVE    10, R8
                RSUB    CYC_END, 1

                ; ---- T5: f32_fseek to LBA 10000
                MOVE    IO$CYC_STATE, R7
                MOVE    1, @R7
                MOVE    HANDLE_FILE, R8
                MOVE    0x2000, R9
                MOVE    0x004E, R10
                SYSCALL(f32_fseek, 1)
                MOVE    12, R8
                RSUB    CYC_END, 1

                ; ---- T6: f32_fseek to LBA 80000
                MOVE    IO$CYC_STATE, R7
                MOVE    1, @R7
                MOVE    HANDLE_FILE, R8
                MOVE    0x0000, R9
                MOVE    0x0271, R10
                SYSCALL(f32_fseek, 1)
                MOVE    14, R8
                RSUB    CYC_END, 1

                ; ---- T7: bulk alternative: raw SD buffer byte + 1 CAD write
                MOVE    IO$CYC_STATE, R7
                MOVE    1, @R7
                MOVE    512, R0
                XOR     R6, R6
_T7             CMP     R6, R0
                RBRA    _T7_DONE, Z
                MOVE    IO$SD_DATA_POS, R8
                MOVE    R6, @R8
                MOVE    IO$SD_DATA, R8
                MOVE    @R8, R12
                MOVE    SIM_B_DOUT, R8
                MOVE    R12, R9
                RSUB    CAD_WRITE, 1
                ADD     1, R6
                RBRA    _T7, 1
_T7_DONE        MOVE    16, R8
                RSUB    CYC_END, 1

                ; ---- T8: one FAT32$RW_SIC-sized SD block read via SD library
                MOVE    IO$CYC_STATE, R7
                MOVE    1, @R7
                MOVE    0x0A00, R8
                XOR     R9, R9
                SYSCALL(sd_r_block, 1)
                MOVE    18, R8
                RSUB    CYC_END, 1

                HALT

; stop the counter and store it: R8 = slot index
CYC_END         MOVE    IO$CYC_STATE, R9
                MOVE    0, @R9
                MOVE    RESULTS, R10
                ADD     R8, R10
                MOVE    IO$CYC_LO, R9
                MOVE    @R9, @R10
                ADD     1, R10
                MOVE    IO$CYC_MID, R9
                MOVE    @R9, @R10
                RET

; exact replica of M2M/rom/vdrives.asm VD_CAD_WRITE
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
                 .ORG 0xA000
RESULTS          .BLOCK 32
