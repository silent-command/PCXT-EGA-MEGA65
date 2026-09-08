# Virtual drives served straight from the SD card ("SD-direct")

## Why

The stock MiSTer2MEGA65 firmware mounts a disk image by copying the whole
file into a RAM device (one per drive, `C_VD_BUFFER` in `globals.vhd`) and
then serves the core's block requests from that copy; writes go into the
copy and are flushed back to the file in the background (`FLUSH_CACHE`).
That fits a 170 KB D64, not a 45 MB hard disk image: the MEGA65 R6 has
8 MB of HyperRAM and the demo core's "no buffer" placeholder device
(`x"AAAA"`) simply swallows the copy, so the core reads zeros.

## What changed (framework files, kept minimal)

- `M2M/rom/sysdef.asm`: `VD_BUF_SDDIRECT .EQU 0xAAAA`. A drive whose buffer
  entry is this value has no RAM copy.
- `M2M/rom/vdrives.asm`: `VD_IS_SDDIRECT` (R8 = drive, returns Carry).
- `M2M/rom/shell.asm`:
  - `LOAD_IMAGE` skips the copy loop for SD-direct drives; the file handle
    in `HNDL_VD_FILES` stays open, the mount strobe still uses the file size.
  - `HANDLE_DRV_RD`: seek to `VD_BYTES_H:L`, acknowledge, stream
    `VD_SIZEB` bytes with `f32_fread` into the drive buffer, release.
    Reading past the end of the image yields zeros.
  - `HANDLE_DRV_WR`: seek, copy the drive buffer to the file byte by byte
    with `f32_fwrite`, `f32_fflush`, acknowledge, then clear the cache
    dirty flag (write-through, nothing to flush later).
  - `HANDLE_IO`: never calls `FLUSH_CACHE` for an SD-direct drive.
  - `VD_SD_SEEK`: skips `f32_fseek` when the handle's access position
    already equals the target, because a FAT32 seek walks the cluster chain
    from the start of the file. Sequential sector reads therefore cost no
    seek.
- `CORE/vhdl/globals.vhd`: `C_DEV_VD_SDDIRECT` (same value) for all three
  drives.

## Cost

One block = one QNICE `f32_fread` per byte plus the register writes into
`vdrives.vhd`; a far seek walks the cluster chain (FAT reads per cluster
boundary). Good enough to boot DOS; a sector cache or a smarter seek in the
FAT32 library are the obvious upgrades if it feels slow.
