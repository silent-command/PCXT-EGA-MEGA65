; ****************************************************************************
; MiSTer2MEGA65 (M2M) QNICE ROM
;
; Variables for shell.asm and its direct includes:
; options.asm
;
; done by sy2002 in 2023 and licensed under GPL v3
; ****************************************************************************


#include "dirbrowse_vars.asm"
#include "keyboard_vars.asm"
#include "screen_vars.asm"

#include "menu_vars.asm"

; reset handling
WELCOME_SHOWN   .BLOCK 1                        ; we need to trust that this
                                                ; is 0 on system coldstart

; option menu
OPTM_ICOUNT     .BLOCK 1                        ; amount of menu items
OPTM_SCOUNT     .BLOCK 1                        ; amount of submenus
OPTM_START      .BLOCK 1                        ; initially selected menu item
OPTM_SELECTED   .BLOCK 1                        ; last options menu selection
OPTM_MNT_STATUS .BLOCK 1                        ; drive mount status; all drvs
OPTM_DTY_STATUS .BLOCK 1                        ; cache dirty status; all drvs

; OPTM_HEAP is used by the option menu to save the modified filenames of
; disk images used by mounted drives: Filenames need to be abbreviated by
; "..." if they are too long. See also HELP_MENU and HANDLE_MOUNTING.
;
; OPTM_HEAP also stores the replacement strings for %s within submenu
; headlines/entry points and the replacem. strings for %s for CRT/ROM loading
;
; Each reserved memory block for one string is @SCR$OSM_O_DX in size.
;
; Memory map:
;
; VDrive strings:   <amount of virtual drives> x @SCR$OSM_O_DX
; Submenu strings:  <amount of submenus> x @SCR$OSM_O_DX
; CRT/ROM strings:  <amount of manual loadable CRTs/ROMs> x @SCR$OSM_O_DX
;
; OPTM_HEAP_LAST points to a scratch buffer that can hold a modified filename
; for saving/restoring while the cache dirty "Saving" message is shown.
; See also OPTM_CB_SHOW. 
OPTM_HEAP       .BLOCK 1
OPTM_HEAP_LAST  .BLOCK 1
OPTM_HEAP_SIZE  .BLOCK 1                        ; size of this scratch buffer

; Temporary variables (only to be used in a very narrow local scope)
SCRATCH_HEX     .BLOCK 5
SCRATCH_DWORD   .BLOCK 2

; SD card device handle and array of pointers to file handles for disk images
HANDLE_DEV      .BLOCK  FAT32$DEV_STRUCT_SIZE

; Remember configuration handling:
; * We are using a separate device handle because some logic around SD card
;   switching in shell.asm is tied to the status of HANDLE_DEV.
;   Warning: This is not a best practice. If you want to leverage the
;   automatic data corruption prevention built in to the FAT32 library of the
;   monitor, then stick to one device handle per device. Since we are not
;   following this best practice, we need to prevent data corruption by
;   ourselves, for example see the ROSM_SAVE dirty check in options.asm.
;   @TODO: We might want to re-factor the handling of device handles.
; * File-handle for config file (saving/loading OSM settings) is valid (i.e.
;   not null) when SAVE_SETTINGS (config.vhd) is true and when the file
;   specified by CFG_FILE (config.vhd) exists and has exactly the size of
;   OPTM_SIZE (config.vhd). The convention "checking CONFIG_FILE for not null"
;   can be used as a trigger for various actions in the shell.
; * OLD_SETTINGS is used to determine changes in the 256-bit (16-word)
;   M2M$CFM_DATA register so that we can implement a smart saving mechanism:
;   When pressing "Help" to close the on-screen-menu, we only save the
;   settings to the SD card when the settings changed.
; * Initially (upon core start time) active SD card: Used for protecting the
;   data integrity: see comment for ROSM_INTEGRITY in options.asm
CONFIG_DEVH     .BLOCK  FAT32$DEV_STRUCT_SIZE
CONFIG_FILE     .BLOCK  FAT32$FDH_STRUCT_SIZE
OLD_SETTINGS    .BLOCK  16
INITIAL_SD      .BLOCK  1

SD_ACTIVE       .BLOCK 1                        ; currently active SD card
SD_CHANGED      .BLOCK 1                        ; SD card (briefly) changed?

; SD card "stability" workaround
SD_WAIT         .EQU   0x05F6                   ; 2 seconds @ 50 MHz
SD_CYC_MID      .BLOCK 1                        ; cycle counter for SD card..
SD_CYC_HI       .BLOCK 1                        ; .."stability workaround"
SD_WAIT_DONE    .BLOCK 1                        ; initial waiting done

