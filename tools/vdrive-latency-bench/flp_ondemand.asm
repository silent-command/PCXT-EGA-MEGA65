; flp_ondemand.asm: runs the REAL CORE/m2m-rom/flpdrv.asm (the firmware of
; the internal floppy drive, docs/floppy.md "Disk detection on demand") in
; the QNICE emulator against a scripted model of the sector engine's
; registers and of the framework's vdrive calls, and checks the decisions
; the firmware takes: which engine commands it issues and when (never while
; idle), what it mounts (size, read-only), how it converts a request's LBA
; with the sectors-per-track of the mount, and which requests it refuses
; with the block-error flag.
;
; What the model does NOT cover: the engine's timing (every command completes
; before the next status read, busy is never seen), the block data itself,
; and floppy.v / the BIOS (those are in mgmt_bridge_tb and on the board).
;
; Prints one "ok: ..." or "FAIL: ..." line per check and a summary line;
; run_flp_ondemand.sh counts them.

#define FLP_BENCH
#include "../../M2M/QNICE/dist_kit/sysdef.asm"
#include "../../M2M/QNICE/dist_kit/monitor.def"
#include "../../M2M/rom/sysdef.asm"

                .ORG    0x8000
                MOVE    0xFEE0, SP

; ----------------------------------------------------------------------------
; the tests
; ----------------------------------------------------------------------------
START           RSUB    FW_INIT, 1              ; what FLP_INIT does before FLP_ON

                ; 1. toggle on with a 1.44 MB disk in: PROBE, DETECT, mount
                MOVE    1, R8
                MOVE    0x0112, R9              ; HD found, max R 18
                XOR     R10, R10                ; not write protected
                RSUB    M_INSERT, 1
                MOVE    M_STICKY, R0
                MOVE    1, @R0                  ; power-up latch
                MOVE    M_ACC, R0
                MOVE    1, @R0                  ; a stale access attempt
                RSUB    M_RESET, 1
                RSUB    FLP_ON, 1
                MOVE    FLP_STATE, R8
                MOVE    @R8, R8
                MOVE    FLP_S_READY, R9
                MOVE    S_T1A, R10
                RSUB    CHK, 1
                MOVE    M_NCMD, R8
                MOVE    @R8, R8
                MOVE    2, R9
                MOVE    S_T1B, R10
                RSUB    CHK, 1
                XOR     R8, R8
                MOVE    FLP_CMD_PROBE, R9
                MOVE    S_T1C, R10
                RSUB    CHKCMD, 1
                MOVE    1, R8
                MOVE    FLP_CMD_DETECT, R9
                MOVE    S_T1D, R10
                RSUB    CHKCMD, 1
                MOVE    0x0016, R8              ; 1474560 = 0x00168000
                MOVE    0x8000, R9
                XOR     R10, R10
                MOVE    S_T1E, R11
                RSUB    CHKMNT, 1
                MOVE    FLP_SPT, R8
                MOVE    @R8, R8
                MOVE    18, R9
                MOVE    S_T1F, R10
                RSUB    CHK, 1
                MOVE    FLP_RATE, R8
                MOVE    @R8, R8
                MOVE    FLP_ARG_RATEHD, R9
                MOVE    S_T1G, R10
                RSUB    CHK, 1
                MOVE    M_ACC, R8
                MOVE    @R8, R8
                XOR     R9, R9
                MOVE    S_T1H, R10
                RSUB    CHK, 1
                MOVE    M_STICKY, R8
                MOVE    @R8, R8
                XOR     R9, R9
                MOVE    S_T1I, R10
                RSUB    CHK, 1

                ; 2. idle while READY: nothing is issued
                RSUB    M_RESET, 1
                MOVE    M_ACC, R0
                MOVE    1, @R0                  ; even with DOS busy on A:
                MOVE    8, R8
                RSUB    POLLN, 1
                MOVE    M_NCMD, R8
                MOVE    @R8, R8
                XOR     R9, R9
                MOVE    S_T2A, R10
                RSUB    CHK, 1
                MOVE    M_STR_N, R8
                MOVE    @R8, R8
                XOR     R9, R9
                MOVE    S_T2B, R10
                RSUB    CHK, 1

                ; 3. a read of LBA 19 on the 18-sector mount: C0 H1 R2
                MOVE    M_VALID, R0
                MOVE    0xFFFF, @R0
                MOVE    19, R8
                RSUB    RDREQ, 1
                MOVE    M_NCMD, R8
                MOVE    @R8, R8
                MOVE    2, R9
                MOVE    S_T3A, R10
                RSUB    CHK, 1
                XOR     R8, R8
                MOVE    FLP_CMD_READ, R9
                MOVE    S_T3B, R10
                RSUB    CHKCMD, 1
                MOVE    1, R8
                MOVE    FLP_CMD_COPY, R9
                MOVE    S_T3C, R10
                RSUB    CHKCMD, 1
                MOVE    M_RD_A0, R8
                MOVE    @R8, R8
                MOVE    0x0300, R9              ; C0, head 1, 500 kbit/s
                MOVE    S_T3D, R10
                RSUB    CHK, 1
                MOVE    M_RD_A1, R8
                MOVE    @R8, R8
                MOVE    0x1202, R9              ; R2, SPT 18
                MOVE    S_T3E, R10
                RSUB    CHK, 1
                MOVE    M_CP_A1, R8
                MOVE    @R8, R8
                MOVE    0x1202, R9
                MOVE    S_T3F, R10
                RSUB    CHK, 1
                XOR     R8, R8
                MOVE    S_T3G, R9
                RSUB    CHKACK, 1
                MOVE    M_DIRTY, R8
                MOVE    @R8, R8
                XOR     R9, R9
                MOVE    S_T3H, R10
                RSUB    CHK, 1

                ; 4. sector 18 (LBA 17): valid bit in the cache word
                MOVE    M_VALID, R0
                MOVE    0, @R0
                MOVE    M_VALID17, R0
                MOVE    0x0002, @R0
                MOVE    17, R8
                RSUB    RDREQ, 1
                MOVE    M_RD_A1, R8
                MOVE    @R8, R8
                MOVE    0x1212, R9              ; R18, SPT 18
                MOVE    S_T4A, R10
                RSUB    CHK, 1
                MOVE    M_NCMD, R8
                MOVE    @R8, R8
                MOVE    2, R9
                MOVE    S_T4B, R10
                RSUB    CHK, 1
                XOR     R8, R8
                MOVE    S_T4C, R9
                RSUB    CHKACK, 1

                ; 5. a sector that never turns up: two attempts, the second
                ;    with a recalibrate, then the block error
                MOVE    M_VALID17, R0
                MOVE    0, @R0
                XOR     R8, R8
                RSUB    RDREQ, 1
                MOVE    M_NCMD, R8
                MOVE    @R8, R8
                MOVE    2, R9
                MOVE    S_T5A, R10
                RSUB    CHK, 1
                MOVE    1, R8
                MOVE    FLP_CMD_READ, R9
                MOVE    S_T5B, R10
                RSUB    CHKCMD, 1
                MOVE    M_RD_A0, R8
                MOVE    @R8, R8
                AND     FLP_ARG_FORCE, R8
                MOVE    FLP_ARG_FORCE, R9
                MOVE    S_T5C, R10
                RSUB    CHK, 1
                MOVE    1, R8
                MOVE    S_T5D, R9
                RSUB    CHKACK, 1

                ; 6. eject while idle: unmount at once, no probe, no detect
                RSUB    M_EJECT, 1
                RSUB    M_RESET, 1
                MOVE    1, R8
                RSUB    POLLN, 1
                MOVE    FLP_STATE, R8
                MOVE    @R8, R8
                MOVE    FLP_S_NODISK, R9
                MOVE    S_T6A, R10
                RSUB    CHK, 1
                XOR     R8, R8
                XOR     R9, R9
                XOR     R10, R10
                MOVE    S_T6B, R11
                RSUB    CHKMNT, 1
                MOVE    M_NCMD, R8
                MOVE    @R8, R8
                XOR     R9, R9
                MOVE    S_T6C, R10
                RSUB    CHK, 1
                MOVE    M_STICKY, R8
                MOVE    @R8, R8
                XOR     R9, R9
                MOVE    S_T6D, R10
                RSUB    CHK, 1

                ; 7. unmounted and nobody asks: silence
                RSUB    M_RESET, 1
                MOVE    8, R8
                RSUB    POLLN, 1
                MOVE    M_NCMD, R8
                MOVE    @R8, R8
                XOR     R9, R9
                MOVE    S_T7A, R10
                RSUB    CHK, 1

                ; 8. DOS tries A: with no disk in: one PROBE, no DETECT
                RSUB    EXPIRE, 1
                MOVE    M_ACC, R0
                MOVE    1, @R0
                MOVE    1, R8
                RSUB    POLLN, 1
                MOVE    M_NCMD, R8
                MOVE    @R8, R8
                MOVE    1, R9
                MOVE    S_T8A, R10
                RSUB    CHK, 1
                XOR     R8, R8
                MOVE    FLP_CMD_PROBE, R9
                MOVE    S_T8B, R10
                RSUB    CHKCMD, 1
                MOVE    M_ACC, R8
                MOVE    @R8, R8
                XOR     R9, R9
                MOVE    S_T8C, R10
                RSUB    CHK, 1
                MOVE    4, R8
                RSUB    POLLN, 1
                MOVE    FLP_STATE, R8
                MOVE    @R8, R8
                MOVE    FLP_S_NODISK, R9
                MOVE    S_T8D, R10
                RSUB    CHK, 1
                MOVE    M_NCMD, R8
                MOVE    @R8, R8
                MOVE    1, R9
                MOVE    S_T8E, R10
                RSUB    CHK, 1
                MOVE    M_STR_N, R8
                MOVE    @R8, R8
                XOR     R9, R9
                MOVE    S_T8F, R10
                RSUB    CHK, 1

                ; 9. the hold-off: a second attempt right away waits, the flag
                ;    is kept, and the probe follows once the hold-off is over
                MOVE    M_ACC, R0
                MOVE    1, @R0
                MOVE    4, R8
                RSUB    POLLN, 1
                MOVE    M_NCMD, R8
                MOVE    @R8, R8
                MOVE    1, R9
                MOVE    S_T9A, R10
                RSUB    CHK, 1
                MOVE    M_ACC, R8
                MOVE    @R8, R8
                MOVE    1, R9
                MOVE    S_T9B, R10
                RSUB    CHK, 1
                RSUB    EXPIRE, 1
                MOVE    4, R8
                RSUB    POLLN, 1
                MOVE    M_NCMD, R8
                MOVE    @R8, R8
                MOVE    2, R9
                MOVE    S_T9C, R10
                RSUB    CHK, 1
                MOVE    FLP_STATE, R8
                MOVE    @R8, R8
                MOVE    FLP_S_NODISK, R9
                MOVE    S_T9D, R10
                RSUB    CHK, 1

                ; 10. a write-protected 720 KB disk goes in, DOS retries:
                ;     PROBE, DETECT, mounted read-only with 9 sectors
                MOVE    1, R8
                MOVE    0x0209, R9              ; DD found, max R 9
                MOVE    1, R10                  ; write protected
                RSUB    M_INSERT, 1
                RSUB    M_RESET, 1
                RSUB    EXPIRE, 1
                MOVE    M_ACC, R0
                MOVE    1, @R0
                MOVE    1, R8
                RSUB    POLLN, 1
                MOVE    1, R8
                RSUB    POLLN, 1
                MOVE    FLP_STATE, R8
                MOVE    @R8, R8
                MOVE    FLP_S_DETECT, R9
                MOVE    S_T10A, R10
                RSUB    CHK, 1
                MOVE    1, R8
                MOVE    FLP_CMD_DETECT, R9
                MOVE    S_T10B, R10
                RSUB    CHKCMD, 1
                MOVE    1, R8
                RSUB    POLLN, 1
                MOVE    FLP_STATE, R8
                MOVE    @R8, R8
                MOVE    FLP_S_READY, R9
                MOVE    S_T10C, R10
                RSUB    CHK, 1
                MOVE    0x000B, R8              ; 737280 = 0x000B4000
                MOVE    0x4000, R9
                MOVE    1, R10
                MOVE    S_T10D, R11
                RSUB    CHKMNT, 1
                MOVE    FLP_SPT, R8
                MOVE    @R8, R8
                MOVE    9, R9
                MOVE    S_T10E, R10
                RSUB    CHK, 1
                MOVE    FLP_RATE, R8
                MOVE    @R8, R8
                XOR     R9, R9
                MOVE    S_T10F, R10
                RSUB    CHK, 1
                MOVE    M_NCMD, R8
                MOVE    @R8, R8
                MOVE    2, R9
                MOVE    S_T10G, R10
                RSUB    CHK, 1
                MOVE    M_ACC, R8
                MOVE    @R8, R8
                XOR     R9, R9
                MOVE    S_T10H, R10
                RSUB    CHK, 1

                ; 11. a read of LBA 10 on the 9-sector mount: C0 H1 R2 at 250 kbit/s
                MOVE    M_VALID, R0
                MOVE    0xFFFF, @R0
                MOVE    10, R8
                RSUB    RDREQ, 1
                MOVE    M_RD_A0, R8
                MOVE    @R8, R8
                MOVE    0x0100, R9
                MOVE    S_T11A, R10
                RSUB    CHK, 1
                MOVE    M_RD_A1, R8
                MOVE    @R8, R8
                MOVE    0x0902, R9
                MOVE    S_T11B, R10
                RSUB    CHK, 1
                XOR     R8, R8
                MOVE    S_T11C, R9
                RSUB    CHKACK, 1

                ; 12. a write on the read-only mount is refused without a command
                MOVE    5, R8
                RSUB    WRREQ, 1
                MOVE    M_NCMD, R8
                MOVE    @R8, R8
                XOR     R9, R9
                MOVE    S_T12A, R10
                RSUB    CHK, 1
                MOVE    1, R8
                MOVE    S_T12B, R9
                RSUB    CHKACK, 1

                ; 13. a swap under a pending request: the request is refused,
                ;     the next poll unmounts, the retry finds the new disk
                RSUB    M_EJECT, 1
                MOVE    1, R8
                MOVE    0x0112, R9
                XOR     R10, R10
                RSUB    M_INSERT, 1             ; the latch stays set: no step yet
                XOR     R8, R8
                RSUB    RDREQ, 1
                MOVE    M_NCMD, R8
                MOVE    @R8, R8
                XOR     R9, R9
                MOVE    S_T13A, R10
                RSUB    CHK, 1
                MOVE    1, R8
                MOVE    S_T13B, R9
                RSUB    CHKACK, 1
                RSUB    M_RESET, 1
                MOVE    1, R8
                RSUB    POLLN, 1
                MOVE    FLP_STATE, R8
                MOVE    @R8, R8
                MOVE    FLP_S_NODISK, R9
                MOVE    S_T13C, R10
                RSUB    CHK, 1
                XOR     R8, R8
                XOR     R9, R9
                XOR     R10, R10
                MOVE    S_T13D, R11
                RSUB    CHKMNT, 1
                MOVE    M_ACC, R0
                MOVE    1, @R0                  ; the retry (no hold-off after an eject)
                RSUB    M_RESET, 1
                MOVE    3, R8
                RSUB    POLLN, 1
                MOVE    FLP_STATE, R8
                MOVE    @R8, R8
                MOVE    FLP_S_READY, R9
                MOVE    S_T13E, R10
                RSUB    CHK, 1
                MOVE    0x0016, R8
                MOVE    0x8000, R9
                XOR     R10, R10
                MOVE    S_T13F, R11
                RSUB    CHKMNT, 1
                MOVE    M_NCMD, R8
                MOVE    @R8, R8
                MOVE    2, R9
                MOVE    S_T13G, R10
                RSUB    CHK, 1

                ; 14. a write of LBA 5 (C0 H0 R6)
                MOVE    5, R8
                RSUB    WRREQ, 1
                MOVE    M_NCMD, R8
                MOVE    @R8, R8
                MOVE    1, R9
                MOVE    S_T14A, R10
                RSUB    CHK, 1
                XOR     R8, R8
                MOVE    FLP_CMD_WRITE, R9
                MOVE    S_T14B, R10
                RSUB    CHKCMD, 1
                MOVE    M_WR_A0, R8
                MOVE    @R8, R8
                MOVE    0x0200, R9
                MOVE    S_T14C, R10
                RSUB    CHK, 1
                MOVE    M_WR_A1, R8
                MOVE    @R8, R8
                MOVE    0x1206, R9
                MOVE    S_T14D, R10
                RSUB    CHK, 1
                XOR     R8, R8
                MOVE    S_T14E, R9
                RSUB    CHKACK, 1
                MOVE    M_DIRTY, R8
                MOVE    @R8, R8
                XOR     R9, R9
                MOVE    S_T14F, R10
                RSUB    CHK, 1

                ; 15. a write that fails (no index): retried with a recalibrate, then the block error
                MOVE    M_WERR, R0
                MOVE    1, @R0
                MOVE    5, R8
                RSUB    WRREQ, 1
                MOVE    M_NCMD, R8
                MOVE    @R8, R8
                MOVE    2, R9
                MOVE    S_T15A, R10
                RSUB    CHK, 1
                MOVE    M_WR_A0, R8
                MOVE    @R8, R8
                AND     FLP_ARG_FORCE, R8
                MOVE    FLP_ARG_FORCE, R9
                MOVE    S_T15B, R10
                RSUB    CHK, 1
                MOVE    1, R8
                MOVE    S_T15C, R9
                RSUB    CHKACK, 1

                ; 16. the engine says write protected (tab moved): no retry
                MOVE    M_WERR, R0
                MOVE    7, @R0
                MOVE    5, R8
                RSUB    WRREQ, 1
                MOVE    M_NCMD, R8
                MOVE    @R8, R8
                MOVE    1, R9
                MOVE    S_T16A, R10
                RSUB    CHK, 1
                MOVE    1, R8
                MOVE    S_T16B, R9
                RSUB    CHKACK, 1
                MOVE    M_WERR, R0
                MOVE    0, @R0

                ; 17. a failed read-back verify: noticed by the poll, the
                ;     next read and write are parked without a command
                MOVE    M_VFY, R0
                MOVE    FLP_VFY_FAIL, @R0
                MOVE    1, R8
                RSUB    POLLN, 1
                MOVE    FLP_VFY_ERR, R8
                MOVE    @R8, R8
                MOVE    1, R9
                MOVE    S_T17A, R10
                RSUB    CHK, 1
                MOVE    M_VFY, R8
                MOVE    @R8, R8
                XOR     R9, R9
                MOVE    S_T17B, R10
                RSUB    CHK, 1
                XOR     R8, R8
                RSUB    RDREQ, 1
                MOVE    M_NCMD, R8
                MOVE    @R8, R8
                XOR     R9, R9
                MOVE    S_T17C, R10
                RSUB    CHK, 1
                MOVE    1, R8
                MOVE    S_T17D, R9
                RSUB    CHKACK, 1
                MOVE    5, R8
                RSUB    WRREQ, 1
                MOVE    M_NCMD, R8
                MOVE    @R8, R8
                XOR     R9, R9
                MOVE    S_T17E, R10
                RSUB    CHK, 1
                MOVE    1, R8
                MOVE    S_T17F, R9
                RSUB    CHKACK, 1

                ; 18. an unreadable disk: after the eject a disk with no
                ;     headers at either rate stays unmounted, the verify
                ;     failure is gone with the old disk
                RSUB    M_EJECT, 1
                MOVE    1, R8
                RSUB    POLLN, 1
                MOVE    1, R8
                XOR     R9, R9                  ; nothing readable
                XOR     R10, R10
                RSUB    M_INSERT, 1
                RSUB    M_RESET, 1
                RSUB    EXPIRE, 1
                MOVE    M_ACC, R0
                MOVE    1, @R0
                MOVE    4, R8
                RSUB    POLLN, 1
                MOVE    FLP_STATE, R8
                MOVE    @R8, R8
                MOVE    FLP_S_NODISK, R9
                MOVE    S_T18A, R10
                RSUB    CHK, 1
                MOVE    M_NCMD, R8
                MOVE    @R8, R8
                MOVE    2, R9
                MOVE    S_T18B, R10
                RSUB    CHK, 1
                MOVE    M_STR_N, R8
                MOVE    @R8, R8
                XOR     R9, R9
                MOVE    S_T18C, R10
                RSUB    CHK, 1
                MOVE    M_ACC, R8
                MOVE    @R8, R8
                XOR     R9, R9
                MOVE    S_T18D, R10
                RSUB    CHK, 1

                ; 19. the toggle off and on again
                RSUB    M_RESET, 1
                RSUB    FLP_OFF, 1
                MOVE    FLP_STATE, R8
                MOVE    @R8, R8
                MOVE    FLP_S_OFF, R9
                MOVE    S_T19A, R10
                RSUB    CHK, 1
                MOVE    M_STR_N, R8
                MOVE    @R8, R8
                XOR     R9, R9
                MOVE    S_T19B, R10
                RSUB    CHK, 1
                MOVE    M_CTRL, R8
                MOVE    @R8, R8
                XOR     R9, R9
                MOVE    S_T19C, R10
                RSUB    CHK, 1
                MOVE    1, R8
                MOVE    0x0112, R9
                XOR     R10, R10
                RSUB    M_INSERT, 1
                RSUB    M_RESET, 1
                RSUB    FLP_ON, 1
                MOVE    FLP_STATE, R8
                MOVE    @R8, R8
                MOVE    FLP_S_READY, R9
                MOVE    S_T19D, R10
                RSUB    CHK, 1
                MOVE    FLP_VFY_ERR, R8
                MOVE    @R8, R8
                XOR     R9, R9
                MOVE    S_T19E, R10
                RSUB    CHK, 1
                RSUB    M_RESET, 1
                RSUB    FLP_OFF, 1
                XOR     R8, R8
                XOR     R9, R9
                XOR     R10, R10                ; the unprotected disk: RO 0 as the live line says
                MOVE    S_T19F, R11
                RSUB    CHKMNT, 1

                ; 20. FORMAT (flpfmt.asm): fill blocks of a FORMAT TRACK. The
                ; toggle on with a 1.44 MB disk; the tap says "fill, SC 18,
                ; filler F6": the fill of C1 H0 R1 (LBA 36) formats the track
                MOVE    1, R8
                MOVE    0x0112, R9
                XOR     R10, R10
                RSUB    M_INSERT, 1
                RSUB    M_RESET, 1
                RSUB    FLP_ON, 1
                MOVE    M_FMT, R0
                MOVE    0x92F6, @R0
                MOVE    36, R8
                RSUB    WRREQ, 1
                MOVE    M_NCMD, R8
                MOVE    @R8, R8
                MOVE    1, R9
                MOVE    S_T20A, R10
                RSUB    CHK, 1
                XOR     R8, R8
                MOVE    FLP_CMD_FORMAT, R9
                MOVE    S_T20B, R10
                RSUB    CHKCMD, 1
                MOVE    M_FM_A0, R8
                MOVE    @R8, R8
                MOVE    0x0201, R9              ; C1 H0 HD
                MOVE    S_T20C, R10
                RSUB    CHK, 1
                MOVE    M_FM_A1, R8
                MOVE    @R8, R8
                MOVE    0x1200, R9              ; SC 18, sector field 0
                MOVE    S_T20D, R10
                RSUB    CHK, 1
                MOVE    M_FM_A2, R8
                MOVE    @R8, R8
                MOVE    0x00F6, R9              ; the filler, gap 3 default
                MOVE    S_T20E, R10
                RSUB    CHK, 1
                XOR     R8, R8
                MOVE    S_T20F, R9
                RSUB    CHKACK, 1
                MOVE    M_DIRTY, R8
                MOVE    @R8, R8
                XOR     R9, R9
                MOVE    S_T20G, R10
                RSUB    CHK, 1
                ; the fills of R2 and R18 of the same track: acknowledged, no command
                MOVE    37, R8
                RSUB    WRREQ, 1
                MOVE    M_NCMD, R8
                MOVE    @R8, R8
                XOR     R9, R9
                MOVE    S_T20H, R10
                RSUB    CHK, 1
                XOR     R8, R8
                MOVE    S_T20I, R9
                RSUB    CHKACK, 1
                MOVE    53, R8
                RSUB    WRREQ, 1
                MOVE    M_NCMD, R8
                MOVE    @R8, R8
                XOR     R9, R9
                MOVE    S_T20J, R10
                RSUB    CHK, 1
                ; the other side (C1 H1 R1, LBA 54): formatted
                MOVE    54, R8
                RSUB    WRREQ, 1
                MOVE    M_NCMD, R8
                MOVE    @R8, R8
                MOVE    1, R9
                MOVE    S_T20K, R10
                RSUB    CHK, 1
                MOVE    M_FM_A0, R8
                MOVE    @R8, R8
                MOVE    0x0301, R9              ; C1 H1 HD
                MOVE    S_T20L, R10
                RSUB    CHK, 1
                ; a fill of R5 of a track not formatted (C2 H0, LBA 76): formatted too
                MOVE    76, R8
                RSUB    WRREQ, 1
                MOVE    M_NCMD, R8
                MOVE    @R8, R8
                MOVE    1, R9
                MOVE    S_T20M, R10
                RSUB    CHK, 1
                MOVE    M_FM_A0, R8
                MOVE    @R8, R8
                MOVE    0x0202, R9              ; C2 H0 HD
                MOVE    S_T20N, R10
                RSUB    CHK, 1
                ; sector 1 again of the track just formatted: formatted again
                MOVE    72, R8
                RSUB    WRREQ, 1
                MOVE    M_NCMD, R8
                MOVE    @R8, R8
                MOVE    1, R9
                MOVE    S_T20O, R10
                RSUB    CHK, 1
                ; without the tap bit the same LBA is an ordinary write
                MOVE    M_FMT, R0
                MOVE    0x12F6, @R0
                MOVE    73, R8
                RSUB    WRREQ, 1
                MOVE    M_NCMD, R8
                MOVE    @R8, R8
                MOVE    1, R9
                MOVE    S_T20P, R10
                RSUB    CHK, 1
                XOR     R8, R8
                MOVE    FLP_CMD_WRITE, R9
                MOVE    S_T20Q, R10
                RSUB    CHKCMD, 1

                ; 21. a format that fails: two attempts, the second with force,
                ; the block error; the next fill of that track formats again
                MOVE    M_FMT, R0
                MOVE    0x92F6, @R0
                MOVE    M_FERR, R0
                MOVE    1, @R0                  ; no index
                MOVE    108, R8                 ; C3 H0 R1
                RSUB    WRREQ, 1
                MOVE    M_NCMD, R8
                MOVE    @R8, R8
                MOVE    2, R9
                MOVE    S_T21A, R10
                RSUB    CHK, 1
                MOVE    1, R8
                MOVE    FLP_CMD_FORMAT, R9
                MOVE    S_T21B, R10
                RSUB    CHKCMD, 1
                MOVE    M_FM_A0, R8
                MOVE    @R8, R8
                MOVE    0x0603, R9              ; C3 H0 HD force
                MOVE    S_T21C, R10
                RSUB    CHK, 1
                MOVE    1, R8
                MOVE    S_T21D, R9
                RSUB    CHKACK, 1
                MOVE    M_FERR, R0
                MOVE    0, @R0
                MOVE    109, R8                 ; C3 H0 R2: not formatted yet
                RSUB    WRREQ, 1
                MOVE    M_NCMD, R8
                MOVE    @R8, R8
                MOVE    1, R9
                MOVE    S_T21E, R10
                RSUB    CHK, 1
                XOR     R8, R8
                MOVE    S_T21F, R9
                RSUB    CHKACK, 1
                ; write protected: one attempt, the block error
                MOVE    M_FERR, R0
                MOVE    7, @R0
                MOVE    144, R8                 ; C4 H0 R1
                RSUB    WRREQ, 1
                MOVE    M_NCMD, R8
                MOVE    @R8, R8
                MOVE    1, R9
                MOVE    S_T21G, R10
                RSUB    CHK, 1
                MOVE    1, R8
                MOVE    S_T21H, R9
                RSUB    CHKACK, 1
                MOVE    M_FERR, R0
                MOVE    0, @R0
                MOVE    M_FMT, R0
                MOVE    0, @R0

                ; 22. a blank disk: the drive turns (index seen) but neither
                ; rate reads a header: mounted as 1.44 MB read-write
                RSUB    M_RESET, 1
                RSUB    FLP_OFF, 1
                MOVE    1, R8
                XOR     R9, R9                  ; detect word 0
                XOR     R10, R10
                RSUB    M_INSERT, 1
                MOVE    M_IDX, R0
                MOVE    1, @R0
                RSUB    M_RESET, 1
                RSUB    FLP_ON, 1
                MOVE    FLP_STATE, R8
                MOVE    @R8, R8
                MOVE    FLP_S_READY, R9
                MOVE    S_T22A, R10
                RSUB    CHK, 1
                MOVE    0x0016, R8
                MOVE    0x8000, R9
                XOR     R10, R10
                MOVE    S_T22B, R11
                RSUB    CHKMNT, 1
                MOVE    FLP_SPT, R8
                MOVE    @R8, R8
                MOVE    18, R9
                MOVE    S_T22C, R10
                RSUB    CHK, 1
                MOVE    FLP_RATE, R8
                MOVE    @R8, R8
                MOVE    FLP_ARG_RATEHD, R9
                MOVE    S_T22D, R10
                RSUB    CHK, 1
                ; ... and without index pulses it is no disk (test 18 again)
                RSUB    M_RESET, 1
                RSUB    FLP_OFF, 1
                MOVE    M_IDX, R0
                MOVE    0, @R0
                RSUB    M_RESET, 1
                RSUB    FLP_ON, 1
                MOVE    FLP_STATE, R8
                MOVE    @R8, R8
                MOVE    FLP_S_NODISK, R9
                MOVE    S_T22E, R10
                RSUB    CHK, 1

                ; summary
                MOVE    S_SUM1, R8
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

