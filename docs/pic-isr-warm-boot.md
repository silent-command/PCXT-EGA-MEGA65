# 8259: in-service register survives a warm reboot

## Symptom
After Ctrl+Alt+Del the machine reboots and DOS comes up, but the keyboard is
dead (no typing, no second Ctrl+Alt+Del) and a floppy boot after the reboot
stalls on timeouts until XTIDE falls through to "No ROM BASIC". A cold boot
(power-on, reset button, JTAG reload) works indefinitely. Seen first with
Sergey Kiselev's 8088 BIOS (XT build); the Turbo XT BIOS has the same reboot
convention and is affected the same way.

## Root cause (hardware probe + simulation, CORE/rtl/tb/kbd_bios_tb.sv)
IBM-style BIOSes reboot on Ctrl+Alt+Del from inside INT 9 without an EOI:
8088_bios keyboard.inc (`mov word [warm_boot],1234h; jmp 0F000h:warm_start`),
Super PC/Turbo XT pcxtbios.asm (`reboot:`), IBM 5160 KB_INT. They rely on
the POST's ICW1 to reset the controller. A real 8259A clears its in-service
register on initialisation; upstream KF8259 clears only the request latches
(`clear_interrupt_request` in KF8259_Control_Logic.sv) and leaves
`in_service_register` alone (KF8259_In_Service.sv changes it only through
EOI or an acknowledge).

So after the warm POST, ISR bit 1 stays set. KF8259_Priority_Resolver then
blocks IR1 and every lower-priority input. The keyboard's first byte after
the POST reset (the AA self-test code) raises IRQ1 but INT 9 never runs;
KFPS2KB holds `irq` high, which inhibits the PS/2 clock
(`ps2_clock_out = ~(irq | ...)` in Peripherals.sv), so no further key can
arrive. IRQ6 (floppy) is lower priority than IR1 and is blocked as well.

Probe values on hardware at the dead C:\> prompt: IMR=BC, port B=69
(PB6=1, PB7=0), KFPS2KB irq=1, one more keyboard byte than port-60h reads
across the reboot. The bench shows the same state (ISR=02 IRR=02) on the
upstream logic.

## Fix (CORE/rtl/overlay/KF8259_Control_Logic.sv)
ICW1 also drives `end_of_interrupt` with all ones, the only path that
clears the in-service register:

```systemverilog
if (write_initial_command_word_1 == 1'b1)
    end_of_interrupt = 8'b11111111;     // ICW1 clears the ISR
else if ((auto_eoi_config == 1'b1) && (end_of_acknowledge_sequence == 1'b1))
    ...
```

## Evidence
`run_kbd_bios_tb.ps1` (real KF8255/KF8259/KF8253/KFPS2KB + keyboard.vhd +
ps2_tx.vhd, exact port sequences of both BIOSes incl. Ctrl+Alt+Del and the
warm POST): FAIL for both BIOSes on upstream RTL, PASS for both with `-Fix`.
`run_kbd_bios_sys_tb.ps1` runs the real MCL86 on bios-xt.bin for the cold
path (typing lands in the BIOS ring buffer at 40:1E).
