; Correctness bench for the SD-direct fast path in M2M/rom/sdblock.asm.
;
; Runs the REAL firmware routines (sdblock.asm is included verbatim, the few
; shell.asm variables it needs come from bench_env.asm) against the REAL
; FAT32 library of the QNICE Monitor and compares, byte for byte, what the
; fast path delivers with what the original f32_fread path delivers.
;
; Needs a *writable* image: run.sh points it at sd_rw.img.
;
; Output is plain text on the emulator console, one line per check, plus a
; PASS/FAIL summary at the end.

#include "../../M2M/QNICE/dist_kit/sysdef.asm"
#include "../../M2M/QNICE/dist_kit/monitor.def"
#include "../../M2M/rom/sysdef.asm"

                .ORG    0x8000
                MOVE    0xFEE0, SP

                ; ---- mount the SD card
                MOVE    HANDLE_DEV, R8
                MOVE    1, R9
                SYSCALL(f32_mnt_sd, 1)
                CMP     0, R9
                RBRA    _MOUNTED, Z
                MOVE    S_EMNT, R8
                SYSCALL(puts, 1)
                MOVE    R9, R8
                SYSCALL(puthex, 1)
                SYSCALL(crlf, 1)
                HALT

; ============================================================================
; Test 1: the 42 MB, contiguous image file
; ============================================================================
_MOUNTED        MOVE    S_T1, R8
                SYSCALL(puts, 1)
                MOVE    F_FREEDOS, R8
                RSUB    OPEN, 1

                ; the one-off mount time cost: walking 1344 cluster chain
                ; entries, in emulator instructions
                MOVE    IO$CYC_STATE, R8
                MOVE    1, @R8
                MOVE    IO$CYC_LO, R8
                MOVE    @R8, R4
                MOVE    IO$CYC_MID, R8
                MOVE    @R8, R5
                MOVE    HANDLE_FILE, R8
                MOVE    SDB_VD_MAPS, R9
                RSUB    SDB_MAP_BUILD, 1
                MOVE    IO$CYC_LO, R8
                MOVE    @R8, R6
                MOVE    IO$CYC_MID, R8
                MOVE    @R8, R7
                SUB     R4, R6
                SUBC    R5, R7
                MOVE    S_MAPC, R8
                SYSCALL(puts, 1)
                MOVE    R7, R8
                SYSCALL(puthex, 1)
                MOVE    R6, R8
                SYSCALL(puthex, 1)
                SYSCALL(crlf, 1)

                MOVE    SDB_VD_MAPS, R8
                RSUB    PRMAP, 1

                ; blocks to check: first, second, around the 64 sector
                ; cluster boundary, a marker block, the last one, and two
                ; blocks past the end of the file
                MOVE    T1_BLKS, R0
_T1_L           MOVE    @R0++, R9               ; block index lo
                MOVE    @R0++, R10              ; block index hi
                MOVE    @R0++, R11              ; expectation: 0=ok 1=nomap
                CMP     0xFFFF, R11
                RBRA    _T1B, Z
                MOVE    HANDLE_FILE, R8
                RSUB    CHKBLK, 1
                RSUB    VERDICT, 1
                RBRA    _T1_L, 1

                ; and 16 pseudo random blocks spread over the whole image
_T1B            MOVE    S_T1B, R8
                SYSCALL(puts, 1)
                MOVE    16, R0                  ; R0: blocks still to check
                MOVE    0x1234, R1              ; R1/R2: LCG state
                MOVE    0x5678, R2
                XOR     R3, R3                  ; R3: amount of bad blocks
_T1B_L          MOVE    0x4E6D, R8              ; state = state * 0x41C64E6D
                MOVE    0x41C6, R9              ; .. + 12345 (the classic one)
                MOVE    R1, R10
                MOVE    R2, R11
                SYSCALL(mulu32, 1)
                ADD     0x3039, R8
                ADDC    0, R9
                MOVE    R8, R1
                MOVE    R9, R2
                MOVE    R2, R10                 ; block = state >> 16, which
                AND     0x0001, R10             ; .. is 0 .. 131071, then
                MOVE    R1, R9                  ; .. masked into the image
                CMP     1, R10
                RBRA    _T1B_C, !Z
                CMP     0x5000, R9              ; keep it below 86016
                RBRA    _T1B_C, N               ; still inside the image
                XOR     R10, R10                ; no: fold it down
_T1B_C          MOVE    HANDLE_FILE, R8
                RSUB    CHKBLK, 1
                CMP     0, R8
                RBRA    _T1B_N, Z
                ADD     1, R3
