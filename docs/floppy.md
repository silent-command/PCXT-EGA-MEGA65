# Real floppies: DOS on the MEGA65's internal 3.5" drive

## Goal
Let DOS on this core read, and later write, real 3.5" PC floppies in the MEGA65's
internal drive: 720 KB double density (9 sectors per track, 250 kbit/s) and
1.44 MB high density (18 sectors, 500 kbit/s).

## Design, decided
The DOS-facing floppy controller stays exactly as it is: `CORE/rtl/overlay/floppy.v`
is an image-based FDC that is fed 512-byte sectors through `CORE/rtl/mgmt_bridge.sv`
-> `CORE/vhdl/vd_glue.vhd` -> the M2M vdrives -> the QNICE firmware (the SD card
image). A later phase adds a second, "physical drive" sector source behind that
interface: the FDC keeps asking for logical sectors, and instead of the image the
answer comes from a track read off the real drive. DOS, the BIOS and the DMA path
never learn the difference. Phases:

1. **Physical-layer spike** (this document, 2026-09-17): bring the drive up, seek,
   decode MFM at both rates, count what comes back, report on the serial status
   line, prove it on the board in one build. Modelled on the Ethernet spike
   (`docs/ethernet.md`, `CORE/vhdl/eth_phy_spike.vhd`).
2. **Read path behind the existing FDC** (done 2026-09-17, "Phase 2" below): a
   track cache (18 x 512 bytes in block RAM) filled by the spike's reader after a
   seek; the firmware answers the FDC's block requests for drive A from it,
   re-reading a track when the FDC moves on; DSKCHG through the mount strobe,
   write protect by mounting read-only. Geometry from the ID headers of track 0.
3. **Writes** (done 2026-09-17, "Phase 3" below): MFM encoder, write gate around the
   sector's data field only (22 bytes after the ID CRC to the end of the data CRC
   plus two bytes of gap), the sector taken from the FDC's block buffer, a
   background read-after-write verify, the mount read-write unless the tab says no.
4. **Formatting** (done 2026-09-17, "Phase 4" at the end): the FDC's FORMAT TRACK
   arrives at the firmware as a run of fill-byte block writes; a tap on floppy.v
   tells them from data, the engine writes the whole track from index to index
   (FORMAT_TRACK) on the first one and the rest are acknowledged; blank disks are
   mounted as 1.44 MB so that `FORMAT A:` can reach them.
5. **Disk detection on demand** (done 2026-09-17, section at the end): the drive is
   never touched while idle; an eject unmounts, DOS's own access attempt (seen in
   floppy.v) triggers the probe and detection, floppy.v drops a parked request on
   the FDC software reset the BIOS issues.

## The spike, 2026-09-17
`CORE/vhdl/floppy_phy_spike.vhd` (GPL, VHDL, 50 MHz chipset clock), bench
`CORE/rtl/tb/floppy_phy_spike_tb.sv` (`run_floppy_phy_spike_tb.ps1`). On the board
since 2026-09-17 (select, motor and seek confirmed by ear, counters being read); the
rest of what only the board can prove is listed at the end of this section. Since
phase 2 the spike is no longer instantiated (the sector engine drives the pins) and
its pin side and MFM reader live in `floppy_drive_if.vhd` / `floppy_mfm_reader.vhd`;
the spike itself still builds and its bench still passes with the same 1593 checks.

### What it does
Forever, on drive A only (the drive B lines stay tied off inactive in the top):

1. select the drive (kept selected always, so that TRACK0 / WPT / DSKCHG are
   observable while idle: PC drives only drive their outputs while selected, and the
   drive LED follows the select line, which is itself evidence the internal drive
   listens to the A select), motor on, spin-up 500 ms;
