-------------------------------------------------------------------------------------------------------------
-- eth_mac: MEGA65 R6 Ethernet MAC for the NE1000 emulation of PCXT-EGA on MiSTer2MEGA65
--
-- The physical layer of CORE/rtl/ne1000.sv. Grown out of eth_phy_spike.vhd (the 2026-09-16 bring-up
-- spike, kept in the tree with its bench): the PHY reset / MDIO / link sequencer, the RMII pin handling
-- and the +90 degree clocking are the spike's, verified on the board (docs/ethernet.md). What changed:
-- the receiver no longer counts frames, it streams every byte of every frame into a dual-clock FIFO
-- towards the card; the transmitter no longer sends a canned ARP request, it sends whatever the card
-- queued in the other FIFO. The spike's counters survive as debug taps (dbg_* ports, clk_i domain).
--
-- Two clocks
--   clk_i (clk.vhd clk_50_ps, 50 MHz +90 degrees) is the RMII/MAC clock, see the spike header for why
--   that phase. sys_clk_i is the chipset clock (clk_50, 50 MHz, 0 degrees) in which the card lives.
--   The two are MMCM siblings, so Vivado times paths between them with a 5 ns requirement; every
--   crossing here therefore goes through a gray-coded pointer or a toggle with two ASYNC_REG flops,
--   and CORE/CORE.xdc relaxes those paths to one period (datapath only). Nothing else crosses.
--
-- Card-side interface (sys_clk_i)
--   Receive FIFO, 9-bit entries, the card pops (rx_rd_i) the head (rx_data_o) when rx_empty_o = '0':
--     bit 8 = '0': one frame byte, in wire order, from the first byte after the SFD to the last FCS byte
--     bit 8 = '1': end of frame; bits 7..0 are the frame's status:
--         0  FCS good and the frame ended on a byte boundary (CRC residue DEBB20E3h)
--         1  runt: fewer than 64 bytes including the FCS
--         2  long: more than 1522 bytes (802.1Q maximum)
--         3  frame alignment error: the dibit count was not a multiple of four at the end
--         4  RXER asserted by the PHY during the frame
--         5  FIFO overrun: bytes of this frame were dropped because the card did not drain the FIFO
--   Every frame that had an SFD produces its bytes and one end entry; nothing is filtered here (the
--   card's DP8390 does the address matching from the first six bytes, ne1000.sv). The MAC only pushes a
--   data byte when at least four entries are free, so the end entry always fits.
--   Transmit FIFO: the card pushes (tx_wr_i, tx_full_o) the frame bytes with bit 8 = '0' followed by
--   one entry with bit 8 = '1'. The MAC starts sending only after that end entry (a toggle crosses
--   into clk_i, counted in tx_avail), so a frame can never underrun; it appends zero padding to 60
--   bytes and the FCS, sends the preamble/SFD and the 96-bit inter-frame gap, then pulses tx_done_o
--   (one sys_clk_i cycle) which the card uses to complete the DP8390 transmit command (PTX).
--   Full duplex is assumed on the wire (the KSZ8081 negotiated 100BASE-TX full duplex on the board;
--   there is no deferral and no collision handling, so TSR never reports any).
--
-- What only the board can prove: everything listed in eth_phy_spike.vhd, plus that a real switch
-- accepts the padded/FCS'd frames from the card path (the spike's ARP request proved the same
-- transmitter logic, now fed from the FIFO instead of a constant table).
--
-- MEGA65 port done by silent-command in 2026 and licensed under GPL v3
-- MiSTer2MEGA65 done by sy2002 and MJoergen in 2022 and licensed under GPL v3
-------------------------------------------------------------------------------------------------------------

