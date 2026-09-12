-------------------------------------------------------------------------------------------------------------
-- ramtest_mem_model: the MEGA65 memory path behind the KFSDRAM overlay, as one
-- std_logic-only entity so the SystemVerilog system bench (ramtest_sys_tb.sv)
-- can instantiate it without VHDL generics of type boolean/unsigned.
--
--   mem_backend.vhd (G_CACHE = false as on the released core, G_BIST = false)
--   behind it, G_REAL = 1 (default): the framework's real HyperRAM path as in
--   mem_backend_tb.vhd's harness - avm_arbit_general with the scaler (64-word
--   bursts) and QNICE traffic models, hyperram_errata / _config / _ctrl and the
--   HyperBus device model, G_HR_BASE = 0x200000 as on the core;
--   G_REAL = 0: hr_model, the compact random-latency model (G_HR_BASE = 0).
-------------------------------------------------------------------------------------------------------------
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity ramtest_mem_model is
   generic (
      G_SEED : positive := 1;
      G_REAL : integer  := 1
   );
   port (
      clk_i               : in  std_logic;
      rst_i               : in  std_logic;
      hr_clk_i            : in  std_logic;
      hr_rst_i            : in  std_logic;
      avm_address_i       : in  std_logic_vector(21 downto 0);
      avm_writedata_i     : in  std_logic_vector(7 downto 0);
      avm_write_i         : in  std_logic;
      avm_read_i          : in  std_logic;
      avm_readdata_o      : out std_logic_vector(7 downto 0);
      avm_readdatavalid_o : out std_logic;
      avm_waitrequest_o   : out std_logic;
      rom_wr_i            : in  std_logic;
      rom_index_i         : in  std_logic_vector(7 downto 0);
      rom_addr_i          : in  std_logic_vector(24 downto 0);
      rom_data_i          : in  std_logic_vector(15 downto 0)
   );
end entity ramtest_mem_model;

