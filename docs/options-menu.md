# Options menu (Help key)

Main menu: Drive A, Drive B, Hard Disk, four submenus, the framework's HDMI
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
| Input | Joystick 1 / Joystick 2 | `osm_joy1_i` / `osm_joy2_i` | MEGA65 ports 1 and 2 on the game port at 201h, digital mode |
| Input | Swap joysticks | `osm_joy_swap_i` | |
| Input | Write-protect A: / B: | `osm_floppy_wp_i` | in addition to a read-only image |

Sound Blaster (DSP at 220h, DMA 1) is always present; "Sound Blaster FM"
only chooses where the FM chip answers. Game Blaster (C/MS) is not exposed.

## Remembering settings

The framework saves menu choices to `/m2m/m2mcfg` on the SD card, but only
if that file already exists and is exactly `OPTM_SIZE` (82) bytes. A file of
82 bytes of 0xFF means "use the defaults". `sdcard/m2m/m2mcfg` in this repo
is that file; copy the `m2m` folder next to `pcxt`. Regenerate it whenever
the menu changes size:

```
cd M2M/tools && ./make_config.sh <path>/m2m/m2mcfg 82
```

The firmware prints "Config file not found" or "corrupt config file" in the
serial log when it falls back to defaults.
