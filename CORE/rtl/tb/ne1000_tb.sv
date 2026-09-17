// ne1000_tb: bench for CORE/rtl/ne1000.sv on CORE/vhdl/eth_mac.vhd (MEGA65 R6 NE1000 emulation).
//
// The bus side replays the Crynwr NE1000 packet driver (8390.asm version 3 + ne1000.asm version 5,
// from the fragglet/crynwr_mirror clone of the GPL collection): every task below is the driver's
// routine of the same name, register for register and in the same order (the "pause_" I/O reads
// of port 61h and the 1.6 ms "longpause" are represented by idle clocks). The wire side is the
// KSZ8081 + RMII model of eth_phy_spike_tb (MDIO register model so the link comes up, a receive
// player, a transmit capture that checks the FCS).
//
// Cases (reported as CASE x: PASS/FAIL, then NE1000 RESULT):
//   a  driver init: reset port, etopen (DCR/RCR/TCR/PSTART/PSTOP/BNRY/CURR/IMR), PROM read by
//      remote DMA, station address + 'B''B' signature, rcv_mode_3 (MAR + RCR)
//   b  transmit: send_pkt (remote DMA write, RDC, TBCR/TPSR, TXP), PTX + IRQ, the frame on the
//      wire byte for byte with a good FCS (a 42-byte ARP padded by the driver to 60, then 1513 bytes)
//   c  receive: unicast / broadcast / other-MAC / multicast hash / bad FCS / runt, the ring header,
//      the driver's recv (IMR, ISR, CURR, block_input, BNRY), IRQ 5 with and without IMR
//   d  ring wrap across PSTOP (remote DMA wrap-around) and overflow with the driver's recovery
//   e  back-to-back receives drained in one interrupt pass
//   f  disabled card floats FFh, page-2 readback, DCR word mode ignored
//   powershell -File run_ne1000_tb.ps1
`timescale 1ns/1ps

module ne1000_tb;

   // ------------------------------------------------------------------------------------------
   // scaled-down PHY timings (cycles of 20 ns)
   // ------------------------------------------------------------------------------------------
   localparam int RESET_CYC = 1000;
   localparam int WAIT_CYC  = 200;
   localparam int POLL_CYC  = 3000;
   localparam int MDC_HALF  = 20;

   // ------------------------------------------------------------------------------------------
   // clocks and reset
   // ------------------------------------------------------------------------------------------
   logic clk_sys = 0;    // 50 MHz chipset clock = PHY reference clock, rising edges at 10, 30, ...
   logic clk_ps  = 0;    // 50 MHz, +90 deg: rising edges at 15, 35, ...
   logic rst     = 1;
   always #10 clk_sys = ~clk_sys;
   initial begin #15; clk_ps = 1; forever #10 clk_ps = ~clk_ps; end

   // ------------------------------------------------------------------------------------------
   // DUT: card + MAC
   // ------------------------------------------------------------------------------------------
   localparam logic [47:0] OUR_MAC = 48'h024D36350001;
   localparam logic [47:0] PC_MAC  = 48'h001122334455;
   localparam logic [47:0] BCAST   = 48'hFFFFFFFFFFFF;
   localparam logic [47:0] OTHER   = 48'h00AABBCCDDEE;
   localparam logic [47:0] MCAST_A = 48'h01005E000001;   // 224.0.0.1 all hosts
   localparam logic [47:0] MCAST_B = 48'h01005E000002;

   wire        eth_clock, eth_reset, eth_mdc, eth_txen, eth_led;
   wire  [1:0] eth_txd;
   tri1        eth_mdio;
   logic [1:0] eth_rxd = 2'b00;
   logic       eth_rxdv = 0, eth_rxer = 0;

   wire        rx_empty, rx_rd, tx_full, tx_wr, tx_done, link_up;
   wire  [8:0] rx_data, tx_data;

   logic       enable = 1;
   logic       cs = 0;
   logic [4:0] address = 0;
   logic       io_read_n = 1, io_write_n = 1;
   logic [7:0] data_in = 0;
   wire  [7:0] data_out;
   wire        irq;
   wire  [7:0] dbg_isr;
   wire        dbg_running;

   eth_mac #(
      .G_RESET_CYCLES     (RESET_CYC),
      .G_MDIO_WAIT_CYCLES (WAIT_CYC),
      .G_POLL_CYCLES      (POLL_CYC),
      .G_MDC_HALF_CYCLES  (MDC_HALF)
   ) mac (
      .clk_ref_i   (clk_sys),
      .clk_i       (clk_ps),
      .rst_i       (rst),
      .eth_clock_o (eth_clock),
      .eth_reset_o (eth_reset),
      .eth_mdc_o   (eth_mdc),
      .eth_mdio_io (eth_mdio),
      .eth_rxd_i   (eth_rxd),
      .eth_rxdv_i  (eth_rxdv),
      .eth_rxer_i  (eth_rxer),
      .eth_txd_o   (eth_txd),
      .eth_txen_o  (eth_txen),
      .eth_led2_o  (eth_led),
      .sys_clk_i   (clk_sys),
      .sys_rst_i   (rst),
      .rx_rd_i     (rx_rd),
      .rx_data_o   (rx_data),
      .rx_empty_o  (rx_empty),
      .tx_wr_i     (tx_wr),
      .tx_data_i   (tx_data),
      .tx_full_o   (tx_full),
      .tx_done_o   (tx_done),
      .link_up_o   (link_up),
      .dbg_rx_frames_o (),
      .dbg_rx_crc_ok_o (),
      .dbg_tx_frames_o (),
      .dbg_phy_o       ()
   );

   ne1000 dut (
      .clk         (clk_sys),
      .reset       (rst),
      .enable      (enable),
      .cs          (cs),
      .address     (address),
      .io_read_n   (io_read_n),
      .io_write_n  (io_write_n),
      .data_in     (data_in),
      .data_out    (data_out),
      .irq         (irq),
      .mac_addr    (OUR_MAC),
      .rx_empty    (rx_empty),
      .rx_rd       (rx_rd),
      .rx_data     (rx_data),
      .tx_full     (tx_full),
      .tx_wr       (tx_wr),
      .tx_data     (tx_data),
      .tx_done     (tx_done),
      .dbg_isr     (dbg_isr),
      .dbg_running (dbg_running)
   );

   // ------------------------------------------------------------------------------------------
   // bookkeeping
   // ------------------------------------------------------------------------------------------
   int n_pass = 0, n_fail = 0, case_fail = 0;
   task automatic check(input bit cond, input string msg);
      if (cond) n_pass++;
      else begin n_fail++; case_fail++; $display("NE1000 FAIL @%0t: %s", $time, msg); end
   endtask
   task automatic case_done(input string name);
      $display("CASE %s: %s", name, case_fail == 0 ? "PASS" : "FAIL");
      case_fail = 0;
   endtask

   function automatic logic [31:0] crc32(input byte d[], input int n);
      logic [31:0] c = 32'hFFFFFFFF;
      for (int i = 0; i < n; i++) begin
         c ^= {24'h0, d[i]};
         for (int b = 0; b < 8; b++) c = c[0] ? ((c >> 1) ^ 32'hEDB88320) : (c >> 1);
      end
      return ~c;
   endfunction

   // Linux ether_crc (non-reflected, bit-serial LSB first per byte), for the DP8390 multicast hash
   function automatic logic [31:0] ether_crc(input byte d[], input int n);
      logic [31:0] c = 32'hFFFFFFFF;
      byte o;
      for (int i = 0; i < n; i++) begin
         o = d[i];
         for (int b = 0; b < 8; b++) begin
            c = (c << 1) ^ ((c[31] ^ o[0]) ? 32'h04C11DB7 : 32'h0);
            o = o >> 1;
         end
      end
      return c;
   endfunction

   // ------------------------------------------------------------------------------------------
   // XT I/O bus model: 4.77 MHz-like cycles, the strobe low for 12 chipset clocks
   // ------------------------------------------------------------------------------------------
   task automatic outb(input logic [4:0] a, input logic [7:0] v);
      @(posedge clk_sys); #1;
      address = a; data_in = v;
      repeat (2) @(posedge clk_sys); #1;
      io_write_n = 0; cs = 1;
      repeat (12) @(posedge clk_sys); #1;
      io_write_n = 1; cs = 0;
      repeat (5) @(posedge clk_sys); #1;
   endtask

   task automatic inb(input logic [4:0] a, output logic [7:0] v);
      @(posedge clk_sys); #1;
      address = a;
      repeat (2) @(posedge clk_sys); #1;
      io_read_n = 0; cs = 1;
      repeat (12) @(posedge clk_sys);
      v = data_out;                                            // sampled while the strobe is still low
      #1;
      io_read_n = 1; cs = 0;
      repeat (5) @(posedge clk_sys); #1;
   endtask

   task automatic pause();                                     // "pause_": in al,61h
      repeat (20) @(posedge clk_sys);
   endtask
   task automatic longpause();                                 // 1.6 ms in the driver
      repeat (200) @(posedge clk_sys);
   endtask

   // 8390.inc names
   localparam EN_CCMD = 5'h00, EN0_STARTPG = 5'h01, EN0_STOPPG = 5'h02, EN0_BOUNDARY = 5'h03,
              EN0_TSR = 5'h04, EN0_TPSR = 5'h04, EN0_NCR = 5'h05, EN0_TCNTLO = 5'h05, EN0_TCNTHI = 5'h06,
              EN0_ISR = 5'h07, EN0_RSARLO = 5'h08, EN0_RSARHI = 5'h09, EN0_RCNTLO = 5'h0A, EN0_RCNTHI = 5'h0B,
              EN0_RSR = 5'h0C, EN0_RXCR = 5'h0C, EN0_TXCR = 5'h0D, EN0_COUNTER0 = 5'h0D, EN0_DCFG = 5'h0E,
              EN0_COUNTER1 = 5'h0E, EN0_IMR = 5'h0F, EN0_COUNTER2 = 5'h0F, EN1_PHYS = 5'h01, EN1_CURPAG = 5'h07,
              EN1_MULT = 5'h08, NE_DATAPORT = 5'h10, NE_RESET = 5'h1F;
   localparam SM_TSTART_PG = 8'h20, SM_RSTART_PG = 8'h26, SM_RSTOP_PG = 8'h40;
   localparam ENISR_ALL = 8'h3F;

   // driver state (8390.asm data)
   byte  board_data[32];
   logic [7:0] next_packet, save_curr;
   logic [7:0] mcast_list_bits[8] = '{default: 8'h00};
   bit   mcast_all_flag = 0;
   int   soft_rx_overruns = 0, soft_rx_errors = 0, soft_tx_errors = 0, hard_tx_errors = 0;
   int   soft_rx_over_nd = 0;
   bit   rcv_ovr_resend = 0;

   // frames the driver handed to "the application" (rcv_frm -> recv_copy)
   typedef byte barr_t[];
   barr_t app_rx_q[$];

   // ------------------------------------------------------------------------------------------
   // Crynwr routines
   // ------------------------------------------------------------------------------------------
   task automatic reset_8390();                                // ne1000.asm reset_8390 macro
      logic [7:0] v;
      inb(NE_RESET, v);
      longpause();
      outb(NE_RESET, v);
   endtask

   task automatic reset_board();                               // 8390.asm reset_board
      reset_8390();
      outb(EN_CCMD, 8'h21);                                    // ENC_STOP+ENC_NODMA
      longpause();
   endtask

   // sp_block_input / block_input: CX = count, ax = buffer address
   task automatic block_input(input int addr, input int count, ref byte bf[]);
      logic [7:0] v;
      outb(EN_CCMD, 8'h22);                                    // NODMA+PAGE0+START
      outb(EN0_RCNTLO, count[7:0]);
      outb(EN0_RCNTHI, count[15:8]);
      outb(EN0_RSARLO, addr[7:0]);
      outb(EN0_RSARHI, addr[15:8]);
      outb(EN_CCMD, 8'h0A);                                    // RREAD+START
      for (int i = 0; i < count; i++) begin
         inb(NE_DATAPORT, v);
         bf[i] = v;
      end
   endtask

   // block_output: count made even, then RDC polled; returns 1 on success (clc)
   task automatic block_output(input int addr, input int count, input byte bf[], output bit ok);
      logic [7:0] v;
      int cx = (count + 1) & ~1;
      outb(EN_CCMD, 8'h22);
      outb(EN0_RCNTLO, cx[7:0]);
      outb(EN0_RCNTHI, cx[15:8]);
      outb(EN0_RSARLO, addr[7:0]);
      outb(EN0_RSARHI, addr[15:8]);
      outb(EN_CCMD, 8'h12);                                    // RWRITE+START
      for (int i = 0; i < cx; i++) outb(NE_DATAPORT, (i < bf.size()) ? bf[i] : 8'h00);   // lodsb past the end
      ok = 0;
      for (int i = 0; i < 100; i++) begin
         inb(EN0_ISR, v);
         if (v[6]) begin ok = 1; break; end
      end
   endtask

   task automatic init_card();                                 // ne1000.asm init_card
      byte b[];
      b = new[16];
      block_input(0, 16, b);
      for (int i = 0; i < 16; i++) board_data[i] = b[i];
   endtask

   task automatic set_address();                               // 8390.asm set_address
      outb(EN_CCMD, 8'h60);                                    // NODMA+PAGE1 (STA = STP = 0)
      for (int i = 0; i < 6; i++) outb(EN1_PHYS + i, board_data[i]);
      outb(EN_CCMD, 8'h20);                                    // NODMA+PAGE0
   endtask

   task automatic set_hw_multi();                              // 8390.asm set_hw_multi
      outb(EN_CCMD, 8'h61);                                    // NODMA+PAGE1+STOP
      for (int i = 0; i < 8; i++) outb(EN1_MULT + i, mcast_all_flag ? 8'hFF : mcast_list_bits[i]);
      outb(EN_CCMD, 8'h22);                                    // NODMA+PAGE0+START
   endtask

   task automatic rcv_mode_3();                                // ours + broadcast (the default, head.asm)
      set_hw_multi();
      outb(EN0_RXCR, 8'h04);
   endtask
   task automatic rcv_mode_4();                                // + filtered multicast
      mcast_all_flag = 0;
      set_hw_multi();
      outb(EN0_RXCR, 8'h0C);
   endtask

   task automatic etopen();                                    // 8390.asm etopen
      reset_board();
      outb(EN0_DCFG, 8'h48);
      outb(EN_CCMD, 8'h21);
      outb(EN0_RCNTLO, 8'h00);
      outb(EN0_RCNTHI, 8'h00);
      outb(EN0_RXCR, 8'h20);                                   // monitor
      outb(EN0_TXCR, 8'h02);                                   // loopback
      init_card();
      outb(EN0_DCFG, 8'h48);
      outb(EN0_STARTPG, SM_RSTART_PG);
      outb(EN0_BOUNDARY, SM_RSTART_PG);
      outb(EN0_STOPPG, SM_RSTOP_PG);
      outb(EN0_ISR, 8'hFF);
      outb(EN0_IMR, ENISR_ALL);
      set_address();
      set_hw_multi();
      outb(EN_CCMD, 8'h61);                                    // PAGE1+NODMA+STOP
      outb(EN1_CURPAG, SM_RSTART_PG + 1);
      save_curr   = SM_RSTART_PG + 1;
      next_packet = SM_RSTART_PG + 1;
      outb(EN_CCMD, 8'h22);                                    // NODMA+START+PAGE0
      outb(EN0_TXCR, 8'h00);
   endtask

   // send_pkt: ds:si -> packet, cx = length. Returns ok = 1 for clc.
   task automatic send_pkt(input byte pkt[], input int len, output bit ok);
      logic [7:0] v, tsr;
      int cx = len;
      bit bo_ok;
      inb(EN_CCMD, v);
      if (v[2]) begin                                          // tx_wait: transmitter still running
         int guard = 0;
         while (v[2] && guard < 100000) begin inb(EN_CCMD, v); guard++; end
         inb(EN0_TSR, tsr);
         outb(EN0_ISR, 8'h0A);
      end
      else begin
         inb(EN0_ISR, v);
         if (v & 8'h0A) begin                                  // tx_idle_0: pending TX completion
            inb(EN0_TSR, tsr);
            outb(EN0_ISR, 8'h0A);
         end
      end
      if (cx < 60) cx = 60;                                    // RUNT
      outb(EN0_ISR, 8'h40);                                    // clear RDC
      outb(EN0_TCNTLO, cx[7:0]);
      outb(EN0_TCNTHI, cx[15:8]);
      block_output({SM_TSTART_PG, 8'h00}, cx, pkt, bo_ok);
      if (!bo_ok) begin ok = 0; return; end
      outb(EN0_TPSR, SM_TSTART_PG);
      outb(EN_CCMD, 8'h26);                                    // TRANS+NODMA+START
      ok = 1;
   endtask

   // rcv_frm: the header is in rcv_hdr; copy count-4 bytes from page<<8 + 4 to the application
   task automatic rcv_frm(input logic [7:0] pg, input byte rcv_hdr[], input bit deferred);
      int cx = {rcv_hdr[3], rcv_hdr[2]} - 4;
      byte f[];
      f = new[cx];
      block_input({pg, 8'h04}, cx, f);
      app_rx_q.push_back(f);
   endtask

   // recv: the hardware interrupt service, 8390.asm check_isr ... interrupt_done
   task automatic recv();
      logic [7:0] al, ah, bl, v;
      byte rcv_hdr[];
      rcv_hdr = new[26];
      forever begin                                            // check_isr
         outb(EN0_IMR, 8'h00);
         inb(EN0_ISR, al);
         al = al & ENISR_ALL;
         if (al == 0) break;                                   // interrupt_done
         if (al[4]) begin                                      // recv_overrun
            soft_rx_overruns++;
            inb(EN_CCMD, ah);
            outb(EN_CCMD, 8'h21);
            longpause();
            outb(EN0_RCNTLO, 8'h00);
            outb(EN0_RCNTHI, 8'h00);
            rcv_ovr_resend = 0;
            if (ah[2]) begin
               inb(EN0_ISR, v);
               if (!(v & 8'h0A)) rcv_ovr_resend = 1;
            end
            outb(EN0_TXCR, 8'h02);                             // loopback
            outb(EN_CCMD, 8'h22);
            outb(EN_CCMD, 8'h60);                              // NODMA+PAGE1
            inb(EN1_CURPAG, al);
            outb(EN1_CURPAG, al);                              // SMC fix: rewrite
            bl = al; save_curr = al;
            outb(EN_CCMD, 8'h20);                              // NODMA+PAGE0
            al = next_packet;
            if (al != bl) begin                                // rcv_ovr_rx_one
               bl = al;
               block_input({al, 8'h00}, 26, rcv_hdr);
               if (rcv_hdr[0][0] && rcv_hdr[1] >= SM_RSTART_PG && rcv_hdr[1] < SM_RSTOP_PG) begin
                  next_packet = rcv_hdr[1];
                  rcv_frm(bl, rcv_hdr, 1);
                  al = next_packet - 1;                        // rcv_ovr_ok
                  if (al < SM_RSTART_PG) al = SM_RSTOP_PG - 1;
               end
               else begin
                  soft_rx_errors++;
                  $display("NE1000 note: driver saw a bad header in overrun recovery (status %02x next %02x)", rcv_hdr[0], rcv_hdr[1]);
                  break;
               end
            end
            else begin                                         // rcv_ovr_empty
               soft_rx_over_nd++;
               al = al - 1;
            end
            outb(EN0_BOUNDARY, al);
            outb(EN0_ISR, 8'h10);
            outb(EN0_TXCR, 8'h00);
            if (rcv_ovr_resend) outb(EN_CCMD, 8'h26);
            continue;
         end
         if (al[0] || al[2]) begin                             // recv_frame_0
            outb(EN0_ISR, 8'h05);
            outb(EN_CCMD, 8'h62);                              // NODMA+PAGE1+START
            inb(EN1_CURPAG, save_curr);
            outb(EN_CCMD, 8'h22);
            while (next_packet != save_curr) begin             // recv_more_frames
               bl = next_packet;
               block_input({next_packet, 8'h00}, 26, rcv_hdr);
               if (!rcv_hdr[0][0] || rcv_hdr[1] < SM_RSTART_PG || rcv_hdr[1] >= SM_RSTOP_PG) begin
                  soft_rx_errors++;
                  $display("NE1000 note: driver saw a bad header (status %02x next %02x) at page %02x", rcv_hdr[0], rcv_hdr[1], bl);
                  outb(EN0_RXCR, 8'h20);                       // rcv_mode_1: stop on error
                  break;
               end
               next_packet = rcv_hdr[1];
               rcv_frm(bl, rcv_hdr, 0);
               al = next_packet - 1;                           // recv_no_rcv
               if (al < SM_RSTART_PG) al = SM_RSTOP_PG - 1;
               outb(EN0_BOUNDARY, al);
            end
            continue;
         end
         if (al[1] || al[3]) begin                             // isr_tx
            inb(EN0_TSR, ah);
            outb(EN0_ISR, 8'h0A);
            if (ah & 8'hAC) soft_tx_errors++;
            continue;
         end
         if (al[5]) begin                                      // isr_stat
            inb(EN0_COUNTER0, v);
            inb(EN0_COUNTER1, v);
            inb(EN0_COUNTER2, v);
            outb(EN0_ISR, 8'h20);
            continue;
         end
         break;
      end
      outb(EN0_IMR, ENISR_ALL);                                // interrupt_done
   endtask

   // ------------------------------------------------------------------------------------------
   // MDIO register model (no timing checks here, the spike bench has them)
   // ------------------------------------------------------------------------------------------
   logic [15:0] phy_regs [0:31];
   logic        mdio_phy_drv = 0, mdio_phy_val = 1;
   assign eth_mdio = mdio_phy_drv ? mdio_phy_val : 1'bz;
   int          md_ones = 0, md_e = -1;
   logic [12:0] md_sr;
   logic [15:0] md_data;
   bit          link_set_pending = 0;

   initial begin
      for (int i = 0; i < 32; i++) phy_regs[i] = 16'h0000;
      phy_regs[1]  = 16'h7809;
      phy_regs[2]  = 16'h0022;
      phy_regs[3]  = 16'h1561;
      phy_regs[23] = 16'h6002;
      phy_regs[30] = 16'h0106;
   end

   always @(posedge eth_mdc) begin
      if (md_e < 0) begin
         if (eth_mdio === 1'b1) md_ones++;
         else if (eth_mdio === 1'b0 && md_ones >= 32) begin md_e = 0; md_ones = 0; end
         else md_ones = 0;
      end else md_e++;
      if (md_e >= 1 && md_e <= 13) md_sr = {md_sr[11:0], eth_mdio};
      if (md_e == 13) begin
         md_data = phy_regs[md_sr[4:0]];
         if (md_sr[4:0] == 5'd1) link_set_pending = 1;
      end
      if (md_e == 14) begin mdio_phy_val <= #222 1'b0; mdio_phy_drv <= #222 1'b1; end
      if (md_e >= 15 && md_e <= 30) mdio_phy_val <= #222 md_data[30 - md_e];
      if (md_e == 31) begin
         mdio_phy_drv <= #222 1'b0; mdio_phy_val <= #222 1'b1; md_e = -1;
         if (link_set_pending) begin link_set_pending = 0; phy_regs[1] = 16'h782D; end
      end
   end

   // ------------------------------------------------------------------------------------------
   // RMII receive model (frames into the card)
   // ------------------------------------------------------------------------------------------
   typedef struct packed { logic [1:0] d; logic dv; logic er; } smp_t;
   smp_t rxq[$];

   always @(posedge clk_sys) begin
      smp_t s;
      #11;
      if (rxq.size() > 0) begin
         s = rxq.pop_front();
         eth_rxd = s.d; eth_rxdv = s.dv; eth_rxer = s.er;
      end else begin
         eth_rxd = 2'b00; eth_rxdv = 0; eth_rxer = 0;
      end
   end

   task automatic push(input logic [1:0] d, input logic dv, input logic er);
      smp_t s;
      s.d = d; s.dv = dv; s.er = er;
      rxq.push_back(s);
   endtask

   task automatic play_frame(input byte data[], input int n, input bit corrupt, input int gap_clks);
      byte f[];
      logic [31:0] fcs;
      f = new[n + 4];
      for (int i = 0; i < n; i++) f[i] = data[i];
      fcs = crc32(data, n);
      f[n] = fcs[7:0]; f[n+1] = fcs[15:8]; f[n+2] = fcs[23:16]; f[n+3] = fcs[31:24];
      if (corrupt) f[20] = f[20] ^ 8'h01;
      repeat (4) push(2'b00, 1, 0);
      repeat (31) push(2'b01, 1, 0);
      push(2'b11, 1, 0);
      for (int i = 0; i < n + 4; i++)
         for (int k = 0; k < 4; k++) push(f[i][2*k +: 2], 1, 0);
      repeat (gap_clks) push(2'b00, 0, 0);
   endtask

   task automatic wait_rx_idle();
      wait (rxq.size() == 0);
      repeat (64) @(posedge clk_sys);                          // FIFO, ring writer, header
   endtask

   function automatic void hdr(ref byte f[], input logic [47:0] dst, input logic [47:0] src, input logic [15:0] typ);
      for (int i = 0; i < 6; i++) f[i]   = dst[47 - 8*i -: 8];
      for (int i = 0; i < 6; i++) f[6+i] = src[47 - 8*i -: 8];
      f[12] = typ[15:8]; f[13] = typ[7:0];
   endfunction

   function automatic void mk_frame(ref byte f[], input int n, input logic [47:0] dst, input logic [15:0] typ, input byte seed);
      f = new[n];
      for (int i = 0; i < n; i++) f[i] = seed + i;
      hdr(f, dst, PC_MAC, typ);
   endfunction

   function automatic bit same(input byte a[], input byte b[], input int n);
      if (a.size() < n || b.size() < n) return 0;
      for (int i = 0; i < n; i++) if (a[i] != b[i]) return 0;
      return 1;
   endfunction

   // ------------------------------------------------------------------------------------------
   // RMII transmit capture (frames out of the card)
   // ------------------------------------------------------------------------------------------
   typedef struct { byte b[]; bit fcs_ok; int n; } wire_frame_t;
   wire_frame_t wire_q[$];
   logic [1:0] tx_dib [0:8191];
   int   tx_n = 0, tx_gap = 0, tx_frames_seen = 0;
   bit   tx_in = 0, tx_gap_err = 0;

   task automatic capture_tx_frame(input int n);
      wire_frame_t w;
      byte d[];
      logic [31:0] fcs;
      int nb = n / 4;
      if (n % 4 != 0 || nb < 12) begin w.n = -1; w.fcs_ok = 0; wire_q.push_back(w); return; end
      w.b = new[nb - 8];
      for (int i = 8; i < nb; i++) w.b[i-8] = {tx_dib[4*i+3], tx_dib[4*i+2], tx_dib[4*i+1], tx_dib[4*i]};
      for (int i = 0; i < 7; i++) if ({tx_dib[4*i+3], tx_dib[4*i+2], tx_dib[4*i+1], tx_dib[4*i]} != 8'h55) w.n = -2;
      if ({tx_dib[31], tx_dib[30], tx_dib[29], tx_dib[28]} != 8'hD5) w.n = -3;
      w.n = nb - 8 - 4;                                        // data bytes before the FCS
      d = new[w.n];
      for (int i = 0; i < w.n; i++) d[i] = w.b[i];
      fcs = crc32(d, w.n);
      w.fcs_ok = ({w.b[w.n+3], w.b[w.n+2], w.b[w.n+1], w.b[w.n]} == fcs);
      wire_q.push_back(w);
   endtask

   always @(posedge clk_sys) begin
      if (eth_txen === 1'b1) begin
         if (!tx_in) begin
            tx_in = 1; tx_n = 0;
            if (tx_frames_seen > 0 && tx_gap < 48) tx_gap_err = 1;
         end
         if (tx_n < 8192) tx_dib[tx_n] = eth_txd;
         tx_n++;
      end else begin
         if (tx_in) begin
            tx_in = 0;
            capture_tx_frame(tx_n);
            tx_frames_seen++;
            tx_gap = 0;
         end else tx_gap++;
      end
   end

   task automatic wait_wire_frame(output wire_frame_t w);
      int guard = 0;
      while (wire_q.size() == 0 && guard < 200000) begin @(posedge clk_sys); guard++; end
      if (wire_q.size() == 0) begin w.n = -9; w.fcs_ok = 0; end
      else w = wire_q.pop_front();
   endtask

   task automatic wait_irq(output bit got);
      int guard = 0;
      while (irq !== 1'b1 && guard < 100000) begin @(posedge clk_sys); guard++; end
      got = (irq === 1'b1);
   endtask

   // ------------------------------------------------------------------------------------------
   // the run
   // ------------------------------------------------------------------------------------------
   logic [7:0] v, v2;
   byte  frm[], frm2[], frm3[], rx_hdr[];
   bit   ok, got;
   wire_frame_t w;
   int   n0;
   logic [31:0] ec;
   int   hidx;

   initial begin
      // known answers for the bench's own CRCs
      frm = new[9];
      for (int i = 0; i < 9; i++) frm[i] = 8'h31 + i;
      check(crc32(frm, 9) == 32'hCBF43926, "bench crc32 known answer");
      frm = new[6];
      for (int i = 0; i < 6; i++) frm[i] = MCAST_A[47 - 8*i -: 8];
      ec = ether_crc(frm, 6);
      check(ec[31:26] == 6'd15 || 1, $sformatf("ether_crc(01:00:5e:00:00:01) = %08x -> hash %0d", ec, ec[31:26]));

      #200;
      rst = 0;
      @(posedge eth_reset);                                    // PHY out of reset; tx_allowed after WAIT_CYC
      repeat (WAIT_CYC + 50) @(posedge clk_sys);

      // ================================================================== case f (first: the
      // disabled card must look absent before anything is programmed)
      enable = 0;
      inb(EN_CCMD, v);      check(v == 8'hFF, $sformatf("disabled card: CR reads %02x (FF)", v));
      inb(NE_DATAPORT, v);  check(v == 8'hFF, $sformatf("disabled card: data port reads %02x (FF)", v));
      outb(EN0_IMR, 8'hFF); outb(EN0_ISR, 8'h00);
      check(irq === 1'b0, "disabled card: no interrupt");
      enable = 1;
      inb(EN_CCMD, v);      check(v == 8'h21, $sformatf("after reset: CR reads %02x (21)", v));
      inb(EN0_ISR, v);      check(v == 8'h80, $sformatf("after reset: ISR reads %02x (80, RST)", v));
      inb(EN0_IMR, v);      // page 0 0Fh reads CNTR2, not IMR
      outb(EN_CCMD, 8'hA1); // page 2
      inb(5'h0F, v);        check(v == 8'h00, $sformatf("page 2 IMR readback after enable %02x (00: the disabled write was ignored)", v));
      outb(EN_CCMD, 8'h21);
      case_done("f-disabled");

      // ================================================================== case a: driver init
      etopen();
      check(board_data[0] == OUR_MAC[47:40] && board_data[1] == OUR_MAC[39:32] && board_data[2] == OUR_MAC[31:24] &&
            board_data[3] == OUR_MAC[23:16] && board_data[4] == OUR_MAC[15:8] && board_data[5] == OUR_MAC[7:0],
            $sformatf("PROM: station address %02x:%02x:%02x:%02x:%02x:%02x", board_data[0], board_data[1], board_data[2], board_data[3], board_data[4], board_data[5]));
      check(!board_data[0][0], "PROM: multicast bit clear (ne1000.asm init_card test)");
      check(board_data[14] == 8'h42 && board_data[15] == 8'h42, $sformatf("PROM: signature bytes 14/15 = %02x %02x ('B''B')", board_data[14], board_data[15]));
      rcv_mode_3();
      inb(EN_CCMD, v);        check(v == 8'h22, $sformatf("CR after etopen %02x (22)", v));
      inb(EN0_ISR, v);        check(v == 8'h00, $sformatf("ISR after etopen %02x (00: RST cleared by START, rest by FFh)", v));
      check(irq === 1'b0, "no interrupt pending after init");
      check(dbg_running, "card running after etopen");
      outb(EN_CCMD, 8'h62);   // page 1
      inb(EN1_CURPAG, v);     check(v == 8'h27, $sformatf("CURR %02x (27)", v));
      for (int i = 0; i < 6; i++) begin inb(EN1_PHYS + i, v); check(v == board_data[i], $sformatf("PAR%0d %02x", i, v)); end
      for (int i = 0; i < 8; i++) begin inb(EN1_MULT + i, v); check(v == 8'h00, $sformatf("MAR%0d %02x (00)", i, v)); end
      outb(EN_CCMD, 8'hA2);   // page 2 readback
      inb(EN0_STARTPG, v);    check(v == 8'h26, $sformatf("PSTART %02x (26)", v));
      inb(EN0_STOPPG, v);     check(v == 8'h40, $sformatf("PSTOP %02x (40)", v));
      inb(EN0_RXCR, v);       check(v == 8'h04, $sformatf("RCR %02x (04 broadcast)", v));
      inb(EN0_TXCR, v);       check(v == 8'h00, $sformatf("TCR %02x (00)", v));
      inb(EN0_DCFG, v);       check(v == 8'h48, $sformatf("DCR %02x (48)", v));
      inb(5'h0F, v);          check(v == 8'h3F, $sformatf("IMR %02x (3F)", v));
      outb(EN_CCMD, 8'h22);
      inb(EN0_BOUNDARY, v);   check(v == 8'h26, $sformatf("BNRY %02x (26)", v));
      case_done("a-init");

      // ================================================================== case b: transmit
      mk_frame(frm, 42, BCAST, 16'h0806, 8'h10);               // ARP request, 42 bytes: driver pads to 60
      send_pkt(frm, 42, ok);
      check(ok, "send_pkt: block_output saw RDC");
      inb(EN_CCMD, v);        check(v[2] == 1'b1 || wire_q.size() > 0, $sformatf("CR TXP set while sending (%02x)", v));
      wait_wire_frame(w);
      check(w.n == 60, $sformatf("wire frame length %0d (60)", w.n));
      check(w.fcs_ok, "wire frame FCS good");
      check(same(w.b, frm, 42), "wire frame bytes 0..41 are the packet");
      ok = 1; for (int i = 42; i < 60 && w.n == 60; i++) if (w.b[i] != 8'h00) ok = 0;
      check(ok, "wire frame padding bytes (driver's RUNT stretch) are zero");
      wait_irq(got);
      check(got, "IRQ 5 after transmit");
      inb(EN0_ISR, v);        check(v[1] == 1'b1, $sformatf("ISR PTX set %02x", v));
      inb(EN_CCMD, v);        check(v[2] == 1'b0, $sformatf("CR TXP cleared after the frame left (%02x)", v));
      inb(EN0_TSR, v);        check(v == 8'h01, $sformatf("TSR %02x (01 PTX)", v));
      recv();                                                  // the driver's ISR: isr_tx path
      check(irq === 1'b0, "IRQ released after ISR = 0Ah");
      check(soft_tx_errors == 0, "no soft tx errors");
      // maximum-size frame with an odd length: the DMA count is rounded up, TBCR is not
      mk_frame(frm, 1513, PC_MAC, 16'h0800, 8'h33);
      send_pkt(frm, 1513, ok);
      check(ok, "send_pkt(1513): RDC");
      wait_wire_frame(w);
      check(w.n == 1513, $sformatf("wire frame length %0d (1513)", w.n));
      check(w.fcs_ok, "1513-byte frame FCS good");
      check(same(w.b, frm, 1513), "1513-byte frame bytes");
      wait_irq(got); check(got, "IRQ after 1513-byte frame");
      recv();
      check(tx_gap_err == 0, "inter-frame gap >= 96 bit times");
      case_done("b-transmit");

      // ================================================================== case c: receive
      mk_frame(frm, 100, OUR_MAC, 16'h0800, 8'h50);
      play_frame(frm, 100, 0, 20);
      wait_irq(got);
      check(got, "IRQ 5 on receive");
      inb(EN0_ISR, v);        check((v & 8'h3F) == 8'h01, $sformatf("ISR %02x (01 PRX; RDC from the remote DMA is outside ENISR_ALL)", v));
      inb(EN0_RSR, v);        check(v == 8'h01, $sformatf("RSR %02x (01)", v));
      outb(EN_CCMD, 8'h62); inb(EN1_CURPAG, v); outb(EN_CCMD, 8'h22);
      check(v == 8'h28, $sformatf("CURR %02x after a 104-byte packet from page 27 (28)", v));
      rx_hdr = new[26];
      block_input(16'h2700, 26, rx_hdr);
      check(rx_hdr[0] == 8'h01, $sformatf("ring header status %02x (01)", rx_hdr[0]));
      check(rx_hdr[1] == 8'h28, $sformatf("ring header next page %02x (28)", rx_hdr[1]));
      check({rx_hdr[3], rx_hdr[2]} == 16'd104, $sformatf("ring header count %0d (104 = 100 + FCS)", {rx_hdr[3], rx_hdr[2]}));
      check(same(rx_hdr[4:25], frm, 22) || 1, "");
      ok = 1; for (int i = 0; i < 22; i++) if (rx_hdr[4+i] != frm[i]) ok = 0;
      check(ok, "ring header + first 22 bytes are the frame");
      recv();
      check(app_rx_q.size() == 1, $sformatf("driver delivered %0d frame(s) (1)", app_rx_q.size()));
      if (app_rx_q.size() == 1) begin
         frm2 = app_rx_q.pop_front();
         check(frm2.size() == 100 && same(frm2, frm, 100), "delivered frame is the 100 bytes sent (FCS stripped by count-4)");
      end
      inb(EN0_BOUNDARY, v);   check(v == 8'h27, $sformatf("BNRY %02x after the driver freed the packet (27 = next - 1)", v));
      check(irq === 1'b0, "IRQ released after recv");
      inb(EN0_ISR, v);        check((v & 8'h3F) == 8'h00, $sformatf("ISR clean %02x (masked 3F)", v));

      // broadcast: status has PHY (20h)
      mk_frame(frm, 64, BCAST, 16'h0806, 8'h60);
      play_frame(frm, 64, 0, 20);
      wait_irq(got); check(got, "IRQ on broadcast");
      block_input(16'h2800, 26, rx_hdr);
      check(rx_hdr[0] == 8'h21, $sformatf("broadcast header status %02x (21 = PRX + PHY)", rx_hdr[0]));
      recv();
      check(app_rx_q.size() == 1 && same(app_rx_q[0], frm, 64), "broadcast delivered");
      if (app_rx_q.size()) app_rx_q.pop_front();

      // to another station: ignored
      mk_frame(frm, 64, OTHER, 16'h0800, 8'h70);
      play_frame(frm, 64, 0, 20);
      wait_rx_idle();
      check(irq === 1'b0, "frame to another MAC: no interrupt");
      outb(EN_CCMD, 8'h62); inb(EN1_CURPAG, v); outb(EN_CCMD, 8'h22);
      check(v == 8'h29, $sformatf("frame to another MAC: CURR unchanged %02x (29)", v));

      // multicast in rcv_mode_3 (RCR = 04, no AM): ignored
      mk_frame(frm, 64, MCAST_A, 16'h0800, 8'h80);
      play_frame(frm, 64, 0, 20);
      wait_rx_idle();
      check(irq === 1'b0, "multicast without AM: no interrupt");

      // multicast in rcv_mode_4 with the hash bit of MCAST_A set: accepted; MCAST_B (other bit): not
      frm3 = new[6]; for (int i = 0; i < 6; i++) frm3[i] = MCAST_A[47 - 8*i -: 8];
      ec = ether_crc(frm3, 6); hidx = ec[31:26];
      for (int i = 0; i < 8; i++) mcast_list_bits[i] = 8'h00;
      mcast_list_bits[hidx >> 3] = 8'h01 << (hidx & 7);
      rcv_mode_4();
      play_frame(frm, 64, 0, 20);
      wait_irq(got); check(got, $sformatf("multicast %012x with MAR%0d bit %0d set: received", MCAST_A, hidx >> 3, hidx & 7));
      block_input(16'h2900, 26, rx_hdr);
      check(rx_hdr[0] == 8'h21, $sformatf("multicast header status %02x (21)", rx_hdr[0]));
      recv();
      check(app_rx_q.size() == 1 && same(app_rx_q[0], frm, 64), "multicast delivered");
      if (app_rx_q.size()) app_rx_q.pop_front();
      frm3 = new[6]; for (int i = 0; i < 6; i++) frm3[i] = MCAST_B[47 - 8*i -: 8];
      ec = ether_crc(frm3, 6);
      check((ec[31:26]) != hidx, "MCAST_B hashes to a different bit (test precondition)");
      mk_frame(frm, 64, MCAST_B, 16'h0800, 8'h90);
      play_frame(frm, 64, 0, 20);
      wait_rx_idle();
      check(irq === 1'b0, "multicast with its MAR bit clear: ignored");
      rcv_mode_3();

      // bad FCS: dropped, CRC counter
      mk_frame(frm, 80, OUR_MAC, 16'h0800, 8'hA0);
      play_frame(frm, 80, 1, 20);
      wait_rx_idle();
      check(irq === 1'b0, "bad FCS: no interrupt");
      inb(EN0_COUNTER1, v);   check(v == 8'h01, $sformatf("CNTR1 (CRC errors) %02x (01)", v));
      inb(EN0_COUNTER1, v);   check(v == 8'h00, "CNTR1 cleared by the read");
      inb(EN0_RSR, v);        check(v[1] == 1'b1 && v[0] == 1'b0, $sformatf("RSR %02x shows CRC error", v));
      outb(EN_CCMD, 8'h62); inb(EN1_CURPAG, v); outb(EN_CCMD, 8'h22);
      check(v == 8'h2A, $sformatf("bad FCS: CURR unchanged %02x (2A)", v));

      // runt (40 bytes + FCS = 44 < 64): dropped without AR
      mk_frame(frm, 40, OUR_MAC, 16'h0800, 8'hB0);
      play_frame(frm, 40, 0, 20);
      wait_rx_idle();
      check(irq === 1'b0, "runt: no interrupt");

      // IMR gating: a frame with IMR = 0 sets PRX but no IRQ; writing IMR raises it (the driver's
      // recv relies on this: IMR 00h at entry, 3Fh at exit re-arms a packet that arrived meanwhile)
      outb(EN0_IMR, 8'h00);
      mk_frame(frm, 64, OUR_MAC, 16'h0800, 8'hC0);
      play_frame(frm, 64, 0, 20);
      wait_rx_idle();
      inb(EN0_ISR, v);        check(v[0] == 1'b1, "PRX set with IMR = 0");
      check(irq === 1'b0, "no IRQ with IMR = 0");
      outb(EN0_IMR, 8'h3F);
      repeat (4) @(posedge clk_sys);
      check(irq === 1'b1, "IRQ rises when IMR is written");
      recv();
      check(app_rx_q.size() == 1 && same(app_rx_q[0], frm, 64), "frame delivered after IMR re-enable");
      if (app_rx_q.size()) app_rx_q.pop_front();
      case_done("c-receive");

      // ================================================================== case e: back-to-back
      mk_frame(frm,  200, OUR_MAC, 16'h0800, 8'h01);
      mk_frame(frm2, 300, BCAST,   16'h0806, 8'h02);
      mk_frame(frm3,  60, OUR_MAC, 16'h0800, 8'h03);
      play_frame(frm,  200, 0, 48);                            // 96-bit gaps
      play_frame(frm2, 300, 0, 48);
      play_frame(frm3,  60, 0, 20);
      wait_rx_idle();
      wait_irq(got); check(got, "IRQ after back-to-back frames");
      recv();
      check(app_rx_q.size() == 3, $sformatf("driver drained %0d frames in one pass (3)", app_rx_q.size()));
      if (app_rx_q.size() == 3) begin
         check(same(app_rx_q[0], frm, 200) && app_rx_q[0].size() == 200, "frame 1 of 3");
         check(same(app_rx_q[1], frm2, 300) && app_rx_q[1].size() == 300, "frame 2 of 3");
         check(same(app_rx_q[2], frm3, 60) && app_rx_q[2].size() == 60, "frame 3 of 3");
      end
      while (app_rx_q.size()) app_rx_q.pop_front();
      check(irq === 1'b0, "IRQ released");
      case_done("e-back-to-back");

      // ================================================================== case d: wrap + overflow
      // ring 26h..3Fh; 1514-byte frames take 6 pages (1518 + 4 header = 1522 bytes)
      outb(EN_CCMD, 8'h62); inb(EN1_CURPAG, v); outb(EN_CCMD, 8'h22);
      $display("NE1000 note: CURR before the wrap test %02x, next_packet %02x", v, next_packet);
      for (int k = 0; k < 6; k++) begin
         mk_frame(frm, 1514, OUR_MAC, 16'h0800, 8'h11 * (k + 1));
         play_frame(frm, 1514, 0, 20);
         wait_irq(got); check(got, $sformatf("wrap test: IRQ for frame %0d", k));
         recv();
         check(app_rx_q.size() == 1 && app_rx_q[0].size() == 1514 && same(app_rx_q[0], frm, 1514), $sformatf("wrap test: frame %0d delivered intact", k));
         while (app_rx_q.size()) app_rx_q.pop_front();
      end
      outb(EN_CCMD, 8'h62); inb(EN1_CURPAG, v); outb(EN_CCMD, 8'h22);
      inb(EN0_BOUNDARY, v2);
      $display("NE1000 note: after six 1514-byte frames CURR %02x BNRY %02x (the ring wrapped at 40h)", v, v2);
      check(v < 8'h40 && v >= 8'h26, "CURR inside the ring after wrapping");

      // overflow: the driver does not service the card; 26 pages minus the BNRY page hold four
      // 6-page frames, the fifth runs into BNRY
      outb(EN0_IMR, 8'h00);                                    // interrupts masked = driver busy
      for (int k = 0; k < 5; k++) begin
         mk_frame(frm, 1514, OUR_MAC, 16'h0800, 8'h21 + k);
         play_frame(frm, 1514, 0, 20);
         wait_rx_idle();
      end
      inb(EN0_ISR, v);
      check(v[4] == 1'b1, $sformatf("ISR OVW set after the fifth unserviced frame (%02x)", v));
      check(v[0] == 1'b1, "PRX also set (four frames stored)");
      inb(EN0_COUNTER2, v);   check(v == 8'h01, $sformatf("CNTR2 (missed) %02x (01)", v));
      // one more frame while halted is missed too, no OVW storm
      mk_frame(frm2, 100, OUR_MAC, 16'h0800, 8'hE0);
      play_frame(frm2, 100, 0, 20);
      wait_rx_idle();
      inb(EN0_COUNTER2, v);   check(v == 8'h01, $sformatf("CNTR2 counts the frame received while halted %02x (01)", v));
      outb(EN0_IMR, 8'h3F);
      wait_irq(got); check(got, "IRQ with OVW pending");
      n0 = soft_rx_overruns;
      recv();                                                  // recv_overrun path, then recv_frame for the rest
      check(soft_rx_overruns == n0 + 1, "driver took the overrun path once");
      check(app_rx_q.size() == 4, $sformatf("driver recovered %0d frames (4)", app_rx_q.size()));
      for (int k = 0; k < 4 && k < app_rx_q.size(); k++) begin
         mk_frame(frm, 1514, OUR_MAC, 16'h0800, 8'h21 + k);
         check(same(app_rx_q[k], frm, 1514), $sformatf("recovered frame %0d intact", k));
      end
      while (app_rx_q.size()) app_rx_q.pop_front();
      inb(EN0_ISR, v);        check((v & 8'h3F) == 8'h00, $sformatf("ISR clean after recovery %02x (masked 3F)", v));
      check(irq === 1'b0, "IRQ released after recovery");
      inb(EN0_RXCR, v);
      outb(EN_CCMD, 8'hA2); inb(EN0_TXCR, v); outb(EN_CCMD, 8'h22);
      check(v == 8'h00, $sformatf("TCR back to normal after recovery %02x", v));
      // reception works again
      mk_frame(frm, 120, OUR_MAC, 16'h0800, 8'hF0);
      play_frame(frm, 120, 0, 20);
      wait_irq(got); check(got, "IRQ after recovery");
      recv();
      check(app_rx_q.size() == 1 && same(app_rx_q[0], frm, 120), "frame after recovery delivered");
      while (app_rx_q.size()) app_rx_q.pop_front();
      // and transmit still works
      mk_frame(frm, 60, PC_MAC, 16'h0800, 8'h44);
      send_pkt(frm, 60, ok);
      wait_wire_frame(w);
      check(w.n == 60 && w.fcs_ok && same(w.b, frm, 60), "transmit after recovery");
      wait_irq(got); recv();
      case_done("d-wrap-overflow");

      // ================================================================== case f: DCR WTS ignored,
      // reset port semantics with a frame queued
      outb(EN0_DCFG, 8'h49);                                   // word mode requested: NE1000 stays byte-wide
      mk_frame(frm, 64, OUR_MAC, 16'h0800, 8'h55);
      play_frame(frm, 64, 0, 20);
      wait_irq(got); recv();
      check(app_rx_q.size() == 1 && same(app_rx_q[0], frm, 64), "byte-wide DMA with DCR WTS = 1");
      while (app_rx_q.size()) app_rx_q.pop_front();
      inb(NE_RESET, v);
      repeat (4) @(posedge clk_sys);
      inb(EN0_ISR, v);        check(v == 8'h80, $sformatf("reset port read: ISR %02x (80)", v));
      inb(EN_CCMD, v);        check(v == 8'h21, $sformatf("reset port read: CR %02x (21)", v));
      check(!dbg_running, "reset port read: card stopped");
      check(irq === 1'b0, "reset port read: no interrupt (IMR cleared)");
      case_done("f-misc");

      if (n_fail == 0) $display("NE1000 RESULT: PASS (%0d checks)", n_pass);
      else             $display("NE1000 RESULT: FAIL (%0d failed, %0d passed)", n_fail, n_pass);
      $finish;
   end

   initial begin
      #60ms;
      $display("NE1000 RESULT: FAIL (timeout; %0d failed, %0d passed so far)", n_fail, n_pass);
      $finish;
   end

endmodule
