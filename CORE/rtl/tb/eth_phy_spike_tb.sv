// eth_phy_spike_tb: bench for CORE/vhdl/eth_phy_spike.vhd (MEGA65 R6 Ethernet PHY spike).
//
// Models the KSZ8081RND side of the pins:
//   * MDIO register model: decodes clause-22 read frames, checks the MAC's MDIO setup/hold around
//     the MDC rising edge (datasheet table 7-4: 10 ns / 4 ns), the MDC frequency (<= 10 MHz) and
//     drives its turnaround 0 and data bits 222 ns after the rising edge (tMD3 worst case).
//     Link status is flipped to "up" after the first BMSR read.
//   * RMII receive model: plays canned frames (a good broadcast ARP reply, one with a corrupt FCS,
//     a unicast to our MAC with the 100 Mb/s CRS_DV end-of-frame toggle, a unicast to someone
//     else, two back-to-back frames with a 12-byte gap, a false-carrier RXER pulse). The inputs
//     change 11 ns after the reference clock edge (tOD typical).
//   * RMII transmit checker: samples TXD/TXEN at the reference clock edge, verifies preamble,
//     SFD, the 60 bytes of the ARP request, the FCS, the frame length and the inter-frame gap.
//   * The status words are read through the DUT's clock crossing into an unrelated 41.7 MHz clock.
// The DUT's timers are shortened through generics; the ordering checks (reset low time, no MDIO
// before the post-reset wait) are scaled the same way.
//   powershell -File run_eth_phy_spike_tb.ps1
`timescale 1ns/1ps

module eth_phy_spike_tb;

   // ------------------------------------------------------------------------------------------
   // scaled-down DUT timings (cycles of 20 ns)
   // ------------------------------------------------------------------------------------------
   localparam int RESET_CYC   = 1000;    // 20 us RST# low
   localparam int WAIT_CYC    = 200;     // 4 us before MDIO
   localparam int POLL_CYC    = 3000;    // 60 us between BMSR polls
   localparam int TXPER_CYC   = 12000;   // 240 us between ARP requests
   localparam int MDC_HALF    = 20;      // 1.25 MHz MDC (the real value)

   // ------------------------------------------------------------------------------------------
   // clocks and reset
   // ------------------------------------------------------------------------------------------
   logic clk_ref  = 0;   // 50 MHz, 0 deg: rising edges at 10, 30, ...
   logic clk_ps   = 0;   // 50 MHz, +90 deg: rising edges at 15, 35, ...
   logic stat_clk = 0;   // 41.7 MHz, unrelated
   logic rst      = 1;
   always #10 clk_ref = ~clk_ref;
   initial begin #15; clk_ps = 1; forever #10 clk_ps = ~clk_ps; end
   always #12 stat_clk = ~stat_clk;

   // ------------------------------------------------------------------------------------------
   // DUT
   // ------------------------------------------------------------------------------------------
   wire        eth_clock, eth_reset, eth_mdc, eth_txen, eth_led;
   wire  [1:0] eth_txd;
   tri1        eth_mdio;                      // 1 k pull-up on the board
   logic [1:0] eth_rxd = 2'b00;
   logic       eth_rxdv = 0, eth_rxer = 0;
   wire [15:0] stat_a, stat_b, stat_c;
   wire [47:0] last_src;

   eth_phy_spike #(
      .G_RESET_CYCLES     (RESET_CYC),
      .G_MDIO_WAIT_CYCLES (WAIT_CYC),
      .G_POLL_CYCLES      (POLL_CYC),
      .G_TX_PERIOD_CYCLES (TXPER_CYC),
      .G_MDC_HALF_CYCLES  (MDC_HALF)
   ) dut (
      .clk_ref_i         (clk_ref),
      .clk_i             (clk_ps),
      .rst_i             (rst),
      .eth_clock_o       (eth_clock),
      .eth_reset_o       (eth_reset),
      .eth_mdc_o         (eth_mdc),
      .eth_mdio_io       (eth_mdio),
      .eth_rxd_i         (eth_rxd),
      .eth_rxdv_i        (eth_rxdv),
      .eth_rxer_i        (eth_rxer),
      .eth_txd_o         (eth_txd),
      .eth_txen_o        (eth_txen),
      .eth_led2_o        (eth_led),
      .stat_clk_i        (stat_clk),
      .stat_a_o          (stat_a),
      .stat_b_o          (stat_b),
      .stat_c_o          (stat_c),
      .rx_last_src_mac_o (last_src)
   );

   // ------------------------------------------------------------------------------------------
   // bookkeeping
   // ------------------------------------------------------------------------------------------
   int n_pass = 0, n_fail = 0;
   task automatic check(input bit cond, input string msg);
      if (cond) n_pass++;
      else begin n_fail++; $display("ETH FAIL @%0t: %s", $time, msg); end
   endtask

   function automatic logic [31:0] crc32(input byte d[], input int n);
      logic [31:0] c = 32'hFFFFFFFF;
      for (int i = 0; i < n; i++) begin
         c ^= {24'h0, d[i]};
         for (int b = 0; b < 8; b++) c = c[0] ? ((c >> 1) ^ 32'hEDB88320) : (c >> 1);
      end
      return ~c;
   endfunction

   localparam logic [47:0] OUR_MAC = 48'h024D36350001;
   localparam logic [47:0] PC_MAC  = 48'h001122334455;
   localparam logic [47:0] BCAST   = 48'hFFFFFFFFFFFF;
   localparam logic [47:0] OTHER   = 48'h00AABBCCDDEE;

   // ------------------------------------------------------------------------------------------
   // MDIO register model + protocol checks
   // ------------------------------------------------------------------------------------------
   logic [15:0] phy_regs [0:31];
   logic        mdio_phy_drv = 0, mdio_phy_val = 1;
   assign eth_mdio = mdio_phy_drv ? mdio_phy_val : 1'bz;

   realtime t_mdio_change = 0;
   always @(eth_mdio) t_mdio_change = $realtime;

   int      md_ones = 0;            // consecutive preamble ones
   int      md_e    = -1;           // rising-edge index within a frame, 0 = ST first bit
   logic [12:0] md_sr;              // ST1, OP, PHYAD, REGAD
   logic [15:0] md_data;
   int      md_regs_seen[$];        // register addresses of the decoded frames, in order
   int      md_frames = 0;
   realtime t_mdc_prev = -1, t_edge, t_first_mdio = -1;
   bit      md_err_op = 0, md_err_addr = 0, md_err_ta = 0, md_err_period = 0;
   bit      link_set_pending = 0;

   initial begin
      for (int i = 0; i < 32; i++) phy_regs[i] = 16'h0000;
      phy_regs[1]  = 16'h7809;      // BMSR: capabilities, link down, autoneg not complete
      phy_regs[2]  = 16'h0022;      // PHY ID 1
      phy_regs[3]  = 16'h1561;      // PHY ID 2: KSZ8081, revision 1
      phy_regs[23] = 16'h6002;      // 17h: strap PHYAD = 011 (address 3), RMII strap bit 1
      phy_regs[30] = 16'h0106;      // 1Eh: operation mode 110 = 100BASE-TX full duplex
   end

   always @(posedge eth_mdc) begin
      t_edge = $realtime;
      if (t_mdc_prev >= 0 && (t_edge - t_mdc_prev) < 99.0) md_err_period = 1;   // > 10 MHz
      t_mdc_prev = t_edge;

      if (md_e < 0) begin
         // hunting for the preamble (>= 32 ones) followed by the ST 0
         if (eth_mdio === 1'b1) md_ones++;
         else if (eth_mdio === 1'b0 && md_ones >= 32) begin
            md_e = 0; md_ones = 0;
            if (t_first_mdio < 0) t_first_mdio = t_edge;
         end else md_ones = 0;
      end else begin
         md_e++;
      end

      if (md_e >= 0 && md_e <= 13) begin
         // MAC-driven bits: setup 10 ns before / hold 4 ns after the rising edge (table 7-4)
         if (t_edge - t_mdio_change < 10.0) begin
            check(0, $sformatf("MDIO setup < 10 ns at frame bit %0d", md_e));
         end
         if (md_e > 0) md_sr = {md_sr[11:0], eth_mdio};
         fork
            begin
               automatic realtime t0 = t_edge;
               #4;
               if (t_mdio_change > t0) check(0, $sformatf("MDIO hold < 4 ns at frame bit %0d", md_e));
            end
         join_none
      end

      if (md_e == 13) begin
         // ST1 in md_sr[12], OP md_sr[11:10], PHYAD md_sr[9:5], REGAD md_sr[4:0]
         if (md_sr[12] !== 1'b1 || md_sr[11:10] !== 2'b10) md_err_op = 1;
         if (md_sr[9:5] !== 5'd0) md_err_addr = 1;
         md_regs_seen.push_back(md_sr[4:0]);
         md_data = phy_regs[md_sr[4:0]];
         md_frames++;
         if (md_sr[4:0] == 5'd1) link_set_pending = 1;
      end
      if (md_e == 14) begin
         // TA1: nobody drives, the pull-up must show
         if (eth_mdio !== 1'b1) md_err_ta = 1;
         // TA2: PHY drives 0, tMD3 max after this edge
         mdio_phy_val <= #222 1'b0;
         mdio_phy_drv <= #222 1'b1;
      end
      if (md_e >= 15 && md_e <= 30) begin
         mdio_phy_val <= #222 md_data[30 - md_e];
      end
      if (md_e == 31) begin
         mdio_phy_drv <= #222 1'b0;
         mdio_phy_val <= #222 1'b1;
         md_e = -1;
         if (link_set_pending) begin
            link_set_pending = 0;
            phy_regs[1] = 16'h782D;    // link up, autoneg complete: seen by the next BMSR read
         end
      end
   end

   // ------------------------------------------------------------------------------------------
   // RMII receive model: a queue of per-clock samples, driven 11 ns after the reference edge
   // ------------------------------------------------------------------------------------------
   typedef struct packed { logic [1:0] d; logic dv; logic er; } smp_t;
   smp_t rxq[$];

   always @(posedge clk_ref) begin
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

   // frame = header + payload (no FCS); the model appends the FCS. corrupt flips a data bit after
   // the FCS was computed; toggle_tail plays the CRS_DV 25 MHz toggle on the last two bytes.
   task automatic play_frame(input byte data[], input int n, input bit corrupt, input bit toggle_tail, input int gap_clks);
      byte f[];
      logic [31:0] fcs;
      int total;
      f = new[n + 4];
      for (int i = 0; i < n; i++) f[i] = data[i];
      fcs = crc32(data, n);
      f[n] = fcs[7:0]; f[n+1] = fcs[15:8]; f[n+2] = fcs[23:16]; f[n+3] = fcs[31:24];
      if (corrupt) f[20] = f[20] ^ 8'h01;
      total = n + 4;
      repeat (4) push(2'b00, 1, 0);                              // CRS_DV up, PHY still decoding
      repeat (31) push(2'b01, 1, 0);                             // 7 x 0x55 + three dibits of 0xD5
      push(2'b11, 1, 0);                                         // last dibit of the SFD
      for (int i = 0; i < total; i++) begin
         for (int k = 0; k < 4; k++) begin
            logic dv = 1;
            if (toggle_tail && i >= total - 2) dv = k[0];        // low on the first dibit of each nibble
            push(f[i][2*k +: 2], dv, 0);
         end
      end
      repeat (gap_clks) push(2'b00, 0, 0);
   endtask

   task automatic wait_rx_idle();
      wait (rxq.size() == 0);
      repeat (8) @(posedge clk_ref);
      #2000;                                                     // status crossing
   endtask

   function automatic void hdr(ref byte f[], input logic [47:0] dst, input logic [47:0] src, input logic [15:0] typ);
      for (int i = 0; i < 6; i++) f[i]   = dst[47 - 8*i -: 8];
      for (int i = 0; i < 6; i++) f[6+i] = src[47 - 8*i -: 8];
      f[12] = typ[15:8]; f[13] = typ[7:0];
   endfunction

   // ARP reply from the PC to us (broadcast, as a switch would flood an unknown address)
   function automatic void arp_reply(ref byte f[]);
      f = new[60];
      foreach (f[i]) f[i] = 0;
      hdr(f, BCAST, PC_MAC, 16'h0806);
      f[14] = 8'h00; f[15] = 8'h01; f[16] = 8'h08; f[17] = 8'h00; f[18] = 8'h06; f[19] = 8'h04;
      f[20] = 8'h00; f[21] = 8'h02;
      for (int i = 0; i < 6; i++) f[22+i] = PC_MAC[47 - 8*i -: 8];
      f[28] = 8'hC0; f[29] = 8'hA8; f[30] = 8'h01; f[31] = 8'hD5;
      for (int i = 0; i < 6; i++) f[32+i] = OUR_MAC[47 - 8*i -: 8];
      f[38] = 8'hC0; f[39] = 8'hA8; f[40] = 8'h01; f[41] = 8'hFA;
   endfunction

   // ------------------------------------------------------------------------------------------
   // RMII transmit checker
   // ------------------------------------------------------------------------------------------
   byte     exp_tx[60];
   initial begin
      foreach (exp_tx[i]) exp_tx[i] = 0;
      for (int i = 0; i < 6; i++) exp_tx[i]   = 8'hFF;
      for (int i = 0; i < 6; i++) exp_tx[6+i] = OUR_MAC[47 - 8*i -: 8];
      exp_tx[12] = 8'h08; exp_tx[13] = 8'h06;
      exp_tx[14] = 8'h00; exp_tx[15] = 8'h01; exp_tx[16] = 8'h08; exp_tx[17] = 8'h00;
      exp_tx[18] = 8'h06; exp_tx[19] = 8'h04; exp_tx[20] = 8'h00; exp_tx[21] = 8'h01;
      for (int i = 0; i < 6; i++) exp_tx[22+i] = OUR_MAC[47 - 8*i -: 8];
      exp_tx[28] = 8'hC0; exp_tx[29] = 8'hA8; exp_tx[30] = 8'h01; exp_tx[31] = 8'hFA;
      exp_tx[38] = 8'hC0; exp_tx[39] = 8'hA8; exp_tx[40] = 8'h01; exp_tx[41] = 8'hD5;
   end

   logic [1:0] tx_dib [0:1023];
   int         tx_n = 0, tx_frames_seen = 0, tx_gap = 0;
   bit         tx_in = 0;

   task automatic check_tx_frame(input int n);
      byte b[72];
      byte d[];
      logic [31:0] fcs;
      bit ok = 1;
      check(n == 288, $sformatf("tx frame length %0d dibits (expected 288)", n));
      if (n != 288) return;
      for (int i = 0; i < 72; i++) b[i] = {tx_dib[4*i+3], tx_dib[4*i+2], tx_dib[4*i+1], tx_dib[4*i]};
      for (int i = 0; i < 7; i++) if (b[i] != 8'h55) ok = 0;
      check(ok, "tx preamble is 7 x 0x55");
      check(b[7] == 8'hD5, "tx SFD is 0xD5");
      ok = 1;
      for (int i = 0; i < 60; i++) if (b[8+i] != exp_tx[i]) begin ok = 0; $display("   tx byte %0d = %02x expected %02x", i, b[8+i], exp_tx[i]); end
      check(ok, "tx ARP request bytes (incl. padding to 60)");
      d = new[60];
      for (int i = 0; i < 60; i++) d[i] = exp_tx[i];
      fcs = crc32(d, 60);
      check({b[71], b[70], b[69], b[68]} == fcs, $sformatf("tx FCS %02x%02x%02x%02x expected %08x", b[71], b[70], b[69], b[68], fcs));
   endtask

   always @(posedge clk_ref) begin
      if (eth_txen === 1'b1) begin
         if (!tx_in) begin
            tx_in = 1; tx_n = 0;
            if (tx_frames_seen > 0) check(tx_gap >= 48, $sformatf("inter-frame gap %0d clocks (>= 48)", tx_gap));
         end
         if (tx_n < 1024) tx_dib[tx_n] = eth_txd;
         tx_n++;
      end else begin
         if (tx_in) begin
            tx_in = 0;
            check_tx_frame(tx_n);
            tx_frames_seen++;
            tx_gap = 0;
         end else tx_gap++;
      end
   end

   // ------------------------------------------------------------------------------------------
   // reference clock check
   // ------------------------------------------------------------------------------------------
   int refclk_edges = 0;
   always @(posedge eth_clock) refclk_edges++;

   // ------------------------------------------------------------------------------------------
   // the run
   // ------------------------------------------------------------------------------------------
   realtime t_rst_off, t_reset_release;
   byte     frm[];
   int      n0;
   initial begin
      // known answer for the bench's own CRC (IEEE 802.3 / zlib crc32 of "123456789")
      frm = new[9];
      for (int i = 0; i < 9; i++) frm[i] = 8'h31 + i;
      check(crc32(frm, 9) == 32'hCBF43926, $sformatf("bench crc32 known answer %08x (CBF43926)", crc32(frm, 9)));

      #200;
      rst = 0;
      t_rst_off = $realtime;
      #100;
      check(eth_reset === 1'b0, "PHY RST# low after start");
      check(eth_txen === 1'b0, "TXEN idle during PHY reset");
      n0 = refclk_edges;
      #1000;
      check(refclk_edges - n0 == 50, $sformatf("reference clock: %0d edges per us (50)", refclk_edges - n0));

      @(posedge eth_reset);
      t_reset_release = $realtime;
      check(t_reset_release - t_rst_off >= RESET_CYC * 20.0, $sformatf("RST# low for %0.1f us", (t_reset_release - t_rst_off) / 1000.0));

      // --- receive tests (the PHY sequencer runs concurrently; no TX frame before ~264 us) ---
      arp_reply(frm);
      play_frame(frm, 60, 0, 0, 20);
      wait_rx_idle();
      check(stat_a == 16'h0101, $sformatf("erx after good broadcast ARP reply: %04x (0101)", stat_a));
      check(stat_b == 16'h0100, $sformatf("etx after good broadcast ARP reply: %04x (0100)", stat_b));
      check(stat_c[7:0] == 8'h06, $sformatf("last EtherType low byte %02x (06)", stat_c[7:0]));
      check(last_src == PC_MAC, "source MAC of the last good frame");

      play_frame(frm, 60, 1, 0, 20);                               // corrupt FCS
      wait_rx_idle();
      check(stat_a == 16'h0201, $sformatf("erx after corrupt FCS: %04x (0201)", stat_a));
      check(stat_b == 16'h0100, $sformatf("etx after corrupt FCS: %04x (0100)", stat_b));

      frm = new[64];                                              // unicast IPv4 to us, CRS_DV toggle tail
      foreach (frm[i]) frm[i] = 8'h40 + i;
      hdr(frm, OUR_MAC, PC_MAC, 16'h0800);
      play_frame(frm, 64, 0, 1, 20);
      wait_rx_idle();
      check(stat_a == 16'h0302, $sformatf("erx after unicast to us with CRS_DV toggle: %04x (0302)", stat_a));
      check(stat_b == 16'h0200, $sformatf("etx after unicast to us: %04x (0200)", stat_b));
      check(stat_c[7:0] == 8'h00, $sformatf("last EtherType low byte %02x (00)", stat_c[7:0]));

      frm = new[60];                                              // unicast to someone else
      foreach (frm[i]) frm[i] = 8'h80 + i;
      hdr(frm, OTHER, PC_MAC, 16'h86DD);
      play_frame(frm, 60, 0, 0, 20);
      wait_rx_idle();
      check(stat_a == 16'h0403, $sformatf("erx after unicast to another MAC: %04x (0403)", stat_a));
      check(stat_b == 16'h0200, $sformatf("etx after unicast to another MAC: %04x (0200)", stat_b));
      check(stat_c[7:0] == 8'hDD, $sformatf("last EtherType low byte %02x (DD)", stat_c[7:0]));

      arp_reply(frm);                                             // back to back, 96-bit gap
      play_frame(frm, 60, 0, 0, 48);
      play_frame(frm, 60, 0, 0, 20);
      wait_rx_idle();
      check(stat_a == 16'h0605, $sformatf("erx after back-to-back frames: %04x (0605)", stat_a));
      check(stat_b == 16'h0400, $sformatf("etx after back-to-back frames: %04x (0400)", stat_b));
      check(stat_c[13] == 1'b0, "rx_er_seen clear so far");

      push(2'b10, 0, 1);                                          // false carrier: RXER with CRS_DV low
      push(2'b10, 0, 1);
      wait_rx_idle();
      check(stat_c[13] == 1'b1, "rx_er_seen sticky after RXER");
      check(stat_a == 16'h0605, "RXER outside a frame counts nothing");

      // --- MDIO: ID reads, then polls; link comes up after the first BMSR read ---
      wait (md_regs_seen.size() >= 3);
      check(md_regs_seen[0] == 2 && md_regs_seen[1] == 3 && md_regs_seen[2] == 23,
            $sformatf("first MDIO reads are 2h, 3h, 17h (got %0d, %0d, %0d)", md_regs_seen[0], md_regs_seen[1], md_regs_seen[2]));
      check(t_first_mdio - t_reset_release >= WAIT_CYC * 20.0,
            $sformatf("first MDIO frame %0.1f us after RST# release (>= %0.1f)", (t_first_mdio - t_reset_release) / 1000.0, WAIT_CYC * 20.0 / 1000.0));
      wait (md_regs_seen.size() >= 7);                            // 2,3,17h, 1,1Eh, 1,1Eh
      check(md_regs_seen[3] == 1 && md_regs_seen[4] == 30 && md_regs_seen[5] == 1 && md_regs_seen[6] == 30,
            "polls read BMSR then PHY control 1");
      #3000;
      check(stat_c[15] == 1'b1, "link_up after BMSR reports link");
      check(stat_c[14] == 1'b1, "phy_id_ok (0022h / 156xh)");
      check(stat_c[12] == 1'b1, "autoneg complete flag");
      check(stat_c[11] == 1'b1, "100 Mb/s flag");
      check(stat_c[10] == 1'b1, "full duplex flag");
      check(stat_c[9]  == 1'b0 && stat_c[8] == 1'b1, $sformatf("strap PHYAD bits from 17h: c=%04x", stat_c));
      check(eth_led === 1'b1, "LED follows link up");
      check(!md_err_op,     "MDIO frames: ST/OP = 01 10 (read)");
      check(!md_err_addr,   "MDIO frames: PHY address 0");
      check(!md_err_ta,     "MDIO turnaround released by the MAC");
      check(!md_err_period, "MDC period >= 100 ns (<= 10 MHz)");
      check(t_mdc_prev >= 0 && (t_mdc_prev - t_edge) == 0, "MDC observed");

      // --- transmit: two ARP requests ---
      wait (tx_frames_seen >= 2);
      #3000;
      check(stat_b[7:0] == tx_frames_seen[7:0], $sformatf("tx_frames counter %0d = frames observed %0d", stat_b[7:0], tx_frames_seen));
      check(stat_a == 16'h0605, "rx counters untouched by transmit");

      if (n_fail == 0) $display("ETH RESULT: PASS (%0d checks)", n_pass);
      else             $display("ETH RESULT: FAIL (%0d failed, %0d passed)", n_fail, n_pass);
      $finish;
   end

   initial begin
      #3ms;
      $display("ETH RESULT: FAIL (timeout; %0d failed, %0d passed so far)", n_fail, n_pass);
      $finish;
   end

endmodule
