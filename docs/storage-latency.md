# Storage: why disk access is slow

## Symptom
FreeDOS takes about 57 seconds to boot from the hard-disk image on hardware,
and the first `dir` at the C:\> prompt takes about 40 seconds. Every later
`dir` is instant, because DOS keeps the free-cluster count in the drive
parameter block and the FAT sectors in its buffers.

> **The original note here said "CPU speed makes no difference, which already
> rules out the emulated 8088 and the ISA bus." That was wrong, and it is what
> sent this whole investigation down the wrong road.** Re-measured properly:
> the same boot takes 64 s at 4.77 MHz and 35 s at "Max". The machine is
> CPU-bound. See "What it actually was, 2026-09-13" at the end. Everything
> between here and there is still worth reading as a description of the
> storage path, but not as a diagnosis of the boot time.

## What a sector costs (measured)
`tools/vdrive-latency-bench/` runs the real QNICE monitor ROM and FAT32
library in the QNICE emulator over the exact instruction sequence of
`M2M/rom/shell.asm:_HDR_SD_LOOP`, for one 512-byte vdrive block:

| stage | time | share |
|---|---|---|
| `mgmt_bridge` request, CDC, 256-word mgmt stream | ~40 us | 0.4 % |
| QNICE poll latency in the shell main loop | 10-50 us | <0.5 % |
| `VD_SD_SEEK` (0 for a strictly sequential block, else ~21 us x LBA) | 0 .. 1.9 s | 0 .. 99 % |
| `SD$READ_BLOCK` (SPI at 12.5 MHz plus card latency) | 0.4-1 ms | ~5 % |
| `HANDLE_DRV_RD` byte loop | 10.45 ms | ~95 % |

80,644 instructions per block, 522,346 QNICE cycles, 10.45 ms at 50 MHz,
i.e. about 46 KB/s. Inside the byte loop, `f32_fread` is 68 % of it: about
107 instructions of FAT32 bookkeeping per byte (`READ_FDH` revalidates the
cluster and sector for every single byte) around two MMIO accesses, and the
four `VD_CAD_WRITE` calls spend 5 of their 9 instructions re-selecting the
RAMROM device and window that never change during a block.

The RTL is not the bottleneck: `mgmt_bridge.sv` issues exactly one block
request per sector and `vd_glue.vhd` adds only clock-crossing flops.

## What the hardware timing says
**Superseded - see "What it actually was, 2026-09-13" at the end of this
document. The boot is CPU-bound, not I/O-bound, and the reasoning below was
wrong. It is kept because the mistake is instructive.**

A FreeDOS boot reads roughly 350-600 sectors (kernel, COMMAND.COM, the
CONFIG.SYS drivers). At 57 seconds that is over 100 ms per sector, about ten
times the firmware cost above. Two candidates for the difference, to be
settled with the `hdd=` sector counter on the status line:

* the O(LBA) seek. `VD_SD_SEEK` walks the file position one sector at a time
  at 123 instructions per step, so a non-sequential read at LBA 5,000 costs
  about 105 ms on its own and one at the far end of a 42 MB image about 1.9 s.
  A boot reads files scattered over the volume, so most reads pay it.
* the SD controller's retry path. `M2M/QNICE/vhdl/sd_spi.vhd` re-initialises
  the card at 390 kHz on a bad R1, up to 200 times per command; its own header
  says `READ_BLOCK` "randomly failed" on some SDHC cards.

A first `dir` should read only about 87 sectors on this image (2 root-directory
sectors plus the 85-sector FAT walk for "bytes free"), so the 40 seconds is
the same per-sector problem, not a different one.

Neither candidate was it. The `hdd=` counter later said 623 sectors for a
boot plus a `dir`, and the per-request timing said 15.3 ms each: about 9.5 s
of disk activity inside 103 s of wall clock. The unexamined step was dividing
wall-clock time by sector count and assuming the sectors explained it.

## The image
`sdcard/pcxt/freedos.vhd`: MBR partition type 06 at LBA 17, 87,091 sectors;
BPB `FRDOS5.1`, 512 B/sector, 4 sectors/cluster, 1 reserved, 2 FATs of 85
sectors, 512 root entries, 21,722 clusters, so FAT16. 24 root entries in use,
highest allocated cluster 2,491.

## Fixes, costed in the bench
| variant | cycles | per block | speedup |
|---|---|---|---|
| current | 522,346 | 10.45 ms | 1x |
| hoist the device/window selection out of the byte loop | 366,698 | 7.33 ms | 1.4x |
| read the byte from the SD controller's own 512-byte buffer instead of `f32_fread` | 36,864 | 0.74 ms | 14x |
| plus an auto-incrementing push register in `vdrives.vhd` | 21,504 | 0.43 ms | 24x |

The 14x variant also removes the O(LBA) seek: walk the image's cluster chain
once at mount and keep the base SD LBA (a freshly copied image is contiguous)
or a small cluster table, then a block is one `SD$READ_BLOCK` at a computed
LBA. Random access at the end of the image drops from ~1.9 s to under a
millisecond. It applies symmetrically to `HANDLE_DRV_WR`, which today also
pays an `f32_fflush` (an extra SD block write) per block.

