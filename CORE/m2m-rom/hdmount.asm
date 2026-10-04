; ****************************************************************************
; PCXT-EGA on MiSTer2MEGA65: remember the hard disk image
;
; The framework forgets every mount when the core is restarted, so the hard
; disk had to be mounted by hand on each start. This file remembers the last
; image mounted as the hard disk (virtual drive HDM_DRIVE) and mounts it again
; at start-up, before the PC is released from reset, so the machine boots
; straight from it. Floppy drives are deliberately not remembered: an XT
; boots from A: first, and a forgotten boot floppy would win over the hard
; disk on every start.
;
; Where it is kept: /m2m/hdmount on the SD card, the full path of the image as
; a zero-terminated string ("/pcxt/freedos.vhd"), first byte 0 = nothing
; remembered. The FAT32 library of the firmware can rewrite a file but not
; create or grow one, so the file has to exist already (the release package
; ships it, HDM_PATH_MAX bytes or more of zeros). Without it everything here
; is inert and the core behaves as it always did. Like /m2m/m2mcfg it is read
; and written through CONFIG_DEVH, the device handle of the SD card that was
; active at start-up, and it is dropped for the session as soon as the active
; card changes, so that nothing is ever written to another card.
;
; Hooks (each one line, marked "PCXT-EGA: hdmount.asm"):
;   m2m-rom.asm  PREP_START       HDM_INIT       read the file, mount the image
;   shell.asm    HANDLE_IO        HDM_POLL       write the file when it is due
;   shell.asm    HANDLE_MOUNTING  HDM_MOUNTED    an image was mounted
;                                 HDM_UNMOUNTED  the drive was switched off
;   selectfile.asm (twice)        HDM_CD         the browser changes directory
;   options.asm  HELP_MENU        HDM_MENU_OPEN  name of an auto-mounted image
;
; The file browser only ever hands a bare file name to HANDLE_MOUNTING, the
; directory lives in the state of HANDLE_DEV. HDM_CD therefore mirrors every
; directory change of the browser in HDM_CWD ("" = root, "/pcxt", ...), and
; HDM_MOUNTED joins the two. A path that does not fit in HDM_PATH_MAX is
; simply not remembered.
;
; HDM_BENCH: tools/vdrive-latency-bench/hdmount_bench.asm runs this file in
; the QNICE emulator against the real FAT32 library and stubs of the framework
; calls; it defines HDM_BENCH and supplies HDM_CSR itself.
; ****************************************************************************

HDM_DRIVE       .EQU    2                       ; virtual drive of the hard disk
HDM_PATH_MAX    .EQU    80                      ; longest path incl. terminator

; The control and status register. A preprocessor name, not an .EQU: the
; assembler does not resolve an .EQU whose value is another symbol (it came
; out as 0xFFFF, and the first hardware run read the SD card bit from there).
#ifndef HDM_BENCH
#define HDM_CSR M2M$CSR
#endif

HDM_FNAME       .ASCII_W "/m2m/hdmount"
HDM_STR_OFF     .ASCII_W "HDM: no usable /m2m/hdmount, the hard disk is not remembered\n"
HDM_STR_NONE    .ASCII_W "HDM: no hard disk remembered\n"
HDM_STR_MNT     .ASCII_W "HDM: mounting "
HDM_STR_GONE    .ASCII_W "HDM: not found: "
HDM_STR_SAVED   .ASCII_W "HDM: remembered: "
HDM_STR_CLR     .ASCII_W "HDM: forgotten\n"
HDM_STR_ERR     .ASCII_W "HDM: write error, remembering is off\n"
HDM_STR_CARD    .ASCII_W "HDM: SD card changed, remembering is off\n"