2. recalibrate: one step in if TRACK0 is already asserted (a step with a disk in is
   what clears the drive's latched DISK CHANGE), then step out until TRACK0 asserts,
   at most 85 steps (`seek_ok` records whether it did), settle 15 ms;
3. read for 3 index pulses at 500 kbit/s, then for 3 at 250 kbit/s; a phase also
   ends after 1 s without an index pulse (no disk, motor not turning);
4. seek to track 40, read for 3 index pulses at whichever rate produced good ID
   headers in step 3 (DD if neither), seek back to track 0;
5. motor off, wait 3 s (less if the DISK CHANGE line changes state), run again.

WRITE GATE and WRITE DATA are never asserted. SIDE1 stays at side 0.

### Reset-to-track-0 and timing evidence
Everything is taken from mega65-core (github.com/MEGA65/mega65-core, `master`,
checked 2026-09-17), which drives this exact mechanism; `sdcardio.vhdl` (the F011)
runs at `cpu_frequency` = 40.5 MHz (`mega65r3.vhdl:807`). The R6 top for that core is
only on their `development` branch; the pin list and polarities are the R3's
(`mega65r3.vhdl:199-213`, `mega65r3.xdc:389-405`, no pull-ups) and identical to
`M2M/MEGA65-R6.xdc:255-269`.

| item | value here | evidence |
|---|---|---|
| polarity | all lines active low | `sdcardio.vhdl:2109` `f011_write_protected <= not f_writeprotect`; `:2126-2128` `f011_track0 <= not f_track0; f011_over_index <= not f_index; f011_disk_changed <= (not f_diskchanged) or ...`; outputs default `'1'` (`:139-148`) |
| motor + select | asserted together, drive 0 = A lines | `:2353-2361` `f_motora <= not fastio_wdata(5); f_selecta <= not fastio_wdata(5)` |
| spin-up | 500 ms | F011 "wait for motor spin up" = 16000 ticks of 16 kHz = 1 s (`:2740-2742`); PC BIOS 3.5" value 500 ms |
| STEP pulse | 12 us low | `:2673-2675` `f_step <= '0'; step_countdown <= 500` (12.3 us at 40.5 MHz), released at `:2063-2066` "Stepping pulses should be short" |
| DIR | `'1'` = out towards track 0, `'0'` = in | `:2672-2674` (`x"10"` step out: `f_stepdir <= '1'`), `:2713-2716` (`x"18"` step in: `f_stepdir <= '0'`) |
| DIR set-up | 10 us before a pulse (RTL enforced) | interface asks for 1 us; the drive acts on the trailing edge 12 us later still |
| step rate | 3 ms | F011 default 8 ms (`f011_reg_step x"80"` in 16 kHz ticks, `:460`, `:2695`); PC BIOS 3-4 ms for 3.5" drives |
| head settle | 15 ms | PC BIOS head-settle value; mega65-core has none beyond the step interval |
| recalibrate | step out until TRACK0, limit 85 | the F011 has no recalibrate command; PC BIOSes step 77-80 with a limit |
| INDEX debounce | 4 samples (80 ns) | mega65-core 8 samples (`:1867-1877`) |
| RDATA filter | 3 consecutive low samples (60 ns) | `machine.vhdl:885-895`: low only when four consecutive samples are low |
| flux event | falling edge of the filtered RDATA | `mfm_gaps.vhdl:60` `last_rdata='0' and last_last_rdata='1'` |
| half cell | HD 50 clocks (1 us), DD 100 (2 us) | `cycles_per_interval` 40 / 81 at 40.5 MHz (`sdcardio.vhdl:3998-4000`, decoder instances `:950`, `:992`; default `cpu_frequency/500000`, `:467`) |
| quantiser | 2 half cells for hc..2.5 hc, 3 for ..3.5 hc, 4 for ..5 hc, else invalid | `mfm_quantise_gaps.vhdl:39-63` |
| sync mark | raw 0x4489 in a 16-bit shift register | `mfm_gaps_to_bits.vhdl:37` detects the same mark as gaps 2.0, 1.5, 2.0, 1.5 |
| CRC | CRC-16/CCITT 0x1021 preset FFFF over A1 A1 A1 FE C H R N | `crc1581.vhdl:92-95` (toggle bits 0, 5, 12), preset at the first mark and fed every mark as `mfm_decoder.vhdl:380-383` |
| DENSITY pin | HD `'1'`, DD `'0'` (generics, unproven) | mega65-core only writes it from the `$D6A0` debug register (`sdcardio.vhdl:3399-3407`), default `'1'` for everything; HD/DD is purely the decoder's rate there |

No PLL: the fixed +-0.5 half-cell windows read this drive in mega65-core, and the
bench passes them with +-3 % spindle speed and +-12 % half-cell jitter. A carry of
half the previous gap's error was considered and rejected: it halves jitter but
doubles a steady speed error; a frequency-tracking loop is the right refinement if
the board shows marginal reads, and belongs to phase 2.

### Status line (spike builds only; restored to `bist=` / `req=` / `hdd=` with phase 2)
`rom_loader` `dbg_a/b/c` -> `m2m-rom.asm` `DBG_STR_6..8` were `" fidx="`,
`" fchr="`, `" fst="` while the spike was instantiated:

| word | contents |
|---|---|
| `fidx` | `idam_crc_ok[7:0]` & `index_count[7:0]` |
| `fchr` | last good IDAM `C[7:0]` & `R[7:0]` |
| `fst` | `rate_hd, track0_seen, write_protect, disk_changed, seek_ok, motor_on, dd_found, hd_found` & `max_R[7:0]` |

`rate_hd` is the rate of the last good IDAM; `hd_found` / `dd_found` say which rate
produced good IDAMs in step 3 of the current or last run; `max_R` is the largest
sector number of this run (9 = 720 KB, 18 = 1.44 MB); `track0_seen` is sticky since
reset; `write_protect` / `disk_changed` are the live lines. Every counter (index,
marks, IDAMs, good IDAMs, DAMs, good DAMs, steps, runs), the last C/H/R/N, the
sequencer state, the head position by step count, the last gap length and the decoded
byte stream are on `dbg_*` taps in the 50 MHz domain, left open in `mega65.vhd`.

### Plumbing
* `CORE/vhdl/mega65.vhd`: `f_*` ports on `MEGA65_Core` next to the `eth_*` ones,
  `i_floppy_phy_spike` on `main_clk` / `main_rst` (the clock-lock reset, like the
  MAC), status words into `i_rom_loader`.
* `M2M/vhdl/top_mega65-r6.vhd`: the eight drive-A outputs and five inputs passed
  through raw (the tie-offs kept in a comment); `f_motorb_o` / `f_selectb_o` still
  tied to `'1'`.
* `CORE/CORE.xdc`: false paths from the five inputs (two-flop ASYNC_REG
  synchronisers inside) and to the eight outputs; IOB on STEP and DIR.
* `CORE/add-core-sources.tcl` lists the file; `CORE-R6.xpr` refreshed with it.

### Bench
`CORE/rtl/tb/floppy_phy_spike_tb.sv` (the drive model is now `floppy_drive_model.sv`,
shared with the engine bench) models the drive on the pins: outputs gated by
DRIVE SELECT, DISK CHANGE latched on eject/insert and cleared by a STEP with a disk
in, STEP on the trailing edge with checks of pulse width (1..20 us), step interval,
DIR set-up and hold (1 us), motor on for the spin-up time before the first pulse,
select and motor during steps, WGATE / WDATA / SIDE1 never asserted. Rotation plays a
synthetic System 34 track built for the current head position (gap 4a, IAM C2 C2 C2
FC, per sector: 12 x 00, A1 A1 A1 FE C H R N CRC, gap 2, 12 x 00, A1 A1 A1 FB, 512
bytes, CRC, gap 3; 18 sectors on 12500 bytes for HD, 9 on 6250 for DD) as MFM with
real 0x4489 / 0x5224 marks, 300 ns RDATA pulses, +3 % (HD) / -3 % (DD) spindle speed
and +-12 % half-cell random jitter on every transition; INDEX low for 2 ms per
revolution. Sector 5 has a corrupt ID CRC, sector 7 a corrupt data CRC. The DUT's
timers are shortened by generics (1 ms spin-up, 300 us steps, 0.5 ms settle, 2 index
pulses per phase, 250 ms index timeout, 50 ms repeat); the real STEP width is kept.

Scenario: HD disk in, head parked on track 5, DSKCHG latched; run 1; eject while
idle (the DSKCHG edge must start a run at once), insert a write-protected DD disk;
run 2; the periodic restart; eject, and a run without a disk must time out its read
phases. Checked at each sequencer state: head position in the model, the step
counts, TRACK0 / DSKCHG / WPT and the flags, the DENSITY level per phase, the counter
deltas per phase (17 good IDAMs and DAMs per HD revolution, 8 per DD revolution, the
corrupt ones rejected, nothing decoded at the wrong rate), C = 40 after the seek,
`max_R` 18 then 9, `rate_hd` per disk, and the three status words against the
`dbg_*` taps through the clock crossing.

Result: **PASS, 1593 checks** (most of them the model's per-step timing checks over 251 STEP pulses), 21 revolutions, 162 IDAMs of which 150 good and 163 DAMs of which 149 good (exactly the corrupt ones rejected), about 4.5 s of simulated time in about 5 minutes of xsim. Per HD
revolution the reader delivers 18 IDAMs / 17 good, 18 DAMs / 17 good, 108 marks;
per DD revolution 9 / 8, 9 / 8, 54; at the wrong rate nothing at all (the 250 kbit/s
windows reject every 500 kbit/s gap as too short and the other way round). What the
bench found on the way: the sequencer issued its step request in the same cycle it
changed DIR, before the set-up timer had loaded, so one step per seek was lost and
the one-step-in recalibrate never pulsed (fixed: the request waits for the direction
change to be seen); xsim's kernel crashes on a `return` out of nested loops inside a
`fork` (bench restructured).

### Resources
Vivado 2026.1 out-of-context (`CORE/synth-vhdl-ooc.tcl floppy_phy_spike`,
`CORE/ooc/floppy_phy_spike/floppy_phy_spike-util.rpt`): 372 LUTs, 539 FFs, no block
RAM, no latches, no `Synth 8-327`. The read path of phase 2 adds the track buffer
(one RAMB36 per 4 KB) and nothing else of note.

### What only the board can prove
* **Select and motor**: whether the internal drive listens to the A lines
  (`f_selecta_o` / `f_motora_o`, as mega65-core's drive 0 does) or is jumpered as
  B; the drive LED lights with select, the motor is audible. If neither, swap to the
  B lines in `top_mega65-r6.vhd`.
* **Sense of the inputs**: `fst` bit 14 (`track0_seen`) and bit 11 (`seek_ok`) after
  the first run; `fidx` low byte counting 5 per second while the motor runs (index at
  300 rpm); bit 13 (`write_protect`) following the tab; bit 12 (`disk_changed`)
  set after an eject and cleared by the next run's recalibrate step.
* **RDATA and the rates**: `fidx` high byte (good IDAMs) advancing and `fchr` /
  `max_R` = 18 with a 1.44 MB disk, 9 with a 720 KB disk, `rate_hd` (bit 15)
  accordingly; C = 40 in `fchr` while the head is on track 40 (about 1.5 s into a
  run) and 0 otherwise.
* **DENSITY**: whether HD reads need the pin driven (`G_DENSITY_HD` / `G_DENSITY_DD`
  in `floppy_phy_spike.vhd`, defaults `'1'` / `'0'`); if HD disks only read with
  the pin at the other level, swap the generics; if both work either way, the
  mechanism ignores the pin (most 3.5" PC drives do, they sense the HD hole).
* **Margins**: a real drive's peak shift and speed against the fixed +-0.5 half-cell
  windows; `dbg_last_gap_o` on a scope-less board is best read by widening the
  status words temporarily.
* **Timing closure** of the whole core with the module in: it adds nothing to the
  chipset paths; the synchroniser inputs are false paths.

---

## Phase 2: the read path, 2026-09-17
DOS can `DIR A:` and `TYPE` a file from a PC-formatted 720 KB or 1.44 MB floppy in
the internal drive when the Options menu toggle **Input Settings / A: internal
drive** is on. `CORE/rtl/overlay/floppy.v` is untouched; the spike's status-line
hijack is gone (`bist=` / `req=` / `hdd=` are back). **Not yet run on the board**;
what only the board can prove is at the end of this section.

### The pieces
| file | role |
|---|---|
| `CORE/vhdl/floppy_drive_if.vhd` | the pin side of the spike (synchronisers, INDEX / RDATA filters, step engine with the DIR set-up rule), shared |
| `CORE/vhdl/floppy_mfm_reader.vhd` | the spike's gap quantiser, sync detector, byte assembler and IDAM / DAM decoder with CRC, shared; events out (`idam_o`/`idam_ok_o`, `dam_o`, `data_valid_o`, `dam_end_o`/`dam_ok_o`) |
| `CORE/vhdl/floppy_phy_spike.vhd` | the spike on top of the two, same ports and behaviour, no longer instantiated but still built and benched (1593 checks as before) |
| `CORE/vhdl/floppy_sector_engine.vhd` | the read path: commands DETECT / READ_TRACK / COPY / PROBE / MOTOR_OFF, an 18 x 512-byte track cache in block RAM, motor timer, disk-change latch; instantiated in `mega65.vhd` on `main_clk` in place of the spike |
| `CORE/vhdl/rom_loader.vhd` | the engine's registers in 4k window `0xFFFD` of the PCXT ROM device (0x0110), request/acknowledge toggles across QNICE / core clocks, result capture; `flp_blk_err_o` to the bridge |
| `CORE/vhdl/vd_glue.vhd` | the engine's COPY writes a block into the framework's block buffer through the core-side port (a mux on port B) |
| `CORE/rtl/mgmt_bridge.sv` | `blk_err` input: a floppy block acknowledged with it high is not streamed and the request is parked (`fd_hold`) |
| `CORE/vhdl/main.vhd`, `mega65.vhd` | plumbing; menu bits above 75 shifted by one |
| `CORE/vhdl/config.vhd` | line 76 " A: internal drive" (group `OPTM_G_FLP_INT` = 21), `OPTM_SIZE` 98 -> 99, `sdcard/m2m/m2mcfg` regenerated (99 bytes) |
| `CORE/m2m-rom/flpdrv.asm`, `flpdrv_vars.asm`, `flpdrv_calc.asm` | the firmware: mount/unmount, probing, detection, the block-request handler; hooked into `M2M/rom/shell.asm` (`HANDLE_MOUNTING`, `HANDLE_DRV_RD/WR`, `HANDLE_IO`) and `m2m-rom.asm` (`PREP_START`, `OSM_SEL_POST`) |

### Design: a track cache rather than a sector reader
A sector-at-a-time engine would answer each FDC request by waiting for the IDAM
of that one sector. Between two consecutive sectors DOS reads there is only the
inter-sector gap, about 2 ms at 500 kbit/s (gap 3 + sync + marks), and the
turnaround from one block to the next request is about 1.4 ms (floppy.v's DMA
of the previous sector into PC memory, its 80 us wait, the bridge, the firmware's
poll and command); any hiccup costs a full revolution (200 ms) per sector, i.e.
a track in 3.6 s. So `READ_TRACK` captures *every* sector of the track whose ID
header matches (C, H, N = 2, 1 <= R <= 18, ID CRC good) into its own 512-byte slot,
CRC-checking the data field, for one revolution (2 index edges) or until all
sectors 1..spt are in; a slot already valid is never overwritten (a re-read with
a bad CRC cannot spoil a good copy). A later `READ_TRACK` for the same track,
head and rate with the wanted sector valid is a cache hit and completes in two
clocks without the motor. The cache is dropped by any head step, a rate or side
change, a disk change, DETECT and disable. `COPY` streams slot R into the
vdrive block buffer in 512 clocks; the firmware copies nothing byte by byte.

Timing (real generics): spin-up 500 ms, 3 ms steps, 15 ms settle, 100 us side
switch, 1 s index timeout (no disk), motor off 2 s after the last command. A
first sector on a cold drive costs 0.5 s + the seek + up to 2 revolutions; the
rest of the track is free; a track change costs a seek plus 1..2 revolutions.

### The block-request flow with the physical source
1. floppy.v gets READ DATA C/H/R from the BIOS, computes
   `LBA = (C*2 + H) * SPT + R - 1` with the SPT of the mount, raises `mgmt_req[6]`.
2. `mgmt_bridge` reads the LBA, raises `blk_rd(0)`; `vd_glue` crosses it into
   the QNICE domain; `vdrives.vhd` sets `VD_RD` for drive 0.
3. The shell's `HANDLE_IO` polls `VD_RD`, calls `HANDLE_DRV_RD`, which asks
   `FLP_OWNS_DRIVE` (drive 0 and the toggle on) and hands over to `FLP_DRV_RD`.
4. `FLP_DRV_RD`: LBA from `VD_BYTES_H:L`, C/H/R with `FLP_LBA2CHS` using the SPT the
   FDC was told (`FLP_SPT`), `READ_TRACK(C, H, rate, R, spt)`; the engine either hits
   the cache or motors, recalibrates if the head position is unknown, seeks and
   captures; the firmware checks `valid(R)`; on a miss it retries once with
   `force` (recalibrate first); then `COPY(R)` into the block buffer, clears the
   block-error flag and strobes `VD_ACK`.
5. The bridge sees the acknowledge fall, streams the 512 bytes to floppy.v's FIFO
   (`0xF2FF`), which DMAs them to the PC and raises IRQ 6, exactly as for an image.

### Geometry
At mount the firmware runs DETECT (motor, recalibrate, 500 kbit/s for two index
edges, then 250 kbit/s). Good ID headers at 500 kbit/s = 1.44 MB: the FDC is told
1474560 bytes (80/2/18) like a 1.44 MB image; at 250 kbit/s = 720 KB: 737280 bytes
(80/2/9); the largest R seen is logged. The inverse conversion in `flpdrv_calc.asm`
uses that told SPT and only that, never the rate: sectors are 1-based, LBA 0 =
C0 H0 R1, LBA 18 = C0 H1 R1 on 1.44 MB, LBA 36 = C1 H0 R1 (checked for every LBA
of both geometries by `tools/vdrive-latency-bench/run_flp_chs.sh`, which runs the
real routine in the QNICE emulator). In phase 2 the mount was read-only, so
writes never reached the firmware: floppy.v answered them with its write-protect
error and DOS printed "Write protect error writing drive A"; since phase 3 the
mount follows the drive's write-protect line.

### No disk, disk change
With no disk the FDC is unmounted (`media_present` = 0): its change bit stays set,
the BIOS answers every DOS access with "not ready" at once and DOS prints "Not
ready reading drive A. Abort, Retry, Fail?" like a real PC with the door open.
Phase 2 then probed the drive every 2 s (one step in and out without the motor,
which clears the drive's DISK CHANGE latch when a disk is in) and re-ran DETECT on
every change while mounted; that made an empty drive click for ever and is gone.
Since "Disk detection on demand" (end of this document) an eject unmounts at once
and the probe runs only when DOS tries to use the drive.

### Read errors: what floppy.v allows, and what was chosen
floppy.v cannot be told about a read error: the ARM sends 512 bytes whatever
happened ("image missing or read error -> 512 zero bytes"), and its SD state
machine leaves `S_SD_READ_WAIT_FOR_DATA` only on `fifo_full` or the chip reset
(`rst_n`); the DOR software reset clears `busy` and the interrupt but not
`state`. Zeros would make DOS read garbage silently. So when the engine's two
attempts leave sector R invalid (ID never seen, data CRC bad, no index), the
firmware acknowledges the block with the block-error flag set and the bridge
streams nothing: floppy.v keeps waiting, the BIOS's INT 13h times out (error 80h),
DOS retries and prints "Not ready reading drive A"; the still-pending request is
parked so the hard disk keeps being served. In phase 2 drive A was then dead until
the next core reset, because only that released floppy.v's state machine; since
"Disk detection on demand" the overlay floppy.v drops the request on the FDC
software reset the BIOS issues on its error path, so a Retry raises a fresh one.
`mgmt_bridge_tb` test 16 covers all of it (5121 checks in phase 2, now with the
DOR reset as the recovery).

### Menu
"A: internal drive" is a single-select toggle in Input Settings, saved with the
other settings. On: any image mounted on A: is unmounted, the engine is enabled,
one PROBE runs and, with a disk in, DETECT and the mount (or the drive is left
"no disk", unmounted); the Drive A line shows "Internal drive" and is inert while
the toggle is on (`HANDLE_MOUNTING` returns without browsing). Off: unmount, engine
disabled (motor off, drive deselected). At start-up `PREP_START` applies the saved
toggle and waits for the probe and detection so that the BIOS can boot from A:. `FLP_MENU_LINE` (76) and `FLP_MENU_GRP` (21) in
`flpdrv.asm` must follow config.vhd.

### Registers
Documented in the header of `rom_loader.vhd`: write 0 command, 1 cylinder/head/
rate/force, 2 sector/spt, 3 control (enable, disk-change clear, block error);
read 0 status (busy, live flags, error), 1 detect result, 2/3 valid and CRC-error
slots, 4 cache track and slots 17/18, 5 state and head position, 6..11 counters.
The command write toggles a request into the core clock; the engine's completion
toggles an acknowledge back; busy is the XOR of the two on the QNICE side (set by
the write itself, cleared in the same clock as the result capture, so there is
no window in which a fast firmware sees "idle" with stale results - the
`rom_loader_tb` found exactly that window in the first version).

### Benches
* `run_floppy_sector_engine_tb.ps1` (`floppy_sector_engine_tb.sv`, drive model
  `floppy_drive_model.sv` shared with the spike bench, now with both sides and
  configurable corrupt sectors): disabled engine; DETECT on an HD disk from track 5;
  every valid sector of C0 H0 copied and compared byte for byte (5 rejected by ID CRC,
  7 by data CRC); the bad sector stays bad after a plain and a forced re-read; bad
  arguments; the wrong rate; seeks to C40 H1, H0 without a seek, C3; a cache hit in
  two clocks; motor-off and spin-up; eject / PROBE / insert a write-protected DD disk;
  DETECT DD, C0 H0 and C7 H1 verified; sector 12 of a 9-sector track stays invalid;
  no disk: READ and DETECT time out; a clean track fills and exits early; disable.
  Result: **PASS, 1086 checks** (41 revolutions, 429 good ID headers, 428 good data fields, 125 steps), about 6.2 s of simulated time in 12 minutes of xsim.
* `run_rom_loader_tb.ps1`: the register window, the toggles, result capture, the
  dropped command while busy, control levels and the clear pulse, no ROM words from
  the window: pass.
* `run_mgmt_bridge_tb.sh` (WSL, Icarus): test 16 as above: pass.
* `tools/vdrive-latency-bench/run_flp_chs.sh` (WSL): the real `FLP_LBA2CHS` for all
  2880 + 1440 LBAs plus the corner cases: pass, 4320 conversions and 12 corner cases, 0 failures.
* `run_floppy_phy_spike_tb.ps1`: the refactored spike: pass, 1593 checks.
* The benches found (and the fixes are in): a PROBE that changed DIR in the same
  cycle as its step request lost the step (the spike's lesson again), and one that
  changed DIR 20 ns after the step request, while STEP was still low, made the
  drive step the wrong way, since a drive samples DIR at the trailing edge (the
  model now flags any DIR change during a STEP pulse; DIR changes only once the
  step engine is ready again, 3 ms after the pulse); the busy-before-capture
  window in `rom_loader`.

### Resources (Vivado 2026.1 out of context, `synth-vhdl-ooc.tcl` now takes dependencies)
`floppy_sector_engine` with the two shared modules: 620 LUTs, 541 FFs, 4 RAMB36, no latches, no `Synth 8-327`;
`rom_loader` with the register block: 302 LUTs, 543 FFs. The cache is 18 x 512
bytes in a 14-bit address space, which costs 4 RAMB36 (3 would hold it; the
core has 165 free).

### What only the board can prove
* Everything the spike could not prove (select, input senses, DENSITY, margins).
* **PROBE / DISK CHANGE**: that a step without the motor clears the drive's latch
  when a disk is in and leaves it when not (mega65-core's wording; the model does
  the same). Proven by the first board result below: the re-inserted disk was
  noticed by exactly such a probe.
* **The BIOS timeout** against the first-sector latency (spin-up 0.5 s + recalibrate
  + seek + up to 2 revolutions): the 8088_bios INT 13h timeout is 2 s like IBM's; if
  it bites, shorten `G_CAP_INDEX` handling or keep the motor on longer.
* **Sequential throughput**: the cache should make a track cost one or two
  revolutions; the serial log's `FLP:` lines and the `hdd=`-style counters tell.
* **The dead-drive-after-error behaviour** and that the reset button revives A:
  (superseded: see "Disk detection on demand", the BIOS reset revives it).
* **DOS's reaction to the eject/insert re-mount** on a disk change with the same
  geometry (superseded: an eject now unmounts, see "Disk detection on demand").

## First board result, 2026-09-17: DOS reads a real disk
Build of commit 03ba1c6 (WNS +0.177, no violations) on the R6, a 1.44 MB
PC-formatted disk in the internal drive, "A: internal drive" switched on in
Input Settings, FreeDOS booted from the hard-disk image: `DIR A:` listed the
disk and `TYPE A:\HELLO.TXT` printed the file. First bitstream, no changes
needed. The physical-layer spike had run earlier on a MEGA65-formatted disk
(drive audibly seeking and reading); its counters were not read before the
read-path build superseded it.
Follow-up on the same build: a second `DIR A:` and `COPY A:\*.* C:\` work,
`DIR A:` takes a couple of seconds; with the disk ejected DOS shows its normal
"Error reading drive A" Abort/Retry prompt, and after re-inserting the disk
Retry recovers and `DIR A:` works again.

---

## Phase 3: writes, 2026-09-17
DOS can `COPY` files onto the disk in the internal drive and `DEL` them, on a
1.44 MB or 720 KB PC floppy, and the result reads back on this core; whether a
PC reads it is for the board (end of this section). `floppy.v` is still
untouched; the image-based drives are unaffected while the toggle is off (the
firmware hooks all sit behind `FLP_OWNS_DRIVE`). **Not yet run on the board.**
FORMAT (phase 4) is not designed out: the writer takes any byte sequence with
marks, and a whole-track write is the same writer started at the index with a
longer sequence.

### The pieces
| file | role |
|---|---|
| `CORE/vhdl/floppy_mfm_writer.vhd` | new: MFM encoder (clock bits per the MFM rule, A1 marks as raw 0x4489), the bit-cell timer at 50 / 100 clocks per raw bit, the WRITE DATA pulse, write precompensation, WRITE GATE |
| `CORE/vhdl/floppy_sector_engine.vhd` | command 6 WRITE_SECTOR, a 512-byte write buffer loaded from the framework's block buffer, the splice timing, the background verify (below), error codes 7 (write protected) and 9 (track seen, sector not), the wait for pending verifies before the head moves |
| `CORE/vhdl/floppy_mfm_reader.vhd` | `data_crc_o`: the two data-CRC bytes as received, for the verify |
| `CORE/vhdl/floppy_drive_if.vhd` | `wgate_i` / `wdata_i` (active high) onto the two pins; WRITE GATE forced off while the drive is not selected |
| `CORE/vhdl/vd_glue.vhd` | the core-side port of the block buffer can now be read by the engine (`flp_buf_rd_i` / `flp_buf_rdata_o`, one clock latency like the bridge's) |
| `CORE/vhdl/rom_loader.vhd` | control bit 3 (clear verify-failed), read 12 (verify pending / failed, live), nine live flags; the clear pulses held low in reset |
| `CORE/rtl/mgmt_bridge.sv` | `fd_dead`: a floppy *write* block acknowledged with `blk_err` parks every later floppy request until the chip reset |
| `CORE/m2m-rom/flpdrv.asm` | `FLP_DRV_WR` (LBA -> C/H/R, WRITE_SECTOR, retry with recalibrate, acknowledge), the mount read-write unless the drive says write protect, the verify check, the cache-dirty bypass |
| `M2M/rom/shell.asm` | the dirty-cache flush loop skips the internal drive like an SD-direct drive |
| `CORE/vhdl/main.vhd`, `mega65.vhd`, `CORE-R6.xpr`, `add-core-sources.tcl` | plumbing, the new file |

### The write timing: where the new data field starts, and why
IBM System 34 puts 22 bytes of 4E (gap 2) between the ID field's CRC and the
12 bytes of 00 that precede the data field's A1 A1 A1 FB. Gap 2 exists for
the write splice: a controller that rewrites a data field cannot know the exact
phase of the old sync field, so it starts writing *its own* sync field where
the old one was, and the reader resynchronises on the 0x4489 marks; the 22
bytes are what a controller is allowed to lose to its ID-field decode latency,
speed differences between the drive that formatted the disk and the one
writing, and head-switch and erase-turn-on delays.

Two controllers, the same rule:
* WD177x ("WD177x-Prog.txt", Write Sector): *"The 177x then counts off 22 bytes
  from the CRC field. ... the controller writes 12 bytes of zeroes. The 177x then
  writes a normal or deleted Data Address Mark ... writes the byte which the CPU
  placed in the Data Register, and continues ... After the 177x writes the last
  byte, it calculates and writes the 16-bit CRC. The chip then writes one $ff
  byte"* and drops write gate.
* mega65-core (`sdcardio.vhdl` `F011WriteSectorRealDriveWait` /
  `F011WriteSectorRealDrive`, master, checked 2026-09-17): on `fdc_sector_found`
  (the decoder's "data gap begins now" after the ID CRC check) it opens
  `f_wgate` at once and writes 23 x 4E (its `fdc_write_byte_number` 0..22, i.e.
  it rewrites gap 2 instead of waiting it out), 12 x 00, 3 x A1 with clock byte
  FB (the missing clock), FB, 512 bytes, CRC, then 6 x 4E "really only to make
  sure MFM writer has flushed last CRC byte before we disable f_wgate", and
  closes the gate. Same splice point, different lead-in.

Here: the engine counts `G_WR_GAP2_BYTES` (22) x 16 half cells from the
reader's `idam` event less `G_WR_LEAD_HC` (4) half cells, opens WRITE GATE and
starts the writer; the first raw bit reaches the head 3 half cells later (the
writer's precompensation window) and the reader's `idam` comes 0..1 half cell
(plus 5 clocks) after the CRC's last bit, so the first zero lands within about
half a half cell of where the old sync field began, plus whatever the two
drives' speeds differ over 22 bytes (1 % = 3.5 half cells). Everything before
it in gap 2 stays as it was (WD style); the drive model measures the splice at
21 (HD) / 22 (DD) bytes after the ID CRC (22 nominal, the model plays the HD disk 3 %
slow and the DD disk 3 % fast). The field written: 12 x 00, 3 x A1 (raw 0x4489),
FB, 512 bytes, CRC-16/CCITT 0x1021 preset FFFF over A1 A1 A1 FB and the data
(the reader's polynomial), then `G_WR_TAIL_BYTES` (2) x 4E so that the CRC's
last clock bit is defined and the last transition is on the disk before the
gate closes (WD writes one FF, mega65-core 6 x 4E), then WRITE GATE off one data
cell after the last transition. The old gap 3 stays; the model measures WRITE
GATE off 122 (HD) / 61 (DD) bytes before the next sector's ID sync field (gap 3 is 108
/ 80 bytes in the model, 84 / 80 in the uPD765's format tables; the field
written is 530 bytes at the writer's rate, so it lands 3 % shorter or longer on
the disk than the original at the model's spindle speeds).

Bit cells: one raw MFM bit per half cell, 50 clocks (1 us) at 500 kbit/s and
100 (2 us) at 250 kbit/s, exactly the cells the reader quantises against; the
WRITE DATA pulse is low for half a raw bit (0.5 / 1 us) from the middle of the
raw bit, mega65-core's `f_write` timing (`transition_point =
cycles_per_interval / 2`, citing the SMSC FDC37C78 figure 7, "0.5 x WCLK");
the drive acts on the falling edge. The A1 mark is the fixed raw 0x4489; every
other byte gets its clock bits from the MFM rule with the previous byte's last
data bit carried across (mega65-core `mfm_bits_to_gaps.vhdl` `bit_queue`).

### Write precompensation: implemented, off by default
Evidence: mega65-core has it (`mfm_bits_to_gaps.vhdl`: a 7-raw-bit window,
three bits before and after the one being written, shifts of
`write_precomp_magnitude` 4 / `_b` 8 cycles at 40.5 MHz, about 100 / 200 ns)
but only applies it when bit 2 of the F011 command says so (`$84` "add 4 for
write precompensation", `f011_write_precomp <= fastio_wdata(2)`), on every
track alike, and by default writes this mechanism without it. The WD177x
applies "1/8 of a cycle" when its ENP bit asks and documents that
"programmers typically enable precompensation on the innermost tracks"; a PC's
82077 defaults to 125 ns on all tracks in MFM. mega65-core's table writes a
transition with a close neighbour *before* it *late* ("pulse will be pushed
early, so write it a bit late"), the opposite of the classic peak-shift rule
(read peaks of close transitions move apart, so such a transition reads late
and is written early); whether their sign was tuned on this mechanism or is a
slip is not recorded. With the two sources disagreeing on the sign, no board
evidence yet, and the same drive proven to read what it writes without
precompensation in mega65-core, the decision is: the writer implements the
classic rule (`precomp_i` clocks early when the nearer neighbour is before,
late when after, distances 2 / 3 / >= 4 half cells compared, mega65-core's
window), the engine enables it from cylinder `G_PRECOMP_FROM_CYL` with
`G_PRECOMP_CYCLES` clocks, and both default to 0 = off. The bench runs it at 4
clocks (80 ns) from cylinder 20 to prove the path. Turning it on is a
two-generic change once the board says whether inner tracks written without it
read back on a PC.

### The verify: in the background, by CRC signature
A read-after-write inside the command would cost a revolution per sector
(200 ms); DOS writes runs of consecutive sectors (a track's worth for a big
COPY, then the FAT and the directory), floppy.v hands them over one at a time
and the BIOS's INT 13h times out at about 2 s, so 18 sectors x (write + a
revolution) would fail every large copy. Instead WRITE_SECTOR ends when WRITE
GATE drops; the engine remembers the CRC it wrote for the slot, invalidates the
slot and leaves the verify *pending*. The capture logic, which for reads fills
the cache from every matching ID header, now also runs whenever the head is on
the cached track: the written sector comes around on the next revolution, is
captured like any invalid slot, and the verify passes when its data CRC checks
*and* the CRC bytes read back equal the ones written: the data is
byte-identical with probability 1 - 2^-16, and an unwritten old sector with a
good CRC of its own (WRITE GATE having no effect: a polarity or drive problem)
is caught, without a second buffer or a compare port on the cache. Meanwhile
the next sector's WRITE_SECTOR is already accepted: consecutive sectors are
written on the same revolution (the bench writes sectors 7 and 8 within 60 ms
after sector 6; the ID header of the next sector follows the written field by
about 3.4 ms at 500 kbit/s) and their verifies queue up (a bit per slot, 18
CRCs). A pending verify fails after `G_VFY_INDEX` (2) index edges without the
sector coming around, on a motor stop, a disk change or the index timeout; any
command that must move the head, switch side or rate, recalibrate or DETECT
first waits for the pending verifies (at most about two revolutions), so a
write is never left unchecked by a seek. The 100 us side settle is skipped when
neither side nor rate changes.

Reporting: `vfy_pend` / `vfy_fail` are live in register 12; control bit 3
clears the failure. The firmware (`FLP_VFY_CHECK`, from `FLP_POLL` and before
every block request) latches a failure into `FLP_VFY_ERR` and acknowledges the
*next* block request, read or write, with the block-error flag; the bridge then
parks the drive (`fd_dead` for a write, `fd_hold` for a read) until the reset
button. That is one request late, and it cannot be earlier: floppy.v completes
a WRITE DATA sector the moment its FIFO is drained into the block buffer, before
the request even reaches the firmware, and reports success to the BIOS; the
only way DOS learns of a failed write is the following access timing out
("Error writing drive A. Abort, Retry, Fail?"), which for a COPY is the next
data sector, the FAT or the directory write. A write that fails outright
(no index, the ID header never found, the recalibrate limit) is retried once
with a recalibrate, then acknowledged with the block error the same way; a
write-protect refusal is not retried.

### The write-cache bypass and the mount
The framework's vdrives keeps an image write cache: HANDLE_DRV_WR copies the
block into the image buffer, vdrives marks the drive's cache dirty on the
acknowledge, and HANDLE_IO flushes it to the SD card 2 s after the last write
(`shell.asm` FLUSH_CACHE, vdrives.vhd's `cache_flush_de`). The physical drive
has no image: `FLP_DRV_WR` writes the sector when the FDC delivers it (the
bridge has already drained floppy.v's 512 bytes into the block buffer, which
the engine reads through vd_glue in 512 clocks into its own write buffer), and
`FLP_ACK` clears the dirty flag right after the acknowledge that set it; the
flush loop in HANDLE_IO also skips the drive the way it skips SD-direct drives
(otherwise it would try to flush a RAM cache through file handle 0). The block
protocol of `docs/floppy-write-multisector.md` is unchanged: one acknowledge
per block, the bridge returns to idle and dispatches the next sector's request,
which floppy.v raised while we were still writing; the acknowledge is held for
the same 16 instructions as for reads.

The mount: `FLP_STROBE` reads the drive's write-protect line (valid while the
drive is selected, which it always is with the toggle on) and mounts read-only
when it is asserted, read-write otherwise; every re-mount (a disk change re-runs
DETECT and mounts again) re-evaluates it, and the log line says which. With a
read-only mount floppy.v refuses writes itself with the FDC's write-protect
error, so DOS prints "Write protect error writing drive A" and nothing reaches
the firmware; the engine refuses with error 7 anyway before touching WRITE
GATE, for the case of a tab moved without a disk change (a write then parks the
drive like any other failure). No disk: the FDC is unmounted, so no write
request exists; a write on a drive whose disk vanished mid-way ends in "no
index" after 1 s.

### Benches
* `run_floppy_sector_engine_tb.ps1`: the drive model (`floppy_drive_model.sv`)
  now records writes: while WRITE GATE is low it stores every WRITE DATA
  falling edge at its angular position in units of the disk's own raw bit
  (fractional, so the writer's clock against the +-3 % spindle is kept and the
  splice phase is real), erases the raw bits it passes, mutes RDATA, keeps the
  recording per cylinder and side and replays it with jitter in place of the
  erased bits on later revolutions. It checks WRITE GATE only with select, motor,
  disk and no write protect; WRITE DATA only under WRITE GATE, 0.1..2.5 us wide,
  transitions >= 1.5 half cells apart; WRITE GATE on inside gap 2 or the data
  sync field and off inside the same sector's gap 3 at least 30 bytes before the
  next ID sync field; no write across the index; `corrupt_next` drops one
  recorded transition of the next write. Cases added after the phase-2 scenario:
  one sector on the cached track, verify, then a forced re-read of the track
  with every sector compared (17 originals, 1 written); a write-protected disk
  refused before WRITE GATE; sector 0 / 19 / cylinder 83; a write after a seek
  (cylinder 30, with precompensation); sectors 6, 7, 8 back to back and a read
  of sector 7 before its verify; a write the model corrupts fails its verify, the
  flag clears, the rewrite passes; a read of cylinder 31 right after a write on
  30 waits for the verify; the wrong rate (no header) and no disk (no index); on
  a DD disk at 250 kbit/s one sector, one after a side switch, sector 12 of 9
  refused with error 9, both tracks re-read and compared.
  Result: **PASS, 66805 checks** (1086 in phase 2; the model checks every one of the
  ~3200 WRITE DATA pulses of each of the 10 writes for width and spacing), 69
  revolutions, 764 good ID headers, 748 good data fields, 265 steps, about 15 s of
  simulated time in roughly 50 minutes of xsim. What it found on the way: the
  model's first "WRITE GATE off inside gap 3" check was wrong for a disk turning
  slower than the writer assumes (the new field ends inside the tail of the old
  one, which is what really happens); the read of a just-written sector is a cache
  hit (the verify filled the slot), so the bench reads the next sector, as DOS does.
* `run_vd_glue_tb.ps1` (new, with `vd_glue_wrap.vhd` flattening the vdrives
  array ports for xsim): the block buffer in both directions: the bridge
  writes, the engine loads through the new read port and the QNICE side sees
  the same bytes; the engine's COPY writes and the bridge reads back; the
  engine's address is ignored while it is idle; a block request and its
  acknowledge cross. Result: **PASS, 8 checks**.
* `run_rom_loader_tb.ps1`: the verify-clear pulse (alone, with the disk-change
  clear, never spuriously: a start-up pulse from the X on the synchroniser
  outputs was found, and the clear outputs are now held low in reset), the nine
  live flags with register 12, a WRITE_SECTOR command through the window.
  Result: **PASS** (4 commands, 2 + 2 clear pulses, 592 ROM words as before).
* `run_mgmt_bridge_tb.sh`: test 17: a floppy write block acknowledged with
  `blk_err`: the sector completes in floppy.v (DOS cannot learn of it there),
  the drive is parked, the next read request stays pending with nothing fetched
  and no IRQ, the hard disk is still served, the chip reset revives it, a good
  write afterwards leaves the drive alive. Result: **PASS, 7246 checks** (5121
  before).
* `run_floppy_phy_spike_tb.ps1`: the spike on the extended model: **PASS, 1844 checks**
  (1593 before; the model now also checks "no STEP under WRITE GATE" at each of its
  251 steps).
* `tools/vdrive-latency-bench/run_flp_chs.sh`: unchanged code, re-run: pass, 4320
  conversions and 12 corner cases, 0 failures.
* The firmware assembles (`make_rom.sh`, 26819 ROM lines).

### Resources (Vivado 2026.1 out of context, `synth-vhdl-ooc.tcl`)
`floppy_sector_engine` with its three modules: 1250 LUTs, 793 FFs, 4 RAMB36 +
1 RAMB18 (was 620 / 541 / 4 in phase 2: the write buffer is the RAMB18; the 18
remembered CRCs and their comparator, the per-slot index counters, the write
byte sequencer with its CRC and the writer are the rest); `floppy_mfm_writer`
alone: 112 LUTs, 71 FFs; `rom_loader`: 311 LUTs, 555 FFs (302 / 543). No
latches, no `Synth 8-327` (the 77 warnings are the XPM memories' unconnected ports).

### What only the board can prove
* **The write splice on real media**: the model puts the splice where the maths
  says; a real drive adds its erase-to-write turn-on time, and whether the sync
  field written over the old one gives a clean 0x4489 on read-back is the first
  thing the `FLP:` log ("write verify failed") tells after the first
  `COPY CON A:\X.TXT`. `last_wr_lead` = 21 / 22 bytes in the model is the
  number to move (`G_WR_LEAD_HC`) if it does not.
* **Write current at HD versus DD**: 3.5" drives switch the write current from
  the HD hole, some from the DENSITY pin (`G_DENSITY_HD` / `_DD`, still unproven
  either way); a 720 KB disk written with HD current is unreadable elsewhere.
  Write a 720 KB disk here, read it on a PC.
* **Whether a PC reads what we wrote**: the same disk in a PC drive after a
  `COPY`; then the inner tracks (a full disk) to decide the precompensation
  generics.
* **The verify against real margins**: a false "verify failed" on a good write
  parks the drive; the log says which LBA, and `G_VFY_INDEX` can be raised to 3
  if the read-back needs a second revolution on marginal media.
* **The BIOS timeout on long writes**: a track's worth of consecutive sectors
  should cost one to two revolutions plus the firmware's per-sector turnaround;
  if the `FLP:` counters show a revolution per sector, the main loop's poll is
  the place to look (the engine's part is 10 us for the load plus the gap).
* **DOS after a failed write**: that the parked drive produces "Abort, Retry,
  Fail?" and the reset button revives A:, as for reads.

## Phase 3 on the board, 2026-09-17: writes work
First attempt (commit 42ef96d): every write refused with "write error
lba=0013 status=0000" - FLP_DRV_WR cleared its status register before
comparing the block size with 512 (fixed in ec28ea1, one line; the read
handler never had the slip). The disk was untouched, because DOS writes
data before the directory and the first data write was refused.

Second attempt (ec28ea1 built, WNS +0.053, no violations), 1.44 MB PC disk
with the write-protect slider closed: `DIR A:`, `COPY C:\FDCONFIG.SYS A:\`,
`DIR A:`, `TYPE A:\FDCONFIG.SYS` (reads back correctly), `COPY C:\COMMAND.COM
A:\` (85 KB, a few seconds), `DEL A:\FDCONFIG.SYS`, `DIR A:` - all correct;
the disk in a PC drive lists the files and COMMAND.COM is intact. So the
splice point, the write timing at 500 kbit/s, the background verify and the
read-write mount all hold on real media. Not yet exercised on the board:
720 KB (250 kbit/s) writes, a write-protected disk, formatting (phase 4).

---

## Phase 4: formatting, 2026-09-17
`FORMAT A:` from DOS on a blank, erased or foreign disk in the internal drive
produces a standard 1.44 MB disk (or a 720 KB one from a disk detected as 720 KB).
**Not yet run on the board**; what only the board can prove is at the end of this
section. floppy.v is *tapped* (a read-only management register) and, separately,
*fixed* in one condition: with this core's DMA timing it never wrote the last
sector of a track and ended every FORMAT TRACK with "abnormal termination", which
the BIOS turns into error 20h "controller failure" - so `FORMAT A:` could not have
worked on this core even with an image (see "The floppy.v fix").

### How DOS formats, and what the firmware sees
FreeDOS FORMAT issues INT 13h AH=05h per cylinder and head (with an ID list of
C, H, R = 1..SPT, N = 2), reads the track back (its verify pass, AH=04h or 02h),
and at the end writes the boot sector, the FATs and the root directory with
ordinary AH=03h writes. The 8088_bios (`floppy2.inc` `int_13_fn05`) seeks, sends the
uPD765 FORMAT TRACK command `4D HD/DS N=2 SC GPL D` with SC / GPL / D from its INT 1Eh
table (1.44 MB: 18 / 0x6C / 0xF6, 720 KB: 9 / 0x50 / 0xF6) and DMAs the ID list with
a count of SC x 4 - 1. floppy.v (`CORE/rtl/overlay/floppy.v`, ao486's image-based
controller) refuses the command outright (it "hangs", the BIOS times out) when SC
is not the mounted image's sectors per track; otherwise, per ID field, it computes
`sd_sector = (C * 2 + H) * SPT + R - 1` from the ID's C and R (the head from the
command byte), enters `S_SD_FORMAT_WAIT_FOR_FILL` with `request[1]` set and lets
the bridge pop 512 x the filler byte through its FIFO. **So what reaches the
firmware is 18 (or 9) ordinary block writes of fill bytes to consecutive LBAs**,
indistinguishable from DOS writing those sectors - and they must be
distinguished, because formatting destroys a track while a data write to a bad
sector must not silently reformat it (a heuristic "a write to a sector whose
ID header is missing is a format" was rejected for that reason).

### The tap
* floppy.v: management register 1 (address `F201`, which the original ARM side
  never reads; it returned a constant 1) now returns `{fill, SC[6:0], D[7:0]}`:
  bit 15 = the controller is in `S_SD_FORMAT_WAIT_FOR_FILL` for a format command
  (this request is a fill), bits 14..8 = the command's sector count, 7..0 = its
  filler byte. Nothing the CPU sees changes.
* `mgmt_bridge.sv`: one extra bus read per floppy request (`S_FDD_TAP`, after the
  LBA read) latches that word into `fd_fmt`, held until the next dispatch. It has
  to be sampled *per request*: floppy.v's format command ends 80 us after the
  bridge pops the last sector's fill, long before the firmware handles that
  block, so a level would be gone for the last sector.
* `main.vhd` `flp_fmt_o` -> `mega65.vhd` -> `rom_loader.vhd` register **14** of
  window `0xFFFD` (a 16-bit `xpm_cdc_array_single`; the word is stable from more
  than 512 core clocks before the block request rises until the firmware's
  acknowledge, so the bit-wise crossing is safe). Register **15** shows the gap 4b
  count of the last FORMAT_TRACK (debug), **write 4** carries the engine's third
  argument (fill byte 7..0, gap 3 length 15..8, 0 = default). Control bit 4 and
  register 13 belong to the on-demand detection.

### The floppy.v fix (DOS-visible, deliberate)
`Peripherals.sv` presents the 8237's terminal count to floppy.v in the same
clock as the acknowledge of the last byte (`dma_tc = fdd_dma_tc &
fdd_dma_rw_ack`), i.e. together with the 4th ID byte of the last sector.
Upstream's `cmd_format_in_input_finish = ~execute_ndma && dma_has_terminated`
then pre-empted the completed ID field in `S_WAIT_FOR_FORMAT_INPUT`: the last
sector's fill was never requested and the command ended from that state with
ST0 = 0x40. `fdc_get_error` maps that to 20h; every AH=05h failed. (ao486's own
DMA presumably presents TC a clock later, where the code works.) The overlay
adds `&& format_data_count != 3'd4`: a completed ID field is processed first,
the terminal count then ends the command normally in `S_CHECK_TC` after that
sector - what a uPD765 does (after TC it formats to the end of the track and
reports normal termination). `mgmt_bridge_tb` test 19 saw 17 fills and ST0 0x40
before the fix, 18 fills (LBA 36..53) and ST0 0x00 after it. Image-based
floppies get the same fix: the last sector of every formatted track is now
written too.

### The engine: FORMAT_TRACK (command 7)
`floppy_sector_engine.vhd`, arguments cylinder / head / rate / spt (1..18) /
fill / gap 3. Refused with err 7 while the drive reports write protect, before
anything moves; err 5 for cylinder > 82 or spt 0 / > 18. Then motor, the wait
for pending verifies if the head must move, recalibrate / seek / settle as for
a write; at the seek-settle point every slot, CRC-error bit and pending verify of
the track is dropped (the track is about to disappear; `cache_valid` stays set
for the read-back). `S_FMT_INDEX` waits for the leading edge of the INDEX pulse
(err 1 after 1 s: no disk); at the edge WRITE GATE goes on and the byte
sequencer (`fr`, `fr_cnt`, `fr_sec`) feeds the writer the IBM System 34 track:

| region | bytes | content |
|---|---|---|
| gap 4a | 80 | 4E |
| sync | 12 | 00 |
| IAM | 4 | C2 C2 C2 (raw 0x5224, the writer's new `mark_c2_i`) FC |
| gap 1 | 50 | 4E |
| per sector: ID | 12 + 3 + 1 + 4 + 2 = 22 | 00 x 12, A1 A1 A1 (raw 0x4489), FE, C, H, R, 02, CRC |
| gap 2 | 22 | 4E |
| data | 12 + 3 + 1 + 512 + 2 = 530 | 00 x 12, A1 A1 A1, FB, 512 x fill, CRC |
| gap 3 | 84 (HD, 0x54) / 80 (DD, 0x50) | 4E |
| gap 4b | until the next index | 4E |

CRC-16/CCITT 0x1021 preset FFFF over A1 A1 A1 FE C H R N and over A1 A1 A1 FB +
data, computed on the fly as the writer takes each byte (`wr_crc`, reset when
the sync field ends). At the next INDEX edge the sequencer stops the writer
(`fmt_stop`; the writer drains its window and drops WRITE GATE within about
2 bytes) and, if the index came before gap 4b, reports err 11 (the track did
not fit). `fmt_tail_o` counts the gap 4b bytes written = the margin left. Then
the reader is reset and the engine runs its normal track capture once
(`S_CAPTURE`, early exit when all spt sectors are in): that is the format's
verify *and* it leaves the track in the cache, so DOS's own verify pass costs
no disk time; if not every sector 1..spt came back with good CRCs the command
ends with err 10 (`valid_o` says which did; err 3 if nothing was read back).

### The timing budget, and why gap 3 is 0x54 and not the BIOS table's 0x6C
The writer runs at exactly 500 / 250 kbit/s (50 / 100 clocks per raw bit); the
spindle is what varies, and a fast spindle brings the next index *before* the
sequencer has finished. Bytes per revolution: 12500 (HD, 200 ms at 16 us) /
6250 (DD, 32 us); at +3 % spindle speed 12136 / 6068. What must lie before the
index is everything up to and including the last sector's data CRC; gap 3 of
the last sector and gap 4b are filler.

| | lead-in | per sector | last CRC ends at | whole track | fits +3 % fast? | gap 4b at nominal |
|---|---|---|---|---|---|---|
| HD, gap 3 0x6C (108, BIOS 1.44 MB table) | 146 | 682 | 12314 | 12422 | **no**: 12136 available, 178 bytes of sector 18 cut; fits only up to +1.5 % (1 byte spare) | 78 |
| HD, gap 3 0x54 (84, the datasheet's 15-sector / 1.2 MB value) | 146 | 658 | 11906 | 11990 | yes, 230 bytes (3.7 ms) spare before the last CRC, 146 bytes of gap 4b | 510 |
| DD, gap 3 0x50 (80, the BIOS 720 KB table) | 146 | 654 | 5952 | 6032 | yes, 116 bytes spare, 36 bytes of gap 4b | 218 |

So the task's requirement (never overrun the index with a +-3 % spindle)
cannot be met with 0x6C at 500 kbit/s: the IBM value assumes a drive within
about +1.5 %. 84 bytes of gap 3 is still three times what the WRITE_SECTOR
splice needs (the model's minimum margin is 30 bytes; a data field written on a
3 % slower drive than the formatter's lands 16 bytes longer) and more than the
uPD765's minimum read/write gap for 512-byte MFM sectors (0x1B). The engine
defaults are `G_FMT_GAP3_HD` = 84 / `G_FMT_GAP3_DD` = 80; the firmware passes
0 (= default). The bench formats the same track with 0x6C on a 3 % fast disk
and gets err 11, and with the default gets 100..200 bytes of gap 4b.

Per track on the board: seek (3 ms per step + 15 ms settle) + up to one
revolution to the index (200 ms) + one revolution of writing + the read-back
(one revolution when every sector comes back, two otherwise): about 0.45 to
0.65 s, so a 1.44 MB disk formats in roughly 80..105 s of drive time plus DOS's
verify pass (cache hits) and the FAT / root writes; the motor is spun up once
(0.5 s) and stays on between tracks. The BIOS's 2 s INT 13h timeout covers the
first fill's acknowledge (spin-up + format + read-back < 1.5 s); the other 17
fills are acknowledged within the firmware's poll latency.

### The ack rule (firmware, `CORE/m2m-rom/flpfmt.asm`)
`FLPF_WR_HOOK`, called from `FLP_DRV_WR` once the request is converted and
checked (LBA in range, mounted read-write, no verify failure pending, no disk
change), reads register 14. Bit 15 clear: an ordinary write, back to
WRITE_SECTOR. Bit 15 set: the block is a fill; the track key is C * 2 + H.
* R = 1, or a track other than the one formatted last (`FLPF_TRK`): run
  FORMAT_TRACK with the tap's sector count and filler and the rate of the mount,
  two attempts (the second with a recalibrate), none after a write-protect
  refusal; on success remember the key and acknowledge, on failure log
  "format error status=", forget the key and acknowledge with the block error
  (the bridge parks the drive as for a failed write, DOS's next access fails
  and FORMAT reports the track).
* otherwise (R > 1 of the track formatted last): acknowledge without any disk
  activity - the content is the filler byte and it is on the disk already
  (`FLPF_N_ACK` counts them). 18 WRITE_SECTORs would cost 18 revolutions.
R = 1 always formats so that a retry of the same track (FORMAT's own retry
after a verify error, or a second FORMAT run) never gets acknowledged fills for
a track that was not written again. The boot sector, FATs and root directory
arrive as ordinary writes afterwards and take the phase 3 path. `FLPF_INIT`
(from `FLP_INIT`) initialises the state; the include of `flpfmt.asm` sits at the
end of `flpdrv.asm` and of `flpfmt_vars.asm` at the end of `flpdrv_vars.asm`, so
the emulator bench `flp_ondemand.asm` gets both.

### The blank-disk mount decision
With the on-demand detection a disk that DETECT cannot read at either rate
was "no disk": unmounted, `FORMAT A:` got "Not ready". Now `FLP_DET_APPLY` asks
`FLPF_BLANK`: when the DETECT ended without error (index pulses came, so a disk
turns) but neither rate produced a header, the disk is mounted **as 1.44 MB
read-write** (read-only if the tab says so) with the log line "turns but nothing
readable: blank or foreign disk, mounted as 1.44 MB for FORMAT". That covers a
blank disk, an erased one and foreign formats (Amiga, a MEGA65/1581 disk):
DOS reading it gets errors (the BIOS's FDC reset releases the request, "Abort,
Retry, Fail?"), `FORMAT A:` makes it a PC disk. 1.44 MB because the interface
has no way to sense the HD hole (the drive senses it itself and sets its write
current accordingly) and the MEGA65's drive is an HD drive; a DD blank
formatted this way would fail its read-back on the first track (write current
/ media mismatch) and FORMAT would report track 0 - the documented limitation.
Not supported: `FORMAT A: /F:720` on a disk mounted as 1.44 MB. floppy.v refuses
the FORMAT TRACK whose SC (9) is not the mount's (18) before it reaches the
firmware, the BIOS times out (error 80h), FORMAT reports the track, the disk is
untouched; so the sector count in the tap always equals `FLP_SPT`. A 720 KB PC
disk (detected as such) formats as 720 KB with plain `FORMAT A:`. The mechanics
for /F:720 exist (a tap of the refused command's SC, a re-mount with that
geometry, the user's second FORMAT then succeeds) but are not built.

### Benches
* `run_floppy_sector_engine_tb.ps1`: the drive model (`floppy_drive_model.sv`)
  gained blank disks (no flux at all), a sector-count / gap 3 override (a
  MEGA65/1581-style DD disk: 10 sectors, gap 3 30), a spindle speed factor per
  rate, and full-track writes: with `fmt_expect` set, a write may start within
  4 bytes after the index (gap 4a) and must end within 8 bytes after the next
  one with exactly one index inside; it replaces the whole recording of the
  track, and the region map of a formatted track is rebuilt from the layout the
  bench announced, scaled by the writer's rate against the spindle, so that
  later sector writes are still checked against the new gap 2 / gap 3. New
  cases, after the phase 3 ones: a blank HD disk on a 3 % *fast* spindle
  (DETECT: err 0, no HD, no DD, index seen - the firmware's blank rule; a read
  finds no header); FORMAT C0 H0 with the defaults (18 sectors read back by the
  engine, every sector compared as 512 x F6, then a forced re-read and DETECT
  finding 18 sectors); the same track with gap 3 0x6C: err 11 overrun, then
  formatted again with fill E5; C40 H1 after a seek with precompensation, then a
  WRITE_SECTOR onto the fresh format (the splice lands in our own gap 2) and a
  full compare; write protect refused before WRITE GATE; the 1581-style DD disk
  (DETECT sees 10 sectors) formatted with 9 on both sides, its old sector 10 gone,
  DETECT then sees 9; no disk (err 1); cylinder 83, 0 and 19 sectors (err 5).
  Result: **PASS, 847954 checks** (66805 in phase 3; the format cases measure 135 gap 4b bytes at 500 kbit/s and 31 at 250 kbit/s on a 3 % fast spindle).
* `run_mgmt_bridge_tb.sh` (WSL, Icarus, the overlay floppy.v): test 19: a
  FORMAT TRACK of C1 H0 through the BIOS's exact sequence (6 command bytes, the
  ID list by DMA with TC on the last byte) produces 18 block writes of 512 x F6 to
  LBA 36..53 with `fd_fmt` = {1, 18, F6} at every dispatch and a normal
  termination; a normal write and a read afterwards are dispatched with the tap
  bit clear (the fill bytes read back). Result: **PASS, 9481 checks** (8306
  before; the same bench showed 17 fills and ST0 0x40 before the floppy.v fix).
* `run_rom_loader_tb.ps1`: registers 14 / 15 read back through the window,
  write 4 reaches the engine with a FORMAT_TRACK (code 7) command. Result: PASS.
* `tools/vdrive-latency-bench/run_flp_ondemand.sh` (the real flpdrv.asm +
  flpfmt.asm in the QNICE emulator): tests 20..22: the fill of C1 H0 R1 issues
  exactly one FORMAT_TRACK with arg0 = C1 H0 HD, arg1 = SC 18, arg2 = F6 and is
  acknowledged clean; the fills of R2 and R18 are acknowledged without a
  command; C1 H1 R1 and a fill of R5 of a track not formatted are formatted; R1
  of the track just formatted formats again; the same LBA without the tap bit is
  a WRITE_SECTOR; a format that fails: two attempts (the second with force), the
  block error, the next fill of that track formats again; write protected: one
  attempt; a blank disk (index, no headers) mounts as 1.44 MB read-write with
  SPT 18 at 500 kbit/s, without index pulses it is NODISK. Result: **PASS, 155
  checks** (117 before).
* `run_vd_glue_tb.ps1`: unchanged, re-run: PASS, 8 checks. `run_floppy_phy_spike_tb.ps1`
  on the extended model: PASS, 1844 checks (unchanged).
* The firmware assembles (`make_rom.sh`, 27295 ROM lines).

### Resources (Vivado 2026.1 out of context, `synth-vhdl-ooc.tcl`)
`floppy_sector_engine` with its three modules: 1417 LUTs, 846 FFs, 4 RAMB36 +
1 RAMB18 (phase 3: 1250 / 793 / the same RAM): the format sequencer, its byte
mux and the gap counters are the 167 LUTs. `rom_loader`: 336 LUTs, 644 FFs
(311 / 555 in phase 3; includes the on-demand access flag). No latches, no
`Synth 8-327`.

### What only the board can prove
* **PC readability of a MEGA65-formatted disk**: `FORMAT A:` here, then the disk in
  a PC drive: `DIR`, `CHKDSK`, a file copied both ways. The sync fields, IAM and
  gaps are written by our clock; a PC's controller must lock onto them.
* **The DOS FORMAT verify pass** against the cache: FORMAT reads every track back
  right after formatting it; those reads should be cache hits (the `FLP:` log
  shows no READ_TRACK disk time between "formatted, gap 4b bytes=" lines).
* **The gap 4b count** (`FLP: formatted, gap 4b bytes=`, register 15) on the real
  spindle: about 500 at nominal speed, 146 at +3 %; a value near 0 or an err 11
  means the drive is faster than +3 % and `G_FMT_GAP3_HD` must come down.
* **Write current on a DD blank**: a 720 KB blank is mounted as 1.44 MB and should
  fail its read-back on track 0 (documented); a 720 KB PC disk formats as 720 KB.
* **FORMAT /F:720 on an HD mount**: the FDC-level refusal should end in FORMAT's
  error message with the disk untouched.
* **The BIOS timeout on the first fill** (spin-up + up to one revolution to the
  index + the write + the read-back) and the total format time.
* **Erase-to-write turn-on at the index**: WRITE GATE goes on at the index edge;
  a drive that needs time before the first transition eats into gap 4a (80
  bytes, 1.3 ms), which a PC ignores anyway.
