# Reset button: black screen or vertical bars

## Symptom
Pressing the MEGA65's reset button while the core runs sometimes leaves a
black screen or vertical bars; only a JTAG reload or a power cycle recovers.
Ctrl+Alt+Del (a warm reboot inside the PC) is always fine.

## What the button does here
A short press asserts the framework's core reset (CPU, chipset, EGA, video
retime) and, through `clk_m2m.vhd`, `hr_rst`: the HyperRAM controller, the
HyperRAM chip's own reset line, the framework's memory arbiter and the
memory backend (`mem_backend.vhd` `rst_all`, which also re-runs the BIST).
It does NOT reset the chipset's memory master (`RAM.sv` / `KFSDRAM.sv`),
whose reset is the clock-lock reset only, deliberately, so that the ROM
windows, the ROM presence latches and `initilized_sdram` survive a reset
(otherwise the core would sit in the "BIOS missing" hold after every press).
A long press (1.5 s) additionally restarts QNICE, which re-runs the ROM
autoload; a short press prints nothing on the serial line at all.

## Cause (proven in simulation)
`mem_backend.vhd` handled `hr_rst` by clearing its outstanding-read counter.
A read that KFSDRAM had already issued at that instant was lost, and
`KFSDRAM.sv`'s READ_ISSUE waits for `readdatavalid` with no timeout. When the
CPU came out of reset, its first memory access never completed: the 8088
hung at the very start of POST, before the BIOS could reprogram the freshly
reset EGA, which then displayed its post-reset state over stale video RAM,
black or bars, for ever. "Sometimes" = only when a HyperRAM read was in
flight at the moment of the press. The C64 core on the same framework resets
its HyperRAM master together with the controller, which is why it never sees
this.

Bench: `run_ramtest_sys_tb.ps1 -Speed 3 -Button 2500000` (real MCL86 +
BIOS + RAM.sv/KFSDRAM + mem_backend + real HyperRAM path) presses the button
with two reads in flight: original RTL hangs with KFSDRAM in READ_ISSUE and
no POST codes; fixed RTL POSTs again. `mem_backend_tb` case T0(iii) tightened
the same way.

## Fix (CORE/vhdl/mem_backend.vhd)
While `rst_all` is high, outstanding reads are drained one per clock with a
dummy data beat (`flush_valid`, data FF) instead of being forgotten, so
KFSDRAM's bookkeeping comes out of the reset consistent. The CPU is in reset
at the same time, so the dummy data is never consumed.
