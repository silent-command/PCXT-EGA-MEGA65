; hdmount_bench.asm: runs the REAL CORE/m2m-rom/hdmount.asm (remember the hard
; disk image, /m2m/hdmount) in the QNICE emulator. The FAT32 library is the
; real one of the monitor and the SD card is the bench image (mk_sd_image.py:
; /M2M/HDMOUNT, 128 zero bytes, and /PCXT/FREEDOS.VHD), so opening, reading,
; rewriting and re-reading the file are the real thing. The framework calls
; around it (LOAD_IMAGE, VD_STROBE_IM, the dirty flags, SDB_ORPHAN, the CSR)
; are stubs that record what they were asked to do.
;
; What it does NOT cover: the hooks in shell.asm / selectfile.asm / options.asm
; themselves, LOAD_IMAGE and the block map, and the reset of the PC. Those
; need the board.
;
; Prints one "ok: ..." or "FAIL: ..." line per check and a summary line;
; run_hdmount.sh counts them and then inspects the card image itself.

#define HDM_BENCH
#include "../../M2M/QNICE/dist_kit/sysdef.asm"
#include "../../M2M/QNICE/dist_kit/monitor.def"
#include "../../M2M/rom/sysdef.asm"

                .ORG    0x8000
                MOVE    0xFEE0, SP

; ----------------------------------------------------------------------------
; T1: no SD card at start-up (CONFIG_DEVH not mounted): everything is inert
; ----------------------------------------------------------------------------
START           RSUB    B_FRESH, 1
                RSUB    HDM_INIT, 1
                MOVE    HDM_ON, R8
                XOR     R9, R9
                MOVE    S_T1A, R10
                RSUB    CHKV, 1
                MOVE    M_LI_N, R8
                XOR     R9, R9
                MOVE    S_T1B, R10
                RSUB    CHKV, 1
                MOVE    S_PCXT, R9
                RSUB    HDM_CD, 1
                MOVE    2, R8
                MOVE    S_FDOS, R9
                RSUB    HDM_MOUNTED, 1
                RSUB    HDM_POLL, 1
                MOVE    HDM_PENDING, R8
                XOR     R9, R9
                MOVE    S_T1C, R10
                RSUB    CHKV, 1
                MOVE    M_ORPH, R8
                XOR     R9, R9
                MOVE    S_T1D, R10
                RSUB    CHKV, 1

; ----------------------------------------------------------------------------
; T2: card there, file empty: remembering is on, nothing is mounted
; ----------------------------------------------------------------------------
                RSUB    B_RESTART, 1
                MOVE    HDM_ON, R8
                MOVE    1, R9
                MOVE    S_T2A, R10
                RSUB    CHKV, 1
                MOVE    HDM_PATH, R8
                XOR     R9, R9
                MOVE    S_T2B, R10
                RSUB    CHKV, 1
                MOVE    M_LI_N, R8
                XOR     R9, R9
                MOVE    S_T2C, R10
                RSUB    CHKV, 1
                MOVE    HDM_CSR, R8
                XOR     R9, R9
                MOVE    S_T2D, R10
                RSUB    CHKV, 1

; ----------------------------------------------------------------------------
; T3: browse to /pcxt, mount freedos.vhd as the hard disk: path joined, saved
; only once no write cache is dirty
; ----------------------------------------------------------------------------
                MOVE    S_PCXT, R9
                RSUB    HDM_CD, 1
                MOVE    HDM_CWD, R8
                MOVE    S_PCXT, R9
                MOVE    S_T3A, R10
                RSUB    CHKS, 1
                MOVE    2, R8
                MOVE    S_FDOS, R9
                RSUB    HDM_MOUNTED, 1
                MOVE    HDM_PATH, R8
                MOVE    S_P_FDOS, R9
                MOVE    S_T3B, R10
                RSUB    CHKS, 1
                MOVE    HDM_PENDING, R8
                MOVE    1, R9
                MOVE    S_T3C, R10
                RSUB    CHKV, 1
                MOVE    M_DIRTY, R0
                MOVE    1, @R0
                RSUB    HDM_POLL, 1
                MOVE    HDM_PENDING, R8
                MOVE    1, R9
                MOVE    S_T3D, R10
                RSUB    CHKV, 1
                MOVE    M_ORPH, R8
                XOR     R9, R9
                MOVE    S_T3E, R10
                RSUB    CHKV, 1
                MOVE    M_DIRTY, R0
                MOVE    0, @R0
                RSUB    HDM_POLL, 1
                MOVE    HDM_PENDING, R8
                XOR     R9, R9
                MOVE    S_T3F, R10
                RSUB    CHKV, 1
                MOVE    M_ORPH, R8
                MOVE    1, R9
                MOVE    S_T3G, R10
                RSUB    CHKV, 1
                MOVE    HDM_ON, R8
                MOVE    1, R9
                MOVE    S_T3H, R10
                RSUB    CHKV, 1
                RSUB    HDM_POLL, 1             ; nothing pending: no second write
                MOVE    M_ORPH, R8
                MOVE    1, R9
                MOVE    S_T3I, R10
                RSUB    CHKV, 1

