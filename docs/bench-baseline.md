# Bench baseline of the pinned PCXT-EGA_MiSTer submodule

Recorded 2026-09-07 on the Windows PC (WSL2 Ubuntu 24.04, Icarus Verilog
12, Verilator from the Ubuntu 24.04 archive). Submodule commit c6b4dc8
("Document partial Mode X support", release 20263008).

Run with `tools/run-core-benches.sh` from WSL, or each suite's own
`rtl/<suite>/TESTBENCH/run_tests.sh`.

| Suite | Backend | Result | Longest bench |
|---|---|---|---|
| KFPC-XT (chipset) | Icarus | 17 passed, 0 failed, 0 did not build | KF8259_tb, ram_lookahead_tb (1 s) |
| video (EGA path) | Icarus | 32 passed, 0 failed, 0 did not build | ega_raster_baseline_tb (215 s) |
| 8088 (MCL86) | Icarus | 7 passed, 0 failed, 0 did not build | cpu_8086_timing_tb (37 s) |
| sound | Verilator | 8 passed, 0 failed, 0 did not build | sb_driver_poll_tb (18 s) |

Notes:

- The video suite takes about seven minutes under Icarus; `run_tests.sh -v`
  switches it to Verilator for a faster full pass.
- The chipset suite deliberately skips Chipset_tb and the KF8237 benches
  (see the header of its run_tests.sh); the sound suite drives the real
  KF8237 under Verilator instead.
- Benches the port will reuse directly: `ram_lookahead_tb` and
  `ram_refresh_collision_tb` (KFPC-XT) as the harness for the KFSDRAM
  compatible memory shim, and `biu_ram_prefetch_tb` (8088) for the BIU path
  through RAM.sv.

## Benches written for the port

All live in `CORE/rtl/tb/` (plus `CORE/vhdl/` for the VHDL ones) and are
self-checking; each prints `RESULT: PASS`.

| Bench | Runner | What it covers |
|---|---|---|
| `ram_lookahead_avm_tb.sv` | `run_ram_avm_tb.sh` (Icarus, WSL) | KFSDRAM overlay: the chipset's RAM handshake on the Avalon byte bus (56 checks) |
| `rom_load_tb.sv` | `run_rom_load_tb.sh` (Verilator, WSL) | Full `pcxt_core` wrapper: ROM download stream lands in the BIOS windows |
| `rom_loader_tb.sv` | `run_rom_loader_tb.ps1` (xsim) | QNICE side of `rom_loader.vhd`: device writes, CDC, timeouts, status |
| `keyboard_tb.vhd` | `run_keyboard_tb.sh` (GHDL, WSL) | MEGA65 key numbers to PS/2 set-2 frames, host reset (FF) handshake |
| `mgmt_bridge_tb.sv` | `run_mgmt_bridge_tb.sh` (Icarus, WSL) | Storage bridge against the real `ide.v`/`floppy.v`: mount, IDENTIFY, CHS/LBA reads and writes, 8272 DMA reads/writes (1266 checks) |
