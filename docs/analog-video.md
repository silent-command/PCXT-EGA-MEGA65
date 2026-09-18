# Analog video (the VGA connector)

What the MiSTer2MEGA65 framework does with the core's video on the analog
side, which option combinations give a monitor or a TV a signal it can lock
to for each raster this core produces, and a minimal wiring proposal for a
"VGA" group in the options menu. Nothing in this document has been tried on
hardware; section 6 lists what only hardware can settle.

Files referred to by short name: `analog_pipeline.vhd`, `av_pipeline.vhd`,
`video_overlay.vhd`, `vga_recover_counters.vhd`, `digital_pipeline.vhd` are in
`M2M/vhdl/av_pipeline/`; `video_mixer.sv`, `scandoubler.v`, `csync.sv`,
`hq2x.sv` in `M2M/vhdl/controllers/MiSTer/`; `PCXT-EGA.sv`, `sys_top.v` and
`rtl/video/*` in `CORE/PCXT-EGA_MiSTer/`; `pcxt_core.sv` in `CORE/rtl/`.

## 1. What reaches the VGA connector today

The core's own raster, re-timed by nothing. The framework has two consumers
of the core video (`video_*_i`, all in the core's `video_clk`, which is
`clk_57_ps`, `mega65.vhd:376`):

* the analog pipeline, `av_pipeline.vhd:391-443`, instantiates
  `analog_pipeline` straight from `video_red_i/.../video_vblank_i`;
* the digital (HDMI) pipeline gets the same inputs through `crop`
  (`av_pipeline.vhd:505-527`) and then ascal (`av_pipeline.vhd:528-598`,
  `digital_pipeline.vhd:293-424`).

Inside `analog_pipeline` the chain is `video_mixer` (`analog_pipeline.vhd:
134-157`) -> blank outside DE (`:161-172`) -> `video_overlay` (OSM,
`:174-206`) -> `csync` (`:208-214`) -> the falling-edge phase-shift registers
(`:222-239`) -> `vga_*_o` and the VDAC pins (`vdac_clk_o <= video_clk_i`,
`:250`), which `top_mega65-r6.vhd:584-591` wires to the connector. No scaler,
no frame buffer, no clock change: the VDAC is clocked with `clk_57_ps` and the
line and frame rate on the connector are whatever the core emits. So with the
current settings (`mega65.vhd:519,530,531` all `'0'`) the connector carries
15.7 kHz in the CGA/EGA 200-line modes, 21.8 kHz in the 350-line modes and
31.5 kHz in mode 13h.

### `qnice_scandoubler_o`

`av_pipeline.vhd:282/291` crosses it into the video clock
(`xpm_cdc_array_single`, 2 stages) and `analog_pipeline.vhd:139` feeds it to
`video_mixer.scandoubler`. `video_mixer.sv:150-172` always runs the MiSTer
`scandoubler` (with `hq2x = '0'`, `analog_pipeline.vhd:140`, and the default
`LINE_LENGTH = 768`, `video_mixer.sv:21`) and the flag only selects between
the doubled and the raw stream: RGB `:174-176`, `CE_PIXEL :194`, DE/HS/VS
`:207-210`. So "scandoubler on" is line doubling of the core video for the
analog output only.

Clocks: the doubler runs on `CLK_VIDEO = video_clk_i` (`analog_pipeline.vhd:
136`), i.e. `clk_57_ps`. It is *not* fed by a separate x2 clock; the
`clk_video_x2_i` / `clk_video_out_ps_i` ports of `main.vhd:33-34` are the
core's own 57.27 MHz pipeline and its +90 degree copy (`clk.vhd:9-10`), and
the framework never sees the 28.636 MHz base. The doubler derives everything
from the pixel enable: `scandoubler.v:64-91` measures the number of clocks
between `ce_pix` pulses in the visible area (`pixsz`, and `pixsz2 = pixsz/2`,
`pixsz4 = pixsz/4`), samples the input every `pixsz` clocks (`:85-89`),
replays each line twice from the Hq2x line buffer at `pixsz2` clocks per
pixel (`:126-144`), and regenerates HS at half the measured period
(`:163-204`, all positions are `hcnt[31:1]`). The header of `video_mixer.sv:
27` states the precondition: `CLK_VIDEO` "should be multiple by (ce_pix*4)".
Which of this core's rasters satisfy that is in section 2.

Runtime switching: the mux is combinational on a synchronised level, the
doubler measures continuously whether selected or not, and its measurements
are refreshed every line/frame. Switching it (by the menu or by the mode-13h
gate below) therefore costs at most one broken frame plus the monitor's own
re-lock time. Nothing in the framework resets or re-initialises on the
transition.

### `qnice_retro15kHz_o`

