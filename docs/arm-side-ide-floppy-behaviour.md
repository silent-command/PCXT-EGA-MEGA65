# ARM-side IDE and floppy behaviour for PCXT-EGA (MiSTer Main_MiSTer)

Purpose: specify exactly what the MiSTer HPS (ARM) software does for the IDE and
floppy controllers of the PCXT-EGA core, so that a hardware bridge on the MEGA65
can reproduce it register-for-register.

Sources (Main_MiSTer `master`, fetched 2026-09-07; raw copies in the session
scratchpad `main_mister/`):

| File | Role |
|---|---|
| `ide.cpp`, `ide.h` | ATA emulation, register transport, IDENTIFY, mount |
| `support/x86/x86.cpp`, `x86.h` | x86-family core glue: poll loop, floppy, HDD mount, RTC |
| `user_io.cpp`, `user_io.h`, `spi.cpp`, `fpga_io.cpp` | SPI transport primitives, core detection, poll entry |
| `support/vhd/vhdcgf.cpp` | optional `.cfg` sidecar geometry override |
| `menu.cpp` | OSD image selection path |

Core-side references (this repo, `CORE/PCXT-EGA_MiSTer`): `rtl/hps_ext.v`,
`rtl/common/ide.v`, `rtl/common/floppy.v`, `rtl/KFPC-XT/HDL/Peripherals.sv`,
`PCXT-EGA.sv`. Line numbers below are for these exact files.

Status-bit names used throughout (`ide.h:6-14`):

| Name | Value | ATA meaning | Core decode (`ide.v:156,165,172,193`) |
|---|---|---|---|
| BSY | 0x80 | busy | status[7] |
| RDY | 0x40 | drive ready | status[6] |
| RDP | 0x20 | "performance read" (MiSTer private) | `fast_read` flag, not a status bit |
| DSC | 0x10 | seek complete | status[4] |
| DRQ | 0x08 | data request | status[3] |
| IRQ | 0x04 | MiSTer private: raise INTRQ | `irq <= 1` (if not masked by nIEN) |
| END | 0x02 | MiSTer private: last block | `last_read` flag |
| ERR | 0x01 | error | status[0] |

Error-register value used: `ATA_ERR_ABRT` 0x04 (`ide.h:23`).

---

## 1. Transport

### 1.1 Which handler, how often

* `is_pcxt()` is true for core names `PCXT`, `Tandy1000`, `PCjr`, `PCXT-EGA`
  (`user_io.cpp:320-335`). `is_x86()` (ao486 family) is false for PCXT-EGA.
* Init: on core load `x86_config_load(); x86_init();` (`user_io.cpp:1585-1589`);
  again on the user-button reset (`user_io.cpp:3077`).
* Poll: `user_io_poll()` calls `x86_poll(0)` every pass of the ARM main loop
  (`user_io.cpp:3220-3223`); there is no timer gating.
* `x86_poll` (`x86.cpp:761-777`): one `ide_check()`; if non-zero, dispatch
  `ide_io(0, bits[2:0])`, `ide_io(1, bits[5:3])`, and `fdd_io(bit6)` if
  bits[7:6] != 0. Bit 10 (`0x400`) triggers CD audio; always 0 on this core.

### 1.2 SPI framing (HPS -> FPGA "IO" channel)

All transfers are 16-bit SPI words on the user-IO chip-select (`EnableIO()` =
`fpga_spi_en(SSPI_IO_EN,1)`, `spi.cpp:45-53`). Command codes (`user_io.h:87-89`):

| Code | Name | Use |
|---|---|---|
| 0x61 | `UIO_DMA_WRITE` | mgmt register/buffer write |
| 0x62 | `UIO_DMA_READ` | mgmt register/buffer read |
| 0x63 | `UIO_DMA_SDIO` | request-status poll |

Core-side decoder is `rtl/hps_ext.v` (16-bit `ext_addr`, `ext_din/ext_dout`):

| SPI word # | 0x61 write transaction | 0x62 read transaction | Core action (`hps_ext.v`) |
|---|---|---|---|
| 0 | 0x0061 | 0x0062 | latch cmd; reply word = `{4'hE, 2'b00, hotswap[1:0], req[7:0]}` (line 74) |
| 1 | addr[15:0] | addr[15:0] | `ext_addr <= word` (line 69) |
| 2 | addr[31:16] (always 0) | 0 | ignored |
| 3.. | data word k | dummy 0; reply = data word k | `ext_wr` / `ext_rd` pulse per word (lines 78-85) |

