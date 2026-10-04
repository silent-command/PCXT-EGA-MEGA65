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

## 2026-10-04: an R3 report, and what the reset path was never asked

An R3 owner (v0.13.1) reported that after a soft reset the BIOS sometimes
stops with "faulty memory detected" at 592 KB; not after a clean start. The
same owner had earlier seen the first DOS boot after mount + Ctrl+Alt+Del hang
after the FreeCom banner. Not seen on the R6.

What was checked:

* **Constraints.** The R3 carries an IS66WVH8M8BLL, the R6 an IS66WVH8M8DBLL,
  and `M2M/common.xdc` says its HyperRAM numbers are "correct for" the DBLL.
  The upstream controller's documentation (MJoergen/HyperRAM,
  `src/hyperram/README.md`, from table 10.3 of the BLL datasheet) gives the
  BLL: tIS 1.0, tIH 1.0, tDSS -0.8..0.8, tDSH -0.8..0.8 ns - the same values.
  The R3 build is timed for its own chip. Our controller sources are
  identical to upstream main, including "Sample RWDS a clock cycle later" and
  "Insert BUFR into RWDS path" of 2024.
* **The button scenario of `ramtest_sys_tb` stopped too early.** It ended the
  run as soon as POST codes came back after the press, i.e. it proved "no
  hang" and never looked at the RAM test that follows - which is where the
  report fails. `-ButtonFull` now runs on to the verdict of the second POST
  and requires it to pass with no read mismatch and no dropped write;
  `-ButtonMode 1|2` presses right after an accepted write, or exactly at the
  given time. One run (Max, two reads in flight) takes 29 minutes and passes.
* **`mem_reset_stress_tb`**, new, for breadth: no CPU, a master that behaves
  like KFSDRAM (one request at a time, at most two reads outstanding, not
  reset by the button) with a scoreboard, on the real path of
  `ramtest_mem_model`, and `hr_rst` pulsed hundreds of times at random
  moments and lengths, asynchronously to both clocks. Every accepted read
  must get exactly one answer, and every read of a byte written after a reset
  must return it. `-Mutate` removes the drain of this document's fix and the
  bench reports hangs and shifted answers at once, so it can fail.

What it found: **with the self test on, as on the core, 900 resets pass. With
the self test off, it fails**, and that is a real flaw in `mem_backend.vhd`:

```
v_real  := s_readdatavalid = '1' and bist_active = '0';
v_flush := rst_all = '1' and out_count /= 0 and not v_real;
```

A read is in flight when the reset arrives. `v_flush` drains it (out_count 1
-> 0). A clock or two later its real answer, which was already in the FIFO,
comes out after all: `v_real`, another pop, out_count below zero - and then
`out_count /= 0` keeps `v_flush` going for as long as the reset lasts, a dummy
beat every clock. (In the simulator the natural wrapped to 4294967294; in
hardware a 4-bit counter would wrap to 15 and drain 15 extra beats.)

The shipped core is not affected, by an accident of its own: with `G_BIST` the
self test's state machine goes to `B_WAIT` on `rst_all`, `bist_active` is high
for the whole reset and masks `s_readdatavalid`. Every bench that set
`G_BIST => false` to save time, `ramtest_mem_model` included, was testing a
configuration that does not ship and that had this hole.

Fix: an answer that arrives while `rst_all` is high belongs to a read the
reset killed, so `v_real` and the `avm_readdatavalid_o` term are gated with
`not rst_all`, with or without the self test. After the fix: self test off
5 x 500 resets and on 3 x 300 resets pass, `mem_backend_tb` 5763 checks pass.

So no logic fault was found that explains the R3 report: the configuration
that ships passed before the fix too. What is left is physical - that board,
that chip, temperature (a clean start is a cold machine, a soft reset is not)
- and it stays open until there is data from the board itself. The core logs
the self-test result after every reset (`bist=` on the serial status line);
an R3 owner without the serial cable cannot see it.
