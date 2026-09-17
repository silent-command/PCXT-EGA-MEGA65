; ****************************************************************************
; PCXT-EGA on MiSTer2MEGA65: the MEGA65 internal 3.5" floppy drive as A:
;
; flpdrv.asm: the QNICE side of the read and write paths of docs/floppy.md
; (phases 2 and 3).
;
; When the Options menu toggle "A: internal drive" (config.vhd line
; FLP_MENU_LINE, group FLP_MENU_GRP) is on, virtual drive 0 is not an image
; on the SD card but the real drive: this module mounts vdrive 0 with the
; geometry it detects (1.44 MB or 720 KB; read-only while the drive reports
; write protect, read-write otherwise, re-evaluated at every re-mount), and
; every block the emulated FDC requests for vdrive 0 is served by the
; sector engine in CORE/vhdl/floppy_sector_engine.vhd through the register
; window 0xFFFD of the PCXT ROM device (CORE/vhdl/rom_loader.vhd, see
; there for the register map).
;
; States (FLP_STATE):
;   FLP_S_OFF     toggle off; the engine is disabled, nothing here runs.
;   FLP_S_NODISK  toggle on, no disk found: the FDC is told "no media", so
;                 DOS gets "Not ready reading drive A" like on a real PC.
;                 Every 2 s a PROBE steps the head in and out: a step with a
;                 disk in clears the drive DISK CHANGE latch, so the line
;                 afterwards says whether a disk is in - without the motor.
;   FLP_S_PROBING a PROBE is running (FLP_POLL finishes it).
;   FLP_S_DETECT  a DETECT is running (motor, recalibrate, both rates).
;   FLP_S_READY   mounted; the FDC has the detected geometry; reads served.
; FLP_POLL runs these from HANDLE_IO (the main loop) without blocking; only
; the initial mount at start-up (FLP_INIT) waits for its DETECT, so that the
; drive is ready before the BIOS looks at A:.
;
; A block request (FLP_DRV_RD, from HANDLE_DRV_RD): the FDC LBA is
; turned back into the C/H/R DOS asked for with the sectors-per-track the
; FDC was told (FLP_SPT, flpdrv_calc.asm), READ_TRACK fills the engine
; track cache (a no-op when the track is already cached), COPY moves the
; sector into the vdrive block buffer in hardware, and the request is
; acknowledged. On failure (two attempts, the second with a recalibrate)
; the request is acknowledged with the block-error flag set: mgmt_bridge
; then streams nothing, the BIOS times out and DOS reports the error
; instead of reading garbage; drive A is dead until the next core reset
; (floppy.v cannot be told about read errors, see docs/floppy.md).
; A disk change (the drive DISK CHANGE line, sticky in the engine) is
; handled by re-running DETECT and re-mounting, which makes floppy.v raise
; its change line so that DOS re-reads the disk; a removed disk unmounts.
; A block write (FLP_DRV_WR, from HANDLE_DRV_WR): the bridge has drained
; floppy.v FIFO 512 bytes into the vdrive block buffer; WRITE_SECTOR makes the
; engine read them back from there and write the sector (two attempts, the
; second with a recalibrate), then the request is acknowledged. The engine
; verifies the sector in the background on its next pass (a CRC signature
; read-back); a failure shows in register FLP_R_VFY and is remembered here
; (FLP_VFY_ERR) so that the next block request, read or write, is
; acknowledged with the block-error flag: floppy.v has long completed the
; write DOS asked for (it completes when its FIFO is drained, before the
; disk is touched), so the error can only surface on the following
; request, where mgmt_bridge parks the drive until the next core reset.
; The image write cache of the framework is bypassed: a physical write is done
; when the FDC delivers it, and the cache-dirty flag vdrives sets on the
; acknowledge is cleared at once (the HANDLE_IO flush loop skips this drive
; too), so no 2-second flush ever runs for a drive that has no image.
; A write-protected disk is mounted read-only: floppy.v refuses writes
; itself with the write-protect error of the FDC, none reaches here.
;
; done by silent-command in 2026 and licensed under GPL v3
; ****************************************************************************

FLP_DEV         .EQU 0x0110                     ; rom_loader.vhd (C_DEV_ROM_PCXT)
FLP_WIN         .EQU 0xFFFD                     ; floppy engine register window
FLP_R_CMD       .EQU 0x7000                     ; M2M$RAMROM_DATA + register
FLP_R_ARG0      .EQU 0x7001
FLP_R_ARG1      .EQU 0x7002
FLP_R_CTRL      .EQU 0x7003
FLP_R_STATUS    .EQU 0x7000
FLP_R_DET       .EQU 0x7001
FLP_R_VALID     .EQU 0x7002
FLP_R_CRCERR    .EQU 0x7003
FLP_R_CACHE     .EQU 0x7004
FLP_R_VFY       .EQU 0x700C                     ; live: bit 0 verify pending, bit 1 verify failed

FLP_CMD_DETECT  .EQU 1
FLP_CMD_READ    .EQU 2
FLP_CMD_COPY    .EQU 3
FLP_CMD_PROBE   .EQU 4
FLP_CMD_MOTOFF  .EQU 5
FLP_CMD_WRITE   .EQU 6