architecture sim of ramtest_mem_model is
   function pick(c : boolean; a : natural; b : natural) return natural is
   begin
      if c then return a; else return b; end if;
   end function;

   constant C_REAL     : boolean := G_REAL /= 0;
   constant C_MEM_BITS : natural := pick(C_REAL, 22, 21);
   constant C_HR_BASE  : natural := pick(C_REAL, 16#200000#, 0);   -- word address of XT byte 0

   signal hr_write, hr_read, hr_readdatavalid, hr_waitrequest : std_logic;
   signal hr_address    : std_logic_vector(31 downto 0);
   signal hr_writedata  : std_logic_vector(15 downto 0);
   signal hr_readdata   : std_logic_vector(15 downto 0);
   signal hr_byteenable : std_logic_vector(1 downto 0);
   signal hr_burstcount : std_logic_vector(7 downto 0);
   signal hr_state      : natural;
   signal hr_viol       : natural;

   -- real path
   signal sc_write, sc_read, sc_readdatavalid, sc_waitrequest : std_logic;
   signal sc_address        : std_logic_vector(31 downto 0);
   signal sc_writedata, sc_readdata : std_logic_vector(15 downto 0);
   signal sc_byteenable     : std_logic_vector(1 downto 0);
   signal sc_burstcount     : std_logic_vector(7 downto 0);
   signal qn_write, qn_read, qn_readdatavalid, qn_waitrequest : std_logic;
   signal qn_address        : std_logic_vector(31 downto 0);
   signal qn_writedata, qn_readdata : std_logic_vector(15 downto 0);
   signal qn_byteenable     : std_logic_vector(1 downto 0);
   signal qn_burstcount     : std_logic_vector(7 downto 0);
   signal ar_write, ar_read, ar_readdatavalid, ar_waitrequest : std_logic;
   signal ar_address        : std_logic_vector(31 downto 0);
   signal ar_writedata, ar_readdata : std_logic_vector(15 downto 0);
   signal ar_byteenable     : std_logic_vector(1 downto 0);
   signal ar_burstcount     : std_logic_vector(7 downto 0);
   signal er_write, er_read, er_readdatavalid, er_waitrequest : std_logic;
   signal er_address        : std_logic_vector(31 downto 0);
   signal er_writedata, er_readdata : std_logic_vector(15 downto 0);
   signal er_byteenable     : std_logic_vector(1 downto 0);
   signal er_burstcount     : std_logic_vector(7 downto 0);
   signal cf_write, cf_read, cf_readdatavalid, cf_waitrequest : std_logic;
   signal cf_address        : std_logic_vector(31 downto 0);
   signal cf_writedata, cf_readdata : std_logic_vector(15 downto 0);
   signal cf_byteenable     : std_logic_vector(1 downto 0);
   signal cf_burstcount     : std_logic_vector(7 downto 0);
   signal hb_csn, hb_dq_oe, hb_rwds_oe, hb_read, hb_dq_ie, hb_rwds_in, hb_rstn : std_logic;
   signal hb_ck_ddr, hb_rwds_ddr_out : std_logic_vector(1 downto 0);
   signal hb_dq_ddr_in, hb_dq_ddr_out : std_logic_vector(15 downto 0);
   signal cnt_long, cnt_short : unsigned(31 downto 0);
   signal sc_errors, qn_errors, sc_reads, qn_reads, sc_beats, qn_beats : natural := 0;
   signal hb_words          : natural := 0;
begin

   i_backend : entity work.mem_backend
      generic map (
         G_HR_BASE    => to_unsigned(C_HR_BASE, 32),
         G_CACHE      => false,
         G_CACHE_SIZE => 8,
         G_BIST       => false
      )
      port map (
         clk_i               => clk_i,
         rst_i               => rst_i,
         avm_address_i       => avm_address_i,
         avm_writedata_i     => avm_writedata_i,
         avm_write_i         => avm_write_i,
         avm_read_i          => avm_read_i,
         avm_readdata_o      => avm_readdata_o,
         avm_readdatavalid_o => avm_readdatavalid_o,
         avm_waitrequest_o   => avm_waitrequest_o,
         rom_wr_i            => rom_wr_i,
         rom_index_i         => rom_index_i,
         rom_addr_i          => rom_addr_i,
         rom_data_i          => rom_data_i,
         hr_clk_i            => hr_clk_i,
         hr_rst_i            => hr_rst_i,
         hr_write_o          => hr_write,
         hr_read_o           => hr_read,
         hr_address_o        => hr_address,
         hr_writedata_o      => hr_writedata,
         hr_byteenable_o     => hr_byteenable,
         hr_burstcount_o     => hr_burstcount,
         hr_readdata_i       => hr_readdata,
         hr_readdatavalid_i  => hr_readdatavalid,
         hr_waitrequest_i    => hr_waitrequest
      );

   gen_model : if not C_REAL generate
      i_mem : entity work.hr_model
         generic map (
            G_ADDRESS_SIZE => C_MEM_BITS,
            G_SEED         => G_SEED * 3 + 1,
            G_INIT_HOLD    => 300,
            G_LAT_MIN      => 10,
            G_LAT_MAX      => 60,
            G_HOLD_MAX     => 80
         )
         port map (
            clk_i               => hr_clk_i,
            rst_i               => hr_rst_i,
            avm_write_i         => hr_write,
            avm_read_i          => hr_read,
            avm_address_i       => hr_address(C_MEM_BITS-1 downto 0),
            avm_writedata_i     => hr_writedata,
            avm_byteenable_i    => hr_byteenable,
            avm_burstcount_i    => hr_burstcount,
            avm_readdata_o      => hr_readdata,
            avm_readdatavalid_o => hr_readdatavalid,
            avm_waitrequest_o   => hr_waitrequest,
            state_o             => hr_state,
            viol_o              => hr_viol
         );
   end generate gen_model;

   gen_real : if C_REAL generate
      -- slot 2: the scaler, 64-word bursts in the bottom 2 MB (words 0..0FFFFF)
      i_scaler : entity work.avm_master_model
         generic map (G_NAME => "ramtest/scaler", G_SEED => G_SEED * 5 + 2, G_BURST => 64,
                      G_ADDR_LO => 0, G_ADDR_HI => 16#0FFFFF#, G_IDLE_MIN => 0, G_IDLE_MAX => 200)
         port map (clk_i => hr_clk_i, rst_i => hr_rst_i,
                   avm_write_o => sc_write, avm_read_o => sc_read, avm_address_o => sc_address,
                   avm_writedata_o => sc_writedata, avm_byteenable_o => sc_byteenable, avm_burstcount_o => sc_burstcount,
                   avm_readdata_i => sc_readdata, avm_readdatavalid_i => sc_readdatavalid, avm_waitrequest_i => sc_waitrequest,
                   errors_o => sc_errors, reads_o => sc_reads, beats_o => sc_beats);

      -- slot 0: QNICE, the odd single access in words 1F0000..1FFFFF
      i_qnice : entity work.avm_master_model
         generic map (G_NAME => "ramtest/qnice", G_SEED => G_SEED * 7 + 4, G_BURST => 1,
                      G_ADDR_LO => 16#1F0000#, G_ADDR_HI => 16#1FFFFF#, G_IDLE_MIN => 300, G_IDLE_MAX => 3000)
         port map (clk_i => hr_clk_i, rst_i => hr_rst_i,
                   avm_write_o => qn_write, avm_read_o => qn_read, avm_address_o => qn_address,
                   avm_writedata_o => qn_writedata, avm_byteenable_o => qn_byteenable, avm_burstcount_o => qn_burstcount,
                   avm_readdata_i => qn_readdata, avm_readdatavalid_i => qn_readdatavalid, avm_waitrequest_i => qn_waitrequest,
                   errors_o => qn_errors, reads_o => qn_reads, beats_o => qn_beats);

      i_arb : entity work.avm_arbit_general
         generic map (G_NUM_SLAVES => 3, G_FREQ_HZ => 100_000_000, G_ADDRESS_SIZE => 32, G_DATA_SIZE => 16)
         port map (
            clk_i                 => hr_clk_i,
            rst_i                 => hr_rst_i,
            s_avm_write_i         => sc_write      & hr_write      & qn_write,
            s_avm_read_i          => sc_read       & hr_read       & qn_read,
            s_avm_address_i       => sc_address    & hr_address    & qn_address,
            s_avm_writedata_i     => sc_writedata  & hr_writedata  & qn_writedata,
            s_avm_byteenable_i    => sc_byteenable & hr_byteenable & qn_byteenable,
            s_avm_burstcount_i    => sc_burstcount & hr_burstcount & qn_burstcount,
            s_avm_readdata_o(3*16-1 downto 2*16) => sc_readdata,
            s_avm_readdata_o(2*16-1 downto 1*16) => hr_readdata,
            s_avm_readdata_o(1*16-1 downto 0*16) => qn_readdata,
            s_avm_readdatavalid_o(2) => sc_readdatavalid,
            s_avm_readdatavalid_o(1) => hr_readdatavalid,
            s_avm_readdatavalid_o(0) => qn_readdatavalid,
            s_avm_waitrequest_o(2)   => sc_waitrequest,
            s_avm_waitrequest_o(1)   => hr_waitrequest,
            s_avm_waitrequest_o(0)   => qn_waitrequest,
            m_avm_write_o         => ar_write,
            m_avm_read_o          => ar_read,
            m_avm_address_o       => ar_address,
            m_avm_writedata_o     => ar_writedata,
            m_avm_byteenable_o    => ar_byteenable,
            m_avm_burstcount_o    => ar_burstcount,
            m_avm_readdata_i      => ar_readdata,
            m_avm_readdatavalid_i => ar_readdatavalid,
            m_avm_waitrequest_i   => ar_waitrequest
         );

      i_errata : entity work.hyperram_errata
         port map (
            clk_i                 => hr_clk_i,
            rst_i                 => hr_rst_i,
            s_avm_waitrequest_o   => ar_waitrequest,
            s_avm_write_i         => ar_write,
            s_avm_read_i          => ar_read,
            s_avm_address_i       => ar_address,
            s_avm_writedata_i     => ar_writedata,
            s_avm_byteenable_i    => ar_byteenable,
            s_avm_burstcount_i    => ar_burstcount,
            s_avm_readdata_o      => ar_readdata,
            s_avm_readdatavalid_o => ar_readdatavalid,
            m_avm_waitrequest_i   => er_waitrequest,
            m_avm_write_o         => er_write,
            m_avm_read_o          => er_read,
            m_avm_address_o       => er_address,
            m_avm_writedata_o     => er_writedata,
            m_avm_byteenable_o    => er_byteenable,
            m_avm_burstcount_o    => er_burstcount,
            m_avm_readdata_i      => er_readdata,
            m_avm_readdatavalid_i => er_readdatavalid
         );

      i_config : entity work.hyperram_config
         generic map (G_LATENCY => 4)
         port map (
            clk_i                 => hr_clk_i,
            rst_i                 => hr_rst_i,
            s_avm_write_i         => er_write,
            s_avm_read_i          => er_read,
            s_avm_address_i       => er_address,
            s_avm_writedata_i     => er_writedata,
            s_avm_byteenable_i    => er_byteenable,
            s_avm_burstcount_i    => er_burstcount,
            s_avm_readdata_o      => er_readdata,
            s_avm_readdatavalid_o => er_readdatavalid,
            s_avm_waitrequest_o   => er_waitrequest,
            m_avm_write_o         => cf_write,
            m_avm_read_o          => cf_read,
            m_avm_address_o       => cf_address,
            m_avm_writedata_o     => cf_writedata,
            m_avm_byteenable_o    => cf_byteenable,
            m_avm_burstcount_o    => cf_burstcount,
            m_avm_readdata_i      => cf_readdata,
            m_avm_readdatavalid_i => cf_readdatavalid,
            m_avm_waitrequest_i   => cf_waitrequest
         );

      i_ctrl : entity work.hyperram_ctrl
         generic map (G_LATENCY => 4)
         port map (
            clk_i               => hr_clk_i,
            rst_i               => hr_rst_i,
            avm_waitrequest_o   => cf_waitrequest,
            avm_write_i         => cf_write,
            avm_read_i          => cf_read,
            avm_address_i       => cf_address,
            avm_writedata_i     => cf_writedata,
            avm_byteenable_i    => cf_byteenable,
            avm_burstcount_i    => cf_burstcount,
            avm_readdata_o      => cf_readdata,
            avm_readdatavalid_o => cf_readdatavalid,
            count_long_o        => cnt_long,
            count_short_o       => cnt_short,
            hb_rstn_o           => hb_rstn,
            hb_csn_o            => hb_csn,
            hb_ck_ddr_o         => hb_ck_ddr,
            hb_dq_ddr_in_i      => hb_dq_ddr_in,
            hb_dq_ddr_out_o     => hb_dq_ddr_out,
            hb_dq_oe_o          => hb_dq_oe,
            hb_dq_ie_i          => hb_dq_ie,
            hb_rwds_ddr_out_o   => hb_rwds_ddr_out,
            hb_rwds_oe_o        => hb_rwds_oe,
            hb_rwds_in_i        => hb_rwds_in,
            hb_read_o           => hb_read
         );

      i_dev : entity work.hb_device
         generic map (G_ADDR_BITS => C_MEM_BITS, G_SEED => G_SEED * 3 + 1, G_DELAY => 2)
         port map (
            clk_i             => hr_clk_i,
            hb_csn_i          => hb_csn,
            hb_ck_ddr_i       => hb_ck_ddr,
            hb_dq_ddr_out_i   => hb_dq_ddr_out,
            hb_dq_oe_i        => hb_dq_oe,
            hb_rwds_ddr_out_i => hb_rwds_ddr_out,
            hb_rwds_oe_i      => hb_rwds_oe,
            hb_read_i         => hb_read,
            hb_dq_ddr_in_o    => hb_dq_ddr_in,
            hb_dq_ie_o        => hb_dq_ie,
            hb_rwds_in_o      => hb_rwds_in,
            words_read_o      => hb_words,
            phase_o           => hr_state
         );
   end generate gen_real;

end architecture sim;