After every `ext_rd`/`ext_wr` the address auto-increments **unless
`addr[7:0] == 0xFF`** (`hps_ext.v:54`). A run of words starting at `base+0`
therefore walks registers 0,1,2,...; a run at `base+0xFF` stays on the buffer
port.

ARM helpers:

| Function | Lines | Sends |
|---|---|---|
| `ide_reg_set(ide, reg, v)` | `ide.cpp:50-57` | 0x61, addr lo, addr hi, one 16-bit value |
| `ide_sendbuf(ide, reg, n, p)` | `ide.cpp:59-67` | 0x61, addr, 0, then `n` 16-bit words |
| `ide_recvbuf(ide, reg, n, p)` | `ide.cpp:69-77` | 0x62, addr, 0, then `n` reads |
| `ide_check()` | `ide.cpp:84-92` | 0x63; returns the reply to that same word (never 0 on this core because of the 0xE nibble) |
| `x86_dma_set(addr, v)` | `x86.cpp:254-261` | as `ide_reg_set`; value truncated to 16 bits |
| `x86_dma_sendbuf/recvbuf` | `x86.cpp:263-299` | for `addr >= 0xF200`: one **byte** per 16-bit word (`spi_w(*buf++)`), i.e. word[7:0] = data, word[15:8] = 0 |

Data word order: the ARM casts its little-endian byte buffer to `uint16_t`, so
sector byte 2k is in word k bits [7:0] and byte 2k+1 in bits [15:8]. No byte
swapping is applied to sector data. IDENTIFY words are sent as native 16-bit
values.

`ide_check()` reply bit map (`hps_ext.v:74`; `PCXT-EGA.sv:456-457,472,1320-1321`):

| Bits | Meaning on PCXT-EGA |
|---|---|
| [2:0] | IDE0 request (`ide.v` `request`): 000 none, 100 new command, 101 data phase, 110 reset |
| [5:3] | IDE1 request: hard-wired 000 |
| [6] | floppy read request (`floppy.v:80-81`) |
| [7] | floppy write/format request |
| [9:8] | `ext_hotswap`: hard-wired 00 |
| [11:10] | 0 |
| [15:12] | 0xE (constant) |

### 1.3 Address map (`Peripherals.sv:1527,1631,1774`; `x86.cpp:42-45`)

| Base | Decode | Device |
|---|---|---|
| 0xF000 | `addr[15:8]==0xF0`, reg = `addr[3:0]` | IDE port 0 (`ide.v`) |
| 0xF100 | not decoded | IDE port 1 (ARM still writes here; no-op) |
| 0xF200 | `addr[15:8]==0xF2`, reg = `addr[3:0]`, drive = `addr[7]` | floppy (`floppy.v`) |
| 0xF400 | `addr[15:8]==0xF4` | RTC/CMOS (128 bytes written by `x86_init`) |

Because only `addr[3:0]` is decoded, the ARM's buffer register 255
(`ide.cpp:45-46`: `base+255`) lands on mgmt address 0xF. Floppy B media
registers are at 0xF280-0xF285 (`x86.cpp:460`: `subaddr = num << 7`), not at
the unused `FDD1_BASE` 0xF300.

### 1.4 IDE mgmt register file (`ide.v`)

Write (ARM -> core), one 16-bit word per address:

| Addr | [15:8] | [7:0] | Core effect |
|---|---|---|---|
| 0 | error | io_size (sectors in buffer; 0x80 = CD) | `error`; `blk_size = io_size*256` words (`ide.v:105,112`) |
| 1 | sector[7:0] | sector_count[7:0] | `ide.v:118,126` |
| 2 | cylinder[15:0] | | `ide.v:134` |
| 3 | sector[15:8] | sector_count[15:8] | HOB bytes; ARM always writes 0 (`ide.v:119,127`) |
| 4 | cylinder[31:16] | | ARM writes 0 for HDD (`ide.v:135`; also `blk_size` when io_size=0x80) |
| 5 | status byte | drive/head byte | `drv_addr`, `status`, `last_read`, `fast_read`, `irq`; **clears `request`, `io_cnt`, `io_wait`** (`ide.v:143,156,165,172,179,186,193,264`) |
| 6 | bit 9 = latch use_wait (from bit 8) | bit 3 = latch drive 0 `{hob_ena,present}` from bits[1:0]; bit 7 = latch drive 1 from bits[5:4] | `ide.v:214-215,220` |
| 0xF | data word | | buffer; pointer `mgmt_cnt` |

