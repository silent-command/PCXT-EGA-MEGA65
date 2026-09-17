-------------------------------------------------------------------------------------------------------------
-- eth_phy_spike: MEGA65 R6 Ethernet PHY bring-up for PCXT-EGA on MiSTer2MEGA65
--
-- One-day spike that proves the R6's Ethernet port from this core, as the physical layer of a later
-- NE1000 emulation. It brings the PHY up, receives frames and counts them, sends one broadcast ARP
-- request per second and reports everything through three 16-bit status words on the core's serial
-- status line (" erx=", " etx=", " eth=" in CORE/m2m-rom/m2m-rom.asm). The card emulation will replace
-- the counters and the canned frame; the RMII/MDIO/clock/reset parts are meant to be reused.
--
-- Hardware (M2M/MEGA65-R6.xdc:237-252, M2M/vhdl/top_mega65-r6.vhd:178-188): Microchip KSZ8081RNDCA
-- in RMII mode. Datasheet references below are to DS00002199E (KSZ8081RNA/RND, 2016-2021).
--
-- Reference clock
--   The RND variant powers up in "RMII - 50 MHz mode": it takes the 50 MHz reference on XI (pin 8)
--   from the MAC and leaves pin 16 (REF_CLK/PHYAD[2]) unconnected (DS00002199E table 2-1 pins 8 and
--   16; hardware design checklist DS00002781A section 6.1). So the FPGA drives the clock: clk_ref_i
--   (the exact 50.000 MHz of CORE/vhdl/clk.vhd MMCM B CLKOUT1) goes to the eth_clock_o pin through an
--   ODDR (constant D1=1/D2=0), never through fabric logic, so the pin carries a clean copy of the
--   internal clock with a fixed clock-to-out. mega65-core drives the same pin straight from its 50 MHz
--   BUFG (mega65r6.vhdl "eth_clock <= ethclock").
--
-- Why the MAC runs on a +90 degree copy of that clock (clk_i = clk.vhd clk_50_ps)
--   RMII timing, table 7-2 (50 MHz input to XI): the PHY drives CRS_DV/RXD/RXER 8 ns (min) to 13 ns
--   (max) after the rising edge of its reference clock and needs TXD/TXEN 4 ns before / 2 ns after it.
--   The pin clock lags the internal clk_50 edge by the ODDR + OBUF delay (about 3-4 ns), the return path
--   adds trace + IBUF (about 1-2 ns). Inside the FPGA the receive data of cycle N is therefore stable
--   from about 17 ns to about 32 ns after internal edge N: neither the next rising edge (20 ns) nor the
--   falling edge (30 ns) of clk_50 sits in the middle of that window. A 50 MHz clock shifted by +90
--   degrees (rising edges at 5, 25, 45 ns) samples at 25 ns with about 7 ns of margin on both sides,
--   and TXD/TXEN launched from it reach the PHY about 11 ns after the pin clock edge: 12 ns of setup to
--   the next edge, 7 ns of hold after the previous one. The same trick the core uses for its video
--   output (clk_57_ps, CORE/vhdl/clk.vhd). mega65-core instead resamples RXD on a 200 MHz clock with a
--   CPU-selectable phase (ethernet.vhdl "eth_rx_latch_phase"), evidence that the phase matters on this
--   board. CORE/CORE.xdc constrains the pins with the table 7-2 numbers and a 2-cycle setup multicycle
--   so that Vivado checks exactly this arrangement (the 90 degree clock's first edge after the pin
--   clock is at 5 ns, the intended capture edge is the second one).
--
-- PHY reset and strapping
--   Table 7-5 / section 7.4: a warm reset needs RST# low for at least 500 us, the strap pins are
--   latched at the de-assertion of reset and the MIIM interface must not be used for 100 us after it.
--   Here RST# is held low for 10 ms after the MMCMs lock and MDIO starts 1 ms later. The straps
--   (table 2-2) are PHYAD[1:0] on CRS_DV (pin 15), PHYAD[2] on pin 16 (NC on the RND) and
--   ANEN_SPEED on LED0 (pin 23): all internal pull-ups/downs, none driven by the FPGA. RXER (pin 17)
--   must latch a pull-down at reset; it is an FPGA input without a pull (M2M/MEGA65-R6.xdc). Because
--   the FPGA's inputs are high-impedance when this reset is released, the straps are re-latched
--   cleanly whatever the pins did while the FPGA was being configured. The PHY address can be 0, 3, 4
--   or 7 (section 3.4); address 0 is the broadcast address after power-up and is answered whatever
--   the strap says, so G_PHY_ADDR = 0 works unconditionally, and register 17h[15:13] (operation mode
--   strap status) is read once to report the real strap. Auto-negotiation is on by default (0.12),
--   the PHY advertises 100BASE-TX full duplex; the receiver assumes a 100 Mb/s link (at 10 Mb/s every
--   dibit is repeated ten times on RMII, not handled here).
--
-- MDIO (section 3.4 table 3-3, timing table 7-4)
--   Clause 22 read frames: 32 x 1 preamble, ST 01, OP 10, PHYAD, REGAD, turnaround (Z, then the PHY
--   drives 0), 16 data bits MSB first. MDC max 10 MHz; the PHY needs MDIO setup 10 ns / hold 4 ns and
--   drives its output 5..222 ns after the rising edge. MDC runs at 50 MHz / (2 x G_MDC_HALF_CYCLES) =
--   1.25 MHz continuously; the MAC changes MDIO at the falling edge (400 ns of setup) and samples 60 ns
--   before the rising edge through a two-flop synchroniser (740 ns after the previous rising edge, so
--   well after the 222 ns worst case). Sequence: read 2h (PHY ID 1, 0022h), 3h (PHY ID 2, 156xh:
--   OUI bits 000101, model 010110, revision x), 17h (strap status), then every G_POLL_CYCLES
--   (100 ms) 1h (BMSR: link 1.2, auto-negotiation complete 1.5) and 1Eh (PHY control 1: operation mode
--   [2:0], 110 = 100BASE-TX full duplex). eth_led2_o follows link status. mega65-core has an MIIM
--   master too (ethernet_miim.vhdl) but only under CPU control; nothing there is automatic.
--
-- RMII receive (RMII specification 1.2 as summarised in section 3.2 / table 3-1)
--   Two bits per clock, LSB first. CRS_DV rises asynchronously with carrier; RXD carries 00 until the
--   PHY decodes, then 0x55 preamble dibits (01 01 01 01) and the SFD 0xD5 (01 01 01 11), which is how
--   the frame start is found (same rule as mega65-core ethernet.vhdl "ReceivingPreamble"). At 100 Mb/s
--   the PHY toggles CRS_DV at 25 MHz at the end of a frame (carrier gone, data still in its FIFO: low
--   on the first dibit of each nibble, high on the second), so a dibit is data when CRS_DV is high in
--   this or the following clock, and the frame ends when CRS_DV has been low for two consecutive
--   samples (mega65-core waits for three and notes that fewer lost the last CRC byte with its
--   sampling; with the look-ahead the rule is exact). CRC-32 is computed bit-serially, two bits per
--   clock, in the reflected form (polynomial EDB88320h, init FFFFFFFFh): after data + FCS the register
--   holds DEBB20E3h for a good frame. Counted: frames with an SFD, frames with a good FCS and at least
--   64 bytes, good frames addressed to G_MAC or FF:FF:FF:FF:FF:FF; remembered: the EtherType and the
--   source MAC of the last good frame. rx_er_seen is sticky for any RXER = 1 (the PHY also uses it
--   outside frames to flag false carrier / symbol errors).
--
-- RMII transmit
--   Every G_TX_PERIOD_CYCLES (1 s) a broadcast ARP request "who has G_TARGET_IP tell G_OUR_IP" from
--   G_MAC (locally administered 02:4D:36:35:00:01): 7 x 0x55, 0xD5, 60 bytes (42 of header + ARP,
--   18 of zero padding), 4 bytes FCS (CRC register complemented, sent least significant bit first),
--   TXEN high from the first preamble dibit to the last FCS dibit, then a 96-bit (48-clock)
--   inter-frame gap. Full duplex is assumed: no deferral on CRS_DV, no collision handling. The frame
--   is sent whether or not the link is up (the PHY drops it): the counter proves the transmitter is
--   alive, the PC's ARP table (arp -a shows 192.168.1.250 at 02-4d-36-35-00-01) proves the wire.
--
-- Status words and clock crossing
--   All counters live in clk_i. A toggle handshake (request/acknowledge, two-flop synchronisers)
--   moves a 48-bit snapshot into stat_clk_i (QNICE, where rom_loader's dbg_* readback lives):
--   the snapshot register is only rewritten after the previous one was acknowledged, so the
--   destination always captures a stable value. CORE/CORE.xdc false-paths the synchronisers and
--   bounds the snapshot bus with a datapath-only max delay. Layout (m2m-rom.asm prints them in hex):
--     stat_a_o " erx=": rx_frames[7:0] & rx_crc_ok[7:0]
--     stat_b_o " etx=": rx_to_us[7:0]  & tx_frames[7:0]
--     stat_c_o " eth=": link_up, phy_id_ok, rx_er_seen, an_complete, speed_100, full_duplex,
--                       strap PHYAD[2], strap PHYAD[0] (the strap is 0/3/4/7, so bit 1 = bit 0),
--                       last_ethertype[7:0]
--   The line prints at core start and on every menu selection; the counters are free running 8-bit.
--
-- What only the board can prove: the RMII strap (17h bit 1 = 1) and PHY address, that ETH_LED2 (FPGA
-- pin R14) is a jack LED and its polarity (the PHY itself has a single LED0 output, pin 23, driven by
-- the PHY, so the FPGA pin cannot be a PHY LED), the receive sampling margin against the real board
-- delays, and whether the 10 ms / 1 ms reset timings are needed or merely generous.
--
-- MEGA65 port done by silent-command in 2026 and licensed under GPL v3
-- MiSTer2MEGA65 done by sy2002 and MJoergen in 2022 and licensed under GPL v3
-------------------------------------------------------------------------------------------------------------

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

library unisim;
use unisim.vcomponents.all;

entity eth_phy_spike is
   generic (
      G_MAC              : std_logic_vector(47 downto 0) := x"024D36350001";  -- locally administered
      G_OUR_IP           : std_logic_vector(31 downto 0) := x"C0A801FA";      -- 192.168.1.250 (claimed)
      G_TARGET_IP        : std_logic_vector(31 downto 0) := x"C0A801D5";      -- 192.168.1.213 (the PC)
      G_PHY_ADDR         : std_logic_vector(4 downto 0)  := "00000";          -- 0 = broadcast on the KSZ8081
      G_RESET_CYCLES     : natural := 500_000;      -- RST# low: 10 ms at 50 MHz (datasheet: >= 500 us)
      G_MDIO_WAIT_CYCLES : natural := 50_000;       -- RST# high to first MDIO: 1 ms (datasheet: >= 100 us)
      G_POLL_CYCLES      : natural := 5_000_000;    -- BMSR / PHY control 1 poll: 100 ms
      G_TX_PERIOD_CYCLES : natural := 50_000_000;   -- one ARP request per second
      G_MDC_HALF_CYCLES  : natural := 20;           -- MDC half period in clk_i cycles: 1.25 MHz
      G_LED_ACTIVE_LOW   : boolean := false         -- eth_led2_o polarity (unknown, see header)
   );
   port (
      clk_ref_i         : in    std_logic;                     -- 50 MHz, 0 degrees: forwarded to the PHY only
      clk_i             : in    std_logic;                     -- 50 MHz, +90 degrees: MAC clock
      rst_i             : in    std_logic;                     -- synchronous to clk_i, MMCM lock based

      -- PHY pins
      eth_clock_o       : out   std_logic;
      eth_reset_o       : out   std_logic;                     -- RST#, active low
      eth_mdc_o         : out   std_logic;
      eth_mdio_io       : inout std_logic;
      eth_rxd_i         : in    std_logic_vector(1 downto 0);
      eth_rxdv_i        : in    std_logic;                     -- CRS_DV
      eth_rxer_i        : in    std_logic;
      eth_txd_o         : out   std_logic_vector(1 downto 0);
      eth_txen_o        : out   std_logic;
      eth_led2_o        : out   std_logic;

      -- status words, stat_clk_i domain
      stat_clk_i        : in    std_logic;
      stat_a_o          : out   std_logic_vector(15 downto 0);
      stat_b_o          : out   std_logic_vector(15 downto 0);
      stat_c_o          : out   std_logic_vector(15 downto 0);

      -- source MAC of the last frame with a good FCS, clk_i domain (for the card, unused by the spike)
      rx_last_src_mac_o : out   std_logic_vector(47 downto 0)
   );
end entity eth_phy_spike;

architecture rtl of eth_phy_spike is

   ---------------------------------------------------------------------------------------------
   -- CRC-32 (IEEE 802.3), reflected form, two bits per clock, d(0) is the earlier bit on the wire
   ---------------------------------------------------------------------------------------------
   constant C_CRC_INIT    : std_logic_vector(31 downto 0) := x"FFFFFFFF";
   constant C_CRC_RESIDUE : std_logic_vector(31 downto 0) := x"DEBB20E3";   -- register after data + FCS

   function crc32_dibit(crc : std_logic_vector(31 downto 0); d : std_logic_vector(1 downto 0))
      return std_logic_vector is
      variable c : std_logic_vector(31 downto 0) := crc;
   begin
      for i in 0 to 1 loop
         if (c(0) xor d(i)) = '1' then
            c := ('0' & c(31 downto 1)) xor x"EDB88320";
         else
            c := '0' & c(31 downto 1);
         end if;
      end loop;
      return c;
   end function crc32_dibit;

   ---------------------------------------------------------------------------------------------
   -- The canned frame: broadcast ARP request, padded to the 60-byte minimum (FCS is appended live)
   ---------------------------------------------------------------------------------------------
   type byte_array_t is array (natural range <>) of std_logic_vector(7 downto 0);

   function byte_of(v : std_logic_vector; i : natural) return std_logic_vector is
      -- byte i of a vector, most significant byte first (i = 0 is the first on the wire)
   begin
      return v(v'high - 8*i downto v'high - 8*i - 7);
   end function byte_of;

   function build_arp_request return byte_array_t is
      variable f : byte_array_t(0 to 59) := (others => x"00");
   begin
      for i in 0 to 5 loop f(i)      := x"FF";               end loop;   -- destination: broadcast
      for i in 0 to 5 loop f(6 + i)  := byte_of(G_MAC, i);  end loop;   -- source
      f(12) := x"08"; f(13) := x"06";                                    -- EtherType ARP
      f(14) := x"00"; f(15) := x"01";                                    -- HTYPE Ethernet
      f(16) := x"08"; f(17) := x"00";                                    -- PTYPE IPv4
      f(18) := x"06"; f(19) := x"04";                                    -- HLEN, PLEN
      f(20) := x"00"; f(21) := x"01";                                    -- OPER request
      for i in 0 to 5 loop f(22 + i) := byte_of(G_MAC, i);       end loop;   -- SHA
      for i in 0 to 3 loop f(28 + i) := byte_of(G_OUR_IP, i);    end loop;   -- SPA
      for i in 0 to 5 loop f(32 + i) := x"00";                   end loop;   -- THA (unknown)
      for i in 0 to 3 loop f(38 + i) := byte_of(G_TARGET_IP, i); end loop;   -- TPA
      return f;                                                                 -- 42..59: padding
   end function build_arp_request;

   constant C_TX_FRAME  : byte_array_t(0 to 59) := build_arp_request;
   constant C_IFG_CLKS  : natural := 48;                                   -- 96 bit times at 2 bits/clock

   ---------------------------------------------------------------------------------------------
   -- RMII pins: IOB registers on clk_i (+90 degrees), see header
   ---------------------------------------------------------------------------------------------
   attribute IOB       : string;
   attribute ASYNC_REG : string;

   signal rxd_iob       : std_logic_vector(1 downto 0) := "00";
   signal rxdv_iob      : std_logic := '0';
   signal rxer_iob      : std_logic := '0';
   signal txd_iob       : std_logic_vector(1 downto 0) := "00";
   signal txen_iob      : std_logic := '0';
   attribute IOB of rxd_iob  : signal is "TRUE";
   attribute IOB of rxdv_iob : signal is "TRUE";
   attribute IOB of rxer_iob : signal is "TRUE";
   attribute IOB of txd_iob  : signal is "TRUE";
   attribute IOB of txen_iob : signal is "TRUE";

   -- one clock older copies for the CRS_DV look-ahead
   signal rxd_q         : std_logic_vector(1 downto 0) := "00";
   signal rxdv_q        : std_logic := '0';

   ---------------------------------------------------------------------------------------------
   -- Receiver
   ---------------------------------------------------------------------------------------------
   type rx_state_t is (RX_IDLE, RX_PREAMBLE, RX_DATA, RX_DROP);
   signal rx_state      : rx_state_t := RX_IDLE;
   signal rx_crc        : std_logic_vector(31 downto 0);
   signal rx_byte_sr    : std_logic_vector(7 downto 0);
   signal rx_dibit_cnt  : natural range 0 to 3;
   signal rx_byte_cnt   : natural range 0 to 2047;                       -- saturating
   signal rx_is_bcast   : std_logic;
   signal rx_is_ours    : std_logic;
   signal rx_dst_tmp    : std_logic_vector(39 downto 0);                 -- first five destination bytes
   signal rx_src_tmp    : std_logic_vector(47 downto 0);
   signal rx_type_tmp   : std_logic_vector(15 downto 0);

   signal rx_frames     : unsigned(7 downto 0) := (others => '0');
   signal rx_crc_ok     : unsigned(7 downto 0) := (others => '0');
   signal rx_to_us      : unsigned(7 downto 0) := (others => '0');
   signal rx_er_seen    : std_logic := '0';
   signal rx_last_type  : std_logic_vector(15 downto 0) := (others => '0');
   signal rx_last_src   : std_logic_vector(47 downto 0) := (others => '0');

   ---------------------------------------------------------------------------------------------
   -- Transmitter
   ---------------------------------------------------------------------------------------------
   type tx_state_t is (TX_IDLE, TX_PREAMBLE, TX_DATA, TX_FCS, TX_IFG);
   signal tx_state      : tx_state_t := TX_IDLE;
   signal tx_timer      : natural range 0 to G_TX_PERIOD_CYCLES - 1 := G_TX_PERIOD_CYCLES - 1;
   signal tx_cnt        : natural range 0 to 63;                         -- preamble dibits / FCS dibits / IFG clocks
   signal tx_byte       : natural range 0 to 59;
   signal tx_dibit      : natural range 0 to 3;
   signal tx_crc        : std_logic_vector(31 downto 0);
   signal tx_fcs_sr     : std_logic_vector(31 downto 0);
   signal txd_r         : std_logic_vector(1 downto 0) := "00";
   signal txen_r        : std_logic := '0';
   signal tx_frames     : unsigned(7 downto 0) := (others => '0');
   signal tx_allowed    : std_logic := '0';                              -- PHY out of reset

   ---------------------------------------------------------------------------------------------
   -- MDIO master
   ---------------------------------------------------------------------------------------------
   constant C_MDC_PERIOD : natural := 2 * G_MDC_HALF_CYCLES;
   signal mdc_cnt       : natural range 0 to C_MDC_PERIOD - 1 := 0;
   signal mdc_r         : std_logic := '0';
   signal mdio_out      : std_logic := '1';
   signal mdio_oe       : std_logic := '0';
   signal mdio_meta     : std_logic := '1';
   signal mdio_sync     : std_logic := '1';
   attribute ASYNC_REG of mdio_meta : signal is "TRUE";
   attribute ASYNC_REG of mdio_sync : signal is "TRUE";
   signal mdio_cmd      : std_logic_vector(0 to 45);                     -- bits driven by the MAC, in wire order
   signal mdio_cycle    : natural range 0 to 63;
   signal mdio_busy     : std_logic := '0';
   signal mdio_pending  : std_logic := '0';
   signal mdio_start    : std_logic := '0';                              -- one-clock request from the sequencer
   signal mdio_reg      : std_logic_vector(4 downto 0) := (others => '0');
   signal mdio_data     : std_logic_vector(15 downto 0) := (others => '0');
   signal mdio_done     : std_logic := '0';                              -- one clock, mdio_data valid
   signal mdio_ta_ok    : std_logic := '0';                              -- the PHY drove the turnaround 0

   ---------------------------------------------------------------------------------------------
   -- PHY sequencer
   ---------------------------------------------------------------------------------------------
   type ctl_state_t is (C_RESET, C_WAIT, C_RD_ID1, C_RD_ID2, C_RD_STRAP, C_POLL_WAIT, C_RD_BMSR, C_RD_PC1);
   signal ctl_state     : ctl_state_t := C_RESET;
   signal ctl_timer     : natural range 0 to G_RESET_CYCLES + G_MDIO_WAIT_CYCLES + G_POLL_CYCLES := 0;
   signal ctl_issued    : std_logic := '0';
   signal phy_reset_n   : std_logic := '0';
   signal phy_id1       : std_logic_vector(15 downto 0) := (others => '0');
   signal phy_id2       : std_logic_vector(15 downto 0) := (others => '0');
   signal phy_strap     : std_logic_vector(15 downto 0) := (others => '0');
   signal phy_bmsr      : std_logic_vector(15 downto 0) := (others => '0');
   signal phy_pc1       : std_logic_vector(15 downto 0) := (others => '0');
   signal phy_id_ok     : std_logic := '0';
   signal link_up       : std_logic := '0';
   signal led_r         : std_logic := '0';

   ---------------------------------------------------------------------------------------------
   -- Status clock crossing (toggle handshake)
   ---------------------------------------------------------------------------------------------
   signal src_snap      : std_logic_vector(47 downto 0) := (others => '0');
   signal src_req       : std_logic := '0';
   signal src_ack_meta  : std_logic := '0';
   signal src_ack_sync  : std_logic := '0';
   signal stat_req_meta : std_logic := '0';
   signal stat_req_sync : std_logic := '0';
   signal stat_ack      : std_logic := '0';
   signal stat_hold     : std_logic_vector(47 downto 0) := (others => '0');
   attribute ASYNC_REG of src_ack_meta  : signal is "TRUE";
   attribute ASYNC_REG of src_ack_sync  : signal is "TRUE";
   attribute ASYNC_REG of stat_req_meta : signal is "TRUE";
   attribute ASYNC_REG of stat_req_sync : signal is "TRUE";

   signal stat_word_a   : std_logic_vector(15 downto 0);
   signal stat_word_b   : std_logic_vector(15 downto 0);
   signal stat_word_c   : std_logic_vector(15 downto 0);

begin

   ---------------------------------------------------------------------------------------------
   -- Reference clock to the PHY: clock forwarding through the IOB's ODDR
   ---------------------------------------------------------------------------------------------
   i_refclk_oddr : ODDR
      generic map (
         DDR_CLK_EDGE => "SAME_EDGE",
         INIT         => '0',
         SRTYPE       => "SYNC"
      )
      port map (
         Q  => eth_clock_o,
         C  => clk_ref_i,
         CE => '1',
         D1 => '1',
         D2 => '0',
         R  => '0',
         S  => '0'
      );

   ---------------------------------------------------------------------------------------------
   -- Pin registers
   ---------------------------------------------------------------------------------------------
   p_pins : process (clk_i)
   begin
      if rising_edge(clk_i) then
         rxd_iob   <= eth_rxd_i;
         rxdv_iob  <= eth_rxdv_i;
         rxer_iob  <= eth_rxer_i;
         rxd_q     <= rxd_iob;
         rxdv_q    <= rxdv_iob;
         txd_iob   <= txd_r;
         txen_iob  <= txen_r;
         mdio_meta <= to_x01(eth_mdio_io);
         mdio_sync <= mdio_meta;
      end if;
   end process p_pins;

   eth_txd_o   <= txd_iob;
   eth_txen_o  <= txen_iob;
   eth_mdc_o   <= mdc_r;
   eth_mdio_io <= mdio_out when mdio_oe = '1' else 'Z';
   eth_reset_o <= phy_reset_n;
   eth_led2_o  <= led_r;

   ---------------------------------------------------------------------------------------------
   -- Receiver: the pair (rxd_q, rxdv_q) is the sample being decoded, (rxd_iob, rxdv_iob) the next one
   ---------------------------------------------------------------------------------------------
   p_rx : process (clk_i)
      variable v_accept : boolean;     -- the older sample is frame data
      variable v_end    : boolean;     -- CRS_DV low twice: carrier and data gone
      variable v_byte   : std_logic_vector(7 downto 0);
      variable v_crc    : std_logic_vector(31 downto 0);
   begin
      if rising_edge(clk_i) then
         v_accept := (rxdv_q = '1') or (rxdv_iob = '1');
         v_end    := (rxdv_q = '0') and (rxdv_iob = '0');
         v_byte   := rxd_q & rx_byte_sr(7 downto 2);
         v_crc    := crc32_dibit(rx_crc, rxd_q);

         if rxer_iob = '1' then
            rx_er_seen <= '1';
         end if;

         case rx_state is
            when RX_IDLE =>
               -- RMII: RXD is 00 after CRS_DV rises until the PHY decodes, then the 0x55 preamble
               if rxdv_q = '1' and rxd_q = "01" then
                  rx_state <= RX_PREAMBLE;
               end if;

            when RX_PREAMBLE =>
               if v_end then
                  rx_state <= RX_IDLE;
               elsif rxd_q = "11" then                             -- last dibit of the SFD 0xD5
                  rx_state     <= RX_DATA;
                  rx_crc       <= C_CRC_INIT;
                  rx_dibit_cnt <= 0;
                  rx_byte_cnt  <= 0;
                  rx_is_bcast  <= '0';
                  rx_is_ours   <= '0';
                  rx_frames    <= rx_frames + 1;
               elsif rxd_q /= "01" then
                  rx_state <= RX_DROP;                              -- junk in the preamble
               end if;

            when RX_DATA =>
               if v_end then
                  rx_state <= RX_IDLE;
                  if rx_dibit_cnt = 0 and rx_byte_cnt >= 64 and rx_crc = C_CRC_RESIDUE then
                     rx_crc_ok    <= rx_crc_ok + 1;
                     rx_last_type <= rx_type_tmp;
                     rx_last_src  <= rx_src_tmp;
                     if rx_is_bcast = '1' or rx_is_ours = '1' then
                        rx_to_us <= rx_to_us + 1;
                     end if;
                  end if;
               elsif v_accept then
                  rx_crc     <= v_crc;
                  rx_byte_sr <= v_byte;
                  if rx_dibit_cnt = 3 then
                     rx_dibit_cnt <= 0;
                     if rx_byte_cnt < 2047 then
                        rx_byte_cnt <= rx_byte_cnt + 1;
                     end if;
                     if rx_byte_cnt <= 4 then                        -- destination MAC, bytes 0..4
                        rx_dst_tmp <= rx_dst_tmp(31 downto 0) & v_byte;
                     elsif rx_byte_cnt = 5 then                       -- byte 5 completes it
                        if (rx_dst_tmp & v_byte) = G_MAC then
                           rx_is_ours <= '1';
                        end if;
                        if (rx_dst_tmp & v_byte) = x"FFFFFFFFFFFF" then
                           rx_is_bcast <= '1';
                        end if;
                     elsif rx_byte_cnt <= 11 then                    -- source MAC
                        rx_src_tmp <= rx_src_tmp(39 downto 0) & v_byte;
                     elsif rx_byte_cnt = 12 then
                        rx_type_tmp(15 downto 8) <= v_byte;
                     elsif rx_byte_cnt = 13 then
                        rx_type_tmp(7 downto 0) <= v_byte;
                     end if;
                  else
                     rx_dibit_cnt <= rx_dibit_cnt + 1;
                  end if;
               end if;

            when RX_DROP =>
               if v_end then
                  rx_state <= RX_IDLE;
               end if;
         end case;

         if rst_i = '1' then
            rx_state   <= RX_IDLE;
            rx_frames  <= (others => '0');
            rx_crc_ok  <= (others => '0');
            rx_to_us   <= (others => '0');
            rx_er_seen <= '0';
         end if;
      end if;
   end process p_rx;

   rx_last_src_mac_o <= rx_last_src;

   ---------------------------------------------------------------------------------------------
   -- Transmitter
   ---------------------------------------------------------------------------------------------
   p_tx : process (clk_i)
      variable v_d   : std_logic_vector(1 downto 0);
      variable v_crc : std_logic_vector(31 downto 0);
   begin
      if rising_edge(clk_i) then
         case tx_state is
            when TX_IDLE =>
               txen_r <= '0';
               txd_r  <= "00";
               if tx_allowed = '1' then
                  if tx_timer = 0 then
                     tx_timer <= G_TX_PERIOD_CYCLES - 1;
                     tx_state <= TX_PREAMBLE;
                     tx_cnt   <= 0;
                  else
                     tx_timer <= tx_timer - 1;
                  end if;
               end if;

            when TX_PREAMBLE =>                                      -- 7 x 0x55 then 0xD5: 31 x "01", then "11"
               txen_r <= '1';
               if tx_cnt = 31 then
                  txd_r    <= "11";
                  tx_state <= TX_DATA;
                  tx_crc   <= C_CRC_INIT;
                  tx_byte  <= 0;
                  tx_dibit <= 0;
               else
                  txd_r  <= "01";
                  tx_cnt <= tx_cnt + 1;
               end if;

            when TX_DATA =>
               v_d   := C_TX_FRAME(tx_byte)(2*tx_dibit + 1 downto 2*tx_dibit);
               v_crc := crc32_dibit(tx_crc, v_d);
               txd_r  <= v_d;
               tx_crc <= v_crc;
               if tx_dibit = 3 then
                  tx_dibit <= 0;
                  if tx_byte = 59 then
                     tx_state  <= TX_FCS;
                     tx_fcs_sr <= not v_crc;
                     tx_cnt    <= 0;
                  else
                     tx_byte <= tx_byte + 1;
                  end if;
               else
                  tx_dibit <= tx_dibit + 1;
               end if;

            when TX_FCS =>                                           -- 16 dibits, LSB first
               txd_r     <= tx_fcs_sr(1 downto 0);
               tx_fcs_sr <= "00" & tx_fcs_sr(31 downto 2);
               if tx_cnt = 15 then
                  tx_state  <= TX_IFG;
                  tx_cnt    <= 0;
                  tx_frames <= tx_frames + 1;
               else
                  tx_cnt <= tx_cnt + 1;
               end if;

            when TX_IFG =>
               txen_r <= '0';
               txd_r  <= "00";
               if tx_cnt = C_IFG_CLKS - 1 then
                  tx_state <= TX_IDLE;
               else
                  tx_cnt <= tx_cnt + 1;
               end if;
         end case;

         if rst_i = '1' then
            tx_state  <= TX_IDLE;
            tx_timer  <= G_TX_PERIOD_CYCLES - 1;
            tx_frames <= (others => '0');
            txen_r    <= '0';
            txd_r     <= "00";
         end if;
      end if;
   end process p_tx;

   ---------------------------------------------------------------------------------------------
   -- MDIO master. MDC cycle j: MAC bit j is driven at the falling edge before rising edge j+1, PHY bit j
   -- is launched after rising edge j and sampled two clocks before rising edge j+1 (mdio_cycle = j).
   ---------------------------------------------------------------------------------------------
   p_mdio : process (clk_i)
   begin
      if rising_edge(clk_i) then
         mdio_done <= '0';

         if mdc_cnt = C_MDC_PERIOD - 1 then
            mdc_cnt <= 0;
            mdc_r   <= '1';                                          -- rising edge
         else
            mdc_cnt <= mdc_cnt + 1;
            if mdc_cnt = G_MDC_HALF_CYCLES - 1 then
               mdc_r <= '0';                                         -- falling edge
            end if;
         end if;

         if mdio_start = '1' then
            mdio_pending <= '1';
            mdio_cmd     <= (0 to 31 => '1') & "01" & "10" & G_PHY_ADDR & mdio_reg;
         end if;

         -- drive at the falling edge
         if mdc_cnt = G_MDC_HALF_CYCLES - 1 and mdio_busy = '1' then
            if mdio_cycle <= 45 then
               mdio_oe  <= '1';
               mdio_out <= mdio_cmd(mdio_cycle);
            else
               mdio_oe  <= '0';                                      -- turnaround and data: the PHY drives
               mdio_out <= '1';
            end if;
         end if;

         -- sample 60 ns (2 clocks + synchroniser) before the rising edge
         if mdc_cnt = C_MDC_PERIOD - 2 and mdio_busy = '1' then
            if mdio_cycle = 47 then
               mdio_ta_ok <= not mdio_sync;
            elsif mdio_cycle >= 48 then
               mdio_data <= mdio_data(14 downto 0) & mdio_sync;
            end if;
         end if;

         -- advance the bit index at the end of the low phase
         if mdc_cnt = C_MDC_PERIOD - 1 then
            if mdio_busy = '1' then
               if mdio_cycle = 63 then
                  mdio_busy  <= '0';
                  mdio_done  <= '1';
                  mdio_cycle <= 0;
               else
                  mdio_cycle <= mdio_cycle + 1;
               end if;
            elsif mdio_pending = '1' then
               mdio_pending <= '0';
               mdio_busy    <= '1';
               mdio_cycle   <= 0;
            end if;
         end if;

         if rst_i = '1' then
            mdc_cnt      <= 0;
            mdc_r        <= '0';
            mdio_oe      <= '0';
            mdio_out     <= '1';
            mdio_busy    <= '0';
            mdio_pending <= '0';
            mdio_done    <= '0';
            mdio_cycle   <= 0;
         end if;
      end if;
   end process p_mdio;

   ---------------------------------------------------------------------------------------------
   -- PHY sequencer: reset, wait, ID registers once, then BMSR + PHY control 1 every G_POLL_CYCLES
   ---------------------------------------------------------------------------------------------
   p_ctl : process (clk_i)
   begin
      if rising_edge(clk_i) then
         mdio_start <= '0';

         case ctl_state is
            when C_RESET =>                                          -- RST# low
               phy_reset_n <= '0';
               tx_allowed  <= '0';
               if ctl_timer = G_RESET_CYCLES - 1 then
                  ctl_timer <= 0;
                  ctl_state <= C_WAIT;
               else
                  ctl_timer <= ctl_timer + 1;
               end if;

            when C_WAIT =>                                           -- straps latched; no MDIO yet
               phy_reset_n <= '1';
               if ctl_timer = G_MDIO_WAIT_CYCLES - 1 then
                  ctl_timer  <= 0;
                  ctl_state  <= C_RD_ID1;
                  tx_allowed <= '1';
               else
                  ctl_timer <= ctl_timer + 1;
               end if;

            when C_RD_ID1 | C_RD_ID2 | C_RD_STRAP | C_RD_BMSR | C_RD_PC1 =>
               if ctl_issued = '0' then                              -- issue one read
                  mdio_start <= '1';
                  ctl_issued <= '1';
                  case ctl_state is
                     when C_RD_ID1   => mdio_reg <= "00010";          -- 2h  PHY identifier 1
                     when C_RD_ID2   => mdio_reg <= "00011";          -- 3h  PHY identifier 2
                     when C_RD_STRAP => mdio_reg <= "10111";          -- 17h operation mode strap status
                     when C_RD_BMSR  => mdio_reg <= "00001";          -- 1h  basic status
                     when others     => mdio_reg <= "11110";          -- 1Eh PHY control 1
                  end case;
               elsif mdio_done = '1' then                             -- collect it
                  ctl_issued <= '0';
                  case ctl_state is
                     when C_RD_ID1   => phy_id1   <= mdio_data; ctl_state <= C_RD_ID2;
                     when C_RD_ID2   => phy_id2   <= mdio_data; ctl_state <= C_RD_STRAP;
                     when C_RD_STRAP => phy_strap <= mdio_data; ctl_state <= C_POLL_WAIT;
                     when C_RD_BMSR  => phy_bmsr  <= mdio_data; ctl_state <= C_RD_PC1;
                     when others     => phy_pc1   <= mdio_data; ctl_state <= C_POLL_WAIT;
                  end case;
               end if;

            when C_POLL_WAIT =>
               if ctl_timer = G_POLL_CYCLES - 1 then
                  ctl_timer <= 0;
                  ctl_state <= C_RD_BMSR;
               else
                  ctl_timer <= ctl_timer + 1;
               end if;

         end case;

         if phy_id1 = x"0022" and phy_id2(15 downto 4) = x"156" then
            phy_id_ok <= '1';
         else
            phy_id_ok <= '0';
         end if;
         link_up <= phy_bmsr(2);
         if G_LED_ACTIVE_LOW then
            led_r <= not phy_bmsr(2);
         else
            led_r <= phy_bmsr(2);
         end if;

         if rst_i = '1' then
            ctl_state   <= C_RESET;
            ctl_timer   <= 0;
            ctl_issued  <= '0';
            phy_reset_n <= '0';
            tx_allowed  <= '0';
            mdio_start  <= '0';
            phy_id1     <= (others => '0');
            phy_id2     <= (others => '0');
            phy_strap   <= (others => '0');
            phy_bmsr    <= (others => '0');
            phy_pc1     <= (others => '0');
         end if;
      end if;
   end process p_ctl;

   ---------------------------------------------------------------------------------------------
   -- Status words and the crossing into stat_clk_i
   ---------------------------------------------------------------------------------------------
   stat_word_a <= std_logic_vector(rx_frames) & std_logic_vector(rx_crc_ok);
   stat_word_b <= std_logic_vector(rx_to_us)  & std_logic_vector(tx_frames);
   stat_word_c <= link_up & phy_id_ok & rx_er_seen & phy_bmsr(5) & phy_pc1(1) & phy_pc1(2) &
                  phy_strap(15) & phy_strap(13) & rx_last_type(7 downto 0);

   p_cdc_src : process (clk_i)
   begin
      if rising_edge(clk_i) then
         src_ack_meta <= stat_ack;
         src_ack_sync <= src_ack_meta;
         if src_req = src_ack_sync then                              -- previous snapshot delivered
            src_snap <= stat_word_a & stat_word_b & stat_word_c;
            src_req  <= not src_req;
         end if;
      end if;
   end process p_cdc_src;

   p_cdc_dst : process (stat_clk_i)
   begin
      if rising_edge(stat_clk_i) then
         stat_req_meta <= src_req;
         stat_req_sync <= stat_req_meta;
         if stat_req_sync /= stat_ack then
            stat_hold <= src_snap;                                   -- stable until acknowledged
            stat_ack  <= stat_req_sync;
         end if;
      end if;
   end process p_cdc_dst;

   stat_a_o <= stat_hold(47 downto 32);
   stat_b_o <= stat_hold(31 downto 16);
   stat_c_o <= stat_hold(15 downto 0);

end architecture rtl;
