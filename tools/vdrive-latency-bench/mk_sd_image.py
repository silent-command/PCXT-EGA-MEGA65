import struct, os, sys
OUT = "sd.img"
TOT = 262144           # 128 MB
PSTART = 2048
PSEC = TOT - PSTART
BPS = 512
SPC = 64               # 32 KB clusters, typical SD card FAT32
RSVD = 32
NFAT = 2
# solve cluster count
N = (PSEC - RSVD) // (SPC + 2.0/128)
N = int(N)
FATSZ = (N*4 + BPS - 1)//BPS
while RSVD + NFAT*FATSZ + N*SPC > PSEC:
    N -= 1
    FATSZ = (N*4 + BPS - 1)//BPS
print("clusters", N, "fatsz", FATSZ)
FILE_BYTES = 44040192  # 42 MB image file
NCL = (FILE_BYTES + SPC*BPS - 1)//(SPC*BPS)
print("file clusters", NCL)
assert 3+NCL-1 <= N+1

f = open(OUT, "wb")
f.truncate(TOT*BPS)

# ---- MBR
mbr = bytearray(512)
pe = bytearray(16)
pe[0]=0x00; pe[4]=0x0C
pe[1:4] = bytes([0,2,0]); pe[5:8]=bytes([0xFE,0xFF,0xFF])
pe[8:12] = struct.pack('<I', PSTART)
pe[12:16] = struct.pack('<I', PSEC)
mbr[446:462] = pe
mbr[510]=0x55; mbr[511]=0xAA
f.seek(0); f.write(mbr)

# ---- BPB (FAT32)
bs = bytearray(512)
bs[0:3] = b'\xEB\x58\x90'
bs[3:11] = b'MSWIN4.1'
struct.pack_into('<H', bs, 11, BPS)
bs[13] = SPC
struct.pack_into('<H', bs, 14, RSVD)
bs[16] = NFAT
struct.pack_into('<H', bs, 17, 0)      # root entries = 0 for FAT32
struct.pack_into('<H', bs, 19, 0)
bs[21] = 0xF8
struct.pack_into('<H', bs, 22, 0)      # FATSz16 = 0
struct.pack_into('<H', bs, 24, 63)
struct.pack_into('<H', bs, 26, 255)
struct.pack_into('<I', bs, 28, PSTART)
struct.pack_into('<I', bs, 32, PSEC)
struct.pack_into('<I', bs, 36, FATSZ)  # FATSz32
struct.pack_into('<H', bs, 40, 0)
struct.pack_into('<H', bs, 42, 0)
struct.pack_into('<I', bs, 44, 2)      # root cluster
struct.pack_into('<H', bs, 48, 1)      # FSInfo
struct.pack_into('<H', bs, 50, 6)      # backup boot
bs[64] = 0x80
bs[66] = 0x29
struct.pack_into('<I', bs, 67, 0x12345678)
bs[71:82] = b'QNICEBENCH '
bs[82:90] = b'FAT32   '
bs[510]=0x55; bs[511]=0xAA
f.seek(PSTART*BPS); f.write(bs)

# ---- FATs
fat = bytearray(FATSZ*BPS)
def setf(i, v): struct.pack_into('<I', fat, i*4, v & 0x0FFFFFFF)
setf(0, 0x0FFFFFF8); setf(1, 0x0FFFFFFF)
setf(2, 0x0FFFFFFF)               # root dir, one cluster
for i in range(NCL):
    c = 3+i
    setf(c, 0x0FFFFFFF if i == NCL-1 else c+1)

# ---- two deliberately fragmented files, to exercise the extent table and
#      the automatic fallback in M2M/rom/sdblock.asm
#
# FRAG3.VHD   3 runs of 2 clusters  -> 3 extents, must still be mapped
# FRAG16.VHD  12 isolated clusters  -> 12 extents, must fall back
FRAG3_RUNS  = [(1400, 2), (1500, 2), (1600, 2)]
FRAG16_RUNS = [(1700 + 10*i, 1) for i in range(12)]

def chain(runs):
    "cluster numbers of a file, in file order"
    out = []
    for start, n in runs:
        out += list(range(start, start+n))
    return out

def link(runs):
    cl = chain(runs)
    for i, c in enumerate(cl):
        setf(c, 0x0FFFFFFF if i == len(cl)-1 else cl[i+1])
    return len(cl) * SPC * BPS

