; ****************************************************************************
; YOUR-PROJECT-NAME (GITHUB-REPO-SHORTNAME) QNICE ROM
;
; Main program that is used to build m2m-rom.rom by make-rom.sh.
; The ROM is loaded by TODO-ADD-NAME-OF-VHDL-FILE-HERE.
;
; The execution starts at the label START_FIRMWARE.
;
; done by YOURNAME in YEAR and licensed under GPL v3
; ****************************************************************************

; If the define RELEASE is defined, then the ROM will be a self-contained and
; self-starting ROM that includes the Monitor (QNICE "operating system") and
; jumps to START_FIRMWARE. In this case it is assumed, that the firmware is
; located in ROM and the variables are located in RAM.
;
; If RELEASE is not defined, then it is assumed that we are in the develop and
; debug mode so that the firmware runs in RAM and can be changed/loaded using
; the standard QNICE Monitor mechanisms such as "M/L" or QTransfer.

#define RELEASE

; ----------------------------------------------------------------------------
; Firmware: M2M system
; ----------------------------------------------------------------------------

; main.asm is the mandatory, so always include it
; It jumps to START_FIRMWARE (see below) after the QNICE "operating system"
; called "Monitor" has been included and initialized
#include "../../M2M/rom/main.asm"

; Only include the Shell, if you want to use the pre-build core automation
; and user experience. If you build your own, then remove this include and
; also remove the include "shell_vars.asm" in the variables section below.
#include "../../M2M/rom/shell.asm"

; ----------------------------------------------------------------------------
; Firmware: Main Code
; ----------------------------------------------------------------------------

                ; Run the Shell: This is where you could put your own system
                ; instead of the shell
START_FIRMWARE  RBRA    START_SHELL, 1

; ----------------------------------------------------------------------------
; Core specific callback functions: Submenus
; ----------------------------------------------------------------------------

; SUBMENU_SUMMARY callback function:
;
; Called when displaying the main menu for every %s that is found in the
; "headline" / starting point of any submenu in config.vhd: You are able to
; change the standard semantics when it comes to summarizing the status of the
; very submenu that is meant by the "headline" / starting point.
;
; Input:
;   R8: pointer to the string that includes the "%s"
;   R9: pointer to the menu item within the M2M$CFG_OPTM_GROUPS structure
;  R10: end-of-menu-marker: if R9 == R10: we reached end of the menu structure
; Output:
;   R8: 0, if no custom SUBMENU_SUMMARY, else:
;       string pointer to completely new headline (do not modify/re-use R8)
;   R9, R10: unchanged

SUBMENU_SUMMARY XOR     R8, R8                  ; R8 = 0 = no custom string
                RET

; ----------------------------------------------------------------------------
; Core specific callback functions: File browsing and disk image mounting
; ----------------------------------------------------------------------------

; FILTER_FILES callback function:
;
; Called by the file- and directory browser. Used to make sure that the 
; browser is only showing valid files and directories.
;
; Input:
;   R8: Name of the file in capital letters
;   R9: 0=file, 1=directory
;  R10: @TODO: Future release: Context (see CTX_* in sysdef.asm)
; Output:
;   R8: 0=do not filter file, i.e. show file
FILTER_FILES    XOR     R8, R8                  ; R8 = 0 = do not filter file
                RET

; PREP_LOAD_IMAGE callback function:
;
; Some images need to be parsed, for example to extract configuration data or
; to move the file read pointer to the start position of the actual data.
; Sanity checks ("is this a valid file") can also be implemented here.
; Last but not least: The mount system supports the concept of a 2-bit
; "image type". In case this is used at the core of your choice, make sure
; you return the correct image type.
;
; Input:
;   R8: File handle: You are allowed to modify the read pointer of the handle
;   R9: @TODO: Future release: Context (see CTX_* in sysdef.asm)
; Output:
;   R8: 0=OK, error code otherwise
;   R9: image type if R8=0, otherwise 0 or optional ptr to  error msg string
PREP_LOAD_IMAGE XOR     R8, R8                  ; no errors
                XOR     R9, R9                  ; image type hardcoded to 0
                RET

; ----------------------------------------------------------------------------
; Core specific callback functions: Custom tasks
; ----------------------------------------------------------------------------

