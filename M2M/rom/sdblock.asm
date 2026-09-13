; ****************************************************************************
; MiSTer2MEGA65 (M2M) QNICE ROM
;
; sdblock.asm: direct 512-byte block access to files on the SD card
;
; The FAT32 library of the QNICE Monitor only offers a byte-wise API
; (f32_fread / f32_fwrite). Every single byte revalidates the cluster and the
; sector of the file handle, which costs about 107 instructions per byte, and
; f32_fseek walks the cluster chain from the start of the file, which makes a
; random access at the far end of a 42 MB image cost seconds.
;
; This module resolves the on-disk layout of a file *once* into a compact
; extent table and can then map "block N of the file" to an absolute SD card
; LBA. A block is then one SD$READ_BLOCK plus a tight copy loop out of the
; 512-byte buffer of the SD controller.
;
; ----------------------------------------------------------------------------
; THE TWO RULES
; ----------------------------------------------------------------------------
;
; (1) The FAT32 library must never be able to tell that we were here.
;
;     The 512-byte "sector buffer" of the FAT32 library IS the 512-byte
;     hardware buffer of the SD controller; the device handle only remembers
;     *which* file handle filled it (FAT32$DEV_BUFFERED_FDH). Every direct
;     access destroys the library's buffer while the library still believes
;     it holds a particular sector.
;
;     Earlier versions of this file solved that by pointing
;     FAT32$DEV_BUFFERED_FDH at a dummy handle, i.e. by reaching into the
;     library's bookkeeping. That is not done any more. Instead:
;
;       * SDB_GUARD_IN works out, *before* anything is touched, which sector
;         the library believes is in the buffer and whether that sector can
;         be read back. If it cannot, the fast path is refused and nothing
;         is touched at all.
;       * a dirty buffer is written back through the library first.
;       * SDB_GUARD_OUT reads that very sector back, so the buffer holds
;         exactly what it held before.
;       * SDB_FREAD_FAST, which moves the file position anyway, restores the
;         library state the library's own way: with an f32_fseek, which
;         unconditionally re-reads the sector and re-claims ownership.
;
;     The one remaining poke, SDB_ORPHAN, exists only for the case where the
;     restoring read itself fails, i.e. where the card is already broken. It
;     is strictly better than leaving the library with a buffer that holds
;     something else than it thinks.
;
; (2) Any error anywhere leaves the caller with "nothing happened".
;
;     Every entry point returns Carry=0 on any problem, and the byte-wise
;     FAT32 path then does all of the work exactly as it did before this
;     file existed. In particular:
;
;       * an SD card error latches the controller into its error state (see
;         the IO$SD_CSR description in sysdef.asm: "you need to reset the
;         controller to go on"), which would make every *subsequent* library
;         access fail too. SDB_SDERR therefore issues SD$RESET after any
;         failed SD operation before we hand back control.
;       * SDB_FREAD_FAST never seeks to the end of the file. It always leaves
;         at least one whole block to the byte loop, so the file position it
;         hands over is strictly inside the file and the caller reaches EOF
;         through the library, the way it always did.
;       * every seek is verified against FAT32$FDH_ACCESS afterwards.
;
; ----------------------------------------------------------------------------
; Serial logging
; ----------------------------------------------------------------------------
; The switch is SDB_DEBUG in M2M/rom/sdblock_cfg.asm, which shell.asm includes
; as its very first line. It must NOT be defined here: this file is included
; at the end of shell.asm, and the C preprocessor runs once from top to
; bottom, so a #define here would be invisible to every #ifdef above it.
;
; This file needs the environment of shell.asm.
;
; done for the PCXT-EGA-MEGA65 port and licensed under GPL v3
; ****************************************************************************

; ----------------------------------------------------------------------------
; Layout of a block map (see SDB_VD_MAPS / SDB_RM_MAP in shell_vars.asm)
; ----------------------------------------------------------------------------

; Maximum amount of extents (runs of physically consecutive clusters) that we
; are willing to remember for one file. A freshly copied image file normally
; is one single extent. Files that would need more extents than this fall
; back to the FAT32 library path.
SDB_MAX_EXT     .EQU 8

SDB_M_NEXT      .EQU 0                  ; amount of valid extents; 0 = no map
SDB_M_FDH       .EQU 1                  ; FDH this map was built for
SDB_M_TBLK_LO   .EQU 2                  ; amount of *whole* 512-byte blocks..
SDB_M_TBLK_HI   .EQU 3                  ; ..in the file (filesize / 512)
SDB_M_BAIL      .EQU 4                  ; why there is no map (SDB_B_*)
SDB_M_EXT       .EQU 5                  ; start of the extent array

; one extent: amount of blocks (lo/hi) and the absolute SD card LBA (lo/hi)
; of the first of them
SDB_E_NBLK_LO   .EQU 0
SDB_E_NBLK_HI   .EQU 1
SDB_E_LBA_LO    .EQU 2
SDB_E_LBA_HI    .EQU 3
SDB_E_SIZE      .EQU 4

; size of one map in words: SDB_M_EXT + SDB_E_SIZE * SDB_MAX_EXT = 5 + 4*8
; = 37, rounded up to 40 to leave room
SDB_M_SIZE      .EQU 40

; Amount of virtual drives that SDB_VD_MAPS in shell_vars.asm has room for.
; The QNICE assembler cannot evaluate expressions in .BLOCK, so the size of
; SDB_VD_MAPS is the literal SDB_M_SIZE * SDB_VD_MAX_N and both have to be
; kept in sync by hand. Virtual drives beyond SDB_VD_MAX_N are not broken,
; they just always use the (slow) FAT32 library path.
SDB_VD_MAX_N    .EQU 3

; Why a map could not be built. Logged, and also readable from SDB_M_BAIL.
SDB_B_OK        .EQU 0
SDB_B_NOMAP     .EQU 1                  ; no map slot for this drive
SDB_B_NODEV     .EQU 2                  ; file handle has no device handle
SDB_B_NOSPC     .EQU 3                  ; sectors per cluster is zero
SDB_B_EMPTY     .EQU 4                  ; file is shorter than one block
SDB_B_BADSTART  .EQU 5                  ; start cluster < 2
SDB_B_FRAG      .EQU 6                  ; more extents than SDB_MAX_EXT
SDB_B_FATERR    .EQU 7                  ; could not read a FAT sector
SDB_B_BADCLUS   .EQU 8                  ; illegal cluster in the chain
SDB_B_SHORT     .EQU 9                  ; chain ends before the file does
SDB_B_LBA       .EQU 10                 ; LBA arithmetic out of range
SDB_B_GUARD     .EQU 11                 ; buffer could not be made restorable
SDB_B_SEEK      .EQU 12                 ; restoring seek failed

; Why one virtual drive block request did or did not take the fast path.
; Left in SDB_RD_STAT by SDB_VD_RDBLK / SDB_VD_WRBLK after every request, so
; it can be read out even in a build without the serial log.
SDB_R_OK        .EQU 0                  ; fast path taken
SDB_R_SIZE      .EQU 1                  ; VD_SIZEB is not exactly 512
SDB_R_ALIGN     .EQU 2                  ; byte position is not block aligned
SDB_R_MAP       .EQU 3                  ; no usable map for this drive/handle
SDB_R_RANGE     .EQU 4                  ; block is outside the mapped file
SDB_R_GUARD     .EQU 5                  ; buffer could not be made restorable
SDB_R_SDERR     .EQU 6                  ; the SD card operation failed

; end-of-chain marker: everything >= 0x0FFFFFF8 terminates a FAT32 chain,
; and everything >= 0x0FFFFFF0 is reserved, so refuse all of it
SDB_EOC_HI      .EQU 0x0FFF
SDB_EOC_LO      .EQU 0xFFF0

; ----------------------------------------------------------------------------
; Housekeeping
; ----------------------------------------------------------------------------

; SDB_INVAL_ALL
; Invalidates all block maps, i.e. everything falls back to the FAT32 library
; until the maps are rebuilt. Called from VD_INIT and whenever the SD card
; changes. Also clears the two zero-filled helper structures, because the
; variables live in uninitialized RAM.
;
; Input:   none
; Output:  none, all registers unchanged
SDB_INVAL_ALL   INCRB
                MOVE    SDB_VD_MAPS, R0
                MOVE    SDB_VD_MAX_N, R1
_SDBIA_L        MOVE    0, @R0
                ADD     SDB_M_SIZE, R0
                SUB     1, R1
                RBRA    _SDBIA_L, !Z
                MOVE    SDB_RM_MAP, R0
                MOVE    0, @R0
                MOVE    SDB_NULL_MAP, R0
                MOVE    0, @R0
                MOVE    SDB_G_VAL, R0
                MOVE    0, @R0

                ; SDB_DUMMY_FDH must read as an all-zero, and therefore never
                ; dirty, file handle: SDB_ORPHAN hands it to FAT32$FLUSH
                MOVE    SDB_DUMMY_FDH, R0
                MOVE    FAT32$FDH_STRUCT_SIZE, R1
_SDBIA_L2       MOVE    0, @R0++
                SUB     1, R1
                RBRA    _SDBIA_L2, !Z
                DECRB
                RET

; SDB_VDMAP
; Returns the block map that belongs to a virtual drive. Drives that have no
; map (see SDB_VD_MAX_N) get the permanently empty SDB_NULL_MAP, which makes
; SDB_CHECK fail and therefore forces the FAT32 library path.
;
; Input:   R8: virtual drive number
; Output:  R8: pointer to the block map
SDB_VDMAP       INCRB
                MOVE    R8, R0
                MOVE    SDB_VD_MAX_N, R1
                CMP     R1, R0                  ; drive number < maximum?
                RBRA    _SDBVM_OK, N            ; yes
                MOVE    SDB_NULL_MAP, R8        ; no: never mapped
                RBRA    _SDBVM_D, 1
_SDBVM_OK       MOVE    SDB_VD_MAPS, R8
_SDBVM_L        CMP     0, R0
                RBRA    _SDBVM_D, Z
                ADD     SDB_M_SIZE, R8
                SUB     1, R0
                RBRA    _SDBVM_L, 1
_SDBVM_D        DECRB
                RET

; SDB_CHECK
; Is the given map valid and does it belong to the given file handle?
;
; Input:   R8: pointer to the block map
;          R9: file handle (FDH)
; Output:  Carry=1 if the map can be used, all registers unchanged
SDB_CHECK       INCRB
                CMP     0, @R8                  ; any extents?
                RBRA    _SDBC_NO, Z             ; no: unusable
                MOVE    R8, R0
                ADD     SDB_M_FDH, R0
                CMP     @R0, R9                 ; built for this file handle?
                RBRA    _SDBC_NO, !Z            ; no: unusable
                OR      0x0004, SR              ; set Carry
                RBRA    _SDBC_R, 1
_SDBC_NO        AND     0xFFFB, SR              ; clear Carry
_SDBC_R         DECRB
                RET

; ----------------------------------------------------------------------------
; Every SD card access of the fast path goes through these two wrappers, so
; that the time the card itself needs can be measured separately from
; everything else, and so that the number of card accesses per virtual drive
; request is countable. Without SDB_DEBUG they are a plain call.
; ----------------------------------------------------------------------------

; SDB_SDRD: read one 512-byte block into the SD controller's buffer
; Input:   R8/R9 = LBA lo/hi
; Output:  R8 = 0, or the error code
SDB_SDRD
#ifdef SDB_DEBUG
                RSUB    _SDB_SDT0, 1
#endif
                SYSCALL(sd_r_block, 1)
#ifdef SDB_DEBUG
                RSUB    _SDB_SDT1, 1
#endif
                RET

; SDB_SDWR: write the SD controller's buffer to one 512-byte block
; Input:   R8/R9 = LBA lo/hi
; Output:  R8 = 0, or the error code
SDB_SDWR
#ifdef SDB_DEBUG
                RSUB    _SDB_SDT0, 1
#endif
                SYSCALL(sd_w_block, 1)
#ifdef SDB_DEBUG
                RSUB    _SDB_SDT1, 1
#endif
                RET

#ifdef SDB_DEBUG
; take the time before one card access; all registers unchanged
_SDB_SDT0       SYSCALL(enter, 1)
                RSUB    SDB_DBG_NOW, 1
                MOVE    SDB_SD_T0, R0
                MOVE    R8, @R0++
                MOVE    R9, @R0
                SYSCALL(leave, 1)
                RET

; take the time after one card access and accumulate it; R8 (the error code
; of the access) and all other registers unchanged
_SDB_SDT1       SYSCALL(enter, 1)
                RSUB    SDB_DBG_NOW, 1          ; R9|R8 = now
                MOVE    SDB_SD_T0, R0
                SUB     @R0++, R8               ; R9|R8 = how long it took
                SUBC    @R0, R9
                MOVE    SDB_SD_LAST, R0
                MOVE    R8, @R0++
                MOVE    R9, @R0
                MOVE    SDB_SD_CYC, R0          ; total in this request
                ADD     R8, @R0++
                ADDC    R9, @R0
                MOVE    SDB_SD_N, R0            ; accesses in this request
                ADD     1, @R0
                SYSCALL(leave, 1)
                RET
#endif

; SDB_SDERR
; Called after a failed SD card operation. The controller latches its error
; state and refuses everything until it is reset, which would turn our
; problem into a fatal error in the *next* FAT32 library call. Reset it, so
; that the fallback path starts from a clean controller.
;
; Input:   R8: the error code (only used for logging)
; Output:  none, R8 unchanged
SDB_SDERR       INCRB
                MOVE    R8, R0
#ifdef SDB_DEBUG
                MOVE    SDB_L_SDERR, R8
                RSUB    SDB_LOGS, 1
                MOVE    R0, R8
                RSUB    SDB_LOGH, 1
                RSUB    SDB_LOGNL, 1
#endif
                SYSCALL(sd_reset, 1)
                MOVE    R0, R8
                DECRB
                RET

; ----------------------------------------------------------------------------
; Guarding the FAT32 library's sector buffer
; ----------------------------------------------------------------------------

; SDB_GUARD_IN
; Prepares for direct SD card access. Writes the FAT32 library's sector
; buffer back first if it is dirty, and notes whether a real file handle
; currently claims the buffer, so that SDB_GUARD_OUT can tell that handle
; afterwards that the contents are no longer what it thinks. Refuses
; (Carry=0) without touching anything if the write-back fails.
;
; This used to remember the sector's LBA and read it back in
; SDB_GUARD_OUT. That was a second SD card access per virtual drive request,
; about 1.5 ms of hardware time out of 3.4 ms, for something that the
; library's own re-read mechanism does for free. It also could only ever
; satisfy one of the two device handles that share the one hardware buffer,
; whereas marking tells both.
;
; Input:   none
; Output:  Carry=1: direct access is allowed
;          Carry=0: do not touch the SD card, nothing has been touched
;          all registers unchanged
SDB_GUARD_IN    SYSCALL(enter, 1)

                MOVE    SDB_G_VAL, R8           ; nobody to tell yet
                MOVE    0, @R8

                MOVE    HANDLE_DEV, R8          ; who claims the buffer?
                RSUB    _SDB_OWNER, 1
                RBRA    _SDBGI_HAVE, C
                MOVE    CONFIG_DEVH, R8
                RSUB    _SDB_OWNER, 1
                RBRA    _SDBGI_HAVE, C
                RBRA    _SDBGI_OK, 1            ; nobody: nothing to do

                ; R8: device handle, R9: owning FDH
_SDBGI_HAVE     MOVE    R9, R1

                MOVE    R1, R8                  ; dirty? then write it back
                ADD     FAT32$FDH_FLAGS, R8
                MOVE    @R8, R8
                AND     FAT32$FDHF_DIRTY, R8
                RBRA    _SDBGI_CLEAN, Z
                MOVE    R1, R8
                SYSCALL(f32_fflush, 1)
                CMP     0, R9
                RBRA    _SDBGI_NO, !Z           ; cannot write back: refuse

_SDBGI_CLEAN    MOVE    SDB_G_VAL, R8           ; a real handle owns it, so
                MOVE    1, @R8                  ; ..it has to be told later

_SDBGI_OK       OR      0x0004, SR              ; set Carry
                RBRA    _SDBGI_RET, 1
_SDBGI_NO       AND     0xFFFB, SR              ; clear Carry
_SDBGI_RET      SYSCALL(leave, 1)
                RET

; Input:  R8: device handle
; Output: Carry=1 and R9 = the FDH that claims the buffer, R8 unchanged
;
; SDB_DUMMY_FDH is our own "the contents are unknown" marker and must not be
; reported as an owner: otherwise the request after an orphaned one would try
; to write back and mark a handle that is not a real file, and - since the
; dummy has cluster 0 - would have been refused outright by the old
; restore-based guard.
_SDB_OWNER      INCRB
                CMP     0, @R8                  ; device handle initialized?
                RBRA    _SDB_OWN_NO, Z
                MOVE    R8, R0
                ADD     FAT32$DEV_BUFFERED_FDH, R0
                MOVE    @R0, R9
                RBRA    _SDB_OWN_NO, Z          ; nobody claims it
                MOVE    SDB_DUMMY_FDH, R0
                CMP     R0, R9                  ; already marked as unknown?
                RBRA    _SDB_OWN_NO, Z          ; then there is no owner
                OR      0x0004, SR
                RBRA    _SDB_OWN_R, 1
_SDB_OWN_NO     AND     0xFFFB, SR
_SDB_OWN_R      DECRB
                RET

; SDB_GUARD_OUT
; The direct access is done and the hardware buffer now holds our block. Tell
; whoever claimed it that its contents are unknown, so that the FAT32 library
; re-reads instead of trusting it.
;
; Input:   none
; Output:  none, all registers unchanged
SDB_GUARD_OUT   SYSCALL(enter, 1)
                MOVE    SDB_G_VAL, R8
                CMP     0, @R8
                RBRA    _SDBGO_RET, Z           ; nobody had claimed it
                MOVE    0, @R8
                RSUB    SDB_ORPHAN, 1
_SDBGO_RET      SYSCALL(leave, 1)
                RET

; SDB_GUARD_CLR
; The library has been put back by other means - SDB_FREAD_FAST finishes with
; an f32_fseek, which re-reads the sector and re-claims ownership itself - so
; there is nothing left to mark.
;
; Input:   none
; Output:  none, all registers unchanged
SDB_GUARD_CLR   INCRB
                MOVE    SDB_G_VAL, R0
                MOVE    0, @R0
                DECRB
                RET

; SDB_ORPHAN
; Tells both device handles that the contents of the 512-byte hardware buffer
; are unknown, so that the library re-reads rather than serving something we
; overwrote. This is the same mechanism the library uses on itself: READ_FDH
; compares FAT32$DEV_BUFFERED_FDH with the handle it was called for and
; re-reads through FAT32$RW_SIC whenever they differ.
;
; "Unknown" is expressed by handing the buffer to SDB_DUMMY_FDH, an all-zero
; and therefore never dirty file handle, and not by the obvious 0: FAT32$FLUSH
; returns immediately when called with R8 = 0 and then leaves R9 - its error
; code - untouched, and FAT32$FILE_SEEK checks that stale R9 right after
; calling it, so a seek would silently do nothing.
;
; Note what this does NOT do: it issues no SD card access of its own, so it
; cannot produce an LBA, and therefore cannot reproduce anything of the shape
; that made hardware run 1 fatal (a wild LBA latching the controller's error
; state). All of the guards against that - stopping one block short of the
; end of a file, verifying FAT32$FDH_ACCESS after every seek, validating every
; LBA in SDB_CLULBA, and resetting the controller after a failed access - are
; untouched.
;
; Input:   none
; Output:  none, all registers unchanged
SDB_ORPHAN      SYSCALL(enter, 1)
#ifdef SDB_DEBUG
                MOVE    SDB_L_ORPH, R8
                RSUB    SDB_LOGS, 1
                RSUB    SDB_LOGNL, 1
#endif
                MOVE    HANDLE_DEV, R8
                RSUB    _SDB_ORPH1, 1
                MOVE    CONFIG_DEVH, R8
                RSUB    _SDB_ORPH1, 1
                MOVE    SDB_G_VAL, R8           ; everybody has been told
                MOVE    0, @R8
                SYSCALL(leave, 1)
                RET

_SDB_ORPH1      INCRB
                MOVE    R8, R1
                CMP     0, @R8
                RBRA    _SDB_ORPH_R, Z
                MOVE    R8, R0
                ADD     FAT32$DEV_BUFFERED_FDH, R0
                MOVE    SDB_DUMMY_FDH, R2
                MOVE    R2, @R0
_SDB_ORPH_R     MOVE    R1, R8
                DECRB
                RET

; ----------------------------------------------------------------------------
; 32-bit helpers
; ----------------------------------------------------------------------------

; SDB_B2BLK
; Converts a byte position into a 512-byte block index (unsigned 32 bit).
;
; Input:   R9/R10: byte position lo/hi
; Output:  R9/R10: block index lo/hi
SDB_B2BLK       INCRB
                MOVE    R10, R0
                AND     0x01FF, R0              ; bits that move down into..
                AND     0xFFFD, SR              ; ..the low word; clear X so..
                SHL     7, R0                   ; ..SHL shifts in zeros
                AND     0xFFFB, SR              ; clear C so SHR shifts in 0
                SHR     9, R9
                ADD     R0, R9
                AND     0xFFFB, SR
                SHR     9, R10
                DECRB
                RET

; SDB_BLK2B
; Converts a 512-byte block index into a byte position (unsigned 32 bit).
;
; Input:   R9/R10: block index lo/hi
; Output:  R9/R10: byte position lo/hi
SDB_BLK2B       INCRB
                MOVE    R9, R0
                AND     0xFFFB, SR              ; clear C so SHR shifts in 0
                SHR     7, R0                   ; bits that move up into..
                AND     0xFFFD, SR              ; ..the high word; clear X
                SHL     9, R10
                ADD     R0, R10
                AND     0xFFFD, SR
                SHL     9, R9
                DECRB
                RET

; SDB_CLULBA
; The absolute SD card LBA of one sector within one cluster, i.e. exactly
; what FAT32$RW_SIC computes, with every range check spelled out.
;
; Input:   R8: device handle
;          R9/R10: cluster lo/hi
;          R11: sector within the cluster
; Output:  Carry=1: R9/R10 = LBA lo/hi
;          Carry=0: the cluster or the sector is out of range
;          R8, R11 unchanged
SDB_CLULBA      INCRB
                MOVE    R8, R0                  ; R0: device handle
                MOVE    R11, R1                 ; R1: sector

                CMP     0, R10                  ; cluster >= 2?
                RBRA    _SDBCL_C1, !Z
                CMP     1, R9
                RBRA    _SDBCL_NO, N            ; cluster = 0
                RBRA    _SDBCL_NO, Z            ; cluster = 1
_SDBCL_C1       CMP     SDB_EOC_HI, R10         ; cluster < 0x0FFFFFF0?
                RBRA    _SDBCL_C2, !Z
                CMP     R9, SDB_EOC_LO
                RBRA    _SDBCL_NO, N
                RBRA    _SDBCL_NO, Z
_SDBCL_C2       CMP     R10, 0x0FFF             ; and inside 28 bits at all?
                RBRA    _SDBCL_NO, N

                MOVE    R0, R2                  ; R2: sectors per cluster
                ADD     FAT32$DEV_SECT_PER_CLUS, R2
                MOVE    @R2, R2
                RBRA    _SDBCL_NO, Z
                MOVE    R2, R3
                SUB     1, R3
                CMP     R1, R3                  ; sector inside the cluster?
                RBRA    _SDBCL_NO, N

                MOVE    R9, R8                  ; (cluster - 2) * spc
                MOVE    R10, R9
                SUB     2, R8
                SUBC    0, R9
                MOVE    R2, R10
                XOR     R11, R11
                SYSCALL(mulu32, 1)              ; R11|R10|R9|R8 = 64 bit
                CMP     0, R10                  ; more than 32 bits?
                RBRA    _SDBCL_NO, !Z
                CMP     0, R11
                RBRA    _SDBCL_NO, !Z

                MOVE    R0, R11                 ; plus cluster_begin_lba
                ADD     FAT32$DEV_CLUSTER_LO, R11
                MOVE    @R11++, R10
                MOVE    @R11, R11
                ADD     R10, R8
                ADDC    R11, R9
                RBRA    _SDBCL_NO, C            ; 32-bit overflow
                ADD     R1, R8                  ; plus the sector
                ADDC    0, R9
                RBRA    _SDBCL_NO, C

                MOVE    R9, R10                 ; return the LBA in R9/R10
                MOVE    R8, R9
                MOVE    R0, R8
                MOVE    R1, R11
                OR      0x0004, SR              ; set Carry
                RBRA    _SDBCL_RET, 1
_SDBCL_NO       MOVE    R0, R8
                MOVE    R1, R11
                AND     0xFFFB, SR              ; clear Carry
_SDBCL_RET      DECRB
                RET

; SDB_LBA
; Maps a block index within the file to an absolute SD card LBA.
;
; Input:   R8: pointer to the block map
;          R9/R10: block index lo/hi
; Output:  Carry=1: R9/R10 = LBA lo/hi
;          Carry=0: the block cannot be mapped (use the FAT32 library)
;          R8 unchanged
SDB_LBA         INCRB
                MOVE    R8, R0                  ; R0: map
                MOVE    R9, R1                  ; R1/R2: remaining block idx
                MOVE    R10, R2
                MOVE    @R0, R3                 ; R3: amount of extents
                RBRA    _SDBL_NO, Z

                ; reject anything that is not completely inside the file
                MOVE    R0, R4
                ADD     SDB_M_TBLK_HI, R4
                CMP     R2, @R4
                RBRA    _SDBL_NO, N             ; idx_hi > total_hi
                RBRA    _SDBL_C1, !Z            ; idx_hi < total_hi: inside
                MOVE    R0, R4
                ADD     SDB_M_TBLK_LO, R4
                CMP     R1, @R4
                RBRA    _SDBL_NO, N             ; idx_lo > total_lo
                RBRA    _SDBL_NO, Z             ; idx_lo = total_lo: outside

_SDBL_C1        MOVE    R0, R4
                ADD     SDB_M_EXT, R4           ; R4: current extent
_SDBL_LOOP      MOVE    @R4, R5                 ; R5/R6: blocks in extent
                MOVE    R4, R6
                ADD     SDB_E_NBLK_HI, R6
                MOVE    @R6, R6
                CMP     R2, R6                  ; remainder < extent size?
                RBRA    _SDBL_NEXT, N           ; rem_hi > ext_hi: no
                RBRA    _SDBL_HIT, !Z           ; rem_hi < ext_hi: yes
                CMP     R1, R5
                RBRA    _SDBL_NEXT, N           ; rem_lo > ext_lo: no
                RBRA    _SDBL_NEXT, Z           ; rem_lo = ext_lo: no

_SDBL_HIT       MOVE    R4, R6
                ADD     SDB_E_LBA_LO, R6
                MOVE    @R6++, R9               ; R9/R10: LBA of the extent
                MOVE    @R6, R10
                ADD     R1, R9                  ; plus the remainder
                ADDC    R2, R10
                RBRA    _SDBL_NO, C             ; 32-bit overflow
                OR      0x0004, SR              ; set Carry
                RBRA    _SDBL_RET, 1

_SDBL_NEXT      SUB     R5, R1                  ; remainder -= extent size
                SUBC    R6, R2
                ADD     SDB_E_SIZE, R4          ; next extent
                SUB     1, R3
                RBRA    _SDBL_LOOP, !Z
_SDBL_NO        AND     0xFFFB, SR              ; clear Carry
_SDBL_RET       DECRB
                RET

; Unsigned 32-bit "A >= B" for two little-endian word pairs in memory.
; The answer is returned in the Carry flag and not in N/Z, because RET is
; a MOVE (see sysdef.asm) and a MOVE overwrites N and Z but not the Carry.
; Input:   R8: pointer to A (lo, hi), R9: pointer to B (lo, hi)
; Output:  Carry=1 if A >= B, R8 and R9 unchanged
_SDB_GE32       INCRB
                MOVE    R8, R0
                MOVE    R9, R1
                ADD     1, R0
                ADD     1, R1
                CMP     @R0, @R1                ; high words
                RBRA    _SDB_G32Y, N            ; A_hi > B_hi
                RBRA    _SDB_G32N, !Z           ; A_hi < B_hi
                CMP     @R8, @R9                ; low words
                RBRA    _SDB_G32Y, N
                RBRA    _SDB_G32Y, Z
_SDB_G32N       AND     0xFFFB, SR              ; clear Carry
                RBRA    _SDB_G32R, 1
_SDB_G32Y       OR      0x0004, SR              ; set Carry
_SDB_G32R       DECRB
                RET

; ----------------------------------------------------------------------------
; Building the map
; ----------------------------------------------------------------------------

; SDB_MAP_BUILD
; Walks the FAT cluster chain of an open file once and stores the result as
; an extent table, so that SDB_LBA can map blocks to LBAs afterwards. Costs
; one SD card block read per 128 clusters of the file.
;
; Reads FAT sectors directly and therefore destroys the FAT32 library's
; sector buffer, so it guards and restores it (see THE TWO RULES above). It
; never modifies the file handle: the file position is the same afterwards.
;
; Input:   R8: file handle (FDH)
;          R9: pointer to the block map to be filled
; Output:  none. The map is left invalid (extent count = 0, reason in
;          SDB_M_BAIL) when the file cannot be described, which makes all
;          callers fall back silently.
SDB_MAP_BUILD   SYSCALL(enter, 1)

                MOVE    R8, R0                  ; R0: FDH
                MOVE    R9, R1                  ; R1: map

                MOVE    0, @R1                  ; invalid until proven good
                MOVE    R1, R2
                ADD     SDB_M_BAIL, R2
                MOVE    SDB_B_NOMAP, @R2
                MOVE    SDB_NULL_MAP, R2        ; no real map for this drive?
                CMP     R2, R1
                RBRA    _SDBMB_RET, Z           ; then there is nothing to do

                MOVE    R1, R2
                ADD     SDB_M_FDH, R2
                MOVE    R0, @R2                 ; remember the file handle

                MOVE    SDB_B_NODEV, R8
                RSUB    _SDB_BAIL, 1
                MOVE    R0, R2
                ADD     FAT32$FDH_DEVICE, R2
                MOVE    @R2, R2                 ; R2: device handle
                RBRA    _SDBMB_RET, Z

                MOVE    SDB_B_NOSPC, R8
                RSUB    _SDB_BAIL, 1
                MOVE    R2, R3
                ADD     FAT32$DEV_SECT_PER_CLUS, R3
                MOVE    @R3, R3                 ; R3: sectors per cluster
                RBRA    _SDBMB_RET, Z

                ; total amount of whole 512-byte blocks = filesize / 512
                MOVE    R0, R8
                ADD     FAT32$FDH_SIZE_LO, R8
                MOVE    @R8, R9
                MOVE    R0, R8
                ADD     FAT32$FDH_SIZE_HI, R8
                MOVE    @R8, R10
                RSUB    SDB_B2BLK, 1
                MOVE    R1, R8
                ADD     SDB_M_TBLK_LO, R8
                MOVE    R9, @R8
                MOVE    R1, R8
                ADD     SDB_M_TBLK_HI, R8
                MOVE    R10, @R8
                MOVE    SDB_S_BLEFT, R8         ; blocks still to be mapped
                MOVE    R9, @R8++
                MOVE    R10, @R8

#ifdef SDB_DEBUG
                MOVE    R0, R8                  ; the log helpers take their
                MOVE    R2, R9                  ; arguments in R8..R12, which
                MOVE    R3, R10                 ; are not banked registers
                RSUB    _SDB_LOGBLD, 1
#endif
                MOVE    SDB_B_EMPTY, R8
                RSUB    _SDB_BAIL, 1
                MOVE    SDB_S_BLEFT, R8
                CMP     0, @R8
                RBRA    _SDBMB_C0, !Z
                ADD     1, R8
                CMP     0, @R8
                RBRA    _SDBMB_RET, Z           ; less than one whole block

                ; start cluster of the file
_SDBMB_C0       MOVE    SDB_B_BADSTART, R8
                RSUB    _SDB_BAIL, 1
                MOVE    R0, R8
                ADD     FAT32$FDH_START_CLUS_LO, R8
                MOVE    @R8, R9
                MOVE    R0, R8
                ADD     FAT32$FDH_START_CLUS_HI, R8
                MOVE    @R8, R10
                CMP     0, R10                  ; cluster >= 2?
                RBRA    _SDBMB_C1, !Z
                CMP     1, R9
                RBRA    _SDBMB_RET, N           ; cluster = 0: unusable
                RBRA    _SDBMB_RET, Z           ; cluster = 1: unusable
_SDBMB_C1       MOVE    SDB_S_CLU, R8
                MOVE    R9, @R8++
                MOVE    R10, @R8

                ; from here on the SD controller buffer gets destroyed, so
                ; make sure we can put it back before touching anything
                MOVE    SDB_B_GUARD, R8
                RSUB    _SDB_BAIL, 1
                RSUB    SDB_GUARD_IN, 1
                RBRA    _SDBMB_RET, !C

                MOVE    SDB_S_FCVAL, R8         ; FAT sector cache is empty
                MOVE    0, @R8

                XOR     R4, R4                  ; R4: amount of extents
                MOVE    R1, R5
                ADD     SDB_M_EXT, R5           ; R5: next extent to write

                ; ---- outer loop: one iteration per extent
_SDBMB_EXT      MOVE    SDB_B_FRAG, R8
                RSUB    _SDB_BAIL, 1
                MOVE    SDB_MAX_EXT, R8
                CMP     R4, R8                  ; still room for an extent?
                RBRA    _SDBMB_OUT, N           ; cannot happen
                RBRA    _SDBMB_OUT, Z           ; no: file is too fragmented

                MOVE    SDB_S_CLU, R8           ; remember the first cluster
                MOVE    SDB_S_RSTART, R9        ; of this extent
                MOVE    @R8++, @R9++
                MOVE    @R8, @R9

                MOVE    SDB_S_RBLK, R8          ; blocks in this extent = 0
                MOVE    0, @R8++
                MOVE    0, @R8

                ; ---- inner loop: follow physically consecutive clusters
_SDBMB_RUN      MOVE    SDB_S_RBLK, R8          ; blocks += sectors/cluster
                MOVE    R3, R9
                ADD     R9, @R8++
                ADDC    0, @R8

                MOVE    SDB_S_RBLK, R8          ; blocks >= blocks left?
                MOVE    SDB_S_BLEFT, R9
                RSUB    _SDB_GE32, 1
                RBRA    _SDBMB_LAST, C          ; yes: this is the last extent

                MOVE    SDB_B_FATERR, R8
                RSUB    _SDB_BAIL, 1
                MOVE    SDB_S_CLU, R8           ; next cluster from the FAT
                MOVE    @R8++, R9
                MOVE    @R8, R10
                MOVE    R2, R8
                RSUB    SDB_FAT_NEXT, 1
                RBRA    _SDBMB_OUT, !C          ; read error: no map

                MOVE    SDB_B_BADCLUS, R8
                RSUB    _SDB_BAIL, 1
                CMP     0, R10                  ; free or reserved cluster?
                RBRA    _SDBMB_N1, !Z
                CMP     1, R9
                RBRA    _SDBMB_OUT, N           ; cluster = 0: unusable
                RBRA    _SDBMB_OUT, Z           ; cluster = 1: unusable
_SDBMB_N1       MOVE    SDB_B_SHORT, R8
                RSUB    _SDB_BAIL, 1
                CMP     SDB_EOC_HI, R10         ; end of chain?
                RBRA    _SDBMB_N2, !Z
                CMP     R9, SDB_EOC_LO
                RBRA    _SDBMB_OUT, N           ; chain shorter than the file
                RBRA    _SDBMB_OUT, Z
_SDBMB_N2       MOVE    SDB_S_NEXT, R8
                MOVE    R9, @R8++
                MOVE    R10, @R8

                ; physically consecutive? then extend the current run
                MOVE    SDB_S_CLU, R8
                MOVE    @R8++, R11
                MOVE    @R8, R12
                ADD     1, R11
                ADDC    0, R12
                CMP     R11, R9
                RBRA    _SDBMB_BRK, !Z
                CMP     R12, R10
                RBRA    _SDBMB_BRK, !Z
                MOVE    SDB_S_CLU, R8           ; yes: advance and continue
                MOVE    R9, @R8++
                MOVE    R10, @R8
                RBRA    _SDBMB_RUN, 1

                ; ---- the run ends here, but the file continues
_SDBMB_BRK      MOVE    SDB_S_RBLK, R8          ; extent size = run size
                MOVE    @R8++, R6
                MOVE    @R8, R7
                MOVE    SDB_B_LBA, R8
                RSUB    _SDB_BAIL, 1
                RSUB    _SDB_EMIT, 1
                RBRA    _SDBMB_OUT, !C
                MOVE    SDB_S_BLEFT, R8         ; blocks left -= extent size
                SUB     R6, @R8++
                SUBC    R7, @R8
                MOVE    SDB_S_NEXT, R8          ; continue with the cluster..
                MOVE    SDB_S_CLU, R9           ; ..that broke the run
                MOVE    @R8++, @R9++
                MOVE    @R8, @R9
                ADD     1, R4
                ADD     SDB_E_SIZE, R5
                RBRA    _SDBMB_EXT, 1

                ; ---- the current run covers the rest of the file
_SDBMB_LAST     MOVE    SDB_S_BLEFT, R8         ; extent size = blocks left
                MOVE    @R8++, R6
                MOVE    @R8, R7
                MOVE    SDB_B_LBA, R8
                RSUB    _SDB_BAIL, 1
                RSUB    _SDB_EMIT, 1
                RBRA    _SDBMB_OUT, !C
                ADD     1, R4
                MOVE    R4, @R1                 ; map is complete and valid
                MOVE    R1, R8
                ADD     SDB_M_BAIL, R8
                MOVE    SDB_B_OK, @R8

                ; ---- put the library's sector buffer back
_SDBMB_OUT      RSUB    SDB_GUARD_OUT, 1
_SDBMB_RET
#ifdef SDB_DEBUG
                MOVE    R1, R8
                RSUB    _SDB_LOGMAP, 1
#endif
                SYSCALL(leave, 1)
                RET

; Stores a bail-out reason in the map, so that the reason survives even
; without the serial log. Runs in SDB_MAP_BUILD's own register bank (R1 is
; the map there) and must not disturb any register, hence the stack.
; Input: R1 = map, R8 = reason. Output: everything unchanged.
_SDB_BAIL       MOVE    R9, @--SP
                MOVE    R1, R9
                ADD     SDB_M_BAIL, R9
                MOVE    R8, @R9
                MOVE    @SP++, R9
                RET