; ----------------------------------------------------------------------------
; T4: restart: the path comes back from the card and the image is mounted
; ----------------------------------------------------------------------------
                RSUB    B_RESTART, 1
                MOVE    HDM_PATH, R8
                MOVE    S_P_FDOS, R9
                MOVE    S_T4A, R10
                RSUB    CHKS, 1
                MOVE    M_LI_N, R8
                MOVE    1, R9
                MOVE    S_T4B, R10
                RSUB    CHKV, 1
                MOVE    M_LI_DRV, R8
                MOVE    2, R9
                MOVE    S_T4C, R10
                RSUB    CHKV, 1
                MOVE    M_LI_PATH, R8
                MOVE    HDM_PATH, R9
                MOVE    S_T4D, R10
                RSUB    CHKV, 1
                MOVE    M_STR_N, R8
                MOVE    1, R9
                MOVE    S_T4E, R10
                RSUB    CHKV, 1
                MOVE    M_STR_DRV, R8
                MOVE    2, R9
                MOVE    S_T4F, R10
                RSUB    CHKV, 1
                MOVE    M_STR_L, R8             ; 44040192 = 0x02A00000
                XOR     R9, R9
                MOVE    S_T4G, R10
                RSUB    CHKV, 1
                MOVE    M_STR_H, R8
                MOVE    0x02A0, R9
                MOVE    S_T4H, R10
                RSUB    CHKV, 1
                MOVE    HDM_CSR, R8
                MOVE    M2M$CSR_RESET, R9
                MOVE    S_T4I, R10
                RSUB    CHKV, 1
                MOVE    HDM_NAMED, R8
                XOR     R9, R9
                MOVE    S_T4J, R10
                RSUB    CHKV, 1
                MOVE    HDM_PENDING, R8
                XOR     R9, R9
                MOVE    S_T4K, R10
                RSUB    CHKV, 1
                MOVE    HANDLE_DEV, R8          ; the browser device got mounted
                MOVE    @R8, R8
                RBRA    _T4L_1, Z
                MOVE    1, R8
_T4L_1          MOVE    1, R9
                MOVE    S_T4L, R10
                RSUB    CHK, 1

; ----------------------------------------------------------------------------
; T5: the name for the menu line: plain, and cut for a narrow menu
; ----------------------------------------------------------------------------
                MOVE    M_HEAPBUF, R8
                MOVE    80, R9
                MOVE    0x0055, R10
                SYSCALL(memset, 1)
                MOVE    OPTM_HEAP, R0
                MOVE    M_HEAPBUF, @R0
                MOVE    SCR$OSM_O_DX, R0
                MOVE    20, @R0
                RSUB    HDM_MENU_OPEN, 1
                MOVE    M_HEAPBUF, R8
                ADD     40, R8                  ; slot of drive 2
                MOVE    S_FDOS, R9
                MOVE    S_T5A, R10
                RSUB    CHKS, 1
                MOVE    M_HEAPBUF, R8
                ADD     59, R8                  ; its "%s is replaced" flag
                XOR     R9, R9
                MOVE    S_T5B, R10
                RSUB    CHKV, 1
                MOVE    M_HEAPBUF, R8
                ADD     39, R8                  ; the slot of drive 1 is not touched
                MOVE    0x0055, R9
                MOVE    S_T5C, R10
                RSUB    CHKV, 1
                MOVE    HDM_NAMED, R8
                MOVE    1, R9
                MOVE    S_T5D, R10
                RSUB    CHKV, 1
                MOVE    M_HEAPBUF, R8           ; named: a second call writes nothing
                ADD     40, R8
                MOVE    0x0055, @R8
                RSUB    HDM_MENU_OPEN, 1
                MOVE    M_HEAPBUF, R8
                ADD     40, R8
                MOVE    0x0055, R9
                MOVE    S_T5E, R10
                RSUB    CHKV, 1
                MOVE    HDM_NAMED, R0           ; menu 8 wide: 6 fit, 7 are copied
                MOVE    0, @R0
                MOVE    SCR$OSM_O_DX, R0
                MOVE    8, @R0
                RSUB    HDM_MENU_OPEN, 1
                MOVE    M_HEAPBUF, R8
                ADD     16, R8
                MOVE    S_FREEDOS7, R9
                MOVE    S_T5F, R10
                RSUB    CHKS, 1

