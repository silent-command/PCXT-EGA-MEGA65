# PCXT-EGA for MEGA65

An IBM PC/XT with an EGA card on the MEGA65 R6: 8088 or 8086 CPU at 4.77,
7.16, 9.54 MHz or unthrottled, 640 KB of RAM plus upper memory and 2 MB of
EMS, floppy and hard disk images from the SD card, **the MEGA65's own 3.5"
floppy drive as A: - real disks, read, write and `FORMAT`**, Adlib, Sound
Blaster, Tandy and PC speaker sound, an NE1000 Ethernet card on the MEGA65's
network port, and the MEGA65 keyboard, joysticks and mouse.

Ported from [MiSTer-devel/PCXT-EGA_MiSTer](https://github.com/MiSTer-devel/PCXT-EGA_MiSTer)
with the [MiSTer2MEGA65](https://github.com/sy2002/MiSTer2MEGA65) framework.
MEGA65 port by silent-command. GPL v3, see LICENSE.

## Install

1. Flash `pcxt-ega-r6.cor` into a core slot: hold **No Scroll** while
   powering on, pick an empty slot, choose the file from the SD card.
2. Copy the `m2m` and `pcxt` folders to the **root** of the SD card, next to
   each other. `m2m/m2mcfg` makes the menu remember your settings. **Replace
   an existing `m2m/m2mcfg` with this release's copy**: the menu grew with
   the "A: internal drive" line and the file must match its size, otherwise the
   core logs "corrupt config file" and stops saving settings (nothing else
   breaks).
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
| Input | joystick 1 and 2 (MEGA65 ports, digital), swap; write-protect A: / B:; **A: internal drive** (the MEGA65's own floppy drive, see below); mouse off / 1351 / Amiga (port 1) |
| Network | NE1000 Ethernet card at port 320h: Off / IRQ 5 (default) / IRQ 7 |
| HDMI: CRT emulation, Zoom-in, Audio improvements | framework video and audio options |

Settings are saved when the menu closes, if `/m2m/m2mcfg` exists.

## The internal floppy drive

Switch on **"A: internal drive"** in Input Settings and drive A: becomes the
MEGA65's own 3.5" drive instead of an image from the SD card. Real PC disks
are read and written, and `FORMAT A: /U` formats a blank or foreign disk into
a standard 1.44 MB PC disk that any PC reads.

* 1.44 MB (HD) and 720 KB (DD) disks are detected automatically from the disk
  itself. A disk with its write-protect tab open mounts read-only, and DOS
  reports "write protect error" as it would on a real PC.
* The drive is only touched when DOS uses it, so it is silent when idle. An
  empty drive answers "Not ready" at once; insert a disk and press **R** for
  Retry and it is picked up (about 1.5 s).
* Booting from a real disk works: with no hard disk mounted, Ctrl+Alt+Del boots
  drive A:, or pick it from the XTIDE boot menu (F2).
* `FORMAT A:` alone is not enough on a disk that already holds files: DOS then
  does a quick format, which only rewrites the directory. Use `FORMAT A: /U`
  for a real format.
* A **blank or unreadable disk mounts as 1.44 MB** so that `FORMAT` can reach
  it. A blank 720 KB disk therefore cannot be formatted as 720 KB; use a
  720 KB disk that already holds a PC filesystem, or format it on a PC.
* An **unrecoverable read or write error parks drive A:** until the core is
  reset (the emulated controller cannot be told about disk errors). Reads
  recover by themselves on Retry; a failed write needs the reset button.
* Drive B: and the hard disk are unaffected and keep using SD card images.

**1.44 MB disks need the alternative BIOS.** The default `pcxt.rom` cannot do
high-density floppies at all, so install `pcxt/bios-hd-floppy/` as described
under "Known limitations" before using HD disks in the internal drive.

## Network

The core emulates a Novell NE1000 (8-bit ISA, DP8390) at port 320h on the
MEGA65's Ethernet socket (100 Mb/s links only). Load a packet driver in DOS
and any packet-driver application works; mTCP (DHCP, ping, FTP, telnet,
IRC, ...) has been tested. With the Crynwr driver:

```
NE1000 0x60 5 0x320      (menu: Network: IRQ 5, the default)
NE1000 0x60 7 0x320      (menu: Network: IRQ 7)
```

The IRQ you pick must not be the one the Sound Blaster uses: the SB is on
IRQ 5 unless "Sound Blaster IRQ 7" is on in the Sound menu, and the XT's
interrupt controller cannot share a line. So either leave the SB on IRQ 5 and
put the card on IRQ 7, or the other way round; the defaults (both on IRQ 5)
are what most DOS software expects for the SB and what the driver assumes for
the card, so change one of them before using both at once. "Off" removes the
card (port 320h reads as an empty slot).

The card's MAC address is the one stored in your MEGA65's configuration
(the MEGA65 Configure utility, "MAC address"), read from the SD card at
start-up. If none is stored the core uses 02:4D:36:35:00:01; the serial log
line "Ethernet MAC: ..." says which.

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

- The analog VGA connector shares its video mode with HDMI. With "VGA: 31 kHz"
  selected it carries the scaled picture in whatever mode the HDMI submenu is
  set to, and the default there (720p 50 Hz) is not a VGA timing: pick
  **640x480 60 Hz or 800x600 60 Hz** for a VGA monitor. Verified through a
  VGA-to-HDMI adapter in every mode; a direct connection to one particular LCD
  is still refused even at those VESA timings, and is under investigation. The
  "VGA: 15 kHz" settings are unaffected and still pass the core's own raster
  through for CRTs and SCART. See docs/analog-video.md.

- The Turbo XT BIOS in `pcxt.rom` has no high-density floppy support: 1.44 MB
  and 1.2 MB images mount but DOS reports "drive not ready" on them, and **the
  internal drive needs it for 1.44 MB disks**. Either
  use 360 KB or 720 KB images, or switch to the alternative BIOS shipped in
  `pcxt/bios-hd-floppy/`: copy its `pcxt-xt.rom` over `/pcxt/pcxt.rom` and
  its `xtide.rom` to `/pcxt/xtide.rom`. That is Sergey Kiselev's 8088 BIOS
  (XT build) with the XTIDE Universal BIOS as a separate option ROM; it boots
  DOS 3.30 and FreeDOS and reads 1.44 MB images.

- Joystick: verified with a digital stick (axes, centre, fire). The 8088 BIOS
  shipped in `pcxt/bios-hd-floppy/` detects the game port at power-on and sets
  the BIOS "game adapter" bit, which games such as Alley Cat require; keep the
  stick centred while it boots. If another BIOS leaves the bit clear, mount
  `pcxt/joytest.img` in Drive A and run `A:\SETJOY` before the game.
  `A:\JOYTEST` on the same image shows the raw port readings.

- Mouse: a Commodore 1351 or an Amiga mouse in joystick port 1 appears as a
  Microsoft serial mouse on COM1 (3F8h, IRQ 4). Pick 1351 or Amiga under
  Input Settings and load a serial mouse driver in DOS, such as FreeDOS
  CTMOUSE. USB mice need an adapter that presents one of those two; a USB4AMI
  in C64 mode is what this was tested with. Turn Joystick 1 off while using a
  mouse in port 1, since the buttons share pins with joystick 1. If the pointer
  moves opposite to your hand, your adapter counts the other way round from a
  real 1351 and `G_POT_INVERTED` in main.vhd flips it. See docs/mouse.md.
- One hard disk image at a time; the second SD card slot is not used.
- With the default `pcxt.rom` the optional `/pcxt/xtide.rom` is not needed:
  XTIDE is inside `pcxt.rom`. The startup log line "LOADING ROM #0002: FAILED"
  refers to it and is harmless.

## Source

https://github.com/silent-command/PCXT-EGA-MEGA65 (docs/ has the port's design notes).
