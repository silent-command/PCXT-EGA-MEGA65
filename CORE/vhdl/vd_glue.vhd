-------------------------------------------------------------------------------------------------------------
-- PCXT-EGA on MiSTer2MEGA65: glue between mgmt_bridge and the framework's vdrives
--
-- The bridge (chipset clock) asks for 512-byte blocks by drive number and LBA
-- and works on a byte buffer. The framework's vdrives runs MiSTer's SD block
-- interface (sd_lba/sd_rd/sd_wr/sd_ack, sd_buff_*) in the QNICE clock. This
-- entity does the crossing and owns the buffer:
--
--   core -> QNICE: blk_rd/blk_wr are levels; the LBA is registered on the core
--   side and the request is delayed a few clocks behind it, so that by the time
--   the synchronised request arrives on the QNICE side the synchronised LBA is
--   stable. sd_blk_cnt is 0 (one block).
--   QNICE -> core: sd_ack per drive, synchronised. The bridge sees ack rise and
--   fall; the block is complete on the fall.
--   Buffer: a dual-clock RAM. QNICE port: written by sd_buff_wr while the
--   drive's ack is high (reads), read via sd_buff_din (writes; vdrives' firmware
--   reads the byte after setting sd_buff_addr, so one clock of latency is fine).
--   Core port: the bridge's byte port, one clock read latency.
--
-- MiSTer2MEGA65 done by sy2002 and MJoergen in 2022 and licensed under GPL v3
-------------------------------------------------------------------------------------------------------------

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

library xpm;
use xpm.vcomponents.all;

library work;
use work.vdrives_pkg.all;

entity vd_glue is
   generic (
      G_VDNUM        : natural := 3
   );
   port (
      -- core (chipset) clock domain: the bridge
      core_clk_i        : in  std_logic;
      core_rst_i        : in  std_logic;
      blk_rd_i          : in  std_logic_vector(G_VDNUM-1 downto 0);
      blk_wr_i          : in  std_logic_vector(G_VDNUM-1 downto 0);
      blk_lba_i         : in  std_logic_vector(31 downto 0);
      blk_ack_o         : out std_logic_vector(G_VDNUM-1 downto 0);
      buf_addr_i        : in  std_logic_vector(8 downto 0);
      buf_wdata_i       : in  std_logic_vector(7 downto 0);
      buf_we_i          : in  std_logic;
      buf_rdata_o       : out std_logic_vector(7 downto 0);

      -- QNICE clock domain: vdrives
      qnice_clk_i       : in  std_logic;
      sd_lba_o          : out vd_vec_array(G_VDNUM-1 downto 0)(31 downto 0);
      sd_blk_cnt_o      : out vd_vec_array(G_VDNUM-1 downto 0)(5 downto 0);
      sd_rd_o           : out vd_std_array(G_VDNUM-1 downto 0);
      sd_wr_o           : out vd_std_array(G_VDNUM-1 downto 0);
      sd_ack_i          : in  vd_std_array(G_VDNUM-1 downto 0);
      sd_buff_addr_i    : in  std_logic_vector(AW downto 0);
      sd_buff_dout_i    : in  std_logic_vector(DW downto 0);
      sd_buff_din_o     : out vd_vec_array(G_VDNUM-1 downto 0)(DW downto 0);
      sd_buff_wr_i      : in  std_logic
   );
end entity vd_glue;

architecture rtl of vd_glue is

   -- core side: delayed request so the LBA leads it through the synchronisers
   signal lba_q        : std_logic_vector(31 downto 0) := (others => '0');
   type dly_t is array (0 to 3) of std_logic_vector(G_VDNUM-1 downto 0);
   signal rd_dly       : dly_t := (others => (others => '0'));
   signal wr_dly       : dly_t := (others => (others => '0'));
   signal req_any      : std_logic;

   -- QNICE side
   signal q_lba        : std_logic_vector(31 downto 0);
   signal q_rd         : std_logic_vector(G_VDNUM-1 downto 0);
   signal q_wr         : std_logic_vector(G_VDNUM-1 downto 0);
   signal q_ack_any    : std_logic;

   -- core side, synchronised acks
   signal c_ack        : std_logic_vector(G_VDNUM-1 downto 0);

   -- the block buffer (xpm true dual port RAM, independent clocks)
   signal q_we         : std_logic_vector(0 downto 0);
   signal c_we         : std_logic_vector(0 downto 0);
   signal q_rdata      : std_logic_vector(7 downto 0);
   signal c_rdata      : std_logic_vector(7 downto 0);