; ----------------------------------------------------------------------------
; T6: the directory tracking
; ----------------------------------------------------------------------------
                MOVE    FN_ROOT, R9
                RSUB    HDM_CD, 1
                MOVE    HDM_CWD, R8
                MOVE    S_EMPTY, R9
                MOVE    S_T6A, R10
                RSUB    CHKS, 1
                MOVE    S_GAMES, R9
                RSUB    HDM_CD, 1
                MOVE    HDM_CWD, R8
                MOVE    S_P_GAMES, R9
                MOVE    S_T6B, R10
                RSUB    CHKS, 1
                MOVE    S_SUBDIR, R9
                RSUB    HDM_CD, 1
                MOVE    HDM_CWD, R8
                MOVE    S_P_SUB, R9
                MOVE    S_T6C, R10
                RSUB    CHKS, 1
                MOVE    S_DOT, R9
                RSUB    HDM_CD, 1
                MOVE    HDM_CWD, R8
                MOVE    S_P_SUB, R9
                MOVE    S_T6D, R10
                RSUB    CHKS, 1
                MOVE    S_DOTDOT, R9
                RSUB    HDM_CD, 1
                MOVE    HDM_CWD, R8
                MOVE    S_P_GAMES, R9
                MOVE    S_T6E, R10
                RSUB    CHKS, 1
                MOVE    S_DOTDOT, R9
                RSUB    HDM_CD, 1
                MOVE    HDM_CWD, R8
                MOVE    S_EMPTY, R9
                MOVE    S_T6F, R10
                RSUB    CHKS, 1
                MOVE    S_DOTDOT, R9            ; ".." in the root stays there
                RSUB    HDM_CD, 1
                MOVE    HDM_CWD, R8
                MOVE    S_EMPTY, R9
                MOVE    S_T6G, R10
                RSUB    CHKS, 1
                MOVE    2, R8                   ; a file in the root
                MOVE    S_XVHD, R9
                RSUB    HDM_MOUNTED, 1
                MOVE    HDM_PATH, R8
                MOVE    S_P_XVHD, R9
                MOVE    S_T6H, R10
                RSUB    CHKS, 1
                MOVE    S_DOTNAME, R9           ; a name that merely starts with dots
                RSUB    HDM_CD, 1
                MOVE    HDM_CWD, R8
                MOVE    S_P_DOTNAME, R9
                MOVE    S_T6I, R10
                RSUB    CHKS, 1
                MOVE    S_PCXT_SL, R9           ; "/pcxt/" loses its slash
                RSUB    HDM_CD, 1
                MOVE    HDM_CWD, R8
                MOVE    S_PCXT, R9
                MOVE    S_T6J, R10
                RSUB    CHKS, 1

                ; the limits: /pcxt (5) + "/" + name + terminator <= 80
                MOVE    2, R8
                MOVE    S_N73, R9               ; 5+1+73+1 = 80: fits exactly
                RSUB    HDM_MOUNTED, 1
                MOVE    HDM_PATH, R8
                SYSCALL(strlen, 1)
                MOVE    R9, R8
                MOVE    79, R9
                MOVE    S_T6K, R10
                RSUB    CHK, 1
                MOVE    2, R8
                MOVE    S_N74, R9               ; one more: not remembered
                RSUB    HDM_MOUNTED, 1
                MOVE    HDM_PATH, R8
                XOR     R9, R9
                MOVE    S_T6L, R10
                RSUB    CHKV, 1
                MOVE    HDM_PENDING, R8         ; ... but the old entry is cleared
                MOVE    1, R9
                MOVE    S_T6M, R10
                RSUB    CHKV, 1
                MOVE    S_N73, R9               ; a directory that fits exactly
                RSUB    HDM_CD, 1
                MOVE    HDM_CWD_OK, R8
                MOVE    1, R9
                MOVE    S_T6N, R10
                RSUB    CHKV, 1
                MOVE    S_GAMES, R9             ; and one below it that does not
                RSUB    HDM_CD, 1
                MOVE    HDM_CWD_OK, R8
                XOR     R9, R9
                MOVE    S_T6O, R10
                RSUB    CHKV, 1
                MOVE    S_DOTDOT, R9            ; unknown stays unknown
                RSUB    HDM_CD, 1
                MOVE    HDM_CWD_OK, R8
                XOR     R9, R9
                MOVE    S_T6P, R10
                RSUB    CHKV, 1
                MOVE    2, R8
                MOVE    S_XVHD, R9
                RSUB    HDM_MOUNTED, 1
                MOVE    HDM_PATH, R8
                XOR     R9, R9
                MOVE    S_T6Q, R10
                RSUB    CHKV, 1
                MOVE    FN_ROOT, R9             ; an absolute path makes it known again
                RSUB    HDM_CD, 1
                MOVE    HDM_CWD_OK, R8
                MOVE    1, R9
                MOVE    S_T6R, R10
                RSUB    CHKV, 1

