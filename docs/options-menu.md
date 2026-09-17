# Options menu (Help key)

Main menu: Drive A, Drive B, Hard Disk, six submenus, the framework's HDMI
toggles, Help, Close. Menu line numbers are the option bits decoded in
`CORE/vhdl/main.vhd` (core options) and `CORE/vhdl/mega65.vhd` (framework
options, `C_MENU_*`). Change `config.vhd` and both decoders together.

| Submenu | Items | Core input | Notes |
|---|---|---|---|
| CPU | 4.77 / 7.16 / 9.54 MHz / Max | `osm_cpu_speed_i` | live |
| CPU | 8086 CPU | `osm_cpu_8086_i` | applied at the next reset |
| CPU | 286 speedup | `osm_fake286_i` | faster string ops; not cycle exact |
| HDMI | 7 output modes | framework | framework `C_MENU_HDMI_*` |
| Sound | Adlib / Sound Blaster FM / No FM synth | `osm_opl2_i` | OPL2 at 388h; SB FM adds 228h |
| Sound | Tandy sound | `osm_tandy_i` | SN76489 at C0h |
| Sound | Sound Blaster IRQ 7 | `osm_sb_irq7_i` | off = IRQ 5 (default for most software) |
| Sound | Speaker: Low / Medium / High / Max | `osm_speaker_vol_i` | PC speaker level |
| Sound | Boost: None / 2x / 4x | `osm_audio_boost_i` | overall gain |
| Display | EGA 5154 / CGA 5153 / Mono 5151 | `osm_monitor_i` | monitor the EGA card thinks it drives; applied at reset |
| Display | Full color / Green / Amber / Black and white | `osm_display_i` | tint |
| Display | VGA: 31 kHz / 15 kHz / 15 kHz + CSync | framework analog pipeline via `analog_video_ctl` | 31 kHz scandoubles the 200-line modes for VGA monitors (off in mode 13h); 15 kHz is the native raster for CRTs and SCART, also selects the 60 Hz TV raster for mode 13h; 350-line EGA modes stay 21.8 kHz either way. See docs/analog-video.md |
| Input | Joystick 1 / Joystick 2 | `osm_joy1_i` / `osm_joy2_i` | MEGA65 ports 1 and 2 on the game port at 201h, digital mode |
| Input | Swap joysticks | `osm_joy_swap_i` | |
| Input | Write-protect A: / B: | `osm_floppy_wp_i` | in addition to a read-only image |
| Input | Mouse: Off / C1351 / Amiga | `m65_mouse_ps2` -> core PS/2 mouse -> serial mouse on COM1 | a Commodore 1351 (proportional mode) or an Amiga/Atari ST mouse in joystick port 1; use CTMOUSE or another serial mouse driver in DOS |
| Network | Off / IRQ 5 / IRQ 7 (default IRQ 5) | `osm_eth_enable`, `osm_eth_irq7` -> `pcxt_core` `ne1000_en_i`, `ne1000_irq7_i` | the NE1000 at port 320h (docs/ethernet.md). Off: the port reads FFh like an empty slot and no interrupt is raised. The card is also held off until the firmware has delivered its MAC (`rom_loader.vhd` `eth_mac_valid_o`). IRQ 5 and IRQ 7 are the two lines the Sound Blaster can sit on ("Sound Blaster IRQ 7" off/on); the XT's 8259 is edge-triggered, so give the card the line the SB is not using. Packet driver: `NE1000 0x60 5 0x320` or `NE1000 0x60 7 0x320`; live |

Sound Blaster (DSP at 220h, DMA 1) is always present; "Sound Blaster FM"
only chooses where the FM chip answers. Game Blaster (C/MS) is not exposed.

Menu line numbers (the bit numbers) are listed above `OPTM_ITEMS` in
config.vhd; the framework toggles moved from lines 83..85 to 91..93 when the
Network submenu (lines 82..89) was added, and `C_MENU_*` in mega65.vhd moved
with them. Group ids are `OPTM_G_NETWORK` = 22, the three after it renumbered.

## Remembering settings

The framework saves menu choices to `/m2m/m2mcfg` on the SD card, but only
if that file already exists and is exactly `OPTM_SIZE` bytes (see config.vhd;
the release script generates it). OPTM_SIZE is 98 since the Network submenu
(it was 90): a card carrying the old 90-byte file gets "corrupt config file"
in the serial log and no settings are saved until the file is replaced. A file of OPTM_SIZE bytes of 0xFF means "use the defaults". `sdcard/m2m/m2mcfg` in this repo
is that file; copy the `m2m` folder next to `pcxt`. Regenerate it whenever
the menu changes size:

```
cd M2M/tools && ./make_config.sh <path>/m2m/m2mcfg auto
```

The firmware prints "Config file not found" or "corrupt config file" in the
serial log when it falls back to defaults.

## Framework fix: settings save hung with more than one virtual drive

`M2M/rom/options.asm` `ROSM_SAVE` loops over the virtual drives to check
their dirty flags before writing the settings file. `VD_DRV_READ` returns
the flag in R8, the same register that held the drive number, so with no
drive dirty R8 became 1 after every iteration and the loop never reached
the drive count of 3: the firmware spun forever at the first menu close
once `/m2m/m2mcfg` existed (Help dead, no log line, disk requests unserved,
XTIDE "Error 80h"). Cores with a single drive never hit it. The port keeps
the drive number in R1 across the call. Upstream master (checked
2026-09-09) still has the clobber; report it.