; waiting time until M2M$SYS_CORE_H_FREQ is ready to be read: 2.5 seconds
LOG_HFREQ_WAIT  .EQU   0x0773                   ; 2.5 seconds @ 50 MHz
LOG_HFREQ_FLAG  .BLOCK 1                        ; info has been logged
LOG_CYC_MID     .BLOCK 1
LOG_CYC_HI      .BLOCK 1

LOG_HEAP_SHOWN  .BLOCK 1

; file browser persistent status
FB_HEAP         .BLOCK 1                        ; heap used by file browser
FB_STACK        .BLOCK 1                        ; local stack used by browser
FB_STACK_INIT   .BLOCK 1                        ; initial local browser stack
FB_MAINSTACK    .BLOCK 1                        ; stack of main program
FB_HEAD         .BLOCK 1                        ; lnkd list: curr. disp. head
FB_LASTCALLER   .BLOCK 1                        ; vdrive id/CRTROM id + mode

; context variables (see CTX_* constants in sysdef.asm)
SF_CONTEXT      .BLOCK 1                        ; context for SELECT_FILE
SF_CONTEXT_DATA .BLOCK 1                        ; optional add. data for ctx

; ----------------------------------------------------------------------------
; Virtual drive and manual/automatic CRT/ROM loading system
; ----------------------------------------------------------------------------

; Important: Make sure you have as many ".BLOCK FAT32$FDH_STRUCT_SIZE"
; statements listed one after another as the .EQU VDRIVES_MAX (below) plus
; the .EQU CRTROM_MAN_MAX demands and make sure that the HNDL_VD_FILES
; and HNDL_RM_FILES arrays in shell.asm point to the right amount of them
; as well, i.e. you need to edit shell.asm
; Autogenerated from globals.vhd and included from globals.asm
#include "../../CORE/m2m-rom/shell_fhandles.asm"

#include "../../CORE/m2m-rom/globals.asm"

; Virtual drive system (aka mounting disk/module/tape images):
; VDRIVES_NUM:      Amount of virtual, mountable drives; needs to correlate
;                   with the actual hardware in vdrives.vhd and the menu items
;                   tagged with OPTM_G_MOUNT_DRV in config.vhd
;                   VDRIVES_MAX must be equal or larger than the value stored
;                   in this variable
;                   Variable is initialized in VD_INIT in vdrives.asm
;
; VDRIVES_MAX:      Maximum amount of supported virtual drives.
;                   VD_INIT expects an .EQU and also the assembler does not
;                   allow this value to be a variable. Do not forget to
;                   adjust the file handles (see above) accordingly.
;                   Try to keep small for RAM preservation reasons.
;                   Autogen. from globals.vhd and included from globals.asm
;
; VDRIVES_DEVICE:   Device ID of the IEC bridge in vdrives.vhd
;
; VDRIVES_BUFS:     Array of device IDs of size VDRIVES_NUM that contains the
;                   RAM buffer-devices that will hold the mounted drives
;
; VDRIVES_FLUSH_*:  Array of high/low words of the amount of bytes that still
;                   need to be flushed to ensure that the cache is written
;                   completely to the SD card
;
; VDRIVES_ITERSIZ   Array of amount of bytes stored in one iteration of the
;                   background saving (buffer flushing) process
;
; VDRIVES_FL_*:     Array of current 4k window and offset within window of the
;                   disk image buffer in RAM
VDRIVES_NUM     .BLOCK  1
VDRIVES_DEVICE  .BLOCK  1
VDRIVES_BUFS    .BLOCK  VDRIVES_MAX
VDRIVES_FLUSH_H .BLOCK  VDRIVES_MAX
VDRIVES_FLUSH_L .BLOCK  VDRIVES_MAX
VDRIVES_ITERSIZ .BLOCK  VDRIVES_MAX
VDRIVES_FL_4K   .BLOCK  VDRIVES_MAX
VDRIVES_FL_OFS  .BLOCK  VDRIVES_MAX

; ----------------------------------------------------------------------------
; Direct SD card block access (sdblock.asm)
; ----------------------------------------------------------------------------