Read (core -> ARM) (`ide.v:199-205`):

| Addr | [15:8] | [7:0] |
|---|---|---|
| 0 | features | bit1 = `use_fast` (tied 0 in this core, `Peripherals.sv` `.use_fast(0)`), bit0 = `io_done` |
| 1 | sector[7:0] | sector_count[7:0] |
| 2 | cylinder[15:0] | |
| 3 | sector[15:8] | sector_count[15:8] |
| 4 | cylinder[31:16] | |
| 5 | cmd | drv_addr (bit6 = LBA, bit4 = DRV, [3:0] = head) |
| 0xF | buffer word | |

Buffer pointer: `mgmt_cnt` increments on every access to address 0xF and is
**reset to 0 by any access to addresses 0-6** (`ide.v:274-277`). Every ARM
buffer transfer is preceded by a register access, so transfers always start at
word 0. Buffer = 2 x `dpram(12,16)` = 8192 words = 16 KiB = 32 sectors
(`ide.v:290-296`; `ide_io_max_size = 32`, `ide.cpp:79`).

Host-side completion: when the host has moved `blk_size` words through the data
port (`io_done`, `ide.v:253`) with DRQ set, the core sets status to 0x40 if
`last_read` else 0x80 and raises request 101 (`ide.v:158-159,188`).

`ide_get_regs` (`ide.cpp:139-160`) reads 6 words from address 0 and unpacks
exactly the table above; `ide_set_regs` (`ide.cpp:162-190`) packs 12 bytes
(little-endian words as above) and writes 6 words at address 0. Before packing
it ORs DSC into status when the drive is not a CD and status has neither BSY nor
ERR (`ide.cpp:165-168`).

---

## 2. IDE (`ide.cpp`)

### 2.1 State

`drive_t` (`ide.h:72-115`): `f` (image), `present`, `drvnum`, `cylinders`,
`heads`, `spt`, `total_sectors`, `spb` (sectors per block for READ/WRITE
MULTIPLE, default 16), `offset` (0 on PCXT), `type`, `cd`, `placeholder`,
`id[256]` (IDENTIFY image). `regs_t` (`ide.h:35-56`): the register snapshot.
`ide_config` (`ide.h:117-127`): `base`, `bitoff` (= port*3, shift into the
`ide_check` word), `state`, `null` (I/O failed flag), `regs`, `drive[2]`.

### 2.2 Mount (`hdd_set`, `x86.cpp:475-524`; `ide_img_set`, `ide.cpp:418-698`)

`hdd_set(num, name)` for PCXT:

1. `.vhd` only is treated as an HDD (`x86.cpp:481`); non-`.vhd` on num 2/3 is
   tried as CD. Opened read-write if the file is writable (`ide_img_mount`,
   `ide.cpp:94-123`).
2. Geometry choice (`x86.cpp:491-519`), using the file size in bytes:
   * exact match of `C*H*S*512` against `hdd_table[128]` (`x86.cpp:53-197`,
     `FindHDDInfoBySize` 216-240) -> use that table H and S;
   * else size > 8455200768 (16383*16*63*512) -> `ide_img_set(num,f,cd)` with
     sectors=0, heads=0 -> `ide_set_geometry` defaults **heads=16, spt=256**
     (`ide.cpp:300-301`);
   * else -> heads=16, spt=63 (the "16x63 rule").
   If the file cannot be `fopen`ed (e.g. empty name) `ide_img_set` is **not
   called** on the PCXT path, so an absent drive is never explicitly programmed.
3. `ide_img_set` (`ide.cpp:418-698`):
   * resets drive fields, `spb=16`, `present = f!=0`, `state = IDE_STATE_RESET`.
   * writes reg 6 twice (`ide.cpp:461-462`):
     `((present||placeholder) ? 9 : 8) << (drv*4)` then `0x200`.
     (9 = latch + present=1, hob_ena=0; 8 = latch + present=0; 0x200 = latch
     use_wait=0.)
   * `total_sectors = size/512` (`ide.cpp:466`).
   * `parse_vhd_config` (`vhdcgf.cpp:199-246`): if `<image>.cfg` exists with
     `SECTORS=`/`HEADS=` (optional `CYLINDERS=`) it overrides `spt/heads`
     (and `total_sectors` if cylinders given) and returns 0; then
     `ide_set_geometry(drive, drive->spt, drive->heads)`. Otherwise
     `ide_set_geometry(drive, sectors, heads)` (`ide.cpp:479-480`).
   * `ide_set_geometry` (`ide.cpp:291-314`): `heads = h?h:16`, `spt = s?s:256`,
     `cylinders = size / (heads*spt*512)` (truncated), capped at 65535.
   * builds `id[256]` (section 2.4), then overwrites words 27-46 with the image
     **file name** (`f->name`, not the path), ATA byte order, space padded
     (`ide.cpp:685-694`).