; ----------------------------------------------------------------------------
; T7: the floppy drives are none of our business
; ----------------------------------------------------------------------------
                MOVE    2, R8
                MOVE    S_XVHD, R9
                RSUB    HDM_MOUNTED, 1
                MOVE    HDM_PENDING, R0
                MOVE    0, @R0
                XOR     R8, R8
                MOVE    S_FDOS, R9
                RSUB    HDM_MOUNTED, 1
                MOVE    1, R8
                RSUB    HDM_UNMOUNTED, 1
                MOVE    HDM_PATH, R8
                MOVE    S_P_XVHD, R9
                MOVE    S_T7A, R10
                RSUB    CHKS, 1
                MOVE    HDM_PENDING, R8
                XOR     R9, R9
                MOVE    S_T7B, R10
                RSUB    CHKV, 1

; ----------------------------------------------------------------------------
; T8: switching the hard disk off forgets it, also on the card
; ----------------------------------------------------------------------------
                MOVE    2, R8
                RSUB    HDM_UNMOUNTED, 1
                MOVE    HDM_PATH, R8
                XOR     R9, R9
                MOVE    S_T8A, R10
                RSUB    CHKV, 1
                RSUB    HDM_POLL, 1
                MOVE    HDM_PENDING, R8
                XOR     R9, R9
                MOVE    S_T8B, R10
                RSUB    CHKV, 1
                RSUB    B_RESTART, 1
                MOVE    HDM_ON, R8
                MOVE    1, R9
                MOVE    S_T8C, R10
                RSUB    CHKV, 1
                MOVE    HDM_PATH, R8
                XOR     R9, R9
                MOVE    S_T8D, R10
                RSUB    CHKV, 1
                MOVE    M_LI_N, R8
                XOR     R9, R9
                MOVE    S_T8E, R10
                RSUB    CHKV, 1
                MOVE    HDM_CSR, R8
                XOR     R9, R9
                MOVE    S_T8F, R10
                RSUB    CHKV, 1

; ----------------------------------------------------------------------------
; T9: the remembered image is gone: nothing is mounted, the PC is not reset,
; the entry is kept
; ----------------------------------------------------------------------------
                MOVE    S_PCXT, R9
                RSUB    HDM_CD, 1
                MOVE    2, R8
                MOVE    S_NOTHERE, R9
                RSUB    HDM_MOUNTED, 1
                RSUB    HDM_POLL, 1
                RSUB    B_RESTART, 1
                MOVE    HDM_PATH, R8
                MOVE    S_P_NOTHERE, R9
                MOVE    S_T9A, R10
                RSUB    CHKS, 1
                MOVE    M_LI_N, R8
                XOR     R9, R9
                MOVE    S_T9B, R10
                RSUB    CHKV, 1
                MOVE    M_STR_N, R8
                XOR     R9, R9
                MOVE    S_T9C, R10
                RSUB    CHKV, 1
                MOVE    HDM_CSR, R8
                XOR     R9, R9
                MOVE    S_T9D, R10
                RSUB    CHKV, 1
                MOVE    HDM_ON, R8
                MOVE    1, R9
                MOVE    S_T9E, R10
                RSUB    CHKV, 1