; FW_INIT: the variable initialisation of FLP_INIT (FLP_INIT itself reads the
; menu bit from hardware, so the bench calls FLP_ON directly)
FW_INIT         INCRB
                RSUB    FLPF_INIT, 1
                MOVE    FLP_STATE, R0
                MOVE    FLP_S_OFF, @R0
                MOVE    FLP_MOUNTED, R0
                MOVE    0, @R0
                MOVE    FLP_CTRL, R0
                MOVE    0, @R0
                MOVE    FLP_N_RD, R0
                MOVE    0, @R0
                MOVE    FLP_N_ERR, R0
                MOVE    0, @R0
                MOVE    FLP_N_WR, R0
                MOVE    0, @R0
                MOVE    FLP_VFY_ERR, R0
                MOVE    0, @R0
                MOVE    FLP_RO, R0
                MOVE    1, @R0
                XOR     R8, R8
                RSUB    FLP_CTRL_SET, 1
                DECRB
                RET

; POLLN: R8 = number of main-loop passes (FLP_POLL calls)
POLLN           INCRB
                MOVE    R8, R0
_POLLN_1        RSUB    FLP_POLL, 1
                SUB     1, R0
                RBRA    _POLLN_1, !Z
                DECRB
                RET

; EXPIRE: end the probe hold-off
EXPIRE          INCRB
                MOVE    FLP_CYC, R0
                SUB     FLP_HOLDOFF, @R0
                DECRB
                RET