; ----------------------------------------------------------------------------
; HDM_INIT: called from PREP_START, i.e. after the settings were loaded and
; before the core is started. Opens /m2m/hdmount, reads the remembered path
; and mounts that image as the hard disk. Whatever goes wrong is logged and
; otherwise ignored: the drive just stays empty.
;
; After a successful mount the core is put (back) into reset: START_CONNECT
; releases it a moment later and the BIOS then finds the disk at POST. The
; mount strobe itself is not affected by the reset (mega65.vhd ties the
; vdrives reset to 0, and mgmt_bridge is only reset by a lost clock).
; Registers preserved.
; ----------------------------------------------------------------------------
HDM_INIT        SYSCALL(enter, 1)
                MOVE    HDM_PATH, R0
                MOVE    0, @R0
                MOVE    HDM_CWD, R0
                MOVE    0, @R0
                MOVE    HDM_CWD_OK, R0
                MOVE    0, @R0
                MOVE    HDM_PENDING, R0
                MOVE    0, @R0
                MOVE    HDM_NAMED, R0
                MOVE    1, @R0                  ; no name owed to the menu
                MOVE    HDM_ON, R0
                MOVE    0, @R0

                ; the SD card of the settings must have been mounted
                MOVE    CONFIG_DEVH, R8
                CMP     0, @R8
                RBRA    _HDM_I_OFF, Z

                MOVE    HDM_FILE, R9
                MOVE    HDM_FNAME, R10
                XOR     R11, R11
                SYSCALL(f32_fopen, 1)
                CMP     0, R10
                RBRA    _HDM_I_OFF, !Z

                ; the file must be able to hold the longest path
                MOVE    HDM_FILE, R0
                ADD     FAT32$FDH_SIZE_HI, R0
                CMP     0, @R0
                RBRA    _HDM_I_READ, !Z
                MOVE    HDM_FILE, R0
                ADD     FAT32$FDH_SIZE_LO, R0
                MOVE    @R0, R0
                CMP     HDM_PATH_MAX, R0        ; HDM_PATH_MAX > size?
                RBRA    _HDM_I_OFF, N

                ; read the path: stops at the terminator; a read error means
                ; the file cannot be trusted for writing either
_HDM_I_READ     MOVE    HDM_PATH, R1
                XOR     R2, R2
_HDM_I_RD       MOVE    HDM_FILE, R8
                SYSCALL(f32_fread, 1)
                CMP     0, R10
                RBRA    _HDM_I_OFF, !Z
                AND     0x00FF, R9
                MOVE    R9, @R1++
                RBRA    _HDM_I_GOT, Z           ; terminator stored
                ADD     1, R2
                CMP     HDM_PATH_MAX, R2
                RBRA    _HDM_I_RD, !Z
                MOVE    HDM_PATH, R1            ; no terminator: not a path
                MOVE    0, @R1

_HDM_I_GOT      MOVE    HDM_ON, R0
                MOVE    1, @R0                  ; from here on we remember

                ; a path starts with "/": anything else (zeros, 0xFF of an
                ; erased file, garbage) is "nothing remembered"
                MOVE    HDM_PATH, R0
                CMP     0x002F, @R0
                RBRA    _HDM_I_MNT, Z
                MOVE    0, @R0
                MOVE    HDM_STR_NONE, R8
                SYSCALL(puts, 1)
                RBRA    _HDM_I_RET, 1

                ; mount it. Only an SD-direct drive: a buffered one would
                ; make LOAD_IMAGE draw a progress bar on a screen that is not
                ; there at this point.
_HDM_I_MNT      MOVE    HDM_DRIVE, R8
                RSUB    VD_IS_SDDIRECT, 1
                RBRA    _HDM_I_RET, !C

                MOVE    HDM_STR_MNT, R8
                SYSCALL(puts, 1)
                MOVE    HDM_PATH, R8
                SYSCALL(puts, 1)
                SYSCALL(crlf, 1)

                MOVE    HANDLE_DEV, R8          ; the browser device handle:
                CMP     0, @R8                  ; mounted on first use, which
                RBRA    _HDM_I_OPEN, !Z         ; is now
                MOVE    1, R9                   ; partition #1, as everywhere
                SYSCALL(f32_mnt_sd, 1)
                CMP     0, R9
                RBRA    _HDM_I_OPEN, Z
                MOVE    HANDLE_DEV, R8          ; as HANDLE_MOUNTING does
                MOVE    0, @R8
                RBRA    _HDM_I_GONE, 1

                ; LOAD_IMAGE goes fatal if the file cannot be opened, so try
                ; it first. The handle is the one of the drive: LOAD_IMAGE
                ; opens the file again.
