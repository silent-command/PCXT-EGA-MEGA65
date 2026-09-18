# Keyboard: ":" typed as ";" once after a Shift

## Symptom
Typing the MEGA65's ":" key sometimes gives ";" in DOS; it happens once and
the next presses are right. Noticed when typing "a:" or "c:" repeatedly.
Reliable board repro with no other keys involved:

1. tap "*" -> "*" (correct)
2. hold Shift, tap "*", release Shift -> "}" (correct, "}" is Shift+"]" on a PC)
3. tap "*" -> "8" (WRONG)
4. tap "*" -> "*" (correct again)

Same class: any use of a physical Shift (a capital letter, "\", ">",
`dir *.*`) followed by a key whose PC legend needs Shift while the MEGA65 key
is unshifted (":" "*" "@" "+" "(" ")" "&" "^" "#" "~" "|") loses that Shift,
once.

## Root cause: keyboard.vhd's idea of the PC's Shift went stale
`CORE/vhdl/keyboard.vhd` turns MEGA65 keys into PS/2 set-2 codes. ":" is
unshifted on the MEGA65 but Shift+";" on a PC, so its table entry says
`S_ON`: the translator sends a Left Shift make (`12`) before the ";" make
(`4C`) when the PC's Shift is up, and puts the PC's Shift back to the
physical state when the key is released. It kept one flag for "what the PC
believes", `emitted_shift`.

That flag was refreshed by makes only. In `LOOKUP` a release went straight
to `PREFIX`, never through `SHIFT_FIX`, so the physical Shift's break
(`F0 12`) was queued without clearing `emitted_shift`. Traced through the
board repro:

| step | bytes sent | `emitted_shift` after | PC Shift |
|---|---|---|---|
| tap "*" | `12 3E`, `F0 3E F0 12` | false | up |
| Shift down | `12` (SHIFT_FIX shift-key branch: true) | true | down |
| "*" shifted (= "]", `S_ON`): want true = emitted, nothing forced | `5B`, `F0 5B` | true | down |
| Shift up: release path skips SHIFT_FIX | `F0 12` | **true (stale)** | **up** |
| tap "*": want true = stale emitted, no `12` sent | `3E` -> "8" | true | up |
| "*" release: override restore sees phys false /= emitted true | `F0 12` (stray) | false | up |
| tap "*" | `12 3E` -> "*" | false | up |

Releasing the Shift *before* the key hides it: the key's own override
restore then sends a second `F0 12` and resyncs the flag by luck. That is why
it depended on the typing rhythm. The old single flag also could not break
the *right* Shift: a `S_OFF` key (";" = "]" with Shift held, "'" on Shift+7,
F2..F12 on Shift+F1..F11) always sent `F0 12`, which does nothing when the
PC has `59` (Right Shift) down.

The BIOS side is not involved: INT 9 (8088_bios keyboard.inc) reads one
scancode per interrupt, sets or clears the Shift bits in `kbd_flags_1` for
`2A`/`AA`/`36`/`B6` with no timing dependence, and `scan_xlat` picks the ":"
column from those bits. KFPS2KB turns `F0 12` into `AA`. The only way the
BIOS loses a byte is KFPS2KB's overrun/timeout error (`FF`), which needs an
aborted frame first. None of this happened in the benches: every `12` the
translator queued reached INT 9.

## Fix 1 (root cause): model the PC's Shift keys where the bytes are queued
`keyboard.vhd` now keeps `pc_lshift` / `pc_rshift`, the PC's view of each
Shift key, and derives `emitted_shift` from them. They are updated at the
one place a Shift make or break is queued, whatever its origin:

* `CODE`: a physical Shift key's own make/break (`12`, `F0 12`, `59`,
  `F0 59`) sets or clears its bit, for makes and breaks alike.
* `FIX`/`FIX2`: a forced make (`12`) or break (`F0 12` / `F0 59`) queued for
  a `S_ON` / `S_OFF` key.

`SHIFT_FIX` (make of a `S_ON`/`S_OFF` key) forces the state from that
model: `S_ON` sends `12` if neither PC Shift is down; `S_OFF` breaks
whichever PC Shift keys are down (left, then right). The release of the key
that forced the state goes to `RESTORE`, which brings each PC Shift key back
to its physical state (make or break, per key). The forced state now stays in
effect until that key is released; the old code silently cancelled it when a
plain key was pressed meanwhile, leaving the PC's Shift down.