FRAG3_BYTES  = link(FRAG3_RUNS)
FRAG16_BYTES = link(FRAG16_RUNS)
assert max(chain(FRAG3_RUNS) + chain(FRAG16_RUNS)) <= N+1

for k in range(NFAT):
    f.seek((PSTART+RSVD+k*FATSZ)*BPS); f.write(fat)

# ---- root dir
datalba = PSTART + RSVD + NFAT*FATSZ
rd = bytearray(SPC*BPS)
def mkent(off, name, ext, attr, clus, size):
    e = bytearray(32)
    e[0:8] = name.ljust(8).encode()
    e[8:11] = ext.ljust(3).encode()
    e[11] = attr
    struct.pack_into('<H', e, 20, (clus>>16)&0xFFFF)
    struct.pack_into('<H', e, 26, clus & 0xFFFF)
    struct.pack_into('<I', e, 28, size)
    rd[off:off+32] = e
mkent(0, 'QNICEBEN','CH ', 0x08, 0, 0)
mkent(32, 'FREEDOS','VHD', 0x20, 3, FILE_BYTES)
mkent(64, 'FRAG3', 'VHD', 0x20, FRAG3_RUNS[0][0],  FRAG3_BYTES)
mkent(96, 'FRAG16', 'VHD', 0x20, FRAG16_RUNS[0][0], FRAG16_BYTES)
# a small ROM-sized file whose length is not a multiple of 512, to exercise
# the "whole blocks fast, tail byte-wise" split of SDB_FREAD_FAST
ROM_RUNS   = [(1900, 1)]
ROM_BYTES  = 16384 + 300
SMALL_RUNS = [(1950, 1)]
SMALL_BYTES = 1536 + 100
# A file whose length is an exact multiple of the cluster size, i.e. one that
# ends exactly on a cluster boundary. Seeking such a file to its very end
# makes FAT32$FILE_SEEK walk one step past the last cluster, pick up the
# end-of-chain marker as a cluster number and hand it to FAT32$RW_SIC, whose
# range check lets it through - which on real hardware makes the SD
# controller latch its error state. M2M/rom/sdblock.asm must never seek
# there; see the "stop one block short" rule in SDB_FREAD_FAST.
EXACT_RUNS  = [(1970, 1)]
EXACT_BYTES = SPC * BPS
link(ROM_RUNS)
link(SMALL_RUNS)
link(EXACT_RUNS)
for k in range(NFAT):                       # re-write the FATs, link() above
    f.seek((PSTART+RSVD+k*FATSZ)*BPS); f.write(fat)
mkent(128, 'TESTROM', 'BIN', 0x20, ROM_RUNS[0][0], ROM_BYTES)
mkent(160, 'SMALL', 'BIN', 0x20, SMALL_RUNS[0][0], SMALL_BYTES)
mkent(192, 'EXACT', 'BIN', 0x20, EXACT_RUNS[0][0], EXACT_BYTES)
f.seek(datalba*BPS); f.write(rd)

# ---- file content: byte i = i & 0xFF, only first few sectors + markers
fstart = datalba + (3-2)*SPC
buf = bytes(range(256))*2
f.seek(fstart*BPS); f.write(buf*8)          # first 8 sectors patterned
# marker at LBA 20000 of the file
f.seek((fstart+20000)*BPS); f.write(b'MARK20000'.ljust(512, b'\x5A'))

# ---- content of the fragmented files and of the test ROM: byte at file
#      offset k is (k*31 + 17) & 0xFF, so a block that is fetched from the
#      wrong LBA cannot accidentally compare equal
def fill(runs, nbytes, seed):
    off = 0
    for start, ncl in runs:
        lba = datalba + (start-2)*SPC
        for s in range(ncl*SPC):
            if off >= nbytes: return
            blk = bytes(((off + i)*31 + 17 + seed) & 0xFF for i in range(BPS))
            f.seek((lba+s)*BPS); f.write(blk)
            off += BPS

fill(FRAG3_RUNS,  FRAG3_BYTES,  0)
fill(FRAG16_RUNS, FRAG16_BYTES, 0)
fill(ROM_RUNS,    ROM_BYTES,    0)
fill(SMALL_RUNS,  SMALL_BYTES,  0)
fill(EXACT_RUNS,  EXACT_BYTES,  0)
f.close()
print("image", OUT, "file data starts at abs LBA", fstart, "part LBA", PSTART)