_HDM_I_OPEN     MOVE    HANDLE_DEV, R8
                MOVE    HNDL_VD_FILES, R9
                ADD     HDM_DRIVE, R9
                MOVE    @R9, R9
                MOVE    HDM_PATH, R10
                XOR     R11, R11
                SYSCALL(f32_fopen, 1)
                CMP     0, R10
                RBRA    _HDM_I_GONE, !Z

                MOVE    HDM_DRIVE, R8
                MOVE    HDM_PATH, R9
                XOR     R10, R10                ; mode: virtual drive
                RSUB    LOAD_IMAGE, 1
                CMP     0, R8
                RBRA    _HDM_I_GONE, !Z

                ; tell the core, exactly as HANDLE_MOUNTING does
                MOVE    HNDL_VD_FILES, R9
                ADD     HDM_DRIVE, R9
                MOVE    @R9, R9
                MOVE    R9, R10
                ADD     FAT32$FDH_SIZE_LO, R9
                MOVE    @R9, R9                 ; R9: file size, low word
                ADD     FAT32$FDH_SIZE_HI, R10
                MOVE    @R10, R10               ; R10: file size, high word
                MOVE    HDM_DRIVE, R8
                XOR     R11, R11                ; read/write
                XOR     R12, R12                ; image type 0
                RSUB    VD_STROBE_IM, 1

                MOVE    HDM_NAMED, R0           ; the menu line needs the name
                MOVE    0, @R0

                MOVE    HDM_CSR, R0             ; POST with the disk present
                OR      M2M$CSR_RESET, @R0
                RBRA    _HDM_I_RET, 1

                ; the image is not there (card swapped, file deleted): keep
                ; the path, it may be back next time
_HDM_I_GONE     MOVE    HDM_STR_GONE, R8
                SYSCALL(puts, 1)
                MOVE    HDM_PATH, R8
                SYSCALL(puts, 1)
                SYSCALL(crlf, 1)
                RBRA    _HDM_I_RET, 1

_HDM_I_OFF      MOVE    HDM_PATH, R0
                MOVE    0, @R0
                MOVE    HDM_STR_OFF, R8
                SYSCALL(puts, 1)

_HDM_I_RET      SYSCALL(leave, 1)
                RET

; ----------------------------------------------------------------------------
; HDM_CD: the file browser is about to change HANDLE_DEV to the directory in
; R9 (the argument of DIRBROWSE_READ): absolute ("/pcxt", "/"), a
; subdirectory name, or "..". Mirrors it in HDM_CWD. Registers preserved.
; ----------------------------------------------------------------------------
HDM_CD          SYSCALL(enter, 1)
                MOVE    R9, R0                  ; R0: the new directory
                CMP     0x002F, @R0             ; "/..." = absolute
                RBRA    _HDM_CD_REL, !Z

                MOVE    HDM_CWD_OK, R1          ; unknown until it is stored
                MOVE    0, @R1
                MOVE    R0, R8
                SYSCALL(strlen, 1)
                ADD     1, R9
                CMP     R9, HDM_PATH_MAX        ; does not fit?
                RBRA    _HDM_CD_RET, N
                MOVE    R0, R8
                MOVE    HDM_CWD, R9
                SYSCALL(strcpy, 1)
                MOVE    HDM_CWD, R8             ; no trailing "/": root = ""
                SYSCALL(strlen, 1)