_T1B_N          SUB     1, R0
                RBRA    _T1B_L, !Z
                MOVE    R3, R8
                RSUB    VERDICT0, 1

; ============================================================================
; Test 2: a file that is not one block long and not block aligned
; ============================================================================
_T2             MOVE    S_T2, R8
                SYSCALL(puts, 1)
                XOR     R8, R8                  ; virtual drive 0
                MOVE    HANDLE_FILE, R9
                XOR     R10, R10                ; byte position 0
                XOR     R11, R11
                MOVE    0x0100, R12             ; 256 bytes: not a block
                RSUB    SDB_VD_RDBLK, 1
                RBRA    _T2_F1, C
                MOVE    S_OK, R8
                RBRA    _T2_P1, 1
_T2_F1          MOVE    S_FAIL, R8
                RSUB    BUMPFAIL, 1
_T2_P1          SYSCALL(puts, 1)

                MOVE    S_T2B, R8
                SYSCALL(puts, 1)
                XOR     R8, R8
                MOVE    HANDLE_FILE, R9
                MOVE    0x0100, R10             ; byte position 256
                XOR     R11, R11
                MOVE    0x0200, R12
                RSUB    SDB_VD_RDBLK, 1
                RBRA    _T2_F2, C
                MOVE    S_OK, R8
                RBRA    _T2_P2, 1
_T2_F2          MOVE    S_FAIL, R8
                RSUB    BUMPFAIL, 1
_T2_P2          SYSCALL(puts, 1)

; ============================================================================
; Test 3: read after write, both directions
; ============================================================================
                MOVE    S_T3, R8
                SYSCALL(puts, 1)

                ; (a) direct write, then read back through the FAT32 library
                MOVE    BUF_A, R8
                MOVE    0x0055, R9
                RSUB    PATTERN, 1
                MOVE    T3_BLK, R9
                MOVE    @R9, R9
                XOR     R10, R10
                RSUB    WRBLK, 1                ; fills the drive buffer and
                RBRA    _T3_NOMAP, !C           ; ..calls SDB_VD_WRBLK

                MOVE    T3_BLK, R9
                MOVE    @R9, R9
                XOR     R10, R10
                MOVE    HANDLE_FILE, R8
                RSUB    RDSLOW, 1               ; f32 read into BUF_B
                MOVE    BUF_A, R8
                MOVE    BUF_B, R9
                RSUB    CMP512, 1
                RSUB    VERDICT0, 1

                ; (b) the same block through the fast read path
                MOVE    S_T3B, R8
                SYSCALL(puts, 1)
                MOVE    HANDLE_FILE, R8
                MOVE    T3_BLK, R9
                MOVE    @R9, R9
                XOR     R10, R10
                RSUB    CHKBLK, 1               ; fast vs slow, both re-read
                RSUB    VERDICT0, 1

                ; (c) write through the FAT32 library, read through the fast
                ;     path: this is the direction that would show a stale
                ;     buffer if SDB_FLUSHINV were missing
                MOVE    S_T3C, R8
                SYSCALL(puts, 1)
                MOVE    BUF_A, R8
                MOVE    0x00A7, R9
                RSUB    PATTERN, 1
                MOVE    HANDLE_FILE, R8
                MOVE    T3_BLK, R9
                MOVE    @R9, R9
                XOR     R10, R10
                RSUB    WRSLOW, 1               ; f32_fwrite + f32_fflush
                MOVE    HANDLE_FILE, R8
                MOVE    T3_BLK, R9
                MOVE    @R9, R9
                XOR     R10, R10
                RSUB    RDFAST, 1               ; SDB_VD_RDBLK into BUF_B
                RBRA    _T3_NOMAP, !C
                MOVE    BUF_A, R8
                MOVE    BUF_B, R9
                RSUB    CMP512, 1
                RSUB    VERDICT0, 1
                RBRA    _T4, 1
_T3_NOMAP       MOVE    S_FAIL, R8
                SYSCALL(puts, 1)
                RSUB    BUMPFAIL, 1

; ============================================================================
; Test 4: a file with three extents - all of its blocks, byte for byte
; ============================================================================
_T4             MOVE    S_T4, R8
                SYSCALL(puts, 1)
                MOVE    F_FRAG3, R8
                RSUB    OPEN, 1
                MOVE    HANDLE_FILE, R8
                MOVE    SDB_VD_MAPS, R9
                RSUB    SDB_MAP_BUILD, 1
                MOVE    SDB_VD_MAPS, R8
                RSUB    PRMAP, 1

                MOVE    SDB_VD_MAPS, R8
                ADD     SDB_M_TBLK_LO, R8
                MOVE    @R8, R0                 ; R0: amount of blocks
                XOR     R1, R1                  ; R1: block index
                XOR     R2, R2                  ; R2: amount of bad blocks