(Both of those are real and were implemented. What they buy is bulk transfer
rate, not boot time: see the end of this document.)

Floppies use the same path and cost the same per sector; their LBAs stay
under 2,880 so the seek term is small there.

`M2M/rom` and `M2M/vhdl` are part of this repo (only `M2M/QNICE` and
`CORE/PCXT-EGA_MiSTer` are submodules), and `shell.asm` is already patched by
this port, so all three fixes are ours to make.

## Hardware baseline, 2026-09-13
Measured on the R6 with the V0.7.1 build, from the serial log after a JTAG
load (no keyboard needed, the core loads its ROMs by itself):

```
[   1.8s] Using config file: /m2m/m2mcfg
LOADING ROM #0000[   2.0s] : OK      pcxt.rom,     16 KB
LOADING ROM #0001[   2.2s] : OK      ega_bios.rom, 16 KB
LOADING ROM #0002[   2.3s] : OK      xtide.rom,    12 KB
```

About 0.2 s per 16 KB, i.e. ~80 KB/s, the same rate the emulator predicts for
the per-byte `f32_fread` path. The CRT/ROM autoload loop in
`M2M/rom/crts-and-roms.asm` (`_CRMA_3`) has the same shape as the vdrive loop,
so it is the one part of this path that can be measured on hardware without
touching the keyboard.

---

# What was done: direct SD block access (`M2M/rom/sdblock.asm`)

Implemented; byte-exact against the old path in the emulator. **Revision 2,
after the first hardware run failed** - see "Hardware run 1" below, which is
the most useful part of this section.

## The idea
The FAT32 library only offers a byte API, and its `f32_fseek` walks the
cluster chain from the start of the file. Both costs are avoidable, because
the on-disk layout of an image file does not change while it is mounted:

1. **At mount time** (`LOAD_IMAGE`, SD-direct branch) `SDB_MAP_BUILD` walks
   the file's FAT cluster chain once and condenses it into a small *extent
   table*: runs of physically consecutive clusters, each stored as
   `{amount of blocks, absolute SD LBA of the first one}`. A freshly copied
   image is one single extent; up to `SDB_MAX_EXT` = 8 are kept.
2. **Per block** `SDB_LBA` turns "block N of the image" into an absolute SD
   card LBA, and the block is then one `SD$READ_BLOCK` plus a tight copy loop
   out of the 512-byte buffer of the SD controller into the drive buffer,
   with the RAMROM device and 4k window selection hoisted out of the loop.
   `f32_fread` and `VD_SD_SEEK` are gone.
3. **Writes** are symmetric: the drive buffer is copied into the SD
   controller buffer and written with one `SD$WRITE_BLOCK`.
4. The **CRT/ROM auto loader** (`crts-and-roms.asm`, `_CRMA_3`) had the same
   per-byte defect and uses the same machinery through `SDB_FREAD_FAST`.
5. **Fallback is automatic and silent** everywhere, see "Fail-safe" below.

---

## Hardware run 1: what broke, and why the bench could not see it

Symptom on the R6: the ROM auto loader ran the fast path (the serial
timestamp moved from 1.8 s to 1.9 s, i.e. faster than the 0.2 s it used to
take) and then went fatal out of `_CRMA_3`, because the very next
`f32_fread` returned a non-zero, non-EOF error code.

The chain, reconstructed from the sources:

1. `SDB_FREAD_FAST` finished by seeking the file handle to
   `whole blocks * 512`, which for a ROM whose size is a multiple of 512 is
   **exactly the end of the file**.
2. `FAT32$FILE_SEEK` implements a seek by pushing the index forward one
   sector at a time (`_F32_FS_IPUSH`). Pushing to the very end of a file that
   ends on a cluster boundary takes one step *past* the last cluster:
   `_F32_RFDH_INCC` reads the FAT, finds the end-of-chain marker
   `0x0FFFFFFF`, and - in seek mode - stores it into `FAT32$FDH_CLUSTER` and
   returns success without validating it.
3. `_F32_FS_INDEX` then calls `FAT32$RW_SIC` with that cluster. Its range
   check is
   `CMP 0, R11 / RBRA ok, Z / CMP 0, R10 / RBRA ok, Z / error`, i.e. it only
   rejects the product when **both** high words are non-zero. For
   `(0x0FFFFFFF - 2) * 64` the top word is zero, so the check passes and the
   library issues a real `SD$READ_BLOCK` at a wild LBA.
4. The real card rejects it. The SD controller then **latches its error
   state** - `sysdef.asm` says it plainly: "you need to reset the controller
   to go on", and `sdcard.vhd`'s `sds_error` has no exit other than a reset.
   From that moment `SD$WAIT_BUSY` returns an error immediately, so every
   subsequent library access fails too.
5. The next library access is the `f32_fread` in `_CRMA_3`. It returns the
   device error, `_CRMA_3` treats it as "file read error", fatal.

Why the emulator passed: `M2M/QNICE/emulator/sd.c` masks the block address
to 28 bits, seeks past the end of the image file, lets the read fail silently
and **never sets an error bit** - `SD_CSR` reads back a constant `0x2000`. A
wild LBA is a no-op there, and there is no error state to latch. On top of
that the bench image uses 32 KB clusters and every test file fits inside one
cluster, so the seek never crossed a cluster boundary in the first place.

