#!/usr/bin/env python3
"""Build joytest.img, a 360 KB FAT12 floppy with two hand-assembled DOS tools.

  JOYTEST.COM  strobes the game port (0x201) and prints, until a key is pressed:
                 <X count> <Y count> <raw byte>   all hex
               count = polling loops until the axis bit dropped (FFFF = never,
               i.e. no joystick or port disabled; 0000 = dropped at once = stick
               held to the low end). Raw byte bits 4..7 are buttons, active low:
               F? = none, E? = button 1, D? = button 2.
  SETJOY.COM   ORs 1000h into the BIOS equipment word at 0040:0010 ("game
               adapter installed") for BIOSes that never detect the port.

usage: python3 make_joytest.py <out.img>
"""
import struct
import sys


def asm(items):
    """Two-pass mini assembler. Items are bytes or tuples:
    ('label', name), ('call', name), ('jz'|'jnz'|'jbe'|'jmp', name)."""
    sizes = {'label': 0, 'call': 3, 'jz': 2, 'jnz': 2, 'jbe': 2, 'jmp': 2}
    labels, pc = {}, 0x100
    for it in items:
        if isinstance(it, bytes):
            pc += len(it)
        elif it[0] == 'label':
            labels[it[1]] = pc
        else:
            pc += sizes[it[0]]
    out, pc = bytearray(), 0x100
    for it in items:
        if isinstance(it, bytes):
            out += it
            pc += len(it)
            continue
        kind = it[0]
        if kind == 'label':
            continue
        tgt = labels[it[1]]
        if kind == 'call':
            out += b'\xE8' + struct.pack('<h', tgt - (pc + 3))
            pc += 3
        else:
            rel = tgt - (pc + 2)
            assert -128 <= rel <= 127, (kind, it[1], rel)
            op = {'jz': 0x74, 'jnz': 0x75, 'jbe': 0x76, 'jmp': 0xEB}[kind]
            out += bytes([op, rel & 0xFF])
            pc += 2
    return bytes(out)


JOYTEST = asm([
    ('label', 'start'),
    b'\xBA\x01\x02',            # mov dx,0201h
    b'\xEE',                    # out dx,al        strobe the one-shots
    b'\x31\xC9',                # xor cx,cx        X loops
    b'\x31\xDB',                # xor bx,bx        Y loops
    b'\xBE\xFF\xFF',            # mov si,0FFFFh    timeout
    ('label', 'poll'),
    b'\xEC',                    # in al,dx
    b'\xA8\x01',                # test al,1        P1 X still high?
    ('jz', 'nx'),
    b'\x41',                    # inc cx
    ('label', 'nx'),
    b'\xA8\x02',                # test al,2        P1 Y still high?
    ('jz', 'ny'),
    b'\x43',                    # inc bx
    ('label', 'ny'),
    b'\xA8\x03',                # test al,3        both dropped?
    ('jz', 'done'),
    b'\x4E',                    # dec si
    ('jnz', 'poll'),
    ('label', 'done'),
    b'\x50',                    # push ax          raw byte
    b'\x89\xC8',                # mov ax,cx
    ('call', 'phex'),
    b'\xB0\x20', ('call', 'pchr'),
    b'\x89\xD8',                # mov ax,bx
    ('call', 'phex'),
    b'\xB0\x20', ('call', 'pchr'),
    b'\x58',                    # pop ax
    b'\x30\xE4',                # xor ah,ah
    ('call', 'phex'),
    b'\xB0\x0D', ('call', 'pchr'),
    b'\xB0\x0A', ('call', 'pchr'),
    b'\x31\xC9',                # xor cx,cx        crude delay so the
    ('label', 'dly'),
    b'\xE2\xFE',                # loop dly         screen stays readable
    b'\xB4\x01', b'\xCD\x16',   # int 16h/01: key waiting?
    ('jz', 'start'),
    b'\xB4\x00', b'\xCD\x16',   # int 16h/00: eat it
    b'\xCD\x20',                # int 20h          exit
    ('label', 'phex'),          # print AX as 4 hex digits, preserves BX CX DX
    b'\x53', b'\x51',           # push bx / push cx
    b'\x89\xC3',                # mov bx,ax
    b'\xB1\x04',                # mov cl,4
    b'\x88\xF8', b'\xD2\xE8', ('call', 'pnib'),   # al = bh >> 4
    b'\x88\xF8', b'\x24\x0F', ('call', 'pnib'),   # al = bh & 15
    b'\x88\xD8', b'\xD2\xE8', ('call', 'pnib'),   # al = bl >> 4
    b'\x88\xD8', b'\x24\x0F', ('call', 'pnib'),   # al = bl & 15
    b'\x59', b'\x5B', b'\xC3',  # pop cx / pop bx / ret
    ('label', 'pnib'),
    b'\x04\x30',                # add al,'0'
    b'\x3C\x39',                # cmp al,'9'
    ('jbe', 'pchr'),
    b'\x04\x07',                # add al,7
    ('label', 'pchr'),          # print AL, preserves DX
    b'\x52',                    # push dx
    b'\x88\xC2',                # mov dl,al
    b'\xB4\x02', b'\xCD\x21',   # int 21h/02
    b'\x5A', b'\xC3',           # pop dx / ret
])