_HDM_CD_TS      CMP     0, R9
                RBRA    _HDM_CD_OK, Z
                MOVE    HDM_CWD, R2
                ADD     R9, R2
                SUB     1, R2
                CMP     0x002F, @R2
                RBRA    _HDM_CD_OK, !Z
                MOVE    0, @R2
                SUB     1, R9
                RBRA    _HDM_CD_TS, 1
_HDM_CD_OK      MOVE    HDM_CWD_OK, R1
                MOVE    1, @R1
                RBRA    _HDM_CD_RET, 1

_HDM_CD_REL     MOVE    HDM_CWD_OK, R1          ; relative to an unknown
                CMP     1, @R1                  ; directory stays unknown
                RBRA    _HDM_CD_RET, !Z

                CMP     0x002E, @R0             ; "." or ".."?
                RBRA    _HDM_CD_APP, !Z
                MOVE    R0, R2
                ADD     1, R2
                CMP     0, @R2
                RBRA    _HDM_CD_RET, Z          ; ".": nothing changes
                CMP     0x002E, @R2
                RBRA    _HDM_CD_APP, !Z
                ADD     1, R2
                CMP     0, @R2
                RBRA    _HDM_CD_APP, !Z

                ; "..": cut at the last "/"
                MOVE    HDM_CWD, R2
                XOR     R3, R3
_HDM_CD_UP1     CMP     0, @R2
                RBRA    _HDM_CD_UP3, Z
                CMP     0x002F, @R2
                RBRA    _HDM_CD_UP2, !Z
                MOVE    R2, R3
_HDM_CD_UP2     ADD     1, R2
                RBRA    _HDM_CD_UP1, 1
_HDM_CD_UP3     CMP     0, R3
                RBRA    _HDM_CD_RET, Z          ; already the root
                MOVE    0, @R3
                RBRA    _HDM_CD_RET, 1

                ; a subdirectory: append "/name"
_HDM_CD_APP     MOVE    HDM_CWD, R8
                SYSCALL(strlen, 1)
                MOVE    R9, R3
                MOVE    R0, R8
                SYSCALL(strlen, 1)
                ADD     R9, R3
                ADD     2, R3                   ; the "/" and the terminator
                CMP     R3, HDM_PATH_MAX        ; does not fit?
                RBRA    _HDM_CD_BAD, N
                MOVE    HDM_CWD, R8
                SYSCALL(strlen, 1)
                ADD     R9, R8
                MOVE    0x002F, @R8++
                MOVE    R8, R9
                MOVE    R0, R8
                SYSCALL(strcpy, 1)
                RBRA    _HDM_CD_RET, 1
_HDM_CD_BAD     MOVE    0, @R1                  ; until the next absolute path

_HDM_CD_RET     SYSCALL(leave, 1)
                RET

; ----------------------------------------------------------------------------
; HDM_MOUNTED: HANDLE_MOUNTING has mounted the file named R9 (a bare name in
; the current directory of the browser) in drive R8. For the hard disk:
; remember directory + "/" + name, or nothing if that is unknown or too long.
; Registers preserved.
; ----------------------------------------------------------------------------
HDM_MOUNTED     SYSCALL(enter, 1)
                CMP     HDM_DRIVE, R8
                RBRA    _HDM_M_RET, !Z
                MOVE    R9, R2                  ; R2: file name

                MOVE    HDM_PATH, R0
                MOVE    0, @R0
                MOVE    HDM_CWD_OK, R1
                CMP     1, @R1
                RBRA    _HDM_M_SET, !Z

                MOVE    HDM_CWD, R8
                SYSCALL(strlen, 1)
                MOVE    R9, R3
                MOVE    R2, R8
                SYSCALL(strlen, 1)
                ADD     R9, R3
                ADD     2, R3                   ; the "/" and the terminator
                CMP     R3, HDM_PATH_MAX        ; does not fit?
                RBRA    _HDM_M_SET, N

                MOVE    HDM_CWD, R8
                MOVE    HDM_PATH, R9
                SYSCALL(strcpy, 1)
                MOVE    HDM_PATH, R8
                SYSCALL(strlen, 1)
                ADD     R9, R8
                MOVE    0x002F, @R8++
                MOVE    R8, R9
                MOVE    R2, R8
                SYSCALL(strcpy, 1)

