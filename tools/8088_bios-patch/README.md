# 8088_bios game-port detection patch

`sdcard/bios/pcxt-xt.rom` is Sergey Kiselev's 8088 BIOS
(https://github.com/skiselev/8088_bios), tag v1.0.0, MACHINE_XT build, plus
`gameport-v1.0.0.diff`: a `detect_gameport` routine called from POST after
the parallel-port scan. It strobes port 201h, waits up to about 6 ms for the
axis one-shots to fire and clear, prints "Game Port: Present/Absent", and
sets bit 12 of the BIOS equipment word ("game adapter installed") when a
joystick answered. Upstream never sets that bit, and games that trust
INT 11h (Alley Cat, for one) refuse the joystick without it. Version string
bumped to 1.0.0m so the build is recognisable on screen.

The same diff also adds `sti` to the INT 18h "No ROM BASIC" handler: the
INT instruction clears IF, so upstream halts with interrupts off there and
Ctrl+Alt+Del cannot reboot; with interrupts on it can.

## Rebuild
```
git clone https://github.com/skiselev/8088_bios && cd 8088_bios
git checkout v1.0.0
git apply ../gameport-v1.0.0.diff && cp ../gameport.inc src/
nasm -O9 -f bin -DMACHINE_XT -i src/ -o bios-xt.bin src/bios.asm
```
NASM 2.16.03 (the Windows zip from nasm.us runs without installation). The
output is 16384 bytes and goes on the card as `/pcxt/pcxt.rom`, with
`xtide.rom` alongside; see `sdcard/bios/README.txt`.

Verified on the MEGA65 on 2026-09-16: POST prints "Game Port: Present",
Alley Cat accepts the joystick with no workaround, keyboard, floppy and
Ctrl+Alt+Del unchanged. The detection reads "Absent" when the stick is held
in the far up-left corner at power-on or when Joystick 1 is disabled in the
menu, which is the intended meaning of the bit.
