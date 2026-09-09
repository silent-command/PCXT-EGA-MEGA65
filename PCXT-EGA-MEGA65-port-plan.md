
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
