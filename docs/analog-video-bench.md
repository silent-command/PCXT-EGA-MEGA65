# Analog (VGA) output: framework pipeline bench

Hardware-free verification of what the MEGA65 VGA connector carries in the
PCXT-EGA port, for the three items of the "VGA" menu group described in
`docs/analog-video.md`. Bench: `CORE/rtl/tb/analog_pipeline_tb.sv`, runner
`CORE/rtl/tb/run_analog_pipeline_tb.ps1` (xsim, Vivado 2026.1, about 5.5
minutes), log `CORE/ooc/analog_pipeline_tb/run.log`. Result of the run on
2026-09-11: `APT RESULT: PASS pass=10 fail=0`.

## 1. What is simulated

The device under test is the real analog path as `CORE/vhdl/mega65.vhd` and
`M2M/vhdl/av_pipeline/av_pipeline.vhd` wire it:

* `CORE/vhdl/analog_video_ctl.vhd` (menu bits -> `qnice_scandoubler`,
  `qnice_retro15kHz`, `qnice_csync`; `video_ce_ovl` = free-running clk/2);
* `xpm_cdc_array_single` with only `WIDTH` set, i.e. the same CDC as
  `av_pipeline.vhd:272-296` (4 destination stages, input register);
* `M2M/vhdl/av_pipeline/analog_pipeline.vhd` with its real submodules:
  `video_mixer.sv` (+ `scandoubler.v`, `hq2x.sv`, `video_freezer.sv`),
  `video_overlay.vhd` (+ `vga_recover_counters.vhd`, `vga_osm.vhd`,
  `ram_init.vhd` with the real font ROM), `csync.sv`, and the falling-edge
  output registers; generics from `globals.vhd` (720x576, 16x16 font).

Not modelled: the VDAC, the analog levels and the OSM content (overlay
disabled, VRAM reads 0; the overlay pipeline itself is in the path). The
VGA pins are read exactly where `framework.vhd:945-946` /
`top_mega65-r6.vhd:587-588` pass them to the connector.

Stimulus: the 200-line CGA/EGA raster as `pcxt_core.sv` emits it in
`clk_57_ps` (57.27 MHz): 912 dots x 262 lines, one dot = 4 clocks
(14.318 MHz), 640x200 active, HS positive 64 dots from dot 720, VS positive
3 lines from line 224 changing at the HS rising edge; HS/VS on the same
clock as the pixel enable, RGB/hblank/vblank one clock later (the
`jtframe_credits.v:439-463` skew). Every active pixel encodes its position
(R = x[7:0], G = y[7:0], B = {x[9:8], 101010}) so the bench checks the output
pixel by pixel: order, count per line, hold time per pixel, line repetition,
colour, and that nothing else appears.

Two xsim-only adaptations, neither touching M2M sources:

* `CORE/rtl/tb/analog_pipeline_wrap.vhd` ties `video_osm_cfg_scaling_i`
  (a `natural range 0 to 8`) to 0 because xelab cannot bind that subtype from
  a Verilog parent.
* `analog_pipeline.vhd:141-143` pass `R => unsigned(video_red_i)` (a type
  conversion inside the port map) to the Verilog `video_mixer`; xelab accepts
  it and Vivado synthesis binds it correctly (`CORE/build-r6.log:680`, Synth
  8-3491, no width warnings, Hq2x BRAMs present), but xsim aborts at time 0
  ("Array sizes do not match, left array has 0 elements, right array has 8
  elements"; reproduced with a 60-line probe, an `unsigned` signal or an
  slv component port both work). The runner therefore compiles a copy in
  which the three conversions are moved into signal assignments, verifies the
  transform and uses nothing else from the copy.

## 2. Results

Clock = 17.461 ns. Line = 3648 clocks, frame = 955776 clocks (59.92 Hz) at
the input. "phase" is the position of the core's pixel enable modulo 4
clocks against the free-running overlay enable; every case was run in at
least two phases (A in all four).

### A. "VGA: 31 kHz" (scandoubler on) - PASS, phases 0..3

```
HS period 1824 clk = 31.40 kHz, positive, pulse 128 clk (2.23 us), low 1696 clk
VS period 955776 clk = 59.92 Hz, positive, pulse 10944 clk (6 output lines)
524 lines per frame, 400 active lines, 640 active pixels per line,
each output pixel held 2 clocks (34.9 ns), each input line output twice,
x = 0..639 in order, y = 0..199 in order, colours exact, 0 pixel errors
HS rise -> first pixel 390 clk (6.8 us incl. pulse), last pixel -> HS rise 154 clk (2.7 us)
```

The overlay enable parity is constant within every run (phases 0/2: sampled
low at the pixel enable, phases 1/3: high) and the picture is intact in
both, so the suspicion that `vga_recover_counters.vhd:46-54` re-sampling the
2-clock doubled pixels on the free-running clk/2 enable could drop every
other column is refuted: no column is dropped or duplicated in any phase.

