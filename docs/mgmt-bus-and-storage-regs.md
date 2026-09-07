# PCXT-EGA MiSTer core: management bus and storage registers

Reference for replacing the MiSTer ARM (HPS) side of the storage path with a
hardware bridge. All paths are relative to the submodule
`CORE/PCXT-EGA_MiSTer` at commit `c6b4dc81` (2026-09-04). Every claim carries
a `file:line` citation; anything not directly supported by the RTL is marked
**speculative** or **ARM-side (not in repo)**.

Terminology: "mgmt" = the 16-bit register bus the ARM uses to talk to
`ide.v`, `floppy.v` and `rtc.v`. "CPU side" = the 8088 I/O port view.

---

## 1. The mgmt bus

### 1.1 Physical path from the HPS to the consumers

| Stage | Where | What |
|---|---|---|
| HPS SPI slave in FPGA | `sys/sys_top.v:241-262` | `io_din` = gp_out[15:0], `io_clk` = gp_out[17], chip selects `io_ss0..2` (243-245); `io_fpga = ~ss1 & ss0` (251), `io_uio = ~ss1 & ss2` (252); `io_strobe = ~rack & io_clk` (256) is one `clk_sys` cycle per 16-bit SPI word. |
| Packing into `HPS_BUS` | `sys/sys_top.v:1760-1763` | `HPS_BUS[15:0]=io_dout`, `[31:16]=io_din`, `[32]=io_wide`, `[33]=io_strobe`, `[34]=io_uio`, `[35]=io_fpga`, `[36]=clk_sys`, `[37]=io_wait`. |
| `hps_io` pass-through | `sys/hps_io.sv:177-178` | `EXT_BUS[31:16]=HPS_BUS[31:16]`, `EXT_BUS[35:33]=HPS_BUS[35:33]`. Line 194: `HPS_BUS[15:0] = EXT_BUS[32] ? EXT_BUS[15:0] : ...` so `hps_ext` owns the reply data whenever it asserts `EXT_BUS[32]`. |
| Command decoder | `rtl/hps_ext.v` (whole file, 93 lines) | Turns SPI words into `ext_addr/ext_dout/ext_din/ext_rd/ext_wr` and reports `ext_req`. |
| Core top | `PCXT-EGA.sv:451-473` | Wires `hps_ext` to `mgmt_din/mgmt_dout/mgmt_addr/mgmt_rd/mgmt_wr/mgmt_req`; `mgmt_req[5:3]=0` (457); `ext_hotswap=2'b00` (472); `ext_midi` left unconnected. |
| Into the chipset | `PCXT-EGA.sv:1313-1321` | `mgmt_readdata<=mgmt_din`, `mgmt_writedata<=mgmt_dout`, `mgmt_address<=mgmt_addr`, `mgmt_write<=mgmt_wr`, `mgmt_read<=mgmt_rd`, `fdd_request->mgmt_req[7:6]`, `ide0_request->mgmt_req[2:0]`. |
| `CHIPSET` | `rtl/KFPC-XT/HDL/Chipset.sv:174-182` (ports), `492-500` (pass-through to `PERIPHERALS`) | Pure wiring; no decode. |
| `PERIPHERALS` | `rtl/KFPC-XT/HDL/Peripherals.sv:145-153` (ports) | Decodes `mgmt_address[15:8]` and fans out (section 1.4). |

Note: the generic MiSTer SD/image path of `hps_io` (`sd_lba/sd_rd/sd_wr/sd_buff_*`, `img_mounted/img_size`, `sys/hps_io.sv:394-413, 461-466`) is **not connected** in this core: the `hps_io` instance at `PCXT-EGA.sv:407-448` binds no `sd_*`/`img_*` ports. Storage traffic goes exclusively over the mgmt bus.

### 1.2 Signals as they leave `hps_ext`

| Signal (core name) | `hps_ext` port | Width | Direction | Definition |
|---|---|---|---|---|
| `mgmt_addr` | `ext_addr` | 16 | ARM -> core | Latched from SPI word 1 (`rtl/hps_ext.v:69`); auto-incremented after each rd/wr unless `ext_addr[7:0]==8'hFF` (`:54`). |
| `mgmt_dout` | `ext_dout` | 16 | ARM -> core | Every SPI word is copied here on its strobe (`:64`). |
| `mgmt_din` | `ext_din` | 16 | core -> ARM | Sampled into the SPI reply on the same strobe that raises `ext_rd` (`:83-84`). |
| `mgmt_wr` | `ext_wr` | 1 | ARM -> core | One-cycle pulse (`:53` clears every cycle, `:79` sets). |
| `mgmt_rd` | `ext_rd` | 1 | ARM -> core | One-cycle pulse (`:53`, `:84`). |
| `mgmt_req` | `ext_req` | 8 | core -> ARM | Returned in the reply to SPI word 0 of every ext command as `{4'hE, 2'b00, ext_hotswap, ext_req}` (`:74`). Bits: `[7]` FDD write/format request, `[6]` FDD read request, `[5:3]` 0, `[2:0]` IDE request code. |

Address width 16, data width 16. No byte enables.

### 1.3 SPI transaction format decoded by `hps_ext` (`rtl/hps_ext.v`)

