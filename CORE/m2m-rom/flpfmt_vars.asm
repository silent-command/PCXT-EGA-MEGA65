; ****************************************************************************
; PCXT-EGA on MiSTer2MEGA65: internal floppy drive, FORMAT (flpfmt.asm)
; variables; included from flpdrv_vars.asm
;
; done by silent-command in 2026 and licensed under GPL v3
; ****************************************************************************

FLPF_TRK        .BLOCK 1                        ; track key (C * 2 + H) formatted last, FLPF_NO_TRK = none
FLPF_N_FMT      .BLOCK 1                        ; tracks formatted
FLPF_N_ACK      .BLOCK 1                        ; fill blocks acknowledged without a write