; Writes one extent: R6/R7 = amount of blocks, SDB_S_RSTART = first cluster,
; R5 = destination, R2 = device handle.
; Output: Carry=1 if the extent is usable. Clobbers R8..R12, leaves R0..R7.
_SDB_EMIT       MOVE    SDB_S_RSTART, R8
                MOVE    @R8++, R9
                MOVE    @R8, R10
                XOR     R11, R11                ; sector 0 within the cluster
                MOVE    R2, R8
                RSUB    SDB_CLULBA, 1
                RBRA    _SDB_EMIT_R, !C         ; Carry is already clear

                MOVE    R5, R8
                MOVE    R6, @R8
                MOVE    R5, R8
                ADD     SDB_E_NBLK_HI, R8
                MOVE    R7, @R8
                MOVE    R5, R8
                ADD     SDB_E_LBA_LO, R8
                MOVE    R9, @R8++
                MOVE    R10, @R8
                OR      0x0004, SR              ; set Carry
_SDB_EMIT_R     RET

; SDB_FAT_NEXT
; Reads the FAT32 chain successor of a cluster. Uses a one entry cache for
; the FAT sector, so a run of consecutive clusters costs one SD card block
; read per 128 clusters. Expects SDB_GUARD_IN to have been called.
;
; Input:   R8: device handle
;          R9/R10: cluster lo/hi
; Output:  Carry=1: R9/R10 = successor cluster lo/hi (28 bit)
;          Carry=0: the FAT sector could not be read
;          R8 unchanged
SDB_FAT_NEXT    INCRB
                MOVE    R8, R0                  ; R0: device handle
                MOVE    R9, R1                  ; R1: byte offset in sector
                AND     0x007F, R1              ; 128 FAT entries per sector
                AND     0xFFFD, SR              ; clear X
                SHL     2, R1                   ; 4 bytes per entry

                ; FAT sector number = cluster / 128
                MOVE    R10, R2
                AND     0x007F, R2
                AND     0xFFFD, SR
                SHL     9, R2
                AND     0xFFFB, SR              ; clear C
                SHR     7, R9
                ADD     R2, R9
                AND     0xFFFB, SR
                SHR     7, R10

                MOVE    R0, R2                  ; plus the FAT start LBA
                ADD     FAT32$DEV_FAT_LO, R2
                MOVE    @R2++, R3
                MOVE    @R2, R2
                ADD     R3, R9
                ADDC    R2, R10
                RBRA    _SDB_FN_ERR, C          ; 32-bit overflow

                ; is this sector already in the hardware buffer?
                MOVE    SDB_S_FCVAL, R2
                CMP     0, @R2
                RBRA    _SDB_FN_RD, Z
                MOVE    SDB_S_FCLBA, R2
                CMP     @R2, R9
                RBRA    _SDB_FN_RD, !Z
                ADD     1, R2
                CMP     @R2, R10
                RBRA    _SDB_FN_BUF, Z