A transaction is bounded by `io_enable = |EXT_BUS[35:34]` (`:41`, i.e. `io_fpga | io_uio`); when it drops, `byte_cnt`, `io_dout`, `dout_en` reset (`:56-60`). Per 16-bit word (one `io_strobe`, `:62`):

| Word index (`byte_cnt`) | Meaning | Lines |
|---|---|---|
| 0 | Command. `dout_en` set only for `0x61..0x63` (`:43-44`, `:73`). Reply = `{4'hE,2'b00,hotswap,ext_req}` (`:74`). | 71-75 |
| 1 | `ext_addr <= io_din` (`:69`). For `0x63`, `ext_midi <= io_din[7]` (`:86`). | 69, 86 |
| 2 | Ignored: rd/wr require `byte_cnt >= 3` (`:78`, `:82`). (The ARM sends a dummy word here: **inferred from this gate, ARM code not in repo**.) | 78, 82 |
| 3.. | `0x61`: `ext_wr` pulse per word, data = that word (`:64`, `:79`). `0x62`: `io_dout <= ext_din` and `ext_rd` pulse per word (`:83-84`). | 78-85 |

`byte_cnt` is 3 bits and saturates at 7 (`:67`), so a burst has no length limit. After each rd/wr pulse `ext_addr` increments unless its low byte is `0xFF` (`:54`). Consequence used by the consumers: a streaming register whose decode only looks at `mgmt_address[3:0]==4'hF` must be addressed as `0xXXFF` to defeat the increment (e.g. `0xF0FF` for the IDE buffer, `0xF2FF` for the FDD FIFO). That the ARM does so is **inferred**; it is the only way the increment rule and the decoders fit together.

### 1.4 Address decode (`rtl/KFPC-XT/HDL/Peripherals.sv`)

| `mgmt_address[15:8]` | Consumer | Sub-address bits actually used | Cite |
|---|---|---|---|
| `0xF0` | `ide` (primary IDE, ARM-served) | `[3:0]` register/buffer | `:1527`, `:1566-1570` |
| `0xF2` | `floppy` | `[3:0]` register, `[7]` drive (0 = A, 1 = B) | `:1631`, `:1699-1703`; `fdd_present[addr[7]]` also latched at `:1633-1637` |
| `0xF4` | `rtc` (write-only) | `[7:0]` | `:1774`, `:1789-1791` |
| anything else | no write target | | |

Read mux (`:1738`): `mgmt_readdata = mgmt_ide0_cs ? mgmt_ide0_readdata : mgmt_fdd_readdata`. Reads of any non-`0xF0` page, including `0xF4`, return floppy read data. Bits `[7:4]` (IDE) and `[6:4]` (FDD) are ignored, so registers mirror.

### 1.5 Clock domain and strobe timing

- Everything is in one domain: `clk_chipset` = PLL `outclk_1` = 50 MHz (`rtl/pll.v:84`; `PCXT-EGA.sv:497-503`). `hps_io.clk_sys` and `hps_ext.clk_sys` are `clk_chipset` (`PCXT-EGA.sv:409`, `:462`); `CHIPSET.clock` is `clk_chipset` (`:1182`); `PERIPHERALS.clock` = `CHIPSET.clock` (`Chipset.sv:392`); `ide.clk`, `floppy.clk`, `rtc.clk` = `clock` (`Peripherals.sv:1545`, `:1677`, `:1778`). No synchronisers anywhere on the mgmt path.
- `mgmt_wr`/`mgmt_rd` are exactly one `clk_chipset` cycle wide; `mgmt_dout` and `mgmt_addr` are valid on the same edge (`hps_ext.v:53, 64, 69, 79, 84`).
- Consumers use the strobe **level** for register writes and FIFO/RAM enables (`ide.v:104`, `:295`; `floppy.v:84`, `:867`, `:869`; `rtc.v:298`), and `ide.v` uses the **trailing edge** for its buffer pointer (`ide.v:271-276`). A bridge must therefore drive single-cycle pulses: a multi-cycle level would push/pop one FDD FIFO byte per cycle (`rtl/common/simple_fifo.v:59, 65`).
- Read data is registered in the consumers (`ide.v:196-206`, one cycle; `floppy.v:845-849`, one cycle after the combinational FIFO head `simple_fifo.v:53`). `hps_ext` samples `ext_din` on the same edge it raises `ext_rd`, so the value returned is the one for the address *before* auto-increment / *before* the FIFO pop. A bridge must hold the address stable for at least 2 cycles before sampling `mgmt_din`, and sample it no later than the cycle it asserts `mgmt_rd`.

---

## 2. `rtl/common/ide.v` (ARM-served IDE)

### 2.1 Integration in the chipset