Changes no timing at all. The only consumer is the overlay:
`av_pipeline.vhd:281/290` -> `analog_pipeline.vhd:194` (`vga_cfg_r15kHz_i`)
-> `video_overlay.vhd:104-105`, which doubles the recovered row counter
(`vga_row <= vga_pix_y * 2`) so that the 16-line OSM font occupies 8 raster
lines and the menu fits a 200/240-line raster. It is not read by the QNICE
firmware (no reference in `M2M/rom` or `M2M/QNICE`) and it does not touch
HDMI. The comment in `analog_pipeline.vhd:46-48` ("scandoubler off does not
automatically mean retro 15 kHz on") says the same thing: it describes the
input raster, it does not create one.

### `qnice_csync_o`

`analog_pipeline.vhd:208-214` generates `csync` from the overlay's HS/VS
(`csync.sv`, MiSTer's `sys_top` generator: HS xor VS with HS shifted during
VS). `:231-236`: with csync the HS pin carries `not csync` (active-low
composite sync) and the VS pin is held `'1'`, the MiSTer VGA-to-SCART adaptor
pinout. `csync.sv` measures the HS pulse as the time the input is high
(`:25-33`), i.e. it expects positive HS/VS pulses. This core delivers
positive pulses in every raster: EGA/CGA `ega_top.v:1314-1323`
(`hsync = ... ega_hsync_out`, `vsync = ... ega_vsync` where
`ega_vsync = ~ega_vsync_out_l`, `:1069`) with the CRTC emitting positive
pulses (`UM6845R.v:719-722, 862-865`); mode 13h `vga_mode13_timing.v:170-175`
(`hsync/vsync = 1` inside the sync window). The EGA Miscellaneous Output
polarity bits are not applied to the outputs (bit 7 is used as
`palette_64_mode`, `ega_top.v:849`, bit 6 is unused). Note the framework does
not invert the sync pins (MiSTer does, `sys_top.v:1521-1522`); a VGA monitor
gets positive HS/VS, which VESA monitors treat only as a mode hint.

### The overlay sampling enable (`video_ce_ovl`)

`analog_pipeline.vhd:26` declares `video_ce_ovl_i` as "2x the speed of
video_ce_i" and feeds it to the overlay (`:184`). `vga_recover_counters.vhd:
46-54` registers RGB, HS, VS and DE *only* when that enable is high, so the
picture on the connector is re-sampled at the overlay enable rate. `main.vhd:
675-677` currently ties `video_ce_ovl_o <= video_ce_o` (one pulse per core
pixel, every 4th clock in the 14.318 MHz modes). That is fine while the
scandoubler is off. With it on, the doubled stream changes every 2 clocks
(`scandoubler.v:136`, `ce_x2o` at `pixsz2 = 2`) and a 4-clock enable would
drop every second doubled pixel: 320 effective columns. Any use of the
scandoubler therefore needs a faster overlay enable; section 4 makes it a
free-running divide-by-two.

The enable also sets the OSM cell size on the analog output: the firmware
lays the OSM out as `VGA_DX/FONT_DX` x `VGA_DY/FONT_DY` = 45 x 36 cells
(`globals.vhd:59-69`, `screen.asm:13-27` uses the VGA settings for both
outputs) and places the 23-cell options menu at cell 22 (`screen.asm:65-67`,
`config.vhd OPTM_DX = 23`). With a 16-dot cell that is dot 352..720 of a
640-dot raster: cut off on the right. With the 2x enable the cell is 8 dots
wide (dot 176..360) and the menu is on screen.

## 2. The core's rasters and what each option does to them

From `docs/emu-signal-map.md` section 4.3, `ega_dot_clock.v:11-19`,
`vga_mode13_timing.v:1-24` and `ega_top.v:1043-1050`:

| Raster | Line / frame | Dot clock, clocks per pixel in `clk_57_ps` | Scandoubled | On a 15 kHz TV |
|---|---|---|---|---|
| CGA/EGA 200-line modes, boot splash, BIOS hold | 15.7 kHz / 60 Hz | 14.318 MHz, exactly 4 | 31.4 kHz, in spec | yes, native |
| Mode 13h+ TV profile (`status[10]` = 1) | 15.7 kHz / 60 Hz, CGA geometry (`vga_mode13_timing.v:7-18`) | 14.318 MHz equivalent, exactly 4 | 31.4 kHz, in spec | yes, native |
| Mode 13h+ native profile (`status[10]` = 0) | 31.5 kHz / 70 Hz (25.2 MHz clock; 360-wide: 31.4 kHz on 28.636) | 12.6 MHz, ~4.5 clocks and asynchronous (or 4) | 63 kHz: must not be doubled | no |
| EGA 350-line modes, MDA 720x350 (`ega_hifreq_mode`) | 18.4-21.9 kHz / 60 Hz | 16.257 MHz from an NCO, alternating 2 and 4 clocks (measured) | 43.7 kHz by `analog_line_doubler.vhd`, in spec; the framework doubler corrupts it | no (as upstream without the 480i option) |

Mode 13h: the doubler must follow `video_mode13_o` (`pcxt_core.sv:2117`,
`vga_private_active` = mode 13h, planar-16 and the unchained profiles,
`ega_top.v:301, 1291`). The flag comes from the chipset in `clk_card_video`,
the muxed 28.636/25.2 MHz clock (`pcxt_core.sv:574-581, 1251-1264`), and
changes once per mode set (`vga_mode13_ctrl.v:16-23`), not aligned to vblank;
the clock mux switches at the same moment, so the raster is discontinuous
there anyway and the doubler switching adds nothing visible.

350-line modes: 2 x 21.86 kHz = 43.72 kHz is inside the range of nearly every
multisync input, and since this change `CORE/vhdl/analog_line_doubler.vhd`
produces it. Neither doubler the port already had can:

* The **framework** doubler measures ONE integer pixel size - the number of
  `clk_57_ps` clocks between two `ce_pix` pulses in the visible area
  (`scandoubler.v:64-91`) - and then resamples the input at that fixed spacing
  (`:85-89`) and replays at `pixsz2` (`:126-144`). The 16.257 MHz dot enable is
  an NCO in the 28.636 MHz domain (`ega_dot_clock.v:11-19`, 59609/105000,
  restarted once per CRTC line) whose *toggle* is crossed into `clk_57_ps` with
  one synchroniser and an XOR (`pcxt_core.sv:1762-1771`), so the enables land
  on alternate video clocks only and are **2 or 4 clocks apart** - measured
  194375 gaps of 2 against 618071 of 4 over the bench run, mean 3.5215, i.e.
  16.2635 MHz. (An earlier draft of this document said 3 or 4; the toggle
  crossing makes odd gaps impossible.) With a fixed `pixsz` the 24 % of short
  dots are lost: `analog_pipeline_350_tb` case A measures the framework
  doubler producing correct sync (43.72 kHz, 728 lines/frame, 700 active
  lines) but only **488 of the 640 columns**, 214200 column faults over two
  frames. `video_mixer.sv:27` states the precondition that is being violated.
* The **core's own** generic doubler `rtl/video/video_scandoubler.v` is forced
  off for these modes (`ega_top.v:1043-1050`) because 2 x 16.257 MHz cannot be
  made in the 28.636 MHz domain it runs in. It also regenerates HS from
  hard-coded pulse widths (`HS_START_80`/`HS_WIDTH_80` = 748/110 source dots,
  `:96-99`) chosen for a 912-dot CGA line, not from the measured input.

`analog_line_doubler.vhd` never looks at a dot clock. Per source line it
measures the number of pixel enables and the number of video clocks between
two HS rising edges, stores the line - colour *and* hs/vs/hblank/vblank, one
entry per source pixel - in a ping-pong line buffer, and replays it twice
during the following source line, each replay spread over half the measured
line length by a Bresenham rate divider (add `line_pix` per clock modulo
`line_clk/2`). That divider emits exactly `line_pix` pulses in exactly
`line_clk/2` clocks, so no column is skipped or duplicated whatever the dot
clock is, and because sync, blanking and colour come out of the same buffer
entry the regenerated HS keeps the input geometry exactly, at half the
duration. Measured (`analog_pipeline_350_tb` case C, all three sampling
phases): 43.72 kHz, 728 lines/frame, 700 active lines, 640 columns per line,
the frame period bit-identical to the input, zero column faults.

**It has to sit beside `video_mixer`, not in front of it.** With a real clock
enable on `ce_pix`, `video_mixer` reduces `CE_PIXEL` to the *rising edge* of
`ce_pix` (`video_mixer.sv:185-194`, `fs_osc ? (~old_ce & ce_pix) : ce_pix`), so
two enables on adjacent video clocks become one pixel. A doubled 16.257 MHz
enable is 32.5 MHz in a 57.27 MHz domain, i.e. gaps of 1 or 2 clocks with
about 24 % ones - the first version of this module was placed in front of the
mixer and the bench measured 486 of 640 columns surviving. Everything
downstream of the mux in `analog_pipeline.vhd` samples on a *level*
(`vga_recover_counters.vhd:48`) or on every clock, so the doubled stream passes
through intact. That also means the overlay enable has to follow: while the
doubler owns the stream, `vga_ce_i` is its pixel enable instead of the
free-running `clk/2` of `analog_video_ctl.vhd`, which is slower than 32.5 MHz
and would drop columns by itself.

Cost, out-of-context synthesis of `analog_line_doubler` on the XC7A200T:
2 RAMB36E1 (a 2048 x 28 bit ping-pong buffer: 24 bits of colour plus
hs/vs/hblank/vblank, 1024 dots per line), 141 LUTs, 79 registers, no warnings.
The buffers are only built when `G_ANALOG_LINE_DOUBLER` is true.

Not doubled, deliberately: the 15 kHz menu items. 43.6 kHz is no more use to a
15.7 kHz set than 21.8 kHz is, and those settings are meant to stay exactly as
they were (`analog_pipeline_350_tb` case D checks that the 15 kHz output is
still the pixel-exact native 21.86 kHz raster).

### Validity matrix

"VGA" = a 31 kHz-and-up monitor; "TV" = 15 kHz CRT/SCART. `sd` =
`qnice_scandoubler`, `r15` = `qnice_retro15kHz`, `cs` = `qnice_csync`,
`tv13` = `osm_vga13_tv_i` (`pcxt_core.sv:145, 454`, currently `'0'` at
`main.vhd:483`).

| Raster | VGA: valid with | TV: valid with |
|---|---|---|
| 200-line modes, splash | `sd=1` (31.4 kHz) | `sd=0`, `r15=1`, `cs` per adaptor |
| Mode 13h native | `sd=0` (31.5 kHz; `sd=1` gives 63 kHz) | never; select `tv13=1` instead |
| Mode 13h TV profile | `sd=1` (31.4 kHz) | `sd=0`, `r15=1`, `cs` per adaptor |
| 350-line modes | `sd=0` + `analog_line_doubler` on (43.7 kHz, 700 lines, pixel-exact); `sd=1` is corrupt (488 of 640 columns) | none (needs a frame/line-rate converter) |

So a VGA monitor is served by `sd = NOT video_mode13` with `tv13 = 0`
(mode 13h at its real 70 Hz), and a TV by `sd = 0`, `r15 = 1`, `tv13 = 1`
plus `cs` as the cable requires, with the 350-line modes as the one caveat in
both cases.

## 3. HDMI is unaffected

`digital_pipeline.vhd` has no scandoubler, retro15kHz or csync port (its
inputs are `video_*`, `hdmi_*`, `qnice_ascal_*`, `hr_*`), and the three
signals leave `av_pipeline` only through `i_qnice2video` into
`i_analog_pipeline` (`av_pipeline.vhd:271-296, 417-424`); the HDMI CDC
`i_qnice2hdmi` (`:486-502`) carries the OSM geometry, zoom/crop and scaling
only. ascal takes the core's raster directly (`digital_pipeline.vhd:322-327`)
and re-times it to the selected HDMI mode, exactly as now. `osm_vga13_tv_i`
is the one proposed signal that *does* reach HDMI, because it changes the
core's raster itself (70 Hz -> 60 Hz in mode 13h); see the caveat in
section 5.

The framework's scanline emulation is HDMI-only: `mega65.vhd:543` maps the
"HDMI: CRT emulation" item to `qnice_ascal_polyphase_o`. The analog path has
no scanline control (`scandoubler.v` in this framework version has no
scanline input, `analog_pipeline` has none), so a "Scanlines" item for the
VGA group is not possible without framework changes. The core's `VGA_SL`
(`video_scanlines_o`, `osm_scandoubler_fx_i`) only ever fed MiSTer's
`sys_top` (`docs/emu-signal-map.md` 1.2, bits 2:1) and stays unused.

## 4. Upstream's 15 kHz path and what the port kept

`CORE/PCXT-EGA_MiSTer/README.md:40-47` advertises direct 15 kHz output, the
350-line modes convertible to 480i/240p, and a Native/TV raster for mode 13h.
In `PCXT-EGA.sv`:

* `"P2OA,VGA 13h+ CRT,Native 70Hz,TV 60Hz;"` (`:186`) -> `status[10]` ->
  `vga_mode13_native_osd = ~status[10]` (`:226`) -> `CHIPSET.vga_mode13_native`
  (`:1211`) -> `vga_mode13_timing.native_70hz`; the same bit selects the
  25.2 MHz clock (`:519-525`). The port keeps all of it: `osm_vga13_tv_i`
  (`pcxt_core.sv:145`, `status[10]` at `:454`, clock mux `:572-581`), tied
  `'0'` in `main.vhd:483`.
* `"P2o23,350-line CRT,Native,480i 15 kHz,240p 15 kHz;"` (`:187`) ->
  `status[35:34]` (`:1927-1929`) -> `fb_enable = mode350 & crt480i_osd`
  (`:1944`): `ega_fb_capture` writes each frame to DDRAM, `ega_fb_readout`
  reads it back on a 15.734 kHz 720x480i (or 240p, dropping a third of the
  lines) raster at 14.318 MHz, `ega_ddr_arbiter` shares the HPS DDR3 port,
  `video_source_switch` swaps rasters in the destination's vblank and
  `VGA_F1` flags the field (`:1907-2089`). The port dropped the whole block
  (`pcxt_core.sv:31-36`, muxes collapsed at `:1882-1893`, `status[35:34] = 0`
  at `:468`; `docs/emu-signal-map.md` row 35 "DROP: ascal handles 21.8 kHz").
  Bringing it back means a frame store in HyperRAM behind the existing
  Avalon arbiter (`mem_backend`, shared with EMS/UMB and ascal's own buffer)
  and a rewrite of the capture/readout memory interface; not minimal.
* CSync, YPbPr, `forced_scandoubler` and the VGA scaler are MiSTer.ini
  settings applied in `sys_top.v:300-309, 1425, 1521-1522`, not core
  options; the M2M equivalents are the three `qnice_*` controls above.
* The chipset's own line doubler (`rtl/video/video_scandoubler.v`) is forced
  off (`ega_top.v:1043-1050`) and `video_scandoubler_en` is dead upstream too
  (`docs/emu-signal-map.md` 1.2, bits 2:1).

Hence for a 15 kHz set the port can offer, without new video RTL: every
200-line mode natively, mode 13h through its TV profile (`osm_vga13_tv_i`),
optionally composite sync; and not the 350-line modes.

## 5. Proposal

### Menu

A single-select group in the Display submenu (`config.vhd`), inserted after
line 60 ("Black and white"):

```
   " Black and white\n"     &    -- 60
   "\n"                     &    -- 61  (new)
   " VGA: 31 kHz\n"         &    -- 62  (new) default
   " VGA: 15 kHz\n"         &    -- 63  (new)
   " VGA: 15 kHz + CSync\n" &    -- 64  (new)
   "\n"                     &    -- 65  (was 61)
   " Back to main menu\n"   &    -- 66  (was 62)
```

with `OPTM_G_VGA : integer := 24`, groups `OPTM_G_LINE`,
`OPTM_G_VGA + OPTM_G_STDSEL`, `OPTM_G_VGA`, `OPTM_G_VGA`, and everything
from the old line 61 onwards shifted by +4: Input submenu 67..77, line 78,
`C_MENU_CRT_EMULATION` 79, `C_MENU_HDMI_ZOOM` 80, `C_MENU_IMPROVE_AUDIO` 81,
Help 83, Close 85, `OPTM_SIZE` 86 (the Display submenu grows to 17 lines,
under `OPTM_DY` 19). `main.vhd` decoders move with them (joystick 66/67 ->
70/71, swap 68 -> 72, write-protect 70/71 -> 74/75), `docs/options-menu.md`
gets the new rows, and `sdcard/m2m/m2mcfg` must be regenerated at 86 bytes
(`M2M/tools/make_config.sh`, see `docs/options-menu.md`). No "Scanlines"
item (section 3).

Default "VGA: 31 kHz": a modern LCD gets 31.4 kHz in every 200-line mode and
31.5 kHz/70 Hz in mode 13h; only the 350-line modes fall outside its range.

### Signal values

| Menu item | `qnice_scandoubler_o` | `qnice_retro15kHz_o` | `qnice_csync_o` | `osm_vga13_tv_i` |
|---|---|---|---|---|
| VGA: 31 kHz | `NOT video_mode13 AND NOT video_mode350` | 0 | 0 | 0 |
| VGA: 15 kHz | 0 | 1 | 0 | 1 |
| VGA: 15 kHz + CSync | 0 | 1 | 1 | 1 |

plus `video_analog_dbl = video_mode350 AND NOT vga_15khz` (the analog line
doubler of section 2, video clock domain), and in every setting
`video_ce_ovl = clk_57_ps / 2` (free running; `analog_pipeline.vhd` overrides
it with the doubler's own pixel enable while the doubler owns the stream).

### Glue: `CORE/vhdl/analog_video_ctl.vhd`

The mode-13h flag has to be synchronised into the QNICE domain (the
framework wants the three controls in `qnice_clk`, `av_pipeline.vhd:277`,
and the flag lives in the muxed core video clock), so the gating is a small
module rather than a line in `mega65.vhd`. `analog_video_ctl.vhd` (added in
this change, bench `CORE/rtl/tb/analog_video_ctl_tb.vhd`, runner
`run_analog_video_ctl_tb.ps1`, xsim, "AVC RESULT: PASS checks=653"):

```vhdl
entity analog_video_ctl is
   port (
      qnice_clk_i         : in  std_logic;
      qnice_vga_15khz_i   : in  std_logic;   -- either 15 kHz item
      qnice_vga_csync_i   : in  std_logic;   -- the "+ CSync" item
      qnice_scandoubler_o : out std_logic;
      qnice_retro15khz_o  : out std_logic;
      qnice_csync_o       : out std_logic;
      video_clk_i         : in  std_logic;   -- clk_57_ps
      video_mode13_i      : in  std_logic;   -- pcxt_core video_mode13_o, asynchronous
      video_mode350_i     : in  std_logic;   -- pcxt_core video_mode350_o, asynchronous
      video_analog_dbl_o  : out std_logic;   -- -> av_pipeline video_analog_dbl_i
      video_ce_ovl_o      : out std_logic    -- clk_57_ps / 2
   );
end entity;
```

Body, for reference (the file has the comments):

```vhdl
   p_qnice : process (qnice_clk_i)
   begin
      if rising_edge(qnice_clk_i) then
         qnice_mode13_meta <= video_mode13_i;             -- ASYNC_REG pair
         qnice_mode13      <= qnice_mode13_meta;
         qnice_scandoubler <= (not qnice_vga_15khz_i) and (not qnice_mode13);
         qnice_retro15khz  <= qnice_vga_15khz_i;
         qnice_csync       <= qnice_vga_15khz_i and qnice_vga_csync_i;
      end if;
   end process;

   p_video : process (video_clk_i)
   begin
      if rising_edge(video_clk_i) then
         video_ce_2x <= not video_ce_2x;
      end if;
   end process;
   video_ce_ovl_o <= video_ce_2x;
```

Why a free-running 2x enable is safe with the doubler: the doubled output
pixel cadence is `pixsz2 = 2` clocks restarted at the regenerated HS edge
(`scandoubler.v:138-143`), whose position is `hcnt[31:1]` of a value
measured at a pixel-enable instant, and in the 14.318 MHz modes the core's
enable keeps a fixed parity in `clk_57_ps` (one toggle per 4 clocks,
`pcxt_core.sv:1758-1764`). The parity between the overlay enable and the
doubled pixels is therefore constant (either aligned or one clock late, a
constant one-output-pixel shift), not a per-line jitter. In the undoubled
modes the mixer holds a pixel for >= 4 clocks and sampling it twice changes
nothing. An alternative that keeps the 16-dot OSM cell in the 15 kHz modes
would be `ce_ovl <= ce_2x when scandoubled else video_ce`, which needs the
effective scandoubler flag in the video domain (another synchroniser); it
was not chosen because the constant 2x also fixes the options-menu width on
the 640-dot raster (section 1).

### Integration (the files I did not edit)

`main.vhd`

* new port `video_mode13_o : out std_logic` driven by the core's
  `video_mode13_o` (currently `open`, `main.vhd:439`);
* `osm_vga13_tv_i => osm_control_i(63) or osm_control_i(64)` (currently
  `'0'`, `:483`); `osm_control_i` is quasi-static in `clk_main` and the core
  already takes its other status bits the same way (`:461-490`);
* `video_ce_ovl_o <= video_ce_o` (`:675-677`) goes away, the port is driven
  from `mega65.vhd` instead (or keep it and leave it unconnected there).

`mega65.vhd`

```vhdl
constant C_MENU_VGA_15KHZ    : natural := 63;
constant C_MENU_VGA_15KHZ_CS : natural := 64;
...
   i_analog_video_ctl : entity work.analog_video_ctl
      port map (
         qnice_clk_i         => qnice_clk_i,
         qnice_vga_15khz_i   => qnice_osm_control_i(C_MENU_VGA_15KHZ) or
                                qnice_osm_control_i(C_MENU_VGA_15KHZ_CS),
         qnice_vga_csync_i   => qnice_osm_control_i(C_MENU_VGA_15KHZ_CS),
         qnice_scandoubler_o => qnice_scandoubler_o,      -- replaces line 519
         qnice_retro15khz_o  => qnice_retro15kHz_o,       -- replaces line 530
         qnice_csync_o       => qnice_csync_o,            -- replaces line 531
         video_clk_i         => clk_57_ps,
         video_mode13_i      => main_video_mode13,        -- new main.vhd port
         video_ce_ovl_o      => video_ce_ovl_o            -- replaces line 415
      );
```

The 350-line doubler adds to this, in the same places:

* `main.vhd`: new port `video_mode350_o` driven by the core's `video_mode350_o`
  (`ega_top.v:1383`, was `open`);
* `mega65.vhd`: `video_mode350_i => main_video_mode350` and
  `video_analog_dbl_o => video_analog_dbl_o` on `i_analog_video_ctl`, and a new
  output port `video_analog_dbl_o`;
* `M2M/vhdl/top_mega65-r6.vhd`: `G_ANALOG_LINE_DOUBLER => true` on
  `i_framework` and `video_analog_dbl_i => video_analog_dbl` between the core
  and the framework;
* `M2M/vhdl/framework.vhd` and `M2M/vhdl/av_pipeline/av_pipeline.vhd`: the same
  generic and port forwarded down, both defaulting to `false` / `'0'` so an
  unmodified M2M core is bit-for-bit unchanged and builds no line buffers;
* `M2M/vhdl/av_pipeline/analog_pipeline.vhd`: the `gen_analog_dbl` generate
  beside `i_video_mixer` and the `src_*` mux in front of `i_video_overlay`.

Build: add `vhdl/analog_video_ctl.vhd` and `vhdl/analog_line_doubler.vhd` to
`vhd_extra` in `CORE/add-core-sources.tcl:16` (the list that carries the port's
own VHDL).
Constraints: none needed beyond the existing asynchronous group between
`clk_25` and the 28/57 MHz family (`CORE/CORE.xdc:35-42`) and QNICE;
`qnice_mode13_meta/qnice_mode13` carry `ASYNC_REG`, and
`docs/clocks-and-timing-constraints.md:284-287` already suggests a global
`set_max_delay -datapath_only` on `ASYNC_REG` cells if one is wanted.

### Caveats to document for users

* 350-line EGA modes (640x350, MDA/Hercules-style text): 43.7 kHz on the VGA
  connector in the 31 kHz setting (`analog_line_doubler.vhd`, section 2), which
  most multisync inputs accept; 21.86 kHz in the 15 kHz settings, where a
  15 kHz TV shows nothing and a 31 kHz LCD reports no signal. With the default
  "EGA monitor 5154" profile the EGA BIOS puts DOS text mode (mode 3) into the
  350-line raster, so users of the 15 kHz output should still pick "CGA monitor
  5153" in the Display submenu to keep text mode at 200 lines. HDMI is
  unaffected either way.
* Selecting a 15 kHz item switches mode 13h to its 60 Hz TV raster on HDMI
  as well (the core has one raster for both outputs). If that is unwanted,
  `osm_vga13_tv_i` can become its own toggle ("Mode 13h: 60 Hz TV raster")
  and the 15 kHz items merely recommend it.
* Composite sync follows the MiSTer VGA-to-SCART convention (CS on HS pin,
  VS pin high, `analog_pipeline.vhd:231-236`); the picture level/sync
  attenuation is the adaptor's business.
* On a VGA monitor, switching modes between the 200-line (31.4 kHz doubled)
  and mode 13h (31.5 kHz native) rasters costs the monitor a re-lock, as any
  mode change does. The doubler switch itself is at most one bad frame.
* OSM on the analog output: the overlay grid becomes 8 dots x 16 lines
  (31 kHz) or 8 dots x 8 lines (15 kHz, `retro15kHz`) on a 640-dot raster,
  i.e. narrow characters. Legibility is for hardware to judge; the HDMI OSM
  is untouched.

## 6. Not determinable without hardware

* Whether the user's monitor accepts the 21.8 kHz 350-line raster, and how it
  reacts to the positive HS/VS polarity the framework emits in all modes.
* The constant sampling parity between `video_ce_2x` and the doubled pixels
  (aligned vs. one output pixel late); both are invisible, but a bench of the
  framework `video_mixer` + `scandoubler` with this core's enable pattern
  would settle it and also demonstrate the 350-line failure mode in
  section 2. It needs the MiSTer Verilog (`video_mixer.sv`, `scandoubler.v`,
  `hq2x.sv`, `video_freezer.sv`, `gamma_corr.sv`) compiled under xsim; not
  done here.
* How the OSM looks on a real 15 kHz set with the 8x8 cell.
* Whether a SCART set needs the CSync variant or is happy with separate
  H/V on a cable that combines them; both are offered.

## 7. Later options (not part of this proposal)

* ~~A correct line doubler for the 350-line modes~~ - DONE, see section 2:
  `CORE/vhdl/analog_line_doubler.vhd`, `qnice_scandoubler` cleared for those
  modes by `analog_video_ctl.vhd`. It resamples from the measured line
  geometry rather than from a 2x NCO as this section originally sketched, which
  makes it independent of which dot clock the raster uses, and it sits beside
  `video_mixer` inside `analog_pipeline.vhd` rather than in front of it,
  because the mixer cannot carry a pixel enable with 1-clock gaps.
* 350 lines on a 15 kHz TV without a frame store: both rasters run at 60 Hz,
  so a 240p converter needs only a few BRAM line buffers (write at 21.8 kHz
  lines, read at 15.7 kHz lines, drop every third line, 233 lines out),
  locked to the input vsync. Simpler than upstream's DDRAM 480i path but
  still a new video module with its own testing.

## 8. "No signal" on the VGA connector: what the implemented design says

Reported from hardware: a VGA monitor on a normal cable reports "no signal"
and goes to standby at the M2M welcome screen, at the BIOS screen and at the
DOS prompt, with "VGA: 31 kHz", "EGA monitor 5154" and "Full color" selected.
HDMI is correct throughout, and the same monitor and cable work with other
cores on the same MEGA65.

### What was checked in the implemented design (nothing is wrong there)

All of this is from `CORE/CORE-R6.runs/impl_1/mega65_r6_routed.dcp` and
`CORE/CORE-R6.runs/synth_1/runme.log` of the build that was on the board:

* **Pins.** `vga_hs_o` = W12, `vga_vs_o` = V14, R/G/B on the eight pins each,
  `vdac_clk_o` = AA9, `vdac_sync_n_o` = V10, `vdac_blank_n_o` = W11,
  `vdac_psave_n_o` = W16, all `LVCMOS33` OBUFs. Identical to
  `M2M/MEGA65-R3/R4/R6.xdc`, which differ only by `vdac_psave_n_o` existing
  from R4 on.
* **Clocks.** `report_clocks`: `clk_57_ps` = 17.460 ns (57.273 MHz), waveform
  `{4.365 13.095}`, driven by `BUFGCTRL_X0Y6` from `i_mmcm_a/CLKOUT2` with
  2527 loads. `check_timing`: 0 pins with no clock, 0 constant clocks, 0
  unconstrained internal endpoints. Timing is met (`WNS` +0.203 ns overall,
  +6.761 ns inside `clk_57_ps`).
* **The analog chain survives synthesis.** `i_analog_pipeline` 1945 cells, of
  which `i_video_mixer` 1188 (`sd/` 1091), `i_video_overlay` 1229,
  `vga_recover_counters` 168, `i_csync` 92, `VGA_OUT_PHASE_SHIFTED` 28.
  `vga_hs_o_reg` is an `FDRE` with `IS_C_INVERTED = 1'b1` (the `falling_edge`
  of `analog_pipeline.vhd:226` is real) clocked by `video_clk_i`, `CE` tied to
  `<const1>`, `D` from a `LUT3` `INIT = 8'h74` over
  `{vga_hs_ps, video_csync_i, vga_cs_ps}` - which is exactly
  `vga_hs_ps when not video_csync_i else not vga_cs_ps`.
