# Storage: why disk access is slow

## Symptom
FreeDOS takes about 57 seconds to boot from the hard-disk image on hardware,
and the first `dir` at the C:\> prompt takes about 40 seconds. Every later
`dir` is instant, because DOS keeps the free-cluster count in the drive
parameter block and the FAT sectors in its buffers. CPU speed makes no
difference, which already rules out the emulated 8088 and the ISA bus.

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

## Serial log for the next hardware run

`M2M/rom/sdblock.asm` has, near the top:

```
;#define SDB_DEBUG
```

**Remove the leading `;` and rebuild** (`CORE/m2m-rom/make_rom.sh`) to get a
log on the serial console at boot - no keyboard involved, since the ROM auto
loader runs by itself. Put the `;` back to switch it off. The default build
contains none of it.

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

## Expected effect on hardware
* **CRT/ROM auto load** is the keyboard-free check. The baseline above is
  ~0.2 s per 16 KB file, which the bench predicts as 240 ms of firmware plus
  32 SD block reads, so on this card the firmware dominates. After the change
  the firmware part is 28.4 ms, so the gap between the
  `LOADING ROM #nnnn : OK` timestamps should fall from ~0.2 s to roughly
  **0.04-0.07 s**. Whatever is left *is* the SD block read time, which makes
  this also a direct measurement of it.
* **Sequential vdrive read** of one sector: ~10.9-11.5 ms before, ~1.5-2.7 ms
  after (0.7 ms firmware plus two SD reads), i.e. roughly **4-7x**.
* **Random vdrive read**, which is what a FreeDOS boot does: the O(LBA)
  `VD_SD_SEEK` term disappears completely. At LBA 5,000 that alone was about
  105 ms and near the end of the image about 1.9 s; it is now 0.
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
QNICE **ROM**: `END_OF_ROM` moved from `0x58DE` to `0x5E15`, i.e. **+1335
words (2670 bytes)**. Free ROM space goes from 5922 to **4587 words**. With
`SDB_DEBUG` enabled it is `0x6036`, i.e. **4042 words still free**, so the
logging build fits comfortably.

QNICE **RAM**: `HEAP` moved from `0x8200` to `0x82BF`, i.e. **+191 words (382
bytes)**: 3 x 40 words of virtual-drive block map, 40 words for the CRT/ROM
map, 12 words for `SDB_DUMMY_FDH`, 1 word for `SDB_NULL_MAP`, 5 words of
guard and status state and 13 words of map-build scratch. "Free QNICE memory"
in the boot log goes from 736 to **545 words**. Nothing overflows.

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
* `M2M/rom/crts-and-roms.asm` - fast path in the ROM auto loader, plus the
  `SDB_DEBUG` hook that logs the error code the byte loop sees
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