FLP_ST_BUSY     .EQU 0x8000
FLP_ST_CHGLIVE  .EQU 0x2000                     ; DISK CHANGE line, live
FLP_ST_CHG      .EQU 0x0200                     ; DISK CHANGE, sticky
FLP_ST_WP       .EQU 0x0100
FLP_ST_ERR      .EQU 0x00FF
FLP_VFY_PEND    .EQU 0x0001
FLP_VFY_FAIL    .EQU 0x0002
FLP_DET_DD      .EQU 0x0200
FLP_DET_HD      .EQU 0x0100
FLP_DET_MAXR    .EQU 0x00FF

FLP_CTL_EN      .EQU 0x0001
FLP_CTL_CHGCLR  .EQU 0x0002
FLP_CTL_BLKERR  .EQU 0x0004
FLP_CTL_VFYCLR  .EQU 0x0008
FLP_ARG_HEAD    .EQU 0x0100
FLP_ARG_RATEHD  .EQU 0x0200
FLP_ARG_FORCE   .EQU 0x0400

FLP_MENU_LINE   .EQU 76                         ; config.vhd OPTM_ITEMS line of " A: internal drive"
FLP_MENU_GRP    .EQU 21                         ; config.vhd OPTM_G_FLP_INT
FLP_DRIVE       .EQU 0                          ; vdrive of drive A
FLP_SIZE_HD_L   .EQU 0x8000                     ; 1474560 bytes = 0x00168000
FLP_SIZE_HD_H   .EQU 0x0016
FLP_SIZE_DD_L   .EQU 0x4000                     ; 737280 bytes = 0x000B4000
FLP_SIZE_DD_H   .EQU 0x000B
FLP_MAX_LBA     .EQU 2880
FLP_PROBE_WAIT  .EQU 0x05F6                     ; 2 s in IO$CYC_MID units (763 Hz)
FLP_ATTEMPTS    .EQU 2

FLP_S_OFF       .EQU 0
FLP_S_NODISK    .EQU 1
FLP_S_PROBING   .EQU 2
FLP_S_DETECT    .EQU 3
FLP_S_READY     .EQU 4

FLP_STR_ON      .ASCII_W "FLP: A: internal drive on"
FLP_STR_OFF     .ASCII_W "FLP: A: internal drive off"
FLP_STR_DET     .ASCII_W "FLP: detect="
FLP_STR_HD      .ASCII_W " -> 1.44 MB, mounted"
FLP_STR_DD      .ASCII_W " -> 720 KB, mounted"
FLP_STR_RO      .ASCII_W " read-only (write protected)"
FLP_STR_RW      .ASCII_W " read-write"
FLP_STR_NONE    .ASCII_W " -> no disk"
FLP_STR_CHG     .ASCII_W "FLP: disk change"
FLP_STR_RDERR   .ASCII_W "FLP: read error lba="
FLP_STR_STAT    .ASCII_W " status="
FLP_STR_WR      .ASCII_W "FLP: write error lba="
FLP_STR_VFY     .ASCII_W "FLP: write verify failed, drive parked on the next request"
FLP_STR_PARK    .ASCII_W "FLP: request parked after a verify failure lba="
FLP_STR_NAME    .ASCII_W "Internal drive"

#include "flpdrv_calc.asm"

; ----------------------------------------------------------------------------
; Register access
; ----------------------------------------------------------------------------

; FLP_SEL: select the engine register window; R0 of the current bank used
FLP_SEL         INCRB
                MOVE    M2M$RAMROM_DEV, R0
                MOVE    FLP_DEV, @R0
                MOVE    M2M$RAMROM_4KWIN, R0
                MOVE    FLP_WIN, @R0
                DECRB
                RET

; FLP_RD: R8 = register -> R8 = value
FLP_RD          RSUB    FLP_SEL, 1
                MOVE    @R8, R8
                RET

; FLP_WR: R8 = register, R9 = value; registers preserved
FLP_WR          RSUB    FLP_SEL, 1
                MOVE    R9, @R8
                RET

; FLP_CTRL_SET: R8 = control word (FLP_CTL_*); the enable / block-error
; levels are remembered in FLP_CTRL, the clear bits are pulses
FLP_CTRL_SET    INCRB
                MOVE    R8, R0
                MOVE    R0, R9
                AND     0xFFF5, R9              ; without the clear pulses
                MOVE    FLP_CTRL, R1
                MOVE    R9, @R1
                MOVE    R0, R9
                MOVE    FLP_R_CTRL, R8
                RSUB    FLP_WR, 1
                MOVE    R0, R8
                DECRB
                RET

; FLP_CMD: R8 = command, R9 = arg0, R10 = arg1; starts the command
FLP_CMD         INCRB
                MOVE    R8, R0
                MOVE    R9, R1
                MOVE    R10, R2
                MOVE    FLP_R_ARG0, R8
                RSUB    FLP_WR, 1               ; R9 = arg0
                MOVE    FLP_R_ARG1, R8
                MOVE    R2, R9
                RSUB    FLP_WR, 1
                MOVE    FLP_R_CMD, R8
                MOVE    R0, R9
                RSUB    FLP_WR, 1
                MOVE    R0, R8
                MOVE    R1, R9
                MOVE    R2, R10
                DECRB
                RET