- CPU access is through XT2IDE at XT I/O `0x300..0x30F` (`Peripherals.sv:348`, instance `:1484-1506`, `high_speed=0` at `:1488`). With `high_speed=0`: `ide_address = address[2:0]`, command block when `address[3]=0` (`XT2IDE.sv:39-40, 59-60, 65`); `0x308` is the data high-byte latch (`XT2IDE.sv:48-54, 70-78, 91-99`).
- `ide.io_address[3]` = control block (`Peripherals.sv:1530`, `:1539`); only `ide_address[2:1]==2'b11` of the control block is decoded, i.e. `0x30E` (alt status / device control) and `0x30F` (drive address).
- `io_read` is a rising-edge pulse two cycles after the bus read starts (`:1536-1537`, `:1557`); `io_write` is the trailing edge of the write (`:1538`, `:1559`). `io_32 = 0` (`:1561`), `use_fast = 0` (`:1551`).
- **Not connected:** `irq`, `drq`, `no_data`, `drive_en`, `io_wait` (`:1548-1554`, `:1563`). The IDE controller never reaches the 8259; the XT-IDE BIOS polls status. Reg-5 bit 10 (raise IRQ) is therefore a no-op in this core.
- Read data path: `ide0_data_bus_in = ~ide_ignore ? ide_readdata : mmcide_readdata` (`:1609`).
- Master/slave split with the SD-card MMC device: `use_mmc = status[22:21]` latched at reset (`PCXT-EGA.sv:1718-1722`); `primary_only = (use_mmc==2'b10)`, `secondary_only = (use_mmc==2'b01)` (`Peripherals.sv:1572-1573`); `ignore_access = primary_only & drv_addr[4] | secondary_only & ~drv_addr[4]` (`ide.v:64`). `use_mmc==2'b11` disables the MMC (`:1582`) and `ide.v` serves both units; `2'b00` likewise.
- Drive-present gating: `io_wr = io_write & |present` (`ide.v:68`); reads return `0xFFFFFFFF` when `present==0` or `ignore_access` (`:73-75`).

### 2.2 CPU-side ATA registers (`io_address[3:0]`)

| `io_address` | XT port | Read (`ide.v:78-87`) | Write effect |
|---|---|---|---|
| 0 | 0x300 (+0x308 hi byte) | data: `buf_q` half selected by `io_cnt[0]`, only while DRQ, else 0 (`:78`) | data into buffer at `io_cnt` when DRQ (`:249`, `:298-301`, `:313-316`) |
| 1 | 0x301 | `error` (`:79`) | `features` (`:98`) |
| 2 | 0x302 | `sector_count` lo, or hi when HOB (`:80`) | shift: `{old lo, new}` (`:119`) |
| 3 | 0x303 | `sector` lo/hi (`:81`) | shift (`:127`) |
| 4 | 0x304 | `cylinder[7:0]` / `[23:16]` (`:82`) | shift into `{[23:16],[7:0]}` (`:135`) |
| 5 | 0x305 | `cylinder[15:8]` / `[31:24]` (`:83`) | shift (`:136`) |
| 6 | 0x306 | `drv_addr` (`:84`) | `drv_addr` (`:143`) |
| 7 | 0x307 | `status` (`:85`) and clears `irq` (`:193`) | `cmd` (`:149`); `status<=0x80` (`:156`); `io_wait<=use_wait` (`:179`); `request<=3'b100` (`:186`); `irq<=0` (`:193`). All ignored when `ignore_access`. |
| 14 | 0x30E | `status` (alt status, no irq clear) (`:86`) | device control: bit1 `disable_irq` (`:229`), bit2 `sw_reset` (`:235`, **level**, held until written 0), bit7 `hob_pre` (`:241`) |
| 15 | 0x30F | drive address `{2'b10, ~drv_addr[3:0], ~drv_addr[4], drv_addr[4]}` (`:87`) | none |

`hob = hob_pre & hob_ena[drv_addr[4]]` (`:245`); `hob_ena` comes from mgmt reg 6. The "shift previous into high byte" writes implement LBA48 order-of-writes semantics; the ARM sees both halves via mgmt regs 1..4.

Data phase counting: `io_stb = read_data_io | write_data_io` (`:254`); `io_cnt` (14-bit, units of 16-bit words) increments on the trailing edge of each data access by `1 + r_32` (`:256-265`); `io_done = (blk_size != 0) && io_cnt >= blk_size` (`:252`). `io_cnt` is zeroed by `reset` and by a mgmt write to reg 5 (`:262-263`).

### 2.3 mgmt-visible registers (base `0xF000`, decode on `mgmt_address[3:0]`)

Writes (`mgmt_writedata` = `wd`):

