; ****************************************************************************
; MiSTer2MEGA65 (M2M) QNICE ROM
;
; sdblock_cfg.asm: the single build switch for the direct SD block access in
; sdblock.asm and for its serial logging.
;
; ----------------------------------------------------------------------------
; SDB_DEBUG: log what the fast path does on the serial console at boot
; ----------------------------------------------------------------------------
; Remove the ";" in front of the #define to switch the log on, put it back to
; switch it off, then rebuild with CORE/m2m-rom/make_rom.sh. No keyboard is
; involved: the ROM auto loader runs by itself and the virtual drive lines
; appear as soon as an image is mounted.
;
; This lives in its own file and NOT in sdblock.asm because the C
; preprocessor runs once, top to bottom, over the whole concatenated source.
; sdblock.asm is included at the *end* of shell.asm, so a #define in it is
; not yet known while shell.asm's own body, crts-and-roms.asm and everything
; else above it are being processed - their #ifdef SDB_DEBUG blocks would be
; silently dropped. Include this file first and the flag is visible
; everywhere.
;
; That is not hypothetical: it is exactly how the first instrumented build
; ended up with a working map-build log (inside sdblock.asm, after the
; define) and no virtual drive log at all (in shell.asm, before it).
; ****************************************************************************

;#define SDB_DEBUG

; tools/vdrive-latency-bench/run.sh passes -DSDB_NODEBUG for its timing runs,
; so that the cycle counts it reports are those of the shipping build no
; matter how the switch above is set.
#if defined(SDB_NODEBUG) && !defined(FORCE_LOG)
#undef SDB_DEBUG
#endif