; FLP_WAIT: poll until the engine is idle -> R8 = status word (the engine
; bounds every command by its own timeouts, so this always returns)
FLP_WAIT        INCRB
_FLP_WAIT_1     MOVE    FLP_R_STATUS, R8
                RSUB    FLP_RD, 1
                MOVE    R8, R0
                AND     FLP_ST_BUSY, R0
                RBRA    _FLP_WAIT_1, !Z
                DECRB
                RET

; FLP_STATUS: -> R8 = status word (no wait)
FLP_STATUS      MOVE    FLP_R_STATUS, R8
                RSUB    FLP_RD, 1
                RET

; FLP_LOG: R8 = string, R9 = hex value; registers preserved
FLP_LOG         INCRB
                MOVE    R8, R0
                MOVE    R9, R1
                SYSCALL(puts, 1)
                MOVE    R1, R8
                SYSCALL(puthex, 1)
                SYSCALL(crlf, 1)
                MOVE    R0, R8
                MOVE    R1, R9
                DECRB
                RET

; FLP_NOW: -> R8 = IO$CYC_MID (763 Hz)
FLP_NOW         MOVE    IO$CYC_MID, R8
                MOVE    @R8, R8
                RET

; ----------------------------------------------------------------------------
; Public: menu and start-up
; ----------------------------------------------------------------------------

; FLP_OWNS_DRIVE: R8 = vdrive -> Carry=1 if the internal drive owns it now
; (the toggle is on); registers preserved
FLP_OWNS_DRIVE  INCRB
                CMP     FLP_DRIVE, R8
                RBRA    _FLP_OWN_NO, !Z
                MOVE    FLP_STATE, R0
                CMP     FLP_S_OFF, @R0
                RBRA    _FLP_OWN_NO, Z
                OR      0x0004, SR              ; set Carry
                RBRA    _FLP_OWN_RET, 1
_FLP_OWN_NO     AND     0xFFFB, SR              ; clear Carry
_FLP_OWN_RET    DECRB
                RET

; FLP_MENU_BIT: -> R8 = 1 if the "A: internal drive" toggle is on
FLP_MENU_BIT    INCRB
                MOVE    M2M$CFM_ADDR, R0
                MOVE    4, @R0                  ; FLP_MENU_LINE / 16
                MOVE    M2M$CFM_DATA, R0
                MOVE    @R0, R8
                AND     0xFFFB, SR              ; clear C (SHR shifts it in)
                SHR     12, R8                  ; FLP_MENU_LINE mod 16
                AND     0x0001, R8
                DECRB
                RET

; FLP_INIT: called from PREP_START, before the core is released. Starts the
; physical mode if the toggle is on (saved settings) and waits for the
; detection so that the BIOS finds the drive ready.
FLP_INIT        SYSCALL(enter, 1)
                SUB     2, SP                   ; SAVE_DEVSEL buffer
                MOVE    SP, R8
                RSUB    SAVE_DEVSEL, 1
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
                RSUB    FLP_CTRL_SET, 1         ; engine disabled
                RSUB    FLP_MENU_BIT, 1
                CMP     1, R8
                RBRA    _FLP_INIT_RET, !Z
                RSUB    FLP_ON, 1
_FLP_INIT_1     RSUB    FLP_POLL, 1             ; run the DETECT to its end
                MOVE    FLP_STATE, R0
                CMP     FLP_S_DETECT, @R0
                RBRA    _FLP_INIT_1, Z
_FLP_INIT_RET   MOVE    SP, R8
                RSUB    RESTORE_DEVSEL, 1
                ADD     2, SP
                SYSCALL(leave, 1)
                RET

; FLP_OSM_SEL: OSM_SEL_POST hook, R8 = menu group, R9 = 0/1 selected;
; registers preserved
FLP_OSM_SEL     SYSCALL(enter, 1)
                CMP     FLP_MENU_GRP, R8
                RBRA    _FLP_OSM_RET, !Z
                SUB     2, SP
                MOVE    SP, R8
                RSUB    SAVE_DEVSEL, 1
                CMP     1, R9
                RBRA    _FLP_OSM_OFF, !Z
                RSUB    FLP_ON, 1
                RBRA    _FLP_OSM_1, 1
_FLP_OSM_OFF    RSUB    FLP_OFF, 1
_FLP_OSM_1      MOVE    SP, R8
                RSUB    RESTORE_DEVSEL, 1
                ADD     2, SP
_FLP_OSM_RET    SYSCALL(leave, 1)
                RET

; FLP_ON: leave FLP_S_OFF: drop an image mounted on drive A, enable the
; engine and start the detection (FLP_POLL completes it)
FLP_ON          SYSCALL(enter, 1)
                MOVE    FLP_STATE, R0
                CMP     FLP_S_OFF, @R0
                RBRA    _FLP_ON_RET, !Z
                MOVE    FLP_STR_ON, R8
                SYSCALL(puts, 1)
                SYSCALL(crlf, 1)
                MOVE    FLP_DRIVE, R8
                RSUB    VD_MOUNTED, 1           ; an image on A:?
                RBRA    _FLP_ON_1, !C
                XOR     R8, R8                  ; yes: unmount it
                RSUB    FLP_STROBE, 1