| Addr | Field | Effect | Cite |
|---|---|---|---|
| 0 | `wd[7:0]` | `blk_size <= {wd[7:0], 8'h00}`: block length in 16-bit words = sectors * 256 | `:104` |
| 0 | `wd[15:8]` | `error <= wd[15:8]` (ATA error register) | `:111` |
| 1 | `wd[7:0]` / `wd[15:8]` | `sector_count[7:0]` / `sector[7:0]` | `:117`, `:125` |
| 2 | `wd[15:0]` | `cylinder[15:0]` | `:133` |
| 3 | `wd[7:0]` / `wd[15:8]` | `sector_count[15:8]` / `sector[15:8]` | `:118`, `:126` |
| 4 | `wd[15:0]` | `cylinder[31:16]`; **also** if `blk_size[15]==1`, `blk_size <= wd[15:0]` (arbitrary word count; only reachable after a reg-0 write with `wd[7]=1`) | `:134`, `:105` |
| 5 | `wd[15]` BSY, `wd[14]` DRDY, `wd[12]` DSC, `wd[11]` DRQ, `wd[8]` ERR | `status <= {wd[15:14],1'b0,wd[12:11],2'b00,wd[8]}` | `:155` |
| 5 | `wd[9]` | `last_read` (final block of a read) | `:164` |
| 5 | `wd[10]` | `irq <= 1` unless `disable_irq` (no effect here, irq unconnected) | `:192` |
| 5 | `wd[13]` | `fast_read` (no effect, `use_fast=0`) | `:171` |
| 5 | `wd[7:0]` | `drv_addr <= wd[7:0]` (write back what was read from reg 5) | `:142` |
| 5 | any | side effects: `io_wait<=0` (`:178`), `request<=3'b000` (`:185`), `io_cnt<=0` (`:263`) | |
| 6 | `wd[3]`=1 | `{hob_ena[0], present[0]} <= wd[1:0]` (unit 0) | `:213` |
| 6 | `wd[7]`=1 | `{hob_ena[1], present[1]} <= wd[5:4]` (unit 1) | `:214` |
| 6 | `wd[9]`=1 | `use_wait <= wd[8]` (`io_wait` unconnected; write 0) | `:219` |
| 15 (`0xF`) | `wd[15:0]` | buffer word at `mgmt_cnt` (section 2.4) | `:295`, `:310` |
| 7..14 | | no write target | |

Reads (`ide.v:196-206`, registered, 1-cycle latency):

| Addr | Value |
|---|---|
| 0 | `{features[7:0], 6'd0, use_fast, io_done}` |
| 1 | `{sector[7:0], sector_count[7:0]}` |
| 2 | `cylinder[15:0]` |
| 3 | `{sector[15:8], sector_count[15:8]}` |
| 4 | `cylinder[31:16]` |
| 5 | `{cmd[7:0], drv_addr[7:0]}` |
| 6..15 | buffer word at `mgmt_cnt` (`:204`); but only addr 15 keeps `mgmt_cnt` counting (section 2.4) |

Reset values: `blk_size=0`, `error=0`, `sector_count=1`, `sector=1`, `cylinder=0xFFFFFFFF`, `drv_addr=0`, `cmd=0` (`:103`, `:110`, `:116`, `:124`, `:132`, `:141`, `:148`); `present`, `hob_ena`, `use_wait` have no reset (`:210-220`) and power up 0.

### 2.4 The data buffer at mgmt address `0xF`

- Storage: two `dpram #(12,16)` (`:289-317`) = 2 x 4096 x 16 bit = 16 KB = 32 sectors of 512 bytes. Word index `k` (16-bit words) lives in RAM `k & 1` at row `k >> 1`; the same layout is used by the CPU port (`address_b = io_cnt[12:1]`, half select `io_cnt[0]`), so the ARM streams plain little-endian 16-bit words in sector order.
- Pointer `mgmt_cnt` (14-bit, `:267-279`): on the **trailing edge** of `mgmt_write` or `mgmt_read`, if `mgmt_address[3:0]==4'hF` then `mgmt_cnt++`, else `mgmt_cnt<=0`. Also zeroed by `~rst_n`. Hence any access to regs 0..14 (including reading reg 5 or writing reg 0) rewinds the buffer pointer; the pointer is *not* reset by a data-phase completion.
- Write: `wren = mgmt_write & (&mgmt_address) & ...` selects the RAM by `mgmt_cnt[0]` at the pre-increment pointer (`:295`, `:310`).
- Read: reg-15 read data is the word at the current pointer; valid two cycles after `mgmt_cnt` changes (registered `q` + registered `mgmt_readdata`).
- Because `hps_ext` auto-increments the address, the ARM must use `0xF0FF` (low byte all ones) to stay on the buffer (section 1.3). With a direct bridge, any address with `[15:8]=0xF0`, `[3:0]=0xF` works.
- `no_data`/`n_data` (`:281-284`) compare `mgmt_cnt` and `io_cnt` for the unused fast-read mode; irrelevant here.

### 2.5 `request` encoding (`ide.v:183-188`, wired to `mgmt_req[2:0]`, `PCXT-EGA.sv:1321`)

| Value | Set when | Meaning for the bridge |
|---|---|---|
| `3'b110` | `reset` = `~rst_n \| sw_reset` (`:184`, `:224`) | Controller reset (power-on or CPU SRST). Held for as long as SRST is asserted; stays 110 after SRST release until the bridge writes reg 5. |
| `3'b100` | CPU wrote the command register (`:186`) | New command: read reg 5 (cmd/drive) and regs 0..4. |
| `3'b101` | `io_done & drq & ~last_read` (`:187`) | CPU finished one data block: for reads, buffer needs the next block; for writes, buffer holds a block to be stored. |
| `3'b000` | any mgmt write to reg 5 (`:185`) | Idle / acknowledged. |

There are no other encodings. While `reset` is active, the `status<=0x80` (`:154`) and `request<=110` (`:184`) assignments have priority over a mgmt reg-5 write, so a reg-5 write issued during SRST is lost for `status`/`request` (regs 1..4 and `drv_addr` still take).

### 2.6 Status transitions performed by `ide.v` itself