So the bug needed three things the bench did not have: a file ending on a
cluster boundary, a card that rejects a bad LBA, and a controller that stays
broken afterwards.

---

## Fail-safe by construction (revision 2)

**Rule 1 - never seek to the end of a file.** `SDB_FREAD_FAST` now always
leaves at least one whole block to the byte loop, so the position it hands
over is strictly inside the file, the push loop can never walk off the chain,
and the caller reaches EOF through the library exactly as it always did. It
also verifies afterwards that `FAT32$FDH_ACCESS` really is where it asked
for, and rewinds to 0 and reports "nothing done" if it is not. `exact.bin` in
the bench is a file that ends exactly on a cluster boundary, precisely to
keep this honest.

**Rule 2 - reset the SD controller after any SD error.** `SDB_SDERR` issues
`SD$RESET` after every failed `sd_r_block` / `sd_w_block`, so a failure in the
fast path can no longer poison the library's next access. This alone turns
the observed fatal into "slow but correct".

**Rule 3 - the FAT32 library must not be able to tell we were here.** The
512-byte "sector buffer" of the library *is* the hardware buffer of the SD
controller; the device handle only remembers *which* file handle filled it
(`FAT32$DEV_BUFFERED_FDH`). Revision 1 solved that by pointing
`FAT32$DEV_BUFFERED_FDH` at a dummy handle, i.e. by reaching into the
library's bookkeeping. That is gone. Now:

* `SDB_GUARD_IN` works out, **before** anything is touched, which sector the
  library believes is in the buffer, and whether that sector's LBA can be
  computed at all. If it cannot, the fast path is refused and nothing is
  touched. A dirty buffer is written back through the library first, and if
  that write-back fails the fast path is refused as well.
* `SDB_GUARD_OUT` reads exactly that sector back, so the buffer holds what it
  held before. The library is left in a state it produced itself.
* `SDB_FREAD_FAST`, which moves the file position anyway, restores the
  library the library's own way: its final `f32_fseek` unconditionally
  re-reads the sector and re-claims ownership.
* `SDB_MAP_BUILD` is transparent for the same reason: it guards on the way in
  and restores on the way out, whether it succeeds or gives up.

The only remaining poke is `SDB_ORPHAN`, and it runs only when the
*restoring* read itself fails, i.e. when the card is already broken. Even
then it is better than leaving the library with a buffer holding something
other than it believes. It uses an all-zero dummy handle rather than 0,
because `FAT32$FLUSH` returns immediately when called with `R8 = 0` and then
leaves `R9` - its error code - untouched, and `FAT32$FILE_SEEK` checks that
stale `R9` right after calling it, so a seek would silently do nothing. (That
latent trap is in the stock library too: `f32_mnt_sd` also leaves
`BUFFERED_FDH` at 0.)

**Rule 4 - validate every LBA before issuing it.** `SDB_CLULBA` is the single
place that turns a cluster plus a sector into an LBA. It rejects clusters
below 2, anything at or above `0x0FFFFFF0`, clusters outside 28 bits, sectors
outside the cluster, a zero sectors-per-cluster, a multiply that does not fit
in 32 bits and an addition that carries out. `SDB_LBA` and `_SDB_EMIT` both
go through it.

**Rule 5 - one instruction between `IO$SD_DATA_POS` and `IO$SD_DATA`.** The
SD controller's buffer is a block RAM with a registered output
(`byte_bram.vhd` clocks `data_o`), and the monitor's own `SD$READ_BYTE`
always has one instruction in between. Revision 1's tightest loops had none.
They now match the monitor, at a cost of about one instruction per byte.

Every bail-out reason is recorded in the map (`SDB_M_BAIL`) and in
`SDB_FF_STAT`, so it can be read out even without the serial log.

---

## Hardware run 2: the map is right, the vdrive is still slow

The instrumented build produced, at mount of the hard disk image:

```
SDB: build fdh=81B4 dev=814A spc=0008 size=02A97600 clus=00046ED8
SDB: map ext=0001 tblk=000154BB lba0=00244DE4 bail=0000
```

512-byte sectors, **4 KB clusters (spc=8)**, one extent, 87,227 whole blocks,
no bail - on two independently written copies of the image. The ROM auto load
got measurably faster on the same build, so `sdblock.asm` itself works. The
FreeDOS boot and the first `dir` did not change at all.

Note what `spc=8` means for "Hardware run 1": a 16 KB ROM is exactly 4
clusters, so it *did* end on a cluster boundary and the seek-past-the-chain
really was reachable. That story holds.

For the vdrive there are only two possibilities, and they need different
answers:

* `HANDLE_DRV_RD` refuses the fast path on every request, or
* it takes it, and the time goes somewhere the firmware does not control -
  in which case the premise of this work is wrong for the vdrive path.

The second is not far-fetched. This document's own first measurement already
said so: a boot reads 350-600 sectors in 57 s, i.e. **over 100 ms per
sector**, while the whole firmware byte loop only ever cost 10.45 ms. Even
before this work, 90 % of the time per sector was somewhere else. Removing
the 10 % is invisible. The `VD_SD_SEEK` term was the candidate for the other
90 % - and that term is now provably gone, so if the boot time is unchanged,
it was never the seek either.

