# Draft issues for the upstream projects

Four defects found while porting to the MEGA65, each fixed in this repo,
each still present upstream as of 2026-09-12. Drafted for the port author to
post (or adapt); nothing has been filed.

---

## 1. sy2002/MiSTer2MEGA65 — `ROSM_SAVE` never terminates with two or more virtual drives

**File:** `M2M/rom/options.asm`, routine `ROSM_SAVE`, label `_ROSMS_0`
(present in V2.0.1 and in master as of 2026-09-11).

**Symptom.** With `SAVE_SETTINGS = true` and `/m2m/m2mcfg` present, the
first time the options menu closes the firmware hangs: Help no longer opens,
nothing is logged, virtual drive requests are no longer served (a core that
is reading a disk times out). Cores with a single virtual drive are not
affected.

**Cause.** The loop that checks every drive's `VD_CACHE_DIRTY` before
writing the config file uses R8 both as the drive index and as the value
returned by `VD_DRV_READ`:

```
_ROSMS_0        MOVE    VD_CACHE_DIRTY, R9
                RSUB    VD_DRV_READ, 1          ; returns the flag in R8 ...
                CMP     0, R8
                RBRA    _ROSMS_NOWR, !Z
                ADD     1, R8                   ; ... so this is flag+1, not drive+1
                CMP     R0, R8                  ; R0 = number of drives
                RBRA    _ROSMS_0, !Z
```

With no drive dirty R8 is 1 after every iteration; for `VDNUM >= 2` it never
equals R0 and the loop spins forever.

**Fix (as applied in the MEGA65 PCXT-EGA port):** keep the drive number in a
scratch register across the call.

```
_ROSMS_0        MOVE    VD_CACHE_DIRTY, R9
                MOVE    R8, R1                  ; R1: current drive
                RSUB    VD_DRV_READ, 1
                CMP     0, R8
                RBRA    _ROSMS_NOWR, !Z
                MOVE    R1, R8
                ADD     1, R8
                CMP     R0, R8
                RBRA    _ROSMS_0, !Z
```

---

## 2. MiSTer-devel/PCXT-EGA_MiSTer — floppy interrupt is never re-armed for an edge-triggered 8259 when the BIOS skips Sense Interrupt

**File:** `rtl/common/floppy.v`, the `irq` register (around the
`ndma_irq | raise_interrupt` clause).

**Symptom.** With the Super PC/Turbo XT BIOS v3.1 (`pcxt_pcxt31.rom`), every
floppy access ends in DOS "drive not ready" although the image is mounted
and the controller completes recalibrate and seek. Traced on hardware: the
controller raises `irq` for the recalibrate, the BIOS issues SEEK without a
Sense Interrupt Status in between, and `irq` stays high because `floppy.v`
only drops it on a read of the data port 0x3F5. The seek-completion
therefore produces no rising edge, the edge-triggered 8259 (ICW1 LTIM=0)
never delivers IRQ6 again, the BIOS wait times out and READ DATA is never
issued.

**Fix (as applied):** deassert `irq` when the host starts the next command,
after the completion-interrupt clause so a genuine completion is never lost:

```verilog
else if(ndma_irq | raise_interrupt)                  irq <= 1'b1;
else if(command_first)                               irq <= 1'b0;   // re-arm the edge PIC
else if(io_read && io_address == 3'd5 && ~ndma_read) irq <= 1'b0;
```

A bench driving `floppy.v` + `KF8259` with the exact BIOS port sequence
reproduces the hang without the clause and passes with it (512 bytes moved).

---

## 3. MiSTer-devel/PCXT-EGA_MiSTer (KFPC-XT) — 8259 in-service register is not cleared by ICW1, so Ctrl+Alt+Del leaves the keyboard dead

**File:** `rtl/KFPC-XT/HDL/KF8259/HDL/KF8259_Control_Logic.sv` (the
`end_of_interrupt` block; upstream of upstream is kitune-san/KF8259).

**Symptom.** After a Ctrl+Alt+Del reboot the keyboard no longer responds
and a floppy boot stalls on interrupt timeouts; a cold boot is fine. Seen
with the Super PC/Turbo XT BIOS and with skiselev/8088_bios. Both reboot
from inside INT 9 without an EOI (`mov word [40:72],1234h` and a far jump
to the POST), as the IBM BIOS does, relying on the POST's ICW1 to reset the
controller. A real 8259A clears its in-service register on initialisation;
KF8259 clears only the request latches (`clear_interrupt_request`) and
keeps `in_service_register`, so ISR bit 1 survives the warm POST and the
priority resolver blocks IR1 and every lower-priority input from then on.
The keyboard's self-test byte after the POST reset is never serviced,
KFPS2KB holds `irq` high and inhibits the PS/2 clock, and IRQ6 is blocked.

**Fix (as applied):** in the `end_of_interrupt` always_comb, make ICW1
clear the ISR:

```systemverilog
if (write_initial_command_word_1 == 1'b1)
    end_of_interrupt = 8'b11111111;
else if ((auto_eoi_config == 1'b1) && (end_of_acknowledge_sequence == 1'b1))
    ...
```

A bench with the real KF8259/KF8255/KFPS2KB and the exact port sequences of
both BIOSes (Ctrl+Alt+Del, warm POST, typing) reproduces the dead keyboard
without the change (ISR=02 after POST) and passes with it.

---

## 4. MiSTer-devel/PCXT-EGA_MiSTer — inferred latches on the SDRAM command path in `RAM.sv`

**File:** `rtl/KFPC-XT/HDL/RAM.sv`, the `always_comb casez (state)` block that
drives `access_address`, `access_num`, `access_data_in`, `write_request`,
`read_request`, `sdram_ldqm/udqm`.

**Symptom.** The enum has seven states in three bits and the case has no
`default` arm, so synthesis (Vivado: Synth 8-327; Quartus reports the
equivalent) infers a latch for every output of the block. The latch gate is
decoded from the state bits and has no clock, so every path through it into
the SDRAM controller is unconstrained. On the MEGA65 port two builds with
identical logic behaved differently (one booted, one did not detect the IDE
drive) until the latches were removed; the same structure exists on MiSTer,
where it simply happens to meet timing.

**Fix (as applied):** add a `default:` arm with the idle values (all
requests 0, address/data 0, dqm 0). No functional change; the block becomes
a plain mux.
