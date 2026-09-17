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
2. **Read path behind the existing FDC**: a track buffer (one track = 18 x 512 =
   9 KB per side at HD; one RAMB36 pair holds a side, or 4.5 KB at DD) filled by the
   spike's reader after a seek; the sector source answers the FDC's "read sector
   C/H/R" from the buffer, re-reading the track when the FDC moves on; DSKCHG and
   WPT reported through the existing media-present / write-protect management words.
   Geometry (9 or 18 sectors) from the IDAMs of track 0, or from the boot sector.
3. **Writes**: MFM encoder with write precompensation (mega65-core's
   `mfm_bits_to_gaps.vhdl` has one, tuned on this mechanism), write gate around the
   sector's data field only (from the IDAM's end to the end of the data CRC plus a
   few bytes of gap), sector written back from the buffer.
4. **Formatting**: whole-track writes from the FDC's format command (the FDC already
   collects C/H/R/N per sector into its buffer for the image path).

## The spike, 2026-09-17
`CORE/vhdl/floppy_phy_spike.vhd` (GPL, VHDL, 50 MHz chipset clock), bench
`CORE/rtl/tb/floppy_phy_spike_tb.sv` (`run_floppy_phy_spike_tb.ps1`). **Not yet run
on the board** (no hardware access when this was written); what only the board can
prove is listed at the end.

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

### Status line
`rom_loader` `dbg_a/b/c` -> `m2m-rom.asm` `DBG_STR_6..8`, now `" fidx="`, `" fchr="`,
`" fst="` (the originals `" bist="`, `" req="`, `" hdd="` are kept in comments in the
asm and in the port map in `mega65.vhd`; the spike must not ship in this form):

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
`CORE/rtl/tb/floppy_phy_spike_tb.sv` models the drive on the pins: outputs gated by
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