### What the third instrumented build measures

Per virtual drive block request (`SDB_DBG_RD0` / `SDB_DBG_RD1` in
`sdblock.asm`, hooked into `HANDLE_DRV_RD`):

```
SDB: rd drv=0002 sz=0200 pos=02A97400 st=0000 lba=00244DE4 fw=0000889C gap=00003A1F
```

* `drv`, `sz` (`VD_SIZEB`), `pos` (`VD_BYTES_H:L`) - the request as the core
  posed it.
* `st` - the decision, from `SDB_RD_STAT`: **0 = fast path taken**, 1 =
  `VD_SIZEB` was not 512, 2 = position not block aligned, 3 = no usable map
  for this drive or handle, 4 = block outside the mapped file, 5 = the
  library's buffer could not be made restorable, 6 = SD card error. This
  alone settles possibility one.
* `lba` - the LBA it computed, when it was taken.
* `fw` - QNICE cycles spent **inside `HANDLE_DRV_RD`**, i.e. everything the
  firmware controls. 50,000 cycles = 1 ms. 0.7 ms is about `0000 88B8`;
  10 ms is about `0007 A120`.
* `gap` - QNICE cycles between the **end of the previous request and the
  start of this one**: the core, the bridge, the SD controller's own latency
  and the poll interval of the Shell main loop. **If `gap` dwarfs `fw`, the
  firmware was never the bottleneck** and the remaining work is in
  `mgmt_bridge.sv` / `vd_glue.vhd` / `sd_spi.vhd`, not here.

The first 8 requests after each mount are logged, plus one in every 512 after
that, so the steady state is visible without flooding the serial line and
without changing the timing.

### Hardware sector counter

`CORE/vhdl/main.vhd` now counts rising edges of `blk_ack(2)` - the hard disk -
into a free-running 16-bit counter and publishes it alone as the third status
word, relabelled `hdd=` in `CORE/m2m-rom/m2m-rom.asm`. The status line prints
on every OSM selection, so: open the OSM, note `hdd=`, boot, open the OSM,
note it again. Wall clock divided by the difference is the true cost of one
sector, with no arithmetic about how many sectors DOS "should" read.

The 8-bit `blk=` counters for floppy A are still maintained internally, they
are just no longer published.

---

## Hardware run 3: 165 ms per sector, and why no `SDB: rd` line appeared

The `hdd=` counter did its job: **623 sectors across a 64 s boot plus a 39 s
`dir`, i.e. about 165 ms per 512-byte sector.** The firmware byte loop that
this whole exercise replaced only ever cost 10.45 ms, so **94 % of a sector
has always been somewhere the firmware does not control**, and the 0.70 ms
the fast path now costs is 0.4 % of it. That is the headline, and it was
already visible in the very first measurement at the top of this document
(350-600 sectors in 57 s is over 100 ms per sector); it just had not been
confronted.

### The logging bug

Not one `SDB: rd` line printed, while the map lines printed normally. Cause:
`#define SDB_DEBUG` lived in `sdblock.asm`, which `shell.asm` includes at its
**end**. The C preprocessor runs once, top to bottom, over the concatenated
source, so while it was processing `HANDLE_DRV_RD`, `LOAD_IMAGE` and
`crts-and-roms.asm` - all of them *above* that include - the macro did not
exist yet and every `#ifdef SDB_DEBUG` block in them was silently dropped.
Only the logging inside `sdblock.asm` itself, which comes after the define,
survived. `grep -c "RSUB SDB_DBG_RD0" m2m-rom.lis` said `0`.

The switch now lives in its own file, `M2M/rom/sdblock_cfg.asm`, included as
the **first line of shell.asm**, so it is visible everywhere. The built ROM is
now checked for the call sites rather than assumed:

```
SDB_DBG_ARM 1   SDB_DBG_RD0 1   SDB_DBG_RD1 1   SDB_SDRD 5   SDB_SDWR 1
```

### "Successfully loaded disk image to buffer RAM" is a red herring

`LOAD_IMAGE` prints `LOG_STR_LOADOK` at `_LI_FREAD_EOF` for every virtual
drive, and the SD-direct branch jumps there too, so the wording appears even
though nothing was loaded into buffer RAM. Drive 2 really is SD-direct: the
map build only runs in the SD-direct branch, and it ran. To remove the doubt
from the log rather than from the reasoning, every mount now prints

```
SDB: mount drv=0002 buf=AAAA
```

where `buf=AAAA` is `VD_BUF_SDDIRECT`, and every request line carries `drv=`.

### What the next build measures

The `SDB: rd` line now decomposes a sector completely:

```
SDB: rd drv=0002 sz=0200 pos=02A97400 st=0000 lba=00244DE4 fw=00042F80 gap=0096ACA0 sdn=0002 sdcyc=00041A70 sdlast=00020D38
```

* `st=0000` means the fast path was taken (the codes are listed below).
* `fw` - cycles inside `HANDLE_DRV_RD`, **including** the card accesses.
* `sdn` - how many SD card block accesses this one request made, `sdcyc` how
  many cycles they took together, `sdlast` how long the last single one took.
  Every card access of the fast path goes through `SDB_SDRD` / `SDB_SDWR`,
  which is where the timing is taken.
