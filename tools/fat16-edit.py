#!/usr/bin/env python3
"""Edit the FAT16 partition of a hard disk image (the layout of
pcxt/freedos.vhd: an MBR disk whose first partition is FAT16).

    fat16-edit.py <image> ls                      tree of the volume
    fat16-edit.py <image> check                   consistency check (below)
    fat16-edit.py <image> cat   <C:\\PATH\\FILE>     write a file to stdout
    fat16-edit.py <image> put   <hostfile> <C:\\PATH\\NAME.EXT>
    fat16-edit.py <image> rm    <C:\\PATH\\NAME>     a file or a whole tree
    fat16-edit.py <image> mkdir <C:\\PATH\\NAME>

Several commands can follow one image, separated by "--".

The image is redistributed, so the rules of tools/clean-hd-image.py apply:
clusters that are freed are zeroed, and a directory that loses an entry is
rewritten compactly instead of being left with a deleted slot that still
carries the old name. Long-name slots are kept with the entry they belong to
and dropped otherwise. New names are 8.3. Both FAT copies are written.

check: every directory is walked; each file's chain must be as long as its
size needs, no cluster may belong to two chains, no chain may run into a free
or reserved cluster, every allocated cluster must belong to something, the
two FAT copies must be equal and every free cluster must be all zeros.
"""
import io
import struct
import sys
import time