_SDB_FN_RD      MOVE    SDB_S_FCVAL, R2         ; cache is stale in any case
                MOVE    0, @R2
                MOVE    R9, R2                  ; R2/R3: remember the LBA
                MOVE    R10, R3
                MOVE    R2, R8
                MOVE    R3, R9
                RSUB    SDB_SDRD, 1
                CMP     0, R8
                RBRA    _SDB_FN_SDE, !Z
                MOVE    SDB_S_FCLBA, R8
                MOVE    R2, @R8++
                MOVE    R3, @R8
                MOVE    SDB_S_FCVAL, R8
                MOVE    1, @R8

                ; read the 32-bit little-endian FAT entry. Keep one
                ; instruction between writing IO$SD_DATA_POS and reading
                ; IO$SD_DATA, exactly like SD$READ_BYTE does: the buffer is a
                ; block RAM whose output is registered (see byte_bram.vhd).
_SDB_FN_BUF     MOVE    IO$SD_DATA_POS, R2
                MOVE    IO$SD_DATA, R3
                MOVE    R1, R4                  ; R4: walking byte offset
                MOVE    R4, @R2
                ADD     1, R4                   ; spacing, and the next offset
                MOVE    @R3, R9                 ; byte 0
                MOVE    R4, @R2
                ADD     1, R4
                MOVE    @R3, R5                 ; byte 1
                AND     0xFFFD, SR
                SHL     8, R5
                ADD     R5, R9
                MOVE    R4, @R2
                ADD     1, R4
                MOVE    @R3, R10                ; byte 2
                MOVE    R4, @R2
                ADD     1, R4
                MOVE    @R3, R5                 ; byte 3
                AND     0xFFFD, SR
                SHL     8, R5
                ADD     R5, R10
                AND     0x0FFF, R10             ; FAT32 entries are 28 bit
                MOVE    R0, R8
                OR      0x0004, SR              ; set Carry
                RBRA    _SDB_FN_RET, 1

