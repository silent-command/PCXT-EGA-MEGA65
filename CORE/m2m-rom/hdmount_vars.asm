; variables of hdmount.asm (RAM)
HDM_ON          .BLOCK 1                        ; 1 = /m2m/hdmount is open: changes are written
HDM_PENDING     .BLOCK 1                        ; 1 = HDM_PATH still has to be written (HDM_POLL)
HDM_NAMED       .BLOCK 1                        ; 0 = the menu line still needs the name (HDM_MENU_OPEN)
HDM_CWD_OK      .BLOCK 1                        ; 1 = HDM_CWD is the directory of the browser
HDM_CWD         .BLOCK 80                       ; HDM_PATH_MAX: directory of HANDLE_DEV, "" = root
HDM_PATH        .BLOCK 80                       ; HDM_PATH_MAX: the remembered image, "" = none
HDM_FILE        .BLOCK FAT32$FDH_STRUCT_SIZE    ; /m2m/hdmount, on CONFIG_DEVH