* `gap` - cycles between the end of the previous request and the start of
  this one: the core, the bridge and the poll interval of the Shell main
  loop. Nothing the firmware does is in here.

50,000 cycles = 1 ms. `fw - sdcyc` is the pure firmware cost (expect about
`0000 88B8`). The three numbers `sdcyc`, `fw - sdcyc` and `gap` add up to the
165 ms, and whichever one is large is the answer.

### How it came out

The prediction made here before the measurement was that neither the card
alone nor the firmware would explain 165 ms and that `gap` would be the
largest of the three. That is what happened: 0.40 ms firmware, 3.03 ms of
card accesses, 11.8 ms of gap. The full decomposition and what it means is in
"What it actually was, 2026-09-13" at the end of this document; the second of
those card accesses has since been removed, see "The second SD access,
removed".

## Serial log for the next hardware run

`M2M/rom/sdblock_cfg.asm` is the single switch, and shell.asm includes it as
its very first line so that every `#ifdef SDB_DEBUG` in the tree sees it:

```
#define SDB_DEBUG
```

**It is currently OFF** (`;#define SDB_DEBUG`), so the tree builds the
shipping firmware and `m2m-rom.rom` matches. Remove the `;` and rebuild
(`CORE/m2m-rom/make_rom.sh`) to get the instrumented one. Nothing else has to
change.

Whichever way it is set, check the built listing rather than trusting it -
this is the one-pass preprocessor trap, and it is silent:

```
grep -c "RSUB SDB_DBG_RD0," CORE/m2m-rom/m2m-rom.lis   # 1 with the log, 0 without
grep -c "RSUB SDB_SDRD,"    CORE/m2m-rom/m2m-rom.lis   # 3, always: the fast path itself
```

The log goes to the serial console at boot - no keyboard involved, since the
ROM auto loader runs by itself, and the vdrive lines appear as soon as an
image is mounted.

What it prints, per ROM file:

```
SDB: build fdh=8B7E dev=8E6E spc=0040 size=00004000 clus=0000076C
SDB: map ext=0001 tblk=00000020 lba0=0001E2E0 bail=0000
SDB: blk 0000 -> lba 0001E2E0
...
SDB: ff stat=0000 blks=001F win=0003 adr=7E00 pos=00003E00 cluster=0000076C sector=001F
```

* `build` - the file handle, its device handle, the card's sectors per
  cluster, the file size and the file's first cluster. **`spc` is the number
  that decides whether the trigger geometry above is present at all.**
* `map` - extents found, whole blocks in the file, the LBA of the first
  extent, and `bail` = why there is no map (0 = fine; 6 = too fragmented,
  7 = FAT read error, 8 = illegal cluster, 9 = chain shorter than the file,
  10 = LBA out of range, 11 = the buffer could not be made restorable, 12 =
  the restoring seek failed; see the `SDB_B_*` constants).
* `blk` - every block that is fetched, with the LBA it was mapped to. A wrong
  map shows up here immediately.
* `ff` - what `SDB_FREAD_FAST` did: `stat` (0 = clean hand-over), blocks
  transferred, the 4k window and address it hands back, and the file handle's
  position, cluster and sector afterwards.

Plus, on any problem:

```
SDB: SD ERROR code=....                 (and the controller is reset)
SDB: buffer could not be restored
SDB: f32_fread error in _CRMA_3 code=....
```

The last one is the hook in `crts-and-roms.asm` that prints exactly the error
code the byte loop sees before it goes fatal.

## Bench evidence
`wsl -d Ubuntu bash tools/vdrive-latency-bench/run.sh`

The bench assembles the **real** `M2M/rom/sdblock.asm` (only the handful of
`shell_vars.asm` variables it needs are stubbed, see `bench_env.asm`) and runs
it against the real FAT32 library on a generated FAT32 card image.

| check | what it covers |
|---|---|
| T1 | blocks 0, 1, 63, 64, 65 (cluster boundary), 20000, 65537, 86014, 86015 (last) of the 42 MB image, plus two blocks past the end which must fall back |
| T1b | 16 pseudo-random blocks spread over the whole image |
| T2 | a 256-byte request and an unaligned request must fall back |
| T3a/b/c | read after write: fast write then library read, fast write then fast read, library write then fast read |
| T4 | `frag3.vhd`, three extents: **all 384 blocks** compared one by one |
| T5 | `frag16.vhd`, twelve extents: the map must be refused and the entry point must report the fallback |
| T6a | `SDB_FREAD_FAST` on a 1636-byte file: window, address, hand-over position, every transferred byte, and the byte-wise tail |
| T6b | the same on a 16684-byte file, so the 4k window wrap is exercised |
| T6c | **`exact.bin`, whose length is exactly one cluster** - the geometry that broke the hardware. The hand-over position must stay one block short of the end |
| T7a | after a map build that *gives up*, the very next `f32_fread` must still return the right bytes (revision 1 had no such test, and this is the property that matters) |
| T7b | a fast vdrive block read must not disturb a second, unrelated open file handle on the same device |