- CPU command write: `status<=0x80` (BSY) (`:156`), `request<=100`.
- Block complete, `last_read=1`: `status<=0x40` (DRDY only), request unchanged (`:157`); `last_read<=0` (`:165`).
- Block complete, `last_read=0`: `status<=0x80`, `request<=101` (`:158`, `:187`).
- `irq` cleared on any CPU access to reg 7 (`:193`) (unused).
- Everything else (DRQ, DRDY, ERR, DSC, error code, all register contents after a command, IDENTIFY data, sector data, CHS/LBA arithmetic, geometry, command decode) is the ARM's job. `ide.v` never inspects `cmd` (`:146-150` only stores it and reports it in reg 5).

### 2.7 Handshake sequences (as required by the RTL)

Notation: `W(n, v)` = mgmt write at `0xF000+n`, `R(n)` = mgmt read. `BUF` = `0xF00F` (`0xF0FF` through `hps_ext`). Sector = 256 words.

**Reset (request 110)**
1. Observe `request==110`.
2. `W(1, 0x0101)` (sector=1, count=1), `W(2, 0x0000)`, `W(3, 0x0000)`, `W(4, 0x0000)` -> ATA signature (ATAPI signature `cylinder=0xEB14` would go in reg 2; **speculative**, follows the ATA spec, not the RTL).
3. `W(5, {BSY=0, DRDY=1, DSC=1, DRQ=0, ERR=0, drv_addr=0x00})` = `0x5000` -> `status=0x50`, `request=000`.
4. If `request` still reads 110, SRST is still asserted (`:224`); repeat step 3 later. Reg 6 (present/hob_ena) is not affected by reset and need not be rewritten.

**New command with no data phase (request 100)** e.g. SET FEATURES `0xEF`, INITIALIZE DEVICE PARAMETERS `0x91`, RECALIBRATE `0x1x`, SEEK `0x7x`, FLUSH `0xE7`, NOP:
1. `R(5)` -> `{cmd, drv_addr}`; `R(0..4)` as needed (`features` in `R(0)[15:8]`).
2. Optionally `W(0, {error, 0x00})` (sets error; note it also sets `blk_size=0`), and `W(1..4)` with the register values the command should leave behind.
3. `W(5, {BSY=0, DRDY=1, DSC=1, DRQ=0, ERR=err, drv_addr})` -> `status` 0x50 / 0x51, `request=000`.
   For an unsupported command: `W(0, 0x0400)` (ABRT) then `W(5, 0x5100 | drv_addr)`.

**READ SECTORS / READ MULTIPLE / IDENTIFY (request 100, cmd 0x20/0x21/0xC4/0xEC)**
1. `R(5)`, `R(1)`, `R(3)`, `R(2)`, `R(4)` -> cmd, unit, count (`0` = 256 / 65536), LBA or CHS.
2. Pick block size `B` sectors, `1 <= B <= 32` (16 KB buffer, `:289-317`). `B` per DRQ event is the bridge's choice; `ide.v` only counts words. For IDENTIFY, `B=1` and the 256 words are the IDENTIFY structure.
3. `W(0, {error=0x00, B})` -> `blk_size = B*256` words; this access also rewinds `mgmt_cnt` (`:275`).
4. Stream `B*256` words to `BUF` (each write advances `mgmt_cnt`, `:274`).
5. Optionally `W(1..4)` with the post-transfer LBA/count (ATA requires this on completion; **speculative** whether the XT-IDE BIOS needs it).
6. `W(5, {BSY=0, DRDY=1, DSC=1, DRQ=1, ERR=0, last_read=(this is the final block), drv_addr})`: `0x5800 | (last?0x0200:0) | drv_addr` -> `status=0x58`, `io_cnt=0`, `request=000`.
7. CPU reads `B*256` words. When `io_done`:
   - last block: `status<=0x40`, done (`:157`).
   - else: `status<=0x80`, `request<=101` (`:158`, `:187`); go to step 3 (or step 4 if `B` is unchanged; a non-`0xF` access such as `R(5)` is still needed first to rewind `mgmt_cnt`).

**WRITE SECTORS / WRITE MULTIPLE (request 100, cmd 0x30/0x31/0xC5)**
1. As read, step 1. Choose `B`.
2. `W(0, {0x00, B})`.
3. `W(5, {BSY=0, DRDY=1, DSC=1, DRQ=1, ERR=0, last_read=0, drv_addr})` = `0x5800 | drv_addr`. `last_read` **must be 0**: with it set, block completion goes to `status=0x40` without raising `request=101` (`:157`) and the data is never handed over.
4. CPU writes `B*256` words. On `io_done`: `status<=0x80`, `request<=101`.
5. `R(5)` (or any non-`0xF` access) to rewind `mgmt_cnt`; then `R(BUF)` x `B*256` and store to the image.
6. If sectors remain: back to step 2 (or 3). Else `W(5, {DRDY=1, DSC=1, DRQ=0, drv_addr})` = `0x5000 | drv_addr` -> `status=0x50`.
   On a write error: `W(0, {error, B})` then `W(5, 0x5100 | drv_addr)`.