_FLP_ON_1       MOVE    FLP_MOUNTED, R0
                MOVE    0, @R0
                MOVE    FLP_VFY_ERR, R0
                MOVE    0, @R0
                MOVE    FLP_CTL_EN, R8
                RSUB    FLP_CTRL_SET, 1
                MOVE    FLP_CMD_DETECT, R8
                XOR     R9, R9
                XOR     R10, R10
                RSUB    FLP_CMD, 1
                MOVE    FLP_STATE, R0
                MOVE    FLP_S_DETECT, @R0
_FLP_ON_RET     SYSCALL(leave, 1)
                RET

; FLP_OFF: back to FLP_S_OFF: unmount, disable the engine (motor off,
; drive deselected)
FLP_OFF         SYSCALL(enter, 1)
                MOVE    FLP_STATE, R0
                CMP     FLP_S_OFF, @R0
                RBRA    _FLP_OFF_RET, Z
                RSUB    FLP_WAIT, 1             ; let a running command end
                MOVE    FLP_MOUNTED, R0
                CMP     1, @R0
                RBRA    _FLP_OFF_1, !Z
                XOR     R8, R8
                RSUB    FLP_STROBE, 1
_FLP_OFF_1      XOR     R8, R8
                RSUB    FLP_CTRL_SET, 1
                MOVE    FLP_STATE, R0
                MOVE    FLP_S_OFF, @R0
                MOVE    FLP_STR_OFF, R8
                SYSCALL(puts, 1)
                SYSCALL(crlf, 1)
_FLP_OFF_RET    SYSCALL(leave, 1)
                RET

; FLP_STROBE: R8 = 0 unmount, 1 = 720 KB, 2 = 1.44 MB: tell the framework
; (VD_STROBE_IM: size, read-only while the drive reports write protect)
; and put "Internal drive" on the menu line
FLP_STROBE      SYSCALL(enter, 1)
                MOVE    R8, R7                  ; R7: what
                RSUB    FLP_STATUS, 1           ; the live write-protect line
                AND     FLP_ST_WP, R8
                MOVE    FLP_RO, R0
                MOVE    0, @R0
                CMP     0, R8
                RBRA    _FLP_STR_0, Z
                MOVE    1, @R0
_FLP_STR_0      MOVE    FLP_MOUNTED, R0
                MOVE    0, @R0
                XOR     R9, R9                  ; size low
                XOR     R10, R10                ; size high
                CMP     1, R7
                RBRA    _FLP_STR_1, !Z
                MOVE    FLP_SIZE_DD_L, R9
                MOVE    FLP_SIZE_DD_H, R10
                MOVE    1, @R0
                RBRA    _FLP_STR_2, 1
_FLP_STR_1      CMP     2, R7
                RBRA    _FLP_STR_2, !Z
                MOVE    FLP_SIZE_HD_L, R9
                MOVE    FLP_SIZE_HD_H, R10
                MOVE    1, @R0
_FLP_STR_2      MOVE    FLP_DRIVE, R8
                MOVE    FLP_RO, R11
                MOVE    @R11, R11               ; read-only while write protected
                XOR     R12, R12                ; image type 0
                RSUB    VD_STROBE_IM, 1
                CMP     0, R7
                RBRA    _FLP_STR_RET, Z         ; unmount: no name

                ; the menu "%s" of the Drive A line: string slot of vdrive
                ; FLP_DRIVE in the options heap (see _HM_SDMOUNTED3A)
                MOVE    OPTM_HEAP, R0
                MOVE    @R0, R0
                RBRA    _FLP_STR_RET, Z         ; heap not ready (no menu yet)
                MOVE    FLP_DRIVE, R8
                MOVE    SCR$OSM_O_DX, R9
                MOVE    @R9, R9
                SYSCALL(mulu, 1)
                ADD     R10, R0                 ; R0: string slot
                MOVE    FLP_STR_NAME, R8
                MOVE    R0, R9
                SYSCALL(strcpy, 1)
                MOVE    SCR$OSM_O_DX, R8        ; "%s is replaced" flag = 0
                MOVE    @R8, R8
                SUB     1, R8
                ADD     R0, R8
                MOVE    0, @R8
_FLP_STR_RET    SYSCALL(leave, 1)
                RET

; FLP_DET_APPLY: R8 = detect result word; mounts with the detected geometry
; -> Carry=1 if a disk was found (state FLP_S_READY), Carry=0 otherwise
; (the FDC is unmounted, state FLP_S_NODISK)
FLP_DET_APPLY   SYSCALL(enter, 1)
                MOVE    R8, R0                  ; R0: detect word
                MOVE    FLP_STR_DET, R8
                MOVE    R0, R9
                MOVE    R0, R1
                AND     FLP_DET_HD, R1
                RBRA    _FLP_DA_HD, !Z
                MOVE    R0, R1
                AND     FLP_DET_DD, R1
                RBRA    _FLP_DA_DD, !Z

                ; nothing readable at either rate
                SYSCALL(puts, 1)
                MOVE    R0, R8
                SYSCALL(puthex, 1)
                MOVE    FLP_STR_NONE, R8
                SYSCALL(puts, 1)
                SYSCALL(crlf, 1)
                MOVE    FLP_MOUNTED, R1
                CMP     1, @R1
                RBRA    _FLP_DA_1, !Z
                XOR     R8, R8                  ; was mounted: eject
                RSUB    FLP_STROBE, 1