T6a/b/c read their tails through **two file handles at once**, alternating,
so the two handles fight over the library's single sector buffer on every
byte. All checks pass.

Cost, per 512-byte block (`cycles ~= 3*I + 2*R + 2*W` at 50 MHz):

| path | cycles | per block | KB/s | vs. before |
|---|---|---|---|---|
| read, before (`f32_fread` + 4x `VD_CAD_WRITE`) | 522,346 | 10.45 ms | 48 | 1x |
| **read, after** | **34,944** | **0.699 ms** | **715** | **14.9x** |
| write, before (`f32_fwrite` per byte + `f32_fflush`) | 483,059 | 9.66 ms | 52 | 1x |
| **write, after** | **33,900** | **0.678 ms** | **738** | **14.2x** |

CRT/ROM auto load, one 16 KB ROM file:

| path | instructions | cycles | at 50 MHz | KB/s |
|---|---|---|---|---|
| byte loop (`_CRMA_3`) | 1,910,337 | 11,998,565 | 240 ms | 67 |
| **`SDB_FREAD_FAST` + tail** | **213,335** | **1,420,937** | **28.4 ms** | **563** |

The safety work costs some speed against revision 1 (which measured 33,496 /
32,478 / 1,090,543): the guard adds one restoring SD block read per vdrive
block, and the ROM path now hands one whole block to the byte loop.

One-off cost at mount: `SDB_MAP_BUILD` on the 42 MB image (1344 clusters of
32 KB) is 177,746 instructions, about 1.1 M cycles or 22 ms, plus 11 SD block
reads for the FAT sectors.

These are firmware figures only: the emulator's SD card is instantaneous, so
real `SD$READ_BLOCK` / `SD$WRITE_BLOCK` time (0.4-1 ms) has to be added to
both columns - and note that the guard means the vdrive path now issues
**two** SD reads per block where the old path issued one.

## Effect on hardware, measured
What these predictions got right and wrong is settled at the end of this
document; the short version is that the per-sector transfer numbers held up
and the boot-time conclusion drawn from them did not.

* **CRT/ROM auto load**, the keyboard-free check: ~0.2 s per 16 KB file
  before, ~0.07 s after, i.e. 88 KB/s to 220 KB/s. Less than the 8x the
  emulator predicts for the firmware alone, because the emulator's SD card
  costs nothing and the real one does not; the card is now the limit on this
  path.
* **One vdrive sector**: about 12 ms of firmware plus card time before,
  **3.4 ms** after the first version and **about 1.9 ms** once the restoring
  read was dropped (0.40 ms firmware plus one ~1.5 ms card access). Bulk I/O
  - copying files, loading large programs, floppy transfers - is roughly
  3.5x faster, now closer to 6x.
* The O(LBA) `VD_SD_SEEK` term disappears completely: at LBA 5,000 it was
  about 105 ms on its own, near the end of the image about 1.9 s, and it is
  now 0. This turned out to matter far less than expected, because DOS reads
  are mostly sequential and the term was rarely paid.
* **Boot time is not affected**, because it was never disk-bound. See "What
  it actually was".
* **Writes** lose the per-byte library work, the read-before-modify and the
  `f32_fflush` block write.

## What can only be proven on hardware
* Everything in "Hardware run 1" was found by reading the sources after the
  fact. The next run either confirms it (the log shows a clean `ff stat=0000`
  and the ROMs load) or shows exactly where it goes wrong instead.
* The **vdrives.vhd register protocol**. The emulator has no vdrives device,
  so `SDB_SD2VD` and `SDB_VD2SD` write to and read from plain RAM there. The
  register sequence is the same as the existing, working `VD_CAD_WRITE` /
  `VD_DRV_READ` code, only with the device and window selection hoisted out.
  What is new is that the write-enable strobe is about 4 QNICE clocks wide
  instead of about 30, and that `VD_B_DIN` is read 2 instructions after
  `VD_B_ADDR` is written instead of 6. Port A of the block buffer in
  `CORE/vhdl/vd_glue.vhd` is clocked by `qnice_clk` with no clock-domain
  crossing on the buffer port and one clock of read latency, plus one
  register stage in `vdrives.vhd`, so both margins look fine - but only
  hardware can confirm it.
* **`sd_rd`/`sd_wr` acknowledgement timing.** The fast read asserts `sd_ack`
  after the SD block read and holds it for the 0.7 ms copy instead of
  10.45 ms; the fast write asserts it after the block write, as before.
  Shorter is the safe direction for the constraints in
  `docs/floppy-write-multisector.md`, but the floppy controller's tolerance
  is only observable on the real core. Floppies and the hard disk share this
  path.
* **The real SD card's retry path** in `M2M/QNICE/vhdl/sd_spi.vhd` is
  untouched and could still dominate.
* **Fragmentation of the real `freedos.vhd` on the card.** If boot time does
  not change at all, the file needs more than 8 extents and everything falls
  back; the log's `bail=0006` says so, and recopying to a freshly formatted
  card fixes it.