_T4_L           CMP     R1, R0
                RBRA    _T4_D, Z
                MOVE    HANDLE_FILE, R8
                MOVE    R1, R9
                XOR     R10, R10
                RSUB    CHKBLK, 1
                CMP     0, R8
                RBRA    _T4_N, Z
                ADD     1, R2
_T4_N           ADD     1, R1
                RBRA    _T4_L, 1
_T4_D           MOVE    R0, R8
                SYSCALL(puthex, 1)
                MOVE    S_BLOCKS, R8
                SYSCALL(puts, 1)
                MOVE    R2, R8
                RSUB    VERDICT0, 1

; ============================================================================
; Test 5: a file with twelve extents - must fall back, silently
; ============================================================================
                MOVE    S_T5, R8
                SYSCALL(puts, 1)
                MOVE    F_FRAG16, R8
                RSUB    OPEN, 1
                MOVE    HANDLE_FILE, R8
                MOVE    SDB_VD_MAPS, R9
                RSUB    SDB_MAP_BUILD, 1
                MOVE    SDB_VD_MAPS, R8
                RSUB    PRMAP, 1
                MOVE    SDB_VD_MAPS, R8
                CMP     0, @R8                  ; must be "no map"
                RBRA    _T5_F, !Z
                XOR     R8, R8                  ; ..and the entry point must
                MOVE    HANDLE_FILE, R9         ; ..report the fallback
                XOR     R10, R10
                XOR     R11, R11
                MOVE    0x0200, R12
                RSUB    SDB_VD_RDBLK, 1
                RBRA    _T5_F, C
                MOVE    S_OK, R8
                RBRA    _T5_P, 1
_T5_F           MOVE    S_FAIL, R8
                RSUB    BUMPFAIL, 1
_T5_P           SYSCALL(puts, 1)

; ============================================================================
; Test 6: SDB_FREAD_FAST, the CRT/ROM loader path
;   6a: a file that fits into one 4k window, all bytes are checked
;   6b: a 16 KB file, so that the 4k window wrap is exercised; the last
;       window and the byte-wise tail are checked
; ============================================================================
                MOVE    S_T6A, R8
                SYSCALL(puts, 1)
                MOVE    F_SMALL, R8
                MOVE    1636, R9                ; file size
                RSUB    CHKROM, 1

                MOVE    S_T6B, R8
                SYSCALL(puts, 1)
                MOVE    F_TESTROM, R8
                MOVE    16684, R9               ; file size
                RSUB    CHKROM, 1

                ; A file that ends exactly on a cluster boundary. Seeking such
                ; a file to its very end walks one step past the last cluster,
                ; and FAT32$RW_SIC then issues a block read at a wild LBA,
                ; which latches the error state of the real SD controller.
                ; The fast path must stop one whole block short, so that the
                ; position it hands over is always strictly inside the file.
                MOVE    S_T6C, R8
                SYSCALL(puts, 1)
                MOVE    F_EXACT, R8
                MOVE    32768, R9               ; exactly one 64 sector cluster
                RSUB    CHKROM, 1

