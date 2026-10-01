# FASTFREE.COM - seed the DOS kernel's cached free-cluster count for a FAT16
# drive, so the first DIR after boot does not stall.
#
# FreeDOS (kernel 2043, as shipped in freedos.vhd) computes "bytes free" the
# first time it is asked by calling link_fat() once per cluster: two 32-bit
# software divisions and a far-pointer buffer lookup per FAT entry. On a
# 4.77 MHz 8088 that is ~8,000 cycles per entry, i.e. about 38 s for the
# 21,722 clusters of the shipped image. After that the count lives in the
# drive parameter block (dpb_nfreeclst) and every later DIR is instant.
#
# This program does the same count in a tight loop - reads the FAT with
# INT 25h, 8 sectors at a time, and counts zero entries - and stores the
# result where the kernel would have put it:
#     DPB+1Fh  dpb_nfreeclst   number of free clusters (FFFFh = unknown)
#     DPB+1Dh  dpb_cluster     first free cluster (search start hint)
# exactly as the kernel's dos_free() does. If the count is already known it
# does nothing. FAT16 only (highest cluster in 4086..65525, the kernel's own
# ISFAT16 test); FAT12 and FAT32 drives are left alone.
#
# usage: FASTFREE [d:]      default: the current drive
#
# DOS 4+ / FreeDOS (INT 25h packet form, DPB layout with word sectors/FAT).
# Build: see build.sh (GNU as, .code16).

        .code16
        .arch   i8086
        .intel_syntax noprefix
        .text
        .globl  _start
_start:
        mov     si, 0x81                # command tail
1:      lodsb
        cmp     al, ' '
        je      1b
        cmp     al, 9
        je      1b
        xor     dl, dl                  # 0 = current drive
        cmp     al, 13
        je      getdpb
        and     al, 0xDF                # upper case
        sub     al, 'A'-1               # 1-based drive number
        jbe     t_usage
        cmp     al, 26
        ja      t_usage
        mov     dl, al
        jmp     getdpb
# short-range trampolines (8086 has no near conditional jumps)
t_usage:    jmp usage
t_baddrv:   jmp baddrv
t_known:    jmp known
t_notfat16: jmp notfat16
getdpb:
        mov     ah, 0x32                # get DPB -> DS:BX
        int     0x21
        cmp     al, 0xFF
        je      t_baddrv
        mov     word ptr cs:[dpb_off], bx
        mov     word ptr cs:[dpb_seg], ds
        mov     al, [bx]                # dpb_unit: 0-based drive for INT 25h
        mov     byte ptr cs:[drv], al
        mov     ax, [bx+0x1F]           # dpb_nfreeclst
        cmp     ax, 0xFFFF
        jne     t_known
        mov     ax, [bx+0x0D]           # dpb_size = highest cluster number
        cmp     ax, 4086                # ISFAT16: 4085 < size <= 65525
        jb      t_notfat16
        cmp     ax, 65525
        ja      t_notfat16
        mov     word ptr cs:[maxclus], ax
        mov     ax, [bx+0x0F]           # dpb_fatsize: sectors per FAT
        mov     word ptr cs:[left], ax
        mov     ax, [bx+0x06]           # dpb_fatstrt: first FAT sector
        mov     word ptr cs:[pkt_sec], ax
        push    cs
        pop     ds
        mov     word ptr [pkt_buf+2], cs # packet buffer segment
        xor     dx, dx                  # dx = cluster index of the next word
readloop:
        mov     ax, [left]
        or      ax, ax
        jz      finish
        cmp     ax, 8
        jbe     2f
        mov     ax, 8
2:      mov     [pkt_cnt], ax
        mov     [nsec], ax
        mov     al, [drv]
        mov     cx, 0xFFFF              # packet form
        mov     bx, offset pkt
        push    dx
        push    ds
        int     0x25
        pop     ax                      # flags INT 25h leaves on the stack
        pop     ds
        pop     dx
        jc      t_readerr
        mov     si, offset buf
        mov     cx, [nsec]
        mov     ch, cl                  # cx = sectors * 256 words
        xor     cl, cl
scan:   lodsw
        cmp     dx, 2
        jb      3f
        cmp     dx, [maxclus]
        ja      3f
        or      ax, ax
        jnz     3f
        inc     word ptr [count]
        cmp     word ptr [first], 0
        jne     3f
        mov     [first], dx
3:      inc     dx
        loop    scan
        mov     ax, [nsec]
        add     [pkt_sec], ax
        adc     word ptr [pkt_sec+2], 0
        sub     [left], ax
        cmp     dx, [maxclus]
        jbe     readloop
        jmp     finish
t_readerr:  jmp readerr
finish:
        les     di, dword ptr [dpb_off]
        mov     ax, [count]
        mov     es:[di+0x1F], ax        # dpb_nfreeclst
        mov     ax, [first]
        or      ax, ax
        jz      4f
        mov     es:[di+0x1D], ax        # dpb_cluster
4:      mov     dx, offset msg_done
        mov     ah, 9
        int     0x21
        mov     ax, [count]
        call    putdec
        mov     dx, offset msg_done2
        mov     ah, 9
        int     0x21
        mov     dl, [drv]
        add     dl, 'A'
        mov     ah, 2
        int     0x21
        mov     dl, ':'
        mov     ah, 2
        int     0x21
        call    crlf
        xor     al, al
        jmp     exit

known:  mov     dx, offset msg_known
        jmp     say
notfat16:
        mov     dx, offset msg_nofat16
        jmp     say
readerr:
        mov     dx, offset msg_readerr
        jmp     say
baddrv: mov     dx, offset msg_baddrv
        jmp     say
usage:  mov     dx, offset msg_usage
say:    push    cs
        pop     ds
        mov     ah, 9
        int     0x21
        mov     al, 1
exit:   mov     ah, 0x4C
        int     0x21

# print ax in decimal
putdec: xor     cx, cx
        mov     bx, 10
5:      xor     dx, dx
        div     bx
        push    dx
        inc     cx
        or      ax, ax
        jnz     5b
6:      pop     dx
        add     dl, '0'
        mov     ah, 2
        int     0x21
        loop    6b
        ret
crlf:   mov     dl, 13
        mov     ah, 2
        int     0x21
        mov     dl, 10
        mov     ah, 2
        int     0x21
        ret

msg_done:    .ascii "FASTFREE: $"
msg_done2:   .ascii " free clusters cached for $"
msg_known:   .ascii "FASTFREE: free space already known, nothing done\r\n$"
msg_nofat16: .ascii "FASTFREE: not a FAT16 drive, nothing done\r\n$"
msg_readerr: .ascii "FASTFREE: FAT read error, nothing done\r\n$"
msg_baddrv:  .ascii "FASTFREE: invalid drive\r\n$"
msg_usage:   .ascii "usage: FASTFREE [d:]\r\n$"

        .balign 2
dpb_off: .word 0
dpb_seg: .word 0
maxclus: .word 0
left:    .word 0
nsec:    .word 0
count:   .word 0
first:   .word 0
drv:     .byte 0
        .balign 2
pkt:
pkt_sec: .long 0                        # INT 25h packet: sector (dword)
pkt_cnt: .word 0                        #   count (word)
pkt_buf: .word buf                      #   buffer offset
         .word 0                        #   buffer segment, set at run time
end_of_image:
        .set buf, end_of_image          # 4 KB read buffer, not in the file
