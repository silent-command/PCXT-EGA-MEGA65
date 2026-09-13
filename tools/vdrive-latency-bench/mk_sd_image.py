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
f.seek(datalba*BPS); f.write(rd)

# ---- file content: byte i = i & 0xFF, only first few sectors + markers
fstart = datalba + (3-2)*SPC
buf = bytes(range(256))*2
f.seek(fstart*BPS); f.write(buf*8)          # first 8 sectors patterned
# marker at LBA 20000 of the file
f.seek((fstart+20000)*BPS); f.write(b'MARK20000'.ljust(512, b'\x5A'))
f.close()
print("image", OUT, "file data starts at abs LBA", fstart, "part LBA", PSTART)