; ----------------------------------------------------------------------------
; T10: the active SD card is not the one of start-up any more: nothing is
; written, remembering goes off
; ----------------------------------------------------------------------------
                MOVE    INITIAL_SD, R0
                MOVE    M2M$CSR_SD_ACTIVE, @R0
                MOVE    S_PCXT, R9
                RSUB    HDM_CD, 1
                MOVE    2, R8
                MOVE    S_FDOS, R9
                RSUB    HDM_MOUNTED, 1
                RSUB    HDM_POLL, 1
                MOVE    HDM_ON, R8
                XOR     R9, R9
                MOVE    S_T10A, R10
                RSUB    CHKV, 1
                MOVE    HDM_PENDING, R8
                XOR     R9, R9
                MOVE    S_T10B, R10
                RSUB    CHKV, 1
                MOVE    M_ORPH, R8
                XOR     R9, R9
                MOVE    S_T10C, R10
                RSUB    CHKV, 1
                RSUB    B_RESTART, 1            ; the card still has the old entry
                MOVE    HDM_PATH, R8
                MOVE    S_P_NOTHERE, R9
                MOVE    S_T10D, R10
                RSUB    CHKS, 1

; ----------------------------------------------------------------------------
; T11: a shorter path over a longer one: the terminator cuts it. Leaves
; "/pcxt/freedos.vhd" on the card for run_hdmount.sh to look at.
; ----------------------------------------------------------------------------
                MOVE    S_PCXT, R9
                RSUB    HDM_CD, 1
                MOVE    2, R8
                MOVE    S_FDOS, R9
                RSUB    HDM_MOUNTED, 1
                RSUB    HDM_POLL, 1
                RSUB    B_RESTART, 1
                MOVE    HDM_PATH, R8
                MOVE    S_P_FDOS, R9
                MOVE    S_T11A, R10
                RSUB    CHKS, 1
                MOVE    M_LI_N, R8
                MOVE    1, R9
                MOVE    S_T11B, R10
                RSUB    CHKV, 1

                ; summary
                MOVE    S_SUM, R8
                SYSCALL(puts, 1)
                MOVE    N_PASS, R8
                MOVE    @R8, R8
                SYSCALL(puthex, 1)
                MOVE    S_SUM2, R8
                SYSCALL(puts, 1)
                MOVE    N_FAIL, R8
                MOVE    @R8, R8
                SYSCALL(puthex, 1)
                SYSCALL(crlf, 1)
                HALT

; ----------------------------------------------------------------------------
; test helpers
; ----------------------------------------------------------------------------

; B_FRESH: what START_SHELL leaves behind: no device mounted, counters zero
B_FRESH         INCRB
                MOVE    HANDLE_DEV, R0
                MOVE    0, @R0
                MOVE    CONFIG_DEVH, R0
                MOVE    0, @R0
                MOVE    INITIAL_SD, R0
                MOVE    0, @R0
                MOVE    HDM_CSR, R0
                MOVE    0, @R0
                MOVE    M_DIRTY, R0
                MOVE    0, @R0
                MOVE    M_LI_N, R0
                MOVE    0, @R0
                MOVE    M_LI_DRV, R0
                MOVE    0xFFFF, @R0
                MOVE    M_LI_PATH, R0
                MOVE    0, @R0
                MOVE    M_STR_N, R0
                MOVE    0, @R0
                MOVE    M_STR_DRV, R0
                MOVE    0xFFFF, @R0
                MOVE    M_STR_L, R0
                MOVE    0xFFFF, @R0
                MOVE    M_STR_H, R0
                MOVE    0xFFFF, @R0
                MOVE    M_ORPH, R0
                MOVE    0, @R0
                DECRB
                RET

; B_RESTART: a restart of the firmware with the SD card in: B_FRESH, the
; settings device mounted as HELP_MENU_INIT does, then HDM_INIT
B_RESTART       INCRB
                RSUB    B_FRESH, 1
                MOVE    CONFIG_DEVH, R8
                MOVE    1, R9
                SYSCALL(f32_mnt_sd, 1)
                MOVE    R9, R8
                XOR     R9, R9
                MOVE    S_MNT, R10
                RSUB    CHK, 1
                RSUB    HDM_INIT, 1
                DECRB
                RET