; PREP_START callback function:
;
; Called right before the core is being started. At this point, the core
; is ready to run, settings are loaded (if the core uses settings) and the
; core is still held in reset (if RESET_KEEP is on). So at this point in time,
; you can execute tasks that change the run-state of the core.
;
; Input: None
; Output:
;   R8: 0=OK, else pointer to string with error message
;   R9: 0=OK, else error code
PREP_START      INCRB
                RSUB    DBG_CORE_STATUS, 1
                RSUB    ETH_SET_MAC, 1          ; station address for the NE1000
                XOR     R8, R8
                XOR     R9, R9
                DECRB
                RET

; OSM_SEL_POST callback function:
;
; Called each time the user selects something in the on-screen-menu (OSM),
; and while the OSM is still visible. This means, that this callback function
; is called on each press of one of the valid selection keys with the
; exception that pressing a selection key while hovering over a submenu entry
; or exit point does not call this function. All the functionality and
; semantics associated with a certain menu item is already handled by the
; framework when OSM_SELECTED is called, so you are not able to change the
; basic semantics but you are able to add core specific additional
; "intelligent" semantics and behaviors.
;
; Input:
;   R8: selected menu group (as defined in config.vhd)
;   R9: selected item within menu group
;       in case of single selected items: 0=not selected, 1=selected
;   R10: OPTM_KEY_SELECT (by default means "Return") or
;        OPTM_KEY_SELALT (by default means "Space")
; Output:
;   R8: 0=OK, else pointer to string with error message
;   R9: 0=OK, else error code
OSM_SEL_POST    INCRB
                XOR     R8, R8
                XOR     R9, R9
                DECRB
                RET

; OSM_SEL_PRE callback function:
;
; Identical to the OSM_SEL_POST callback function (see above) but it is being
; called before the functionality and semantics associated with a certain
; menu item has been handled by the framework.
OSM_SEL_PRE     INCRB
                RSUB    DBG_CORE_STATUS, 1
                XOR     R8, R8
                XOR     R9, R9
                DECRB
                RET

; ----------------------------------------------------------------------------
; Core specific callback functions: Custom messages
; ----------------------------------------------------------------------------

; CUSTOM_MSG callback function:
;
; Called in various situations where the Shell needs to output a message
; to the end user. The situations and contexts are described in sysdef.asm
;
; Input:
;   R8: Situation (CMSG_* constants in sysdef.asm)
;   R9: Context   (CTX_* constants in sysdef.asm)
; Output:
;   R8: 0=no custom message available, otherwise pointer to string

CUSTOM_MSG      XOR     R8, R8
                RET              

; ----------------------------------------------------------------------------
; Core specific constants and strings
; ----------------------------------------------------------------------------

; Add your core specific constants and strings here

; ----------------------------------------------------------------------------
; Ethernet station address (docs/ethernet.md): read the MEGA65 MAC from the
; configuration sector and hand it to the NE1000 through rom_loader.vhd.
;
; The MEGA65 keeps its configuration in sector 1 of the SD card, a raw block
; outside any partition: mega65-core src/hyppo/syspart.asm,
; syspart_configsector_set (the comment there: the config sector now lives
; in sector 1), written by the MEGA65 Configure utility
; (src/utilities/mega65_config.s). Layout: bytes 0 and 1 = format version,
; both 01h; bytes 6..11 = MAC address (syspart_configsector_apply copies
; $DE06..$DE0B to mac_addr_0..5). HYPPO uses the sector only if both version
; bytes are 01h; the utility accepts byte 1 = 01h and byte 0 >= 01h
; (checkMagicBytes) and, when it generates an address, sets bit 1 of byte 0
; (locally administered) and clears bit 0 (unicast). We follow the looser
; rule of the utility and additionally refuse a multicast, all-zero or
; all-FF address. Anything else, or no readable card, selects the locally
; administered default 02:4D:36:35:00:01. The sector is read from whichever
; SD card the framework currently uses (external slot wins), which is also
; the card HYPPO booted from.
;
; rom_loader.vhd, device ETH_DEV, 4k window ETH_WIN_MAC: registers 0..2 take
; the MAC as three big-endian words (bytes 0/1, 2/3, 4/5); register 3 bit 0
; is MAC valid (the card is held disabled until it is set), bit 1 records
; the source for readback (1 = MEGA65 config). The valid bit is written last
; so that the card can never see a half-written address.
;
; Called from PREP_START, i.e. after the BIOS auto-load has mounted the SD
; card and before the core leaves reset. The raw block read goes through the
; SDB_GUARD pair of sdblock.asm like the direct reads of the virtual drives,
; so the FAT32 library learns that its sector buffer was overwritten.
; ----------------------------------------------------------------------------
ETH_DEV         .EQU 0x0110                     ; rom_loader.vhd (C_DEV_ROM_PCXT)
ETH_WIN_MAC     .EQU 0xFFFE                     ; MAC register window
ETH_CFG_SECTOR  .EQU 1                          ; MEGA65 configuration sector
ETH_STR_MAC     .ASCII_W "Ethernet MAC: "
ETH_STR_CFG     .ASCII_W " (MEGA65 config)"
ETH_STR_DEF     .ASCII_W " (default)"
ETH_STR_NOSD    .ASCII_W "Ethernet: MEGA65 config sector not readable, SD error "
ETH_STR_BADCFG  .ASCII_W "Ethernet: MEGA65 config sector has no usable MAC"
ETH_HEXDIGITS   .ASCII_W "0123456789ABCDEF"
ETH_DEF_MAC     .DW 0x0002, 0x004D, 0x0036, 0x0035, 0x0000, 0x0001