; ============================================================================
; Test 7: after a map build that gives up, the FAT32 library must be exactly
;         where it was. This is the property that broke on real hardware.
; ============================================================================
                MOVE    S_T7, R8
                SYSCALL(puts, 1)
                MOVE    F_FRAG16, R8            ; twelve extents: always bails
                RSUB    OPEN, 1
                MOVE    HANDLE_FILE, R8         ; reference: read 512 bytes
                MOVE    BUF_A, R9               ; ..before doing anything
                RSUB    FREAD512, 1
                MOVE    HANDLE_FILE, R8
                XOR     R9, R9
                XOR     R10, R10
                SYSCALL(f32_fseek, 1)
                MOVE    HANDLE_FILE, R8         ; now let the map build run
                MOVE    SDB_RM_MAP, R9          ; ..and give up half way
                RSUB    SDB_MAP_BUILD, 1
                MOVE    HANDLE_FILE, R8         ; the very next library read
                MOVE    BUF_B, R9               ; ..must still be correct
                RSUB    FREAD512, 1
                MOVE    BUF_A, R8
                MOVE    BUF_B, R9
                RSUB    CMP512, 1
                RSUB    VERDICT0, 1

                ; the same for a vdrive block read that uses the fast path:
                ; it must not disturb a second, unrelated file handle
                MOVE    S_T7B, R8
                SYSCALL(puts, 1)
                MOVE    F_FREEDOS, R8
                RSUB    OPEN, 1
                MOVE    HANDLE_FILE, R8
                MOVE    SDB_VD_MAPS, R9
                RSUB    SDB_MAP_BUILD, 1
                MOVE    HANDLE_DEV, R8          ; a second file, positioned
                MOVE    HANDLE_FILE2, R9        ; ..somewhere in the middle
                MOVE    F_FRAG3, R10
                XOR     R11, R11
                SYSCALL(f32_fopen, 1)
                MOVE    HANDLE_FILE2, R8
                MOVE    0x2600, R9              ; byte 9728, inside extent 1
                XOR     R10, R10
                SYSCALL(f32_fseek, 1)
                MOVE    HANDLE_FILE2, R8        ; reference bytes
                MOVE    BUF_A, R9
                RSUB    FREAD512, 1
                MOVE    HANDLE_FILE2, R8
                MOVE    0x2600, R9
                XOR     R10, R10
                SYSCALL(f32_fseek, 1)
                XOR     R8, R8                  ; a fast vdrive block read in
                MOVE    HANDLE_FILE, R9         ; ..between, on the other file
                MOVE    0x0000, R10
                MOVE    0x0002, R11             ; byte 131072 of freedos.vhd
                MOVE    0x0200, R12
                RSUB    SDB_VD_RDBLK, 1
                RBRA    _T7B_NO, !C
                XOR     R8, R8
                RSUB    SDB_SD2VD, 1
                RSUB    SDB_VD_RDDONE, 1
                MOVE    HANDLE_FILE2, R8        ; ..and the second handle must
                MOVE    BUF_B, R9               ; ..still read the same bytes
                RSUB    FREAD512, 1
                MOVE    BUF_A, R8
                MOVE    BUF_B, R9
                RSUB    CMP512, 1
                RSUB    VERDICT0, 1
                RBRA    _T7B_D, 1
_T7B_NO         MOVE    S_NOMAP, R8
                SYSCALL(puts, 1)
                RSUB    BUMPFAIL, 1
_T7B_D          MOVE    S_NUL, R8
                SYSCALL(puts, 1)

; ============================================================================
                MOVE    S_SUM, R8
                SYSCALL(puts, 1)
                MOVE    NFAIL, R8
                MOVE    @R8, R8
                RBRA    _SUM_F, !Z
                MOVE    S_PASS, R8
                SYSCALL(puts, 1)
                HALT
_SUM_F          SYSCALL(puthex, 1)
                MOVE    S_FAILS, R8
                SYSCALL(puts, 1)
                HALT

; ============================================================================
; Helpers
; ============================================================================

; open a file, R8 = name
OPEN            INCRB
                MOVE    R8, R0
                MOVE    HANDLE_DEV, R8
                MOVE    HANDLE_FILE, R9
                MOVE    R0, R10
                XOR     R11, R11
                SYSCALL(f32_fopen, 1)
                CMP     0, R10
                RBRA    _OPEN_R, Z
                MOVE    S_EOPEN, R8
                SYSCALL(puts, 1)
                MOVE    R10, R8
                SYSCALL(puthex, 1)
                SYSCALL(crlf, 1)
                HALT
_OPEN_R         DECRB
                RET

; print the interesting parts of a block map, R8 = map
PRMAP           INCRB
                MOVE    R8, R0
                MOVE    S_MAPE, R8
                SYSCALL(puts, 1)
                MOVE    @R0, R8
                SYSCALL(puthex, 1)
                MOVE    S_MAPT, R8
                SYSCALL(puts, 1)
                MOVE    R0, R8
                ADD     SDB_M_TBLK_HI, R8
                MOVE    @R8, R8
                SYSCALL(puthex, 1)
                MOVE    R0, R8
                ADD     SDB_M_TBLK_LO, R8
                MOVE    @R8, R8
                SYSCALL(puthex, 1)
                MOVE    S_MAPL, R8
                SYSCALL(puts, 1)
                MOVE    R0, R8
                ADD     SDB_M_EXT, R8
                ADD     SDB_E_LBA_HI, R8
                MOVE    @R8, R8
                SYSCALL(puthex, 1)
                MOVE    R0, R8
                ADD     SDB_M_EXT, R8
                ADD     SDB_E_LBA_LO, R8
                MOVE    @R8, R8
                SYSCALL(puthex, 1)
                SYSCALL(crlf, 1)
                DECRB
                RET