_FLP_DA_1       RSUB    FLP_NOW, 1
                MOVE    FLP_CYC, R1
                MOVE    R8, @R1
                MOVE    FLP_STATE, R1
                MOVE    FLP_S_NODISK, @R1
                AND     0xFFFB, SR              ; clear Carry
                RBRA    _FLP_DA_RET, 1

_FLP_DA_HD      SYSCALL(puts, 1)
                MOVE    R0, R8
                SYSCALL(puthex, 1)
                MOVE    FLP_STR_HD, R8
                SYSCALL(puts, 1)
                SYSCALL(crlf, 1)
                MOVE    FLP_SPT, R1
                MOVE    18, @R1
                MOVE    FLP_RATE, R1
                MOVE    FLP_ARG_RATEHD, @R1
                MOVE    2, R8
                RBRA    _FLP_DA_MNT, 1

_FLP_DA_DD      SYSCALL(puts, 1)
                MOVE    R0, R8
                SYSCALL(puthex, 1)
                MOVE    FLP_STR_DD, R8
                SYSCALL(puts, 1)
                SYSCALL(crlf, 1)
                MOVE    FLP_SPT, R1
                MOVE    9, @R1
                MOVE    FLP_RATE, R1
                MOVE    0, @R1
                MOVE    1, R8

_FLP_DA_MNT     RSUB    FLP_STROBE, 1           ; (re)mount: floppy.v sees eject + insert
                MOVE    FLP_STR_RW, R8
                MOVE    FLP_RO, R1
                CMP     0, @R1
                RBRA    _FLP_DA_LOG, Z
                MOVE    FLP_STR_RO, R8
_FLP_DA_LOG     SYSCALL(puts, 1)
                SYSCALL(crlf, 1)
                MOVE    FLP_VFY_ERR, R1         ; a fresh disk: no verify failure carried over
                MOVE    0, @R1
                MOVE    FLP_CTL_EN, R8          ; the recalibrate cleared the drive latch:
                OR      FLP_CTL_CHGCLR, R8      ; clear the sticky flag too
                OR      FLP_CTL_VFYCLR, R8
                RSUB    FLP_CTRL_SET, 1
                MOVE    FLP_STATE, R1
                MOVE    FLP_S_READY, @R1
                OR      0x0004, SR              ; set Carry
_FLP_DA_RET     SYSCALL(leave, 1)
                RET

; ----------------------------------------------------------------------------
; Public: main loop
; ----------------------------------------------------------------------------

; FLP_POLL: called from HANDLE_IO on every pass of the main loop; never
; blocks (one register read in the common case); registers preserved
FLP_POLL        SYSCALL(enter, 1)
                MOVE    FLP_STATE, R0
                MOVE    @R0, R1
                CMP     FLP_S_OFF, R1
                RBRA    _FLP_POLL_RET, Z
                SUB     2, SP
                MOVE    SP, R8
                RSUB    SAVE_DEVSEL, 1

                CMP     FLP_S_NODISK, R1
                RBRA    _FLP_POLL_ND, Z
                CMP     FLP_S_PROBING, R1
                RBRA    _FLP_POLL_PR, Z
                CMP     FLP_S_DETECT, R1
                RBRA    _FLP_POLL_DT, Z

                ; READY: a disk change makes the engine re-detect and re-mount;
                ; a failed write verify is remembered for the next request
                RSUB    FLP_VFY_CHECK, 1
                RSUB    FLP_STATUS, 1
                MOVE    R8, R2
                AND     FLP_ST_CHG, R2
                RBRA    _FLP_POLL_END, Z
                MOVE    FLP_STR_CHG, R8
                SYSCALL(puts, 1)
                SYSCALL(crlf, 1)
                RSUB    FLP_START_DET, 1
                RBRA    _FLP_POLL_END, 1

                ; NODISK: probe every 2 s
_FLP_POLL_ND    RSUB    FLP_NOW, 1
                MOVE    FLP_CYC, R2
                SUB     @R2, R8
                AND     0x7FFF, R8
                CMP     FLP_PROBE_WAIT, R8      ; 2 s > elapsed?
                RBRA    _FLP_POLL_END, N        ; yes: not yet
                MOVE    FLP_CMD_PROBE, R8
                XOR     R9, R9
                XOR     R10, R10
                RSUB    FLP_CMD, 1
                MOVE    FLP_S_PROBING, @R0
                RBRA    _FLP_POLL_END, 1

                ; PROBING: done? DISK CHANGE still asserted = no disk
_FLP_POLL_PR    RSUB    FLP_STATUS, 1
                MOVE    R8, R2
                AND     FLP_ST_BUSY, R2
                RBRA    _FLP_POLL_END, !Z
                MOVE    R8, R2
                AND     FLP_ST_CHGLIVE, R2
                RBRA    _FLP_POLL_PR1, Z
                RSUB    FLP_NOW, 1              ; no disk: next probe in 2 s
                MOVE    FLP_CYC, R2
                MOVE    R8, @R2
                MOVE    FLP_S_NODISK, @R0
                RBRA    _FLP_POLL_END, 1