## Budget
QNICE **ROM**: `END_OF_ROM` moved from `0x58DE` to `0x5E2F` in the shipping
build, i.e. **+1361 words (2722 bytes)**; free ROM space goes from 5922 to
**4561 words**. With `SDB_DEBUG` on it is `0x61E4`, i.e. **3612 words still
free**, so the logging build fits comfortably.

QNICE **RAM**: `HEAP` moved from `0x8200` to `0x82D2`, i.e. **+210 words (420
bytes)**: 3 x 40 words of virtual-drive block map, 40 words for the CRT/ROM
map, 12 words for `SDB_DUMMY_FDH`, 1 word for `SDB_NULL_MAP`, 3 words of
guard and status state, 3 words of per-request status, 11 words of
measurement state, 7 words of SD card timing and 13 words of map-build
scratch. "Free QNICE memory" in the boot log goes from 736 to **526 words**.
Nothing overflows. The RAM cost is the same with and without `SDB_DEBUG`, on
purpose: `SDB_RD_STAT` is readable in the shipping build too.

If more headroom is needed, `SDB_MAX_EXT` (8) is the dial: each extent costs
4 words per map. `SDB_M_SIZE` and `SDB_VD_MAX_N` in `sdblock.asm` and the
literal `.BLOCK 120` in `shell_vars.asm` have to be kept in sync by hand,
because the QNICE assembler segfaults on an expression in `.BLOCK`.

## Two QNICE traps worth remembering
* **`RET` is `MOVE @R13++, R15`** (see `dist_kit/sysdef.asm`), and `MOVE`
  updates Z and N. **Only the Carry survives a `RET`**, so a helper must
  never return a comparison result in Z or N. The first version of the 32-bit
  compare in `SDB_MAP_BUILD` did exactly that and silently turned every file
  into one single extent - invisible on a contiguous image, wrong on a
  fragmented one. That is what the `frag3.vhd` test exists for.
* **`R0..R7` are banked, `R8..R15` are not.** A helper that does `INCRB` (or
  `SYSCALL(enter)`) cannot see its caller's `R0..R7`. Arguments go in
  `R8..R12`, which is why every routine here does.

## Files touched
* `M2M/rom/sdblock.asm` - new, the whole mechanism
* `M2M/rom/shell.asm` - include it, build the map in `LOAD_IMAGE`, invalidate
  all maps when the SD card changes, fast paths in `HANDLE_DRV_RD` and
  `HANDLE_DRV_WR` with the old code kept as the fallback
* `M2M/rom/shell_vars.asm` - the maps, the dummy handle, the guard state
* `M2M/rom/vdrives.asm` - `SDB_INVAL_ALL` from `VD_INIT`
* `M2M/rom/sdblock_cfg.asm` - new, the single SDB_DEBUG switch, included as
  the first line of shell.asm so the preprocessor sees it everywhere
* `M2M/rom/crts-and-roms.asm` - fast path in the ROM auto loader, plus the
  `SDB_DEBUG` hook that logs the error code the byte loop sees
* `CORE/vhdl/main.vhd` - `hdd_ack_cnt`, a free-running 16-bit counter of
  `blk_ack(2)` rising edges, published as `dbg_keys_o` in place of the two
  8-bit floppy-A counters
* `CORE/m2m-rom/m2m-rom.asm` - `DBG_STR_8` relabelled from `" blk="` to
  `" hdd="`
* `tools/vdrive-latency-bench/` - `fastpath.asm` (correctness),
  `romload.asm` (ROM loader cost), `bench_env.asm` (shell variable stubs),
  variants 4-6 in `loop_variants.asm`, fragmented / short / exact-cluster
  test files in `mk_sd_image.py`, and `run.sh` running all of it

Nothing under `M2M/QNICE` or `CORE/PCXT-EGA_MiSTer` (the submodules) was
modified.

## Hardware result, 2026-09-13
The ROM autoload path is the part of this that can be measured without a
keyboard, and it is now correct and faster. Three loads of the same build:

| build | config read | ROM #0 | ROM #1 | ROM #2 | span |
|---|---|---|---|---|---|
| before (V0.7.1) | 1.8 s | 2.0 s | 2.2 s | 2.3 s | ~0.5 s |
| after, run 1 | 1.9 s | 1.9 s | 2.0 s | 2.1 s | ~0.2 s |
| after, run 2 | 1.7 s | 1.9 s | 2.0 s | 2.0 s | ~0.3 s |
| after, run 3 | 1.9 s | 1.9 s | 2.0 s | 2.1 s | ~0.2 s |

44 KB of ROM images: about 88 KB/s before, about 220 KB/s after. That is far
short of the 8x the emulator predicts for the firmware alone, and the reason
is that the emulator's SD model costs nothing: what is left is the real card's
block-read time, roughly 2.3 ms per 512-byte block. The firmware is no longer
the bottleneck on this path; the card is.

The first attempt at this failed on hardware in a way the emulator could not
see. `SDB_FREAD_FAST` seeked the file handle to exactly the end of the file
when the file's length was a multiple of 512. `FAT32$FILE_SEEK` then stepped
one cluster past the last one, stored the end-of-chain marker as the current
cluster and reported success, `FAT32$RW_SIC`'s range check let the resulting
wild LBA through, and the real SD controller latched an error state that only
a reset clears (`sysdef.asm`, `sdcard.vhd` `sds_error`), so every later
library call failed and the mandatory ROM load went fatal. The emulator masks
the address to 28 bits, fails the read silently and always reports a clean
status register, and its test image used 32 KB clusters so the geometry never
arose. The fix leaves at least one whole block to the byte loop so the
hand-over position is always strictly inside the file, resets the SD
controller after any failed block access, and no longer touches the FAT32
library's buffered-sector bookkeeping at all.

