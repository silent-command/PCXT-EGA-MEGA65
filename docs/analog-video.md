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
| EGA 350-line modes, MDA 720x350 (`ega_hifreq_mode`) | 18.4-21.9 kHz / 60 Hz | 16.257 MHz from an NCO, alternating 3 and 4 clocks | see below | no (as upstream without the 480i option) |

Mode 13h: the doubler must follow `video_mode13_o` (`pcxt_core.sv:2117`,
`vga_private_active` = mode 13h, planar-16 and the unchained profiles,
`ega_top.v:301, 1291`). The flag comes from the chipset in `clk_card_video`,
the muxed 28.636/25.2 MHz clock (`pcxt_core.sv:574-581, 1251-1264`), and
changes once per mode set (`vga_mode13_ctrl.v:16-23`), not aligned to vblank;
the clock mux switches at the same moment, so the raster is discontinuous
there anyway and the doubler switching adds nothing visible.

350-line modes: 2 x 21.8 kHz = 43.6 kHz would be inside the range of most
multisync monitors, but the framework doubler cannot produce it correctly
from this input. The 16.257 MHz dot enable is an NCO in the 28.636 MHz domain
(`ega_dot_clock.v:11-19`; 59609/105000 restarted per line) and arrives in
`clk_57_ps` as pulses 3 or 4 clocks apart. `scandoubler.v:64-91` latches a
single `pixsz` (3 or 4, whichever the last visible pixel had), resamples the
input at that fixed spacing (`:85-89`), so ~12 % of the columns are skipped
(pixsz 4) or ~17 % duplicated (pixsz 3), and replays at `pixsz2` = 1 or 2
clocks per pixel instead of the 1.76 the doubled 16.257 MHz stream needs
(`:135-143`). The syncs would be right (they are measured in clocks), the
pixels would not. `video_mixer.sv:27` says as much. The core's own line
doubler is no help either: `ega_top.v:1043-1050` forces it off because
2 x 16.257 MHz cannot be made in the 28.636 MHz domain. So for now the
350-line modes stay at their native 21.8 kHz on the analog output in every
menu setting; most LCD monitors need >= 30 kHz and will report "out of range"
there, multisync CRTs and some LCDs may accept it. Section 7 sketches what a
correct doubler for these modes would take.

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
| 350-line modes | none clean (21.8 kHz native, doubled stream corrupt) | none (needs a frame/line-rate converter) |

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
| VGA: 31 kHz | `NOT video_mode13` | 0 | 0 | 0 |
| VGA: 15 kHz | 0 | 1 | 0 | 1 |
| VGA: 15 kHz + CSync | 0 | 1 | 1 | 1 |

plus, in every setting, `video_ce_ovl = clk_57_ps / 2` (free running).

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

Build: add `vhdl/analog_video_ctl.vhd` to `vhd_extra` in
`CORE/add-core-sources.tcl:16` (the list that carries the port's own VHDL).
Constraints: none needed beyond the existing asynchronous group between
`clk_25` and the 28/57 MHz family (`CORE/CORE.xdc:35-42`) and QNICE;
`qnice_mode13_meta/qnice_mode13` carry `ASYNC_REG`, and
`docs/clocks-and-timing-constraints.md:284-287` already suggests a global
`set_max_delay -datapath_only` on `ASYNC_REG` cells if one is wanted.

### Caveats to document for users

* 350-line EGA modes (640x350, MDA/Hercules-style text): 21.8 kHz on the VGA
  connector in every setting; a 15 kHz TV shows nothing, a 31 kHz LCD most
  likely "out of range", a multisync CRT may lock. HDMI is unaffected. The
  boot splash, DOS text mode on a CGA/5153 monitor profile and all 200-line
  games are fine. Note that with the default "EGA monitor 5154" profile the
  EGA BIOS puts DOS text mode (mode 3) into the 350-line raster; users of the
  15 kHz output should pick "CGA monitor 5153" in the Display submenu so
  text mode stays at 200 lines.
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

* A correct line doubler for the 350-line modes: the core's
  `video_scandoubler.v` (line buffers of `H_TOTAL_MAX` pixels, `ce_pix` and a
  `ce_2x` at exactly twice the dot rate) re-instantiated in the `clk_57_ps`
  domain after the retime, with a 2x NCO for the 16.257 MHz modes
  (2 x 59609/105000 of 57.27 MHz = 32.5 MHz, under the clock, so it is
  feasible there even though it is not at 28.636 MHz). Output 43.6 kHz,
  700 lines, positive syncs. New module of a few hundred lines plus the
  framework `qnice_scandoubler` set to 0 for those modes.
* 350 lines on a 15 kHz TV without a frame store: both rasters run at 60 Hz,
  so a 240p converter needs only a few BRAM line buffers (write at 21.8 kHz
  lines, read at 15.7 kHz lines, drop every third line, 233 lines out),
  locked to the input vsync. Simpler than upstream's DDRAM 480i path but
  still a new video module with its own testing.