Consequences: on PCXT, OSD selection of an HDD image only stores the name
(`x86_set_image`, `x86.cpp:779-785`, calls `hdd_set` only for placeholder/CD
slots, and `hotswap[0..1]` are always 0 in `x86_init`, `x86.cpp:554-559`), so
**HDD mounts take effect only on the next `x86_init` (core reset)**. Floppy
selection (`fdd_set`) applies immediately.

### 2.3 Request loop (`ide_io`, `ide.cpp:986-1079`)

| req | Action |
|---|---|
| 0 | if `state==RESET` (set by reset or by mount): write regs with `status = RDY` (-> 0x50 after DSC) and go IDLE (`ide.cpp:992-1003`) |
| 4 | new command: `ide_get_regs`, dispatch `handle_hdd` (or CD handler / not-present -> error); on error write `status = RDY\|ERR\|IRQ` (0x45), `error = ABRT` (0x04) (`ide.cpp:1004-1023`) |
| 5 | data phase outside a running read/write: only CD states are valid; otherwise "unknown state" -> same abort write 0x45/0x04 (`ide.cpp:1024-1053`) |
| 6 | reset: `ide_get_regs`; head=0; error = cd?1:0; sector=1; sector_count=1; cylinder = !present ? 0xFFFF : cd ? 0xEB14 : 0x0000; `status = BSY` (0x80, DSC not added); write regs; `state = RESET` (`ide.cpp:1054-1078`). The following poll (req 0) then writes the same registers with status 0x50. |
| 1,2,3,7 | ignored |

For HDD reads/writes the 101 data-phase requests are consumed **inside**
`process_read`/`process_write` by a busy-wait on `ide_check()` (no timeout;
other devices are starved meanwhile). Any value other than 5 aborts the loop
silently (state IDLE, nothing written).

### 2.4 IDENTIFY DEVICE image (`ide.cpp:488-581`, name patch 685-694)

All words not listed are 0. Values are the 16-bit word as transferred.

| Word | Value | Source |
|---|---|---|
| 0 | 0x0040 | fixed |
| 1 | cylinders | geometry |
| 3 | heads | geometry |
| 4 | (512*spt) & 0xFFFF | geometry |
| 5 | 512 | fixed |
| 6 | spt | geometry |
| 10-14 | "AO","HD","00","00","0 " (first char in high byte) | serial "AOHD00000" |
| 15-19 | 0x2020 | serial padding |
| 20 | 3 | buffer type |
| 21 | 512 | cache size |
| 22 | 4 | ECC bytes |
| 23-26 | 0 | firmware rev (NULs, not spaces) |
| 27-46 | image file name, 2 chars/word, first char in bits[15:8], `0x20` fill; initially 0x2020 | model |
| 47 | 0x8020 | max 32 sectors/multiple |
| 48 | 1 | dword I/O |
| 49 | 0x0200 | LBA supported |
| 50 | 0x4001 | |
| 51, 52 | 0x0200 | PIO/DMA timing |
| 53 | 0x0007 | words 54-58, 64-70, 88 valid |
| 54 | cylinders | current |
| 55 | heads | current |
| 56 | spt | current |
| 57, 58 | total_sectors lo, hi | current capacity |
| 59 | 0x0110 | multiple valid, 16 sectors current |
| 60, 61 | total_sectors lo, hi | LBA28 capacity |
| 65-68 | 120 | cycle times |
| 80 | 0x007E | ATA-1..6 |
| 82 | 0x4200 | NOP, DEVICE RESET |
| 83 | 0x7000 | FLUSH CACHE (EXT) claimed (but E7 is not implemented) |
| 84 | 0x4000 | |
| 85 | 0x4200 | |
| 86 | 0x7000 | |
| 87 | 0x4000 | |
| 93 | 0x630B | cabling/hw reset result |
| 100, 101 | total_sectors lo, hi | LBA48 capacity |
| 102, 103 | 0 | |

Note that words 1/3/6 and 54-56 are frozen at mount; `91h` changes the ARM's
CHS translation but not `id[]`.

### 2.5 Address and count helpers