; RDREQ / WRREQ: R8 = LBA: present a 512-byte block request for it (the
; vdrive registers of the model), clear the log, run the handler
RDREQ           INCRB
                RSUB    SETREQ, 1
                MOVE    FLP_DRIVE, R8
                RSUB    FLP_DRV_RD, 1
                DECRB
                RET
WRREQ           INCRB
                RSUB    SETREQ, 1
                MOVE    FLP_DRIVE, R8
                RSUB    FLP_DRV_WR, 1
                DECRB
                RET
SETREQ          INCRB
                MOVE    R8, R0
                MOVE    R8, R1
                AND     0xFFFD, SR              ; clear X
                SHL     9, R0                   ; bytes low = LBA * 512
                MOVE    M_VD_BL, R2
                MOVE    R0, @R2
                AND     0xFFFB, SR              ; clear C
                SHR     7, R1                   ; bytes high = LBA / 128
                MOVE    M_VD_BH, R2
                MOVE    R1, @R2
                MOVE    M_VD_SZ, R2
                MOVE    0x0200, @R2
                RSUB    M_RESET, 1
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

; CHKCMD: R8 = index into the command log, R9 = expected command, R10 = desc
CHKCMD          INCRB
                MOVE    M_CMDLOG, R0
                ADD     R8, R0
                MOVE    @R0, R8
                RSUB    CHK, 1
                DECRB
                RET

