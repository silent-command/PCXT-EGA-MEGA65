#!/usr/bin/env python3
"""Put a host file into the root directory of a FAT16 hard disk image.

    fat16-put.py <image> <hostfile> <NAME.EXT> [<hostfile> <NAME.EXT> ...]

The image is an MBR disk whose first partition is FAT16 (the layout of
pcxt/freedos.vhd). An existing entry of the same name is replaced: its
cluster chain is freed and zeroed and the new data is written to free clusters. Both
FAT copies are updated. Names are 8.3, upper case, no long names.
"""
import struct
import sys
import time


def main():
    path = sys.argv[1]
    pairs = list(zip(sys.argv[2::2], sys.argv[3::2]))
    if not pairs:
        sys.exit(__doc__)
    f = open(path, "r+b")

    mbr = f.read(512)
    ent = mbr[446:462]
    plba = struct.unpack("<I", ent[8:12])[0]
    f.seek(plba * 512)
    bs = f.read(512)
    bps = struct.unpack("<H", bs[11:13])[0]
    spc = bs[13]
    rsvd = struct.unpack("<H", bs[14:16])[0]
    nfat = bs[16]
    rootent = struct.unpack("<H", bs[17:19])[0]
    spf = struct.unpack("<H", bs[22:24])[0]
    total = struct.unpack("<H", bs[19:21])[0] or struct.unpack("<I", bs[32:36])[0]
    fat0 = plba + rsvd
    root = fat0 + nfat * spf
    data = root + rootent * 32 // bps
    nclus = (total - (rsvd + nfat * spf + rootent * 32 // bps)) // spc
    if not (4085 <= nclus < 65525):
        sys.exit("not FAT16 (%d clusters)" % nclus)
    csize = spc * bps

    f.seek(fat0 * bps)
    fat = bytearray(f.read(spf * bps))
    get = lambda c: struct.unpack("<H", fat[2 * c:2 * c + 2])[0]
    put = lambda c, v: struct.pack_into("<H", fat, 2 * c, v)

    f.seek(root * bps)
    rootraw = bytearray(f.read(rootent * 32))

    def dos_name(n):
        base, _, ext = n.upper().partition(".")
        if len(base) > 8 or len(ext) > 3 or not base:
            sys.exit("bad 8.3 name: " + n)
        return base.ljust(8).encode("ascii") + ext.ljust(3).encode("ascii")

    def dos_datetime():
        t = time.localtime()
        d = ((t.tm_year - 1980) << 9) | (t.tm_mon << 5) | t.tm_mday
        tm = (t.tm_hour << 11) | (t.tm_min << 5) | (t.tm_sec // 2)
        return tm, d

    for host, name in pairs:
        blob = open(host, "rb").read()
        nm = dos_name(name)
        slot = None
        for i in range(rootent):
            x = rootraw[32 * i:32 * i + 32]
            if x[0] in (0, 0xE5) or x[11] & 0x0F == 0x0F:
                if slot is None and x[0] in (0, 0xE5):
                    slot = i
                continue
            if x[0:11] == nm:
                slot = i
                c = struct.unpack("<H", x[26:28])[0]
                freed = 0
                while 2 <= c < 0xFFF8:
                    nxt = get(c)
                    put(c, 0)
                    # deleting in FAT leaves the bytes behind: wipe them, the
                    # image is going to be redistributed
                    f.seek((data + (c - 2) * spc) * bps)
                    f.write(b"\0" * csize)
                    freed += 1
                    c = nxt
                print("%s: replaced (%d clusters freed)" % (name, freed))
                break
        if slot is None:
            sys.exit("root directory full")

        need = (len(blob) + csize - 1) // csize
        free = [c for c in range(2, nclus + 2) if get(c) == 0][:need]
        if len(free) < need:
            sys.exit("disk full")
        for i, c in enumerate(free):
            put(c, free[i + 1] if i + 1 < need else 0xFFFF)
            f.seek((data + (c - 2) * spc) * bps)
            chunk = blob[i * csize:(i + 1) * csize]
            f.write(chunk + b"\0" * (csize - len(chunk)))

        tm, d = dos_datetime()
        e = bytearray(32)
        e[0:11] = nm
        e[11] = 0x20                       # archive
        struct.pack_into("<HHHH", e, 14, tm, d, d, 0)   # ctime, cdate, adate, hi cluster
        struct.pack_into("<HHHI", e, 22, tm, d, free[0] if need else 0, len(blob))
        rootraw[32 * slot:32 * slot + 32] = e
        print("%s: %d bytes in %d cluster(s) from %d" % (name, len(blob), need, free[0] if need else 0))

    f.seek(root * bps)
    f.write(rootraw)
    for n in range(nfat):
        f.seek((fat0 + n * spf) * bps)
        f.write(fat)
    f.flush()
    f.close()
    nfree = sum(1 for c in range(2, nclus + 2) if get(c) == 0)
    print("free clusters now: %d of %d (%d bytes free)" % (nfree, nclus, nfree * csize))


main()
