# Remembering the hard disk image

## What it does
The framework forgets every mount when the core restarts, so the hard disk
image had to be mounted by hand on every start: Help, Hard Disk, pick the file,
close, Ctrl+Alt+Del. Since V0.14 the core remembers the last image mounted as
the hard disk and mounts it again by itself, before the PC is released from
reset, so the machine boots straight from it when the welcome screen is left.

Only the hard disk. Floppy images are deliberately not remembered: an XT tries
A: first, and a boot floppy that was left mounted would win over the hard disk
on every start. With "A: internal drive" on, A: is the real drive anyway.

Ejecting the hard disk in the menu forgets it. If the remembered file is not
there at start-up (another card, file renamed) the drive just stays empty and
the entry is kept, in case the file comes back.

## Where it is kept
`/m2m/hdmount` on the SD card: the full path of the image as a zero-terminated
string (`/pcxt/freedos.vhd`), first byte 0 = nothing remembered. The firmware's
FAT32 library can rewrite a file but can neither create nor grow one - the
same reason `/m2m/m2mcfg` has to exist for the menu settings - so the release
ships the file (128 zero bytes; the firmware wants at least `HDM_PATH_MAX` =
80). Without it everything is inert and the core behaves exactly as before.
A path that does not fit in 80 characters is not remembered.

## How (all of it is `CORE/m2m-rom/hdmount.asm`)
| hook | routine | what |
|---|---|---|
| `m2m-rom.asm` `PREP_START` | `HDM_INIT` | open the file, read the path, mount the image |
| `shell.asm` `HANDLE_IO` | `HDM_POLL` | write the file when a change is pending |
| `shell.asm` `HANDLE_MOUNTING` | `HDM_MOUNTED`, `HDM_UNMOUNTED` | an image was mounted / the drive switched off |
| `selectfile.asm` (twice) | `HDM_CD` | the file browser changes directory |
| `options.asm` `HELP_MENU` | `HDM_MENU_OPEN` | file name for the menu line after an auto-mount |

Things that were not obvious:

* **The browser never has a path.** `SELECT_FILE` returns a bare file name;
  the directory is state inside `HANDLE_DEV`, changed by `f32_cd` with
  relative names in `DIRBROWSE_READ`. `HDM_CD` sits in front of both calls of
  `DIRBROWSE_READ` and mirrors every change in `HDM_CWD` (absolute path,
  subdirectory name, `..`); `HDM_MOUNTED` joins directory and name.
  `f32_fopen` accepts a nested path, so the start-up mount needs no `cd`.
* **`LOAD_IMAGE` is fatal when the file cannot be opened.** `HDM_INIT` opens
  it itself first (into the drive's own handle; `LOAD_IMAGE` reopens) and
  quietly gives up if that fails.
* **Reset.** After the mount strobe `HDM_INIT` sets the reset bit of the CSR;
  `START_CONNECT` clears it 333 ms later, as it does on every start. So the
  BIOS finds the disk at POST whether or not the PC was already running under
  the welcome screen. The strobe is not lost in reset: `mega65.vhd` ties the
  vdrives reset to 0 and `mgmt_bridge` is reset only by a lost clock. The
  bridge's read of block 0 (MBR geometry) is served by the first `HANDLE_IO`
  of the main loop, seconds before XTIDE probes the drive.
* **The menu.** The mount marker of the line corrects itself: the menu loop
  compares the mount status with the one it remembered (`_OPTM_GK_MNT`), and
  `HDM_INIT` does not call `VD_MNT_ST_SET`. The `%s` name slot does not: it
  lives in the options heap, which only exists once the menu has been opened,
  so `HDM_MENU_OPEN` fills it right before the first draw. (The internal
  floppy drive solved the same problem with a retry from its poll,
  `FLP_SET_NAME`.)
* **Writing.** The rules are those of the framework's `ROSM_SAVE`: only on the
  SD card that was active at start-up (otherwise remembering goes off for the
  session), not while any drive's write cache is dirty (the single 512-byte
  buffer of the SD controller then belongs to `HANDLE_DEV`; the write is
  retried on the next poll), seek first. Unlike `ROSM_SAVE` an error is not
  fatal. Afterwards `SDB_ORPHAN` tells both device handles that the hardware
  buffer is not theirs any more.
* `options.asm` now zeroes `CONFIG_DEVH` when the settings card cannot be
  mounted, so that "not mounted" reads as 0 as it does for `HANDLE_DEV`.

Cost: 913 words of ROM (1,191 left), 176 words of RAM (334 left).

## Bench
`wsl -d Ubuntu bash tools/vdrive-latency-bench/run_hdmount.sh` runs the real
`hdmount.asm` in the QNICE emulator with the real FAT32 library on a FAT32
card image that has `/M2M/HDMOUNT` and `/PCXT/FREEDOS.VHD`; the framework
calls around it are stubs that record what they were asked. 78 checks: inert
without a card, empty file, path joining, the deferred write while a cache is
dirty, read-back and mount after a restart (drive, path, image size, reset
bit), the menu name including the cut for a narrow menu, the directory
tracking (`/`, names with spaces, `.`, `..`, `..x`, trailing slash, the 80
character limit from both sides), floppy drives ignored, eject forgets,
image gone, SD card changed. Then the card image itself is inspected: exactly
one sector differs from the pristine image, the file's own, and it holds the
path and its terminator.

Not covered by the bench: the five hooks themselves, `LOAD_IMAGE` with the
block map, and the reset of the PC. Those are the hardware test.

## Hardware, 2026-10-04 (R6)
The first run failed in a way the bench could not have caught. Right after a
manual mount the log said `HDM: SD card changed, remembering is off`. The card
had not changed: `HDM_CSR .EQU M2M$CSR` assembled to 0xFFFF, because qasm does
not resolve an `.EQU` whose value is another symbol, and it says nothing. The
bench supplies its own stand-in for the register, so it never saw the address.
`HDM_CSR` is now a preprocessor name, and `run_hdmount.sh` looks at the
firmware listing and requires both CSR accesses to be assembled with 0xFFE0.
Nothing was written to the card by the faulty build: it only read the wrong
address and then switched itself off.

With the fix, from the serial log and the screen:

| step | log | seen |
|---|---|---|
| Space on the welcome screen, empty file | `HDM: no hard disk remembered` | PC starts without a disk, as before |
| mount freedos.vhd by hand | `HDM: remembered: /pcxt/freedos.vhd` | |
| core reloaded, Space | `HDM: mounting /pcxt/freedos.vhd` 0.1 s later, image loaded 0.1 s after that | PC boots to `C:\>` with no menu and no Ctrl+Alt+Del |
| Help | | `=Hard Disk:freedos.vhd`, marker and name both there |
| Space on that line | `HDM: forgotten` | line back to `<Mount Drive>` |
| Return, pick the file | `HDM: remembered: /pcxt/freedos.vhd` | |

Not tried on hardware: a remembered image that is missing at start-up, a path
too long to remember, and a second SD card. All three are in the bench.