* `get_lba` (`ide.cpp:700-720`): LBA mode: `sector | cylinder<<8 | head<<24`.
  CHS mode: `((cylinder*heads)+head)*spt + sector-1` with the drive's current
  `heads/spt`.
* `put_lba(lba)` (`ide.cpp:722-744`): writes `lba-1` back into
  sector/cylinder/head (LBA form or CHS form matching `regs.lba`), i.e. the
  address of the **last sector transferred**.
* `get_cnt` (`ide.cpp:746-757`): `cnt = sector_count; if (cnt==0 || cnt>spb) cnt = spb`.
  Single-sector commands use cnt=1. `sector_count` is 8-bit and wraps, so
  count 0 means 256.
* Read failure or beyond EOF: buffer zero-filled, no error reported
  (`ide.cpp:759-771,781-783`).

### 2.6 Command handling (`handle_hdd`, `ide.cpp:888-984`)

Status values below are the byte written to mgmt word 5[15:8] after
`ide_set_regs` added DSC. Registers not listed are echoed back as read.

| Cmd | Handling |
|---|---|
| EC IDENTIFY | zero all regs except drv; io_size=1; send 256 words to 0xF; then write regs with status 0x5E (RDY\|DSC\|DRQ\|IRQ\|END), sector/count/cyl = 0, drv/head byte = 0xA0\|drv<<4 (`ide.cpp:892-902`) |
| 20/21 READ SECTORS | `process_read(multi=0)`: cnt=1 per data phase |
| C4 READ MULTIPLE | `process_read(multi=1)`: cnt from `get_cnt` |
| 30/31 WRITE SECTORS | `process_write(multi=0)` |
| C5 WRITE MULTIPLE | `process_write(multi=1)` |
| C6 SET MULTIPLE | count > 32 -> abort; else `spb = count`; status 0x54 (`ide.cpp:927-936`). count 0 would set spb=0 (unguarded) |
| 08 DEVICE RESET | abort |
| 10-1F RECALIBRATE | cylinder=0; status 0x54 |
| 40 READ VERIFY | error=0; status 0x54. **0x41 is not handled -> abort** |
| 70 SEEK, E3 IDLE | error=0; status 0x54 |
| 90 EXEC DIAG | error=0x01; status 0x54 |
| 91 INIT DEV PARAMS | `ide_set_geometry(drive, sector_count, head+1)` (spt 0 -> 256); status 0x54 |
| E7 FLUSH, EF SET FEATURES, E0-E2, E5, A0/A1 (ATAPI, HDD), F8, anything else | abort |
| FA (MiSTer mount) | receives one 512-byte block like a write; `x86_set_image` only if `is_x86()`, so **no effect on PCXT** |
| any cmd to a non-present drive | abort (`ide.cpp:1014`) |

Abort = status 0x45 (RDY\|ERR\|IRQ, no DSC), error 0x04 (`ide.cpp:1017-1022`).

`process_read` (`ide.cpp:773-829`), `use_fast`=0 path (the only one on this core):

```
lba = get_lba(); cnt = multi ? get_cnt() : 1
fetch cnt sectors into buffer (zero on failure)
loop:
  lba += cnt; sector_count -= cnt; put_lba(lba)
  io_size = cnt; status = RDP|RDY|DRQ|IRQ (0x6C) | (sector_count==0 ? END : 0)
  send cnt*256 words to 0xF
  status &= ~RDP  -> 0x4C / 0x4E ; write regs (-> 0x5C / 0x5E after DSC)
  if sector_count == 0: done (core clears DRQ/sets RDY itself via last_read)
  cnt = multi ? get_cnt() : 1; prefetch next block
  busy-wait until ide_check() port bits != 0; if != 5: abandon
```

`process_write` (`ide.cpp:831-886`):

```
lba = get_lba(); irq = 0
loop:
  cnt = multi ? get_cnt() : 1
  status = RDY|DRQ|irq (0x48 first, 0x4C after); irq = IRQ
  io_size = cnt; write regs (-> 0x58 / 0x5C)
  busy-wait for request; if != 5: abandon
  read cnt*256 words from 0xF; write to image
  lba += cnt; sector_count -= cnt; put_lba(lba)
  if sector_count == 0: status = RDY|IRQ (0x44 -> 0x54); write regs; done
```

Only one status write carries IRQ per completed block; the core clears `irq`
when the host reads or writes the status/command register (`ide.v:194`).

---

## 3. Floppy (`x86.cpp`)