; ---- fill a 512 word buffer with a seeded pattern. R8: buffer, R9: seed
PATTERN         INCRB
                MOVE    R8, R0
                MOVE    R9, R1
                XOR     R2, R2
_PAT_L          MOVE    R1, @R0++
                ADD     0x001F, R1
                AND     0x00FF, R1
                ADD     1, R2
                CMP     0x0200, R2
                RBRA    _PAT_L, !Z
                DECRB
                RET

; ---- copy the 512 byte SD controller buffer into a word buffer. R8: buffer
SD2MEM          INCRB
                MOVE    IO$SD_DATA_POS, R0
                MOVE    IO$SD_DATA, R1
                MOVE    R8, R2
                XOR     R3, R3
_S2M_L          MOVE    R3, @R0
                MOVE    @R1, @R2++
                ADD     1, R3
                CMP     0x0200, R3
                RBRA    _S2M_L, !Z
                DECRB
                RET

; ---- read a block through the FAT32 library into BUF_B
;      R8: FDH, R9/R10: block index lo/hi
RDSLOW          INCRB
                MOVE    R8, R0
                RSUB    SDB_BLK2B, 1
                SYSCALL(f32_fseek, 1)
                MOVE    R0, R8
                MOVE    BUF_B, R9
                RSUB    FREAD512, 1
                MOVE    R0, R8
                DECRB
                RET

; ---- write a block through the FAT32 library from BUF_A
;      R8: FDH, R9/R10: block index lo/hi
WRSLOW          INCRB
                MOVE    R8, R0
                RSUB    SDB_BLK2B, 1
                SYSCALL(f32_fseek, 1)
                MOVE    BUF_A, R1
                MOVE    0x0200, R2
_WRS_L          MOVE    R0, R8
                MOVE    @R1++, R9
                SYSCALL(f32_fwrite, 1)
                SUB     1, R2
                RBRA    _WRS_L, !Z
                MOVE    R0, R8
                SYSCALL(f32_fflush, 1)
                MOVE    R0, R8
                DECRB
                RET

; ---- read a block through the fast path into BUF_B
;      R8: FDH, R9/R10: block index lo/hi; Carry=1 if the fast path was used
RDFAST          INCRB
                MOVE    R8, R0
                RSUB    SDB_BLK2B, 1
                MOVE    R10, R11
                MOVE    R9, R10
                XOR     R8, R8
                MOVE    R0, R9
                MOVE    0x0200, R12
                RSUB    SDB_VD_RDBLK, 1
                RBRA    _RDF_NO, !C
                MOVE    BUF_B, R8
                RSUB    SD2MEM, 1
                RSUB    SDB_VD_RDDONE, 1        ; hand the buffer back
                MOVE    R0, R8
                OR      0x0004, SR
                RBRA    _RDF_R, 1
_RDF_NO         MOVE    R0, R8
                AND     0xFFFB, SR
_RDF_R          DECRB
                RET

; ---- write a block through the fast path from BUF_A. The virtual drive
;      buffer is not emulated, so the bytes are staged in the SD controller
;      buffer and SDB_VD_WRBLK is told to write exactly that block: this
;      exercises the mapping, the flush/invalidate and the SD write, but not
;      the vdrives.vhd register protocol (only hardware can show that).
;      R9/R10: block index lo/hi; Carry=1 on success
WRBLK           INCRB
                MOVE    R9, R0
                MOVE    R10, R1
                RSUB    SDB_BLK2B, 1
                MOVE    R9, R2                  ; R2/R3: byte position
                MOVE    R10, R3

                MOVE    SDB_VD_MAPS, R8         ; LBA of that block
                MOVE    R0, R9
                MOVE    R1, R10
                RSUB    SDB_LBA, 1
                RBRA    _WRB_NO, !C
                MOVE    R9, R4                  ; R4/R5: LBA
                MOVE    R10, R5

                RSUB    SDB_GUARD_IN, 1         ; same order as SDB_VD_WRBLK
                RBRA    _WRB_NO, !C
                MOVE    IO$SD_DATA_POS, R6
                MOVE    IO$SD_DATA, R7
                MOVE    BUF_A, R8
                XOR     R9, R9
_WRB_L          MOVE    R9, @R6
                MOVE    @R8++, @R7
                ADD     1, R9
                CMP     0x0200, R9
                RBRA    _WRB_L, !Z
                MOVE    R4, R8
                MOVE    R5, R9
                SYSCALL(sd_w_block, 1)
                MOVE    R8, R3                  ; remember the error code
                RSUB    SDB_GUARD_OUT, 1        ; hand the buffer back
                CMP     0, R3
                RBRA    _WRB_NO, !Z
                OR      0x0004, SR
                RBRA    _WRB_R, 1