; CHKV: R8 = address of a variable, R9 = expected value, R10 = description
CHKV            INCRB
                MOVE    R8, R0
                MOVE    @R8, R8
                RSUB    CHK, 1
                MOVE    R0, R8
                DECRB
                RET

; CHK: R8 = actual, R9 = expected, R10 = description
CHK             INCRB
                MOVE    R8, R0
                MOVE    R9, R1
                MOVE    R10, R2
                CMP     R0, R1
                RBRA    _CHK_OK, Z
                MOVE    N_FAIL, R3
                ADD     1, @R3
                MOVE    S_FAIL, R8
                SYSCALL(puts, 1)
                MOVE    R2, R8
                SYSCALL(puts, 1)
                MOVE    S_GOT, R8
                SYSCALL(puts, 1)
                MOVE    R0, R8
                SYSCALL(puthex, 1)
                MOVE    S_EXP, R8
                SYSCALL(puts, 1)
                MOVE    R1, R8
                SYSCALL(puthex, 1)
                SYSCALL(crlf, 1)
                RBRA    _CHK_RET, 1
_CHK_OK         MOVE    N_PASS, R3
                ADD     1, @R3
                MOVE    S_OK, R8
                SYSCALL(puts, 1)
                MOVE    R2, R8
                SYSCALL(puts, 1)
                SYSCALL(crlf, 1)
_CHK_RET        MOVE    R0, R8
                MOVE    R1, R9
                MOVE    R2, R10
                DECRB
                RET

; CHKS: R8 = actual string, R9 = expected string, R10 = description
CHKS            INCRB
                MOVE    R8, R0
                MOVE    R9, R1
                MOVE    R10, R2
                SYSCALL(strcmp, 1)
                CMP     0, R10
                RBRA    _CHKS_OK, Z
                MOVE    N_FAIL, R3
                ADD     1, @R3
                MOVE    S_FAIL, R8
                SYSCALL(puts, 1)
                MOVE    R2, R8
                SYSCALL(puts, 1)
                MOVE    S_GOT, R8
                SYSCALL(puts, 1)
                MOVE    R0, R8
                SYSCALL(puts, 1)
                MOVE    S_EXP, R8
                SYSCALL(puts, 1)
                MOVE    R1, R8
                SYSCALL(puts, 1)
                SYSCALL(crlf, 1)
                RBRA    _CHKS_RET, 1
_CHKS_OK        MOVE    N_PASS, R3
                ADD     1, @R3
                MOVE    S_OK, R8
                SYSCALL(puts, 1)
                MOVE    R2, R8
                SYSCALL(puts, 1)
                SYSCALL(crlf, 1)
_CHKS_RET       MOVE    R0, R8
                MOVE    R1, R9
                MOVE    R2, R10
                DECRB
                RET

; ----------------------------------------------------------------------------
; stubs of the framework
; ----------------------------------------------------------------------------

; LOAD_IMAGE: R8 drive, R9 path, R10 mode -> R8 = 0 (OK), R9 = image type 0
LOAD_IMAGE      INCRB
                MOVE    M_LI_N, R0
                ADD     1, @R0
                MOVE    M_LI_DRV, R0
                MOVE    R8, @R0
                MOVE    M_LI_PATH, R0
                MOVE    R9, @R0
                XOR     R8, R8
                XOR     R9, R9
                DECRB
                RET

; VD_STROBE_IM: R8 drive, R9/R10 size
VD_STROBE_IM    INCRB
                MOVE    M_STR_N, R0
                ADD     1, @R0
                MOVE    M_STR_DRV, R0
                MOVE    R8, @R0
                MOVE    M_STR_L, R0
                MOVE    R9, @R0
                MOVE    M_STR_H, R0
                MOVE    R10, @R0
                DECRB
                RET

; VD_IS_SDDIRECT: the hard disk is
VD_IS_SDDIRECT  OR      0x0004, SR
                RET

; VD_ACTIVE: three drives
VD_ACTIVE       MOVE    3, R8
                OR      0x0004, SR
                RET

; VD_DRV_READ: R8 drive, R9 register -> R8: M_DIRTY for drive 1, else 0
; (drive 1 so that a loop that only looks at drive 0 is caught)
VD_DRV_READ     INCRB
                MOVE    R8, R0
                XOR     R8, R8
                CMP     1, R0
                RBRA    _VDR_RET, !Z
                MOVE    M_DIRTY, R1
                MOVE    @R1, R8