; Block maps: they translate "block N of the image file" into an absolute SD
; card LBA so that HANDLE_DRV_RD/WR and the CRT/ROM auto loader can bypass
; the byte-wise FAT32 library. See sdblock.asm for the layout.
;
; The QNICE assembler cannot evaluate expressions in .BLOCK, so the size of
; SDB_VD_MAPS is spelled out: SDB_M_SIZE (40) * SDB_VD_MAX_N (3) = 120.
; Keep SDB_VD_MAX_N in sdblock.asm in sync with this and with VDRIVES_MAX.
SDB_VD_MAPS     .BLOCK  120             ; one map per virtual drive
SDB_RM_MAP      .BLOCK  40              ; map for the CRT/ROM loader
SDB_NULL_MAP    .BLOCK  1               ; stays 0: forces the FAT32 fallback
SDB_DUMMY_FDH   .BLOCK  FAT32$FDH_STRUCT_SIZE   ; stays 0: never dirty, see
                                                ; SDB_ORPHAN

; whether a real file handle claims the FAT32 library sector buffer that we
; are about to overwrite (SDB_GUARD_IN/OUT)
SDB_G_VAL       .BLOCK  1               ; 1 = somebody has to be told

; what the last SDB_FREAD_FAST did, also readable without the serial log
SDB_FF_STAT     .BLOCK  1               ; SDB_B_OK or the reason it stopped
SDB_FF_BLKS     .BLOCK  1               ; blocks it transferred

; what the last virtual drive block request did, likewise
SDB_RD_STAT     .BLOCK  1               ; SDB_R_OK or why the fast path was..
SDB_RD_LBA      .BLOCK  2               ; ..refused; the LBA when it was used

; per request measurement, only filled in when SDB_DEBUG is on
SDB_DBG_N       .BLOCK  1               ; log lines still owed after a mount
SDB_DBG_CNT     .BLOCK  1               ; requests since the mount
SDB_DBG_ACT     .BLOCK  1               ; an SD-direct request is in flight
SDB_DBG_DRV     .BLOCK  1               ; its virtual drive
SDB_DBG_SZ      .BLOCK  1               ; its VD_SIZEB
SDB_DBG_PL      .BLOCK  1               ; its byte position, low
SDB_DBG_PH      .BLOCK  1               ; ..and high
SDB_DBG_T0      .BLOCK  2               ; cycle counter when it started
SDB_DBG_TE      .BLOCK  2               ; ..when the previous one ended

; how long the SD card itself takes, and how often it is asked
SDB_SD_T0       .BLOCK  2               ; start of one card access
SDB_SD_LAST     .BLOCK  2               ; cycles of the last card access
SDB_SD_CYC      .BLOCK  2               ; cycles of all of them in a request
SDB_SD_N        .BLOCK  1               ; how many of them in a request

; scratch space used while a map is being built
SDB_S_BLEFT     .BLOCK  2               ; blocks that are not mapped yet
SDB_S_RBLK      .BLOCK  2               ; blocks in the current extent
SDB_S_CLU       .BLOCK  2               ; current cluster
SDB_S_RSTART    .BLOCK  2               ; first cluster of the current extent
SDB_S_NEXT      .BLOCK  2               ; successor that ended the extent
SDB_S_FCLBA     .BLOCK  2               ; LBA of the buffered FAT sector
SDB_S_FCVAL     .BLOCK  1               ; is SDB_S_FCLBA valid?

; System to handle manually and automatically loaded cartridges and ROMs
; See also globals.vhd: There are multiple types of "byte streaming devices"
; that are able to receive the CRT/ROM data. All need to obey to a certain
; protocol that is: 4K windows 0x0000..0xFFFE can be used to recieve data and
; the 4K window 0xFFFF is used as a control and status register
; MAX values are autogen. from globals.vhd and included from globals.asm
CRTROM_MAN_NUM  .BLOCK 1                        ; amount of manual CRTs/ROMs
CRTROM_MAN_LDF  .BLOCK CRTROM_MAN_MAX           ; flag: has been loaded
CRTROM_MAN_DEV  .BLOCK CRTROM_MAN_MAX           ; byte streaming device ids
CRTROM_MAN_4KS  .BLOCK CRTROM_MAN_MAX           ; 4K start address within dev.
CRTROM_AUT_NUM  .BLOCK 1                        ; amount of automatic ROMSs
CRTROM_AUT_LDF  .BLOCK CRTROM_AUT_MAX           ; flag: has been loaded
CRTROM_AUT_DEV  .BLOCK CRTROM_AUT_MAX           ; byte streaming device ids
CRTROM_AUT_4KS  .BLOCK CRTROM_AUT_MAX           ; 4K start address within dev.
CRTROM_AUT_MOD  .BLOCK CRTROM_AUT_MAX           ; mode: mandatory or optional
CRTROM_AUT_NAM  .BLOCK CRTROM_AUT_MAX           ; startpos of filenames
CRTROM_AUT_FILE .BLOCK FAT32$FDH_STRUCT_SIZE    ; file handle to autoload ROMs
