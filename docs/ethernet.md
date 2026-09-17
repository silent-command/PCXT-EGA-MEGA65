# Ethernet: towards an emulated NE1000 for mTCP

## Goal
Run the mTCP suite (https://www.brutman.com/mTCP/) in DOS on this core, and
use its FTP server to move files to and from the PC without touching the SD
card. mTCP talks to a packet driver; the packet driver talks to a network
card; so the core needs a card that a stock DOS packet driver recognises.

## Plan
1. Physical layer spike: bring the KSZ8081 PHY up, receive and count frames,
   transmit a frame the PC can see, report on the status line. DONE, below.
2. Card emulation: a Novell NE1000 (National DP8390 controller, 8-bit ISA,
   8 KB packet buffer) at port 320h, IRQ 5. The XT bus is 8 bits, so the
   NE1000 is the card an XT would have; its packet driver exists and mTCP
   supports it. Port 300h is the IDE controller; IRQ 5 is one of two external
   lines the chipset brings out unconnected (Peripherals.sv:440-447,
   pcxt_core.sv:1290 ties interrupt_request to 0).
3. Integration: I/O decode, IRQ, OSM option, MAC address from the MEGA65's
   own configuration on the SD card with a menu fallback.
4. Bring-up with mTCP: DHCP, ping, FTP, then the rest.

## Spike result, 2026-09-16
`CORE/vhdl/eth_phy_spike.vhd` (bench `CORE/rtl/tb/eth_phy_spike_tb.sv`, 50
checks). Loaded on the R6 with a cable to the home router:

| what | reading, 46 / 54 / 56 s after load |
|---|---|
| link | up, 100 Mb/s full duplex, PHY id OK, autoneg done, strap 0 |
| frames received | 180 / 216 / 229 |
| with valid FCS | 180 / 216 / 229 (all of them) |
| to our MAC or broadcast | 83 / 92 / 94 |
| transmitted (one ARP request per second) | 53 / 61 / 64 |
| RXER seen | never |

On the PC, `arp -a` shows `192.168.1.250  02-4d-36-35-00-01  dynamic`: the
request crossed the router from wired to Wi-Fi and Windows accepted it.
Build: WNS +0.187, no violations. The spike replaces the three status words
with its counters (" erx=", " etx=", " eth=") and must not ship in that form.

Facts the spike established that the card work relies on:
* The FPGA drives the 50 MHz reference clock (KSZ8081RND powers up in
  50 MHz-input mode); the MAC runs on clk_50 shifted +90 degrees so that the
  PHY's 8-13 ns output delay lands in the middle of the sampling window
  (clk.vhd MMCM B CLKOUT2, `clk_50_ps`). Timing-closed with IOB registers.
* PHY address 0 is accepted as broadcast, so MDIO works whatever the strap.
* Reset: 10 ms low, 1 ms before the first MDIO access, both generous.
* The PHY is not reset by the core's reset button or M2M resets, only by the
  MMCM lock; keep that in mind if link state ever looks stale.
* 10 Mb/s links are not decoded (RMII repeats each dibit ten times); the LAN
  here negotiates 100 Mb/s.

## Effort so far
Physical layer: one afternoon, first bitstream. The estimate had allowed a
week for PHY bring-up surprises; there were none.
