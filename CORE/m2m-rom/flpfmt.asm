; ****************************************************************************
; PCXT-EGA on MiSTer2MEGA65: the internal floppy drive, FORMAT (phase 4)
;
; flpfmt.asm: the QNICE side of docs/floppy.md phase 4 ("Formatting"),
; included at the end of flpdrv.asm and reached through three hooks there:
;   FLP_INIT      -> FLPF_INIT      variables
;   FLP_DET_APPLY -> FLPF_BLANK     a disk with index pulses but no readable
;                                   headers is mounted as 1.44 MB so that
;                                   FORMAT A: can reach it
;   FLP_DRV_WR    -> FLPF_WR_HOOK   a block write that is the fill of a
;                                   FORMAT TRACK sector
;
; How DOS formats through this core: FORMAT issues INT 13h AH=05h per
; cylinder and head; the BIOS (int_13_fn05) sends the FDC a FORMAT TRACK
; command with the sector count, gap and filler byte of its parameter table
; (18 / 0x6C / 0xF6 for 1.44 MB, 9 / 0x50 / 0xF6 for 720 KB) and the ID
; fields C/H/R/N of every sector by DMA. The emulated FDC (floppy.v, the
; image-based controller) turns every ID field into an ordinary block write
; of 512 x the filler byte to the LBA of that C/H/R, one after the other, so
; what arrives here is a run of block writes with fill data - which is
; indistinguishable from DOS writing those sectors, and must not be, because
; formatting a track destroys its old contents while writing a sector of a
; bad track must not. So floppy.v is tapped: its management register 1 says
; whether the request being served is such a fill (and the sector count
; and filler byte of the command); mgmt_bridge samples that word when it dispatches
; the request (the format command itself completes long before the last
; fill is written) and rom_loader shows it in FLP_R_FMT, stable until the
; block is acknowledged.
;
; The rule: a fill block for sector 1 of a track, or for a track other than
; the one formatted last, makes the engine format that whole track
; (FORMAT_TRACK: the IBM System 34 layout from the index pulse to the next,
; sector count from the tap, filler from the tap, the standard gap 3 of
; the rate, then one read-back pass that fills the track cache); the fill
; blocks that follow for the same track are acknowledged without any disk
; activity - their content is the filler byte, which is on the disk already
; (18 WRITE_SECTORs would cost 18 revolutions). The DOS verify
; pass then reads every sector: cache hits, no disk time. The boot sector,
; FATs and root directory are ordinary writes afterwards. A format that
; fails (write protect, no index, the read-back missing sectors) is
; acknowledged with the block error like a failed write: the drive is
; parked, the next DOS access fails and FORMAT reports the track.
;
; Geometry: floppy.v refuses (hangs, so the BIOS times out and FORMAT
; reports an error) a FORMAT TRACK whose sector count is not that of the mount,
; so FORMAT A: /F:720 on a disk mounted as 1.44 MB does not reach the
; firmware; the sector count in the tap always equals FLP_SPT. A disk the
; detection cannot read at either rate but which turns (index pulses seen)
; is mounted as 1.44 MB: a blank disk, an erased one, or a foreign format
; (Amiga, a MEGA65/1581 disk). DOS reading it gets errors; FORMAT A: makes
; it a PC disk. 720 KB blanks are a documented limitation (docs/floppy.md).
;
; done by silent-command in 2026 and licensed under GPL v3
; ****************************************************************************

FLP_CMD_FORMAT  .EQU 7                          ; engine command FORMAT_TRACK
FLP_R_ARG2      .EQU 0x7004                     ; write: fill byte (7..0), gap 3 (15..8, 0 = default)
FLP_R_FMT       .EQU 0x700E                     ; the format tap: bit 15 fill block, 14..8 SC, 7..0 filler
FLP_R_FMTTAIL   .EQU 0x700F                     ; gap 4b bytes of the last FORMAT_TRACK (debug)
FLP_FMT_ACTIVE  .EQU 0x8000
FLP_FMT_SC      .EQU 0x7F00
FLP_ST_IDXSEEN  .EQU 0x1000                     ; status bit 12: index pulses during the last command
FLPF_E_WPROT    .EQU 7
FLPF_NO_TRK     .EQU 0xFFFF

FLPF_STR_FMT    .ASCII_W "FLP: format track arg0="
FLPF_STR_TAIL   .ASCII_W "FLP: formatted, gap 4b bytes="
FLPF_STR_ERR    .ASCII_W "FLP: format error status="
FLPF_STR_BLANK  .ASCII_W " -> turns but nothing readable: blank or foreign disk, mounted as 1.44 MB for FORMAT"

; FLPF_INIT: the variables (from FLP_INIT); registers preserved
FLPF_INIT       INCRB
                MOVE    FLPF_TRK, R0
                MOVE    FLPF_NO_TRK, @R0
                MOVE    FLPF_N_FMT, R0
                MOVE    0, @R0
                MOVE    FLPF_N_ACK, R0
                MOVE    0, @R0
                DECRB
                RET