class Vol:
    def __init__(self, path, write):
        # The whole image is edited in memory and only written back when every
        # command has succeeded: a command that fails half way (a missing
        # directory, a full disk) must not leave zeroed clusters behind a FAT
        # that still points at them.
        self.path = path
        self.f = io.BytesIO(open(path, "rb").read())
        mbr = self.f.read(512)
        self.plba = struct.unpack("<I", mbr[446 + 8:446 + 12])[0]
        self.f.seek(self.plba * 512)
        bs = self.f.read(512)
        self.bps = struct.unpack("<H", bs[11:13])[0]
        self.spc = bs[13]
        rsvd = struct.unpack("<H", bs[14:16])[0]
        self.nfat = bs[16]
        self.rootent = struct.unpack("<H", bs[17:19])[0]
        self.spf = struct.unpack("<H", bs[22:24])[0]
        total = struct.unpack("<H", bs[19:21])[0] or struct.unpack("<I", bs[32:36])[0]
        self.fat0 = self.plba + rsvd
        self.root = self.fat0 + self.nfat * self.spf
        self.data = self.root + self.rootent * 32 // self.bps
        self.nclus = (total - (rsvd + self.nfat * self.spf + self.rootent * 32 // self.bps)) // self.spc
        if not 4085 <= self.nclus < 65525:
            sys.exit("not FAT16 (%d clusters)" % self.nclus)
        self.csize = self.spc * self.bps
        self.f.seek(self.fat0 * self.bps)
        self.fat = bytearray(self.f.read(self.spf * self.bps))
        self.dirty = False

    # --- FAT
    def get(self, c):
        return struct.unpack("<H", self.fat[2 * c:2 * c + 2])[0]

    def put(self, c, v):
        struct.pack_into("<H", self.fat, 2 * c, v)
        self.dirty = True

    def chain(self, c):
        out = []
        while 2 <= c < 0xFFF8:
            if c in out or c >= self.nclus + 2:
                sys.exit("bad cluster chain at %d" % c)
            out.append(c)
            c = self.get(c)
        return out

    def off(self, c):
        return (self.data + (c - 2) * self.spc) * self.bps

    def read_chain(self, c):
        b = b""
        for x in self.chain(c):
            self.f.seek(self.off(x))
            b += self.f.read(self.csize)
        return b

    def free_chain(self, c):
        n = 0
        for x in self.chain(c):
            self.put(x, 0)
            self.f.seek(self.off(x))
            self.f.write(bytes(self.csize))
            n += 1
        return n

    def alloc(self, n):
        free = [c for c in range(2, self.nclus + 2) if self.get(c) == 0][:n]
        if len(free) < n:
            sys.exit("disk full")
        for i, c in enumerate(free):
            self.put(c, free[i + 1] if i + 1 < n else 0xFFFF)
        return free

    def write_data(self, clusters, blob):
        for i, c in enumerate(clusters):
            chunk = blob[i * self.csize:(i + 1) * self.csize]
            self.f.seek(self.off(c))
            self.f.write(chunk + bytes(self.csize - len(chunk)))

    def flush(self):
        if self.dirty:
            for n in range(self.nfat):
                self.f.seek((self.fat0 + n * self.spf) * self.bps)
                self.f.write(self.fat)

    def save(self):
        self.flush()
        with open(self.path, "wb") as out:
            out.write(self.f.getvalue())

    # --- directories. A directory is a list of groups; a group is the list
    #     of 32-byte slots of one live entry (its long-name slots, then the
    #     entry itself). start = 0 is the root directory.
    def read_dir(self, start):
        if start == 0:
            self.f.seek(self.root * self.bps)
            raw = self.f.read(self.rootent * 32)
        else:
            raw = self.read_chain(start)
        groups, pend = [], []
        for i in range(len(raw) // 32):
            x = bytes(raw[32 * i:32 * i + 32])
            if x[0] == 0:
                break
            if x[0] == 0xE5:
                pend = []
                continue
            if x[11] & 0x0F == 0x0F:
                pend.append(x)
                continue
            groups.append(pend + [x])
            pend = []
        return groups

    def write_dir(self, start, groups):
        raw = b"".join(b"".join(g) for g in groups)
        if start == 0:
            if len(raw) > self.rootent * 32:
                sys.exit("root directory full")
            self.f.seek(self.root * self.bps)
            self.f.write(raw + bytes(self.rootent * 32 - len(raw)))
            return
        cl = self.chain(start)
        need = max(1, (len(raw) + 32 + self.csize - 1) // self.csize)   # + the end marker
        while len(cl) < need:
            new = self.alloc(1)[0]
            self.put(cl[-1], new)
            cl.append(new)
        for c in cl[need:]:                    # a directory that shrank
            self.put(c, 0)
            self.f.seek(self.off(c))
            self.f.write(bytes(self.csize))
        self.put(cl[need - 1], 0xFFFF)
        self.write_data(cl[:need], raw)


def name83(e):
    nm = e[0:8].decode("cp437").rstrip()
    ex = e[8:11].decode("cp437").rstrip()
    return nm + "." + ex if ex else nm


def to83(name):
    base, _, ext = name.upper().partition(".")
    if not base or len(base) > 8 or len(ext) > 3:
        sys.exit("bad 8.3 name: " + name)
    return base.ljust(8).encode("ascii") + ext.ljust(3).encode("ascii")


def stamp():
    t = time.localtime()
    d = ((t.tm_year - 1980) << 9) | (t.tm_mon << 5) | t.tm_mday
    tm = (t.tm_hour << 11) | (t.tm_min << 5) | (t.tm_sec // 2)
    return tm, d


def entry(name11, attr, clus, size):
    tm, d = stamp()
    e = bytearray(32)
    e[0:11] = name11
    e[11] = attr
    struct.pack_into("<HHHH", e, 14, tm, d, d, 0)
    struct.pack_into("<HHHI", e, 22, tm, d, clus, size)
    return bytes(e)


def split(path):
    p = path.replace("/", "\\")
    if len(p) > 1 and p[1] == ":":
        p = p[2:]
    return [x for x in p.split("\\") if x]


def find(groups, name):
    n = to83(name)
    for i, g in enumerate(groups):
        if g[-1][11] & 0x08:                   # the volume label is not a file
            continue
        if g[-1][0:11] == n:
            return i
    return None


def walk_to(v, parts):
    "start cluster of the directory named by parts (0 = root)"
    start = 0
    for p in parts:
        g = v.read_dir(start)
        i = find(g, p)
        if i is None or not g[i][-1][11] & 0x10:
            sys.exit("no such directory: " + p)
        start = struct.unpack("<H", g[i][-1][26:28])[0]
    return start


def rm_tree(v, start):
    n = 0
    for g in v.read_dir(start):
        e = g[-1]
        if e[0:1] == b"." or e[11] & 0x08:
            continue
        c = struct.unpack("<H", e[26:28])[0]
        if e[11] & 0x10:
            n += rm_tree(v, c)
        elif c:
            n += v.free_chain(c)
    return n + v.free_chain(start)


def cmd_rm(v, path):
    parts = split(path)
    d = walk_to(v, parts[:-1])
    g = v.read_dir(d)
    i = find(g, parts[-1])
    if i is None:
        sys.exit("not found: " + path)
    e = g[i][-1]
    c = struct.unpack("<H", e[26:28])[0]
    n = rm_tree(v, c) if e[11] & 0x10 else (v.free_chain(c) if c else 0)
    del g[i]
    v.write_dir(d, g)
    print("rm %s: %d cluster(s) freed and zeroed" % (path, n))


def cmd_put(v, host, path):
    blob = open(host, "rb").read()
    parts = split(path)
    d = walk_to(v, parts[:-1])
    g = v.read_dir(d)
    i = find(g, parts[-1])
    if i is not None:
        e = g[i][-1]
        if e[11] & 0x10:
            sys.exit("is a directory: " + path)
        c = struct.unpack("<H", e[26:28])[0]
        if c:
            v.free_chain(c)
    need = (len(blob) + v.csize - 1) // v.csize
    cl = v.alloc(need) if need else []
    v.write_data(cl, blob)
    new = [entry(to83(parts[-1]), 0x20, cl[0] if cl else 0, len(blob))]
    if i is None:
        g.append(new)
    else:
        g[i] = new
    v.write_dir(d, g)
    print("put %s: %d bytes, %d cluster(s)%s" % (path, len(blob), need, "" if i is None else ", replaced"))


def cmd_mkdir(v, path):
    parts = split(path)
    d = walk_to(v, parts[:-1])
    g = v.read_dir(d)
    if find(g, parts[-1]) is not None:
        sys.exit("exists: " + path)
    c = v.alloc(1)[0]
    body = entry(b".          ", 0x10, c, 0) + entry(b"..         ", 0x10, d, 0)
    v.write_data([c], body)
    g.append([entry(to83(parts[-1]), 0x10, c, 0)])
    v.write_dir(d, g)
    print("mkdir %s: cluster %d" % (path, c))


def cmd_cat(v, path):
    parts = split(path)
    g = v.read_dir(walk_to(v, parts[:-1]))
    i = find(g, parts[-1])
    if i is None:
        sys.exit("not found: " + path)
    e = g[i][-1]
    sys.stdout.buffer.write(v.read_chain(struct.unpack("<H", e[26:28])[0])[:struct.unpack("<I", e[28:32])[0]])


def cmd_ls(v, start=0, depth=0):
    for g in v.read_dir(start):
        e = g[-1]
        if e[0:1] == b"." or e[11] & 0x08:
            continue
        c = struct.unpack("<H", e[26:28])[0]
        if e[11] & 0x10:
            print("%s%s\\" % ("  " * depth, name83(e)))
            cmd_ls(v, c, depth + 1)
        else:
            print("%s%-13s %8d" % ("  " * depth, name83(e), struct.unpack("<I", e[28:32])[0]))


def cmd_check(v):
    bad = []
    owner = {}

    def claim(c, who, want=None):
        cl = v.chain(c) if c else []
        for x in cl:
            if x in owner:
                bad.append("cluster %d in both %s and %s" % (x, owner[x], who))
            owner[x] = who
        if cl and v.get(cl[-1]) < 0xFFF8:
            bad.append("%s: chain ends in %04X" % (who, v.get(cl[-1])))
        if want is not None and len(cl) != want:
            bad.append("%s: %d clusters, size needs %d" % (who, len(cl), want))

    def walk(start, path, parent):
        groups = v.read_dir(start)
        for g in groups:
            e = g[-1]
            c = struct.unpack("<H", e[26:28])[0]
            sz = struct.unpack("<I", e[28:32])[0]
            if e[11] & 0x08:
                continue
            if e[0:1] == b".":
                want = start if e[0:2] == b". " else parent
                if e[11] & 0x10 and c != want:
                    bad.append("%s%s points to %d, expected %d" % (path, name83(e), c, want))
                continue
            who = path + name83(e)
            if e[11] & 0x10:
                claim(c, who + "\\")
                walk(c, who + "\\", start)
            else:
                claim(c, who, (sz + v.csize - 1) // v.csize)

    walk(0, "C:\\", 0)
    used = free = dirty = 0
    for c in range(2, v.nclus + 2):
        if v.get(c) == 0:
            free += 1
            v.f.seek(v.off(c))
            if v.f.read(v.csize) != bytes(v.csize):
                dirty += 1
        else:
            used += 1
            if c not in owner:
                bad.append("cluster %d allocated (%04X) but belongs to nothing" % (c, v.get(c)))
    if dirty:
        bad.append("%d free cluster(s) are not zero" % dirty)
    for n in range(1, v.nfat):
        v.f.seek((v.fat0 + n * v.spf) * v.bps)
        if v.f.read(v.spf * v.bps) != bytes(v.fat):
            bad.append("FAT copy %d differs from copy 0" % n)
    for b in bad:
        print("FAIL: " + b)
    print("check: %d clusters in %d files and directories, %d free (%d bytes), %d problem(s)"
          % (used, len(set(owner.values())), free, free * v.csize, len(bad)))
    return not bad


def main():
    if len(sys.argv) < 3:
        sys.exit(__doc__)
    cmds, cur = [], []
    for a in sys.argv[2:]:
        if a == "--":
            cmds.append(cur)
            cur = []
        else:
            cur.append(a)
    cmds.append(cur)
    write = any(c and c[0] in ("put", "rm", "mkdir") for c in cmds)
    v = Vol(sys.argv[1], write)
    ok = True
    for c in cmds:
        if not c:
            continue
        op, args = c[0], c[1:]
        v.flush()                              # check reads the FAT copies
        if op == "ls":
            cmd_ls(v)
        elif op == "check":
            ok = cmd_check(v) and ok
        elif op == "cat":
            cmd_cat(v, *args)
        elif op == "put":
            cmd_put(v, *args)
        elif op == "rm":
            cmd_rm(v, *args)
        elif op == "mkdir":
            cmd_mkdir(v, *args)
        else:
            sys.exit("unknown command: " + op)
    if write and ok:
        v.save()
    sys.exit(0 if ok else 1)


main()