_HDM_M_SET      MOVE    HDM_NAMED, R0           ; HANDLE_MOUNTING wrote the
                MOVE    1, @R0                  ; menu name itself
                MOVE    HDM_PENDING, R0
                MOVE    1, @R0
_HDM_M_RET      SYSCALL(leave, 1)
                RET

; ----------------------------------------------------------------------------
; HDM_UNMOUNTED: drive R8 was switched off in the menu. For the hard disk:
; forget the image. Registers preserved.
; ----------------------------------------------------------------------------
HDM_UNMOUNTED   INCRB
                CMP     HDM_DRIVE, R8
                RBRA    _HDM_U_RET, !Z
                MOVE    HDM_PATH, R0
                MOVE    0, @R0
                MOVE    HDM_NAMED, R0
                MOVE    1, @R0
                MOVE    HDM_PENDING, R0
                MOVE    1, @R0
_HDM_U_RET      DECRB
                RET

; ----------------------------------------------------------------------------
; HDM_POLL: called from HANDLE_IO on every pass; writes the file when a change
; is pending. Registers preserved.
; ----------------------------------------------------------------------------
HDM_POLL        INCRB
                MOVE    HDM_PENDING, R0
                CMP     0, @R0
                RSUB    HDM_SAVE, !Z
                DECRB
                RET

; ----------------------------------------------------------------------------
; HDM_SAVE: write HDM_PATH (with its terminator) to the start of the file.
; The same rules as ROSM_SAVE of the framework for /m2m/m2mcfg:
;  * never on another SD card than the one the file was opened on;
;  * not while the write cache of any drive is dirty, because then the single
;    512-byte hardware buffer of the SD controller belongs to HANDLE_DEV.
;    HDM_PENDING stays set and the next HDM_POLL tries again;
;  * seek first: the seek re-reads the sector into that buffer.
; Unlike ROSM_SAVE an error is not fatal, remembering is just switched off.
; Afterwards both device handles are told that the hardware buffer is not
; theirs any more (SDB_ORPHAN), as after every fast block access.
; Registers preserved.
; ----------------------------------------------------------------------------
HDM_SAVE        SYSCALL(enter, 1)
                MOVE    HDM_ON, R0
                CMP     0, @R0
                RBRA    _HDM_S_DONE, Z          ; inert: drop the request

                MOVE    HDM_CSR, R8             ; still the card of start-up?
                MOVE    @R8, R8
                AND     M2M$CSR_SD_ACTIVE, R8
                MOVE    INITIAL_SD, R9
                CMP     R8, @R9
                RBRA    _HDM_S_DIRTY, Z
                MOVE    HDM_STR_CARD, R8
                RBRA    _HDM_S_OFF, 1

_HDM_S_DIRTY    RSUB    VD_ACTIVE, 1            ; R8: amount of drives
                RBRA    _HDM_S_WRITE, !C
                MOVE    R8, R0
                XOR     R1, R1
_HDM_S_DTY1     MOVE    R1, R8
                MOVE    VD_CACHE_DIRTY, R9
                RSUB    VD_DRV_READ, 1
                CMP     0, R8
                RBRA    _HDM_S_RET, !Z          ; dirty: later
                ADD     1, R1
                CMP     R0, R1
                RBRA    _HDM_S_DTY1, !Z

_HDM_S_WRITE    MOVE    HDM_FILE, R8
                XOR     R9, R9
                XOR     R10, R10
                SYSCALL(f32_fseek, 1)
                CMP     0, R9
                RBRA    _HDM_S_ERR, !Z

                MOVE    HDM_PATH, R1