### 3.1 Type table (`fdd_set`, `x86.cpp:387-473`)

Image opened read-write when possible (`ide_img_mount(..., rw=1)`). `size` is in
512-byte blocks; first matching row wins.

| size (blocks) | type | cyl | heads | spt | BIOS CMOS nibble (`get_fdd_bios_type`) |
|---|---|---|---|---|---|
| >= 8000 | rejected (closed) | | | | |
| >= 5760 | 2880 | 80 | 2 | 36 | 5 |
| >= 3360 | 1680 | 80 | 2 | 21 | 4 |
| >= 2880 | 1440 | 80 | 2 | 18 | 4 |
| >= 2400 | 1200 | 80 | 2 | 15 | 2 |
| >= 1440 | 720 | 80 | 2 | 9 | 3 |
| >= 720 | 360 | 40 | 2 | 9 | 1 |
| >= 640 | 320 | 40 | 2 | 8 | 1 |
| >= 360 | 180 | 40 | 1 | 9 | 1 |
| < 360 | 160 | 40 | 1 | 8 | 1 |
| no file | none (geometry of 1440 still written) | 80 | 2 | 18 | 1 |

`total_sectors = spt*heads*cyl`.

### 3.2 Mount/unmount writes (`x86.cpp:460-472`)

Base `B = 0xF200 | (drive << 7)`. Each line is a separate 0x61 transaction.

| Order | Addr | Value | Core (`floppy.v`) |
|---|---|---|---|
| 1 | B+0 | 0 | eject: `media_present=0` -> change line set (`floppy.v:84,251,257`) |
| | | `usleep(100000)` (100 ms) | |
| 2 | B+0 | present ? 1 : 0 | `media_present`; also `fdd_present[]` in `Peripherals.sv:1635` |
| 3 | B+1 | (present && writable) ? 0 : 1 | `wp_sys` (ORed with OSD `status[20:19]`, `floppy.v:89-90`) |
| 4 | B+2 | cylinders | `media_cylinders[7:0]` |
| 5 | B+3 | spt | `media_sectors_per_track[7:0]` |
| 6 | B+4 | total_sectors (16-bit) | `media_sector_count` |
| 7 | B+5 | heads | `media_heads[1:0]` |
| 8 | B+6 | 0 | not decoded by `floppy.v` (no-op) |
| 9 | B+0xC | 0 | not decoded (no-op) |

No motor/ready handling on the ARM side: motor, change line, seek timing and
write-protect checks are entirely in `floppy.v` (`143-154`, `248-258`,
`377-395`).

### 3.3 Read/write service (`fdd_io`, `x86.cpp:682-759`)

Request: `ide_check` bit 6 = read, bit 7 = write or format (`floppy.v:80-81`,
asserted while the state machine sits in `S_SD_READ_WAIT_FOR_DATA`,
`S_SD_WRITE_WAIT_FOR_EMPTY_FIFO` or `S_SD_FORMAT_WAIT_FOR_FILL`).