_SDB_FN_SDE     RSUB    SDB_SDERR, 1
_SDB_FN_ERR     MOVE    R0, R8
                AND     0xFFFB, SR              ; clear Carry
_SDB_FN_RET     DECRB
                RET

; ----------------------------------------------------------------------------
; Block transfers
; ----------------------------------------------------------------------------

; SDB_SD2VD
; Copies the 512 bytes in the buffer of the SD controller into the internal
; block buffer of a virtual drive. Device and 4k window selection are hoisted
; out of the loop, which is what makes this about twenty times faster than
; the original per-byte VD_CAD_WRITE sequence.
;
; Input:   R8: virtual drive number (only used for the vdrives device select)
; Output:  none, all registers unchanged
SDB_SD2VD       INCRB
                MOVE    M2M$RAMROM_DEV, R0
                MOVE    VDRIVES_DEVICE, R1
                MOVE    @R1, @R0                ; select the vdrives device
                MOVE    M2M$RAMROM_4KWIN, R0
                MOVE    VD_WIN_CAD, @R0         ; control and data registers

                MOVE    IO$SD_DATA_POS, R0
                MOVE    IO$SD_DATA, R1
                MOVE    VD_B_ADDR, R2
                MOVE    VD_B_DOUT, R3
                MOVE    VD_B_WREN, R4
                XOR     R5, R5
