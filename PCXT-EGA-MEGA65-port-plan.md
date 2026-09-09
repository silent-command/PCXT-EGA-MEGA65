
## Floppy debugging, 2026-09-09

- Mount confirmed correct on hardware after the strobe-edge fix (78ecb01):
  exactly 7 writes to mgmt page F2, F200 reg 0 = media present, single mount.
- But the floppy controller never raises a read request (fdr counter stays 0)
  when the BIOS reads the disk, so DOS reports "drive not ready" (BIOS
  interrupt timeout). Same for 360K and 1.44M images. Fault is in the
  CPU->FDC I/O, IRQ6, or DMA channel 2 path (the floppy is the first user of
  the 8237 DMA in this port). Under investigation.
- EMS confirmed working on hardware: LTEMM "128 pages found on EMS board at
  0260, Installation completed, 2048K RAM available". Phase 6 memory goals
  (640K conventional, UMB, 2MB EMS) all met.

## Phase 6 complete, 2026-09-09

Everything in Phases 0-6 works on hardware:
- FreeDOS boots from the SD-card hard disk image (XTIDE).
- 640K conventional, 48K UMB, 2048K EMS (LTEMM), all in HyperRAM.
- Video, keyboard, Ctrl+Alt+Del.
- Floppy mount, read AND write (copy verified: file+FAT+directory written).

Three floppy fixes on the way, all with benches:
1. mgmt_bridge: mount strobes are edges (framework holds img_mounted for tens
   of clocks) - 78ecb01.
2. overlay floppy.v: deassert irq on the next command so the edge-triggered
   8259 re-arms (the Turbo XT BIOS does no Sense Interrupt between
   RECALIBRATE and SEEK) - c9ba350, docs/floppy-irq-rearm.md.
3. mgmt_bridge: after a write block return to S_IDLE, not S_FDD_WAIT; for a
   multi-sector write the FDC re-raises its request while the slow SD write
   is in flight, so S_FDD_WAIT never saw it drop - 49d8e56.

Debug probes (rom_loader regs 6/7/8, status line) to be removed for the
release build. Next: Phase 7 polish.
