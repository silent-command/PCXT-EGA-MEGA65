-- vd_glue_wrap: vd_glue with its vdrives_pkg array ports flattened to plain vectors, so that the
-- SystemVerilog bench vd_glue_tb.sv can bind them under xsim (mixed-language elaboration cannot map
-- SV signals onto VHDL array-of-vector formals). Drive i's LBA is bits 32*i+31 downto 32*i, its
-- sd_buff_din bits 8*i+7 downto 8*i.

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

library work;
use work.vdrives_pkg.all;

entity vd_glue_wrap is
   port (
      core_clk_i        : in  std_logic;
      core_rst_i        : in  std_logic;
      blk_rd_i          : in  std_logic_vector(2 downto 0);
      blk_wr_i          : in  std_logic_vector(2 downto 0);
      blk_lba_i         : in  std_logic_vector(31 downto 0);
      blk_ack_o         : out std_logic_vector(2 downto 0);
      buf_addr_i        : in  std_logic_vector(8 downto 0);
      buf_wdata_i       : in  std_logic_vector(7 downto 0);
      buf_we_i          : in  std_logic;
      buf_rdata_o       : out std_logic_vector(7 downto 0);
      flp_buf_addr_i    : in  std_logic_vector(8 downto 0);
      flp_buf_data_i    : in  std_logic_vector(7 downto 0);
      flp_buf_we_i      : in  std_logic;
      flp_buf_rd_i      : in  std_logic;
      flp_buf_rdata_o   : out std_logic_vector(7 downto 0);
      qnice_clk_i       : in  std_logic;
      sd_lba_o          : out std_logic_vector(95 downto 0);
      sd_rd_o           : out std_logic_vector(2 downto 0);
      sd_wr_o           : out std_logic_vector(2 downto 0);
      sd_ack_i          : in  std_logic_vector(2 downto 0);
      sd_buff_addr_i    : in  std_logic_vector(AW downto 0);
      sd_buff_dout_i    : in  std_logic_vector(DW downto 0);
      sd_buff_din_o     : out std_logic_vector(23 downto 0);
      sd_buff_wr_i      : in  std_logic
   );
end entity vd_glue_wrap;

architecture rtl of vd_glue_wrap is
   signal lba  : vd_vec_array(2 downto 0)(31 downto 0);
   signal cnt  : vd_vec_array(2 downto 0)(5 downto 0);
   signal rd   : vd_std_array(2 downto 0);
   signal wr   : vd_std_array(2 downto 0);
   signal ack  : vd_std_array(2 downto 0);
   signal din  : vd_vec_array(2 downto 0)(DW downto 0);
begin
   i_dut : entity work.vd_glue
      generic map (G_VDNUM => 3)
      port map (
         core_clk_i => core_clk_i, core_rst_i => core_rst_i,
         blk_rd_i => blk_rd_i, blk_wr_i => blk_wr_i, blk_lba_i => blk_lba_i, blk_ack_o => blk_ack_o,
         buf_addr_i => buf_addr_i, buf_wdata_i => buf_wdata_i, buf_we_i => buf_we_i, buf_rdata_o => buf_rdata_o,
         flp_buf_addr_i => flp_buf_addr_i, flp_buf_data_i => flp_buf_data_i, flp_buf_we_i => flp_buf_we_i,
         flp_buf_rd_i => flp_buf_rd_i, flp_buf_rdata_o => flp_buf_rdata_o,
         qnice_clk_i => qnice_clk_i,
         sd_lba_o => lba, sd_blk_cnt_o => cnt, sd_rd_o => rd, sd_wr_o => wr, sd_ack_i => ack,
         sd_buff_addr_i => sd_buff_addr_i, sd_buff_dout_i => sd_buff_dout_i, sd_buff_din_o => din,
         sd_buff_wr_i => sd_buff_wr_i
      );
   g : for i in 0 to 2 generate
      sd_lba_o(32 * i + 31 downto 32 * i)   <= lba(i);
      sd_buff_din_o(8 * i + 7 downto 8 * i) <= din(i)(7 downto 0);
      sd_rd_o(i) <= rd(i);
      sd_wr_o(i) <= wr(i);
      ack(i)     <= sd_ack_i(i);
   end generate g;
end architecture rtl;