**Mount / unmount (no request involved)**
- Unit 0 present: `W(6, 0x0008 | {hob_ena0,1})` i.e. `0x0009` (LBA28 only) or `0x000B` (allow HOB/LBA48). Absent: `W(6, 0x0008)`.
- Unit 1: `W(6, 0x0080 | ({hob_ena1,present1} << 4))`.
- `W(6, 0x0200)` once to set `use_wait=0` (harmless either way since `io_wait` is unconnected).
- `ide.v` holds no geometry or capacity; CHS <-> LBA translation and the IDENTIFY contents are entirely the bridge's responsibility, using the geometry it advertises and the values received via INITIALIZE DEVICE PARAMETERS (`0x91`: heads = `drv_addr[3:0]+1`, spt = `sector_count[7:0]`; **ATA semantics, not enforced by RTL**).

### 2.8 Split of responsibilities

`ide.v` does: register file, BSY-on-command, word counting for PIO data, 16 KB buffer, automatic `status`/`request` transitions on block completion, reset signalling, present/ignore gating, HOB selection, SRST/nIEN latches.

The ARM (bridge) must do: decode `cmd`, validate LBA/CHS, geometry, IDENTIFY, all sector data movement, error codes, updating regs 1..4 after commands, choosing block sizes, and acknowledging every `request` by writing reg 5.

---

## 3. `rtl/common/floppy.v` (ARM-served FDC)

### 3.1 Integration in the chipset

- CPU ports `0x3F0..0x3F7` (`Peripherals.sv:349`); `io_address = address[2:0]` (`:1649`); `io_read`/`io_write` pulses (`:1650`, `:1652`), write data latched at `:1639-1645`.
- DMA channel 2 (`Chipset.sv:372`, ack `:502`; TC handling `Peripherals.sv:1664-1673`, `:1683`); IRQ6 (`Peripherals.sv:441`).
- `wp` input = OSD `status[20:19]` (`PCXT-EGA.sv:1318`; `floppy.v:90` ORs it with the mgmt write-protect).
- `clock_rate` is `clk_rate` scaled by the CPU speed selector (`Peripherals.sv:1708-1709`); used only for seek timing (`floppy.v:510-530`).
- `fdd_present[addr[7]] <= wd[0]` is latched a second time in the chipset (`Peripherals.sv:1633-1637`); `fdd_present[1]` drives the motherboard DIP switch "two floppies" (`PCXT-EGA.sv:1162-1164`), read by the BIOS at POST via port C (`:1164`). Drive B must therefore be mounted before boot to appear in the equipment word (**observation**).

### 3.2 mgmt-visible registers (base `0xF200` for A:, `0xF280` for B:; decode on `mgmt_address[3:0]`, drive on `[7]` = `mgmt_fddn`)

| Addr | Write (`wd`) | Cite | Read (`floppy.v:79`) |
|---|---|---|---|
| 0 | `media_present[drive] <= wd[0]` | `:84` | `{selected_drive[0], sd_sector[14:0]}` (drive-independent) |
| 1 | `wp_sys[drive] <= wd[0]` | `:89` | `0x0001` |
| 2 | `media_cylinders[drive] <= wd[7:0]` | `:93` | `0x0001` |
| 3 | `media_sectors_per_track[drive] <= wd[7:0]` | `:96` | `0x0001` |
| 4 | `media_sector_count[drive] <= wd[15:0]` (header comment `:57` says 31:0; register is 16-bit) | `:99-100` | `0x0001` |
| 5 | `media_heads[drive] <= wd[1:0]` (1 or 2; `:743`, `:393`) | `:103` | `0x0001` |
| 6..14 | none | | `0x0001` |
| 15 (`0xF`) | FIFO push of `wd[7:0]` (one byte per 16-bit word) | `:105`, `:866-867` | FIFO head byte (zero-extended) and pop (`:106`, `:869`, `:845-849`) |

The FIFO and the reg-0 read do not depend on `[7]`; `0xF2FF` serves both drives. No mgmt-readable geometry, motor, ready, or drive-select register exists beyond `selected_drive[0]` in the reg-0 read. Motor and drive select come only from the CPU's DOR write (`:143-155`).

### 3.3 `request` (`floppy.v:80-81`, wired to `mgmt_req[7:6]`, `PCXT-EGA.sv:1320`)

`request = (state in {S_SD_READ_WAIT_FOR_DATA, S_SD_WRITE_WAIT_FOR_EMPTY_FIFO, S_SD_FORMAT_WAIT_FOR_FILL}) ? {write_or_format_in_progress, read_in_progress} : 2'b00`.

| `mgmt_req` bit | Meaning | Cleared by |
|---|---|---|
| `[6]` (`request[0]`) | read: FIFO wants 512 bytes of sector `sd_sector` | `fifo_full` (`:693`) |
| `[7]` (`request[1]`) | write: FIFO holds 512 bytes for sector `sd_sector`; or format: pull 512 filler bytes | `fifo_empty` (`:701`) / 512 FIFO reads (`:711`, `:808-812`) |

One request per sector. Multi-sector commands step `sector`/`head`/`cylinder` in `S_UPDATE_SECTOR` (`:795-796`, `:787`, `:773`) and raise a fresh request per sector.

### 3.4 CHS to LBA (`floppy.v:740-759`, `:817`)