_SDB_S2V_L      MOVE    R5, @R0                 ; position in the SD buffer
                MOVE    R5, @R2                 ; address in the drive buffer
                MOVE    @R1, @R3                ; the byte itself
                MOVE    1, @R4                  ; strobe write enable
                MOVE    0, @R4
                ADD     1, R5
                CMP     0x0200, R5
                RBRA    _SDB_S2V_L, !Z
                DECRB
                RET

; SDB_VD2SD
; Copies the 512 bytes from the internal block buffer of a virtual drive into
; the buffer of the SD controller. The drive buffer address register lives in
; the control/data window while the data register lives in the drive window,
; so the window selector has to be toggled per byte; the device selection is
; still hoisted out of the loop.
;
; Input:   R8: virtual drive number
; Output:  none, all registers unchanged
SDB_VD2SD       INCRB
                MOVE    M2M$RAMROM_DEV, R0
                MOVE    VDRIVES_DEVICE, R1
                MOVE    @R1, @R0                ; select the vdrives device

                MOVE    M2M$RAMROM_4KWIN, R0    ; R0: window selector
                MOVE    VD_WIN_DRV, R1
                ADD     R8, R1                  ; R1: window of this drive
                MOVE    IO$SD_DATA_POS, R2
                MOVE    IO$SD_DATA, R3
                MOVE    VD_B_ADDR, R4
                MOVE    VD_B_DIN, R5
                XOR     R6, R6
_SDB_V2S_L      MOVE    VD_WIN_CAD, @R0         ; control and data registers
                MOVE    R6, @R4                 ; address in the drive buffer
                MOVE    R1, @R0                 ; drive specific registers
                MOVE    R6, @R2                 ; position in the SD buffer
                MOVE    @R5, @R3                ; the byte itself
                ADD     1, R6
                CMP     0x0200, R6
                RBRA    _SDB_V2S_L, !Z
                DECRB
                RET

; SDB_SD2DEV
; Copies the 512 bytes in the buffer of the SD controller into an M2M byte
; streaming device (a CRT/ROM load target), handling the 4k window boundary.
;
; Input:   R8: target device id
;          R9: target 4k window
;         R10: target address within the window (M2M$RAMROM_DATA based)
; Output:  R9/R10: window and address behind the last written byte
;          R8 unchanged
SDB_SD2DEV      INCRB
                MOVE    M2M$RAMROM_DEV, R0
                MOVE    R8, @R0
                MOVE    M2M$RAMROM_4KWIN, R0    ; R0: window selector
                MOVE    R9, @R0
                MOVE    IO$SD_DATA_POS, R1
                MOVE    IO$SD_DATA, R2
                MOVE    M2M$RAMROM_DATA, R3
                ADD     0x1000, R3              ; R3: end of window marker
                XOR     R4, R4                  ; R4: position in the SD buf
                MOVE    0x0200, R5              ; R5: bytes still to go
                ; One instruction has to sit between writing IO$SD_DATA_POS
                ; and reading IO$SD_DATA, exactly like SD$READ_BYTE does: the
                ; buffer is a block RAM with a registered output, see
                ; M2M/QNICE/vhdl/byte_bram.vhd. The ADD below is that
                ; instruction and does useful work at the same time.
_SDB_S2D_L      MOVE    R4, @R1                 ; position in the SD buffer
                ADD     1, R4
                MOVE    @R2, @R10++             ; the byte itself
                CMP     R3, R10                 ; 4k window boundary?
                RBRA    _SDB_S2D_1, !Z          ; no
                MOVE    M2M$RAMROM_DATA, R10    ; yes: next window
                ADD     1, R9
                MOVE    R9, @R0
_SDB_S2D_1      SUB     1, R5
                RBRA    _SDB_S2D_L, !Z
                DECRB
                RET

; ----------------------------------------------------------------------------
; High level entry points
; ----------------------------------------------------------------------------

; SDB_VD_RDBLK
; Prepares one virtual drive block read: maps the byte position to an LBA and
; reads that block into the buffer of the SD controller. On success the
; caller acknowledges sd_rd_i and then calls SDB_SD2VD.
;
; Input:   R8: virtual drive number
;          R9: file handle of the disk image
;         R10/R11: byte position within the image, lo/hi
;         R12: amount of bytes the core asked for
; Output:  Carry=1: the block is in the buffer of the SD controller
;          Carry=0: use the FAT32 library path instead
;          R8 .. R12 unchanged
SDB_VD_RDBLK    INCRB
                MOVE    R8, R0
                MOVE    R9, R1
                MOVE    R10, R2
                MOVE    R11, R3
                MOVE    R12, R4
                RSUB    _SDB_PREP, 1            ; R9/R10: LBA
                RBRA    _SDB_VRD_NO, !C
                MOVE    R9, R5                  ; R5/R6: LBA
                MOVE    R10, R6
                RSUB    SDB_GUARD_IN, 1         ; can we put the buffer back?
                RBRA    _SDB_VRD_GRD, !C        ; no: nothing was touched
                MOVE    R5, R8
                MOVE    R6, R9
                RSUB    SDB_SDRD, 1
                CMP     0, R8
                RBRA    _SDB_VRD_SDE, !Z        ; SD error: try the slow path
                MOVE    R0, R8
                OR      0x0004, SR              ; set Carry
                RBRA    _SDB_VRD_R, 1
