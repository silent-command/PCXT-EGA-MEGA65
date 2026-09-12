#!/usr/bin/env python3
"""Reconfigure the XTIDE Universal BIOS block inside an 8088_bios flash image
for this core's IDE controller (XTIDE rev 1 register layout at port 300h).

usage: patch_xtide_rom.py <in.rom> <out.rom>

Finds the 8 KB option-ROM block that carries the XTIDE signature, checks the
ROMVARS it expects (base port 0x0320, device type 0x0E = XT-CF), sets base
port 0x0300 and device type 0x06 (XTIDE rev 1), and fixes the option-ROM
checksum byte so the block sums to zero again. Refuses anything unexpected.
"""
import sys

src, dst = sys.argv[1], sys.argv[2]
img = bytearray(open(src, "rb").read())
print(f"{src}: {len(img)} bytes")

# locate the XTIDE option ROM block (55 AA <size/512> ... "XTIDE Universal BIOS")
blk = None
for off in range(0, len(img), 0x800):
    if img[off] == 0x55 and img[off + 1] == 0xAA and b"XTIDE Universal BIOS" in bytes(img[off:off + 0x2000]):
        blk = off
        break
if blk is None:
    sys.exit("no XTIDE option ROM block found")
size = img[blk + 2] * 512
print(f"XTIDE block at 0x{blk:05X}, {size} bytes, signature {bytes(img[blk+0x8:blk+0x30]).split(b'\\x00')[0]!r}")

# ROMVARS: ideVars0 at block offset 0x4E: wBasePort, wControlBlockPort, bDevice at 0x52
base = int.from_bytes(img[blk + 0x4E:blk + 0x50], "little")
ctrl = int.from_bytes(img[blk + 0x50:blk + 0x52], "little")
dev = img[blk + 0x52]
print(f"ideVars0: base 0x{base:04X} control 0x{ctrl:04X} device 0x{dev:02X}")
if (base, dev) == (0x0300, 0x06):
    print("already configured for this core")
elif (base, dev) == (0x0320, 0x0E):
    img[blk + 0x4E:blk + 0x50] = (0x0300).to_bytes(2, "little")
    img[blk + 0x52] = 0x06
    print("patched: base 0x0300, device 0x06 (XTIDE rev 1)")
else:
    sys.exit("unexpected ideVars0 layout; not patching")

# option ROM checksum: the block must sum to 0 mod 256; last byte is the adjuster
img[blk + size - 1] = 0
s = sum(img[blk:blk + size]) & 0xFF
img[blk + size - 1] = (-s) & 0xFF
assert sum(img[blk:blk + size]) & 0xFF == 0
print(f"checksum byte at 0x{blk + size - 1:05X} = 0x{img[blk + size - 1]:02X}")

# sanity: reset vector at the top of the image
rv = bytes(img[-16:-11])
print(f"reset vector bytes at 0x{len(img)-16:05X}: {rv.hex()} ({'JMP FAR' if rv[0] == 0xEA else 'unexpected'})")

open(dst, "wb").write(img)
print(f"wrote {dst}")