; FLPF_BLANK: from FLP_DET_APPLY when neither rate produced a header: was
; the disk turning (index pulses seen, no timeout)? Then it is a blank or
; foreign disk: SPT / rate set for 1.44 MB -> Carry = 1, the caller mounts;
; otherwise (no disk) Carry = 0. R8 clobbered.
FLPF_BLANK      INCRB
                RSUB    FLP_STATUS, 1
                MOVE    R8, R0
                AND     FLP_ST_ERR, R8          ; the DETECT ended in an error (no index)?
                RBRA    _FLPF_BL_NO, !Z
                MOVE    R0, R8
                AND     FLP_ST_IDXSEEN, R8      ; index pulses seen?
                RBRA    _FLPF_BL_NO, Z
                MOVE    FLPF_STR_BLANK, R8
                SYSCALL(puts, 1)
                SYSCALL(crlf, 1)
                MOVE    FLP_SPT, R0
                MOVE    18, @R0
                MOVE    FLP_RATE, R0
                MOVE    FLP_ARG_RATEHD, @R0
                MOVE    FLPF_TRK, R0            ; a new disk: nothing formatted on it yet
                MOVE    FLPF_NO_TRK, @R0
                OR      0x0004, SR              ; set Carry
                RBRA    _FLPF_BL_RET, 1
_FLPF_BL_NO     AND     0xFFFB, SR              ; clear Carry
_FLPF_BL_RET    DECRB
                RET

; FLPF_WR_HOOK: from FLP_DRV_WR once the request is converted and checked:
; R8 = arg0 (C | H | rate), R9 = arg1 (R | SPT << 8), R10 = LBA (log).
; -> Carry = 1: the block is the fill of a FORMAT TRACK sector and has been
; acknowledged here (the track formatted, or the fill of the track formatted
; last accepted without touching the disk); Carry = 0: an ordinary write,
; the caller writes it. R8..R10 clobbered.
FLPF_WR_HOOK    INCRB
                MOVE    R8, R0                  ; R0: arg0
                MOVE    R9, R1                  ; R1: arg1
                MOVE    R10, R2                 ; R2: LBA
                MOVE    FLP_R_FMT, R8
                RSUB    FLP_RD, 1
                MOVE    R8, R3                  ; R3: the tap word
                AND     FLP_FMT_ACTIVE, R8
                RBRA    _FLPF_WH_NO, Z          ; an ordinary write

                ; the track key C * 2 + H, and R
                MOVE    R0, R4
                AND     0x00FF, R4
                AND     0xFFFD, SR              ; clear X
                SHL     1, R4
                MOVE    R0, R5
                AND     FLP_ARG_HEAD, R5
                RBRA    _FLPF_WH_1, Z
                OR      1, R4                   ; R4: track key
_FLPF_WH_1      MOVE    R1, R5
                AND     0x001F, R5              ; R5: R
                CMP     1, R5                   ; sector 1: a (new) format of this track
                RBRA    _FLPF_WH_FMT, Z
                MOVE    FLPF_TRK, R6
                CMP     R4, @R6                 ; another track than the one formatted last?
                RBRA    _FLPF_WH_FMT, !Z
                MOVE    FLPF_N_ACK, R6          ; the fill is on the disk: acknowledge only
                ADD     1, @R6
                XOR     R8, R8
                RSUB    FLP_ACK, 1
                RBRA    _FLPF_WH_YES, 1

                ; FORMAT_TRACK: sector count and filler from the tap, the
                ; gap 3 of the rate (arg2 high byte 0); two attempts, the
                ; second with a recalibrate, none after a write-protect refusal
_FLPF_WH_FMT    MOVE    FLPF_STR_FMT, R8
                MOVE    R0, R9
                RSUB    FLP_LOG, 1
                MOVE    FLP_R_ARG2, R8
                MOVE    R3, R9
                AND     0x00FF, R9              ; arg2 = filler byte
                RSUB    FLP_WR, 1
                MOVE    R3, R1
                AND     FLP_FMT_SC, R1          ; R1: arg1 = SC << 8
                MOVE    R0, R3                  ; R3: arg0 of the attempt
                XOR     R5, R5                  ; R5: attempt
_FLPF_WH_TRY    MOVE    FLP_CMD_FORMAT, R8
                MOVE    R3, R9
                MOVE    R1, R10
                RSUB    FLP_CMD, 1
                RSUB    FLP_WAIT, 1
                MOVE    R8, R2                  ; R2: status of the attempt
                AND     FLP_ST_ERR, R8
                RBRA    _FLPF_WH_OK, Z
                CMP     FLPF_E_WPROT, R8        ; write protected: no retry
                RBRA    _FLPF_WH_ERR, Z
                ADD     1, R5
                OR      FLP_ARG_FORCE, R3       ; next attempt recalibrates
                CMP     FLP_ATTEMPTS, R5
                RBRA    _FLPF_WH_TRY, !Z

_FLPF_WH_ERR    MOVE    FLPF_TRK, R6            ; nothing formatted: the next fill formats again
                MOVE    FLPF_NO_TRK, @R6
                MOVE    FLP_N_ERR, R6
                ADD     1, @R6
                MOVE    FLP_LAST_ERR, R6
                MOVE    R2, @R6
                MOVE    FLPF_STR_ERR, R8
                MOVE    R2, R9
                RSUB    FLP_LOG, 1
                MOVE    1, R8                   ; the block error parks the drive
                RSUB    FLP_ACK, 1
                RBRA    _FLPF_WH_YES, 1

_FLPF_WH_OK     MOVE    FLPF_TRK, R6
                MOVE    R4, @R6
                MOVE    FLPF_N_FMT, R6
                ADD     1, @R6
                MOVE    FLP_R_FMTTAIL, R8
                RSUB    FLP_RD, 1
                MOVE    R8, R9
                MOVE    FLPF_STR_TAIL, R8
                RSUB    FLP_LOG, 1
                XOR     R8, R8
                RSUB    FLP_ACK, 1
_FLPF_WH_YES    OR      0x0004, SR              ; set Carry
                RBRA    _FLPF_WH_RET, 1
_FLPF_WH_NO     AND     0xFFFB, SR              ; clear Carry
_FLPF_WH_RET    DECRB
                RET
