; The part of the shell.asm environment that M2M/rom/sdblock.asm refers to.
; Same names, same sizes and same semantics as in M2M/rom/shell_vars.asm, so
; that the bench runs the REAL firmware code and not a copy of it.
;
; Include this *after* the code, it only contains data.

HANDLE_DEV      .BLOCK FAT32$DEV_STRUCT_SIZE
CONFIG_DEVH     .BLOCK FAT32$DEV_STRUCT_SIZE    ; stays zero: no config file
VDRIVES_DEVICE  .DW    0x0102                   ; device id of vdrives.vhd

SDB_VD_MAPS     .BLOCK 120                      ; SDB_M_SIZE * SDB_VD_MAX_N
SDB_RM_MAP      .BLOCK 40                       ; SDB_M_SIZE
SDB_NULL_MAP    .BLOCK 1
SDB_DUMMY_FDH   .BLOCK FAT32$FDH_STRUCT_SIZE    ; stays 0: never dirty
SDB_G_VAL       .BLOCK 1
SDB_FF_STAT     .BLOCK 1
SDB_FF_BLKS     .BLOCK 1
SDB_RD_STAT     .BLOCK 1
SDB_RD_LBA      .BLOCK 2
SDB_DBG_N       .BLOCK 1
SDB_DBG_CNT     .BLOCK 1
SDB_DBG_ACT     .BLOCK 1
SDB_DBG_DRV     .BLOCK 1
SDB_DBG_SZ      .BLOCK 1
SDB_DBG_PL      .BLOCK 1
SDB_DBG_PH      .BLOCK 1
SDB_DBG_T0      .BLOCK 2
SDB_DBG_TE      .BLOCK 2
SDB_SD_T0       .BLOCK 2
SDB_SD_LAST     .BLOCK 2
SDB_SD_CYC      .BLOCK 2
SDB_SD_N        .BLOCK 1
SDB_S_BLEFT     .BLOCK 2
SDB_S_RBLK      .BLOCK 2
SDB_S_CLU       .BLOCK 2
SDB_S_RSTART    .BLOCK 2
SDB_S_NEXT      .BLOCK 2
SDB_S_FCLBA     .BLOCK 2
SDB_S_FCVAL     .BLOCK 1