1. Read parameters: 0x62 transaction at 0xF200, two words
   (`x86_dma_recvbuf(FDD0_BASE, 2, ...)`, `x86.cpp:695`):
   * word 0 = `{drive_B, lba[14:0]}` (`floppy.v:79`; `sd_sector` is the linear
     sector computed by the core, clamped to `total-1`, `floppy.v:817`).
     Bit 15 selects image B (`x86.cpp:697-702`).
   * word 1 = constant 1 (`floppy.v:79` returns 16'd1 for addresses 1-14) = `cnt`.
2. Read (bit 6): read **one** sector from the image at `lba` (cnt ignored); send
   512 words to 0xF2FF, one byte per word in bits[7:0]
   (`x86_dma_sendbuf(FDD0_BASE+255, 128, buf)`, byte path `x86.cpp:272-276`).
   Image missing or read error -> 512 zero bytes are sent anyway. Completion:
   FIFO full (512 bytes) advances the state machine (`floppy.v:693`); no
   status is written.
3. Write/format (bit 7): read `cnt*512` bytes from 0xF2FF (one byte per word),
   then write `cnt` (=1) sectors to the image if `1 <= cnt <= 16` and the image
   is writable (`x86.cpp:732-757`). Completion: FIFO empty (`floppy.v:701`)
   or, for format, 512 bytes drained (`floppy.v:711`). Nothing is written back
   on error (read-only image just drops the data).

The FIFO and parameter port are shared by both drives (`floppy.v:79,105-106`
ignore `mgmt_fddn`); only registers 0-5 are per-drive.

---

## 4. Bridge contract

Notation: `W addr <- value` (bridge writes one 16-bit word), `W addr <- [n words]`
(streamed at a fixed address), `R addr -> n words`. Word 5 status/drv-head
values are the final bytes after the ARM's DSC rule. `DH` = drive/head byte
`(lba ? 0xE0 : 0xA0) | drv<<4 | head` from the command's drv_addr; `DH'` is the
same with the head produced by `put_lba`.

### 4.1 Mount HDD (drive d = 0/1 on port 0)

| Step | Op | Note |
|---|---|---|
| 1 | `W 0xF006 <- (present ? 0x0009 : 0x0008) << (4*d)` | latch present, hob_ena=0 |
| 2 | `W 0xF006 <- 0x0200` | use_wait = 0 |
| 3 | compute heads/spt/cylinders/total_sectors and the 256-word IDENTIFY image (2.2, 2.4) | |
| 4 | (ARM: on next poll with req 000, writes regs 0-5 = `{0x0000, 0x0000, 0x0000, 0x0000, 0x0000, {0x50, 0xA0}}`) | redundant with the reset sequence; optional |

### 4.2 Reset (req 110)

| Step | Op |
|---|---|
| 1 | `R 0xF000 -> 6 words` (only `drv` = w5[4] is needed) |
| 2 | `W 0xF000 <- [ {err=0x00, io=0x00}, 0x0101, present ? 0x0000 : 0xFFFF, 0x0000, 0x0000, {0x80, 0xA0\|drv<<4} ]` |
| 3 | next poll, req 000: `W 0xF000 <- [ 0x0000, 0x0101, same cyl, 0x0000, 0x0000, {0x50, 0xA0\|drv<<4} ]` |

Writing word 5 clears the request; while the core reset input is still
asserted the request re-asserts and the ARM repeats step 2 each poll.

### 4.3 New command (req 100)

`R 0xF000 -> 6 words`: `features = w0[15:8]`, `count = w1[7:0]`,
`sector = w1[15:8]`, `cyl = w2`, `drv_addr = w5[7:0]`, `cmd = w5[15:8]`. Abort if
`present[drv] == 0`. Then one of:

**IDENTIFY (EC)**

| Step | Op |
|---|---|
| 1 | `W 0xF00F <- [256 words id[]]` |
| 2 | `W 0xF000 <- [ 0x0001, 0x0000, 0x0000, 0x0000, 0x0000, {0x5E, 0xA0\|drv<<4} ]` |

**Read N sectors (20/21 cnt=1; C4 cnt = count ? min(count,spb) : spb)**

| Step | Op |
|---|---|
| 1 | `lba = get_lba()`; fetch `cnt` sectors (zero on failure) |
| 2 | `lba += cnt; count -= cnt (8-bit); put_lba(lba)` -> new sector/cyl/head |
| 3 | `W 0xF00F <- [cnt*256 words]` |
| 4 | `W 0xF000 <- [ {0x00, cnt}, {sector, count}, cyl, 0x0000, 0x0000, {count ? 0x5C : 0x5E, DH'} ]` |
| 5 | if `count == 0` stop; else fetch next `cnt` (recompute for C4), wait for req 101 (abandon on anything else), go to 2 |

**Write N sectors (30/31 cnt=1; C5 cnt from `get_cnt`)**

| Step | Op |
|---|---|
| 1 | `lba = get_lba()`; `first = 1` |
| 2 | `W 0xF000 <- [ {0x00, cnt}, {sector, count}, cyl, 0x0000, 0x0000, {first ? 0x58 : 0x5C, DH} ]` |
| 3 | wait for req 101 (abandon on anything else) |
| 4 | `R 0xF00F -> cnt*256 words`; write to image |
| 5 | `lba += cnt; count -= cnt; put_lba(lba)`; `first = 0` |
| 6 | if `count == 0`: `W 0xF000 <- [ {0x00, cnt}, {sector, 0x00}, cyl, 0x0000, 0x0000, {0x54, DH'} ]`, stop; else go to 2 (with the updated sector/cyl/head) |

**No-data OK (10-1F, 40, 70, 90, 91, C6, E3)**

`W 0xF000 <- [ {err, io_size}, {sector, count}, cyl, 0x0000, 0x0000, {0x54, DH} ]`
with `err = 0x01` for 90, else 0; `cyl = 0` for 10-1F; side effects: 91 ->
`heads = head+1, spt = count ? count : 256, cylinders = size/(H*S*512)`;
C6 -> `spb = count` (abort if > 32).

**Unsupported / not present / stray 101**

`W 0xF000 <- [ {0x04, 0x00}, {sector, count}, cyl, 0x0000, 0x0000, {0x45, DH} ]`

### 4.4 Mount floppy (drive d)

`B = 0xF200 | d<<7`:
`W B+0 <- 0`; wait >= 100 ms (any delay long enough for the core to see
`media_present=0`); `W B+0 <- present`; `W B+1 <- wp`; `W B+2 <- cyl`;
`W B+3 <- spt`; `W B+4 <- cyl*heads*spt`; `W B+5 <- heads`. (B+6 and B+0xC
are no-ops in this core.)

### 4.5 Floppy read (req bit 6)

| Step | Op |
|---|---|
| 1 | `R 0xF200 -> 2 words`: `lba = w0[14:0]`, drive = `w0[15]` (w1 is always 1) |
| 2 | read sector `lba` from that drive's image (zeros if none) |
| 3 | `W 0xF2FF <- [512 words, byte in bits 7:0]` |

### 4.6 Floppy write / format (req bit 7)

| Step | Op |
|---|---|
| 1 | `R 0xF200 -> 2 words` as above |
| 2 | `R 0xF2FF -> 512 words`, take bits[7:0] of each |
| 3 | if the image is present and writable, write sector `lba`; otherwise discard |

### 4.7 What the ARM does that a bridge can omit

* CD-ROM/ATAPI: `cd`, `placeholder`, `cdrom_*`, states 3-6, `pkt_*`,
  io_size 0x80, the 0x400 CDDA bit, `ide_check` hotswap bits (tied 00).
* IDE port 1 (`0xF1xx`, `mgmt_req[5:3]`): not present in this core; the ARM's
  writes there are no-ops.
* Command FA (mount-by-name): no effect on PCXT; treat as unsupported, or
  consume the 512-byte data phase and complete with 0x54 to stay ARM-identical.
* `io_fast`/RDP path: `use_fast` is tied 0, so data-then-regs ordering is the
  only one needed. Never set bit 13 of word 5.
* Amiga RDB / virtual RDB / `offset` / `type` / CHD (`ide.cpp:222-416`).
* `hdd_table` exact-size lookup can be replaced by the 16x63 rule unless
  matching classic geometries for specific images matters.
* `.cfg` sidecar geometry override.
* BIOS ROM loading (`x86.cpp:542-551`, `is_x86()` only) and `x86_share`.
* `usleep(100000)` exact duration; only the eject-then-insert ordering matters.
* The `ide_check` busy-wait with no timeout; a bridge may add one but must then
  abandon silently (write nothing) like the ARM.
* The ARM's redundant register write after mount (4.1 step 4).
* The floppy `cnt` field (always 1) and the 1..16 range check.

### 4.8 Open questions

1. RTC/CMOS block: `x86_init` writes 128 bytes to 0xF400+i (`x86.cpp:579-676`),
   including floppy types at 0x10, HDD type nibbles at 0x12, 0x19/0x1A, boot
   sequence at 0x2D/0x3D and the checksum. `Peripherals.sv:1774` decodes 0xF4,
   so the PCXT-EGA BIOS may read these; not analysed here.
2. Which IDENTIFY words the PCXT-EGA BIOS (XT-IDE style) uses for CHS (1/3/6 vs
   54-56 vs 60/61) decides whether the `hdd_table` match matters.
3. `91h` changes the ARM's CHS translation without updating `id[]`; verify the
   BIOS never relies on re-reading IDENTIFY after 91h.
4. 256-sector transfers (`count=0`) rely on 8-bit wraparound in
   `sector_count`; untested on this core.
5. IDENTIFY claims FLUSH CACHE (words 83/86) but E7 aborts; check that no DOS
   driver used on the MEGA65 build treats the abort as fatal.
6. OSD write-protect (`status[20:19]`) ORs into the floppy write-protect; the
   bridge's equivalent control source is undefined.
7. Floppy media-type register 0xC and reg 6 are documented in the ARM comment
   (`x86.cpp:419-433`) but not implemented in this `floppy.v`; confirm no other
   consumer exists in the MEGA65 port.
8. `ide.v` reads 0xFFFFFFFF for every ATA register when no drive is present
   (`ide.v:73`); whether the bridge should still answer requests for an absent
   slave (ARM does: abort 0x45/0x04) depends on the BIOS probe order.
