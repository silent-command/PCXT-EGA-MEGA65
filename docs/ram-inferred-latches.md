# RAM.sv: inferred latches on the memory command path (fixed)

## Symptom
The probe-cleanup build (bbaac0c), whose source diff against the previous
build was only counters, ports and comments, stopped detecting the IDE drive
at POST ("Master at 300h: not found"), while the previous build (d078efd)
booted FreeDOS with the same card and procedure. Firmware log, ROM loads and
the HyperRAM self test were all fine on the failing build.

## Root cause
Upstream `RAM.sv` drives the KFSDRAM command inputs from an `always_comb`
`casez (state)` over a 7-state enum. The enum is 3 bits wide, so one encoding
is uncovered and there is no `default` arm; Vivado inferred latches
(Synth 8-327) for `access_address`, `access_num`, `access_data_in`,
`write_request`, `read_request` and the dqm outputs. A latch's gate pin is
its clock, and here the gate is decoded from the state bits: `check_timing`
reported "33 register/latch pins with no clock driven by root clock pin
u_RAM/FSM_sequential_state_reg/Q". Every path through those latches into the
memory controller (22 address bits, 8 data bits, the requests) was therefore
untimed. WNS was met because none of those paths were in the timing graph.
Whether they worked depended on placement, so one build booted and the next
did not.

## Fix
`CORE/rtl/overlay/RAM.sv`: a `default:` arm with the idle values. The block
is now a plain mux, fully timed. OOC synthesis shows 0 latch warnings; the
DMA benches that drive the real RAM.sv + KFSDRAM (`fdc_dma_wr_tb`,
`fdc_dma_8237_tb`) pass.

## Lesson
For a placement-sensitive failure, check the synth log for "inferring latch"
and run `check_timing` on the routed checkpoint before bisecting source.
The CDC report is unusable here (22k upstream entries); `check_timing`'s
no_clock section was the decisive signal. Any Synth 8-327 in the port's own
or overlaid files is a release blocker.