## What it actually was, 2026-09-13
The per-request instrumentation finally decomposed a sector, on hardware,
with the fast path active (50,000 QNICE cycles = 1 ms):

| stage | time per 512-byte sector |
|---|---|
| firmware work in `HANDLE_DRV_RD` | 0.40 ms |
| SD card accesses (two: the data block and the restoring read) | 3.03 ms |
| gap between one request finishing and the next arriving | 11.8 ms |
| total | ~15.3 ms |

A FreeDOS boot plus one `dir` served 623 sectors (`hdd=` counter), so **all
disk activity together is about 9.5 s of the 103 s those two took**. The card
is not slow (about 1.5 ms per access, no retry storm, no `SD ERROR` lines) and
the firmware is now negligible.

The remaining ~93 s is the emulated 8088 running FreeDOS's startup and
FreeCom's directory code, with no disk access at all. Confirmed directly: the
same boot from the same image takes **64 s at 4.77 MHz and 35 s at "Max"**.
The machine is CPU-bound, not I/O-bound.

So the premise behind this whole investigation was wrong. The error was
dividing wall-clock time by sector count and assuming the sectors explained
it; the first measurement in this document said 10.45 ms of firmware per
sector against an apparent 100+ ms, and that gap should have been treated as
evidence that most of the time was not disk at all.

What the work is still worth: a sector costs about 3.4 ms of firmware plus
card time instead of about 12 ms, so bulk I/O (copying files, loading large
programs, floppy access) is roughly 3.5x faster, and the CRT/ROM autoload at
startup is measurably quicker. It is not a fix for boot time.

## The second SD access, removed
That cheap win has been taken. `SDB_GUARD_OUT` used to read back the sector
the FAT32 library believed was in the hardware buffer, which was a second SD
card access - about 1.5 ms of the 3.03 ms - for something the library's own
mechanism does for nothing. It now simply tells both device handles that the
buffer contents are unknown (`SDB_ORPHAN`), by pointing
`FAT32$DEV_BUFFERED_FDH` at an all-zero, never-dirty dummy handle. That is
exactly what `FAT32$READ_FDH` already does to itself: it compares
`FAT32$DEV_BUFFERED_FDH` against the handle it was called for and re-reads
through `FAT32$RW_SIC` whenever they differ.

`_SDB_OWNER` treats the dummy as "nobody owns the buffer", so the request
after an orphaned one finds nothing to flush and nothing to mark, and is not
refused. The dummy is used rather than the obvious 0 because `FAT32$FLUSH`
returns immediately when called with `R8 = 0` and leaves `R9` - its error
code - untouched, and `FAT32$FILE_SEEK` checks that stale `R9` right after
calling it; a seek would then silently do nothing.

This cannot reintroduce what made hardware run 1 fatal: orphan-marking issues
no SD access at all, so it cannot produce an LBA, wild or otherwise. Every
guard from that round stays - stopping one whole block short of the end of a
file, verifying `FAT32$FDH_ACCESS` after every seek, validating every LBA in
`SDB_CLULBA`, and resetting the controller after any failed access. The
change is also strictly *safer* than the restore it replaces: restoring could
only ever satisfy one of the two device handles that share the single
hardware buffer, while marking tells both.

Expected per sector: 0.40 ms firmware plus one ~1.5 ms card access, i.e.
about **1.9 ms instead of 3.4 ms**, and a request `sdn=0001` instead of
`sdn=0002`. The shipping ROM shows it directly: `RSUB SDB_SDRD,` went from 5
call sites to 3.

Bench, before and after, in QNICE cycles for one 512-byte block (the emulator's
SD card is instantaneous, so this only shows the guard arithmetic that also
went away; the real saving is the card access):

| path | before | after |
|---|---|---|
| vdrive read | 35,063 (0.701 ms) | **33,689 (0.674 ms)** |
| vdrive write | 34,019 (0.680 ms) | **32,645 (0.653 ms)** |
| 16 KB ROM load | 1,421,449 (28.43 ms) | 1,419,748 (28.39 ms) |

All checks pass, including three that exist specifically for this change:

* **T7a** - after a map build that gives up half way, the very next
  `f32_fread` must still return the right bytes.
* **T7b** - a fast vdrive read must not disturb a second, unrelated open file
  handle on the same device.
* **T8** - the library reads a *different* sector immediately after the fast
  path overwrote the buffer. Without the marking it would serve our block.

Those three were verified to be sensitive by disabling `SDB_GUARD_OUT` and
confirming all three fail. That negative control was worth running: T8 as
first written compared blocks 4 and 6 of the test image, which are
byte-identical (the generator patterns the first eight sectors the same way),
so it passed with the protection removed. It now compares the `MARK20000`
sector against the `00..FF` patterned one.