_SDB_VRD_SDE    RSUB    SDB_SDERR, 1
                RSUB    SDB_GUARD_OUT, 1
                MOVE    SDB_RD_STAT, R8
                MOVE    SDB_R_SDERR, @R8
                RBRA    _SDB_VRD_NO, 1
_SDB_VRD_GRD    MOVE    SDB_RD_STAT, R8
                MOVE    SDB_R_GUARD, @R8
_SDB_VRD_NO     MOVE    R0, R8
                AND     0xFFFB, SR              ; clear Carry
_SDB_VRD_R      MOVE    R1, R9
                MOVE    R2, R10
                MOVE    R3, R11
                MOVE    R4, R12
                DECRB
                RET

; SDB_VD_RDDONE
; Called by HANDLE_DRV_RD after SDB_SD2VD has emptied the buffer: puts the
; FAT32 library's sector back into it.
;
; Input:   none
; Output:  none, all registers unchanged
SDB_VD_RDDONE   RSUB    SDB_GUARD_OUT, 1
                RET

; SDB_VD_WRBLK
; Writes one virtual drive block: maps the byte position to an LBA, copies
; the internal block buffer of the drive into the buffer of the SD controller
; and writes it. The caller acknowledges sd_wr_i afterwards.
;
; Input:   R8: virtual drive number
;          R9: file handle of the disk image
;         R10/R11: byte position within the image, lo/hi
;         R12: amount of bytes the core wants to write
; Output:  Carry=1: the block has been written to the SD card
;          Carry=0: nothing was written, use the FAT32 library path instead
;          R8 .. R12 unchanged
SDB_VD_WRBLK    INCRB
                MOVE    R8, R0
                MOVE    R9, R1
                MOVE    R10, R2
                MOVE    R11, R3
                MOVE    R12, R4
                RSUB    _SDB_PREP, 1            ; R9/R10: LBA
                RBRA    _SDB_VWR_NO, !C
                MOVE    R9, R5                  ; R5/R6: LBA
                MOVE    R10, R6
                RSUB    SDB_GUARD_IN, 1         ; can we put the buffer back?
                RBRA    _SDB_VWR_GRD, !C        ; no: nothing was touched
                MOVE    R0, R8
                RSUB    SDB_VD2SD, 1
                MOVE    R5, R8
                MOVE    R6, R9
                RSUB    SDB_SDWR, 1
                CMP     0, R8
                RBRA    _SDB_VWR_SDE, !Z
                RSUB    SDB_GUARD_OUT, 1        ; the write is done, restore
                MOVE    R0, R8
                OR      0x0004, SR              ; set Carry
                RBRA    _SDB_VWR_R, 1
_SDB_VWR_SDE    RSUB    SDB_SDERR, 1            ; SD error: try the slow path
                RSUB    SDB_GUARD_OUT, 1
                MOVE    SDB_RD_STAT, R8
                MOVE    SDB_R_SDERR, @R8
                RBRA    _SDB_VWR_NO, 1
_SDB_VWR_GRD    MOVE    SDB_RD_STAT, R8
                MOVE    SDB_R_GUARD, @R8
_SDB_VWR_NO     MOVE    R0, R8
                AND     0xFFFB, SR              ; clear Carry
_SDB_VWR_R      MOVE    R1, R9
                MOVE    R2, R10
                MOVE    R3, R11
                MOVE    R4, R12
                DECRB
                RET

; Common preparation for SDB_VD_RDBLK / SDB_VD_WRBLK. Expects the inputs in
; the caller's R0 (drive), R1 (FDH), R2/R3 (byte position) and R4 (amount of
; bytes) and returns Carry=1 plus the LBA in R9/R10. Runs in the caller's
; register bank on purpose. Touches nothing outside our own variables.
_SDB_PREP       MOVE    SDB_RD_STAT, R11
                MOVE    SDB_R_SIZE, @R11
                MOVE    0x0200, R8
                CMP     R4, R8                  ; exactly one block?
                RBRA    _SDB_PREP_NO, !Z        ; no: let the FAT32 path do
                MOVE    SDB_R_ALIGN, @R11       ; ..partial/multi blocks
                MOVE    R2, R8
                AND     0x01FF, R8              ; block aligned?
                RBRA    _SDB_PREP_NO, !Z        ; no
                MOVE    SDB_R_MAP, @R11
                MOVE    R0, R8
                RSUB    SDB_VDMAP, 1
                MOVE    R8, R12                 ; R12: map (R11 stays the..
                MOVE    R1, R9                  ; ..status pointer)
                RSUB    SDB_CHECK, 1
                RBRA    _SDB_PREP_NO, !C
                MOVE    SDB_R_RANGE, @R11
                MOVE    R2, R9
                MOVE    R3, R10
                RSUB    SDB_B2BLK, 1
                MOVE    R12, R8
                RSUB    SDB_LBA, 1
                RBRA    _SDB_PREP_NO, !C
                MOVE    SDB_RD_LBA, R8          ; remember it for the log
                MOVE    R9, @R8++
                MOVE    R10, @R8
                MOVE    SDB_R_OK, @R11
                OR      0x0004, SR              ; set Carry
                RET
_SDB_PREP_NO    AND     0xFFFB, SR              ; clear Carry
                RET

; SDB_FREAD_FAST
; Streams whole 512-byte blocks of a mapped file directly from the SD card
; into an M2M byte streaming device and then positions the file handle right
; behind them, so that the caller's byte loop reads the rest as usual.
;
; It deliberately stops one whole block short of the end of the file, so that
; the position it hands over is always strictly inside the file and the
; caller reaches EOF through the FAT32 library, exactly as before.
;
; The final f32_fseek is what restores the library: a seek unconditionally
; re-reads the sector into the hardware buffer and re-claims ownership, so
; afterwards the library is in a state it produced itself. If anything at all
; goes wrong the file position is put back where it was and Carry=0 is
; returned, i.e. the caller sees "nothing happened".
;
; Input:   R8: file handle (FDH)
;          R9: pointer to the block map
;         R10: target device id
;         R11: target 4k window
;         R12: target address within the window
; Output:  Carry=1: R11/R12 updated, the file position is behind the data
;          Carry=0: nothing was transferred, the file position is unchanged
;                   and R11/R12 are unchanged
SDB_FREAD_FAST  INCRB
                MOVE    R8, R0                  ; R0: FDH
                MOVE    R9, R1                  ; R1: map
                MOVE    R10, R2                 ; R2: target device
                MOVE    R11, R3                 ; R3: target 4k window
                MOVE    R12, R4                 ; R4: target address

                MOVE    SDB_FF_STAT, R8
                MOVE    SDB_B_NOMAP, @R8
                MOVE    SDB_FF_BLKS, R8
                MOVE    0, @R8

                MOVE    R1, R8
                MOVE    R0, R9
                RSUB    SDB_CHECK, 1
                RBRA    _SDBFF_NO, !C

                ; only from the very beginning of the file
                MOVE    R0, R8
                ADD     FAT32$FDH_ACCESS_LO, R8
                CMP     0, @R8
                RBRA    _SDBFF_NO, !Z
                MOVE    R0, R8
                ADD     FAT32$FDH_ACCESS_HI, R8
                CMP     0, @R8
                RBRA    _SDBFF_NO, !Z

                ; how many whole blocks do we take? Always one less than the
                ; file has, so that the handover position is strictly inside
                ; the file and the caller still reaches EOF through the
                ; library. A CRT/ROM file is never 32 MB or larger, so one
                ; word of block count is plenty and anything else is refused.
                MOVE    R1, R8
                ADD     SDB_M_TBLK_HI, R8
                CMP     0, @R8
                RBRA    _SDBFF_NO, !Z
                MOVE    R1, R8
                ADD     SDB_M_TBLK_LO, R8
                MOVE    @R8, R7                 ; R7: blocks still to do
                SUB     1, R7
                RBRA    _SDBFF_NO, Z            ; a one block file: byte loop
                RBRA    _SDBFF_NO, N            ; cannot happen: TBLK was 0

                MOVE    SDB_FF_STAT, R8
                MOVE    SDB_B_GUARD, @R8
                RSUB    SDB_GUARD_IN, 1         ; nothing touched if it fails
                RBRA    _SDBFF_NO, !C

                XOR     R5, R5                  ; R5/R6: block index
                XOR     R6, R6

_SDBFF_LOOP     CMP     0, R7
                RBRA    _SDBFF_DONE, Z
                MOVE    R1, R8
                MOVE    R5, R9
                MOVE    R6, R10
                RSUB    SDB_LBA, 1
                RBRA    _SDBFF_DONE, !C
#ifdef SDB_DEBUG
                MOVE    R5, R8                  ; R9/R10 are already the LBA
                RSUB    _SDB_LOGBLK, 1
#endif
                MOVE    R9, R8
                MOVE    R10, R9
                RSUB    SDB_SDRD, 1
                CMP     0, R8
                RBRA    _SDBFF_SDE, !Z          ; SD error: stop here
                MOVE    R2, R8
                MOVE    R3, R9
                MOVE    R4, R10
                RSUB    SDB_SD2DEV, 1
                MOVE    R9, R3
                MOVE    R10, R4
                ADD     1, R5
                ADDC    0, R6
                SUB     1, R7
                RBRA    _SDBFF_LOOP, 1

_SDBFF_SDE      RSUB    SDB_SDERR, 1

                ; the hardware buffer is ours now; whatever we do next, the
                ; library has to be put back. A seek does that properly.