### B. "VGA: 15 kHz" (scandoubler off) - PASS, phases 3 and 0

```
HS period 3648 clk = 15.70 kHz, positive, pulse 256 clk (4.47 us), low 3392 clk
VS period 955776 clk = 59.92 Hz, positive, pulse 10944 clk (3 lines)
262 lines per frame, 200 active lines, 640 active pixels per line,
each pixel held 4 clocks (69.8 ns; sampled twice by the 2x enable, no artefact),
0 pixel errors; HS rise -> first pixel 772 clk, last pixel -> HS rise 316 clk
```

### C. "VGA: 15 kHz + CSync" - PASS, phases 0 and 1

```
HS pin = active-low composite sync: period 3648 clk, low 256 clk, high 3392 clk
VS pin held at 1 for the whole run
picture as in B: 640 x 200, 0 pixel errors
Run lengths on the HS pin from line 222 to 230 (level:clocks):
  1:2893 0:256 1:3392 0:256 1:3392 | 0:3393 1:255 0:3393 1:255 0:3393 1:255 | 0:256 1:3392 0:256 1:3392 0:256
```

During the three VS lines the level is inverted (sync level for 3393
clocks) with 255-clock serration pulses whose falling edges stay on the
horizontal grid, i.e. the `csync.sv` "HS shifted left by one HS period
during VS" scheme; outside VS it is the plain HS. This is MiSTer's
`sys_top` generator behaving as designed.

### D. Runtime switching (menu bit changes mid-frame, mid-line) - PASS

```
31 kHz -> 15 kHz: HS settled 1690 clk (29.5 us, 0.46 of a 15 kHz line) after the
                  QNICE bit changed, 1 off-nominal HS pulse, first full frame clean
15 kHz -> 31 kHz: HS settled 255 clk (4.5 us) after the bit changed, 1 off-nominal
                  HS pulse, first full frame clean (640 x 400, 0 errors)
```

The CDC (`av_pipeline.vhd:272-296`) plus the combinational mux in
`video_mixer.sv:174-210` cost one broken HS pulse and part of one line; the
doubler keeps measuring while deselected (`scandoubler.v:64-91`) so it is
correct the moment it is selected. The rest is the monitor's re-lock time.

## 3. Conclusion

Within what can be modelled, the framework's analog output is correct for
this port's 200-line raster in all three settings: the scandoubler's pixel
size measurement (4 clocks, `scandoubler.v:74-78`), the doubled output
cadence (2 clocks, `:136`), the 2x overlay re-sampling, the DE window, the
sync regeneration, the csync block and the control CDC all produce the
intended signal. No RTL defect was found in `analog_pipeline.vhd`,
`video_mixer.sv`, `scandoubler.v`, `vga_recover_counters.vhd`, `csync.sv`,
`analog_video_ctl.vhd` or the `av_pipeline.vhd` wiring, and no fix to them
is proposed.

The black picture on the VGA-to-HDMI adapter box is therefore not explained
by the digital pipeline. What remains, in order of likelihood:

1. **Sync polarity.** The connector carries positive HS and positive VS in
   the 31 kHz setting (`analog_pipeline.vhd:222-239` registers the syncs
   without inversion). In the original IBM VGA monitor-ID scheme H+/V+ is
   the reserved combination (H+/V- = 400 lines, H-/V+ = 350, H-/V- = 480),
   and MiSTer's own `sys_top.v:1521-1522` emits `~vga_hs` / `~vga_vs`.
   Analog monitors normally lock regardless, but an adapter box that
   identifies the mode from polarity and frequency may refuse a 31.4 kHz
   / 59.9 Hz / 524-line H+/V+ timing. A real VGA monitor test settles
   this. If polarity turns out to be the reason, the change belongs in the
   framework, after the csync mux: `analog_pipeline.vhd:231-236`,
   `vga_hs_o <= not vga_hs_ps` / `vga_vs_o <= not vga_vs_ps` in the
   non-csync branch (the csync branch is already active-low), ideally
   behind a new control; nothing downstream of that register needs the
   positive polarity, and `csync.sv` / `scandoubler.v` upstream of it keep
   their positive inputs.
