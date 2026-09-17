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

## The card, 2026-09-16
Step 2 of the plan, plus the integration of step 3 except the OSM item and the
SD-card MAC. Files:

| file | what |
|---|---|
| `CORE/rtl/ne1000.sv` | the NE1000: DP8390 register set (pages 0/1/2), 8 KB buffer as block RAM at pages 20h-3Fh, station address PROM at remote addresses 0-1Fh, remote DMA with the PSTOP wrap, receive ring writer, transmit reader, RCR filtering incl. the MAR hash, ISR/IMR, reset port |
| `CORE/vhdl/eth_mac.vhd` | the MAC: the spike's PHY reset / MDIO / RMII engines with the counters and canned ARP replaced by two dual-clock FIFOs (`eth_afifo`, gray pointers) carrying 9-bit entries (byte or end-of-frame + status) between clk_50_ps and the chipset clock; pads to 60, appends the FCS |
| `CORE/rtl/overlay/Peripherals.sv`, `CHIPSET.sv` | decode 320h-33Fh next to the IDE decode, the card instance, one entry in the registered read mux, the IRQ and the MAC streams passed through (overlays: the submodule stays pristine) |
| `CORE/rtl/pcxt_core.sv`, `CORE/vhdl/main.vhd`, `mega65.vhd` | `interrupt_request` bit 5 carries the card (was tied to 0); the MAC sits in mega65.vhd with the pins, the card inside the chipset; `C_ETH_MAC_ADDR` / `C_ETH_ENABLE` in mega65.vhd until the OSM item and the SD-card MAC exist |
| `CORE/CORE.xdc` | instance rename, the FIFO pointer / toggle crossings (datapath-only 20 ns, false paths) |
| `CORE/rtl/tb/ne1000_tb.sv`, `run_ne1000_tb.ps1` | the bench, 131 checks, about 10 ms of simulated time |
| `CORE/m2m-rom/m2m-rom.asm`, `mega65.vhd` | status line back to `bist= req= hdd=` |

`eth_phy_spike.vhd` and its bench stay in the tree as the record of the PHY
bring-up; the build no longer uses them (`add-core-sources.tcl` lists
`eth_mac.vhd` instead and was run to refresh `CORE-R6.xpr`).

### What the bench replays
The register sequences are the Crynwr packet driver's own, taken from
`8390.asm` (dp8390_version 3) and `ne1000.asm` (version 5) of the GPL
collection (crynwr.com no longer resolves; the fragglet/crynwr_mirror GitHub
clone has the sources and `binaries/ne1000.com`). Each bench task is the
driver routine of the same name, register for register, in order:

* `reset_board`: read then write of the reset port (base+1Fh), CR = 21h,
  1.6 ms wait.
* `etopen`: DCR 48h, CR 21h, RBCR 0, RCR 20h (monitor), TCR 02h (loopback),
  `init_card` = 16-byte remote DMA read from address 0 with the NIC started
  (CR 22h, RBCR 16, RSAR 0, CR 0Ah, 16 x IN base+10h; the driver keeps bytes
  0-5 and tests only bit 0 of byte 0), DCR 48h, PSTART 26h, BNRY 26h, PSTOP
  40h, ISR FFh, IMR 3Fh, `set_address` (CR 60h, PAR0-5, CR 20h: page changes
  with STA = STP = 0, which must not stop the chip), `set_hw_multi` (CR 61h,
  MAR0-7, CR 22h: a STOP/START in the middle of init), CR 61h, CURR 27h, CR
  22h, TCR 00h; then head.asm's default `rcv_mode_3`: `set_hw_multi` again and
  RCR 04h. (etopen runs on the first packet-driver call, not at TSR load.)
* `send_pkt`: CR read (TXP busy test), ISR/TSR handling of a previous
  transmit, length stretched to 60, ISR = 40h, TBCR, `block_output` (CR 22h,
  RBCR = count rounded up to even, RSAR 2000h, CR 12h, N x OUT base+10h, ISR
  polled for RDC), TPSR 20h, CR 26h.