; CHKACK: R8 = expected block-error flag of the (single) acknowledge, R9 = desc
CHKACK          INCRB
                MOVE    R8, R0
                MOVE    R9, R1
                MOVE    M_ACK_N, R8
                MOVE    @R8, R8
                MOVE    1, R9
                MOVE    S_ACK1, R10
                RSUB    CHK, 1
                MOVE    M_ACK_ERR, R8
                MOVE    @R8, R8
                MOVE    R0, R9
                MOVE    R1, R10
                RSUB    CHK, 1
                DECRB
                RET

; CHKMNT: exactly one mount strobe since M_RESET with size R8:R9 (high:low),
; read-only R10; R11 = desc
CHKMNT          INCRB
                MOVE    R8, R0
                MOVE    R9, R1
                MOVE    R10, R2
                MOVE    R11, R3
                MOVE    M_STR_N, R8
                MOVE    @R8, R8
                MOVE    1, R9
                MOVE    S_STR1, R10
                RSUB    CHK, 1
                MOVE    M_STR_H, R8
                MOVE    @R8, R8
                MOVE    R0, R9
                MOVE    S_STRH, R10
                RSUB    CHK, 1
                MOVE    M_STR_L, R8
                MOVE    @R8, R8
                MOVE    R1, R9
                MOVE    S_STRL, R10
                RSUB    CHK, 1
                MOVE    M_STR_RO, R8
                MOVE    @R8, R8
                MOVE    R2, R9
                MOVE    R3, R10
                RSUB    CHK, 1
                DECRB
                RET

