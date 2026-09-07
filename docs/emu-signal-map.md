# PCXT-EGA `emu` signal map: design input for `CORE/rtl/pcxt_core.sv`

Scope: everything the MiSTer top module `emu` (`CORE/PCXT-EGA_MiSTer/PCXT-EGA.sv`,
2252 lines, submodule commit `c6b4dc8`, 2026-09-04) does between the framework
and the core, and what of it the MEGA65 wrapper must keep, re-source, replace or
drop. Bare `:NNN` line numbers refer to `PCXT-EGA.sv`; other files are named.
Build macros: the release build sets **all** of `ENABLE_OPL2/CMS/EMS/UMB/
TANDY_AUDIO/MIDI/SB = 1` (`config.tcl:2-16`, sourced by `PCXT-EGA.qsf:62`), so
the menu below is the full one; the `ifndef` defaults at `:19-42` are not what
ships.

Already documented elsewhere and only referenced here:

* mgmt bus, `ide.v`, `floppy.v`, RTC: `docs/mgmt-bus-and-storage-regs.md`
* ARM-side IDE/FDD behaviour: `docs/arm-side-ide-floppy-behaviour.md`
* clock inventory, CDC list, XDC: `docs/clocks-and-timing-constraints.md`
  (section 1 is the clock inventory; section 3 the crossing list S1-S22/U1-U9)

---

## 1. CONF_STR decode

### 1.1 The menu string as built (`:144-206`, all `ENABLE_*=1`)

Bit letters: `O0..O9,OA..OV` = status[0..31]; `o0..o9,oA..oV` = status[32..63];
`O[n]` = explicit bit. `R`/`r` = momentary (ARM sets the bit, then clears it).
`h<n>` = hidden unless `status_menumask[n]`; `P<n>` = sub-page; `F C<n>` = ROM
file slot n remembered in the CFG file and re-sent at every core start
(`rtl/KFPC-XT/HDL/rom_presence_latch.sv:3-5`); `S<n>` = disk image slot
(served through the mgmt bus, no status bit).

| # | Entry (line) | Bits | Choices |
|---|---|---|---|
| 1 | `PCXT-EGA;UART115200:115200,MIDI;` (`:23`) | - | core name, UART menu with a MIDI mode |
| 2 | `h4-,HALTED: no PCXT BIOS selected;` `h5-,HALTED: no EGA BIOS selected;` (`:124-127`) | - | text lines, shown by menumask 4/5 |
| 3 | `S0,IMGIMAVFD,Floppy A:;` `S1,...,Floppy B:;` (`:147-148`) | - | floppy images (mgmt bus) |
| 4 | `OJK,Write Protect,None,A:,B:,A: & B:;` (`:149`) | 20:19 | |
| 5 | `S2,VHD,IDE 0-0;` `S3,VHD,IDE 0-1;` (`:151-152`) | - | HDD images (mgmt bus) |
| 6 | `OLM,2nd SD card,Disable,IDE 0-0,IDE 0-1;` (`:153`) | 22:21 | |
| 7 | `OHI,CPU Speed,4.77MHz,7.16MHz,9.54MHz,Max;` (`:155`) | 18:17 | |
| 8 | `P1,System & BIOS;` (`:157`) | | page 1 |
| 9 | `P1O7,Boot Splash Screen,Yes,No;` (`:159`) | 7 | |
| 10 | `P1oV,CPU Type,8088,8086;` (`:160`) | 63 | |
| 11 | `P1oL,Fake 286 FLAGS,Off,On;` (`:161`) | 53 | |
| 12 | `P1FC0,ROM,PCXT BIOS:;` (`:92`,`:163`) | ioctl index 0 | |
| 13 | `P1FC2,ROM,EC00 BIOS:;` (`:164`) | ioctl index 2 | |
| 14 | `P1FC3,ROM,EGA BIOS:;` (`:165`) | ioctl index 3 | |
| 15 | `P1OUV,BIOS Writable,None,EC00,Main,All;` (`:167`) | 31:30 | |
| 16 | `P2,Audio & Video;` (`:169`) | | page 2 |
| 17 | `P2OST,Audio 220h,C/MS,Sound Blaster,Disabled;` (`:107`) | 29:28 | three-way because CMS and SB are both built |
| 18 | `P2oAB,OPL2,Adlib 388h,SB FM 388h/228h, Disabled;` (`:110`) | 43:42 | |
| 19 | `P2oN,Tandy Sound,Disabled,Enabled;` (`:111`) | 55 | |
| 20 | `P2o01,Speaker Volume,1,2,3,4;` (`:174`) | 33:32 | |
| 21 | `P2o45,Audio Boost,No,2x,4x;` (`:175`) | 37:36 | |
| 22 | `P2o67,Stereo Mix,none,25%,50%,100%;` (`:176`) | 39:38 | |
| 23 | `P2oEH,CRT H offset,0..15;` (`:178`) | 49:46 | |
| 24 | `P2oIK,CRT V offset,0..7;` (`:179`) | 52:50 | |
| 25 | `P2O[66:64],VSync Width,Auto,1..7;` (`:180`) | 66:64 | |
| 26 | `P2O[69:67],HSync Width,Auto,1..7;` (`:181`) | 69:67 | |
| 27 | `P2O12,Scandoubler Fx,None,HQ2x,CRT 25%,CRT 50%;` (`:183`) | 2:1 | |
| 28 | `P2O89,Aspect ratio,Original,Full Screen,[ARC1],[ARC2];` (`:184`) | 9:8 | |
| 29 | `P2OEG,Display,Full Color,Green,Amber,B&W,Red,Blue,Fuchsia,Purple;` (`:185`) | 16:14 | |
| 30 | `P2OA,VGA 13h+ CRT,Native 70Hz,TV 60Hz;` (`:186`) | 10 | |
| 31 | `P2o23,350-line CRT,Native,480i 15 kHz,240p 15 kHz;` (`:187`) | 35:34 | |
| 32 | `P3,Hardware;` (`:189`) | | page 3 |
| 33 | `P3oCD,Monitor,5154/ECD,5153/CGA,5151/MDA;` (`:191`) | 45:44 | |
| 34 | `P3O5,2MB EMS D000-DFFF,Enabled,Disabled;` (`:112`) | 5 | |
| 35 | `P3OC,UMB C400-CFFF,Enabled,Disabled;` (`:113`) | 12 | |
| 36 | `P3ONO,Joystick 1, Analog, Digital, Disabled;` (`:195`) | 24:23 | |
| 37 | `P3OPQ,Joystick 2, Analog, Digital, Disabled;` (`:196`) | 26:25 | |
| 38 | `P3OR,Sync Joy to CPU Speed,No,Yes;` (`:197`) | 27 | |
| 39 | `P3oM,Swap Joysticks,No,Yes;` (`:198`) | 54 | |
| 40 | `P3O[70],Sound Blaster IRQ,5,7;` (`:199`) | 70 | |
| 41 | `P3oO,MPU-401,Enabled,Disabled;` (`:119`) | 56 | |
| 42 | `P3O6,USER I/O,MIDI,COM2;` (`:119`) | 6 | |
| 43 | `h3P4,MT32-pi;` page: `h3P4OD,Use MT32-pi,Yes,No;` `h3P4o9,MT32-pi Mode,MT-32,General MIDI;` `h3P4O34,MT32-pi ROM,...;` `h3P4oSU,MT32-pi SoundFont,#0..#7;` `h3P4r8,Reset Hanging Notes;` (`:119`) | 13, 41, 4:3, 62:60, 40 | page 4, shown by menumask 3 |
| 44 | `R0,Reset & apply settings;` (`:203`) | 0 | momentary |
| 45 | `J,Fire 1,Fire 2;` (`:204`) | joy[4], joy[5] | joystick button names |
| 46 | `I,` three notices (`:132-142`) | info 1..3 | "No PCXT BIOS selected / Machine halted / OSD: System & BIOS", same for EGA, "That setting is applied when the machine resets" |
| 47 | `V,v<BUILD_DATE>` (`:205`) | - | version line |

### 1.2 Every `status[...]` field used in the code

"Change" column: **live** = takes effect immediately; **reset** = latched only
while the machine is in reset (a `reset_pending` notice is raised otherwise);
**pulse** = momentary. XTEGACTL column: the resolved `eff_*` output of
`xtegactl_resolve` (`:280-335`, `rtl/KFPC-XT/HDL/xtegactl_resolve.sv`) can
override the OSD value when a DOS program writes a non-zero field
(`xtegactl_resolve.sv:3-8`, per-field rules `:128-175`).