* `recv` (the IRQ 5 handler): IMR 00h, ISR read masked with 3Fh; PRX/RXE: ISR
  = 05h, CR 62h, CURR read, CR 22h, then for every packet up to CURR a 26-byte
  `block_input` of the header, status bit 0 and next-page range checks,
  `rcv_frm` = `block_input` of count-4 bytes from offset 4 (linear, so the
  chip's remote DMA must wrap at PSTOP), BNRY = next-1 wrapping to PSTOP-1;
  OVW: CR read, CR 21h, wait, RBCR 0, TCR 02h, CR 22h, CURR read and written
  back, packets removed, BNRY, ISR = 10h, TCR 00h, CR 26h if a transmit was
  pending; PTX/TXE: TSR read, ISR = 0Ah; CNT: three counter reads, ISR = 20h;
  finally IMR 3Fh.

The wire side is the spike bench's KSZ8081/RMII model. Results, all PASS:

| case | what was checked |
|---|---|
| a init | PROM = MAC + 'B''B' at 14/15, CR 22h, ISR 00h (RST cleared by START), CURR 27h, BNRY 26h, PAR, MAR, page-2 readback of PSTART/PSTOP/RCR/TCR/DCR/IMR, no IRQ |
| b transmit | 42-byte ARP: RDC after the DMA write, TXP while sending, exactly 60 bytes on the wire (driver padding) with a good FCS, PTX + TSR 01h + IRQ 5, IRQ released by ISR = 0Ah; a 1513-byte frame (odd count: DMA rounded up, TBCR not) arrives intact; inter-frame gap >= 96 bits |
| c receive | unicast: PRX, RSR 01h, CURR 28h, header {01, 28, 104, 0}, the driver's copy equals the frame, BNRY 27h; broadcast header status 21h; other MAC ignored (CURR unchanged); multicast ignored without AM, accepted with AM and its MAR bit (index from Linux `ether_crc >> 26`), ignored with the bit clear; bad FCS dropped with CNTR1 = 1 (clears on read) and RSR 02h; runt dropped; PRX with IMR = 0 raises no IRQ, writing IMR raises it (what `recv` relies on) |
| d wrap, overflow | six 1514-byte frames read one by one across the 40h -> 26h wrap (remote DMA wrap); with the driver busy (IMR 0) the fifth 6-page frame hits BNRY: OVW, CNTR2 = 1, a further frame while halted counted and not stored, no OVW storm; the driver's overrun path recovers all four stored frames, ISR clean, TCR back to 0, receive and transmit work afterwards |
| e back-to-back | three frames with 96-bit gaps drained in one `recv` pass |
| f misc | disabled card reads FFh everywhere and raises nothing, its writes are ignored; DCR WTS = 1 changes nothing (byte-wide card); the reset port leaves CR 21h / ISR 80h / IMR 0, card stopped |

### Design notes
* Bus: writes and read side effects on the trailing edge of the strobe, as
  XT2IDE -> ide.v; read data is a registered mux, then the chipset's own
  `data_bus_out` register. Nothing touches READY or the multicycle-proven
  launch cells of CORE.xdc; the card's data enters `internal_data_bus` from a
  register like every other peripheral. The card needs two chipset clocks per
  I/O cycle; the I/O settle guard guarantees more even at Max.
* Run state: STP stops, STA starts, both clear leaves it (Bochs/QEMU; the
  driver writes 20h/60h with STA = 0 while running). CR reads back what was
  written, TXP until the frame has left the wire.
* Ring: a frame starts at CURR offset 4; entering any page equal to BNRY
  (including the first) is the overflow; the header count includes the FCS
  and not the header; frames not addressed to the card are dropped after the
  sixth byte and never occupy ring space beyond it. The FCS bytes go into the
  ring, so the driver's count-4 arithmetic yields the frame without it.
* Loopback (TCR LB): a transmit completes at once with PTX and nothing on the
  wire; the driver only uses loopback during init and overrun recovery.
* Port 320h overlaps the MPU-401 at 330h-331h. The MPU-401 is disabled in
  this port (`osm_mpu401_disable_i => '1'`) and wins the read mux if it were
  not; should it come back, one of them moves. IRQ 5 is shared with the
  Sound Blaster unless the SB is on IRQ 7 (`osm_sb_irq7_i`); the XT's 8259 is
  edge-triggered, so sharing is not an option: set the SB to 7 when both are
  in use.
* mTCP never touches the card: it needs a class 1 (Ethernet) packet driver
  with the default receive mode (own address + broadcast, `rcv_mode_3`), which
  is what the Crynwr driver programs; DHCP/ARP replies arrive as broadcast or
  unicast, both stored. The 1514-byte cases above are the MTU mTCP uses.
* MAC address: locally administered 02:4D:36:35:00:01 from `C_ETH_MAC_ADDR`
  in mega65.vhd, delivered to the card on a port (`eth_mac_addr_i`) so the
  SD-card configuration can feed it later. The driver reports it, `arp -a` on
  the PC will show it.
* Resources (Vivado 2026.1 OOC): `ne1000` 614 LUTs, 495 FFs, 2 RAMB36 (the
  8 KB buffer); `eth_mac` 338 LUTs, 504 FFs, 2 RAMB18 (one tile: the two
  FIFOs). Three tiles in total against the 150 committed before system RAM.

### What only the board can prove
The Crynwr driver on real DOS timing (the bench's I/O cycles hold the strobe
for 12 chipset clocks; a 4.77 MHz 8088 gives more, Max speed fewer but still
more than the two the card needs); the 8259 edge behaviour with the driver's
IMR dance under real interrupt latency; that the switch accepts the frames
the MAC pads; the PHY items listed in eth_phy_spike.vhd; timing closure of the
whole core with the card in (the card adds one registered entry to the read
mux and nothing to READY). Then mTCP: `ne1000 0x60 5 0x320`, `dhcp`, `ping`,
`ftp`.

## First DOS test, 2026-09-17: DHCP works
Build of commit d6c7987 (WNS +0.146, no violations) on the R6, FreeDOS from
the hard-disk image, `netdisk.img` in Drive A, `A:\NET`:

```
Packet driver for NE1000, version 11.5.3
Packet driver software interrupt is 0x60 (96)
Interrupt number 0x5 (5)
I/O port 0x320 (800)
My Ethernet address is 02:4D:36:35:00:01
mTCP DHCP Client ... DHCP request sent, attempt 1: Offer received, Acknowledged
IPADDR 192.168.1.168  NETMASK 255.255.255.0  GATEWAY 192.168.1.1
NAMESERVER 192.168.1.1  LEASE_TIME 28800 seconds
Settings written to 'A:\MTCP.CFG'
```

So the Crynwr driver's probe, PROM read, ring setup and interrupt path all
work on the first bitstream, and a full DHCP exchange (broadcast discover,
unicast offer, request, acknowledge) went through the card, the MAC and the
router. The driver warns that an XT hard disk usually uses IRQ 5; ours does
not (XT-IDE is polled), but the emulated Sound Blaster does unless its
"IRQ 7" option is on, so the card needs its own menu setting before release.

Effort so far: physical layer one afternoon, card emulation plus bench one
day, first DOS test passed on the first build. Remaining: menu (card on/off,
IRQ), MAC address from the MEGA65's own configuration, ping/FTP/telnet
verification, release notes.

## File transfer over FTP, 2026-09-17: the second goal, met
With `FTPSRV` running on the XT (working drive C:), from the PC with the
stock Windows `ftp` client, user mega65: `cd DRIVE_C`, `dir` lists the
FreeDOS root, `put` of a text file lands on C:, `get FDCONFIG.SYS` returns
the real file. A 200 KB random file round-trips byte-identical:
10.3 KB/s PC to XT, 14.7 KB/s XT to PC at the 4.77 MHz setting. The XT
answers pings from the PC (15-54 ms) while an mTCP program is running;
with only the packet driver loaded there is no IP stack, so pings time out
then, which is normal. Pings from the XT to the router work; pings from the
XT to this PC time out because of the Windows firewall.

So the SD card is no longer needed to move files: the PC can push and pull
anything on the XT's hard-disk image over the network.