_SDBFF_DONE     MOVE    SDB_FF_BLKS, R8
                MOVE    R5, @R8
                CMP     0, R5                   ; anything transferred?
                RBRA    _SDBFF_SEEK, !Z
                CMP     0, R6
                RBRA    _SDBFF_REW, Z           ; no: just put it back

_SDBFF_SEEK     MOVE    SDB_FF_STAT, R8
                MOVE    SDB_B_SEEK, @R8
                MOVE    R5, R9                  ; file position = blocks * 512
                MOVE    R6, R10
                RSUB    SDB_BLK2B, 1
                MOVE    R9, R11                 ; R11/R12: expected position
                MOVE    R10, R12
                MOVE    R0, R8
                SYSCALL(f32_fseek, 1)
                CMP     0, R9                   ; seek reported success?
                RBRA    _SDBFF_REW, !Z
                MOVE    R0, R8                  ; ..and actually got there?
                ADD     FAT32$FDH_ACCESS_LO, R8
                CMP     @R8, R11
                RBRA    _SDBFF_REW, !Z
                MOVE    R0, R8
                ADD     FAT32$FDH_ACCESS_HI, R8
                CMP     @R8, R12
                RBRA    _SDBFF_REW, !Z

                MOVE    SDB_FF_STAT, R8
                MOVE    SDB_B_OK, @R8
                RSUB    SDB_GUARD_CLR, 1        ; the seek put the library..
                MOVE    R3, R11                 ; ..back, nobody to tell
                MOVE    R4, R12
                OR      0x0004, SR              ; set Carry
                RBRA    _SDBFF_RET, 1

                ; Put the file back to the start and report "nothing done".
                ; The caller has not seen the updated target pointers, so it
                ; simply overwrites whatever we already transferred. The seek
                ; also restores the library's sector buffer; if even that
                ; fails, the buffer is marked unknown.
_SDBFF_REW      MOVE    R0, R8
                XOR     R9, R9
                XOR     R10, R10
                SYSCALL(f32_fseek, 1)
                CMP     0, R9
                RBRA    _SDBFF_RW1, !Z
                RSUB    SDB_GUARD_CLR, 1        ; the rewind put it back
                RBRA    _SDBFF_NO, 1
_SDBFF_RW1      RSUB    SDB_ORPHAN, 1           ; not even that worked

_SDBFF_NO       AND     0xFFFB, SR              ; clear Carry
_SDBFF_RET
#ifdef SDB_DEBUG
                ; the logging calls destroy the flags, so carry the result
                ; over them by hand
                MOVE    0, R7
                RBRA    _SDBFF_LG0, !C
                MOVE    1, R7
_SDBFF_LG0      MOVE    R0, R8
                MOVE    R3, R9
                MOVE    R4, R10
                RSUB    _SDB_LOGFF, 1
                CMP     0, R7
                RBRA    _SDBFF_LG1, Z
                OR      0x0004, SR
                RBRA    _SDBFF_LG2, 1
_SDBFF_LG1      AND     0xFFFB, SR
_SDBFF_LG2
#endif
                DECRB
                RET

; ----------------------------------------------------------------------------
; Serial logging (only assembled when SDB_DEBUG is defined at the top)
; ----------------------------------------------------------------------------

#ifdef SDB_DEBUG

; R8: zero terminated string
SDB_LOGS        SYSCALL(enter, 1)
                SYSCALL(puts, 1)
                SYSCALL(leave, 1)
                RET

; R8: word, printed as four hex digits
SDB_LOGH        SYSCALL(enter, 1)
                SYSCALL(puthex, 1)
                SYSCALL(leave, 1)
                RET

; R8/R9: hi/lo of a 32 bit value
SDB_LOGH32      SYSCALL(enter, 1)
                SYSCALL(puthex, 1)
                MOVE    R9, R8
                SYSCALL(puthex, 1)
                SYSCALL(leave, 1)
                RET

SDB_LOGNL       SYSCALL(enter, 1)
                SYSCALL(crlf, 1)
                SYSCALL(leave, 1)
                RET

; map build entry: R8 = FDH, R9 = device handle, R10 = sectors per cluster
_SDB_LOGBLD     SYSCALL(enter, 1)
                MOVE    R8, R0                  ; R8..R12 survive the INCRB
                MOVE    R9, R1                  ; inside SYSCALL(enter), so
                MOVE    R10, R2                 ; they are safe to copy here
                MOVE    SDB_L_BLD, R8
                RSUB    SDB_LOGS, 1
                MOVE    R0, R8
                RSUB    SDB_LOGH, 1
                MOVE    SDB_L_DEV, R8
                RSUB    SDB_LOGS, 1
                MOVE    R1, R8
                RSUB    SDB_LOGH, 1
                MOVE    SDB_L_SPC, R8
                RSUB    SDB_LOGS, 1
                MOVE    R2, R8
                RSUB    SDB_LOGH, 1
                MOVE    SDB_L_SIZE, R8
                RSUB    SDB_LOGS, 1
                MOVE    R0, R8
                ADD     FAT32$FDH_SIZE_HI, R8
                MOVE    @R8, R8
                MOVE    R0, R9
                ADD     FAT32$FDH_SIZE_LO, R9
                MOVE    @R9, R9
                RSUB    SDB_LOGH32, 1
                MOVE    SDB_L_CLUS, R8
                RSUB    SDB_LOGS, 1
                MOVE    R0, R8
                ADD     FAT32$FDH_START_CLUS_HI, R8
                MOVE    @R8, R8
                MOVE    R0, R9
                ADD     FAT32$FDH_START_CLUS_LO, R9
                MOVE    @R9, R9
                RSUB    SDB_LOGH32, 1
                RSUB    SDB_LOGNL, 1
                SYSCALL(leave, 1)
                RET

; map build result: R8 = map
_SDB_LOGMAP     SYSCALL(enter, 1)
                MOVE    R8, R0
                MOVE    SDB_L_MAP, R8
                RSUB    SDB_LOGS, 1
                MOVE    @R0, R8                 ; extents
                RSUB    SDB_LOGH, 1
                MOVE    SDB_L_TBLK, R8
                RSUB    SDB_LOGS, 1
                MOVE    R0, R8
                ADD     SDB_M_TBLK_HI, R8
                MOVE    @R8, R8
                MOVE    R0, R9
                ADD     SDB_M_TBLK_LO, R9
                MOVE    @R9, R9
                RSUB    SDB_LOGH32, 1
                MOVE    SDB_L_LBA0, R8
                RSUB    SDB_LOGS, 1
                MOVE    R0, R8
                ADD     SDB_M_EXT, R8
                ADD     SDB_E_LBA_HI, R8
                MOVE    @R8, R8
                MOVE    R0, R9
                ADD     SDB_M_EXT, R9
                ADD     SDB_E_LBA_LO, R9
                MOVE    @R9, R9
                RSUB    SDB_LOGH32, 1
                MOVE    SDB_L_BAIL, R8
                RSUB    SDB_LOGS, 1
                MOVE    R0, R8
                ADD     SDB_M_BAIL, R8
                MOVE    @R8, R8
                RSUB    SDB_LOGH, 1
                RSUB    SDB_LOGNL, 1
                SYSCALL(leave, 1)
                RET

; one block of SDB_FREAD_FAST: R8 = block index, R9/R10 = LBA lo/hi
_SDB_LOGBLK     SYSCALL(enter, 1)
                MOVE    R8, R0
                MOVE    R9, R1
                MOVE    R10, R2
                MOVE    SDB_L_BLK, R8
                RSUB    SDB_LOGS, 1
                MOVE    R0, R8
                RSUB    SDB_LOGH, 1
                MOVE    SDB_L_ARROW, R8
                RSUB    SDB_LOGS, 1
                MOVE    R2, R8
                MOVE    R1, R9
                RSUB    SDB_LOGH32, 1
                RSUB    SDB_LOGNL, 1
                SYSCALL(leave, 1)
                RET

; SDB_FREAD_FAST result: R8 = FDH, R9 = 4k window, R10 = address
_SDB_LOGFF      SYSCALL(enter, 1)
                MOVE    R8, R0
                MOVE    R9, R3
                MOVE    R10, R4
                MOVE    SDB_L_FF, R8
                RSUB    SDB_LOGS, 1
                MOVE    SDB_FF_STAT, R8
                MOVE    @R8, R8
                RSUB    SDB_LOGH, 1
                MOVE    SDB_L_BLKS, R8
                RSUB    SDB_LOGS, 1
                MOVE    SDB_FF_BLKS, R8
                MOVE    @R8, R8
                RSUB    SDB_LOGH, 1
                MOVE    SDB_L_WIN, R8
                RSUB    SDB_LOGS, 1
                MOVE    R3, R8
                RSUB    SDB_LOGH, 1
                MOVE    SDB_L_ADR, R8
                RSUB    SDB_LOGS, 1
                MOVE    R4, R8
                RSUB    SDB_LOGH, 1
                MOVE    SDB_L_POS, R8
                RSUB    SDB_LOGS, 1
                MOVE    R0, R8
                ADD     FAT32$FDH_ACCESS_HI, R8
                MOVE    @R8, R8
                MOVE    R0, R9
                ADD     FAT32$FDH_ACCESS_LO, R9
                MOVE    @R9, R9
                RSUB    SDB_LOGH32, 1
                MOVE    SDB_L_CLS, R8
                RSUB    SDB_LOGS, 1
                MOVE    R0, R8
                ADD     FAT32$FDH_CLUSTER_HI, R8
                MOVE    @R8, R8
                MOVE    R0, R9
                ADD     FAT32$FDH_CLUSTER_LO, R9
                MOVE    @R9, R9
                RSUB    SDB_LOGH32, 1
                MOVE    SDB_L_SEC, R8
                RSUB    SDB_LOGS, 1
                MOVE    R0, R8
                ADD     FAT32$FDH_SECTOR, R8
                MOVE    @R8, R8
                RSUB    SDB_LOGH, 1
                RSUB    SDB_LOGNL, 1
                SYSCALL(leave, 1)
                RET