* **`video_ce_ovl` is alive.** `CORE/i_analog_video_ctl/video_ce_2x_reg` is an
  `FDRE` clocked by `video_clk_i` with `CE` tied high and `D` driven by a
  `LUT1 INIT = 2'h1` (an inverter) from its own output: a real toggle at
  57.27/2 = 28.6 MHz. The net is routed with a flat fanout of 35 and reaches
  `i_analog_pipeline/i_video_overlay/vga_ce_i`, which is the one gate the
  analog path has that HDMI does not (`av_pipeline.vhd`).
* The only registers synthesis removed in the analog path are the unused
  `vga_pix_x/pix_y/col/row` copies in `video_overlay` stages 2..9 and the
  matching `vga_osm` pipeline fields - dead by construction, not a symptom.

So the fault is not a missing connection, an optimised-away register, a wrong
polarity, a lost clock or a timing failure.

### What does explain two of the three symptoms

**The BIOS screen and the DOS prompt are 350-line rasters.** With the default
"EGA monitor 5154" profile the EGA BIOS puts its own screens and mode 3 into
the 640x350 raster, which scans at 21.86 kHz (measured end to end in
`analog_pipeline_350_tb`, section 2). That is far under the ~30 kHz an LCD
needs, and a monitor whose sync separator never locks reports "no signal"
rather than "out of range". This is the known limitation of section 2, and it
is what `analog_line_doubler.vhd` addresses - not a new fault.

