; ****************************************************************************
; PCXT-EGA on MiSTer2MEGA65: internal floppy drive, pure arithmetic
;
; flpdrv_calc.asm: the LBA -> C/H/R conversion of the physical floppy path,
; kept free of any hardware or shell dependency so that
; tools/vdrive-latency-bench/flp_chs.asm can run exactly this code in the
; QNICE emulator (docs/floppy.md, "Geometry").
;
; The FDC (CORE/rtl/overlay/floppy.v) turns the C/H/R DOS asked for into
;    LBA = (C * 2 + H) * SPT + R - 1
; with the SPT it was told at mount time (18 for a 1.44 MB image, 9 for
; 720 KB), and the inverse here must use that same SPT, never the rate the
; engine happens to read at. Sectors are 1-based: LBA 0 = C0 H0 R1,
; LBA 18 = C0 H1 R1 on 1.44 MB, LBA 36 = C1 H0 R1.
;
; done by silent-command in 2026 and licensed under GPL v3
; ****************************************************************************

; FLP_LBA2CHS: R8 = LBA (0..2879), R9 = sectors per track (9 or 18)
; Returns:     R8 = cylinder, R9 = head, R10 = sector (1-based)
; Division by repeated subtraction: at most 320 iterations, no EAE needed.
FLP_LBA2CHS     INCRB
                MOVE    R8, R0                  ; R0: remainder
                XOR     R1, R1                  ; R1: track = LBA / SPT
_FLP_L2C_1      CMP     R9, R0                  ; SPT > remainder?
                RBRA    _FLP_L2C_2, N           ; yes: division done
                SUB     R9, R0
                ADD     1, R1
                RBRA    _FLP_L2C_1, 1
_FLP_L2C_2      ADD     1, R0                   ; R = remainder + 1
                MOVE    R0, R10
                MOVE    R1, R9
                AND     0x0001, R9              ; H = track mod 2
                MOVE    R1, R8
                AND     0xFFFB, SR              ; clear C (SHR shifts it in)
                SHR     1, R8                   ; C = track / 2
                DECRB
                RET