def setjoy():
    code = b''.join([
        b'\xB8\x40\x00',                # mov ax,0040h
        b'\x8E\xD8',                    # mov ds,ax
        b'\x81\x0E\x10\x00\x00\x10',    # or word [0010h],1000h
        b'\x0E', b'\x1F',               # push cs / pop ds
        b'\xBA\x00\x00',                # mov dx,msg   (patched below)
        b'\xB4\x09', b'\xCD\x21',       # int 21h/09
        b'\xCD\x20',                    # int 20h
    ])
    msg_off = 0x100 + len(code)
    code = code.replace(b'\xBA\x00\x00', b'\xBA' + struct.pack('<H', msg_off))
    return code + b'Game adapter bit set in the BIOS equipment word.\r\n$'


README = (b"JOYTEST.COM - prints  X-count Y-count raw  (hex) until a key is pressed.\r\n"
          b"  count FFFF = axis never dropped (no joystick / port disabled)\r\n"
          b"  count 0000 = dropped at once (stick at the low end: left / up)\r\n"
          b"  raw F0..FF = no button, E? = fire pressed\r\n"
          b"SETJOY.COM  - marks a game adapter present in the BIOS equipment word.\r\n"
          b"  Run it before a game that says no joystick without probing the port.\r\n")


def fat12_360k(files):
    BPS, SPC, RSVD, NFAT, ROOTN, TOT, MEDIA, SPF, SPT, HEADS = 512, 2, 1, 2, 112, 720, 0xFD, 2, 9, 2
    img = bytearray(TOT * BPS)
    bs = bytearray(BPS)
    bs[0:3] = b'\xEB\x3C\x90'
    bs[3:11] = b'MEGA65  '
    struct.pack_into('<HBHBHHBHHHII', bs, 11, BPS, SPC, RSVD, NFAT, ROOTN, TOT, MEDIA, SPF, SPT, HEADS, 0, 0)
    bs[36] = 0x80
    bs[38] = 0x29
    struct.pack_into('<I', bs, 39, 0x4A4F5954)
    bs[43:54] = b'JOYTEST    '
    bs[54:62] = b'FAT12   '
    bs[510] = 0x55
    bs[511] = 0xAA
    img[0:BPS] = bs
    fat = bytearray(SPF * BPS)
    fat[0:3] = bytes([MEDIA, 0xFF, 0xFF])

    def set12(n, v):
        o = n * 3 // 2
        if n & 1:
            fat[o] = (fat[o] & 0x0F) | ((v << 4) & 0xF0)
            fat[o + 1] = (v >> 4) & 0xFF
        else:
            fat[o] = v & 0xFF
            fat[o + 1] = (fat[o + 1] & 0xF0) | ((v >> 8) & 0x0F)

    root_lba = RSVD + NFAT * SPF
    data_lba = root_lba + ROOTN * 32 // BPS
    root = bytearray(ROOTN * 32)
    next_c = 2
    for i, (name, ext, data) in enumerate(files):
        nclus = max(1, (len(data) + SPC * BPS - 1) // (SPC * BPS))
        first = next_c
        for k in range(nclus):
            c = next_c + k
            set12(c, 0xFFF if k == nclus - 1 else c + 1)
            off = (data_lba + (c - 2) * SPC) * BPS
            chunk = data[k * SPC * BPS:(k + 1) * SPC * BPS]
            img[off:off + len(chunk)] = chunk
        next_c += nclus
        e = bytearray(32)
        e[0:8] = name.ljust(8).encode()
        e[8:11] = ext.ljust(3).encode()
        e[11] = 0x20
        struct.pack_into('<H', e, 24, (46 << 9) | (9 << 5) | 16)   # 2026-09-16
        struct.pack_into('<H', e, 26, first)
        struct.pack_into('<I', e, 28, len(data))
        root[i * 32:(i + 1) * 32] = e
    for f in range(NFAT):
        img[(RSVD + f * SPF) * BPS:(RSVD + (f + 1) * SPF) * BPS] = fat
    img[root_lba * BPS:root_lba * BPS + len(root)] = root
    return bytes(img)


if __name__ == '__main__':
    out = sys.argv[1]
    sj = setjoy()
    img = fat12_360k([('JOYTEST', 'COM', JOYTEST), ('SETJOY', 'COM', sj), ('README', 'TXT', README)])
    open(out, 'wb').write(img)
    print(f"{out}: {len(img)} bytes; JOYTEST.COM {len(JOYTEST)} bytes, SETJOY.COM {len(sj)} bytes")