**The M2M welcome screen is not explained.** Two candidates were checked and
both are ruled out:

* *The core is not held in reset there.* `M2M/rom/shell.asm:127` calls
  `RP_SYSTEM_START`, which ends with `AND M2M$CSR_UN_RESET, @R7`
  (`M2M/rom/gencfg.asm:55`) after wasting `RESET_COUNTER` loops; only then, at
  `shell.asm:134-137`, is the welcome screen drawn. (The comment at
  `shell.asm:138-142` mentioning "RESET_KEEP" refers to a config item this M2M
  version does not have; `CORE/vhdl/config.vhd:214-224` has
  `RESET_COUNTER = 100` and `WELCOME_ACTIVE = true` only.) So the core is
  running, and on the analog side that means its own boot splash - a 200-line
  raster the framework scandoubler takes to 31.4 kHz.
* *`video_retime_reset` is not stuck.* `pcxt_core.sv:585` does clear the whole
  output retime stage - `VGA_HS_video_ps/_hdmi`, `VGA_VS_*`, `CE_PIXEL_*` all
  go to 0 (`:1993-2033`) - but only while
  `RESET | status[0] | buttons[1] | !pll_locked | !pll_system_locked | splash_pending`,
  and `splash_pending` clears itself after `SPLASH_BOOT_WAIT` = 14_318_000
  cycles of `clk_14_318`, i.e. one second (`:1011, 1029-1046`). Note that
  `splashscreen` is deliberately *excluded* from `video_retime_reset`
  (`:584-585`), so the splash itself does have a raster.