2. **HS pulse width.** 2.23 us at 31.4 kHz (half the core's 64 dots) against
   3.8 us in the VESA 640x480 timing. Monitors accept this, some adapters
   are stricter. Widening it would mean the core emitting a longer HS pulse
   in the 200-line modes (`UM6845R.v` hsync width path) - not recommended
   without a hardware result first.
3. **The VDAC path**, which the bench cannot model: `vdac_clk_o` is
   `clk_57_ps` itself while the data changes on its falling edge
   (`analog_pipeline.vhd:224,250`), `vdac_blank_n = 1`, `vdac_sync_n = 0`,
   `vdac_psave_n = 1` (`top_mega65-r6.vhd:523`). This is the framework's
   standard configuration used by other cores, so it is unlikely to be the
   port's problem, but only hardware can confirm it.

Reproduce: `powershell -File CORE/rtl/tb/run_analog_pipeline_tb.ps1`.

## 4. The 350-line raster and the analog line doubler

Sibling bench: `CORE/rtl/tb/analog_pipeline_350_tb.sv`, runner
`CORE/rtl/tb/run_analog_pipeline_350_tb.ps1`, log
`CORE/ooc/analog_pipeline_350_tb/run.log`. Same DUT as section 1, with
`analog_line_doubler.vhd` built into `analog_pipeline` (`gen_analog_dbl`,
`G_ANALOG_LINE_DOUBLER = true`) and `analog_video_ctl.vhd` given the core's
`video_mode350` hint.

Stimulus: the EGA 640x350 raster, 744 dots x 364 lines, HS positive 64 dots
from dot 664, VS positive 3 lines from line 355. The dot enable is not a
divider but the real mechanism: an NCO of 59609/105000 stepped in the
28.636 MHz domain and restarted once per CRTC line (`ega_dot_clock.v:11-19,
80-86`), crossed into `clk_57_ps` as a toggle plus one synchroniser and an XOR
(`pcxt_core.sv:1762-1771`). Measured by the bench itself: 744 dots per line,
2620 clocks per line = 21.860 kHz, 953680 clocks per frame = 60.05 Hz,
CE_PIXEL gaps of **2 or 4 clocks** only (194375 twos against 618071 fours,
mean 3.5215 = 16.2635 MHz). Active pixels encode x and y over the full
640x350 grid (`R = x[7:0]`, `G = y[7:0]`, `B = {x[9:8], y[9:8], 4'b1010}`).

| Case | Setting | Result |
|---|---|---|
| A `A_before_31k_framework_sd` | 31 kHz menu, `video_mode350` hidden from `analog_video_ctl` - i.e. the behaviour before this change, framework scandoubler on | sync correct (43.72 kHz, 728 lines/frame, 700 active lines, 60.05 Hz) but **488 of 640 columns**, 214200 column faults over two frames. Evidence only, not a pass/fail criterion. |
| B `B_before_15k_native` | 15 kHz menu, nothing doubled | PASS. 21.86 kHz, 364 lines/frame, 640x350 active, 0 column faults - today's undoubled analog output for these modes is pixel-exact. |
| C `C_after_31k_doubled` | 31 kHz menu with the hint, `analog_line_doubler` on | PASS in all three sampling phases. 43.72 kHz (HS period 1310 clocks, exactly half the input line), HS positive 113 clocks, 728 lines/frame, **700 active lines, 640 columns per line, 0 column faults, 0 pixel errors**, pixel hold 1..2 clocks (the 32.5 MHz doubled rate), VS period 953680 clocks - the frame rate is bit-identical to the input. |
| D `D_after_15k_native` | 15 kHz menu with the hint | PASS, identical to B: the 15 kHz settings are unchanged. |
| E `E_enter_350` | the hint arrives mid-frame, mid-line | PASS. The HS pin settles to 43.72 kHz in 1294 clocks (22.6 us, half a source line) and the next full frame is already pixel-exact: 0 errors, 640x700. |
| E `E_leave_350` | the hint goes away mid-frame, mid-line | PASS on the settle time (1437 clocks, 25.1 us). Checked non-strictly, because the destination is case A - the framework scandoubler back on a 350-line raster - which is corrupt by construction, and the bench duly measures 488 columns there. |

The 200-line bench of section 1 was re-run with `analog_line_doubler` in the
path (in bypass, since that raster is never doubled) and produced
`APT RESULT: PASS pass=10 fail=0` with every measured number identical to the
2026-09-11 run: the bypass is transparent and adds no latency. The 350-line
bench itself ends `A350 RESULT: PASS pass=7 fail=0`.

### What this bench found

The first version of `analog_line_doubler` was placed in `av_pipeline.vhd`,
*in front of* `analog_pipeline`, so that the doubled stream went through
`video_mixer`. Case C then measured 486 of 640 columns. The cause is
`video_mixer.sv:185-194`: when `ce_pix` is a real clock enable it sets
`CE_PIXEL` to `~old_ce & ce_pix`, the *rising edge* of the enable, so two
enables on adjacent video clocks produce one pixel. A doubled 16.257 MHz dot
clock is 32.5 MHz in a 57.27 MHz domain, i.e. gaps of 1 or 2 clocks with about
24 % ones - exactly the 24 % of columns that went missing. The doubler was
moved beside `video_mixer` instead, with a mux in front of `i_video_overlay`;
everything from there on samples on a level (`vga_recover_counters.vhd:48`) or
on every clock. **A pixel enable faster than `CLK_VIDEO / 2` cannot pass
through this framework's `video_mixer`**, whatever it is generated by.

Reproduce: `powershell -File CORE/rtl/tb/run_analog_pipeline_350_tb.ps1`
(xsim, about 10 minutes).