- `S_PREPARE_COUNT`: `logical_sector = (head ? spt : 0) + sector - 1` (`:757`); `mult_a = spt * heads` (`:743`; heads==2 -> `spt<<1`, else `spt`); `mult_b = cylinder` (`:750`).
- `S_COUNT_LOGICAL`: shift-add multiply, `logical_sector += cylinder * mult_a` (`:744`, `:751`, `:758`), loop until `mult_b==0` (`:690`, `:697`, `:708`).
- `S_PREPARE`: `sd_sector = (logical_sector >= total) ? total-1 : logical_sector` (`:817`).

So `LBA = (cyl * heads + head) * spt + sector - 1`, clamped. `sd_sector` is 16-bit but only `[14:0]` is exposed to mgmt (`:79`); images must be <= 32767 sectors.

### 3.5 Transfer completion

FIFO: `simple_fifo #(8,10)` (`:856-874`), 1024 deep, but "full" is defined as `fifo_count[9]` = 512 entries (`:841`); cleared whenever `state==S_IDLE` (`:864`). Data source/sink is muxed by state: mgmt side only when not `fifo_from_pc`/`fifo_to_pc` (`:851-854`, `:866-869`).

- **Read sector**: `S_IDLE -> S_PREPARE_COUNT -> S_COUNT_LOGICAL -> S_PREPARE -> S_SD_CONTROL -> S_SD_READ_WAIT_FOR_DATA` (`:687-692`, `:718`, `:721`). Bridge writes exactly 512 words to `0xF2FF`; at 512 `fifo_full` -> `S_WAIT_FOR_EMPTY_READ_FIFO` (`:693`), drained by DMA (`:824-826`, `:854`) or PIO (`:110`, `:854`). Then `S_UPDATE_SECTOR -> S_WAIT` (4000 clocks, `:734`) `-> S_CHECK_TC` (`:724-728`): finish (TC or non-DMA end of track: `:406-416`, result phase `:361`, IRQ `:370`) or next sector. Writing more than 512 bytes leaves data in the FIFO and corrupts the transfer (FIFO is not truly full until 1024).
- **Write sector**: `S_COUNT_LOGICAL -> S_WAIT_FOR_FULL_WRITE_FIFO` (`:697`); CPU fills 512 bytes -> `S_PREPARE -> S_SD_CONTROL -> S_SD_WRITE_WAIT_FOR_EMPTY_FIFO` (`:698`, `:700`). Bridge reads `0xF200` for `sd_sector` and pops 512 words from `0xF2FF`; `fifo_empty` -> `S_UPDATE_SECTOR` (`:701`).
- **Format track**: after 4 ID bytes per sector from the CPU (`:578-590`, `:706`) the same LBA path runs; `S_SD_FORMAT_WAIT_FOR_FILL` (`:710`) raises `request[1]`; the bridge pops 512 words, each returning `format_filler_byte` (`:847`) regardless of FIFO contents; after 512 reads `-> S_WAIT` (`:711`). The bridge writes those 512 bytes to `sd_sector`, exactly like a write.
- Commands that hang on the FDC side (motor off, no media, bad cylinder, `:387-391`) never raise a request; write-protect and head/sector errors terminate before any request (`:393-395`, `:358-362`).

### 3.6 What a mount / unmount must program

Unmount drive `d` (base `0xF200 | d<<7`): `W(0, 0)`. `change[d]` is forced 1 while media is absent (`:224`, `:230`).

Mount: `W(2, cylinders)`, `W(3, spt)`, `W(5, heads)`, `W(4, total_sectors)`, `W(1, wp)`, then `W(0, 1)`. The 0->1 transition of `media_present` is what produces the disk-change indication (change stays 1 until the controller clears it on a successful seek/read with media present, `:377-382`). Standard values: 1.44 MB = 80/18/2/2880; 720 KB = 80/9/2/1440; 360 KB = 40/9/2/720; 1.2 MB = 80/15/2/2400.

---

## 4. Other consumers of the mgmt bus

| Page | Module | Notes |
|---|---|---|
| `0xF4xx` | `rtl/KFPC-XT/HDL/rtc.v` | Write-only (`Peripherals.sv:1789-1791`, module has no `mgmt_readdata`). `mgmt_address[7]==0` writes CMOS RAM byte `[6:0]` (`rtc.v:497-499`) and simultaneously the live clock registers at `0x00..0x0B` and `0x32` (`:298-448`). Header mentions addresses 128/129 for cycle counts (`:45-46`) but no such decode exists in this file. CPU access is index/data at `0x340/0x341` (`Peripherals.sv:340`). Reads at `0xF4xx` return floppy data (`:1738`). `hps_io`'s own `RTC`/`TIMESTAMP` outputs are not used by the core. |
| - | `MSMouseWrapper`, `KFMMC_DRIVE_IDE`, UARTs, MPU401 | No mgmt ports (grep of `rtl/common/MSMouseWrapper.v`, `rtl/KFPC-XT/HDL/KFMMC/*`). The MMC drive talks SPI directly to the SD card (`Peripherals.sv:1602-1605`). |
| - | second IDE channel | None. Only `ide0` exists; `mgmt_req[5:3]` are hard 0 (`PCXT-EGA.sv:457`). |
| - | `ext_hotswap` | Tied `2'b00` (`PCXT-EGA.sv:472`). |
| cmd `0x63` | `ext_midi` | Decoded (`hps_ext.v:86`) but the output is unconnected. |

