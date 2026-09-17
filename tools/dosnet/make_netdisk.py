#!/usr/bin/env python3
"""Build netdisk.img: a 1.44 MB FAT12 floppy with the DOS networking kit for
the emulated NE1000 card.

  NE1000.COM   Crynwr packet driver (GPL), from fragglet/crynwr_mirror
  *.EXE        mTCP 2025-01-10 (GPL v3), from brutman.com
  MTCP.CFG     packet interrupt 60h, hostname MEGA65, FTP server settings
  FTPPASS.TXT  FTP server accounts: user "mega65", password "mega65"
  NET.BAT      loads the driver at INT 60h / IRQ 5 / port 320h and runs DHCP
  README.TXT   what to type

usage: python3 make_netdisk.py <out.img>
Inputs come from dist/ next to this script.
"""
import os
import struct
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
DIST = os.path.join(HERE, 'dist')

MTCP_CFG = (
    b"packetint 0x60\r\n"
    b"hostname MEGA65\r\n"
    b"ftpsrv_password_file A:\\FTPPASS.TXT\r\n"
    b"ftpsrv_session_timeout 300\r\n"
    b"ftpsrv_clients 2\r\n"
    b"ftpsrv_packets_per_poll 2\r\n"
)

FTPPASS = (
    b"# user   password  sandboxdir  uploaddir  permissions\r\n"
    b"mega65   mega65    [none]      [any]      all\r\n"
    b"anonymous [email]  [none]      [any]      all\r\n"
)

NET_BAT = (
    b"@echo off\r\n"
    b"rem NE1000 packet driver: software INT 60h, IRQ 5, I/O port 320h\r\n"
    b"A:\\NE1000 0x60 5 0x320\r\n"
    b"set MTCPCFG=A:\\MTCP.CFG\r\n"
    b"A:\\DHCP\r\n"
)

README = (
    b"MEGA65 PCXT-EGA network kit\r\n"
    b"\r\n"
    b"  NET          load the packet driver and get an address by DHCP\r\n"
    b"  PING 192.168.1.1   (or any host)\r\n"
    b"  FTPSRV       start the FTP server; log in as mega65 / mega65\r\n"
    b"  FTP host     FTP client; TELNET host; NC; HTGET url; SNTP host\r\n"
    b"  PKTTOOL      packet driver statistics and a raw packet monitor\r\n"
    b"\r\n"
    b"The packet driver is Crynwr's NE1000 driver (GPL). The tools are mTCP\r\n"
    b"by Michael Brutman, GPL v3 (see COPYING.TXT, MTCP.TXT).\r\n"
    b"DHCP writes the address it obtains into MTCP.CFG, so the disk must not\r\n"
    b"be write-protected.\r\n"
)


def fat12(files, spc, rootn, total, media, spf, spt, heads, label):
    BPS, RSVD, NFAT = 512, 1, 2
    img = bytearray(total * BPS)
    bs = bytearray(BPS)
    bs[0:3] = b'\xEB\x3C\x90'
    bs[3:11] = b'MEGA65  '
    struct.pack_into('<HBHBHHBHHHII', bs, 11, BPS, spc, RSVD, NFAT, rootn, total, media, spf, spt, heads, 0, 0)
    bs[36] = 0x80
    bs[38] = 0x29
    struct.pack_into('<I', bs, 39, 0x4E455431)
    bs[43:54] = label.ljust(11).encode()[:11]
    bs[54:62] = b'FAT12   '
    bs[510] = 0x55
    bs[511] = 0xAA
    img[0:BPS] = bs
    fat = bytearray(spf * BPS)
    fat[0:3] = bytes([media, 0xFF, 0xFF])

    def set12(n, v):
        o = n * 3 // 2
        if n & 1:
            fat[o] = (fat[o] & 0x0F) | ((v << 4) & 0xF0)
            fat[o + 1] = (v >> 4) & 0xFF
        else:
            fat[o] = v & 0xFF
            fat[o + 1] = (fat[o + 1] & 0xF0) | ((v >> 8) & 0x0F)

    root_lba = RSVD + NFAT * spf
    data_lba = root_lba + rootn * 32 // BPS
    root = bytearray(rootn * 32)
    next_c = 2
    csize = spc * BPS
    for i, (name, ext, data) in enumerate(files):
        nclus = max(1, (len(data) + csize - 1) // csize)
        first = next_c
        for k in range(nclus):
            c = next_c + k
            set12(c, 0xFFF if k == nclus - 1 else c + 1)
            off = (data_lba + (c - 2) * spc) * BPS
            chunk = data[k * csize:(k + 1) * csize]
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
    if next_c - 2 > (total - data_lba) // spc:
        raise SystemExit('does not fit')
    for f in range(NFAT):
        img[(RSVD + f * spf) * BPS:(RSVD + (f + 1) * spf) * BPS] = fat
    img[root_lba * BPS:root_lba * BPS + len(root)] = root
    return bytes(img), (next_c - 2) * csize


def dist(name):
    with open(os.path.join(DIST, name), 'rb') as f:
        return f.read()


if __name__ == '__main__':
    out = sys.argv[1]
    files = [
        ('NE1000', 'COM', dist('NE1000.COM')),
        ('NET', 'BAT', NET_BAT),
        ('MTCP', 'CFG', MTCP_CFG),
        ('FTPPASS', 'TXT', FTPPASS),
        ('README', 'TXT', README),
        ('DHCP', 'EXE', dist('DHCP.EXE')),
        ('PING', 'EXE', dist('PING.EXE')),
        ('FTPSRV', 'EXE', dist('FTPSRV.EXE')),
        ('FTP', 'EXE', dist('FTP.EXE')),
        ('TELNET', 'EXE', dist('TELNET.EXE')),
        ('NC', 'EXE', dist('NC.EXE')),
        ('PKTTOOL', 'EXE', dist('PKTTOOL.EXE')),
        ('SNTP', 'EXE', dist('SNTP.EXE')),
        ('HTGET', 'EXE', dist('HTGET.EXE')),
        ('COPYING', 'TXT', dist('COPYING.TXT')),
        ('MTCP', 'TXT', dist('MTCP.TXT')),
    ]
    # 1.44 MB: 1 sector/cluster, 224 root entries, 2880 sectors, media F0,
    # 9 sectors per FAT, 18 sectors/track, 2 heads
    img, used = fat12(files, 1, 224, 2880, 0xF0, 9, 18, 2, 'NETDISK')
    with open(out, 'wb') as f:
        f.write(img)
    print(f"{out}: {len(img)} bytes, {len(files)} files, {used} bytes used")