_HDM_S_WR       MOVE    HDM_FILE, R8
                MOVE    @R1, R9
                SYSCALL(f32_fwrite, 1)
                CMP     0, R9
                RBRA    _HDM_S_ERR, !Z
                CMP     0, @R1++                ; was that the terminator?
                RBRA    _HDM_S_WR, !Z

                MOVE    HDM_FILE, R8
                SYSCALL(f32_fflush, 1)
                CMP     0, R9
                RBRA    _HDM_S_ERR, !Z
                RSUB    SDB_ORPHAN, 1

                MOVE    HDM_PATH, R0
                CMP     0, @R0
                RBRA    _HDM_S_LOG, !Z
                MOVE    HDM_STR_CLR, R8
                SYSCALL(puts, 1)
                RBRA    _HDM_S_DONE, 1
_HDM_S_LOG      MOVE    HDM_STR_SAVED, R8
                SYSCALL(puts, 1)
                MOVE    HDM_PATH, R8
                SYSCALL(puts, 1)
                SYSCALL(crlf, 1)
                RBRA    _HDM_S_DONE, 1

_HDM_S_ERR      RSUB    SDB_ORPHAN, 1
                MOVE    HDM_STR_ERR, R8
_HDM_S_OFF      SYSCALL(puts, 1)
                MOVE    HDM_ON, R0
                MOVE    0, @R0

_HDM_S_DONE     MOVE    HDM_PENDING, R0
                MOVE    0, @R0
_HDM_S_RET      SYSCALL(leave, 1)
                RET

; ----------------------------------------------------------------------------
; HDM_MENU_OPEN: called from HELP_MENU when the options heap is in place and
; before the menu is drawn. After an auto-mount the "%s" slot of the hard disk
; line still has to get the file name (HANDLE_MOUNTING does that for a manual
; mount, _HM_SDMOUNTED3A): the part of HDM_PATH behind the last "/", cut to
; the width of the menu with one extra character so that the framework draws
; its ellipsis. The "mounted" marker of the line follows by itself: the menu
; loop sees the mount status differ from what it remembered (_OPTM_GK_MNT).
; Registers preserved.
; ----------------------------------------------------------------------------
HDM_MENU_OPEN   SYSCALL(enter, 1)
                MOVE    HDM_NAMED, R0
                CMP     0, @R0
                RBRA    _HDM_N_RET, !Z
                MOVE    OPTM_HEAP, R0
                MOVE    @R0, R0
                RBRA    _HDM_N_RET, Z           ; no heap (cannot happen here)

                MOVE    HDM_DRIVE, R8
                MOVE    SCR$OSM_O_DX, R9
                MOVE    @R9, R9
                SYSCALL(mulu, 1)
                ADD     R10, R0                 ; R0: string slot of the drive
                MOVE    R9, R1
                SUB     2, R1                   ; R1: longest name that fits

                MOVE    HDM_PATH, R2            ; R2: name = behind last "/"
                MOVE    R2, R3
_HDM_N_1        CMP     0, @R3
                RBRA    _HDM_N_2, Z
                CMP     0x002F, @R3++
                RBRA    _HDM_N_1, !Z
                MOVE    R3, R2
                RBRA    _HDM_N_1, 1

_HDM_N_2        MOVE    R2, R8
                SYSCALL(strlen, 1)
                CMP     R9, R1                  ; longer than the line?
                RBRA    _HDM_N_3, N
                MOVE    R2, R8
                MOVE    R0, R9
                SYSCALL(strcpy, 1)
                RBRA    _HDM_N_4, 1
_HDM_N_3        MOVE    R2, R8
                MOVE    R0, R9
                MOVE    R1, R10
                ADD     1, R10
                SYSCALL(memcpy, 1)
                ADD     R10, R9
                MOVE    0, @R9

_HDM_N_4        MOVE    SCR$OSM_O_DX, R8        ; "%s is replaced" flag = 0
                MOVE    @R8, R8
                SUB     1, R8
                ADD     R0, R8
                MOVE    0, @R8
                MOVE    HDM_NAMED, R0
                MOVE    1, @R0
_HDM_N_RET      SYSCALL(leave, 1)
                RET