_WRB_NO         AND     0xFFFB, SR
_WRB_R          DECRB
                RET

; ---- read 512 bytes with f32_fread. R8: FDH, R9: destination buffer
FREAD512        INCRB
                MOVE    R8, R0
                MOVE    R9, R1
                MOVE    0x0200, R2
_FR5_L          MOVE    R0, R8
                SYSCALL(f32_fread, 1)
                CMP     0, R10
                RBRA    _FR5_1, Z
                XOR     R9, R9                  ; EOF and errors read as zero
_FR5_1          MOVE    R9, @R1++
                SUB     1, R2
                RBRA    _FR5_L, !Z
                MOVE    R0, R8
                DECRB
                RET

; ---- compare two 512 word buffers. R8, R9 -> R8 = 0 if equal, else the
;      index of the first difference plus one
CMP512          INCRB
                MOVE    R8, R0
                MOVE    R9, R1
                XOR     R2, R2
_C5_L           CMP     @R0++, @R1++
                RBRA    _C5_NE, !Z
                ADD     1, R2
                CMP     0x0200, R2
                RBRA    _C5_L, !Z
                XOR     R8, R8
                RBRA    _C5_R, 1
_C5_NE          MOVE    R2, R8
                ADD     1, R8
_C5_R           DECRB
                RET

; ---- the central comparison: read one block of the file through the fast
;      path and through the FAT32 library and compare byte for byte.
;      R8: FDH, R9/R10: block index lo/hi
;      Returns R8: 0 = identical, 1 = no fast path, else difference index + 2
CHKBLK          SYSCALL(enter, 1)
                MOVE    R8, R0
                MOVE    R9, R1
                MOVE    R10, R2

                MOVE    R0, R8
                MOVE    R1, R9
                MOVE    R2, R10
                RSUB    RDFAST, 1
                RBRA    _CB_MAP, C
                MOVE    1, R8
                RBRA    _CB_RET, 1
_CB_MAP         MOVE    BUF_B, R8               ; keep the fast result
                MOVE    BUF_A, R9
                RSUB    COPY512, 1
                MOVE    R0, R8
                MOVE    R1, R9
                MOVE    R2, R10
                RSUB    RDSLOW, 1
                MOVE    BUF_A, R8
                MOVE    BUF_B, R9
                RSUB    CMP512, 1
                CMP     0, R8
                RBRA    _CB_RET, Z
                ADD     1, R8
_CB_RET         MOVE    R8, @--SP
                SYSCALL(leave, 1)
                MOVE    @SP++, R8
                RET

COPY512         INCRB
                MOVE    R8, R0
                MOVE    R9, R1
                MOVE    0x0200, R2
_CP5_L          MOVE    @R0++, @R1++
                SUB     1, R2
                RBRA    _CP5_L, !Z
                DECRB
                RET

; ---- CRT/ROM loader check.
;      R8: file name, R9: file size in bytes (< 64 KB)
;
;      Works out for itself what SDB_FREAD_FAST is supposed to do: it takes
;      all whole 512-byte blocks except the last one, so
;        blocks = size/512 - 1, bytes = blocks*512,
;        window = bytes/4096, address = 0x7000 + bytes mod 4096
;      Then it checks
;        (a) the returned 4k window and address,
;        (b) that the handed-over file position is exactly "bytes",
;        (c) that reading the rest byte-wise yields exactly (size - bytes)
;            bytes and then EOF, with the right content, read through a
;            second file handle on the same device so that the two handles
;            fight over the FAT32 library's one sector buffer,
;        (d) every byte still visible in the 4k window against f32_fread.
CHKROM          SYSCALL(enter, 1)
                MOVE    R9, R0                  ; R0: file size
                MOVE    R8, R2                  ; R2: file name
                RSUB    OPEN, 1

                MOVE    R0, R1                  ; R1: bytes taken by the
                AND     0xFFFB, SR              ; ..fast path
                SHR     9, R1
                SUB     1, R1
                AND     0xFFFD, SR
                SHL     9, R1

                MOVE    R1, R3                  ; R3: expected 4k window
                AND     0xFFFB, SR
                SHR     12, R3
                MOVE    R1, R4                  ; R4: expected address
                AND     0x0FFF, R4
                ADD     M2M$RAMROM_DATA, R4

                MOVE    HANDLE_FILE, R8
                MOVE    SDB_RM_MAP, R9
                RSUB    SDB_MAP_BUILD, 1
                MOVE    HANDLE_FILE, R8
                MOVE    SDB_RM_MAP, R9
                MOVE    0x00AB, R10             ; target device (ignored here)
                XOR     R11, R11                ; target 4k window
                MOVE    M2M$RAMROM_DATA, R12    ; plain RAM in the emulator
                RSUB    SDB_FREAD_FAST, 1
                RBRA    _CR_NO, !C
                CMP     R3, R11                 ; (a) window as expected?
                RBRA    _CR_BAD, !Z
                CMP     R4, R12                 ;     address as expected?
                RBRA    _CR_BAD, !Z

                ; (b) the file position must be exactly R1
                MOVE    HANDLE_FILE, R8
                ADD     FAT32$FDH_ACCESS_HI, R8
                CMP     0, @R8
                RBRA    _CR_BAD, !Z
                MOVE    HANDLE_FILE, R8
                ADD     FAT32$FDH_ACCESS_LO, R8
                CMP     R1, @R8
                RBRA    _CR_BAD, !Z

                ; (c) the tail, alternating between two file handles
                MOVE    HANDLE_DEV, R8
                MOVE    HANDLE_FILE2, R9
                MOVE    R2, R10
                XOR     R11, R11
                SYSCALL(f32_fopen, 1)
                CMP     0, R10
                RBRA    _CR_BAD, !Z
                MOVE    HANDLE_FILE2, R8
                MOVE    R1, R9
                XOR     R10, R10
                SYSCALL(f32_fseek, 1)
                CMP     0, R9
                RBRA    _CR_BAD, !Z

                MOVE    R0, R7                  ; R7: tail bytes still to go
                SUB     R1, R7