begin

   ---------------------------------------------------------------------------
   -- core -> QNICE
   ---------------------------------------------------------------------------
   req_any <= or blk_rd_i or or blk_wr_i;

   p_core : process (core_clk_i)
   begin
      if rising_edge(core_clk_i) then
         -- capture the LBA when a request first appears, keep it while it lasts
         if req_any = '1' and rd_dly(0) = (rd_dly(0)'range => '0') and wr_dly(0) = (wr_dly(0)'range => '0') then
            lba_q <= blk_lba_i;
         end if;
         rd_dly(0) <= blk_rd_i;
         wr_dly(0) <= blk_wr_i;
         for i in 1 to 3 loop
            rd_dly(i) <= rd_dly(i-1);
            wr_dly(i) <= wr_dly(i-1);
         end loop;
         if core_rst_i = '1' then
            rd_dly <= (others => (others => '0'));
            wr_dly <= (others => (others => '0'));
         end if;
      end if;
   end process;

   i_lba_sync : xpm_cdc_array_single
      generic map (WIDTH => 32, DEST_SYNC_FF => 2, SRC_INPUT_REG => 0)
      port map (src_clk => core_clk_i, src_in => lba_q, dest_clk => qnice_clk_i, dest_out => q_lba);

   i_rd_sync : xpm_cdc_array_single
      generic map (WIDTH => G_VDNUM, DEST_SYNC_FF => 3, SRC_INPUT_REG => 0)
      port map (src_clk => core_clk_i, src_in => rd_dly(3), dest_clk => qnice_clk_i, dest_out => q_rd);

   i_wr_sync : xpm_cdc_array_single
      generic map (WIDTH => G_VDNUM, DEST_SYNC_FF => 3, SRC_INPUT_REG => 0)
      port map (src_clk => core_clk_i, src_in => wr_dly(3), dest_clk => qnice_clk_i, dest_out => q_wr);

   g_sd : for i in 0 to G_VDNUM-1 generate
      sd_lba_o(i)     <= q_lba;
      sd_blk_cnt_o(i) <= (others => '0');           -- one block
      sd_rd_o(i)      <= q_rd(i);
      sd_wr_o(i)      <= q_wr(i);
      sd_buff_din_o(i) <= q_rdata;
   end generate g_sd;

   ---------------------------------------------------------------------------
   -- QNICE -> core
   ---------------------------------------------------------------------------
   i_ack_sync : xpm_cdc_array_single
      generic map (WIDTH => G_VDNUM, DEST_SYNC_FF => 3, SRC_INPUT_REG => 0)
      port map (src_clk => qnice_clk_i, src_in => std_logic_vector(sd_ack_i), dest_clk => core_clk_i, dest_out => c_ack);

   blk_ack_o <= c_ack;

   ---------------------------------------------------------------------------
   -- the 512-byte block buffer, dual clock
   ---------------------------------------------------------------------------
   q_ack_any <= or std_logic_vector(sd_ack_i);

   q_we(0) <= sd_buff_wr_i and q_ack_any;
   c_we(0) <= buf_we_i;

   i_buf : xpm_memory_tdpram
      generic map (
         MEMORY_SIZE        => 4096,
         MEMORY_PRIMITIVE   => "block",
         CLOCKING_MODE      => "independent_clock",
         MEMORY_INIT_FILE   => "none",
         MEMORY_INIT_PARAM  => "0",
         USE_MEM_INIT       => 0,
         WAKEUP_TIME        => "disable_sleep",
         MESSAGE_CONTROL    => 0,
         ECC_MODE           => "no_ecc",
         AUTO_SLEEP_TIME    => 0,
         USE_EMBEDDED_CONSTRAINT => 0,
         MEMORY_OPTIMIZATION => "true",
         WRITE_DATA_WIDTH_A => 8,
         READ_DATA_WIDTH_A  => 8,
         BYTE_WRITE_WIDTH_A => 8,
         ADDR_WIDTH_A       => 9,
         READ_RESET_VALUE_A => "0",
         READ_LATENCY_A     => 1,
         WRITE_MODE_A       => "read_first",
         WRITE_DATA_WIDTH_B => 8,
         READ_DATA_WIDTH_B  => 8,
         BYTE_WRITE_WIDTH_B => 8,
         ADDR_WIDTH_B       => 9,
         READ_RESET_VALUE_B => "0",
         READ_LATENCY_B     => 1,
         WRITE_MODE_B       => "read_first"
      )
      port map (
         sleep          => '0',
         -- port A: QNICE side (vdrives)
         clka           => qnice_clk_i,
         rsta           => '0',
         ena            => '1',
         regcea         => '1',
         wea            => q_we,
         addra          => sd_buff_addr_i(8 downto 0),
         dina           => sd_buff_dout_i(7 downto 0),
         injectsbiterra => '0',
         injectdbiterra => '0',
         douta          => q_rdata,
         sbiterra       => open,
         dbiterra       => open,
         -- port B: core side (the bridge)
         clkb           => core_clk_i,
         rstb           => '0',
         enb            => '1',
         regceb         => '1',
         web            => c_we,
         addrb          => buf_addr_i,
         dinb           => buf_wdata_i,
         injectsbiterrb => '0',
         injectdbiterrb => '0',
         doutb          => c_rdata,
         sbiterrb       => open,
         dbiterrb       => open
      );

   buf_rdata_o <= c_rdata;

end architecture rtl;