SDB_L_BLD       .ASCII_W "SDB: build fdh="
SDB_L_DEV       .ASCII_W " dev="
SDB_L_SPC       .ASCII_W " spc="
SDB_L_SIZE      .ASCII_W " size="
SDB_L_CLUS      .ASCII_W " clus="
SDB_L_MAP       .ASCII_W "SDB: map ext="
SDB_L_TBLK      .ASCII_W " tblk="
SDB_L_LBA0      .ASCII_W " lba0="
SDB_L_BAIL      .ASCII_W " bail="
SDB_L_BLK       .ASCII_W "SDB: blk "
SDB_L_ARROW     .ASCII_W " -> lba "
SDB_L_FF        .ASCII_W "SDB: ff stat="
SDB_L_BLKS      .ASCII_W " blks="
SDB_L_WIN       .ASCII_W " win="
SDB_L_ADR       .ASCII_W " adr="
SDB_L_POS       .ASCII_W " pos="
SDB_L_CLS       .ASCII_W " cluster="
SDB_L_SEC       .ASCII_W " sector="
; ----------------------------------------------------------------------------
; Per request logging for the virtual drives
;
; This is the measurement that tells the two possible explanations of a slow
; virtual drive apart: either the fast path is refused (st= is not 0000) or
; it is taken and the time goes somewhere else. "fw" is the time spent inside
; HANDLE_DRV_RD, "gap" the time between the end of the previous request and
; the start of this one, both in QNICE clock cycles, i.e. 50,000 cycles per
; millisecond. Everything the firmware can influence is in "fw"; everything
; else - the core, the bridge, the poll interval of the Shell main loop - is
; in "gap".
;
; The first 8 requests after a mount are logged, plus one in every 512 after
; that, so that the steady state is visible without flooding the serial line.
; ----------------------------------------------------------------------------

; Arm the log for the next 8 block requests, and say which drive was mounted
; and with which buffer device id, so that "is this drive really SD-direct
; and is HANDLE_DRV_RD really the routine serving it" is answered in the log
; rather than by reasoning. buf=AAAA is VD_BUF_SDDIRECT.
; Input:   R8 = virtual drive number, R9 = its buffer device id
; Output:  all registers unchanged
SDB_DBG_ARM     SYSCALL(enter, 1)
                MOVE    SDB_DBG_N, R0
                MOVE    8, @R0
                MOVE    SDB_DBG_CNT, R0
                MOVE    0, @R0
                MOVE    SDB_DBG_ACT, R0
                MOVE    0, @R0
                MOVE    R8, R1
                MOVE    R9, R2
                MOVE    SDB_L_MNT, R8
                RSUB    SDB_LOGS, 1
                MOVE    R1, R8
                RSUB    SDB_LOGH, 1
                MOVE    SDB_L_MNTB, R8
                RSUB    SDB_LOGS, 1
                MOVE    R2, R8
                RSUB    SDB_LOGH, 1
                RSUB    SDB_LOGNL, 1
                SYSCALL(leave, 1)
                RET

; A tear-free sample of the free running 48-bit cycle counter.
; Output: R8/R9 = low/high word of the lower 32 bits
SDB_DBG_NOW     INCRB
                MOVE    IO$CYC_STATE, R0
                OR      CYC$RUN, @R0            ; make sure it is counting
                MOVE    IO$CYC_LO, R0
                MOVE    IO$CYC_MID, R1
_SDBN_L         MOVE    @R1, R9                 ; high word
                MOVE    @R0, R8                 ; low word
                CMP     @R1, R9                 ; did the high word move on?
                RBRA    _SDBN_L, !Z             ; yes: sample again
                DECRB
                RET

; Start of one SD-direct block request.
; Input: R8 = virtual drive, R9 = VD_SIZEB, R10 = pos lo, R12 = pos hi
; Output: all registers unchanged
SDB_DBG_RD0     SYSCALL(enter, 1)
                MOVE    SDB_DBG_DRV, R0
                MOVE    R8, @R0
                MOVE    SDB_DBG_SZ, R0
                MOVE    R9, @R0
                MOVE    SDB_DBG_PL, R0
                MOVE    R10, @R0
                MOVE    SDB_DBG_PH, R0
                MOVE    R12, @R0
                MOVE    SDB_DBG_ACT, R0
                MOVE    1, @R0
                MOVE    SDB_SD_N, R0            ; count the card accesses of
                MOVE    0, @R0                  ; ..this one request
                MOVE    SDB_SD_CYC, R0
                MOVE    0, @R0++
                MOVE    0, @R0
                RSUB    SDB_DBG_NOW, 1
                MOVE    SDB_DBG_T0, R0
                MOVE    R8, @R0++
                MOVE    R9, @R0
                SYSCALL(leave, 1)
                RET

; End of one SD-direct block request: log it, if this one is due.
; Output: all registers unchanged
SDB_DBG_RD1     SYSCALL(enter, 1)
                MOVE    SDB_DBG_ACT, R0
                CMP     0, @R0                  ; was this an SD-direct read?
                RBRA    _SDBR1_RET, Z           ; no: the buffered path
                MOVE    0, @R0

                RSUB    SDB_DBG_NOW, 1
                MOVE    R8, R2                  ; R2/R3: now
                MOVE    R9, R3

                MOVE    SDB_DBG_T0, R0          ; R4/R5: fw = now - t0
                MOVE    R2, R4
                MOVE    R3, R5
                SUB     @R0++, R4
                SUBC    @R0, R5

                MOVE    SDB_DBG_T0, R0          ; R6/R7: gap = t0 - tend
                MOVE    @R0++, R6
                MOVE    @R0, R7
                MOVE    SDB_DBG_TE, R0
                SUB     @R0++, R6
                SUBC    @R0, R7

                MOVE    SDB_DBG_TE, R0          ; remember the end of this one
                MOVE    R2, @R0++
                MOVE    R3, @R0

                ; is this request due to be logged?
                MOVE    SDB_DBG_CNT, R0
                ADD     1, @R0
                MOVE    SDB_DBG_N, R1
                CMP     0, @R1
                RBRA    _SDBR1_YES, !Z          ; still in the first eight
                MOVE    @R0, R1
                AND     0x01FF, R1              ; one in every 512 after that
                RBRA    _SDBR1_RET, !Z
                RBRA    _SDBR1_LOG, 1
_SDBR1_YES      SUB     1, @R1

_SDBR1_LOG      MOVE    SDB_L_RD, R8
                RSUB    SDB_LOGS, 1
                MOVE    SDB_DBG_DRV, R8
                MOVE    @R8, R8
                RSUB    SDB_LOGH, 1
                MOVE    SDB_L_RDSZ, R8
                RSUB    SDB_LOGS, 1
                MOVE    SDB_DBG_SZ, R8
                MOVE    @R8, R8
                RSUB    SDB_LOGH, 1
                MOVE    SDB_L_RDPOS, R8
                RSUB    SDB_LOGS, 1
                MOVE    SDB_DBG_PH, R8
                MOVE    @R8, R8
                MOVE    SDB_DBG_PL, R9
                MOVE    @R9, R9
                RSUB    SDB_LOGH32, 1
                MOVE    SDB_L_RDST, R8
                RSUB    SDB_LOGS, 1
                MOVE    SDB_RD_STAT, R8
                MOVE    @R8, R8
                RSUB    SDB_LOGH, 1
                MOVE    SDB_L_RDLBA, R8
                RSUB    SDB_LOGS, 1
                MOVE    SDB_RD_LBA, R8
                ADD     1, R8
                MOVE    @R8, R8
                MOVE    SDB_RD_LBA, R9
                MOVE    @R9, R9
                RSUB    SDB_LOGH32, 1
                MOVE    SDB_L_RDFW, R8
                RSUB    SDB_LOGS, 1
                MOVE    R5, R8
                MOVE    R4, R9
                RSUB    SDB_LOGH32, 1
                MOVE    SDB_L_RDGAP, R8
                RSUB    SDB_LOGS, 1
                MOVE    R7, R8
                MOVE    R6, R9
                RSUB    SDB_LOGH32, 1
                MOVE    SDB_L_SDN, R8           ; card accesses in this..
                RSUB    SDB_LOGS, 1             ; ..request and their cost
                MOVE    SDB_SD_N, R8
                MOVE    @R8, R8
                RSUB    SDB_LOGH, 1
                MOVE    SDB_L_SDCYC, R8
                RSUB    SDB_LOGS, 1
                MOVE    SDB_SD_CYC, R8
                ADD     1, R8
                MOVE    @R8, R8
                MOVE    SDB_SD_CYC, R9
                MOVE    @R9, R9
                RSUB    SDB_LOGH32, 1
                MOVE    SDB_L_SDLST, R8
                RSUB    SDB_LOGS, 1
                MOVE    SDB_SD_LAST, R8
                ADD     1, R8
                MOVE    @R8, R8
                MOVE    SDB_SD_LAST, R9
                MOVE    @R9, R9
                RSUB    SDB_LOGH32, 1
                RSUB    SDB_LOGNL, 1
_SDBR1_RET      SYSCALL(leave, 1)
                RET

SDB_L_RD        .ASCII_W "SDB: rd drv="
SDB_L_RDSZ      .ASCII_W " sz="
SDB_L_RDPOS     .ASCII_W " pos="
SDB_L_RDST      .ASCII_W " st="
SDB_L_RDLBA     .ASCII_W " lba="
SDB_L_RDFW      .ASCII_W " fw="
SDB_L_RDGAP     .ASCII_W " gap="
SDB_L_SDN       .ASCII_W " sdn="
SDB_L_SDCYC     .ASCII_W " sdcyc="
SDB_L_SDLST     .ASCII_W " sdlast="
SDB_L_MNT       .ASCII_W "SDB: mount drv="
SDB_L_MNTB      .ASCII_W " buf="
SDB_L_SDERR     .ASCII_W "SDB: SD ERROR code="
SDB_L_ORPH      .ASCII_W "SDB: buffer could not be restored"
SDB_L_CRMA      .ASCII_W "SDB: f32_fread error in _CRMA_3 code="

#endif