## Fix 2 (robustness): ps2_tx resends a frame the host inhibited
`CORE/vhdl/ps2_tx.vhd` abandoned a frame when the host pulled the clock low
mid-frame and never sent the byte again. The PS/2 protocol requires the
device to retransmit a byte interrupted before its stop bit was clocked. The
byte now leaves the queue at its stop bit's clock edge instead of at the
start of the frame, so an interrupted byte is still at the head of the queue
and goes out again once the line is released. The XT controller inhibits the
clock at that very edge on every byte (KFPS2KB's `irq` is raised by the stop
bit and `ps2_clock_out = ~(irq | ...)`): such a byte is complete and is not
repeated. The queue flush on a host request-to-send (keyboard reset) is
unchanged.

This was not the cause of the report (in the running system nothing inhibits
the clock inside a frame: `irq` follows a complete frame, the BIOS's PB7
pulse releases the line, and port B bit 6 only drops for a keyboard reset,
which flushes the queue anyway), but a frame dropped this way would produce
exactly the same symptom, so the device now follows the spec.

## Evidence
* `CORE/rtl/tb/keyboard_tb.vhd` (`run_keyboard_tb.sh`, GHDL in WSL; the
  translator and PS/2 device alone, frames decoded by the bench): extended
  with the board repro in both release orders, "]" with the right Shift, a
  mid-frame host inhibit (byte must arrive exactly once) and an inhibit right
  after the stop bit (byte must not be repeated). Pre-fix RTL: 29 mismatches
  (the first forced-shift key after any Shift use has no `12`; the inhibited
  byte is lost). Fixed RTL: PASS, 82 bytes, 0 errors. (The bench's old
  HELP = F12 expectation was stale since HELP was handed to the framework; F12
  is checked as Shift+F11 now.)
* `CORE/rtl/tb/kbd_colon_sys_tb.sv` (`run_kbd_colon_sys_tb.ps1`, xsim): the
  real MCL86 running the real 8088 BIOS (bios-xt.bin) on the real PIC / PIT /
  PPI / KFPS2KB and keyboard.vhd + ps2_tx.vhd, typing after the POST has
  unmasked the PIC. Scenarios: the board repro (S1), "a:" with rollover (S2),
  "c:" in fast taps (S3), "A:" and "C:" with the left / right Shift released
  before ":" (S4, S5), ":" then Enter in rollover (S6); checked against the
  BIOS keyboard buffer at 0040:001E (ASCII / BIOS scan code words).
  Fixed RTL: PASS, ring `092a 1b7d 092a 092a 1e61 273a 2e63 273a 1e41 273a
  2e43 273a 273a 1c0d` = `* } * * a : c : A : C : :` Enter, 50 port-60h reads
  while typing, nothing left pending. Pre-fix RTL (`-KbdVhdl <dir with the
  old keyboard.vhd/ps2_tx.vhd>`): FAIL, 3 checks: S1 entry 2 is `0938` "8"
  (the board's step 3), S4 and S5 give `273b` ";" for ":" after the left /
  right Shift use (the original report); the port-60h stream shows the missing
  `2a` (`... 1b 9b aa 09 89 ...`, `... 1e 9e aa 27 a7 ...`). The plain "a:"
  and "c:" cases (S2, S3, S6) pass on both: rollover and speed are not the
  trigger, a preceding physical Shift is.
  About 10 minutes of wall time per run (0.9 s of simulated time).
* `run_kbd_bios_tb.ps1 -Fix` (behavioural CPU replaying both BIOSes' exact
  port sequences, overlay RTL as built): PASS for BIOS=8088 and BIOS=TURBO,
  14 INT 9 entries each, unchanged by the fix. Without `-Fix` it fails the
  five warm-reboot checks on the upstream KF8259 as before
  (docs/pic-isr-warm-boot.md).

## Notes for the board
* Ctrl+Alt+Del and the keyboard reset path are untouched (kbd_bios_tb).
* The stray `F0 12` the old code sent on the override release after a stale
  flag is gone; the only bytes now sent for a Shift key are the ones that
  change the PC's state.

## On the board, 2026-09-18
Confirmed on the R6 with the fix built in: the owner's sequence (`*`, Shift+`*`,
`*`, `*`) types `* } * *`. Before the fix the third press produced `8`.
