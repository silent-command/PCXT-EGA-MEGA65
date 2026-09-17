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
3. **Writes**: MFM encoder with write precompensation (mega65-core's
   `mfm_bits_to_gaps.vhdl` has one, tuned on this mechanism), write gate around the
   sector's data field only (from the IDAM's end to the end of the data CRC plus a
   few bytes of gap), sector written back from the buffer.
4. **Formatting**: whole-track writes from the FDC's format command (the FDC already
   collects C/H/R/N per sector into its buffer for the image path).

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
real routine in the QNICE emulator). The mount is read-only, so writes never
reach the firmware: floppy.v answers them with its write-protect error and DOS
prints "Write protect error writing drive A". The drive's own write-protect line
is reported in the status register for later.

### No disk, disk change
With no readable disk at mount time the FDC is left unmounted (`media_present` = 0):
a DOS access "hangs at start" in floppy.v, the BIOS times out and DOS prints
"Not ready reading drive A. Abort, Retry, Fail?" like a real PC, and the FDC stays
clean. While in that state the firmware issues a PROBE every 2 s: one step in
and one out without the motor. A step with a disk in clears the drive's latched
DISK CHANGE, so the line afterwards tells a disk from none. A disk found is
detected and mounted, so a Retry after inserting the disk works. A disk change
while mounted (the engine latches the rising edge of DISK CHANGE, checked in the
main loop and before every request) re-runs DETECT and re-mounts: floppy.v sees
eject/insert, sets its change line, DOS re-reads the disk; a removed disk unmounts.

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
parked so the hard disk keeps being served; drive A is dead until the next core
reset (the reset button), because only that releases floppy.v's state machine.
A later phase can add an abort register to floppy.v if that trade-off is not
acceptable. `mgmt_bridge_tb` test 16 covers all of it (5121 checks, pass).

### Menu
"A: internal drive" is a single-select toggle in Input Settings, saved with the
other settings. On: any image mounted on A: is unmounted, the engine is enabled,
DETECT runs, the drive is mounted (or left "no disk"); the Drive A line shows
"Internal drive" and is inert while the toggle is on (`HANDLE_MOUNTING` returns
without browsing). Off: unmount, engine disabled (motor off, drive deselected).
At start-up `PREP_START` applies the saved toggle and waits for the detection so
that the BIOS can boot from A:. `FLP_MENU_LINE` (76) and `FLP_MENU_GRP` (21) in
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
  the same). If the drive needs the motor for that, `S_PROBE_*` gets a spin-up.
* **The BIOS timeout** against the first-sector latency (spin-up 0.5 s + recalibrate
  + seek + up to 2 revolutions): the 8088_bios INT 13h timeout is 2 s like IBM's; if
  it bites, shorten `G_CAP_INDEX` handling or keep the motor on longer.
* **Sequential throughput**: the cache should make a track cost one or two
  revolutions; the serial log's `FLP:` lines and the `hdd=`-style counters tell.
* **The dead-drive-after-error behaviour** and that the reset button revives A:.
* **DOS's reaction to the eject/insert re-mount** on a disk change with the same
  geometry.

## First board result, 2026-09-17: DOS reads a real disk
Build of commit 03ba1c6 (WNS +0.177, no violations) on the R6, a 1.44 MB
PC-formatted disk in the internal drive, "A: internal drive" switched on in
Input Settings, FreeDOS booted from the hard-disk image: `DIR A:` listed the
disk and `TYPE A:\HELLO.TXT` printed the file. First bitstream, no changes
needed. The physical-layer spike had run earlier on a MEGA65-formatted disk
(drive audibly seeking and reading); its counters were not read before the
read-path build superseded it.