; ETH_SET_MAC: no input, no output, registers preserved
ETH_SET_MAC     SYSCALL(enter, 1)
                SUB     8, SP                   ; SP+0..5: MAC bytes
                MOVE    SP, R8                  ; SP+6..7: saved device select
                ADD     6, R8
                RSUB    SAVE_DEVSEL, 1
                XOR     R7, R7                  ; R7: 0 = default, 1 = MEGA65 config

                ; read the configuration sector (raw SD card block 1)
                RSUB    SDB_GUARD_IN, 1         ; FAT32 buffer: flush and mark
                RBRA    _ETH_DEFAULT, !C        ; card not usable right now
                MOVE    ETH_CFG_SECTOR, R8      ; LBA low word
                XOR     R9, R9                  ; LBA high word
                SYSCALL(sd_r_block, 1)
                MOVE    R8, R0                  ; R0: error code
                RSUB    SDB_GUARD_OUT, 1
                CMP     0, R0
                RBRA    _ETH_CHECK, Z
                MOVE    ETH_STR_NOSD, R8        ; log the error and reset the
                SYSCALL(puts, 1)                ; controller, which latches
                MOVE    R0, R8                  ; errors (see sdblock.asm)
                SYSCALL(puthex, 1)
                SYSCALL(crlf, 1)
                SYSCALL(sd_reset, 1)
                RBRA    _ETH_DEFAULT, 1

                ; version bytes: byte 1 = 01h, byte 0 >= 01h (and not FFh)
_ETH_CHECK      MOVE    1, R8
                SYSCALL(sd_r_byte, 1)
                AND     0x00FF, R8
                CMP     1, R8
                RBRA    _ETH_BADCFG, !Z
                XOR     R8, R8
                SYSCALL(sd_r_byte, 1)
                AND     0x00FF, R8
                RBRA    _ETH_BADCFG, Z          ; 00: blank sector
                CMP     0x00FF, R8
                RBRA    _ETH_BADCFG, Z          ; FF: erased sector

                ; copy the six MAC bytes (offsets 6..11) to the stack
                MOVE    SP, R1                  ; R1: destination
                MOVE    6, R2                   ; R2: byte offset in the sector
                XOR     R3, R3                  ; R3: OR of all bytes
                MOVE    0x00FF, R4              ; R4: AND of all bytes
_ETH_COPY       MOVE    R2, R8
                SYSCALL(sd_r_byte, 1)
                AND     0x00FF, R8
                MOVE    R8, @R1++
                OR      R8, R3
                AND     R8, R4
                ADD     1, R2
                CMP     12, R2
                RBRA    _ETH_COPY, !Z
                CMP     0, R3
                RBRA    _ETH_BADCFG, Z          ; 00:00:00:00:00:00
                CMP     0x00FF, R4
                RBRA    _ETH_BADCFG, Z          ; FF:FF:FF:FF:FF:FF
                MOVE    @SP, R8
                AND     0x0001, R8
                RBRA    _ETH_BADCFG, !Z         ; multicast bit set
                MOVE    1, R7                   ; use it
                RBRA    _ETH_WRITE, 1