_VDR_RET        DECRB
                RET

SDB_ORPHAN      INCRB
                MOVE    M_ORPH, R0
                ADD     1, @R0
                DECRB
                RET

#include "../../CORE/m2m-rom/hdmount.asm"

; ----------------------------------------------------------------------------
; strings
; ----------------------------------------------------------------------------
S_OK            .ASCII_W "ok: "
S_FAIL          .ASCII_W "FAIL: "
S_GOT           .ASCII_W " - got "
S_EXP           .ASCII_W " expected "
S_SUM           .ASCII_W "hdmount: passed "
S_SUM2          .ASCII_W " failed "
S_MNT           .ASCII_W "restart: the settings device mounts"

FN_ROOT         .ASCII_W "/"
S_EMPTY         .ASCII_W ""
S_PCXT          .ASCII_W "/pcxt"
S_PCXT_SL       .ASCII_W "/pcxt/"
S_FDOS          .ASCII_W "freedos.vhd"
S_FREEDOS7      .ASCII_W "freedos"
S_P_FDOS        .ASCII_W "/pcxt/freedos.vhd"
S_GAMES         .ASCII_W "games"
S_P_GAMES       .ASCII_W "/games"
S_SUBDIR        .ASCII_W "sub dir"
S_P_SUB         .ASCII_W "/games/sub dir"
S_DOT           .ASCII_W "."
S_DOTDOT        .ASCII_W ".."
S_DOTNAME       .ASCII_W "..x"
S_P_DOTNAME     .ASCII_W "/..x"
S_XVHD          .ASCII_W "x.vhd"
S_P_XVHD        .ASCII_W "/x.vhd"
S_NOTHERE       .ASCII_W "nothere-at-all.vhd"
S_P_NOTHERE     .ASCII_W "/pcxt/nothere-at-all.vhd"
S_N73           .ASCII_W "n123456789012345678901234567890123456789012345678901234567890123456789012"
S_N74           .ASCII_W "n1234567890123456789012345678901234567890123456789012345678901234567890123"