---

## 5. Bridge requirements

### 5.1 Bus level

Simplest replacement: drop `hps_ext` and drive `mgmt_addr/mgmt_dout/mgmt_wr/mgmt_rd` directly from the bridge, sampling `mgmt_din` and `mgmt_req` (`PCXT-EGA.sv:451-473`). Then the `hps_ext` quirks (word-0 status, dummy word 2, auto-increment, `0xFF` no-increment trick) disappear and only these rules remain:

1. Operate in `clk_chipset` (50 MHz) or add proper CDC on all six signals.
2. `mgmt_wr`/`mgmt_rd` are single-cycle pulses; `mgmt_addr`/`mgmt_dout` valid on the same edge.
3. For reads, hold `mgmt_addr` >= 2 cycles before, and capture `mgmt_din` on the edge where `mgmt_rd` is asserted (or earlier); FDD FIFO pops and IDE pointer advance happen after that edge.
4. Poll `mgmt_req` continuously; it is a level, updated by the consumers.
5. Any IDE non-`0xF` access rewinds the buffer pointer; keep register reads and buffer streaming strictly separated.

### 5.2 IDE bridge state machine (addresses `0xF00n`)

1. **Init/mount**: `W(6, 0x0009)` (unit 0 present, no HOB) and/or `W(6, 0x0090)` (unit 1); `W(6, 0x0200)`.
2. **Idle**: wait for `mgmt_req[2:0] != 0`.
3. **`110` reset**: `W(1,0x0101)`, `W(2,0)`, `W(3,0)`, `W(4,0)`, `W(5,0x5000)`; if `req` still `110`, retry after SRST release.
4. **`100` command**: `R(5)` -> `cmd`, `drv`; `R(0)` -> features; `R(1)`, `R(3)` -> count/sector; `R(2)`, `R(4)` -> cylinder/LBA. Branch:
   - no-data / unsupported: optionally `W(0, {err, 0})`; `W(5, 0x5000 | (err?0x0100:0) | drv)`.
   - read/IDENTIFY: `W(0, {0, B})`; stream `B*256` words to `0xF00F`; `W(5, 0x5800 | (last?0x0200:0) | drv)`.
   - write: `W(0, {0, B})`; `W(5, 0x5800 | drv)`.
5. **`101` block done**:
   - if a read is in progress: as read branch above for the next block (any non-`0xF` access first, e.g. `R(5)`).
   - if a write is in progress: `R(5)` (rewind), `R(0xF00F)` x `B*256`, store; then either `W(0,{0,B'})`+`W(5, 0x5800|drv)` for the next block or `W(5, 0x5000|drv)` to finish.
6. Return to 2.

Bridge-owned state: current command, unit, remaining sector count, current LBA, chosen `B`, per-unit geometry/capacity, IDENTIFY image.

### 5.3 Floppy bridge state machine (addresses `0xF200 | drive<<7 | n`, FIFO `0xF20F`)

1. **Mount** drive `d`: `W(0,0)`, `W(2,cyl)`, `W(3,spt)`, `W(5,heads)`, `W(4,total)`, `W(1,wp)`, `W(0,1)`. **Unmount**: `W(0,0)`.
2. **Idle**: wait for `mgmt_req[7:6] != 0`.
3. `R(0xF200)` -> `drive = [15]`, `lba = [14:0]`.
4. If `mgmt_req[6]` (read): fetch 512 bytes of image[`drive`] sector `lba`; `W(0xF20F, byte)` x 512. Stop at exactly 512.
5. If `mgmt_req[7]` (write or format): `R(0xF20F)` x 512, collecting `[7:0]`; store to image[`drive`] sector `lba`. (Format delivers the filler byte 512 times; handling is identical.)
6. Wait until the request bit drops (it drops on the 512th transfer), return to 2.

### 5.4 Open questions not resolvable from the RTL

1. Which block size `B` the original ARM uses per DRQ for `0x20`/`0x30` vs `0xC4`/`0xC5`, and whether the XT-IDE BIOS tolerates DRQ staying high across sector boundaries (ARM-side code `Main_MiSTer/support/x86` is not in this repo).
2. Whether the BIOS relies on regs 1..4 being updated after a transfer (ATA says yes; `ide.v` does nothing automatically).
3. Exact bit content the ARM writes into reg 5 (DSC, IRQ bit, `fast_read`) and reg 6 (`hob_ena`, `use_wait`); RTL shows only what each bit does.
4. Whether write-then-write of reg 0 / reg 4 (`blk_size[15]` path, `ide.v:105`) is ever used for this core (likely ao486-ATAPI only; **speculative**).
5. FDD: the `0x0001` read value of the non-zero registers (`floppy.v:79`) suggests the ARM probes something there; no consumer of it exists in the FPGA.
6. Whether the ARM re-writes `fdd_present` for drive B after boot (equipment word only sampled at POST).
7. RTC page `0xF4xx` write sequence used by the ARM (time-of-day and CMOS initialisation contents) is ARM-side.