_ETH_BADCFG     MOVE    ETH_STR_BADCFG, R8
                SYSCALL(puts, 1)
                SYSCALL(crlf, 1)

_ETH_DEFAULT    MOVE    ETH_DEF_MAC, R1
                MOVE    SP, R2
                MOVE    6, R3
_ETH_DEFCOPY    MOVE    @R1++, R8
                MOVE    R8, @R2++
                SUB     1, R3
                RBRA    _ETH_DEFCOPY, !Z
                XOR     R7, R7

                ; deliver: three big-endian words, then the valid bit
_ETH_WRITE      MOVE    M2M$RAMROM_DEV, R0
                MOVE    ETH_DEV, @R0
                MOVE    M2M$RAMROM_4KWIN, R0
                MOVE    ETH_WIN_MAC, @R0
                MOVE    M2M$RAMROM_DATA, R0     ; R0: register 0
                MOVE    SP, R1
                MOVE    3, R3
_ETH_WLOOP      MOVE    @R1++, R8
                SHL     8, R8                   ; SHL fills with X: mask it
                AND     0xFF00, R8
                OR      @R1++, R8
                MOVE    R8, @R0++
                SUB     1, R3
                RBRA    _ETH_WLOOP, !Z
                MOVE    R7, R8                  ; register 3: bit 1 = source,
                SHL     1, R8                   ; bit 0 = valid
                AND     0x0002, R8
                OR      0x0001, R8
                MOVE    R8, @R0

                ; log: "Ethernet MAC: xx:xx:xx:xx:xx:xx (source)"
                MOVE    ETH_STR_MAC, R8
                SYSCALL(puts, 1)
                MOVE    SP, R1
                MOVE    6, R3
_ETH_LOG        MOVE    @R1++, R8
                RSUB    ETH_PUTHEX2, 1
                SUB     1, R3
                RBRA    _ETH_LOG_END, Z
                MOVE    0x003A, R8              ; ':'
                SYSCALL(putc, 1)
                RBRA    _ETH_LOG, 1
_ETH_LOG_END    MOVE    ETH_STR_DEF, R8
                CMP     0, R7
                RBRA    _ETH_LOG_SRC, Z
                MOVE    ETH_STR_CFG, R8
_ETH_LOG_SRC    SYSCALL(puts, 1)
                SYSCALL(crlf, 1)

                MOVE    SP, R8
                ADD     6, R8
                RSUB    RESTORE_DEVSEL, 1
                ADD     8, SP
                SYSCALL(leave, 1)
                RET

; ETH_PUTHEX2: print the low byte of R8 as two hex digits; R8 preserved
ETH_PUTHEX2     INCRB
                MOVE    R8, R0
                SHR     4, R8                   ; SHR fills with C: mask it
                AND     0x000F, R8
                MOVE    ETH_HEXDIGITS, R1
                ADD     R8, R1
                MOVE    @R1, R8
                SYSCALL(putc, 1)
                MOVE    R0, R8
                AND     0x000F, R8
                MOVE    ETH_HEXDIGITS, R1
                ADD     R8, R1
                MOVE    @R1, R8
                SYSCALL(putc, 1)
                MOVE    R0, R8
                DECRB
                RET

; This needs to be the last thing before the "Variables" sections starts
; ----------------------------------------------------------------------------
; Debug: log the rom_loader status registers and the core activity counters
; to the serial console. rom_loader.vhd readback: 0 flags, 1 words delivered,
; 2 words dropped, 3 checksum pcxt.rom, 4 checksum ega_bios.rom,
; 5 checksum xtide.rom, 6 chipset-bus reads, 7 vsyncs (6/7 are free-running
; 16-bit counters: unchanged between two calls means the core is dead).
; ----------------------------------------------------------------------------
DBG_DEV_ROM     .EQU 0x0110
DBG_STR_0       .ASCII_W "PCXT core: flags="
DBG_STR_1       .ASCII_W " ok="
DBG_STR_2       .ASCII_W " drop="
DBG_STR_3       .ASCII_W " sum0="
DBG_STR_4       .ASCII_W " sum3="
DBG_STR_5       .ASCII_W " sum2="
; Floppy spike (docs/floppy.md, CORE/vhdl/floppy_phy_spike.vhd): the three words are the spike's status
; words for its duration. The originals, to restore with the dbg_a/b/c_i port map in mega65.vhd:
;   DBG_STR_6       .ASCII_W " bist="
;   DBG_STR_7       .ASCII_W " req="
;   DBG_STR_8       .ASCII_W " hdd="
DBG_STR_6       .ASCII_W " fidx="
DBG_STR_7       .ASCII_W " fchr="
DBG_STR_8       .ASCII_W " fst="
DBG_STRS        .DW DBG_STR_0, DBG_STR_1, DBG_STR_2, DBG_STR_3
                .DW DBG_STR_4, DBG_STR_5, DBG_STR_6, DBG_STR_7
                .DW DBG_STR_8