Why HDMI can be perfect while the analog output is not, in any of these cases:
`digital_pipeline` runs its own timing generator and ascal re-times the core's
frames onto it, so HDMI produces a complete raster with the OSM on it almost
regardless of what the core's sync looks like. The analog side has no raster
generator at all (section 1) - the connector carries the core's own sync,
gated by the one signal HDMI does not use, `video_ce_ovl`.

A cheap hardware test that discriminates before any new bitstream: select
**"CGA monitor 5153"** in the Display submenu so DOS text mode stays a
200-line raster, which the framework scandoubler takes to 31.4 kHz. If a
picture appears there, the analog path works and only the 350-line rasters are
missing.

### The probe (diagnostic build only)

To settle it from the board rather than by inference, a probe measures the sync
**at the pins** and publishes it on the core's serial status line. The same
diagnostic build also repurposes the third status word for an unrelated
investigation (how many hard-disk sectors a FreeDOS boot really reads), so that
one bitstream answers both. Every line the probe adds or changes is tagged
`DIAG-PROBE`; `tools/revert-diag-probe.ps1` removes them all (`-WhatIf` to
preview). It must not ship.

* `M2M/vhdl/top_mega65-r6.vhd`: `vga_hs_o`/`vga_vs_o` are driven from internal
  signals `vga_hs_probe`/`vga_vs_probe` (the framework writes those), their
  rising edges are counted in `qnice_clk` through 2-FF synchronisers, and
  `video_ce_ovl` - 28.6 MHz, too fast to edge-count at 50 MHz without aliasing
  - is first divided in the video clock domain into a 27.3 Hz toggle whose
  13.66 rising edges per second are then counted in `qnice_clk`.