| Bits | Menu item | Values (0..n) | Read at | XTEGACTL override | Drives | Change |
|---|---|---|---|---|---|---|
| 0 | Reset & apply settings | pulse | `:529,:530,:1636` | - | `reset_wire`, `video_retime_reset`, `mt32_reset` | pulse |
| 2:1 | Scandoubler Fx | None, HQ2x, CRT 25%, CRT 50% | `:370` -> `scale` -> `scale_video_ff` (`:395`, clk_57_272) | - | `video_scandoubler_en = scale>0 \| forced_scandoubler` (`:381`) -> `CHIPSET.video_scandoubler_en` (`:1336`); `VGA_SL = {scale==3, scale==2}` (`:1841`); `video_mixer.hq2x = scale==1` (`:2112`) | live. **Dead:** the chipset ignores `video_scandoubler_en` (`ega_top.v:87` port unused, `ega_scandouble_active = 1'b0` at `ega_top.v:1050`) and `video_mixer.scandoubler` is tied 0 (`:2111`) so HQ2x never runs. Only `VGA_SL` (HDMI scanlines in `sys_top.v:1383-1387`) has an effect. |
| 4:3 | MT32-pi ROM | MT-32 v1, v2, CM-32L, Reserved | `:1638` | - | `mt32pi.mt32_rom_req` | live |
| 5 | 2MB EMS | Enabled(0), Disabled(1) | `:300` as `osd_ems = ~status[5]` | `reg_exp[5:4]` | `eff_ems` -> `ems_enabled_sel` (`:1167`) -> `CHIPSET.ems_enabled` (`:1304`) | live (page frame fixed at D000, `ems_address_sel = 2'b01`, `:1168`) |
| 6 | USER I/O | MIDI(0), COM2(1) | `:1592` as `user_io_mt32 = ~status[6]` | - | `USER_OUT` mux (`:1601`), uart2 idle levels (`:1617-1620`), `mt32_use/mute` (`:1650-1651`), `midi_rx` mux (`:1660`) | live |
| 7 | Boot Splash Screen | Yes(0), No(1) | `:960` -> `splash_off` (clk_14_318, no sync: SDC false path) | - | splash FSM: with `splash_off`=0 the splash runs for 5 s; with 1 `splash_pending` still lasts `SPLASH_BOOT_WAIT` = 14318000 clocks = 1.0 s (`:956,:984-987`) and a running splash is cut short (`:995-998`) | live / next boot |
| 9:8 | Aspect ratio | Original, Full Screen, [ARC1], [ARC2] | `:372` -> `ar` | - | `VIDEO_ARX/ARY` (`:396-397`): 0 -> 4:3; 1 -> 0/0 (full screen); 2 -> 1/0; 3 -> 2/0 (`sys_top.v:912-920` reads ARX 1/2 with ARY 0 as the ini custom ratios) | live |
| 10 | VGA 13h+ CRT | Native 70Hz(0), TV 60Hz(1) | `:226` as `vga_mode13_native_osd = ~status[10]` | - | `CHIPSET.vga_mode13_native` (`:1211`); video clock mux select `vga_native_standard_clock` (`:519-521`) | live (switches the muxed video clock) |
| 12 | UMB C400-CFFF | Enabled(0), Disabled(1) | `:301` as `~status[12]` | `reg_exp[7:6]` | `eff_umb` -> `umb_enabled_sel` (`:1169`) -> `CHIPSET.umb_enabled` (`:1306`) | live |
| 13 | Use MT32-pi | Yes(0), No(1) | `:1631` `mt32_disable` | - | `mt32_use`, `mt32_mute` (`:1650-1651`) | live |
| 16:14 | Display | Full Color, Green, Amber, B&W, Red, Blue, Fuchsia, Purple | `:371` -> `screen_mode` -> `screen_mode_video_ff` (`:395`) | - | `video_mono.gfx_mode` (`:1883`); `color = mode==0` (`:1845`) selects the mode-13h converter bypass (`:1898-1905`) | live |
| 18:17 | CPU Speed | 4.77, 7.16, 9.54, Max | `:287` `osd_speed` | `reg_cpu[2:0]` (1..4 = choices) | `eff_speed` -> `clk_select_next` (`:562`) -> `clk_select` latched on `biu_done` (`:564-569`) -> `XT_CE_Generator` (`:572-589`), `CHIPSET.clk_select` (`:1187`) | live, applied between bus cycles |
| 20:19 | Write Protect | None, A:, B:, A:&B: | `:1318` | - | `CHIPSET.floppy_wp` (ORed with the bridge's per-drive WP, `floppy.v:90`) | live |
| 22:21 | 2nd SD card | Disable, IDE 0-0, IDE 0-1 | `:1718-1721` | - | `use_mmc` latched while `reset`=1 -> `CHIPSET.use_mmc` (`:1308`); `reset_pending` (`:1731`) | reset |
| 24:23 | Joystick 1 | Analog(00), Digital(01), Disabled(10) | `:302-303` bit 23 = digital, bit 24 = disable | `reg_inp[1:0]` | `eff_joy1_digital/disable` -> `joy_opts[0]/[1]` (`:367-368`) -> `CHIPSET.joy_opts` (`:1261`) | live |
| 26:25 | Joystick 2 | same | `:304-305` | `reg_inp[3:2]` | `joy_opts[2]/[3]` | live |
| 27 | Sync Joy to CPU Speed | No, Yes | `:306` | `reg_inp[7:6]` | `eff_joy_sync` -> `joy_opts[4]` | live |
| 29:28 | Audio 220h | C/MS(0), Sound Blaster(1), Disabled(2) | `:270-276` -> `a220_cms = sel==0`, `a220_sb = sel==1` | `reg_exp[3:2]` (CMS), `reg_exp2[3:2]` (SB); SB wins a tie (`xtegactl_resolve.sv:141-148`) | `eff_cms` -> `CHIPSET.cms_en` (`:1274`); `eff_sb` -> `CHIPSET.sb_en` (`:1270`) | live |
| 31:30 | BIOS Writable | None, EC00, Main, All | `:818` in loader state 0 | - | `bios_protect_flag = {ega_bios_write_protect, ~status[31], ~status[30]}` -> `CHIPSET.bios_protect_flag` (`:1307`) -> `RAM.sv:234-236` (flag[2] C0000-C3FFF, [1] F0000-FFFFF, [0] EC000-EFFFF) | live while the loader is idle; forced to 000 during a download (`:844,:876,:894,:912`) |
| 33:32 | Speaker Volume | 1,2,3,4 | `:1424,:1426` | - | shift of `spk_vol` and `tandy_snd` | live |
| 35:34 | 350-line CRT | Native, 480i, 240p | `:1927-1929` | - | `fb_enable = mode350 & crt480i_osd` (`:1944`), `crt480i_prog` -> `ega_fb_readout.progressive` (`:1997`) | live |
| 37:36 | Audio Boost | No, 2x, 4x | `:1446,:1479-1480` | - | `compr()` selects 2x (`status[37]=0`) or 4x curve; output uses compressed value when `status[37:36]!=0` | live |
| 39:38 | Stereo Mix | none, 25%, 50%, 100% | `:1482` | - | `AUDIO_MIX` (framework mixer, `sys/audio_out.sv:329`) | live |
| 40 | Reset Hanging Notes | pulse | `:1636` | - | `mt32_reset` | pulse |
| 41 | MT32-pi Mode | MT-32, General MIDI | `:308` | `reg_midi[1:0]` | `eff_mt32_gm` -> `mt32_mode_req` (`:1637`) | live |
| 43:42 | OPL2 | Adlib 388h, SB FM 388h/228h, Disabled | `:289` | `reg_exp[1:0]` | `eff_opl2` -> `CHIPSET.opl2_io` (`:1269`) | live |
| 45:44 | Monitor | 5154/ECD, 5153/CGA, 5151/MDA | `:240` | - | `ega_monitor_profile_latch` (`:626-631`, tracks while `reset`=1, `ega_monitor_profile_latch.v:19-22`) -> `CHIPSET.ega_monitor_profile` (`:1212`); `reset_pending` (`:1730`) | reset |
| 49:46 | CRT H offset | 0..15 | `:296` | `reg_crt[3:0]` when `reg_crt[7]` | `eff_crt_h` -> `CHIPSET.crt_h_offset` (`:1344`), `fb_readout` (`:1999`) | live |
| 52:50 | CRT V offset | 0..7 | `:297` | `reg_crt[6:4]` when `reg_crt[7]` | `eff_crt_v` -> `:1345`, `:2000` | live |
| 53 | Fake 286 FLAGS | Off, On | `:235` | `reg_cpu[4:3]` | `eff_fake286` -> 2-FF sync to clk_100 (`:644-648`) -> `i8088.fake286_flags` (`:1390`) | live |
| 54 | Swap Joysticks | No, Yes | `:307` | `reg_inp[5:4]` | `eff_joy_swap` -> joystick port mux (`:1262-1265`) | live |
| 55 | Tandy Sound | Disabled(0), Enabled(1) | `:309` | `reg_exp2[1:0]` | `eff_tandy` -> `CHIPSET.tandy_en` (`:1268`) | live |
| 56 | MPU-401 | Enabled(0), Disabled(1) | `:310` as `~status[56]` | `reg_midi[3:2]` | `eff_mpu401` -> `mpu401_enabled_sel` (`:1170`) -> `CHIPSET.mpu401_enabled` (`:1288`); `status_menumask[3]` (`:387-388`) | live |
| 62:60 | MT32-pi SoundFont | #0..#7 | `:1639` | - | `mt32_sf_req` | live |
| 63 | CPU Type | 8088, 8086 | `:230` | - | `cpu_type_latch` (`:633-637`, tracks while `reset`=1) -> `i8088.is8086` (`:1389`); `reset_pending` (`:1729`) | reset |
| 66:64 | VSync Width | Auto, 1..7 | `:298` | `reg_sync[2:0]` non-zero | `eff_vsync_w` -> `vsync_width_osd` (`:376`) -> `CHIPSET.vsync_width_osd` (`:1346`) | live |
| 69:67 | HSync Width | Auto, 1..7 | `:299` | `reg_sync[5:3]` non-zero | `eff_hsync_w` -> `:377`, `:1347` | live |
| 70 | Sound Blaster IRQ | 5, 7 | `:277` `sb_irq_osd` | `reg_exp2[5:4]` (1 = IRQ5, 2 = IRQ7) | `eff_sb_irq` -> `sb_irq7` (`:278`) -> `CHIPSET.sb_irq7` (`:1271`) | live |

Totals: **38 fields, 67 status bits** (0-10, 12-27, 28-56, 60-70). Unused: 11,
57, 58, 59; bits 71-127 are free (`hps_io` carries 128).

Menumask (`:387-388`): `[2:0]` = 111 (unused h0-h2), `[3]` = `ENABLE_MIDI &
mt32_available & eff_mpu401`, `[4]` = `bios_missing_pcxt`, `[5]` =
`bios_missing_ega`. Info box: `info/info_req` (`:1081-1082`) from
`bios_hold_notice` (index 1 or 2, re-armed every 1.5 s while held,
`bios_hold_notice.sv:20-21,:59-61`) or `reset_pending_notice` (index 3, once
per OSD close, `reset_pending_notice.sv:29,:49-60`).

### 1.3 The other `hps_io` outputs the core consumes

| Signal | Meaning (from `sys/hps_io.sv`) | Used at | MEGA65 |
|---|---|---|---|
| `buttons[1:0]` | `cfg[1:0]` from the ARM (`hps_io.sv:197`): [1] = user button on the IO board / "reset" from the OSD, [0] = OSD button | `buttons[1]` in `reset_wire` (`:529`), `video_retime_reset` (`:530`), splash `phys_reset_hold` (`:961`), `mt32_reset` (`:1636`); `buttons[0]` unused | one `reset_button_i`; M2M's reset key |
| `OSD_STATUS` | OSD menu open (`sys_top.v:1410,:1859`) | `reset_pending_notice.osd_status` (`:1736`), fires the notice on menu close | drop with the notice, or feed the OSM "menu closed" edge |
| `forced_scandoubler` | `cfg[4]` (`hps_io.sv:200`), MiSTer.ini `forced_scandoubler`/VGA-at-31kHz | `video_scandoubler_en` (`:381`) only | **dead** (see 2:1 above); tie 0 |
| `gamma_bus[21:0]` | `[20:0]` = `{clk_sys, gamma_en, gamma_wr, addr[9:0], value[7:0]}` from the ARM (`hps_io.sv:252`); `[21]` = 1 driven by `video_mixer` `GAMMA=1` (`video_mixer.sv:109`) | `video_mixer.gamma_bus` (`:2113`), assigned back at `:2195` | drop (no gamma table on M2M); set `gamma_en`=0 |
| `ps2_key[10:0]` | `{toggle, pressed, extended, set-2 code}` (`hps_io.sv:102-103,:306`) | `splash_f12_pause` (`:1030-1035`), F12 break while the splash is up | needs an equivalent decoded event from `keyboard.vhd` |
| `ps2_kbd_clk_out/data_out` (into core as `ps2_kbd_clk_in/data_in`, `:428-429`) | `ps2_device` keyboard emulator, PS/2 clock = clk_sys/(2*2001) = 12.5 kHz (`PS2DIV=2000`, `hps_io.sv:551-560`); `PS2WE=1` enables host-to-device bytes (`:578-579`) which the ARM answers | 2-FF on negedge clk_chipset (`:1089-1127`) -> `CHIPSET.ps2_clock/data` (`:1253-1254`); host->device from `CHIPSET.ps2_clock_out/data_out` (`:1255-1256`, keyboard reset via port B bit 6, `Peripherals.sv:552`) | lift `ps2_device` (`hps_io.sv:711-864`); the wrapper side must answer host commands (ACK 0xFA, BAT 0xAA) |
| `ps2_mouse_clk_out/data_out` | second `ps2_device` (`hps_io.sv:590-606`), raw PS/2 mouse packets from the ARM | `CHIPSET.ps2_mouseclk_in/dat_in` (`:1257-1258`) -> `MSMouseWrapper` (`Peripherals.sv:1005-1013`, PS/2 -> Microsoft serial mouse on COM1); host->device `:1259-1260` (mouse init commands) | synthesise 3-byte PS/2 packets from `mouse_input.vhdl`, and answer 0xFF/0xF4 etc. |
| `joystick_0/1[13:0]` (`joy0/joy1`) | digital: [0] right, [1] left, [2] down, [3] up, [4] Fire 1, [5] Fire 2 (`rtl/common/tandy_pcjr_joy.sv:32-35,:63`) | `CHIPSET.joy0/joy1` after the swap mux (`:1262-1263`) | MEGA65 DB9 ports |
| `joystick_l_analog_0/1[15:0]` (`joya0/1`) | Y = [15:8], X = [7:0], signed -127..127 (`hps_io.sv:48`); used as `128 + x` (`tandy_pcjr_joy.sv:32-35`) | `:1264-1265` | paddles later; tie 0 = centred |
| `ioctl_*` | see 3.6 | `:731-944` | QNICE ROM loader |
| `uart_mode[7:0]` | UART menu mode; `>=3` = MIDI (`:1571`) | `hps_midi` routing (`:1573-1583`, `:1660`) | tie 0 |
| `new_vmode` | toggle input telling the ARM to re-measure the video mode (`hps_io.sv:115,:953-957`) | driven by `ega_vmode_toggle` (`:421`) | drop (ascal auto-detects) |
| `EXT_BUS` | pass-through to `hps_ext` (mgmt bus) | `:451-473` | mgmt bridge (existing doc) |
| not connected | `img_*`, `sd_*`, `RTC`, `TIMESTAMP`, `ps2_mouse[24:0]`, `paddle_*`, `spinner_*`, `status_in/set`, `direct_video`, `sdram_sz` | - | - |

---

## 2. Block diagram of `emu` (table)

Verdict key: **KEEP** = compile the upstream file unchanged; **KEEP/RS** = keep,
re-source its inputs from M2M; **REPLACE** = M2M equivalent; **DROP**.
Domains: `chip` = clk_chipset 50 MHz, `core` = clk_100, `vid28` = clk_card_video
(28.636 or 25.2 muxed), `vid57` = clk_57_272, `ps` = clk_video_out_ps,
`14m` = clk_14_318.

| # | Unit (lines) | Purpose | Domain | Verdict | Reason |
|---|---|---|---|---|---|
| 1 | `xtegactl_resolve` (`:280-335`) | merge OSD values with DOS-side XTEGACTL overrides into `eff_*` | comb | KEEP/RS | pure logic; feed `osd_*` from OSM inputs |
| 2 | `hps_io` (`:407-448`) | status, buttons, PS/2 emulation, joysticks, ioctl, info, gamma | chip | REPLACE | OSM + `keyboard.vhd` + lifted `ps2_device` + QNICE loader |
| 3 | `hps_ext` (`:460-473`) | SPI -> mgmt bus | chip | REPLACE | `mgmt_bridge.sv` (existing doc, section 5) |
| 4 | `pll` (`:497-503`) | 100 / 50 MHz | - | REPLACE | MMCM B in `clk.vhd` |
| 5 | `pll_system` (`:508-515`) | 28.636 / 57.27 / 57.27+90 / 25.2 | - | REPLACE | MMCM A |
| 6 | `vga_video_clock_mux` (`:522-527`) | 28.636 vs 25.2 for the EGA/VGA raster | - | REPLACE | `BUFGMUX_CTRL` (clocks doc 4.1) |
| 7 | `clk_14_318` divider (`:547-550`) | register-divided 14.318 MHz | vid28 | REPLACE | MMCM A CLKOUT4 |
| 8 | `clk_select` latch (`:564-569`) + `XT_CE_Generator` (`:572-589`) | CPU clock pin, `cpu_ce_*`, `peripheral_ce`, per-speed wait profiles (`XT_CE_Generator.sv:53-88`) | chip | KEEP | core timing; no framework dependency |
| 9 | `reset` counter (`:591-620`), `reset_cpu` (`:650-687`, negedge), `reset_sdram` (`:689-716`) | stretched resets (section 6) | chip | KEEP/RS | inputs `RESET`, `status[0]`, `buttons[1]`, PLL locks come from M2M |
| 10 | `ega_monitor_profile_latch` (`:626-631`), `cpu_type_latch` (`:633-637`) | reset-applied options | chip | KEEP | |
| 11 | `fake_286_flags_meta` (`:644-648`) | 2-FF to clk_100 | core | KEEP | |
| 12 | BIOS loader FSM (`:720-944`) | ioctl words -> `bios_access_request/address/data/write_n` into the chipset ext bus; protect flags | chip | KEEP/RS | keep the FSM, feed it an ioctl-shaped stream from QNICE (3.6) |
| 13 | `ega_bios_loaded_latch` (`:746-755`), `rom_presence_latch` (`:766-773`) | "ROM present" flags, EGA write-protect and DIP switches | chip | KEEP/RS | `download_active` must be derived the same way |
| 14 | splash FSM (`:947-1022`) | 5 s boot splash, 1 s `splash_pending`, F12 hold | 14m | KEEP | drives the reset tree; `phys_reset_hold` (`:953-972`) is dead logic (no reader) |
| 15 | `splash_f12_pause` (`:1030-1035`) | F12 break during splash toggles `splash_paused` | 14m | KEEP/RS | needs `ps2_key`-format input |
| 16 | `bios_hold_notice` (`:1067-1075`) | holds reset while a BIOS is missing; OSD info | 14m | KEEP/RS | keep `hold`; `info/info_req` have no M2M consumer, export the two flags instead |
| 17 | `reset_pending_notice` (`:1733-1740`) | "applied on reset" info after OSD close | 14m | DROP | needs OSD_STATUS + info box; export `reset_pending` as a flag if the OSM wants it |
| 18 | PS/2 input flops (`:1089-1127`) | 2-FF on negedge clk_chipset | chip | KEEP | |
| 19 | DIP switches / port C (`:1148-1164`) | video switches from EGA presence, floppy count from `fdd_present[1]` | comb | KEEP | |
| 20 | `cpu_address` latch (`:1172-1178`) | ALE latch | chip | KEEP | |
| 21 | `CHIPSET` (`:1180-1347`) | the whole machine minus CPU | chip (+vid28 inside) | KEEP/RS | re-source: `sdram_*` (3.7), `mgmt_*` (3.8), `uart2_*`/`midi_rx`/`spi_miso` tied idle, `use_mmc`=00 |
| 22 | `SDRAM_DQ` tristate (`:1355-1356`) | pin tristate | - | DROP | shim takes `dq_in/dq_out/dq_io` directly |
| 23 | `i8088` (`:1361-1394`) | MCL86 CPU | core | KEEP | |
| 24 | audio sum + clamp + compressor (`:1398-1482`) | section 5 | chip | KEEP/RS | `mt32_*_snd` become 0 |
| 25 | MIDI/UART clock enables (`:1502-1558`) | 12.5 MHz CE for MPU-401, 14.318/8 CE for COM2 | chip | KEEP | cheap; MPU-401 stays for games that probe 330h (menu can disable) |
| 26 | UART pin routing (`:1571-1583`, `:1601-1620`) | COM2 / HPS MIDI on `UART_*`, `USER_*` | comb | DROP | no such pins; tie `uart_rx/cts/dsr/dcd` = 1, `midi_rx` = 1 |
| 27 | `mt32pi` (`:1663-1696`) + attenuation (`:1698-1707`) | MT32-pi on the user port (`sys/mt32pi.sv`: MIDI TX/RX on USER[1]/[0], I2S in on USER[2,4,5], I2C on USER[0,3]) | CLK_AUDIO 24.576 MHz + ps | DROP | no user port; `mt32_available`=0, sounds = 0 |
| 28 | `use_mmc` latch (`:1718-1721`), SD SPI (`:1742-1745`) | second SD card via `KFMMC` | chip | DROP | tie `use_mmc`=2'b00 (MMC disabled, `Peripherals.sv:1582`), `spi_miso`=1 |
| 29 | OSD shadow regs (`:394-399`) | `scale/screen_mode/ar` into vid57 | vid57 | KEEP/RS | keep `screen_mode_video_ff`; `VIDEO_ARX/ARY`, `scale_video_ff` only if the hints are wanted |
| 30 | `ce_pixel` generators (`:1770-1809`, `:1838`) | dot/pixel toggles -> clock enables | vid57 | KEEP | `ce_pixel_28` branch is dead (`ega_scandouble_active`=0) |
| 31 | `LHBL/LVBL` (`:1859-1860`) | HBlank = `~de_o` for EGA, `HBlank` for mode 13h | comb | KEEP | |
| 32 | `video_monochrome_converter` (`:1869-1893`) | tint, 2-pixel latency (`video_monochrome_converter.sv:10-14`) | vid57 | KEEP | |
| 33 | bypass mux (`:1898-1905`) | mode-13h Full Color skips the converter | comb | KEEP | |
| 34 | `mode350/adots/alines` sync (`:1934-1944`) | feeds `fb_enable` only | vid57 | DROP | with 35 |
| 35 | `ega_fb_capture` / `ega_fb_readout` / `ega_ddr_arbiter` / `video_source_switch` (`:1958-2064`) | 350-line -> 480i/240p through DDRAM | vid57 | DROP | plan: no `MISTER_FB`; ascal handles 21.8 kHz. Muxes `:2066-2078` collapse to the bypass |
| 36 | `VGA_F1` (`:2082-2089`) | field flag for interlace | ps | DROP | |
| 37 | `video_mixer` (`:2092-2121`) | freeze, gamma, (bypassed) scandoubler, CE/DE cleanup | vid57 | REPLACE | M2M `av_pipeline`; nothing in it is core-specific |
| 38 | output retime `_src/_ps/_hdmi` (`:2124-2188`) | 57.27 -> 57.27+90 sampling for `sys_top` | vid57 -> ps | DROP | M2M samples video on `video_clk_o` itself |
| 39 | `jtframe_credits` (`:2200-2238`) + `VGA_DE_credits` (`:2240-2249`), `video_credits_show` (`:1851-1857`) | F12 pause/credits overlay, 4 pages, `msg.bin` + `font0.hex` | ps | KEEP (optional) | works on any pixel-CE domain; re-clock to clk_57_272 if kept |
| 40 | framework tie-offs (`:51-67`) | `ADC_BUS`, `VGA_SCALER/DISABLE`, `HDMI_*`, `LED_*`, `BUTTONS` | - | DROP | |

Counts: KEEP 16 (8,10,11,14,18,19,20,23,25,30,31,32,33,39 + the two trivially
kept latches counted in 13), KEEP/RS 9 (1,9,12,13,16,21,24,29,15), REPLACE 7
(2,3,4,5,6,7,37), DROP 10 (17,22,26,27,28,34,35,36,38,40).

---

## 3. Port plan for `pcxt_core.sv`

Flat vectors only (the VHDL side cannot see SV unpacked arrays). Names are
proposals; the "emu signal" column is the exact `PCXT-EGA.sv` net.

### 3.1 Clocks and resets in

| Port | Dir | W | emu signal | Note |
|---|---|---|---|---|
| `clk_core_i` | in | 1 | `clk_100` (`:499`) | MMCM B, related to `clk_chipset_i` (U6) |
| `clk_chipset_i` | in | 1 | `clk_chipset` (`:502`) | 50 MHz |
| `clk_video_base_i` | in | 1 | `clk_28_636` (`:511`) | |
| `clk_video_x2_i` | in | 1 | `clk_57_272` (`:512`) | pipeline / output domain |
| `clk_video_vga_i` | in | 1 | `clk_25_2` (`:514`) | mode-13h native |
| `clk_14_318_i` | in | 1 | `clk_14_318` (`:488,:547-550`) | from MMCM instead of the divider |
| `clk_video_out_ps_i` | in | 1 | `clk_video_out_ps` (`:513`) | only if #39 (credits) keeps its clock; otherwise omit |
| `pll_locked_i` | in | 1 | `pll_locked & pll_system_locked` (`:503,:515`) | both MMCM `locked` ANDed |
| `reset_i` | in | 1 | `RESET` (`emu_ports.vh:6`; `sys_top.v:601,:1759`) | framework/cold reset; also the only OSD-independent input to `reset_sdram_wire` (`:542`) |
| `reset_osd_i` | in | 1 | `status[0]` | one-cycle-or-longer pulse in `clk_chipset_i` |
| `reset_button_i` | in | 1 | `buttons[1]` | user reset key |
| `mt32_reset_i` | in | 1 | `status[40]` | drop with #27 |

The video clock mux output (`clk_card_video`, `:527`) is internal to the
wrapper (`BUFGMUX_CTRL` on `clk_video_base_i`/`clk_video_vga_i`, select
`vga_native_standard_clock`, `:519-521`).

### 3.2 Video out (see section 4 for what is behind each)

| Port | Dir | W | emu signal | Note |
|---|---|---|---|---|
| `video_clk_o` | out | 1 | `CLK_VIDEO_PIPELINE = clk_57_272` (`:1836`) | pass-through of `clk_video_x2_i`; M2M `video_clk_o` |
| `video_ce_o` | out | 1 | `ce_pixel_video` (`:1807-1809`) / `ce_pixel_mixer` (`:2073`) | one pulse per pixel in `video_clk_o` |
| `video_red_o`, `video_green_o`, `video_blue_o` | out | 8 each | `bypass_r/g/b` (`:1899-1901`) = `video_mixer_r/g/b` with the fb path removed | 8-bit because the tint converter outputs 8; the raw chipset value is 6-bit (`r,g,b`, `:1203-1205`). Expose `{r,2'b00}`/`{r,r[5:4]}` as-is |
| `video_hs_o`, `video_vs_o` | out | 1 | `bypass_hs/vs` (`:1902-1903`) | positive pulses (`video_mixer.sv:41`, `ega_top.v:1314-1323`) |
| `video_hblank_o`, `video_vblank_o` | out | 1 | `bypass_hb/vb` (`:1904-1905`) | active high |
| `video_de_o` | out | 1 | `~(hb\|vb)` | convenience |
| `video_mode13_o` | out | 1 | `vga_mode13_active_video` (`:1213`) | hint: 31.5 kHz native raster |
| `video_mode13_native_clk_o` | out | 1 | `vga_native_standard_clock` (`:519-521`) | hint: the 25.2 MHz clock is selected |
| `video_mode350_o` | out | 1 | `ega_mode350` (`:1341`) | hint: 350-line 21.8 kHz raster |
| `video_active_dots_o` | out | 12 | `ega_active_dots` (`:1342`) | vid28 domain, changes at vblank |
| `video_active_lines_o` | out | 10 | `ega_active_lines` (`:1343`) | |
| `video_std_hsyncwidth_o` | out | 1 | `std_hsyncwidth` (`:1199`) | unused inside `emu`; export or drop |
| `video_aspect_o` | out | 2 | `ar = status[9:8]` (`:372`) | only if the OSM aspect choice is applied by the wrapper |
| `video_scanlines_o` | out | 2 | `VGA_SL` (`:1841`) | only if M2M scanline emulation is wired |
| `video_vmode_toggle_o` | out | 1 | `ega_vmode_toggle` (`:1340`) | flips on a CRTC mode change; optional |

### 3.3 Audio out

| Port | Dir | W | emu signal |
|---|---|---|---|
| `audio_left_o`, `audio_right_o` | out | 16 | `AUDIO_L/R` (`:1479-1480`), signed (`AUDIO_S=1`, `:1481`), registered on `clk_chipset_i` |
| `audio_mix_o` | out | 2 | `AUDIO_MIX = status[39:38]` (`:1482`); only if the wrapper implements the 25/50/100 % cross-mix, else drop |

### 3.4 Keyboard, mouse, joysticks

| Port | Dir | W | emu signal | Note |
|---|---|---|---|---|
| `ps2_kbd_clk_i`, `ps2_kbd_data_i` | in | 1 | `ps2_kbd_clk_in/data_in` (`:428-429`) | from the lifted `ps2_device` |
| `ps2_kbd_clk_o`, `ps2_kbd_data_o` | out | 1 | `ps2_kbd_clk_out/data_out` (`:426-427`) | host->device (keyboard reset) |
| `ps2_key_i` | in | 11 | `ps2_key` (`:349`) | `{toggle,pressed,extended,code}`; only F12 break matters (`splash_f12_pause.sv:20,:30-31`) |
| `ps2_mouse_clk_i`, `ps2_mouse_data_i` | in | 1 | `ps2_mouse_clk_out/data_out` (`:431-432`) | |
| `ps2_mouse_clk_o`, `ps2_mouse_data_o` | out | 1 | `ps2_mouse_clk_in/data_in` (`:433-434`) | |
| `joy0_i`, `joy1_i` | in | 14 | `joy0/joy1` (`:363`) | bit map in 1.3 |
| `joya0_i`, `joya1_i` | in | 16 | `joya0/joya1` (`:364`) | `{Y[15:8], X[7:0]}` signed |

### 3.5 OSM option inputs (one per status field; all in `clk_chipset_i`, quasi-static)

| Port | W | status | Notes |
|---|---|---|---|
| `osm_cpu_speed_i` | 2 | 18:17 | |
| `osm_cpu_8086_i` | 1 | 63 | reset-applied |
| `osm_fake286_i` | 1 | 53 | |
| `osm_splash_off_i` | 1 | 7 | |
| `osm_bios_writable_i` | 2 | 31:30 | |
| `osm_audio220_i` | 2 | 29:28 | 0 CMS, 1 SB, 2 off |
| `osm_opl2_i` | 2 | 43:42 | |
| `osm_tandy_i` | 1 | 55 | |
| `osm_speaker_vol_i` | 2 | 33:32 | |
| `osm_audio_boost_i` | 2 | 37:36 | |
| `osm_stereo_mix_i` | 2 | 39:38 | pass to `audio_mix_o` |
| `osm_crt_h_i` | 4 | 49:46 | |
| `osm_crt_v_i` | 3 | 52:50 | |
| `osm_vsync_w_i` | 3 | 66:64 | |
| `osm_hsync_w_i` | 3 | 69:67 | |
| `osm_scandoubler_fx_i` | 2 | 2:1 | only `VGA_SL` survives; may drop |
| `osm_aspect_i` | 2 | 9:8 | hint only |
| `osm_display_i` | 3 | 16:14 | |
| `osm_vga13_tv_i` | 1 | 10 | |
| `osm_crt350_i` | 2 | 35:34 | drop with #35 |
| `osm_monitor_i` | 2 | 45:44 | reset-applied |
| `osm_ems_disable_i` | 1 | 5 | |
| `osm_umb_disable_i` | 1 | 12 | |
| `osm_joy1_i` | 2 | 24:23 | `[0]` digital, `[1]` disable |
| `osm_joy2_i` | 2 | 26:25 | |
| `osm_joy_sync_i` | 1 | 27 | |
| `osm_joy_swap_i` | 1 | 54 | |
| `osm_sb_irq7_i` | 1 | 70 | |
| `osm_mpu401_disable_i` | 1 | 56 | |
| `osm_floppy_wp_i` | 2 | 20:19 | |
| `osm_mmc_map_i` | 2 | 22:21 | drop; tie 0 |
| `osm_user_io_com2_i`, `osm_mt32_disable_i`, `osm_mt32_gm_i`, `osm_mt32_rom_i[1:0]`, `osm_mt32_sf_i[2:0]` | - | 6, 13, 41, 4:3, 62:60 | drop with #27 (tie `osd_mt32_gm`=0 in `xtegactl_resolve`) |

Status outputs for the OSM/help screen: `bios_missing_pcxt_o` (`:777`),
`bios_missing_ega_o` (`:778`), `reset_pending_o` (`:1729-1731`), `pause_o`
(`pause_core`, `:1335`), `splash_active_o` (`splashscreen`, `:1084`).

### 3.6 ROM download interface (BIOS / XTIDE / EGA BIOS)

Source side on MiSTer: `hps_io` with `WIDE=1` (`:407`): 16-bit data, `ioctl_addr`
advances by 2 per word (`hps_io.sv:149,:677,:688`), `ioctl_wr` one clk_chipset
pulse per word (`hps_io.sv:633`), `ioctl_download` high for the whole file,
`ioctl_index[5:0]` = slot (`FC0`=0, `FC2`=2, `FC3`=3), upper bits = extension
index (always 0 here). The wrapper ports mirror this exactly so the loader FSM
stays unchanged:

| Port | Dir | W | emu signal | Used as |
|---|---|---|---|---|
| `rom_download_i` | in | 1 | `ioctl_download` (`:354`) | level, whole file; `pcxt/ega_bios_download_active` (`:738,:762`) |
| `rom_index_i` | in | 8 | `ioctl_index[7:0]` (`:355`) | `select_pcxt = idx[5:0]==0 & addr[24:16]==0` (`:731`), `select_xtide = idx==2` (`:732`, full 8-bit compare), `select_ega_bios = idx[5:0]==3 & addr[24:16]==0` (`:733`) |
| `rom_wr_i` | in | 1 | `ioctl_wr` (`:356`) | one-cycle strobe; accepted only in loader state 01 (`:849-871`) |
| `rom_addr_i` | in | 25 | `ioctl_addr[24:0]` (`:357`) | byte offset in the file, even; only `[15:0]` (PCXT, EGA) or `[13:0]` (XTIDE) are used (`:780-783`) |
| `rom_data_i` | in | 16 | `ioctl_data` (`:358`) | little-endian word: `[7:0]` -> `addr`, `[15:8]` -> `addr+1` (`:866,:930-931`) |
| `rom_wait_o` | out | 1 | `ioctl_wait` (`:359`) | 1 = do not send the next word |

Target addresses (`:780-783`): PCXT `{4'b1111, addr[15:0]}` = F0000-FFFFF
(64 KB); XTIDE `{6'b111011, addr[13:0]}` = EC000-EFFFF (16 KB); EGA
`{4'b1100, addr[15:0]}` = C0000-CFFFF (64 KB). Anything else -> `20'hFFFFF`.

Chipset-side write path (what the FSM drives, all `clk_chipset`):
`bios_access_request` -> `CHIPSET.ext_access_request` (`:1218`),
`bios_access_address` -> `address_ext` (`:1217`), `bios_write_data[7:0]` ->
`data_bus_ext` (`:1227`), `bios_write_n` -> `memory_write_n_ext` (`:1243`),
`bios_protect_flag` -> `:1307`.

FSM (`:787-944`): waits for `initilized_sdram` (`:800-810`); state 00 idle,
enters 01 when `ioctl_download & ~processor_ready & address_direction`
(`:831`); 01 waits for `ioctl_wr` with a valid index (`rom_wait_o`=0 there),
latches word -> 02 (`memory_write_n_ext` low for 20 clocks, `:885-889`) ->
03 (64 clocks settle, `:901-909`) -> 04 (address+1, data>>8, byte toggle,
`:912-924`) -> 02 for the high byte -> 01. About 172 clocks per 16-bit word,
so a 64 KB ROM takes ~113 ms. `rom_wait_o` is 1 from acceptance until the FSM
is back in 01. The write protect is forced to 000 for the whole download and
restored from `osm_bios_writable_i` in state 00 (`:818,:844`).

"Loaded" latches: `rom_presence_latch` sets `loaded` on
`download_active & write_complete` (second byte of any word written,
`:739-740,:763-764`), clears it on the rising edge of `download_active` (new
file for that slot), on `reset_sdram` or while `~initilized_sdram`
(`rom_presence_latch.sv:17-34`). `bios_missing_pcxt = ~pcxt_loaded`,
`bios_missing_ega = pcxt_loaded & ~ega_loaded` (`:777-778`) ->
`bios_hold_notice.hold = ~splash_boot_phase & (missing_pcxt | missing_ega)`
(`bios_hold_notice.sv:40`) -> `splashscreen` (`:1084`) -> `reset_wire`
(`:529`). The CPU therefore never leaves reset until **both** the PCXT and EGA
ROMs have been written at least once since `reset_sdram`; XTIDE is optional.
The EGA latch also drives `ega_bios_write_protect` (= loaded) and the video DIP
switches `2'b00` (EGA) / `2'b10` (CGA) (`ega_bios_loaded_latch.sv:14-15`,
`:1161`).

### 3.7 Memory: what the KFSDRAM shim must present

Two levels exist; pick one (open question 7.1).

**(a) Pin level, outside `CHIPSET`** (keeps the submodule untouched). Ports of
`CHIPSET` (`Chipset.sv:145-159`), all in `clk_chipset`:

| Port | Dir | W | emu signal | KFSDRAM behaviour (`rtl/KFPC-XT/HDL/KFSDRAM/HDL/KFSDRAM.sv`) |
|---|---|---|---|---|
| `sdram_a_o` | out | 13 | `SDRAM_A` (`:1292`) | row on ACTIVE (`:309-329`), column = `address[8:0] + access_counter` on each READ/WRITE beat (`:343-344,:366-367`), A10=1 on PRECHARGE (`:379-380`) |
| `sdram_ba_o` | out | 2 | `SDRAM_BA` | always 0 in practice (`RAM.sv:432`: `access_address = {2'b00, ...}`) |
| `sdram_cke_o`, `sdram_ncs_o`, `sdram_nras_o`, `sdram_ncas_o`, `sdram_nwe_o` | out | 1 | `SDRAM_CKE/nCS/nRAS/nCAS/nWE` | standard SDRAM commands; init = 10000-clock wait, PALL, 2x CBR, MRS (`:76-95`) |
| `sdram_dq_out_o`, `sdram_dq_io_o` | out | 16, 1 | `SDRAM_DQ_OUT`, `SDRAM_DQ_IO` (`:1300-1301`, 0 = driving) | write data on the WRITE beat (`:352-353`) |
| `sdram_dq_in_i` | in | 16 | `SDRAM_DQ_IN` (`:1299`) | sampled while `state_counter > cas_latency`, CL = 2 (`:18,:413,:419`) |
| `sdram_dqml_o`, `sdram_dqmh_o` | out | 1 | `SDRAM_DQML/DQMH` (`:1302-1303`) | 0 during accesses, 1 in the RAM.sv idle branch (`RAM.sv:439-440,:499`) |
| `sdram_clk_o` | out | 1 | `SDRAM_CLK = clk_chipset` (`:56`) | |
| `initilized_sdram` | internal | 1 | `:1290` | set when KFSDRAM first reaches IDLE (`RAM.sv:413-420`); gates the loader and the ROM latches |

Timing parameters (`KFSDRAM.sv:12-21`): tRC 4, tRP 0, tMRD 1, tRCD 0, tDPL 1,
CL 2, refresh every >=100 clocks when `enable_refresh` (rising edge of the
bus's no-command state, `RAM.sv:303`) or forced at 400, i.e. ACTIVE, then the
column command on the very next clock, data expected 2 clocks after READ. A
BRAM backend fits inside CL=2; a variable-latency backend does not, because the
pin protocol has no wait state.

**(b) Command level, replacing `KFSDRAM` inside `RAM.sv`** (`RAM.sv:320-344`):

| Signal | Dir (shim view) | W | Meaning / RAM.sv contract |
|---|---|---|---|
| `sdram_clock`, `sdram_reset` | in | 1 | clk_chipset, `reset_sdram` (`RAM.sv:321-322`) |
| `address` | in | 24 | `{2'b00, decoded_address[21:0]}` (`RAM.sv:432,:443,:455,:467,:476`); `decoded_address` = `{2'b00, xt_addr[19:0]}` or EMS `{1'b1, page[6:0], xt_addr[13:0]}` (`RAM.sv:243-253`): 0x000000-0x0FFFFF conventional/UMB/ROM, 0x200000-0x3FFFFF the 128 x 16 KB EMS pages |
| `access_num` | in | 9 | 1 or 2 words (`RAM.sv:433`: 2 for the sequential-read lookahead or an 8086 word access); a 2-word burst never crosses column 511 (`RAM.sv:183`) |
| `data_in` | in | 16 | **only `[7:0]` carries data** (`RAM.sv:434-436`: `{8'h00, byte}`) |
| `data_out` | out | 16 | only `[7:0]` is read back (`RAM.sv:567,:594,:603`); second beat of a burst = byte at address+1 |
| `write_request` / `read_request` | in | 1 | levels while RAM.sv is in IDLE/RAM_WRITE_x/RAM_READ_x (`RAM.sv:437-438,:449-450,:461-462,:470-471`) |
| `enable_refresh` | in | 1 | pulse, may be ignored by a BRAM shim |
| `write_flag` | out | 1 | = "in WRITE state" (`KFSDRAM.sv:412`); RAM.sv waits for it to rise (`RAM_WRITE_1`, `RAM.sv:375-378`) then fall (`RAM_WRITE_2`, `:379-382`) |
| `read_flag` | out | 1 | one registered pulse per delivered word (`KFSDRAM.sv:413,:420`); RAM.sv captures `data_out[7:0]` on `read_flag & ~read_beat` (`:594`), high byte on the second pulse (`:567`), waits for the fall (`RAM_READ_2`, `:387-392`) |
| `idle` | out | 1 | = "in IDLE" (`KFSDRAM.sv:410`); RAM.sv waits for it after an aborted read (`WAIT`, `RAM.sv:399-402`) and uses its first assertion as `initilized_sdram` (`:413-420`) |
| `refresh_mode` | out | 1 | declared (`RAM.sv:318`) and not consumed |

Consequences for the backend: it is a **byte-wide** memory with a 22-bit
address (4 MB space, 1 MB + 2 MB used); a 16-bit SDRAM word holds one byte.
Reads must be held off (`READY` low) until `read_flag`: RAM.sv aborts a read
whose `MEMR` drops first (`RAM.sv:383-386`), which is safe only while the CPU is
in wait states. Regions the RAM never serves: A0000-BFFFF (`RAM.sv:226`), and
C4000-CFFFF unless UMB is on (`:227`).

### 3.8 mgmt bus

Six signals, `clk_chipset`, single-cycle strobes: `mgmt_addr[15:0]`,
`mgmt_dout[15:0]` (bridge -> core), `mgmt_din[15:0]` (core -> bridge),
`mgmt_wr`, `mgmt_rd`, `mgmt_req[7:0]` (`:451-457`, `:1313-1321`). Contract in
`docs/mgmt-bus-and-storage-regs.md` section 5.1; sequences in
`docs/arm-side-ide-floppy-behaviour.md` section 4. If the bridge lives inside
the wrapper, none of these are ports; if it lives in `main.vhd`, expose all six
plus `fdd_present[1:0]` (`:1319`).

### 3.9 LEDs and misc

| Port | emu signal | Note |
|---|---|---|
| `led_disk_o` | (none; `LED_USER=0`, `:67`, the `fdd_led` line is commented out `:68`) | suggest `|mgmt_req[7:6]` (FDD) or `|mgmt_req[2:0]` (IDE) |
| dropped outputs | `LED_POWER/DISK`, `BUTTONS`, `VGA_SCALER/DISABLE`, `HDMI_FREEZE/BLACKOUT/BOB_DEINT`, `VGA_F1`, `DDRAM_*`, `SD_*`, `UART_*`, `USER_*`, `ADC_BUS` (`:51-67`, `:1742-1745`, `:1573-1583`, `:1601`, `:2021-2050`, `:2089`) | |
| dropped inputs | `HDMI_WIDTH/HEIGHT` (unused in `emu`), `CLK_AUDIO`, `SD_MISO/CD`, `USER_IN`, `UART_RXD/CTS/DSR`, `OSD_STATUS` | |

---

## 4. Video output detail

### 4.1 What leaves `CHIPSET` (`:1198-1215`, `:1335-1343`)

| Signal | W | Domain | Origin | Meaning |
|---|---|---|---|---|
| `r,g,b` (`VGA_R/G/B`) | 6 | `clk_card_video` | `Peripherals.sv:1218-1220` <- `ega_top` DAC | 6-bit RGB for every mode (EGA palette, mode-13h DAC, 5151 luma) |
| `HSync`, `VSync` | 1 | vid28 | `ega_top.v:1314-1323` | positive pulses; 1 while the EGA is disabled |
| `HBlank`, `VBlank` | 1 | vid28 | `ega_top.v:1318-1326` | active high; EGA path = CRTC blanking, mode 13h = the private raster's |
| `VGA_VBlank_border` | 1 | vid28 | `ega_top.v:1327-1329` | vertical border; **not used** by `emu` (`:392`) |
| `de_o` | 1 | vid28 | `ega_top.v:1333-1335` | display enable; used as HBlank source for EGA modes (`:1859`) |
| `std_hsyncwidth` | 1 | vid28 | `ega_top.v:1330-1332` | CRTC HSYNC width equals the standard for the current dot clock; **not used** by `emu` (`:391`) |
| `vga_mode13_active_video` | 1 | vid28 | `Peripherals.sv:1367` | private VGA raster active (mode 13h / planar-16 / unchained) |
| `vga_mode13_wide_clock` | 1 | vid28 | `ega_top.v:1295` | 360x200 needs the 28.636 MHz clock even in Native |
| `vga_mode13_pixel_toggle` | 1 | vid28 | `ega_top.v:911-915,:1299` | flips once per source pixel |
| `ega_dot_toggle` | 1 | vid28 | `ega_dot_clock.v:40` | flips once per EGA dot (14.318 or 16.257 MHz) |
| `ega_dot_clock_sel` | 1 | vid28 | `ega_top.v:1338` | 1 = 16.257 MHz; **not used** by `emu` (`:213`) |
| `ega_scandouble_active` | 1 | const | `ega_top.v:1050` | **hard-wired 0** |
| `ega_vmode_toggle` | 1 | vid28 | `ega_top.v:1239` | flips on a CRTC mode change |
| `ega_mode350`, `ega_active_dots[11:0]`, `ega_active_lines[9:0]` | | vid28 | `ega_top.v:1383-1391` | >240 active lines and not the private VGA raster; geometry, updated at vblank |
| `pause_core` | 1 | chip | `KFPS2KB.sv:251-256` | F12 break toggles it |

### 4.2 What `emu` does before `video_mixer`

1. **Clock enable** (`:1770-1809`): `ce_pixel_dot = toggle_d ^ toggle_dd` from
   `ega_dot_toggle` (one sync stage before the XOR, `:1773-1789`);
   `ce_pixel_mode13` the same from `vga_mode13_pixel_toggle` (`:1791-1806`);
   `ce_pixel_28 = clk_57_272/2` (`:1838`) only for the dead scandoubler branch.
   `ce_pixel_video = scandouble ? ce_pixel_28 : mode13 ? ce_pixel_mode13 :
   ce_pixel_dot` (`:1807-1809`).
2. **Blank selection** (`:1859-1860`): `LHBL = (scandouble || mode13) ? HBlank :
   ~de_o`; `LVBL = VBlank`. So EGA/CGA/MDA modes use the display enable as
   HBlank and the chipset's `HBlank` output is ignored there.
3. **Monochrome converter** (`:1869-1893`): RGB widened to `{x,2'b00}`, tint by
   `screen_mode_video_ff`, sync/blank delayed two `ce_pix` with the colour.
4. **Bypass** (`:1898-1905`): mode 13h in Full Color takes the undelayed raw
   signals with RGB `{x, x[5:4]}` (note the two paths scale 6->8 bits
   differently: max 0xFC vs 0xFF).
5. **350-line framebuffer** (`:1927-2078`): `fb_enable = mode350 & status[35:34]!=0`;
   capture after the converter into DDRAM (`ega_fb_capture`), read back as
   720x480i or 240p at 14.318 MHz (`ce_pix = clk_57_272/4`,
   `ega_fb_readout.v:112-122`), switched in during the destination's vblank
   (`video_source_switch`). Muxed into `video_mixer_*` (`:2066-2073`). DROP.
6. **`video_mixer`** (`:2092-2121`, `sys/video_mixer.sv`): `HDMI_FREEZE`
   freezer, `gamma_corr` (OSD gamma table), `scandoubler`/`hq2x` **bypassed**
   (`scandoubler=0`), then `CE_PIXEL <= ce_pix` (or its rising edge if the
   input CE is a level, `video_mixer.sv:179-188`), RGB/HS/VS registered on
   CE, `VGA_DE` updated on `hde` edges (`:206-216`).
7. **Retime** (`:2124-2188`): registered once on `clk_57_272`, then on
   `clk_video_out_ps`, and finally re-registered on the rising edge of
   `CE_PIXEL` (`:2159-2170`) so the framework sees one clean sample per CE.
8. **Credits** (`:2200-2249`): `jtframe_credits` overlays 4 pages of text on
   `CE_PIXEL` when `video_credits_show = pause_core | splash_paused`
   (`:1854-1857`), `VGA_DE` re-registered on CE (`:2240-2247`).

Aspect and scanlines: `VIDEO_ARX/ARY` per `status[9:8]` (`:396-397`, table in
1.2); `VGA_SL` from `status[2:1]` (`:1841`). `sys_top` consumes both
(`sys_top.v:1786-1788`). There is no `video_freak`/`video_cleaner` inside `emu`;
those live in `sys_top`.

### 4.3 What must survive on MEGA65, and `video_ce` per mode

Keep steps 1-4 exactly (the M2M `av_pipeline` wants RGB + HS/VS + HBlank/VBlank
+ a pixel CE in one clock, and ascal re-times everything). Drop 5-7. Step 8 is
optional. Output on `clk_57_272`:

| Mode | `clk_card_video` | Raster | `video_ce_o` source | CE rate / pattern in clk_57_272 |
|---|---|---|---|---|
| CGA/EGA 200-line, splash, BIOS hold | 28.636 | 15.7 kHz, 640 dots | `ce_pixel_dot` (div-2 dot clock, `ega_dot_clock.v:55`) | 14.318 MHz, every 4th clock |
| EGA 350-line, MDA (`ega_dot_clock_sel`=1) | 28.636 | 18.4-21.8 kHz, 640/720 dots | `ce_pixel_dot` (NCO 59609/105000, `ega_dot_clock.v:15,:28-29`) | 16.257 MHz average, 3- or 4-clock spacing, line-locked |
| Mode 13h TV 60 Hz (`status[10]`=1) | 28.636 | 15.7 kHz, 1824-clock line (`vga_mode13_timing.v:7-18`) | `ce_pixel_mode13` (toggle every 2 clocks) | 14.318 MHz, every 4th clock; 640x200 measured |
| Mode 13h Native 320x200 | **25.2** | 31.47 kHz / 70 Hz, 800-clock line, 400 lines (`vga_mode13_timing.v:65-83`) | `ce_pixel_mode13` (toggle every 2 clocks) | 12.6 MHz, **asynchronous** to 57.27 (only the 2-FF+XOR bridges it, clocks doc S12) |
| Mode 13h Native wide 360x200 | 28.636 | 31.4 kHz, 912-clock line (`vga_mode13_timing.v:72-76`) | `ce_pixel_mode13` | 14.318 MHz, every 4th clock |

Blanking per mode: EGA family uses `~de_o`; the mode-13h rasters use the
chipset `HBlank`. All modes use `VBlank`.

Hints worth exporting because ascal's auto-detect cannot see them:
`video_mode13_o` (31 kHz vs 15/21 kHz), `video_mode13_native_clk_o` (the
video clock just switched), `video_mode350_o`, `video_active_dots/lines_o`.

---

## 5. Audio

Sum (`:1453-1475`, `clk_chipset`, 17-bit signed):

```
tmp = jtopl2_snd + cms_{l,r}_snd + tandy_snd + spk_vol + mt32_{l,r}_snd + sb_{l,r}_snd
```

| Term | Source | Width/scale |
|---|---|---|
| `jtopl2_snd` | `CHIPSET.jtopl2_snd_e` (`:1266`), OPL2 when Adlib-only; 0 when the SB owns the FM (`:1407-1410`) | 16-bit signed, sign-extended |
| `cms_l/r_snd` | `CHIPSET.o_cms_l/r` (`:1275-1276`) | 16-bit signed |
| `sb_l/r_snd` | `CHIPSET.sb_snd_l/r` (`:1272-1273`), DAC + FM after the CT1345 mixer | 16-bit signed |
| `tandy_snd` | `CHIPSET.tandy_snd_e[10:0]` (`:1267`) sign-extended to 17, `<< status[33:32]`, then `<< 2` (`:1423-1425`) | |
| `spk_vol` | `{2'b00, {3'b000, ~speaker_out} << status[33:32], 11'd0}` (`:1426`) = 0 or `2^(11+vol)`; unipolar, so the beeper carries a DC offset | |
| `mt32_l/r_snd` | I2S from `mt32pi`, -6 dB (`:1698-1707`); 0 unless `mt32_use` | drop -> 0 |

Then clamp to 16 bits (`:1459,:1473`), and an optional compressor `compr()`
(`:1429-1449`): Audio Boost 2x uses `f=4,a=2` (knee `comp_x1` = 14044, gain 2
below the knee, 1/4 above, `comp_b1` = 28088); 4x uses `f=8,a=4` (knee 7399,
gain 4 / 1/8, `comp_b2` = 29596). `AUDIO_L/R = pause_core ? 0 : boost ? cmp :
out` (`:1479-1480`). Sample rate = one update per `clk_chipset` (50 MHz);
`AUDIO_S = 1` = signed (`:1481`); `AUDIO_MIX = status[39:38]` = framework
cross-mix 0/25/50/100 % (`emu_ports.vh:86`, `sys/audio_out.sv:281-343`).

Framework low-pass (not in `emu`; `sys_top.v:339-347`, reloadable from
MiSTer.ini via command 0x39, `:386-395`): `audio_out` (`sys/audio_out.sv`)
resamples to 48 kHz (`AUDIO_RATE=48000`, `:66`; 96 kHz when `sample_rate`=1)
and runs a second-order IIR at `flt_rate` = 7 056 000 Hz with
`cx = 4258969`, `cx0 = 3`, `cx1 = 3`, `cx2 = 1`, `cy0 = -6216759`,
`cy1 = 6143386`, `cy2 = -2023767` (40-bit/24-bit fixed point,
`audio_out.sv:33-40,:204-221`). Copy these if the M2M side wants the same
roll-off; the core itself needs none of it.

---

## 6. Reset tree

| Reset | Expression (line) | Domain / stretch | Resets |
|---|---|---|---|
| `RESET` | framework input (`emu_ports.vh:6`; `sys_top.v:601`, HPS `reset_core_req`) | async | everything below |
| `reset_wire` | `RESET \| status[0] \| buttons[1] \| !pll_locked \| !pll_system_locked \| splashscreen \| splash_pending` (`:529`) | async set | `reset` |
| `reset` | set async by `reset_wire`, released after 65535 clk_chipset (1.31 ms) (`:591-620`) | chip | `clk_select` (`:564`), `XT_CE_Generator` (`:575`), monitor/CPU-type latches (`:628,:635`, they *track* while it is high), `reset_cpu_ff/reset_cpu` (`:654-687`), PS/2 input FFs (`:1092,:1113`), `use_mmc` latch (`:1719`) |
| `reset_cpu` | `reset` re-sampled on negedge clk_chipset, released 42 negedges after `reset` (`:650-687`) | chip (negedge) | `CHIPSET.reset` (`:1188`), `i8088.RESET` (`:1366`) |
| `video_retime_reset` | same as `reset_wire` **without** `splashscreen` (`:530`) | async | `CHIPSET.video_reset` (`:1189`) -> `Peripherals.sv:206-231` 2-FF chains into `clock` and `clk_video` -> `ega_top.reset`, EGA I/O synchronisers; fb capture/readout/arbiter/switch (`:1960,:1996,:2025,:2057`); `video_retime_reset_sync` (`:531-541`, async assert, 2-FF release on `clk_video_out_ps`) -> `video_retime_reset_local` -> output retime regs (`:2138`), `jtframe_credits.rst` (`:2210`), `VGA_DE_credits` (`:2241`) |
| `reset_sdram_wire` | `RESET \| !pll_locked` (`:542`) | async set | `reset_sdram` |
| `reset_sdram` | 65535-clock stretch (`:689-716`) | chip | `CHIPSET.sdram_reset` (`:1190`) -> `RAM.sv` FSM and `KFSDRAM` re-init; BIOS loader FSM (`:787`); `rom_presence_latch` x2 (`:748,:768`) |
| `splash_pending` | init 1; cleared when `splash_off`=0 starts the timed splash, or after 1 s (`:951,:976-987`) | 14m | part of `reset_wire` and `video_retime_reset` |
| `splash_timed` | 5 s (5 x 14318000 clocks) unless `splash_off` or `splash_paused` holds it (`:993-1010`) | 14m | `splashscreen` |
| `bios_hold` | `~(splash_pending \| splash_timed) & (missing_pcxt \| missing_ega)` (`bios_hold_notice.sv:40`, `:1067-1075`) | comb | `splashscreen` |
| `splashscreen` | `splash_timed \| bios_hold` (`:1084`) | | `reset_wire`; `CHIPSET.splashscreen` (`:1198`, draws the splash picture) |
| `mt32_reset` | `status[40] \| RESET \| status[0] \| buttons[1]` (`:1636`) | | `mt32pi` only |
| `phys_reset_hold` | `RESET \| buttons[1]`, 0.2 s (`:953-972`) | 14m | **nothing** (dead) |
| warm boot | `keyboard_warm_reset` (Ctrl+Alt+Del, `Peripherals.sv:582-589`) resets the OPL2 (`:642`); `warm_boot_marker_detector` (1234h at 0040:0072, `Chipset.sv:378-387`) clears the VGA 13h+ enable (`Peripherals.sv:1118`) | chip | internal to CHIPSET, no top-level part |
| `pause_core` | F12 (`KFPS2KB.sv:251-256`) | chip | not a reset: gates `i8088.READY` (`:1367`), mutes audio (`:1479`), shows credits (`:1855`) |

Observations that matter for the wrapper:

* Video keeps running through the splash and the BIOS hold because
  `video_retime_reset` excludes `splashscreen`; the CPU/chipset do not.
* `reset_sdram` is independent of the OSD reset and the splash. On MiSTer the
  ROM latches survive a warm reset and the ROMs are only re-sent at core load.
  On MEGA65, `reset_i` (the only OSD-independent input) must be asserted **only
  at power-on/core load**, or the ROMs must be re-streamed after every reset.
* The `reset` stretch (1.31 ms) is what lets `cpu_type_latch`,
  `ega_monitor_profile_latch` and `use_mmc` settle after the OSM values arrive.

---

## 7. Open questions for the wrapper author

1. **Memory shim level.** Pin-level SDRAM emulation (3.7a) keeps `RAM.sv`
   untouched but has no wait-state mechanism (CL=2, tRCD=0), so it only fits
   the BRAM backend. The command-level replacement (3.7b) supports HyperRAM
   but the replacement `KFSDRAM` has no port to the backend without touching
   `RAM.sv` (its only outputs are the SDRAM pins). Decide: overlay copy of
   `RAM.sv` with an Avalon port, a `KFSDRAM`-named module that repurposes the
   pin outputs, or pin-level for Phase 3 and revisit in Phase 6.
2. **Byte-per-word memory.** `RAM.sv` stores one byte in each 16-bit SDRAM word
   (`RAM.sv:434-436,:567,:594`). The BRAM backend can be 8 bits wide (4 MB space,
   ~1 MB needed without EMS); confirm the plan's "832 KB" census assumed this.
3. **Video output domain.** Keep the upstream `clk_57_272` pipeline with the
   toggle-XOR CE (asynchronous in mode-13h Native 25.2 MHz), or drive M2M's
   `video_clk_o` straight from `clk_card_video` with `ce_dot`/pixel enables
   from inside `ega_top`? The latter avoids the async crossing but changes the
   clock at runtime (BUFGMUX) and needs the tint converter moved into that
   domain. Does the M2M `av_pipeline`/ascal tolerate a switching pixel clock?
4. **Mode-13h Native (31.5 kHz, 70 Hz) on HDMI/VGA.** ascal will re-time it;
   confirm the analog VGA path (M2M scandoubler expectations) handles a
   31.47 kHz input, or force `osm_vga13_tv_i` on the VGA output.
5. **Dead menu items.** Scandoubler Fx HQ2x and `forced_scandoubler` do nothing
   (1.2, bits 2:1); CRT 25/50 % only set `VGA_SL`. Keep a "Scanlines" OSM item
   wired to M2M's own scanline option, or drop the field.
6. **PS/2 host-to-device traffic.** The chipset sends keyboard reset (port B
   bit 6) and `MSMouseWrapper` initialises the mouse; on MiSTer the ARM answers.
   `keyboard.vhd` / the mouse packetiser must reply (0xFA ACK, 0xAA BAT, mouse
   ID 0x00) or `KFPS2KB`/`MSMouseWrapper` may wait forever. Verify by reading
   `KFPS2KB_Send_Data.sv` and `MSMouseWrapper.v`.
7. **`ps2_key` for the splash F12.** Provide the `{toggle,pressed,ext,code}`
   stream (needs set-2 codes from `keyboard.vhd`) or replace `splash_f12_pause`
   with a MEGA65 key event; the legend drawn on the splash says F12.
8. **Info notices.** `bios_hold_notice` and `reset_pending_notice` need an OSD
   info box. Options: OSM help-screen text driven by `bios_missing_*_o`, a
   blinking LED, or nothing (the splash stays on screen, which is the visible
   symptom anyway).
9. **Reset policy.** Which M2M signals map to `reset_i` (cold only) vs
   `reset_osd_i`/`reset_button_i` (warm), given observation 2 in section 6.
10. **Aspect/scanline hints.** Whether to expose `video_aspect_o`/`VGA_SL` at
    all or let the M2M OSM own aspect ratio and scanlines outright.
11. **Credits overlay.** Keep `jtframe_credits` (needs `msg.bin`, `font0.hex`,
    `clk_video_out_ps` or a re-clock to `clk_57_272`) or drop F12 credits and
    keep only the pause.
12. **MPU-401 with nothing behind it.** With MT32-pi and HPS MIDI gone the
    MPU-401 UART transmits into the void; keep it enabled by default (games
    that probe 330h) or default `osm_mpu401_disable_i` = 1 so they fall back
    to Adlib.
13. **Unused chipset outputs.** `std_hsyncwidth`, `ega_dot_clock_sel`,
    `VGA_VBlank_border` are produced and never read in `emu`; leave them
    unconnected or export as hints.
