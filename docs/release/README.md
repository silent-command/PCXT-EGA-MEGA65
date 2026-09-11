# PCXT-EGA for MEGA65

An IBM PC/XT with an EGA card on the MEGA65 R6: 8088 or 8086 CPU at 4.77,
7.16, 9.54 MHz or unthrottled, 640 KB of RAM plus upper memory and 2 MB of
EMS, floppy and hard disk images from the SD card, Adlib, Sound Blaster,
Tandy and PC speaker sound, and the MEGA65 keyboard and joysticks.

Ported from [MiSTer-devel/PCXT-EGA_MiSTer](https://github.com/MiSTer-devel/PCXT-EGA_MiSTer)
with the [MiSTer2MEGA65](https://github.com/sy2002/MiSTer2MEGA65) framework.
MEGA65 port by silent-command. GPL v3, see LICENSE.

## Install

1. Flash `pcxt-ega-r6.cor` into a core slot: hold **No Scroll** while
   powering on, pick an empty slot, choose the file from the SD card.
2. Copy the `m2m` and `pcxt` folders to the **root** of the SD card, next to
   each other. `m2m/m2mcfg` makes the menu remember your settings.
3. Put the two remaining files into `/pcxt` (they are not included, see
   `pcxt/README.txt`): `ega_bios.rom` (required) and a hard disk image such
   as `freedos.vhd`.
4. Start the core. Press **Space** on the welcome screen. Press **Help**,
   mount your hard disk image under "Hard Disk", close the menu, press
   **Ctrl+Alt+Del**. XTIDE lists the drive and boots it.

Floppy images (`.img` or `.ima`, 160 KB to 1.44 MB raw) mount under "Drive A"
and "Drive B" at any time, also while DOS is running. A bootable floppy image
in Drive A boots with Ctrl+Alt+Del when no hard disk is mounted, or from the
XTIDE boot menu (F2) otherwise.

## The menu (Help key)

| Line | What it does |
|---|---|
| Drive A, Drive B, Hard Disk | mount an image; select the line again to eject |
| CPU | 4.77 / 7.16 / 9.54 MHz / Max; 8086 CPU (takes effect at the next reset); 286 speedup |
| HDMI | output mode: 720p 50/60, 576p, 640x480, 720x480, 800x600 |
| Sound | Adlib / Sound Blaster FM / none; Tandy sound; Sound Blaster on IRQ 7 (default IRQ 5); PC speaker volume; boost |
| Display | monitor the EGA card drives (5154 EGA, 5153 CGA, 5151 mono; at reset); tint (color, green, amber, black and white); VGA connector: 31 kHz for VGA monitors, 15 kHz or 15 kHz + composite sync for CRTs and SCART |
| Input | joystick 1 and 2 (MEGA65 ports, digital), swap; write-protect A: / B:; mouse off / 1351 / Amiga (port 1) |
| HDMI: CRT emulation, Zoom-in, Audio improvements | framework video and audio options |

Settings are saved when the menu closes, if `/m2m/m2mcfg` exists.

## Keyboard

The MEGA65 keys type what they say, on a US PC layout. Keys the MEGA65
lacks:

| PC key | MEGA65 |
|---|---|
| `[` `]` | Shift+: Shift+; |
| `{` `}` | Shift+@ Shift+* |
| `#` `\` | Pound, Shift+Pound |
| `` ` `` `~` | Arrow-left, shifted |
| `^` `\|` | Arrow-up, shifted |
| F2 to F12 | Shift+F1 to Shift+F11 |
| Insert / Delete | Shift+INS/DEL, MEGA+INS/DEL |
| Alt / AltGr | MEGA / ALT |
| Esc | RUN/STOP or ESC |
| Ctrl+Alt+Del | CTRL + MEGA + INS/DEL |

## Known limitations

- The Turbo XT BIOS has no high-density floppy support: 1.44 MB and 1.2 MB
  images mount but DOS reports "drive not ready" on them. Use 360 KB or
  720 KB images, or a BIOS with high-density support.
- Mouse: a Commodore 1351 or an Amiga mouse in joystick port 1 appears as a
  Microsoft serial mouse on COM1 when enabled in Input Settings; load a
  serial mouse driver such as CTMOUSE in DOS. USB mice are not supported.
- One hard disk image at a time; the second SD card slot is not used.
- The optional `/pcxt/xtide.rom` is not needed: XTIDE is inside `pcxt.rom`.
  The startup log line "LOADING ROM #0002: FAILED" refers to it and is harmless.

## Source

https://github.com/silent-command/PCXT-EGA-MEGA65 (docs/ has the port's design notes).