_FLP_POLL_PR1   RSUB    FLP_START_DET, 1        ; a disk: find out which
                RBRA    _FLP_POLL_END, 1

                ; DETECT: done? apply the result
_FLP_POLL_DT    RSUB    FLP_STATUS, 1
                MOVE    R8, R2
                AND     FLP_ST_BUSY, R2
                RBRA    _FLP_POLL_END, !Z
                MOVE    FLP_R_DET, R8
                RSUB    FLP_RD, 1
                RSUB    FLP_DET_APPLY, 1

_FLP_POLL_END   MOVE    SP, R8
                RSUB    RESTORE_DEVSEL, 1
                ADD     2, SP
_FLP_POLL_RET   SYSCALL(leave, 1)
                RET

; FLP_VFY_CHECK: the verify-failed flag of the engine -> FLP_VFY_ERR (sticky
; here until the next mount), the engine flag cleared; registers preserved
FLP_VFY_CHECK   INCRB
                MOVE    R8, R0
                MOVE    R9, R1
                MOVE    FLP_R_VFY, R8
                RSUB    FLP_RD, 1
                AND     FLP_VFY_FAIL, R8
                RBRA    _FLP_VC_RET, Z
                MOVE    FLP_VFY_ERR, R2
                MOVE    1, @R2
                MOVE    FLP_N_ERR, R2
                ADD     1, @R2
                MOVE    FLP_STR_VFY, R8
                SYSCALL(puts, 1)
                SYSCALL(crlf, 1)
                MOVE    FLP_CTRL, R2
                MOVE    @R2, R8
                OR      FLP_CTL_VFYCLR, R8
                RSUB    FLP_CTRL_SET, 1
_FLP_VC_RET     MOVE    R0, R8
                MOVE    R1, R9
                DECRB
                RET

; FLP_START_DET: clear the sticky change flag and start a DETECT
FLP_START_DET   INCRB
                MOVE    FLP_CTL_EN, R8
                OR      FLP_CTL_CHGCLR, R8
                RSUB    FLP_CTRL_SET, 1
                MOVE    FLP_CMD_DETECT, R8
                XOR     R9, R9
                XOR     R10, R10
                RSUB    FLP_CMD, 1
                MOVE    FLP_STATE, R0
                MOVE    FLP_S_DETECT, @R0
                DECRB
                RET

; ----------------------------------------------------------------------------
; Public: block requests of vdrive 0 (HANDLE_DRV_RD / HANDLE_DRV_WR hooks)
; ----------------------------------------------------------------------------

; FLP_ACK: R8 = 1 error / 0 done: set the block-error flag for
; mgmt_bridge, then strobe the vdrive acknowledge (held a few instructions
; so that the bridge synchroniser sees it high). The acknowledge of a write
; makes vdrives mark its image cache dirty; there is no image, so the flag
; is cleared again at once (no flush).
FLP_ACK         INCRB
                MOVE    FLP_CTL_EN, R0
                CMP     0, R8
                RBRA    _FLP_ACK_1, Z
                OR      FLP_CTL_BLKERR, R0
_FLP_ACK_1      MOVE    R0, R8
                RSUB    FLP_CTRL_SET, 1
                MOVE    FLP_DRIVE, R8
                MOVE    VD_ACK, R9
                MOVE    1, R10
                RSUB    VD_DRV_WRITE, 1
                MOVE    16, R1
_FLP_ACK_2      SUB     1, R1
                RBRA    _FLP_ACK_2, !Z
                MOVE    FLP_DRIVE, R8
                MOVE    VD_ACK, R9
                XOR     R10, R10
                RSUB    VD_DRV_WRITE, 1
                MOVE    FLP_DRIVE, R8
                MOVE    VD_CACHE_DIRTY, R9
                XOR     R10, R10
                RSUB    VD_DRV_WRITE, 1
                DECRB
                RET

; FLP_DRV_RD: R8 = vdrive (FLP_DRIVE): serve one 512-byte block request
FLP_DRV_RD      SYSCALL(enter, 1)
                MOVE    FLP_N_RD, R0
                ADD     1, @R0

                ; the request: byte position -> LBA, amount must be 512
                MOVE    FLP_DRIVE, R8
                MOVE    VD_BYTES_L, R9
                RSUB    VD_DRV_READ, 1
                MOVE    R8, R0
                MOVE    FLP_DRIVE, R8
                MOVE    VD_BYTES_H, R9
                RSUB    VD_DRV_READ, 1
                MOVE    R8, R1
                MOVE    FLP_DRIVE, R8
                MOVE    VD_SIZEB, R9
                RSUB    VD_DRV_READ, 1
                MOVE    R8, R2
                AND     0xFFFB, SR              ; clear C
                SHR     9, R0                   ; LBA = pos / 512
                AND     0xFFFD, SR              ; clear X
                SHL     7, R1
                OR      R1, R0                  ; R0: LBA
                MOVE    R0, R7                  ; R7: LBA for the log
                CMP     0x0200, R2
                RBRA    _FLP_RD_ERR, !Z
                MOVE    FLP_STATE, R1
                CMP     FLP_S_READY, @R1        ; only READY serves data
                RBRA    _FLP_RD_ERR, !Z
                CMP     FLP_MAX_LBA, R0         ; 2880 > LBA?
                RBRA    _FLP_RD_ERR, !N
                RSUB    FLP_VFY_CHECK, 1        ; an earlier write failed its
                MOVE    FLP_VFY_ERR, R1         ; read-back: park this request
                CMP     1, @R1
                RBRA    _FLP_RD_PARK, Z

                ; a disk change since the last look: detect again (blocking,
                ; the request waits); the FDC computed this LBA with the old
                ; geometry, so this request is still converted with it
                RSUB    FLP_STATUS, 1
                MOVE    R8, R1
                AND     FLP_ST_CHG, R1
                RBRA    _FLP_RD_CHS, Z
                MOVE    FLP_STR_CHG, R8
                SYSCALL(puts, 1)
                SYSCALL(crlf, 1)
                MOVE    FLP_SPT, R1
                MOVE    @R1, R6                 ; R6: the SPT of this request
                RSUB    FLP_START_DET, 1
                RSUB    FLP_WAIT, 1
                MOVE    FLP_R_DET, R8
                RSUB    FLP_RD, 1
                RSUB    FLP_DET_APPLY, 1
                RBRA    _FLP_RD_ERR, !C         ; the disk is gone
                RBRA    _FLP_RD_CHS1, 1