_CR_TL          CMP     0, R7
                RBRA    _CR_TD, Z
                MOVE    HANDLE_FILE, R8
                SYSCALL(f32_fread, 1)
                CMP     0, R10                  ; tail must not be short
                RBRA    _CR_BAD, !Z
                MOVE    R9, R5
                MOVE    HANDLE_FILE2, R8
                SYSCALL(f32_fread, 1)
                CMP     0, R10
                RBRA    _CR_BAD, !Z
                CMP     R5, R9                  ; both handles must agree
                RBRA    _CR_BAD, !Z
                SUB     1, R7
                RBRA    _CR_TL, 1
_CR_TD          MOVE    HANDLE_FILE, R8
                SYSCALL(f32_fread, 1)
                CMP     FAT32$EOF, R10          ; ..and must not be long
                RBRA    _CR_BAD, !Z

                ; (d) the bytes that are still visible in the 4k window
                MOVE    R3, R5                  ; R5: their file offset
                AND     0xFFFD, SR
                SHL     12, R5
                MOVE    R1, R7                  ; R7: how many of them
                SUB     R5, R7
                RBRA    _CR_OK, Z               ; the window is empty
                MOVE    HANDLE_FILE, R8
                MOVE    R5, R9
                XOR     R10, R10
                SYSCALL(f32_fseek, 1)
                CMP     0, R9
                RBRA    _CR_BAD, !Z
                MOVE    M2M$RAMROM_DATA, R6
_CR_CL          MOVE    HANDLE_FILE, R8
                SYSCALL(f32_fread, 1)
                CMP     0, R10
                RBRA    _CR_BAD, !Z
                CMP     @R6++, R9
                RBRA    _CR_BAD, !Z
                SUB     1, R7
                RBRA    _CR_CL, !Z

_CR_OK          MOVE    S_OK, R8
                RBRA    _CR_P, 1
_CR_NO          MOVE    S_NOMAP, R8
                RSUB    BUMPFAIL, 1
                RBRA    _CR_P, 1
_CR_BAD         MOVE    S_FAIL, R8
                RSUB    BUMPFAIL, 1
_CR_P           SYSCALL(puts, 1)
                SYSCALL(leave, 1)
                RET

; ---- verdict for CHKBLK, honouring the expectation in R11 (0 = must be
;      readable through the fast path, 1 = must fall back)
VERDICT         INCRB
                MOVE    R8, R0
                CMP     1, R11
                RBRA    _VD_WANT_OK, !Z
                CMP     1, R0                   ; fallback expected
                RBRA    _VD_OK, Z
                RBRA    _VD_BAD, 1
_VD_WANT_OK     CMP     0, R0
                RBRA    _VD_OK, Z
_VD_BAD         MOVE    S_FAIL, R8
                SYSCALL(puts, 1)
                MOVE    R0, R8
                SYSCALL(puthex, 1)
                SYSCALL(crlf, 1)
                RSUB    BUMPFAIL, 1
                RBRA    _VD_R, 1
