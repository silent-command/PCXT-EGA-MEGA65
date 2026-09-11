-------------------------------------------------------------------------------------------------------------
-- analog_pipeline_wrap: bench-only shell around the unmodified M2M analog_pipeline for analog_pipeline_tb.sv.
--
-- xelab cannot associate a VHDL port of subtype "natural range 0 to 8" (video_osm_cfg_scaling_i) with a
-- Verilog net, so the SystemVerilog bench instantiates this wrapper instead; it forwards every other port
-- and generic 1:1 and ties the OSM scaling to 0 (the overlay is disabled in the bench anyway).
-------------------------------------------------------------------------------------------------------------
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity analog_pipeline_wrap is
   generic (
      G_VGA_DX                : natural;
      G_VGA_DY                : natural;
      G_FONT_FILE             : string;
      G_FONT_DX               : natural;
      G_FONT_DY               : natural
   );
   port (
      video_clk_i             : in  std_logic;
      video_rst_i             : in  std_logic;
      video_ce_i              : in  std_logic;
      video_ce_ovl_i          : in  std_logic;
      video_red_i             : in  std_logic_vector(7 downto 0);
      video_green_i           : in  std_logic_vector(7 downto 0);
      video_blue_i            : in  std_logic_vector(7 downto 0);
      video_hs_i              : in  std_logic;
      video_vs_i              : in  std_logic;
      video_hblank_i          : in  std_logic;
      video_vblank_i          : in  std_logic;
      audio_clk_i             : in  std_logic;
      audio_rst_i             : in  std_logic;
      audio_left_i            : in  std_logic_vector(15 downto 0);
      audio_right_i           : in  std_logic_vector(15 downto 0);
      video_scandoubler_i     : in  std_logic;
      video_csync_i           : in  std_logic;
      video_retro15kHz_i      : in  std_logic;
      vga_red_o               : out std_logic_vector(7 downto 0);
      vga_green_o             : out std_logic_vector(7 downto 0);
      vga_blue_o              : out std_logic_vector(7 downto 0);
      vga_hs_o                : out std_logic;
      vga_vs_o                : out std_logic;
      vdac_clk_o              : out std_logic;
      vdac_syncn_o            : out std_logic;
      vdac_blankn_o           : out std_logic;
      video_osm_cfg_enable_i  : in  std_logic;
      video_osm_cfg_xy_i      : in  std_logic_vector(15 downto 0);
      video_osm_cfg_dxdy_i    : in  std_logic_vector(15 downto 0);
      video_osm_vram_addr_o   : out std_logic_vector(15 downto 0);
      video_osm_vram_data_i   : in  std_logic_vector(15 downto 0)
   );
end entity analog_pipeline_wrap;

architecture sim of analog_pipeline_wrap is
begin

   i_analog_pipeline : entity work.analog_pipeline
      generic map (
         G_VGA_DX                => G_VGA_DX,
         G_VGA_DY                => G_VGA_DY,
         G_FONT_FILE             => G_FONT_FILE,
         G_FONT_DX               => G_FONT_DX,
         G_FONT_DY               => G_FONT_DY
      )
      port map (
         video_clk_i             => video_clk_i,
         video_rst_i             => video_rst_i,
         video_ce_i              => video_ce_i,
         video_ce_ovl_i          => video_ce_ovl_i,
         video_red_i             => video_red_i,
         video_green_i           => video_green_i,
         video_blue_i            => video_blue_i,
         video_hs_i              => video_hs_i,
         video_vs_i              => video_vs_i,
         video_hblank_i          => video_hblank_i,
         video_vblank_i          => video_vblank_i,
         audio_clk_i             => audio_clk_i,
         audio_rst_i             => audio_rst_i,
         audio_left_i            => signed(audio_left_i),
         audio_right_i           => signed(audio_right_i),
         video_scandoubler_i     => video_scandoubler_i,
         video_csync_i           => video_csync_i,
         video_retro15kHz_i      => video_retro15kHz_i,
         vga_red_o               => vga_red_o,
         vga_green_o             => vga_green_o,
         vga_blue_o              => vga_blue_o,
         vga_hs_o                => vga_hs_o,
         vga_vs_o                => vga_vs_o,
         vdac_clk_o              => vdac_clk_o,
         vdac_syncn_o            => vdac_syncn_o,
         vdac_blankn_o           => vdac_blankn_o,
         video_osm_cfg_scaling_i => 0,
         video_osm_cfg_enable_i  => video_osm_cfg_enable_i,
         video_osm_cfg_xy_i      => video_osm_cfg_xy_i,
         video_osm_cfg_dxdy_i    => video_osm_cfg_dxdy_i,
         video_osm_vram_addr_o   => video_osm_vram_addr_o,
         video_osm_vram_data_i   => video_osm_vram_data_i
      );

end architecture sim;