_FLP_RD_CHS     MOVE    FLP_SPT, R1
                MOVE    @R1, R6
_FLP_RD_CHS1    MOVE    R0, R8
                MOVE    R6, R9
                RSUB    FLP_LBA2CHS, 1          ; R8 = C, R9 = H, R10 = R
                MOVE    R8, R3                  ; R3: arg0 = C | H | rate
                CMP     0, R9
                RBRA    _FLP_RD_1, Z
                OR      FLP_ARG_HEAD, R3
_FLP_RD_1       MOVE    FLP_RATE, R1
                OR      @R1, R3
                MOVE    R10, R4                 ; R4: arg1 = R | SPT << 8
                MOVE    R6, R1
                AND     0xFFFD, SR
                SHL     8, R1
                OR      R1, R4
                XOR     R5, R5                  ; R5: attempt

                ; READ_TRACK (a cache hit returns at once), then is R valid?
_FLP_RD_TRY     MOVE    FLP_CMD_READ, R8
                MOVE    R3, R9
                MOVE    R4, R10
                RSUB    FLP_CMD, 1
                RSUB    FLP_WAIT, 1
                MOVE    R8, R2                  ; R2: status of the attempt
                MOVE    R4, R1
                AND     0x001F, R1              ; R1: R
                CMP     17, R1
                RBRA    _FLP_RD_2, N            ; 17 > R: word 2, bit R-1
                MOVE    FLP_R_CACHE, R8         ; R = 17, 18: word 4, bit R-17
                RSUB    FLP_RD, 1
                SUB     17, R1
                RBRA    _FLP_RD_3, 1
_FLP_RD_2       MOVE    FLP_R_VALID, R8
                RSUB    FLP_RD, 1
                SUB     1, R1
_FLP_RD_3       MOVE    1, R9
                AND     0xFFFD, SR
                SHL     R1, R9
                AND     R9, R8
                RBRA    _FLP_RD_COPY, !Z
                ADD     1, R5
                OR      FLP_ARG_FORCE, R3       ; next attempt recalibrates
                CMP     FLP_ATTEMPTS, R5
                RBRA    _FLP_RD_TRY, !Z
                RBRA    _FLP_RD_ERR2, 1

                ; the sector is in the cache: hardware copy into the vdrive
                ; buffer, then acknowledge
_FLP_RD_COPY    MOVE    FLP_CMD_COPY, R8
                XOR     R9, R9
                MOVE    R4, R10
                RSUB    FLP_CMD, 1
                RSUB    FLP_WAIT, 1
                XOR     R8, R8
                RSUB    FLP_ACK, 1
                RBRA    _FLP_RD_RET, 1

_FLP_RD_PARK    MOVE    FLP_STR_PARK, R8
                MOVE    R7, R9
                RSUB    FLP_LOG, 1
                MOVE    1, R8
                RSUB    FLP_ACK, 1
                RBRA    _FLP_RD_RET, 1

_FLP_RD_ERR     XOR     R2, R2
_FLP_RD_ERR2    MOVE    FLP_N_ERR, R1
                ADD     1, @R1
                MOVE    FLP_LAST_ERR, R1
                MOVE    R2, @R1
                MOVE    FLP_STR_RDERR, R8
                SYSCALL(puts, 1)
                MOVE    R7, R8
                SYSCALL(puthex, 1)
                MOVE    FLP_STR_STAT, R8
                SYSCALL(puts, 1)
                MOVE    R2, R8
                SYSCALL(puthex, 1)
                SYSCALL(crlf, 1)
                MOVE    1, R8
                RSUB    FLP_ACK, 1
_FLP_RD_RET     SYSCALL(leave, 1)
                RET

