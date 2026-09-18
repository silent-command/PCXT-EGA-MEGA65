; ****************************************************************************
; PCXT-EGA on MiSTer2MEGA65: internal floppy drive (flpdrv.asm) variables
;
; done by silent-command in 2026 and licensed under GPL v3
; ****************************************************************************

FLP_STATE       .BLOCK 1                        ; FLP_S_* (flpdrv.asm)
FLP_MOUNTED     .BLOCK 1                        ; 1 = the FDC has been told a disk is in
FLP_CTRL        .BLOCK 1                        ; shadow of the engine control register
FLP_SPT         .BLOCK 1                        ; sectors per track the FDC was told (9 / 18)
FLP_RATE        .BLOCK 1                        ; FLP_ARG_RATEHD or 0: the rate the disk reads at
FLP_CYC         .BLOCK 1                        ; IO$CYC_MID when the drive was last found empty (probe hold-off)
FLP_N_RD        .BLOCK 1                        ; block requests served
FLP_N_ERR       .BLOCK 1                        ; ... of which failed
FLP_LAST_ERR    .BLOCK 1                        ; engine status of the last failure
FLP_RO          .BLOCK 1                        ; 1 = mounted read-only (drive write protected)
FLP_N_WR        .BLOCK 1                        ; block writes served
FLP_VFY_ERR     .BLOCK 1                        ; 1 = a write failed its read-back: park the next request
FLP_NAMED       .BLOCK 1                        ; 1 = the drive name is in the menu line (FLP_SET_NAME)

#include "flpfmt_vars.asm"
