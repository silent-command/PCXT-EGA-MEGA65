# Floppy: interrupt re-arm for the edge-triggered PIC

## Symptom
A correctly-mounted floppy image gives DOS "drive not ready" a few seconds
after `dir a:`. On-chip probes showed the CPU reaches the FDC (motor and
command-port writes happen, the FDC raises ~13 interrupts) but the READ DATA
command never starts (floppy.v cmd_read_write_start never pulses) and no DMA
occurs.

## Root cause (simulation-proven, CORE/rtl/tb/fdc_bios_tb.sv)
The Super PC/Turbo XT BIOS v3.1 programs the 8259 as edge-triggered
(ICW1 LTIM=0) and, unusually, issues no Sense Interrupt Status between
RECALIBRATE and SEEK. `floppy.v` deasserts its `irq` only when the data port
0x3F5 is read (or on reset). So the recalibrate-completion interrupt stays
asserted through the seek; the seek-completion produces no new rising edge;
the edge-triggered 8259 never re-fires IRQ6; the BIOS interrupt-wait times
out and aborts INT 13h before sending READ DATA.

## Fix (CORE/rtl/overlay/floppy.v)
Deassert `irq` when the CPU writes the first byte of the next command
(`command_first`), placed after the completion-interrupt (`raise_interrupt`)
clause so a genuine completion is never lost:

```verilog
else if(ndma_irq | raise_interrupt)                  irq <= 1'b1;
else if(command_first)                               irq <= 1'b0;   // re-arm the edge PIC
else if(io_read && io_address == 3'd5 && ~ndma_read) irq <= 1'b0;
```

Issuing a new command clears the previous command's stale interrupt, which
lets the edge-triggered PIC see the next completion. Elsewhere the driver
reads 0x3F5 before the next command, so `irq` is already low and the clause
is a no-op. `mgmt_bridge_tb` (real floppy.v read/write over DMA with IRQ
checks) still passes 2016 checks.

## Note / possible upstream report
This is a real floppy.v + edge-PIC + no-sense-interrupt-BIOS interaction.
Whether to push it upstream (MiSTer PCXT-EGA) depends on whether the same
BIOS combination is expected there; on MiSTer the floppy is ARM-served.

## Update: floppy WRITE partially works (2026-09-09)

With the IRQ re-arm fix, floppy READ works fully on hardware (`dir a:`,
`type`). Floppy WRITE partially works and then stalls. On-chip probes during
`copy a:hello.txt a:copy.txt` (status line wrs/req/blk):
- `wrs=02` : the FDC started 2 WRITE DATA commands (write path reached).
- `req=03 0E` : 3 FDD write requests (mgmt_req[7]) and 14 read requests raised.
- `blk=10 02` : the bridge issued 2 blk_wr (drive A) and saw 16 blk_ack
  (14 reads + 2 writes) — so 2 sectors were written to the SD image and
  acknowledged.

So DMA read-from-memory, the FDC write FSM, the bridge drain and the
SD-direct firmware write all function; two sectors reach the card. The
operation stalls after ~2 sectors (a `copy` of 1309 bytes needs more sector
writes than that), so DOS reports "drive not ready". Remaining suspects:
the synchronous SD-direct write latency (the bridge waits for blk_ack, which
waits for f32_fwrite+f32_fflush) exceeding the BIOS per-operation timeout on
a later sector, or a multi-sector (EOT>1) write edge case where the 3rd
write request does not produce a blk_wr. The proper cure is the M2M-standard
cached/background-flush write instead of the write-through SD-direct path,
or splitting the FDC completion from the SD commit. Floppy write is the one
open item; everything else in Phases 0-6 works on hardware.