_VD_OK          MOVE    S_OK, R8
                SYSCALL(puts, 1)
_VD_R           DECRB
                RET

; ---- verdict for a plain "must be zero" result in R8
VERDICT0        INCRB
                MOVE    R8, R0
                CMP     0, R0
                RBRA    _VD0_OK, Z
                MOVE    S_FAIL, R8
                SYSCALL(puts, 1)
                MOVE    R0, R8
                SYSCALL(puthex, 1)
                SYSCALL(crlf, 1)
                RSUB    BUMPFAIL, 1
                RBRA    _VD0_R, 1
_VD0_OK         MOVE    S_OK, R8
                SYSCALL(puts, 1)
_VD0_R          DECRB
                RET

BUMPFAIL        INCRB
                MOVE    NFAIL, R0
                ADD     1, @R0
                DECRB
                RET

; ============================================================================
#include "../../M2M/rom/sdblock.asm"
; ============================================================================

HANDLE_FILE     .BLOCK FAT32$FDH_STRUCT_SIZE
HANDLE_FILE2    .BLOCK FAT32$FDH_STRUCT_SIZE
F_FREEDOS       .ASCII_W "/freedos.vhd"
F_FRAG3         .ASCII_W "/frag3.vhd"
F_FRAG16        .ASCII_W "/frag16.vhd"
F_TESTROM       .ASCII_W "/testrom.bin"
F_SMALL         .ASCII_W "/small.bin"
F_EXACT         .ASCII_W "/exact.bin"

S_EMNT          .ASCII_W "MOUNT FAILED "
S_EOPEN         .ASCII_W "OPEN FAILED "
S_OK            .ASCII_W "ok\n"
S_FAIL          .ASCII_W "FAIL "
S_NOMAP         .ASCII_W "FAIL(no map) "
S_MAPC          .ASCII_W "  SDB_MAP_BUILD instructions="
S_MAPE          .ASCII_W "  extents="
S_MAPT          .ASCII_W " blocks="
S_MAPL          .ASCII_W " lba0="
S_BLOCKS        .ASCII_W " blocks checked: "
S_PASS          .ASCII_W "ALL CHECKS PASSED\n"
S_FAILS         .ASCII_W " CHECK(S) FAILED\n"
S_SUM           .ASCII_W "summary: "

S_T1            .ASCII_W "T1 freedos.vhd (contiguous, 42 MB)\n"
S_T1B           .ASCII_W "T1b 16 pseudo random blocks: "
S_T2            .ASCII_W "T2 half block request must fall back: "
S_T2B           .ASCII_W "T2 unaligned request must fall back: "
S_T3            .ASCII_W "T3a fast write, library read: "
S_T3B           .ASCII_W "T3b fast write, fast read:    "
S_T3C           .ASCII_W "T3c library write, fast read: "
S_T4            .ASCII_W "T4 frag3.vhd (three extents)\n"
S_T5            .ASCII_W "T5 frag16.vhd must fall back: "
S_T6A           .ASCII_W "T6a small.bin via SDB_FREAD_FAST: "
S_T6B           .ASCII_W "T6b testrom.bin, 4k window wrap: "
S_T6C           .ASCII_W "T6c exact.bin, ends on a cluster boundary: "
S_T7            .ASCII_W "T7a library untouched after a failed map: "
S_T7B           .ASCII_W "T7b other file handle after a fast read: "
S_NUL           .ASCII_W ""

; block index lo, hi, expectation (0 = mapped, 1 = must fall back)
; 0xFFFF in the third slot terminates the list
T1_BLKS         .DW 0x0000, 0x0000, 0
                .DW 0x0001, 0x0000, 0
                .DW 0x003F, 0x0000, 0           ; last sector of cluster 0
                .DW 0x0040, 0x0000, 0           ; first sector of cluster 1
                .DW 0x0041, 0x0000, 0
                .DW 0x4E20, 0x0000, 0           ; the MARK20000 sector
                .DW 0x0001, 0x0001, 0           ; 65537
                .DW 0x4FFE, 0x0001, 0           ; 86014
                .DW 0x4FFF, 0x0001, 0           ; 86015, the last one
                .DW 0x5000, 0x0001, 1           ; 86016, one past the end
                .DW 0x0000, 0x0002, 1           ; far past the end
                .DW 0x0000, 0x0000, 0xFFFF

T3_BLK          .DW 0x7530                      ; block 30000 of freedos.vhd
NFAIL           .DW 0

#include "bench_env.asm"

                .ORG 0xB000
BUF_A           .BLOCK 512
BUF_B           .BLOCK 512
