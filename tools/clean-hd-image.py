#!/usr/bin/env python3
"""Remove a directory tree from a FAT16 disk image and wipe the freed space.

Deleting files in FAT only marks the directory entry and frees the cluster
chain; the bytes stay on the disk. For an image that is going to be
redistributed that is not enough, so every cluster the FAT marks free is
overwritten with zeros afterwards - which also removes anything deleted
earlier in the image's life.

usage: clean-image.py <image> <TOPLEVEL_DIR_TO_REMOVE> [...]
"""
import struct
import sys


def main():
    path = sys.argv[1]
    targets = [t.upper() for t in sys.argv[2:]]
    f = open(path, "r+b")

    mbr = f.read(512)
    ent = mbr[446:462]
    if ent[4] == 0:
        sys.exit("no first partition")
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

    f.seek(fat0 * bps)
    fat = bytearray(f.read(spf * bps))

    def get(c):
        return struct.unpack("<H", fat[c * 2:c * 2 + 2])[0]

    def put(c, v):
        struct.pack_into("<H", fat, c * 2, v)

    def chain(c):
        out = []
        while 2 <= c < 0xFFF8 and c not in out:
            out.append(c)
            c = get(c)
        return out

    def clus_off(c):
        return (data + (c - 2) * spc) * bps

    def read_clus(c):
        f.seek(clus_off(c))
        return f.read(spc * bps)

    def dir_entries(raw):
        out = []
        for i in range(len(raw) // 32):
            x = raw[32 * i:32 * i + 32]
            if x[0] in (0, 0xE5) or x[11] & 0x0F == 0x0F:
                continue
            nm = x[0:8].decode("ascii", "ignore").strip()
            ex = x[8:11].decode("ascii", "ignore").strip()
            if nm in (".", ".."):
                continue
            out.append((("%s.%s" % (nm, ex)) if ex else nm,
                        x[11] & 0x10 != 0,
                        struct.unpack("<H", x[26:28])[0],
                        struct.unpack("<I", x[28:32])[0]))
        return out

    freed = []

    def free_tree(start):
        cl = chain(start)
        raw = b"".join(read_clus(c) for c in cl)
        for nm, isdir, c, sz in dir_entries(raw):
            if c:
                if isdir:
                    free_tree(c)
                else:
                    for x in chain(c):
                        put(x, 0)
                        freed.append(x)
        for c in cl:
            put(c, 0)
            freed.append(c)

    # find the targets in the root directory and unlink them
    f.seek(root * bps)
    rootraw = bytearray(f.read(rootent * 32))
    removed = []
    for i in range(rootent):
        x = rootraw[32 * i:32 * i + 32]
        if x[0] in (0, 0xE5) or x[11] & 0x0F == 0x0F:
            continue
        nm = x[0:8].decode("ascii", "ignore").strip()
        if nm in targets:
            start = struct.unpack("<H", x[26:28])[0]
            if x[11] & 0x10 and start:
                free_tree(start)
            elif start:
                for c in chain(start):
                    put(c, 0)
                    freed.append(c)
            rootraw[32 * i] = 0xE5
            removed.append(nm)

    if not removed:
        sys.exit("none of %s found in the root directory" % targets)

    # write the root directory and both FAT copies back
    f.seek(root * bps)
    f.write(rootraw)
    for n in range(nfat):
        f.seek((fat0 + n * spf) * bps)
        f.write(fat)

    # wipe every free cluster, including space freed long before this run
    zero = b"\0" * (spc * bps)
    wiped = 0
    for c in range(2, nclus + 2):
        if get(c) == 0:
            f.seek(clus_off(c))
            f.write(zero)
            wiped += 1
    f.flush()
    f.close()
    print("removed: %s" % ", ".join(removed))
    print("clusters freed by this run: %d" % len(freed))
    print("free clusters zeroed: %d of %d (%.1f MB)"
          % (wiped, nclus, wiped * spc * bps / 1e6))


main()
