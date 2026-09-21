# Mouse

A mouse on MEGA65 joystick port 1 appears to DOS as a **Microsoft serial mouse
on COM1** (3F8h, IRQ 4). Load any serial mouse driver - FreeDOS `CTMOUSE` says
`Installed at COM1 (03F8h/IRQ4) in Microsoft mode` - and mouse-aware DOS
software works.

Set **Input Settings -> Mouse** to `C1351` or `Amiga`. `Off` is the default.
Working on the R6 since 2026-09-21 with a USB4AMI adapter in **C64 mode**.

## The chain

```
joystick port 1  ->  m65_mouse_ps2.vhd  ->  MSMouseWrapper.v  ->  8250 UART  ->  DOS
  1351 pot lines      emulated PS/2         PS/2 host, makes      COM1
  or Amiga quadr.     mouse DEVICE          a serial mouse
```

The core inherits MiSTer's `MSMouseWrapper`, which is a PS/2 *host*: it expects
a real PS/2 mouse and converts its packets into the serial byte stream a
Microsoft mouse sends. `CORE/vhdl/m65_mouse_ps2.vhd` is that mouse, synthesised
from the MEGA65's joystick port: it speaks the PS/2 device protocol (device
clock at 12.5 kHz, 11-bit frames, command replies) and turns either a 1351's
analog position or an Amiga mouse's quadrature into standard 3-byte packets.

The paddle values come from the framework (`mouse_input.vhdl` in the QNICE
domain, inverted to SID polarity in `qnice_wrapper.vhd`), so the numbers this
core sees are the same ones a C64 program would read from `$D419` / `$D41A`.

## The bug that made it silent, and the fix

For a long time the mouse enumerated but the pointer never moved: `CTMOUSE`
reported a Microsoft mouse at COM1, and nothing happened.

Instrumenting the joystick port and the PS/2 wire on the board showed:

| measured | value |
|---|---|
| paddle values while moving the mouse | changing continuously, 25 distinct readings in 30 samples |
| mouse mode bits from the menu | correct (`C1351` set) |
| host clock falling edges, ever | 1 |
| request-to-send from the host, ever | never |
| command bytes received | 0 |
| packets sent | 0 |

So everything on the MEGA65 side worked and the **host never asked the mouse
for anything**. A PS/2 mouse is silent until the host sends `F4` (enable
reporting), so ours was correctly, uselessly, mute.

The cause is in `MSMouseWrapper.v`. Its state machine is
`ResetDelay, SendReset, WaitResetACK, WaitBAT, WaitID, WaitACK, SendM, Loop`
(`:135-142`), and the whole thing is wrapped in

```verilog
if (`RTSRISE) begin
    PS2Pr_STM <= `PS2Pr_SendM;      // :210-213
    ...
end else begin
    ... the PS/2 init state machine ...
end
```

**Any rising edge of RTS jumps straight to `SendM` and from there to `Loop`,
abandoning the PS/2 initialisation - and it never retries.** A serial mouse
driver raises RTS to probe for a mouse, which is exactly what `CTMOUSE` does at
start-up, so on this host the init never survives the driver. On MiSTer with a
real mouse the init completes a millisecond after power-on, long before DOS
loads, so the bug never shows.

The saving grace: `PS2Pr_Loop` consumes 3-byte packets regardless of whether
the init ever ran (`:274-297`). So the device does not need permission, only
the willingness to speak without it. `G_STREAM_WITHOUT_ENABLE` (default true)
makes `m65_mouse_ps2` stream packets without waiting for `F4`; set it false for
strict PS/2 behaviour against a host that does initialise properly.

## Axis direction

`G_POT_INVERTED` is **true** in `main.vhd`. The USB4AMI in C64 mode counts the
opposite way from a real 1351 on both axes; without it the pointer moves
against the hand. A real 1351, or another adapter, may need it false - the
symptom is unmistakable and the fix is that one generic.

Buttons need no such switch: left is the fire pin, right is the up pin, which
is where a 1351 puts its right button. Both were correct first time on the board.

## Notes and limits

* USB mice do not work directly; you need an adapter that presents a 1351 or an
  Amiga mouse on the joystick port.
* The adapter's mode matters. The USB4AMI in **C64 mode** drives the analog
  lines and nothing on the direction pins (`JOYTEST` sees nothing); in **Amiga
  or Atari mode** it drives the direction pins instead, and then the core's
  `Amiga` setting is the one to use.
* Turn **Joystick 1 off** while using a mouse in port 1: the mouse buttons share
  pins with joystick 1's fire and up, so the game port would see clicks as
  joystick presses. Joystick 2 is unaffected.
* The framework debounces the joystick lines over 1 ms, which caps Amiga
  quadrature at one transition per millisecond per line.

## Debugging this again

The instrumentation is in the history of the `mouse` branch (commit tagged
`DIAG-MOUSE`): debug words 6..10 of the PCXT ROM device carry both ports'
paddle values, every direction and fire line, the menu mode bits, the PS/2
device state (reporting, packets sent, last command) and the host-wire activity
(clock edges, request-to-send seen, lines' levels), printed over serial four
times a second.

**Check any such readout against a known value before believing it.** The first
version selected memory window 0 instead of the floppy register window
(`FLP_WIN`, 0xFFFD) and printed the core's general status words; they were read
as paddle values and produced a page of confident, wrong conclusions. The tell
was one word reading `EEEE`, which is `rom_loader`'s fallback for an address it
does not decode.