-------------------------------------------------------------------------------------------------------------
-- eth_afifo: dual-clock FIFO with gray-coded pointers (block RAM), first word visible at rd_data_o
-------------------------------------------------------------------------------------------------------------
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity eth_afifo is
   generic (
      G_ADDR_BITS : natural := 11;                                  -- 2**G_ADDR_BITS entries
      G_WIDTH     : natural := 9
   );
   port (
      wr_clk_i    : in  std_logic;
      wr_rst_i    : in  std_logic;
      wr_en_i     : in  std_logic;
      wr_data_i   : in  std_logic_vector(G_WIDTH - 1 downto 0);
      wr_full_o   : out std_logic;                                  -- exact
      wr_afull_o  : out std_logic;                                  -- fewer than 4 entries free (conservative)
      rd_clk_i    : in  std_logic;
      rd_rst_i    : in  std_logic;
      rd_en_i     : in  std_logic;                                  -- pop the head (ignored while empty)
      rd_data_o   : out std_logic_vector(G_WIDTH - 1 downto 0);     -- the head entry while rd_empty_o = '0'
      rd_empty_o  : out std_logic
   );
end entity eth_afifo;

architecture rtl of eth_afifo is

   constant C_DEPTH : natural := 2 ** G_ADDR_BITS;

   type mem_t is array (0 to C_DEPTH - 1) of std_logic_vector(G_WIDTH - 1 downto 0);
   signal mem : mem_t;

   -- pointers carry one extra bit to tell full from empty
   signal wr_ptr       : unsigned(G_ADDR_BITS downto 0) := (others => '0');
   signal rd_ptr       : unsigned(G_ADDR_BITS downto 0) := (others => '0');
   signal wr_gray      : std_logic_vector(G_ADDR_BITS downto 0) := (others => '0');   -- registered, wr_clk
   signal rd_gray      : std_logic_vector(G_ADDR_BITS downto 0) := (others => '0');   -- registered, rd_clk
   signal rd_gray_meta : std_logic_vector(G_ADDR_BITS downto 0) := (others => '0');   -- wr_clk
   signal rd_gray_sync : std_logic_vector(G_ADDR_BITS downto 0) := (others => '0');
   signal wr_gray_meta : std_logic_vector(G_ADDR_BITS downto 0) := (others => '0');   -- rd_clk
   signal wr_gray_sync : std_logic_vector(G_ADDR_BITS downto 0) := (others => '0');
   attribute ASYNC_REG : string;
   attribute ASYNC_REG of rd_gray_meta : signal is "TRUE";
   attribute ASYNC_REG of rd_gray_sync : signal is "TRUE";
   attribute ASYNC_REG of wr_gray_meta : signal is "TRUE";
   attribute ASYNC_REG of wr_gray_sync : signal is "TRUE";

   signal wr_full      : std_logic;
   signal rd_empty     : std_logic;

   function bin2gray(b : unsigned) return std_logic_vector is
   begin
      return std_logic_vector(b xor ('0' & b(b'high downto 1)));
   end function bin2gray;

   function gray2bin(g : std_logic_vector) return unsigned is
      variable b : unsigned(g'range);
   begin
      b(g'high) := g(g'high);
      for i in g'high - 1 downto 0 loop
         b(i) := b(i + 1) xor g(i);
      end loop;
      return b;
   end function gray2bin;

begin

   p_wr : process (wr_clk_i)
      variable v_ptr  : unsigned(G_ADDR_BITS downto 0);
      variable v_used : unsigned(G_ADDR_BITS downto 0);
   begin
      if rising_edge(wr_clk_i) then
         rd_gray_meta <= rd_gray;
         rd_gray_sync <= rd_gray_meta;
         v_ptr := wr_ptr;
         if wr_en_i = '1' and wr_full = '0' then
            mem(to_integer(wr_ptr(G_ADDR_BITS - 1 downto 0))) <= wr_data_i;
            v_ptr := wr_ptr + 1;
         end if;
         if wr_rst_i = '1' then
            v_ptr := (others => '0');
         end if;
         wr_ptr  <= v_ptr;
         wr_gray <= bin2gray(v_ptr);
         v_used := v_ptr - gray2bin(rd_gray_sync);                  -- the reader may be further, never behind
         if v_used >= C_DEPTH - 4 then
            wr_afull_o <= '1';
         else
            wr_afull_o <= '0';
         end if;
      end if;
   end process p_wr;

   wr_full <= '1' when wr_gray = ((not rd_gray_sync(G_ADDR_BITS downto G_ADDR_BITS - 1)) &
                                  rd_gray_sync(G_ADDR_BITS - 2 downto 0)) else '0';
   wr_full_o <= wr_full;

   p_rd : process (rd_clk_i)
      variable v_ptr : unsigned(G_ADDR_BITS downto 0);
   begin
      if rising_edge(rd_clk_i) then
         wr_gray_meta <= wr_gray;
         wr_gray_sync <= wr_gray_meta;
         v_ptr := rd_ptr;
         if rd_en_i = '1' and rd_empty = '0' then
            v_ptr := rd_ptr + 1;
         end if;
         if rd_rst_i = '1' then
            v_ptr := (others => '0');
         end if;
         rd_ptr    <= v_ptr;
         rd_gray   <= bin2gray(v_ptr);
         rd_data_o <= mem(to_integer(v_ptr(G_ADDR_BITS - 1 downto 0)));   -- the new head
      end if;
   end process p_rd;

   rd_empty   <= '1' when rd_gray = wr_gray_sync else '0';
   rd_empty_o <= rd_empty;

end architecture rtl;

-------------------------------------------------------------------------------------------------------------
-- eth_mac
-------------------------------------------------------------------------------------------------------------
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

library unisim;
use unisim.vcomponents.all;

entity eth_mac is
   generic (
      G_PHY_ADDR         : std_logic_vector(4 downto 0)  := "00000";  -- 0 = broadcast on the KSZ8081
      G_RESET_CYCLES     : natural := 500_000;      -- RST# low: 10 ms at 50 MHz (datasheet: >= 500 us)
      G_MDIO_WAIT_CYCLES : natural := 50_000;       -- RST# high to first MDIO: 1 ms (datasheet: >= 100 us)
      G_POLL_CYCLES      : natural := 5_000_000;    -- BMSR / PHY control 1 poll: 100 ms
      G_MDC_HALF_CYCLES  : natural := 20;           -- MDC half period in clk_i cycles: 1.25 MHz
      G_LED_ACTIVE_LOW   : boolean := false;        -- eth_led2_o polarity (unknown, see the spike header)
      G_RX_FIFO_BITS     : natural := 10;           -- 1024 entries: the card drains at one byte per clock
      G_TX_FIFO_BITS     : natural := 11            -- 2048 entries: a whole frame is queued before it is sent
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

      -- card side, sys_clk_i domain (see header)
      sys_clk_i         : in    std_logic;
      sys_rst_i         : in    std_logic;
      rx_rd_i           : in    std_logic;
      rx_data_o         : out   std_logic_vector(8 downto 0);
      rx_empty_o        : out   std_logic;
      tx_wr_i           : in    std_logic;
      tx_data_i         : in    std_logic_vector(8 downto 0);
      tx_full_o         : out   std_logic;
      tx_done_o         : out   std_logic;
      link_up_o         : out   std_logic;                     -- synchronised level

      -- debug taps, clk_i domain (the spike's counters and PHY flags)
      dbg_rx_frames_o   : out   std_logic_vector(7 downto 0);  -- frames with an SFD
      dbg_rx_crc_ok_o   : out   std_logic_vector(7 downto 0);  -- of which >= 64 bytes with a good FCS
      dbg_tx_frames_o   : out   std_logic_vector(7 downto 0);
      dbg_phy_o         : out   std_logic_vector(7 downto 0)   -- link, id ok, rxer seen, an done, 100M, FD, strap[2], strap[0]
   );
end entity eth_mac;

architecture rtl of eth_mac is

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

   constant C_IFG_CLKS  : natural := 48;                                   -- 96 bit times at 2 bits/clock
   constant C_MIN_FRAME : natural := 60;                                   -- bytes before the FCS

   ---------------------------------------------------------------------------------------------
   -- RMII pins: IOB registers on clk_i (+90 degrees), see the spike header
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
   signal rx_er_frame   : std_logic;                                     -- RXER during this frame
   signal rx_ovr_frame  : std_logic;                                     -- FIFO overrun during this frame
   signal rx_fifo_wr    : std_logic := '0';
   signal rx_fifo_din   : std_logic_vector(8 downto 0) := (others => '0');
   signal rx_fifo_afull : std_logic;
   signal rx_fifo_full  : std_logic;

   signal rx_frames     : unsigned(7 downto 0) := (others => '0');
   signal rx_crc_ok     : unsigned(7 downto 0) := (others => '0');
   signal rx_er_seen    : std_logic := '0';

   ---------------------------------------------------------------------------------------------
   -- Transmitter
   ---------------------------------------------------------------------------------------------
   type tx_state_t is (TX_IDLE, TX_PREAMBLE, TX_DATA, TX_FCS, TX_IFG);
   signal tx_state      : tx_state_t := TX_IDLE;
   signal tx_cnt        : natural range 0 to 63;                         -- preamble dibits / FCS dibits / IFG clocks
   signal tx_bytes      : natural range 0 to 4095;                       -- data + padding bytes sent so far
   signal tx_dibit      : natural range 0 to 3;
   signal tx_cur_byte   : std_logic_vector(7 downto 0);
   signal tx_eof_seen   : std_logic;
   signal tx_crc        : std_logic_vector(31 downto 0);
   signal tx_fcs_sr     : std_logic_vector(31 downto 0);
   signal txd_r         : std_logic_vector(1 downto 0) := "00";
   signal txen_r        : std_logic := '0';
   signal tx_frames     : unsigned(7 downto 0) := (others => '0');
   signal tx_allowed    : std_logic := '0';                              -- PHY out of reset
   signal tx_fetch      : std_logic;                                     -- pop the transmit FIFO now
   signal tx_fifo_rd    : std_logic;
   signal tx_fifo_dout  : std_logic_vector(8 downto 0);
   signal tx_fifo_empty : std_logic;
   signal tx_fifo_full  : std_logic;

   -- frame-queued toggle (sys_clk_i) -> clk_i, frame-done toggle (clk_i) -> sys_clk_i
   signal tx_eof_tgl    : std_logic := '0';
   signal tx_eof_meta   : std_logic := '0';
   signal tx_eof_sync   : std_logic := '0';
   signal tx_eof_prev   : std_logic := '0';
   signal tx_avail      : unsigned(2 downto 0) := (others => '0');
   signal tx_done_tgl   : std_logic := '0';
   signal tx_done_meta  : std_logic := '0';
   signal tx_done_sync  : std_logic := '0';
   signal tx_done_prev  : std_logic := '0';
   signal link_meta     : std_logic := '0';
   signal link_sync     : std_logic := '0';
   attribute ASYNC_REG of tx_eof_meta  : signal is "TRUE";
   attribute ASYNC_REG of tx_eof_sync  : signal is "TRUE";
   attribute ASYNC_REG of tx_done_meta : signal is "TRUE";
   attribute ASYNC_REG of tx_done_sync : signal is "TRUE";
   attribute ASYNC_REG of link_meta    : signal is "TRUE";
   attribute ASYNC_REG of link_sync    : signal is "TRUE";

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
   signal mdio_cmd      : std_logic_vector(0 to 45);
   signal mdio_cycle    : natural range 0 to 63;
   signal mdio_busy     : std_logic := '0';
   signal mdio_pending  : std_logic := '0';
   signal mdio_start    : std_logic := '0';
   signal mdio_reg      : std_logic_vector(4 downto 0) := (others => '0');
   signal mdio_data     : std_logic_vector(15 downto 0) := (others => '0');
   signal mdio_done     : std_logic := '0';
   signal mdio_ta_ok    : std_logic := '0';

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
   -- FIFOs
   ---------------------------------------------------------------------------------------------
   i_rx_fifo : entity work.eth_afifo
      generic map (
         G_ADDR_BITS => G_RX_FIFO_BITS,
         G_WIDTH     => 9
      )
      port map (
         wr_clk_i   => clk_i,
         wr_rst_i   => rst_i,
         wr_en_i    => rx_fifo_wr,
         wr_data_i  => rx_fifo_din,
         wr_full_o  => rx_fifo_full,
         wr_afull_o => rx_fifo_afull,
         rd_clk_i   => sys_clk_i,
         rd_rst_i   => sys_rst_i,
         rd_en_i    => rx_rd_i,
         rd_data_o  => rx_data_o,
         rd_empty_o => rx_empty_o
      );

   i_tx_fifo : entity work.eth_afifo
      generic map (
         G_ADDR_BITS => G_TX_FIFO_BITS,
         G_WIDTH     => 9
      )
      port map (
         wr_clk_i   => sys_clk_i,
         wr_rst_i   => sys_rst_i,
         wr_en_i    => tx_wr_i,
         wr_data_i  => tx_data_i,
         wr_full_o  => tx_fifo_full,
         wr_afull_o => open,
         rd_clk_i   => clk_i,
         rd_rst_i   => rst_i,
         rd_en_i    => tx_fifo_rd,
         rd_data_o  => tx_fifo_dout,
         rd_empty_o => tx_fifo_empty
      );

   tx_full_o <= tx_fifo_full;

   ---------------------------------------------------------------------------------------------
   -- Card-side handshakes (sys_clk_i): count queued frames, report finished ones, link level
   ---------------------------------------------------------------------------------------------
   p_sys : process (sys_clk_i)
   begin
      if rising_edge(sys_clk_i) then
         if tx_wr_i = '1' and tx_data_i(8) = '1' and tx_fifo_full = '0' then
            tx_eof_tgl <= not tx_eof_tgl;
         end if;
         tx_done_meta <= tx_done_tgl;
         tx_done_sync <= tx_done_meta;
         tx_done_prev <= tx_done_sync;
         tx_done_o    <= tx_done_sync xor tx_done_prev;
         link_meta    <= link_up;
         link_sync    <= link_meta;
         if sys_rst_i = '1' then
            tx_eof_tgl <= '0';
            tx_done_o  <= '0';
         end if;
      end if;
   end process p_sys;

   link_up_o <= link_sync;

   ---------------------------------------------------------------------------------------------
   -- Receiver: the pair (rxd_q, rxdv_q) is the sample being decoded, (rxd_iob, rxdv_iob) the next one
   ---------------------------------------------------------------------------------------------
   p_rx : process (clk_i)
      variable v_accept : boolean;     -- the older sample is frame data
      variable v_end    : boolean;     -- CRS_DV low twice: carrier and data gone
      variable v_byte   : std_logic_vector(7 downto 0);
      variable v_crc    : std_logic_vector(31 downto 0);
      variable v_status : std_logic_vector(7 downto 0);
   begin
      if rising_edge(clk_i) then
         v_accept := (rxdv_q = '1') or (rxdv_iob = '1');
         v_end    := (rxdv_q = '0') and (rxdv_iob = '0');
         v_byte   := rxd_q & rx_byte_sr(7 downto 2);
         v_crc    := crc32_dibit(rx_crc, rxd_q);

         rx_fifo_wr <= '0';

         if rxer_iob = '1' then
            rx_er_seen <= '1';
         end if;

         case rx_state is
            when RX_IDLE =>
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
                  rx_er_frame  <= '0';
                  rx_ovr_frame <= '0';
                  rx_frames    <= rx_frames + 1;
               elsif rxd_q /= "01" then
                  rx_state <= RX_DROP;                              -- junk in the preamble
               end if;

            when RX_DATA =>
               if rxer_iob = '1' then
                  rx_er_frame <= '1';
               end if;
               if v_end then
                  rx_state <= RX_IDLE;
                  v_status := (others => '0');
                  if rx_dibit_cnt = 0 and rx_crc = C_CRC_RESIDUE then
                     v_status(0) := '1';
                  end if;
                  if rx_byte_cnt < 64 then
                     v_status(1) := '1';
                  end if;
                  if rx_byte_cnt > 1522 then
                     v_status(2) := '1';
                  end if;
                  if rx_dibit_cnt /= 0 then
                     v_status(3) := '1';
                  end if;
                  v_status(4) := rx_er_frame;
                  v_status(5) := rx_ovr_frame;
                  rx_fifo_wr  <= '1';                               -- the end entry always fits (afull margin)
                  rx_fifo_din <= '1' & v_status;
                  if v_status(0) = '1' and rx_byte_cnt >= 64 then
                     rx_crc_ok <= rx_crc_ok + 1;
                  end if;
               elsif v_accept then
                  rx_crc     <= v_crc;
                  rx_byte_sr <= v_byte;
                  if rx_dibit_cnt = 3 then
                     rx_dibit_cnt <= 0;
                     if rx_byte_cnt < 2047 then
                        rx_byte_cnt <= rx_byte_cnt + 1;
                     end if;
                     if rx_fifo_afull = '0' then
                        rx_fifo_wr  <= '1';
                        rx_fifo_din <= '0' & v_byte;
                     else
                        rx_ovr_frame <= '1';
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
            rx_fifo_wr <= '0';
            rx_frames  <= (others => '0');
            rx_crc_ok  <= (others => '0');
            rx_er_seen <= '0';
         end if;
      end if;
   end process p_rx;

   ---------------------------------------------------------------------------------------------
   -- Transmitter: one frame per queued end entry, padded to 60 bytes, FCS appended
   ---------------------------------------------------------------------------------------------
   -- pop at the start of the frame and after every data byte until the end entry has been taken
   tx_fetch   <= '1' when (tx_state = TX_PREAMBLE and tx_cnt = 31) or
                          (tx_state = TX_DATA and tx_dibit = 3 and tx_eof_seen = '0') else '0';
   tx_fifo_rd <= tx_fetch and not tx_fifo_empty;

   p_tx : process (clk_i)
      variable v_d     : std_logic_vector(1 downto 0);
      variable v_crc   : std_logic_vector(31 downto 0);
      variable v_avail : unsigned(2 downto 0);
      variable v_eof   : boolean;      -- the entry fetched now ends the frame (or nothing is queued)
   begin
      if rising_edge(clk_i) then
         -- queued-frame counter
         tx_eof_meta <= tx_eof_tgl;
         tx_eof_sync <= tx_eof_meta;
         tx_eof_prev <= tx_eof_sync;
         v_avail := tx_avail;
         if (tx_eof_sync xor tx_eof_prev) = '1' then
            v_avail := v_avail + 1;
         end if;

         v_eof := (tx_fifo_empty = '1') or (tx_fifo_dout(8) = '1');

         case tx_state is
            when TX_IDLE =>
               txen_r <= '0';
               txd_r  <= "00";
               if tx_allowed = '1' and v_avail /= 0 then
                  v_avail  := v_avail - 1;
                  tx_state <= TX_PREAMBLE;
                  tx_cnt   <= 0;
               end if;

            when TX_PREAMBLE =>                                      -- 7 x 0x55 then 0xD5: 31 x "01", then "11"
               txen_r <= '1';
               if tx_cnt = 31 then
                  txd_r    <= "11";
                  tx_state <= TX_DATA;
                  tx_crc   <= C_CRC_INIT;
                  tx_bytes <= 0;
                  tx_dibit <= 0;
                  if v_eof then                                      -- empty frame: 60 bytes of padding
                     tx_eof_seen <= '1';
                     tx_cur_byte <= x"00";
                  else
                     tx_eof_seen <= '0';
                     tx_cur_byte <= tx_fifo_dout(7 downto 0);
                  end if;
               else
                  txd_r  <= "01";
                  tx_cnt <= tx_cnt + 1;
               end if;

            when TX_DATA =>
               v_d   := tx_cur_byte(2*tx_dibit + 1 downto 2*tx_dibit);
               v_crc := crc32_dibit(tx_crc, v_d);
               txd_r  <= v_d;
               tx_crc <= v_crc;
               if tx_dibit = 3 then
                  tx_dibit <= 0;
                  tx_bytes <= tx_bytes + 1;
                  if tx_eof_seen = '1' or v_eof then
                     tx_eof_seen <= '1';
                     if tx_bytes + 1 < C_MIN_FRAME then
                        tx_cur_byte <= x"00";                        -- padding
                     else
                        tx_state  <= TX_FCS;
                        tx_fcs_sr <= not v_crc;
                        tx_cnt    <= 0;
                     end if;
                  else
                     tx_cur_byte <= tx_fifo_dout(7 downto 0);
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
                  tx_state    <= TX_IDLE;
                  tx_done_tgl <= not tx_done_tgl;
               else
                  tx_cnt <= tx_cnt + 1;
               end if;
         end case;

         tx_avail <= v_avail;

         if rst_i = '1' then
            tx_state    <= TX_IDLE;
            tx_frames   <= (others => '0');
            tx_avail    <= (others => '0');
            tx_done_tgl <= '0';
            txen_r      <= '0';
            txd_r       <= "00";
         end if;
      end if;
   end process p_tx;

   ---------------------------------------------------------------------------------------------
   -- MDIO master (unchanged from the spike). MDC cycle j: MAC bit j is driven at the falling edge
   -- before rising edge j+1, PHY bit j is launched after rising edge j and sampled two clocks
   -- before rising edge j+1 (mdio_cycle = j).
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

         if mdc_cnt = G_MDC_HALF_CYCLES - 1 and mdio_busy = '1' then
            if mdio_cycle <= 45 then
               mdio_oe  <= '1';
               mdio_out <= mdio_cmd(mdio_cycle);
            else
               mdio_oe  <= '0';
               mdio_out <= '1';
            end if;
         end if;

         if mdc_cnt = C_MDC_PERIOD - 2 and mdio_busy = '1' then
            if mdio_cycle = 47 then
               mdio_ta_ok <= not mdio_sync;
            elsif mdio_cycle >= 48 then
               mdio_data <= mdio_data(14 downto 0) & mdio_sync;
            end if;
         end if;

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
   -- PHY sequencer (unchanged from the spike): reset, wait, ID registers once, then BMSR + PHY
   -- control 1 every G_POLL_CYCLES
   ---------------------------------------------------------------------------------------------
   p_ctl : process (clk_i)
   begin
      if rising_edge(clk_i) then
         mdio_start <= '0';

         case ctl_state is
            when C_RESET =>
               phy_reset_n <= '0';
               tx_allowed  <= '0';
               if ctl_timer = G_RESET_CYCLES - 1 then
                  ctl_timer <= 0;
                  ctl_state <= C_WAIT;
               else
                  ctl_timer <= ctl_timer + 1;
               end if;

            when C_WAIT =>
               phy_reset_n <= '1';
               if ctl_timer = G_MDIO_WAIT_CYCLES - 1 then
                  ctl_timer  <= 0;
                  ctl_state  <= C_RD_ID1;
                  tx_allowed <= '1';
               else
                  ctl_timer <= ctl_timer + 1;
               end if;

            when C_RD_ID1 | C_RD_ID2 | C_RD_STRAP | C_RD_BMSR | C_RD_PC1 =>
               if ctl_issued = '0' then
                  mdio_start <= '1';
                  ctl_issued <= '1';
                  case ctl_state is
                     when C_RD_ID1   => mdio_reg <= "00010";          -- 2h  PHY identifier 1
                     when C_RD_ID2   => mdio_reg <= "00011";          -- 3h  PHY identifier 2
                     when C_RD_STRAP => mdio_reg <= "10111";          -- 17h operation mode strap status
                     when C_RD_BMSR  => mdio_reg <= "00001";          -- 1h  basic status
                     when others     => mdio_reg <= "11110";          -- 1Eh PHY control 1
                  end case;
               elsif mdio_done = '1' then
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
   -- Debug taps
   ---------------------------------------------------------------------------------------------
   dbg_rx_frames_o <= std_logic_vector(rx_frames);
   dbg_rx_crc_ok_o <= std_logic_vector(rx_crc_ok);
   dbg_tx_frames_o <= std_logic_vector(tx_frames);
   dbg_phy_o       <= link_up & phy_id_ok & rx_er_seen & phy_bmsr(5) & phy_pc1(1) & phy_pc1(2) &
                      phy_strap(15) & phy_strap(13);

end architecture rtl;