; ----------------------------------------------------------------------------
; the engine model: the registers of rom_loader.vhd window 0xFFFD
; ----------------------------------------------------------------------------

; M_RESET: forget the commands, strobes and acknowledges seen so far
M_RESET         INCRB
                MOVE    M_NCMD, R0
                MOVE    0, @R0
                MOVE    M_STR_N, R0
                MOVE    0, @R0
                MOVE    M_ACK_N, R0
                MOVE    0, @R0
                DECRB
                RET

; M_EJECT: the disk leaves: the drive asserts DISK CHANGE (live and, in the
; engine, the sticky flag)
M_EJECT         INCRB
                MOVE    M_DISK, R0
                MOVE    0, @R0
                MOVE    M_LIVE, R0
                MOVE    1, @R0
                MOVE    M_STICKY, R0
                MOVE    1, @R0
                DECRB
                RET

; M_INSERT: R8 = 1, R9 = detect word the disk will produce, R10 = write
; protected; the latch stays asserted until a step
M_INSERT        INCRB
                MOVE    M_DISK, R0
                MOVE    R8, @R0
                MOVE    M_DET, R0
                MOVE    R9, @R0
                MOVE    M_WP, R0
                MOVE    R10, @R0
                DECRB
                RET

; FLP_WR: R8 = register, R9 = value (the firmware's register write)
FLP_WR          INCRB
                CMP     FLP_R_ARG0, R8
                RBRA    _MWR_ARG0, Z
                CMP     FLP_R_ARG1, R8
                RBRA    _MWR_ARG1, Z
                CMP     FLP_R_ARG2, R8
                RBRA    _MWR_ARG2, Z
                CMP     FLP_R_CTRL, R8
                RBRA    _MWR_CTRL, Z
                CMP     FLP_R_CMD, R8
                RBRA    _MWR_CMD, Z
                RBRA    _MWR_RET, 1
_MWR_ARG0       MOVE    M_ARG0, R0
                MOVE    R9, @R0
                RBRA    _MWR_RET, 1
_MWR_ARG1       MOVE    M_ARG1, R0
                MOVE    R9, @R0
                RBRA    _MWR_RET, 1
_MWR_ARG2       MOVE    M_ARG2, R0
                MOVE    R9, @R0
                RBRA    _MWR_RET, 1

_MWR_CTRL       MOVE    M_CTRL, R0
                MOVE    R9, @R0
                MOVE    R9, R1
                AND     FLP_CTL_CHGCLR, R1
                RBRA    _MWR_C1, Z
                MOVE    M_STICKY, R0
                MOVE    0, @R0
_MWR_C1         MOVE    R9, R1
                AND     FLP_CTL_ACCCLR, R1
                RBRA    _MWR_C2, Z
                MOVE    M_ACC, R0
                MOVE    0, @R0
_MWR_C2         MOVE    R9, R1
                AND     FLP_CTL_VFYCLR, R1
                RBRA    _MWR_RET, Z
                MOVE    M_VFY, R0
                AND     0xFFFD, @R0
                RBRA    _MWR_RET, 1

_MWR_CMD        MOVE    M_NCMD, R1              ; log it
                MOVE    @R1, R2
                AND     0x001F, R2
                MOVE    M_CMDLOG, R0
                ADD     R2, R0
                MOVE    R9, @R0
                ADD     1, @R1
                MOVE    M_ERR, R0
                MOVE    0, @R0
                CMP     FLP_CMD_DETECT, R9
                RBRA    _MWR_DET, Z
                CMP     FLP_CMD_PROBE, R9
                RBRA    _MWR_PROBE, Z
                CMP     FLP_CMD_READ, R9
                RBRA    _MWR_READ, Z
                CMP     FLP_CMD_COPY, R9
                RBRA    _MWR_COPY, Z
                CMP     FLP_CMD_WRITE, R9
                RBRA    _MWR_WRITE, Z
                CMP     FLP_CMD_FORMAT, R9
                RBRA    _MWR_FORMAT, Z
                RBRA    _MWR_RET, 1
_MWR_FORMAT     MOVE    M_ARG0, R1              ; FORMAT_TRACK: its three arguments, the scripted answer
                MOVE    M_FM_A0, R0
                MOVE    @R1, @R0
                MOVE    M_ARG1, R1
                MOVE    M_FM_A1, R0
                MOVE    @R1, @R0
                MOVE    M_ARG2, R1
                MOVE    M_FM_A2, R0
                MOVE    @R1, @R0
                MOVE    M_FERR, R1
                MOVE    M_ERR, R0
                MOVE    @R1, @R0
                RBRA    _MWR_RET, 1
_MWR_DET        MOVE    M_DETRES, R0            ; a disk answers with its headers,
                MOVE    0, @R0                  ; and its recalibrate clears the latch
                MOVE    M_DISK, R1
                CMP     1, @R1
                RBRA    _MWR_RET, !Z
                MOVE    M_DET, R1
                MOVE    @R1, @R0
                MOVE    M_LIVE, R0
                MOVE    0, @R0
                RBRA    _MWR_RET, 1
_MWR_PROBE      MOVE    M_DISK, R1              ; a step with a disk in clears the latch
                CMP     1, @R1
                RBRA    _MWR_RET, !Z
                MOVE    M_LIVE, R0
                MOVE    0, @R0
                RBRA    _MWR_RET, 1
_MWR_READ       MOVE    M_ARG0, R1
                MOVE    M_RD_A0, R0
                MOVE    @R1, @R0
                MOVE    M_ARG1, R1
                MOVE    M_RD_A1, R0
                MOVE    @R1, @R0
                RBRA    _MWR_RET, 1
_MWR_COPY       MOVE    M_ARG1, R1
                MOVE    M_CP_A1, R0
                MOVE    @R1, @R0
                RBRA    _MWR_RET, 1
_MWR_WRITE      MOVE    M_ARG0, R1
                MOVE    M_WR_A0, R0
                MOVE    @R1, @R0
                MOVE    M_ARG1, R1
                MOVE    M_WR_A1, R0
                MOVE    @R1, @R0
                MOVE    M_WERR, R1
                MOVE    M_ERR, R0
                MOVE    @R1, @R0
_MWR_RET        DECRB
                RET

; FLP_RD: R8 = register -> R8 = value (the firmware's register read)
FLP_RD          INCRB
                CMP     FLP_R_STATUS, R8
                RBRA    _MRD_ST, Z
                CMP     FLP_R_DET, R8
                RBRA    _MRD_DET, Z
                CMP     FLP_R_VALID, R8
                RBRA    _MRD_VALID, Z
                CMP     FLP_R_CACHE, R8
                RBRA    _MRD_CACHE, Z
                CMP     FLP_R_VFY, R8
                RBRA    _MRD_VFY, Z
                CMP     FLP_R_ACC, R8
                RBRA    _MRD_ACC, Z
                CMP     FLP_R_FMT, R8
                RBRA    _MRD_FMT, Z
                XOR     R8, R8
                RBRA    _MRD_RET, 1
_MRD_FMT        MOVE    M_FMT, R0
                MOVE    @R0, R8
                RBRA    _MRD_RET, 1
_MRD_ST         MOVE    M_ERR, R0
                MOVE    @R0, R8
                MOVE    M_IDX, R0               ; index pulses seen (a disk turns)
                CMP     1, @R0
                RBRA    _MRD_ST0, !Z
                OR      FLP_ST_IDXSEEN, R8
_MRD_ST0        MOVE    M_LIVE, R0
                CMP     1, @R0
                RBRA    _MRD_ST1, !Z
                OR      FLP_ST_CHGLIVE, R8
_MRD_ST1        MOVE    M_STICKY, R0
                CMP     1, @R0
                RBRA    _MRD_ST2, !Z
                OR      FLP_ST_CHG, R8
_MRD_ST2        MOVE    M_WP, R0
                CMP     1, @R0
                RBRA    _MRD_RET, !Z
                OR      FLP_ST_WP, R8
                RBRA    _MRD_RET, 1
_MRD_DET        MOVE    M_DETRES, R0
                MOVE    @R0, R8
                RBRA    _MRD_RET, 1
_MRD_VALID      MOVE    M_VALID, R0
                MOVE    @R0, R8
                RBRA    _MRD_RET, 1
_MRD_CACHE      MOVE    M_VALID17, R0
                MOVE    @R0, R8
                RBRA    _MRD_RET, 1
_MRD_VFY        MOVE    M_VFY, R0
                MOVE    @R0, R8
                RBRA    _MRD_RET, 1
_MRD_ACC        MOVE    M_ACC, R0
                MOVE    @R0, R8
_MRD_RET        DECRB
                RET

; ----------------------------------------------------------------------------
; the framework model: the vdrive calls flpdrv.asm makes
; ----------------------------------------------------------------------------

; VD_DRV_READ: R8 = drive, R9 = register -> R8 = value
VD_DRV_READ     INCRB
                CMP     VD_BYTES_L, R9
                RBRA    _VDR_BL, Z
                CMP     VD_BYTES_H, R9
                RBRA    _VDR_BH, Z
                CMP     VD_SIZEB, R9
                RBRA    _VDR_SZ, Z
                XOR     R8, R8
                RBRA    _VDR_RET, 1
_VDR_BL         MOVE    M_VD_BL, R0
                MOVE    @R0, R8
                RBRA    _VDR_RET, 1
_VDR_BH         MOVE    M_VD_BH, R0
                MOVE    @R0, R8
                RBRA    _VDR_RET, 1
_VDR_SZ         MOVE    M_VD_SZ, R0
                MOVE    @R0, R8
_VDR_RET        DECRB
                RET

; VD_DRV_WRITE: R8 = drive, R9 = register, R10 = value; an acknowledge is
; recorded together with the block-error level the control register holds
VD_DRV_WRITE    INCRB
                CMP     VD_ACK, R9
                RBRA    _VDW_ACK, Z
                CMP     VD_CACHE_DIRTY, R9
                RBRA    _VDW_DIRTY, Z
                RBRA    _VDW_RET, 1
_VDW_ACK        CMP     1, R10
                RBRA    _VDW_RET, !Z
                MOVE    M_ACK_N, R0
                ADD     1, @R0
                MOVE    M_CTRL, R0
                MOVE    @R0, R0
                AND     FLP_CTL_BLKERR, R0
                MOVE    M_ACK_ERR, R1
                MOVE    0, @R1
                CMP     0, R0
                RBRA    _VDW_RET, Z
                MOVE    1, @R1
                RBRA    _VDW_RET, 1
_VDW_DIRTY      MOVE    M_DIRTY, R0
                MOVE    R10, @R0
_VDW_RET        DECRB
                RET

; VD_STROBE_IM: R8 = drive, R9/R10 = size low/high, R11 = read-only, R12 = type
VD_STROBE_IM    INCRB
                MOVE    M_STR_N, R0
                ADD     1, @R0
                MOVE    M_STR_L, R0
                MOVE    R9, @R0
                MOVE    M_STR_H, R0
                MOVE    R10, @R0
                MOVE    M_STR_RO, R0
                MOVE    R11, @R0
                MOVE    M_VDMOUNT, R0
                MOVE    R9, R1
                OR      R10, R1
                MOVE    0, @R0
                CMP     0, R1
                RBRA    _VDS_RET, Z
                MOVE    1, @R0
_VDS_RET        DECRB
                RET

; VD_MOUNTED: R8 = drive -> Carry = mounted (what the last strobe said)
VD_MOUNTED      INCRB
                MOVE    M_VDMOUNT, R0
                CMP     1, @R0
                RBRA    _VDM_YES, Z
                AND     0xFFFB, SR
                RBRA    _VDM_RET, 1
_VDM_YES        OR      0x0004, SR
_VDM_RET        DECRB
                RET

SAVE_DEVSEL     RET
RESTORE_DEVSEL  RET

; the firmware itself
#include "../../CORE/m2m-rom/flpdrv.asm"

; ----------------------------------------------------------------------------
; data
; ----------------------------------------------------------------------------

S_OK            .ASCII_W "ok: "
S_FAIL          .ASCII_W "FAIL: "
S_GOT           .ASCII_W " got="
S_EXP           .ASCII_W " exp="
S_SUM1          .ASCII_W "flp_ondemand: passed="
S_SUM2          .ASCII_W " failed="
S_ACK1          .ASCII_W "exactly one acknowledge"
S_STR1          .ASCII_W "exactly one mount strobe"
S_STRH          .ASCII_W "mount size high word"
S_STRL          .ASCII_W "mount size low word"

S_T1A           .ASCII_W "1 toggle on with a 1.44 MB disk: READY"
S_T1B           .ASCII_W "1 two engine commands"
S_T1C           .ASCII_W "1 first PROBE"
S_T1D           .ASCII_W "1 then DETECT"
S_T1E           .ASCII_W "1 mounted read-write"
S_T1F           .ASCII_W "1 SPT 18"
S_T1G           .ASCII_W "1 rate 500 kbit/s"
S_T1H           .ASCII_W "1 stale access flag cleared"
S_T1I           .ASCII_W "1 sticky change flag cleared"
S_T2A           .ASCII_W "2 idle READY: no engine command"
S_T2B           .ASCII_W "2 idle READY: no mount strobe"
S_T3A           .ASCII_W "3 read LBA 19: two commands"
S_T3B           .ASCII_W "3 READ_TRACK"
S_T3C           .ASCII_W "3 COPY"
S_T3D           .ASCII_W "3 READ arg0 = C0 H1 HD"
S_T3E           .ASCII_W "3 READ arg1 = R2 SPT18"
S_T3F           .ASCII_W "3 COPY arg1 = R2"
S_T3G           .ASCII_W "3 acknowledged without error"
S_T3H           .ASCII_W "3 cache-dirty flag cleared"
S_T4A           .ASCII_W "4 read LBA 17: R18"
S_T4B           .ASCII_W "4 valid from the cache word: READ, COPY"
S_T4C           .ASCII_W "4 acknowledged without error"
S_T5A           .ASCII_W "5 missing sector: two attempts"
S_T5B           .ASCII_W "5 second attempt is a READ"
S_T5C           .ASCII_W "5 second attempt with force"
S_T5D           .ASCII_W "5 acknowledged with the block error"
S_T6A           .ASCII_W "6 eject while idle: NODISK"
S_T6B           .ASCII_W "6 unmounted"
S_T6C           .ASCII_W "6 no engine command on the eject"
S_T6D           .ASCII_W "6 sticky change flag consumed"
S_T7A           .ASCII_W "7 unmounted, no access: no engine command"
S_T8A           .ASCII_W "8 access with no disk: one command"
S_T8B           .ASCII_W "8 it is a PROBE"
S_T8C           .ASCII_W "8 access flag consumed"
S_T8D           .ASCII_W "8 back to NODISK"
S_T8E           .ASCII_W "8 no DETECT without a disk"
S_T8F           .ASCII_W "8 no strobe (was unmounted)"
S_T9A           .ASCII_W "9 hold-off: no second probe"
S_T9B           .ASCII_W "9 hold-off: the access flag is kept"
S_T9C           .ASCII_W "9 hold-off over: the probe follows"
S_T9D           .ASCII_W "9 still NODISK"
S_T10A          .ASCII_W "10 DD disk in: DETECT running"
S_T10B          .ASCII_W "10 second command is DETECT"
S_T10C          .ASCII_W "10 READY"
S_T10D          .ASCII_W "10 mounted read-only"
S_T10E          .ASCII_W "10 SPT 9"
S_T10F          .ASCII_W "10 rate 250 kbit/s"
S_T10G          .ASCII_W "10 exactly PROBE and DETECT"
S_T10H          .ASCII_W "10 access flag consumed by the mount"
S_T11A          .ASCII_W "11 read LBA 10: arg0 = C0 H1 DD"
S_T11B          .ASCII_W "11 read LBA 10: arg1 = R2 SPT9"
S_T11C          .ASCII_W "11 acknowledged without error"
S_T12A          .ASCII_W "12 write on a read-only mount: no command"
S_T12B          .ASCII_W "12 acknowledged with the block error"
S_T13A          .ASCII_W "13 swap under a request: no command"
S_T13B          .ASCII_W "13 request refused"
S_T13C          .ASCII_W "13 next poll: NODISK"
S_T13D          .ASCII_W "13 unmounted"
S_T13E          .ASCII_W "13 retry: READY"
S_T13F          .ASCII_W "13 mounted 1.44 MB read-write"
S_T13G          .ASCII_W "13 PROBE and DETECT for it"
S_T14A          .ASCII_W "14 write LBA 5: one command"
S_T14B          .ASCII_W "14 WRITE_SECTOR"
S_T14C          .ASCII_W "14 WRITE arg0 = C0 H0 HD"
S_T14D          .ASCII_W "14 WRITE arg1 = R6 SPT18"
S_T14E          .ASCII_W "14 acknowledged without error"
S_T14F          .ASCII_W "14 cache-dirty flag cleared"
S_T15A          .ASCII_W "15 write fails: two attempts"
S_T15B          .ASCII_W "15 second attempt with force"
S_T15C          .ASCII_W "15 acknowledged with the block error"
S_T16A          .ASCII_W "16 write protected: one attempt"
S_T16B          .ASCII_W "16 acknowledged with the block error"
S_T17A          .ASCII_W "17 verify failure remembered"
S_T17B          .ASCII_W "17 engine flag cleared"
S_T17C          .ASCII_W "17 next read: no command"
S_T17D          .ASCII_W "17 next read parked"
S_T17E          .ASCII_W "17 next write: no command"
S_T17F          .ASCII_W "17 next write parked"
S_T18A          .ASCII_W "18 unreadable disk: NODISK"
S_T18B          .ASCII_W "18 PROBE and DETECT"
S_T18C          .ASCII_W "18 no strobe"
S_T18D          .ASCII_W "18 access flag consumed"
S_T19A          .ASCII_W "19 toggle off from NODISK: OFF"
S_T19B          .ASCII_W "19 nothing to unmount"
S_T19C          .ASCII_W "19 engine disabled"
S_T19D          .ASCII_W "19 toggle on again: READY"
S_T19E          .ASCII_W "19 verify failure not carried over"
S_T19F          .ASCII_W "19 toggle off: unmounted"
S_T20A          .ASCII_W "20 fill of C1 H0 R1: one command"
S_T20B          .ASCII_W "20 it is FORMAT_TRACK"
S_T20C          .ASCII_W "20 FORMAT arg0 = C1 H0 HD"
S_T20D          .ASCII_W "20 FORMAT arg1 = SC 18"
S_T20E          .ASCII_W "20 FORMAT arg2 = filler F6"
S_T20F          .ASCII_W "20 acknowledged without error"
S_T20G          .ASCII_W "20 cache-dirty flag cleared"
S_T20H          .ASCII_W "20 fill of R2: no command"
S_T20I          .ASCII_W "20 fill of R2 acknowledged without error"
S_T20J          .ASCII_W "20 fill of R18: no command"
S_T20K          .ASCII_W "20 fill of C1 H1 R1: one command"
S_T20L          .ASCII_W "20 FORMAT arg0 = C1 H1 HD"
S_T20M          .ASCII_W "20 fill of C2 H0 R5 (track not formatted): one command"
S_T20N          .ASCII_W "20 FORMAT arg0 = C2 H0 HD"
S_T20O          .ASCII_W "20 fill of C2 H0 R1 again: formatted again"
S_T20P          .ASCII_W "20 tap bit clear: one command"
S_T20Q          .ASCII_W "20 it is WRITE_SECTOR"
S_T21A          .ASCII_W "21 format fails: two attempts"
S_T21B          .ASCII_W "21 second attempt is FORMAT_TRACK"
S_T21C          .ASCII_W "21 second attempt with force"
S_T21D          .ASCII_W "21 acknowledged with the block error"
S_T21E          .ASCII_W "21 next fill of that track: formatted again"
S_T21F          .ASCII_W "21 acknowledged without error"
S_T21G          .ASCII_W "21 write protected: one attempt"
S_T21H          .ASCII_W "21 acknowledged with the block error"
S_T22A          .ASCII_W "22 blank disk (index, no headers): READY"
S_T22B          .ASCII_W "22 mounted 1.44 MB read-write"
S_T22C          .ASCII_W "22 SPT 18"
S_T22D          .ASCII_W "22 rate 500 kbit/s"
S_T22E          .ASCII_W "22 no index: NODISK"

N_PASS          .DW     0
N_FAIL          .DW     0

; engine model state
M_DISK          .DW     0                       ; a disk is in
M_DET           .DW     0                       ; the detect word it produces
M_DETRES        .DW     0                       ; result of the last DETECT
M_WP            .DW     0
M_LIVE          .DW     1                       ; DISK CHANGE line (latched by the drive)
M_STICKY        .DW     0                       ; the engine's sticky flag
M_ACC           .DW     0                       ; rom_loader's access flag
M_VFY           .DW     0
M_ERR           .DW     0                       ; error code of the last command
M_WERR          .DW     0                       ; what WRITE_SECTOR answers
M_VALID         .DW     0
M_VALID17       .DW     0
M_CTRL          .DW     0
M_ARG0          .DW     0
M_ARG1          .DW     0
M_RD_A0         .DW     0
M_RD_A1         .DW     0
M_CP_A1         .DW     0
M_WR_A0         .DW     0
M_WR_A1         .DW     0
M_ARG2          .DW     0
M_FMT           .DW     0                       ; the format tap word (rom_loader register 14)
M_IDX           .DW     0                       ; index pulses seen (status bit 12)
M_FERR          .DW     0                       ; what FORMAT_TRACK answers
M_FM_A0         .DW     0
M_FM_A1         .DW     0
M_FM_A2         .DW     0
M_NCMD          .DW     0
M_CMDLOG        .BLOCK  32

; framework model state
M_VD_BL         .DW     0
M_VD_BH         .DW     0
M_VD_SZ         .DW     0
M_ACK_N         .DW     0
M_ACK_ERR       .DW     0
M_DIRTY         .DW     0
M_STR_N         .DW     0
M_STR_L         .DW     0
M_STR_H         .DW     0
M_STR_RO        .DW     0
M_VDMOUNT       .DW     0
OPTM_HEAP       .DW     0                       ; no menu: FLP_STROBE skips the name
SCR$OSM_O_DX    .DW     0

#include "../../CORE/m2m-rom/flpdrv_vars.asm"