DBG_CORE_STATUS SYSCALL(enter, 1)
                SUB     2, SP                   ; buffer for SAVE_DEVSEL
                MOVE    SP, R8
                RSUB    SAVE_DEVSEL, 1
                MOVE    M2M$RAMROM_DEV, R0
                MOVE    DBG_DEV_ROM, @R0
                MOVE    M2M$RAMROM_4KWIN, R0
                MOVE    0, @R0
                MOVE    M2M$RAMROM_DATA, R1     ; R1: register 0
                MOVE    DBG_STRS, R2            ; R2: label strings
                MOVE    9, R3                   ; R3: registers to print
_DBG_CS_LOOP    MOVE    @R2++, R8
                SYSCALL(puts, 1)
                MOVE    @R1++, R8
                SYSCALL(puthex, 1)
                SUB     1, R3
                RBRA    _DBG_CS_LOOP, !Z
                SYSCALL(crlf, 1)
                MOVE    SP, R8
                RSUB    RESTORE_DEVSEL, 1
                ADD     2, SP
                SYSCALL(leave, 1)
                RET

END_OF_ROM      .DW 0

; ----------------------------------------------------------------------------
; Variables: Need to be located in RAM
; ----------------------------------------------------------------------------

#ifdef RELEASE
                .ORG    0x8000                  ; RAM starts at 0x8000
#endif

;
; add your own variables here
;

; M2M Shell variables (only include, if you included "shell.asm" above)
#include "../../M2M/rom/shell_vars.asm"

; ----------------------------------------------------------------------------
; Heap and Stack: Need to be located in RAM after the variables
; ----------------------------------------------------------------------------

; The On-Screen-Menu uses the heap for several data structures. This heap
; is located before the main system heap in memory.
; You need to deduct MENU_HEAP_SIZE from the actual heap size below.
; Example: If your HEAP_SIZE would be 29696, then you write 29696-1024=28672
; instead, but when doing the sanity check calculations, you use 29696
MENU_HEAP_SIZE  .EQU 2560                       ; 98-line menu with 6 submenus: ~1610 words of tables + 250 of %s strings (33 lines used 488)

#ifndef RELEASE

; heap for storing the sorted structure of the current directory entries
; this needs to be the last variable before the monitor variables as it is
; only defined as "BLOCK 1" to avoid a large amount of null-values in
; the ROM file
HEAP_SIZE       .EQU 4608                       ; 7168 - 2560 = 4608
HEAP            .BLOCK 1

; in RELEASE mode: 28k of heap which leads to a better user experience when
; it comes to folders with a lot of files
#else

HEAP_SIZE       .EQU 27136                      ; 29696 - 2560 = 27136
HEAP            .BLOCK 1

; The monitor variables use 22 words, round to 32 for being safe and subtract
; it from FF00 because this is at the moment the highest address that we
; can use as RAM: 0xFEE0
; The stack starts at 0xFEE0 (search var VAR$STACK_START in osm_rom.lis to
; calculate the address). To see, if there is enough room for the stack
; given the HEAP_SIZE do this calculation: Add 29696 words to HEAP which
; is currently 0xXXXX and subtract the result from 0xFEE0. This yields
; currently a stack size of more than 1.5k words, which is sufficient
; for this program.

                .ORG    0xFEE0                  ; TODO: automate calculation
#endif

; STACK_SIZE: Size of the global stack and should be a minimum of 768 words
; after you subtract B_STACK_SIZE.
; B_STACK_SIZE: Size of local stack of the the file- and directory browser. It
; should also have a minimum size of 768 words. If you are not using the
; Shell, then B_STACK_SIZE is not used.
STACK_SIZE      .EQU    1536
B_STACK_SIZE    .EQU    768

#include "../../M2M/rom/main_vars.asm"