* `CORE/vhdl/mega65.vhd`: two new input ports `dbg_vga_i` / `dbg_ctl_i`
  (default `'0'`) replace `main_dbg_bus_reads` / `main_dbg_vsync` on
  `rom_loader`'s `dbg_a_i` / `dbg_b_i`, i.e. QNICE registers 6 and 7.
* `CORE/vhdl/main.vhd`: `p_dbg_wr` counts `blk_wr(2)` / `blk_ack(2)` - virtual
  drive 2, the hard disk (`mgmt_bridge.sv:67`) - instead of drive 0 (floppy A),
  `blk_ack_cnt` is widened from 8 to 16 bits so a whole boot fits without
  wrapping, and `dbg_keys_o` carries that 16-bit ack count alone.
* `CORE/m2m-rom/m2m-rom.asm`: `DBG_STR_6` becomes `" vga="`, `DBG_STR_7`
  `" ctl="`, `DBG_STR_8` `" hdd="`.

Reading the three words, from two status lines a few seconds apart:

| Field | Bits | Meaning |
|---|---|---|
| `vga=` high byte | 15..8 | HSYNC rising edges / 256. Advances 122.6/s at 31.4 kHz, 85.4/s at 21.86 kHz, 61.3/s at 15.7 kHz. Frozen = no HSYNC. |
| `vga=` low byte | 7..0 | VSYNC rising edges. Advances 60/s, wraps every 4.27 s. Frozen = no VSYNC. |
| `ctl=` bit 15 | | `qnice_scandoubler` (1 = the framework doubler is on) |
| `ctl=` bit 14 | | `qnice_csync` |
| `ctl=` bit 13 | | `qnice_retro15kHz` |
| `ctl=` bit 12 | | live HSYNC pin level |
| `ctl=` bit 11 | | live VSYNC pin level |
| `ctl=` bit 10 | | live `video_ce_ovl` level (sampled at 50 MHz, so aliased: only "not stuck" is meaningful) |
| `ctl=` bits 9..0 | | counter advancing 13.66/s while `video_ce_ovl` toggles; frozen = the overlay enable is dead |
| `hdd=` | 15..0 | hard-disk sectors served since power-on: rising edges of `blk_ack(2)`, one per 512-byte block the firmware completes. Read it before and after a FreeDOS boot, and before and after a single `dir`, to separate "DOS is issuing far more reads than expected" from "each read costs far more than the firmware accounts for". |

