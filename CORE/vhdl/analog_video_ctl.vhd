-------------------------------------------------------------------------------------------------------------
-- analog_video_ctl: analog (VGA connector) output policy for PCXT-EGA on MiSTer2MEGA65
--
-- Turns the "VGA" choice of the options menu plus the core's mode-13h raster hint into the three
-- analog-pipeline controls of the framework and the overlay sampling enable. Design notes and the
-- evidence behind every line: docs/analog-video.md.
--
--   VGA 31 kHz (qnice_vga_15khz_i = 0, the default):
--      the framework's scandoubler (M2M/vhdl/controllers/MiSTer/scandoubler.v, inside video_mixer.sv)
--      line-doubles the core's 15.7 kHz rasters - CGA/EGA 200-line modes, the splash, mode 13h in
--      its 60 Hz TV profile - to 31.4 kHz. Mode 13h in its native profile already scans at 31.5 kHz;
--      doubling it would give 63 kHz, so the scandoubler is dropped while video_mode13_i is set.
--      The 350-line modes (21.8 kHz) are passed through undoubled, see the doc for why.
--   VGA 15 kHz (qnice_vga_15khz_i = 1):
--      everything passes through at the core's own line rate; retro15kHz doubles the on-screen-menu
--      rows so the menu fits a 200-line raster (M2M/vhdl/av_pipeline/video_overlay.vhd:104-105).
--      With qnice_vga_csync_i the HS pin carries active-low composite sync and VS is held high, the
--      MiSTer VGA-to-SCART pinout (M2M/vhdl/av_pipeline/analog_pipeline.vhd:231-236).
--
-- Clock domains
--   qnice_*: QNICE, 50 MHz. The menu bits are already in this domain (qnice_osm_control_i). The three
--            qnice_*_o outputs are registered here and are crossed into the video clock by the
--            framework itself (M2M/vhdl/av_pipeline/av_pipeline.vhd:271-296, xpm_cdc_array_single).
--   video_*: the core's video output clock (clk_57_ps). video_mode13_i is the chipset's
--            vga_mode13_active (clk_card_video, the muxed 28.636 / 25.2 MHz clock) and is treated as
--            asynchronous: a 2-FF ASYNC_REG synchroniser brings it into the QNICE domain. It is a
--            level that changes once per mode set (vga_mode13_ctrl.v:16-23), so no stretching is needed.
--
-- video_ce_ovl_o
--   The analog overlay re-samples the whole picture on this enable (video_overlay.vhd ->
--   vga_recover_counters.vhd:46-54, fed from analog_pipeline.vhd:184). A scandoubled line changes every
--   other video clock (scandoubler.v:136, ce_x2o with pixsz = 4 for the 14.318 MHz dot clock), so the
--   enable has to run at least that fast or every second doubled pixel is lost. A free-running
--   divide-by-two is used in every mode: in the undoubled modes the mixer holds each pixel for four
--   clocks and sampling it twice is harmless, and the halved overlay cell (8 dots instead of 16) is what
--   makes the 23-character options menu, placed at cell 22 by the firmware (M2M/rom/screen.asm:65-67),
--   fit on a 640-dot raster at all.
--
-- MiSTer2MEGA65 done by sy2002 and MJoergen in 2022 and licensed under GPL v3
-------------------------------------------------------------------------------------------------------------

library ieee;
use ieee.std_logic_1164.all;

entity analog_video_ctl is
   port (
      -- QNICE domain
      qnice_clk_i         : in  std_logic;
      qnice_vga_15khz_i   : in  std_logic;   -- menu: one of the "15 kHz" items is selected
      qnice_vga_csync_i   : in  std_logic;   -- menu: the "15 kHz + CSync" item is selected
      qnice_scandoubler_o : out std_logic;   -- -> mega65.vhd qnice_scandoubler_o
      qnice_retro15khz_o  : out std_logic;   -- -> mega65.vhd qnice_retro15kHz_o
      qnice_csync_o       : out std_logic;   -- -> mega65.vhd qnice_csync_o

      -- video domain (clk_57_ps)
      video_clk_i         : in  std_logic;
      video_mode13_i      : in  std_logic;   -- pcxt_core video_mode13_o (clk_card_video, asynchronous)
      video_ce_ovl_o      : out std_logic    -- -> framework video_ce_ovl (2x pixel enable)
   );
end entity analog_video_ctl;

architecture rtl of analog_video_ctl is

   -- video_mode13_i synchronised into the QNICE domain
   signal qnice_mode13_meta : std_logic := '0';
   signal qnice_mode13      : std_logic := '0';
   attribute async_reg : string;
   attribute async_reg of qnice_mode13_meta : signal is "true";
   attribute async_reg of qnice_mode13      : signal is "true";

   signal qnice_scandoubler : std_logic := '0';
   signal qnice_retro15khz  : std_logic := '0';
   signal qnice_csync       : std_logic := '0';

   signal video_ce_2x       : std_logic := '0';

begin

   ---------------------------------------------------------------------------
   -- QNICE domain: the three framework controls
   ---------------------------------------------------------------------------

   p_qnice : process (qnice_clk_i)
   begin
      if rising_edge(qnice_clk_i) then
         qnice_mode13_meta <= video_mode13_i;
         qnice_mode13      <= qnice_mode13_meta;

         -- line-double only what the core emits at 15.7 kHz; mode 13h native is 31.5 kHz already
         qnice_scandoubler <= (not qnice_vga_15khz_i) and (not qnice_mode13);
         -- OSM row doubling for the 200-line rasters of the 15 kHz output
         qnice_retro15khz  <= qnice_vga_15khz_i;
         -- composite sync only makes sense on the 15 kHz output
         qnice_csync       <= qnice_vga_15khz_i and qnice_vga_csync_i;
      end if;
   end process p_qnice;

   qnice_scandoubler_o <= qnice_scandoubler;
   qnice_retro15khz_o  <= qnice_retro15khz;
   qnice_csync_o       <= qnice_csync;

   ---------------------------------------------------------------------------
   -- video domain: overlay sampling enable at twice the pixel rate
   ---------------------------------------------------------------------------

   p_video : process (video_clk_i)
   begin
      if rising_edge(video_clk_i) then
         video_ce_2x <= not video_ce_2x;
      end if;
   end process p_video;

   video_ce_ovl_o <= video_ce_2x;

end architecture rtl;
