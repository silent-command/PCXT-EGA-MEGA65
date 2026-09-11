# PCXT-EGA for MEGA65

Port of [MiSTer-devel/PCXT-EGA_MiSTer](https://github.com/MiSTer-devel/PCXT-EGA_MiSTer),
an IBM PC/XT with an EGA card, to the MEGA65 R6 using the
[MiSTer2MEGA65](https://github.com/sy2002/MiSTer2MEGA65) framework (V2.0.1).

Status: boots FreeDOS from an SD-card hard disk image with 640 KB
conventional memory, UMB and 2 MB EMS in HyperRAM; floppy images read and
write; keyboard, joysticks, Adlib / Sound Blaster / Tandy / speaker sound;
options menu with settings persistence. See `docs/release/README.md` for the
user-facing description and `PCXT-EGA-MEGA65-port-plan.md` (next to this
repo) for the phase history.

## Layout

- `CORE/rtl/pcxt_core.sv` — the core wrapper (MiSTer top level minus the HPS)
- `CORE/rtl/overlay/` — upstream files replaced by basename (RAM.sv READY and
  latch fixes, KFSDRAM byte bus, floppy IRQ re-arm, bram wrapper)
- `CORE/rtl/mgmt_bridge.sv` — emulates MiSTer's ARM side of the floppy/IDE
  management bus against the framework's virtual drives
- `CORE/vhdl/` — main.vhd (wrapper, option decode), mem_backend.vhd
  (HyperRAM byte bus with ROM windows and self test), vd_glue.vhd (clock
  crossing to the virtual drives), keyboard.vhd, config.vhd (menu, help)
- `CORE/rtl/tb/` — benches (Icarus and xsim); `docs/` — design notes and
  the root causes of every hardware bug found on the way
- `M2M/rom/` — framework firmware with the port's SD-direct image I/O and
  the settings-save fix
- `tools/` — build, JTAG load, serial log, `make_release.py`

## Build

Vivado 2026.1 on Windows with WSL (the QNICE firmware assembles via WSL):

```
cd CORE
vivado.bat -mode batch -source build-r6.tcl
```

Outputs land in `CORE/CORE-R6.runs/impl_1/`; `tools/make-cor.sh` packages
the `.cor`; `python3 tools/make_release.py --with-hd-image` (run under WSL,
like the firmware assembly) builds the release folder and zip.

## License

GPL v3 (see LICENSE), as upstream and the framework.