What the outcomes mean:

* both `vga=` bytes advancing at the rates above, at the welcome screen and at
  the DOS prompt, with `ctl=` bits 9..0 advancing: the analog path works and
  the problem is the monitor's lock range - i.e. only the 350-line rasters are
  really missing, and the doubler of section 2 is the whole fix.
* `vga=` frozen at the welcome screen but advancing once the core runs: the
  core is emitting no sync during the M2M screen after all, and the next place
  to look is `video_retime_reset` / the CSR reset (`pcxt_core.sv:584-596`).
* `vga=` frozen everywhere while `ctl=` bits 9..0 advance: sync is being lost
  inside `analog_pipeline` despite everything the netlist says.
* `ctl=` bits 9..0 frozen: `video_ce_ovl` is dead, which alone freezes
  `vga_recover_counters` (`vga_recover_counters.vhd:46-54`) and hence every
  analog output, while leaving HDMI untouched.

### If the probe says the sync is there

Then the signal is present and the monitor is refusing it, and the leading
suspect is already written up in `docs/analog-video-bench.md` section 3: the
connector carries **positive HS and positive VS** in the 31 kHz setting
(`analog_pipeline.vhd:222-239` registers the syncs without inverting them, and
the core emits positive pulses in every raster - section 1). In the IBM VGA
monitor-ID scheme H+/V+ is the *reserved* combination (H+/V- = 400 lines,
H-/V+ = 350, H-/V- = 480), and MiSTer's own `sys_top.v:1521-1522` emits
`~vga_hs` / `~vga_vs`. Analog CRTs lock regardless; an LCD scaler that
identifies the mode from polarity plus frequency can refuse a 31.4 kHz /
59.9 Hz / 524-line H+/V+ timing outright. The one-line experiment is
`vga_hs_o <= not vga_hs_ps` / `vga_vs_o <= not vga_vs_ps` in the non-csync
branch of `analog_pipeline.vhd:235-236` (the csync branch is already
active-low; nothing downstream of that register depends on the positive
polarity, and `csync.sv` and `scandoubler.v` upstream of it keep their
positive inputs). The second suspect is the HS pulse width: 2.23 us at
31.4 kHz, against 3.8 us in the VESA 640x480 timing.

## 9. Hardware status, 2026-09-12: analog output parked

