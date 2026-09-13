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
