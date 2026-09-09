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