Measured on the R6 with a VGA cable straight into an LCD monitor (the same
monitor, cable and socket show a picture with the MEGA65's own core):

* The analog path is alive. A diagnostic build counted the sync edges at pins
  W12/V14 and got about 21.88 kHz; the framework's own timing print in the
  same serial log agreed: 21.844 kHz, 640x350, 62.4 Hz, 16.252 MHz pixel rate.
  So the sync, the DAC clock, the overlay enable and the pin drivers are all
  working, and "no signal" is the monitor correctly refusing a 21.8 kHz raster.
* The welcome screen puts no sync on the pins at all, so the monitor stays
  asleep until the core is started with Space.
* Enabling the line doubler of section 7 (G_ANALOG_LINE_DOUBLER, 43.72 kHz,
  700 lines, simulation-clean over the whole pixel sequence) did NOT produce a
  picture on that monitor. Why is unknown: it was not investigated further
  because the owner chose to stop work on the analog output.

The doubler and its benches stay in the tree, disabled at
`M2M/vhdl/top_mega65-r6.vhd` (`G_ANALOG_LINE_DOUBLER => false`), so the analog
path is bit-for-bit what it was before. Anyone picking this up again should
start by re-applying the diagnostic probe (`tools/revert-diag-probe.ps1`
removes it; the probe itself is in the history of this commit's parent) and
reading the sync rate with the doubler on: if the pins really carry 43.7 kHz
and the monitor still refuses it, the next suspects are the sync polarity
(both positive here; MiSTer's `sys_top.v:1521-1522` inverts both) and the
non-standard 700-line geometry.

## 10. The way out, 2026-09-18: drive the DAC from the scaler

Research pass over the framework, the MEGA65's own core and the doubler's
measured output. Conclusion: every attempt so far tried to *transform* the
core's raster into something a monitor accepts. The fix is to *replace* it,
which is exactly what the HDMI path does and why HDMI has never had the problem.

### ascal already generates a standard raster, and it free-runs
`M2M/vhdl/av_pipeline/ascal.vhd:2674-2712` (`OSWEEP`): the output counters run
off `o_htotal`/`o_vtotal` on `o_clk` whenever `o_ce = '1'`, and the sync comes
straight off them. `digital_pipeline.vhd:332` ties `o_ce => '1'` and `:380`
ties `run => '1'`, so **the output sweep has no dependency on the input raster
at all**: HS and VS are on the pins from the moment `hdmi_clk` locks. The
signals to tap are the six post-OSM nets `hdmi_osm_red/green/blue/hs/vs/de`
(`digital_pipeline.vhd:481-486`), all registered, all in `hdmi_clk`, with the
on-screen menu already composited.

The mode records are already correct VESA including polarity
(`video_modes_pkg.vhd`): `C_HDMI_640x480p_60` is 25.2 MHz, 800 x 525,
31.5 kHz, H_POL = V_POL = '0'; `C_SVGA_800_600_60` is 40.0 MHz, 1056 x 628,
37.879 kHz, H_POL = V_POL = '1'. Polarity is applied *outside* ascal
(`vga_to_hdmi.vhd:479-480`, `vga_hs_p <= vga_hs xnor hs_pol_s`), so a VGA tap
needs the same two gates and then gets the right polarity per mode for free.
`video_out_clock.vhd` already produces 25.200, 25.179, 27.000, 40.000, 74.25
MHz by DRP, and the R6 DAC is an ADV7125 rated 170 MHz (`MEGA65-R6.xdc:19`),
so no new clock and no rate problem.

### What the MEGA65's own core does (the monitor's own proof)
Not in this tree; read from `github.com/MEGA65/mega65-core` master.
`pixel_driver` / `frame_generator` are a **free-running raster generator that
the VIC-IV is slaved to** (`machine.vhdl:1194-1217, 1281-1285`), 27.000 MHz,
31.286 kHz (PAL50) / 31.469 kHz (NTSC60), with **negative HS and negative VS**
on the VGA pins (`viciv.vhdl:2813-2863` sets `hsync_polarity <= '1'`,
`vsync_polarity <= '0'`, whose sense at `frame_generator.vhdl:262, 286, 270-276`
gives active-low on both), and a back porch of 2.9 to 3.1 us. Note it is *not*
VESA-conformant either (863 / 858 dot totals, 50.06 / 59.83 Hz), so strict VESA
is not what the monitor demands: **polarity, line rate and generous blanking**
are what differ from ours.

### Why the doubler could never have worked
Measured in `CORE/ooc/analog_pipeline_350_tb/xsim.log`, case
`C_after_31k_doubled`: 32.53 MHz effective dot clock, 744 dots x 728 lines,
**43.716 kHz**, 60.05 Hz, 700 active lines, HS and VS both **positive**.

| | our doubler | VESA 640x480@60 | MEGA65 core |
|---|---|---|---|
| H back porch | **0.49 us** | 1.91 us | 2.9 - 3.1 us |
| H blanking | 14.0 % | 24 % | ~22 % |
| sync polarity | H+ V+ | H- V- | H- V- |
| geometry | 700 lines, in no mode table | standard | standard-ish |

The back porch alone is enough to explain "no picture": LCD front ends need
roughly a microsecond for the clamp and sampling PLL to settle. And it is
structural, not a tuning error: the doubler replays each input line into
exactly half the input line period, so the blanking fractions are inherited
from the 350-line CRTC raster. It is not repairable into a standard mode
without becoming a raster generator, i.e. a worse ascal.

### The plan (Option A)
A generic `G_ANALOG_FROM_SCALER`, default false, that routes the six post-OSM
nets to the VGA output registers and `vdac_clk_o <= hdmi_clk_i`: about 70 lines
over `digital_pipeline.vhd` (6 ports, polarity xnor), `av_pipeline.vhd`
(forwarding), `analog_pipeline.vhd` (the generic, a second falling-edge output
block in the `hdmi_clk` domain), and the two top levels. No new clock, no MMCM,
no BUFG, no BRAM, no CDC. Fixes all three symptoms by construction: the welcome
screen (the sweep free-runs, so `video_retime_reset` stops mattering), the
350-line rasters (ascal re-times any input), and the doubler (obsoleted).

Costs and caveats:
* **One ascal means one output mode**: the VGA timing follows the HDMI menu
  selection. Ship it with 800x600 @ 60 Hz documented as the companion setting -
  a real VESA mode at exactly 40 MHz where H+/V+ *is* the correct polarity, and
  wide enough for the 720-dot MDA raster without downscaling (ascal is built
  `DOWNSCALE => false`, `digital_pipeline.vhd:298`).
* 640x480 @ 60 Hz is safest on polarity but needs the `hdmi_shift` clamp
  (`640 - 720 = -80` into a `natural` port, `video_overlay.vhd:28`) and cannot
  take the 720-dot raster without downscaling.
* The 15 kHz / CSync analog modes are unavailable while the generic is on; a
  runtime `BUFGCTRL` mux on `vdac_clk_o` could restore them later (12 BUFGs free).
* Adds ascal's one-frame latency to VGA, and "HDMI: CRT emulation" starts
  affecting VGA too.

A second ascal instance would decouple the two outputs: ~250-400 lines, a
second `video_out_clock` MMCM, 10-14 BRAM tiles (160 free), `G_NUM_SLAVES => 4`
on `framework.vhd:691` and a 4th Avalon master, and roughly +135 MB/s of
HyperRAM traffic on a bus that already exports over/under-run flags. Only worth
it if independent VGA and HDMI modes are a requirement.

### Free experiment, still worth doing first
Display -> "CGA monitor 5153", then reset the core (it is applied at reset,
`main.vhd:436`). In a 200-line raster `analog_video_ctl.vhd:119` leaves the
framework scandoubler on, and `CORE/ooc/analog_pipeline_tb` case A measured the
result at the pins: 31.40 kHz, 524 lines, 400 active, 59.92 Hz, HS positive
2.23 us, VS positive 6 lines. A picture there proves the analog stage and this
monitor agree once the rate is sane, and that polarity is not by itself fatal.

### M2M upstream
V2.0.1 has nothing for this: `analog_pipeline.vhd` takes no video-mode input at
all (entity at `:13-76`), `H_POL`/`V_POL` appear only in the digital path
(`digital_pipeline.vhd:497-498`), and no switch anywhere connects the scaler to
the VGA pins. Nothing obstructs the change either: the arbiter slave count is a
generic, `hdmi_clk_i` is already a port of `av_pipeline` (`:132`), and
`G_ANALOG_LINE_DOUBLER` is precedent for a framework-local generic defaulted off.
