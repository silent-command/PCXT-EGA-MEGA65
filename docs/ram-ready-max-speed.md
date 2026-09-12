# RAM: READY handed to the wrong bus cycle at "Max" CPU speed

## Symptom
With the CPU speed option "Max" (XT_CE_Generator ratio 1/1) Sergey Kiselev's
8088 BIOS reports "ERROR: Faulty memory detected at 32 KiB" and counts only
32 KiB. 4.77, 7.16 and 9.54 MHz count all 640 KiB, with or without "286
speedup". The first 32 KiB test (IF=0, before the PIT channel 1 refresh timer
is started) passes even at Max; the counted test (16 KiB blocks, rep stosw /
lodsw compare) fails on its first block once the DRAM-refresh DMA (channel 0,
DRQ0 from timer 1) and INT 8 are running. The memory itself is fine.

## Root cause (simulation, CORE/rtl/tb/ramtest_sys_tb.sv)
`RAM.sv` raises `access_ready` in COMPLETE_RAM_RW for the transaction that
just finished and forwards it combinationally as `memory_access_ready` to
whatever command is on the bus. At ratio 1/1 a HyperRAM access can outlast
its own bus cycle (a refresh cycle steals a clock, or the arbiter is busy),
so the next access's MEMW/MEMR strobe is already asserted while the previous
one is completing. The previous transaction's completion then satisfies the
new command's READY before `RAM.sv` has accepted it; the CPU advances inside
the strobe and the access is dropped (a write lost, or a read returning
stale data). At the three real clock rates the command pulse is many times
longer than the transaction, so `RAM.sv` is back in IDLE and has accepted
the new command long before READY is sampled.

The bench (real MCL86 + XT_CE_Generator + Bus_Arbiter with refresh DMA +
Ready + KF8237/RAM/KFSDRAM overlays + mem_backend behind the framework
HyperRAM path, running the real bios-xt.bin through POST) drops 48 writes in
the first 32 KiB at Max with the pre-fix RTL (`-Repro`, pessimistic
`-Model`) and none at 4.77/7.16/9.54.

## Fix (CORE/rtl/overlay/RAM.sv)
`served_match` = the command on the bus is the one `RAM.sv` latched (same
physical address and same direction, `latch_cmd_write`). The CPU-visible
ready is qualified with it under `strict_ready`, and COMPLETE_RAM_RW returns
to IDLE as soon as a different command is pending, so it is re-accepted
instead of being handed the old transaction's readiness. Inert when timing
is not marginal: during any normal single access `served_match` is high
throughout.

## Evidence
`run_ramtest_sys_tb.ps1 -Speed 3` (and `-Model`): counted test passes with
0 dropped writes and 0 read mismatches; `-Repro` reproduces the failure.
Speeds 0..2 pass before and after. RAM lookahead bench 56/56.
Hardware: RAM test 640 KiB at Max, FreeDOS + `dir a:` + Ctrl+Alt+Del at Max.
Build timing: WNS +0.012 ns (the `served_match` comparator sits in the
READY path; watch it in future builds).
