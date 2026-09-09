# Floppy write: multi-sector stall (fixed)

Symptom: `copy` to a mounted floppy image wrote ~2 sectors then DOS reported
"drive not ready". On-chip counters: FDC WRITE DATA starts 2, FDD write
requests 3, bridge blk_wr 2, blk_ack 16 (14 reads + 2 writes).

Cause (mgmt_bridge.sv): for a multi-sector WRITE DATA, floppy.v raises
mgmt_req[7] once per sector. The bridge drains the FIFO (which drops the
request), does the slow SD-card block write, then entered S_FDD_WAIT, which
returns to idle only when mgmt_req[7:6] == 0. floppy.v had already
DMA-refilled its FIFO and re-raised the request for the next sector while
the block write was in flight, so S_FDD_WAIT never saw 0 and parked forever.
Reads are immune: their slow block precedes the transfer.

Fix: after a write block, return to S_IDLE; the just-serviced request was
released long before, so the next sector dispatches cleanly. Bench
(mgmt_bridge_tb, [13b]/[13c]: 3-sector write and back-to-back writes with
slow block writes) reproduces the stall with the fix reverted and passes
with it: 5121 checks.