; FLP_DRV_WR: R8 = vdrive (FLP_DRIVE): write one 512-byte block that the
; bridge has put into the vdrive block buffer
FLP_DRV_WR      SYSCALL(enter, 1)
                MOVE    FLP_N_WR, R0
                ADD     1, @R0

                ; the request: byte position -> LBA, amount must be 512
                MOVE    FLP_DRIVE, R8
                MOVE    VD_BYTES_L, R9
                RSUB    VD_DRV_READ, 1
                MOVE    R8, R0
                MOVE    FLP_DRIVE, R8
                MOVE    VD_BYTES_H, R9
                RSUB    VD_DRV_READ, 1
                MOVE    R8, R1
                MOVE    FLP_DRIVE, R8
                MOVE    VD_SIZEB, R9
                RSUB    VD_DRV_READ, 1
                MOVE    R8, R2
                AND     0xFFFB, SR              ; clear C
                SHR     9, R0                   ; LBA = pos / 512
                AND     0xFFFD, SR              ; clear X
                SHL     7, R1
                OR      R1, R0                  ; R0: LBA
                MOVE    R0, R7                  ; R7: LBA for the log
                XOR     R2, R2                  ; R2: status for the log
                CMP     0x0200, R2
                RBRA    _FLP_WR_ERR, !Z
                MOVE    FLP_STATE, R1
                CMP     FLP_S_READY, @R1        ; only READY serves requests
                RBRA    _FLP_WR_ERR, !Z
                CMP     FLP_MAX_LBA, R0         ; 2880 > LBA?
                RBRA    _FLP_WR_ERR, !N
                MOVE    FLP_RO, R1
                CMP     0, @R1                  ; mounted read-only: floppy.v
                RBRA    _FLP_WR_ERR, !Z         ; should never have sent this
                RSUB    FLP_VFY_CHECK, 1        ; an earlier write failed its
                MOVE    FLP_VFY_ERR, R1         ; read-back: park this request
                CMP     1, @R1
                RBRA    _FLP_WR_PARK, Z

                ; a disk change since the last look: the data DOS wrote was
                ; meant for the disk that is gone; re-detect and refuse
                RSUB    FLP_STATUS, 1
                MOVE    R8, R1
                AND     FLP_ST_CHG, R1
                RBRA    _FLP_WR_CHS, Z
                MOVE    FLP_STR_CHG, R8
                SYSCALL(puts, 1)
                SYSCALL(crlf, 1)
                RSUB    FLP_START_DET, 1
                RSUB    FLP_WAIT, 1
                MOVE    FLP_R_DET, R8
                RSUB    FLP_RD, 1
                RSUB    FLP_DET_APPLY, 1
                RBRA    _FLP_WR_ERR, 1

_FLP_WR_CHS     MOVE    FLP_SPT, R1
                MOVE    @R1, R6                 ; R6: the SPT of this request
                MOVE    R0, R8
                MOVE    R6, R9
                RSUB    FLP_LBA2CHS, 1          ; R8 = C, R9 = H, R10 = R
                MOVE    R8, R3                  ; R3: arg0 = C | H | rate
                CMP     0, R9
                RBRA    _FLP_WR_1, Z
                OR      FLP_ARG_HEAD, R3
_FLP_WR_1       MOVE    FLP_RATE, R1
                OR      @R1, R3
                MOVE    R10, R4                 ; R4: arg1 = R | SPT << 8
                MOVE    R6, R1
                AND     0xFFFD, SR
                SHL     8, R1
                OR      R1, R4
                XOR     R5, R5                  ; R5: attempt

                ; WRITE_SECTOR: the engine reads the block buffer, seeks,
                ; finds the ID header and writes the data field
_FLP_WR_TRY     MOVE    FLP_CMD_WRITE, R8
                MOVE    R3, R9
                MOVE    R4, R10
                RSUB    FLP_CMD, 1
                RSUB    FLP_WAIT, 1
                MOVE    R8, R2                  ; R2: status of the attempt
                AND     FLP_ST_ERR, R8
                RBRA    _FLP_WR_OK, Z
                CMP     7, R8                   ; write protected: no retry
                RBRA    _FLP_WR_ERR2, Z
                ADD     1, R5
                OR      FLP_ARG_FORCE, R3       ; next attempt recalibrates
                CMP     FLP_ATTEMPTS, R5
                RBRA    _FLP_WR_TRY, !Z
                RBRA    _FLP_WR_ERR2, 1

                ; written; the read-back runs in the engine while DOS goes on
_FLP_WR_OK      XOR     R8, R8
                RSUB    FLP_ACK, 1
                RBRA    _FLP_WR_RET, 1

_FLP_WR_PARK    MOVE    FLP_STR_PARK, R8
                MOVE    R7, R9
                RSUB    FLP_LOG, 1
                MOVE    1, R8
                RSUB    FLP_ACK, 1
                RBRA    _FLP_WR_RET, 1

_FLP_WR_ERR     XOR     R2, R2
_FLP_WR_ERR2    MOVE    FLP_N_ERR, R1
                ADD     1, @R1
                MOVE    FLP_LAST_ERR, R1
                MOVE    R2, @R1
                MOVE    FLP_STR_WR, R8
                SYSCALL(puts, 1)
                MOVE    R7, R8
                SYSCALL(puthex, 1)
                MOVE    FLP_STR_STAT, R8
                SYSCALL(puts, 1)
                MOVE    R2, R8
                SYSCALL(puthex, 1)
                SYSCALL(crlf, 1)
                MOVE    1, R8
                RSUB    FLP_ACK, 1
_FLP_WR_RET     SYSCALL(leave, 1)
                RET
