# PCXT-EGA for MEGA65

An IBM PC/XT with an EGA card on the MEGA65: 8088 or 8086 CPU at 4.77,
7.16, 9.54 MHz or unthrottled, 640 KB of RAM plus upper memory and 2 MB of
EMS, floppy and hard disk images from the SD card, **the MEGA65's own 3.5"
floppy drive as A: - real disks, read, write and `FORMAT`**, Adlib, Sound
Blaster, Tandy and PC speaker sound, an NE1000 Ethernet card on the MEGA65's
network port, and the MEGA65 keyboard, joysticks and mouse.

Ported from [MiSTer-devel/PCXT-EGA_MiSTer](https://github.com/MiSTer-devel/PCXT-EGA_MiSTer)
with the [MiSTer2MEGA65](https://github.com/sy2002/MiSTer2MEGA65) framework.
MEGA65 port by silent-command. GPL v3, see LICENSE.

## Install

1. Flash the core file for your machine into a core slot: hold **No Scroll**
   while powering on, pick an empty slot, choose the file from the SD card.
   * **`pcxt-ega-r6.cor`** for a MEGA65 R6. This is the one that is developed
     and tested on real hardware.
   * **`pcxt-ega-r3.cor`** for an R3. Identical design, built for that board.
     One R3 owner reports that it boots and runs, with one open issue - see
     "The R3 core" below.

   The files are stamped for their board, so the MEGA65 will refuse the wrong
   one rather than flash it.
2. Copy the `m2m` and `pcxt` folders to the **root** of the SD card, next to
   each other. `m2m/m2mcfg` makes the menu remember your settings. **Replace
   an existing `m2m/m2mcfg` with this release's copy**: the menu grew with
   the "A: internal drive" line and the file must match its size, otherwise the
   core logs "corrupt config file" and stops saving settings (nothing else
   breaks).
   `m2m/hdmount` is where the core remembers your hard disk image (step 4).
   Copy it once; without it the core works as before and simply does not
   remember. Copying a release's fresh `hdmount` over yours later only makes
   the core forget the image until you mount it again.
3. Put **`ega_bios.rom`** into `/pcxt`. It is the one file this package cannot
   include, the core will not start without it, and it is free to obtain: see
   "The one file you have to supply" below. Everything else, including a
   bootable FreeDOS hard disk and a system BIOS, is already here and in place.
4. Start the core. Press **Space** on the welcome screen. Press **Help**,
   mount your hard disk image under "Hard Disk", close the menu, press
   **Ctrl+Alt+Del**. XTIDE lists the drive and boots it.

   You do this once. The core remembers the image, and from the next start it
   mounts it by itself and the PC boots from it as soon as you leave the
   welcome screen. Ejecting the hard disk in the menu makes it forget. Floppy
   images are not remembered, on purpose: a PC tries A: first, and a boot
   floppy left mounted would win over the hard disk on every start.

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

Settings are saved when the menu closes, if `/m2m/m2mcfg` exists. The hard
disk image is remembered separately, in `/m2m/hdmount`.

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

**High-density disks need the BIOS this package ships as the default.** That is
already in place, so the internal drive works out of the box. Only if you swap
`pcxt.rom` for the Turbo XT BIOS in `pcxt/roms/` do 1.2 and 1.44 MB disks stop
working, because that BIOS has no high-density floppy support at all.

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

- Only one of the system BIOSes in `pcxt/roms/` does high-density floppies.
  The default (Sergey Kiselev's 8088 BIOS, already installed as `pcxt.rom`
  with `xtide.rom` beside it) reads 1.2 and 1.44 MB disks and drives the
  internal drive. The Turbo XT BIOS alternative does not: with it, HD images
  mount but DOS reports "drive not ready", so stay on 360 KB or 720 KB.

- Joystick: verified with a digital stick (axes, centre, fire). The 8088 BIOS
  shipped as the default `pcxt.rom` detects the game port at power-on and sets
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
- Keep `/pcxt/xtide.rom` next to the default `pcxt.rom`: the 8088 BIOS has no
  hard disk support of its own and gets it from that file. Only if you switch
  to the Turbo XT BIOS (`pcxt/roms/README.txt`), which has XTIDE built in, is
  `xtide.rom` unnecessary; delete it then, and the startup log line
  "LOADING ROM #0002: FAILED" that follows is harmless.

## What is already set up for you

The card is ready as shipped, apart from one file. In `/pcxt` you will find:

* **`pcxt.rom`**, the system BIOS the core loads, already in place. It is
  Sergey Kiselev's 8088 BIOS with **`xtide.rom`** beside it, so you get large
  hard disks through XTIDE *and* 1.2 / 1.44 MB floppies, including the MEGA65's
  own drive. `roms/` holds the alternatives with a README explaining how to
  switch; you do not need to touch it.
* **`freedos.vhd`**, a bootable FreeDOS hard disk with the drivers this machine
  wants: CTMOUSE for the mouse, LTEMM for the 2 MB of EMS, USE!UMBS, and the
  core's own `VGATSR.COM` and `XTEGACTL.COM`. Mount it under "Hard Disk".
  It also runs `FASTFREE.COM` at boot, which counts the free clusters in
  well under a second; without it FreeDOS does that count itself the first
  time anything asks for "bytes free", one cluster at a time, and the first
  `dir` after boot stalls for about 40 seconds at 4.77 MHz.
* **`netdisk.img`** for networking and **`joytest.img`** for the game port.

## The R3 core

`pcxt-ega-r3.cor` is the same design built for the MEGA65 R3. All development
and testing happens on an R6. What is known about the R3 comes from **one
owner's report** (of v0.13): the core starts, the PC boots and DOS runs from
the hard disk image. So video, keyboard, SD card and memory work on that board.

The same report has one problem that an R6 does not show. After mounting the
hard disk and pressing Ctrl+Alt+Del, the first DOS boot stopped right after the
FreeCom banner; a second Ctrl+Alt+Del then booted normally. It is not
understood yet. This release changes the path it happened on - the hard disk is
now mounted before the PC first starts, and the DOSMAX driver is no longer
loaded - but whether that cures it is not known. If you see it, a second
Ctrl+Alt+Del gets you going.

Still untested on an R3 are the parts that touch the board around the FPGA: the
internal floppy drive, the Ethernet port and the analog VGA output. Every
MEGA65 revision uses the same FPGA, and the R3 already maps every pin this core
needs, so nothing had to be invented for it.

Reports are welcome either way, and especially on those three and on the hang
above. Nothing the core does can harm the machine: a core slot is rewritable
and the MEGA65 boots from slot 0 regardless.

## The one file you have to supply

**The EGA BIOS** (`pcxt/ega_bios.rom`, required - without it the core stops at
the boot splash). It is IBM's own option ROM for the EGA card, part 6277356,
and it is still under copyright, so no core can ship it. Build your own from
the published dump:

1. Download the raw dump, **[ibm_6277356_ega_card_u44_27128.bin](https://minuszerodegrees.net/rom/bin/ibm_6277356_ega_card_u44_27128.bin)**
   (16,384 bytes), from the ROM archive at
   [minuszerodegrees.net](https://minuszerodegrees.net/rom/rom.htm) - the row
   "IBM / EGA / U44". Open the link in a browser: the site turns away download
   tools that do not look like one.
2. Reverse the byte order. The card feeds the EPROM inverted address lines, so
   the dump is back to front: the last byte of the file is the first byte of
   the ROM. Any one of these does it:
   * `python3 -c "open('ega_bios.rom','wb').write(open('ibm_6277356_ega_card_u44_27128.bin','rb').read()[::-1])"`
   * PowerShell: `$b=[IO.File]::ReadAllBytes("$pwd\ibm_6277356_ega_card_u44_27128.bin"); [array]::Reverse($b); [IO.File]::WriteAllBytes("$pwd\ega_bios.rom",$b)`
   * the upstream script `SW/ROMs/EGA/make_ega_bios_rom.py` from
     [PCXT-EGA_MiSTer](https://github.com/MiSTer-devel/PCXT-EGA_MiSTer), which
     downloads and reverses in one go (Python with the `requests` module).
3. Check it: `ega_bios.rom` is 16,384 bytes, begins with the bytes `55 AA 20`
   (option ROM signature, 16 KB), and its MD5 is
   `528455ed0b701722c166c6536ba4ff46`. The raw download's MD5 is
   `0636f46316f3e15cb287ce3da6ba43a1`.
4. Put it in `/pcxt/ega_bios.rom`.

### About the hard disk image

`pcxt/freedos.vhd` is [FreeDOS](https://www.freedos.org/) and the drivers only.
The MiSTer release ships a similar image in `games/PCXT/hd_image.zip` which also
carries a folder of PC demoscene productions - 8088 MPH, Area 5150 and others.
Those are separate copyrighted works by their authors, so they are not here;
find them through [pouet.net](https://www.pouet.net/) and
[scene.org](https://www.scene.org/) under their own names. They are worth
seeing: this machine runs them as real hardware does.

The one addition is `C:\FASTFREE.COM` (source in `tools/fastfree/` of the
repository), run from `FDAUTO.BAT`. FreeDOS kernel 2043 computes "bytes free"
the first time it is asked by walking the FAT one cluster at a time through
its generic cluster code - two 32-bit divisions per entry - which on a 4.77 MHz
8088 is about 38 seconds for this image's 21,722 clusters. FASTFREE does the
same count in a tight loop and stores it where the kernel keeps it, so the
first `dir` is as quick as every later one. If you build your own image, copy
it over and add `C:\FASTFREE.COM C:` to your `FDAUTO.BAT`; it only acts on
FAT16 drives whose count is not yet known, and does nothing otherwise.

Two lines of its `FDCONFIG.SYS` differ from the MiSTer image as well. It says
`DOS=UMB` instead of `DOS=HIGH,UMB`: an 8088 cannot reach the high memory area,
and the kernel said so with "HMA not enabled" on every boot. And it no longer
loads DOSMAX, a utility for MS-DOS and DR-DOS that can do nothing with the
FreeDOS kernel and only printed a warning; FreeDOS moves its data into upper
memory by itself (`DOSDATA=UMB`). Free memory is unchanged, 516K conventional
and 38K upper.

Any raw image with an MBR works, so your own FreeDOS installation is fine too.
The core reads the geometry from the partition table.

## Source

This core: https://github.com/silent-command/PCXT-EGA-MEGA65 (`docs/` has the
port's design notes). GPL v3, see LICENSE.

It is built on, and ships binaries of, other people's free software. Source for
each, as the GPL requires:

| Shipped here | Source |
|---|---|
| the core itself | [PCXT-EGA_MiSTer](https://github.com/MiSTer-devel/PCXT-EGA_MiSTer), [MiSTer2MEGA65](https://github.com/sy2002/MiSTer2MEGA65), and this repository |
| `pcxt/roms/turbo-xt-3.1-with-xtide.rom` | [virtualxt/pcxtbios](https://github.com/virtualxt/pcxtbios) |
| the XTIDE BIOS in it and `xtide.rom` | [xtideuniversalbios.org](https://www.xtideuniversalbios.org/) |
| `pcxt/pcxt.rom` and `pcxt/roms/8088-bios-xt.rom` (8088 BIOS) | [skiselev/8088_bios](https://github.com/skiselev/8088_bios); this build's change is `tools/8088_bios-patch/` in this repository |
| mTCP on `pcxt/netdisk.img` | [brutman.com](https://www.brutman.com/mTCP/) |
| the Crynwr packet driver on it | [fragglet/crynwr_mirror](https://github.com/fragglet/crynwr_mirror) |