S_T1A           .ASCII_W "T1a no card: remembering is off"
S_T1B           .ASCII_W "T1b no card: nothing is mounted"
S_T1C           .ASCII_W "T1c no card: a mount leaves nothing pending"
S_T1D           .ASCII_W "T1d no card: nothing was written"
S_T2A           .ASCII_W "T2a empty file: remembering is on"
S_T2B           .ASCII_W "T2b empty file: no path"
S_T2C           .ASCII_W "T2c empty file: nothing is mounted"
S_T2D           .ASCII_W "T2d empty file: the PC is not reset"
S_T3A           .ASCII_W "T3a cd /pcxt"
S_T3B           .ASCII_W "T3b mount: directory and name are joined"
S_T3C           .ASCII_W "T3c mount: a write is pending"
S_T3D           .ASCII_W "T3d dirty write cache: still pending"
S_T3E           .ASCII_W "T3e dirty write cache: nothing written"
S_T3F           .ASCII_W "T3f clean: written, nothing pending"
S_T3G           .ASCII_W "T3g clean: hardware buffer handed back once"
S_T3H           .ASCII_W "T3h clean: remembering still on"
S_T3I           .ASCII_W "T3i idle poll: no second write"
S_T4A           .ASCII_W "T4a restart: the path is read back from the card"
S_T4B           .ASCII_W "T4b restart: LOAD_IMAGE called once"
S_T4C           .ASCII_W "T4c restart: for drive 2"
S_T4D           .ASCII_W "T4d restart: with the remembered path"
S_T4E           .ASCII_W "T4e restart: one mount strobe"
S_T4F           .ASCII_W "T4f restart: strobe for drive 2"
S_T4G           .ASCII_W "T4g restart: image size, low word"
S_T4H           .ASCII_W "T4h restart: image size, high word"
S_T4I           .ASCII_W "T4i restart: the PC is put into reset"
S_T4J           .ASCII_W "T4j restart: the menu still needs the name"
S_T4K           .ASCII_W "T4k restart: nothing to write"
S_T4L           .ASCII_W "T4l restart: the browser device is mounted"
S_T5A           .ASCII_W "T5a menu: file name in the slot of drive 2"
S_T5B           .ASCII_W "T5b menu: replaced-flag cleared"
S_T5C           .ASCII_W "T5c menu: the neighbouring slot is untouched"
S_T5D           .ASCII_W "T5d menu: named"
S_T5E           .ASCII_W "T5e menu: not written a second time"
S_T5F           .ASCII_W "T5f menu: long name cut to width plus one"
S_T6A           .ASCII_W "T6a cd / is the empty string"
S_T6B           .ASCII_W "T6b cd games"
S_T6C           .ASCII_W "T6c cd sub dir (a space in the name)"
S_T6D           .ASCII_W "T6d cd . changes nothing"
S_T6E           .ASCII_W "T6e cd .. one level up"
S_T6F           .ASCII_W "T6f cd .. to the root"
S_T6G           .ASCII_W "T6g cd .. in the root"
S_T6H           .ASCII_W "T6h a file in the root"
S_T6I           .ASCII_W "T6i a directory called ..x is a name"
S_T6J           .ASCII_W "T6j trailing slash removed"
S_T6K           .ASCII_W "T6k longest path that fits (79 characters)"
S_T6L           .ASCII_W "T6l one character more: not remembered"
S_T6M           .ASCII_W "T6m one character more: the old entry gets cleared"
S_T6N           .ASCII_W "T6n longest directory that fits"
S_T6O           .ASCII_W "T6o directory too long: unknown"
S_T6P           .ASCII_W "T6p unknown stays unknown on cd .."
S_T6Q           .ASCII_W "T6q unknown directory: not remembered"
S_T6R           .ASCII_W "T6r absolute path: known again"
S_T7A           .ASCII_W "T7a floppy mounts leave the path alone"
S_T7B           .ASCII_W "T7b floppy mounts leave nothing pending"
S_T8A           .ASCII_W "T8a hard disk off: path cleared"
S_T8B           .ASCII_W "T8b hard disk off: written"
S_T8C           .ASCII_W "T8c restart after off: remembering on"
S_T8D           .ASCII_W "T8d restart after off: no path on the card"
S_T8E           .ASCII_W "T8e restart after off: nothing is mounted"
S_T8F           .ASCII_W "T8f restart after off: the PC is not reset"
S_T9A           .ASCII_W "T9a image gone: the entry is kept"
S_T9B           .ASCII_W "T9b image gone: LOAD_IMAGE is not called"
S_T9C           .ASCII_W "T9c image gone: no mount strobe"
S_T9D           .ASCII_W "T9d image gone: the PC is not reset"
S_T9E           .ASCII_W "T9e image gone: remembering stays on"
S_T10A          .ASCII_W "T10a other SD card: remembering goes off"
S_T10B          .ASCII_W "T10b other SD card: request dropped"
S_T10C          .ASCII_W "T10c other SD card: nothing written"
S_T10D          .ASCII_W "T10d other SD card: the old entry is still on the card"
S_T11A          .ASCII_W "T11a short path over a longer one reads back exactly"
S_T11B          .ASCII_W "T11b and is mounted"

; ----------------------------------------------------------------------------
; data
; ----------------------------------------------------------------------------
N_PASS          .DW     0
N_FAIL          .DW     0

; framework model
HDM_CSR         .DW     0                       ; stands in for M2M$CSR
INITIAL_SD      .DW     0
OPTM_HEAP       .DW     0
SCR$OSM_O_DX    .DW     0
M_DIRTY         .DW     0
M_LI_N          .DW     0
M_LI_DRV        .DW     0
M_LI_PATH       .DW     0
M_STR_N         .DW     0
M_STR_DRV       .DW     0
M_STR_L         .DW     0
M_STR_H         .DW     0
M_ORPH          .DW     0
M_HEAPBUF       .BLOCK  80

HANDLE_DEV      .BLOCK  FAT32$DEV_STRUCT_SIZE
CONFIG_DEVH     .BLOCK  FAT32$DEV_STRUCT_SIZE
HANDLE_VD_FILE1 .BLOCK  FAT32$FDH_STRUCT_SIZE
HANDLE_VD_FILE2 .BLOCK  FAT32$FDH_STRUCT_SIZE
HANDLE_VD_FILE3 .BLOCK  FAT32$FDH_STRUCT_SIZE
HNDL_VD_FILES   .DW     HANDLE_VD_FILE1, HANDLE_VD_FILE2, HANDLE_VD_FILE3

#include "../../CORE/m2m-rom/hdmount_vars.asm"
