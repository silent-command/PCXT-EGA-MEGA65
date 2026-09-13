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
--      The 350-line modes (18.4 - 21.9 kHz, video_mode350_i) cannot be doubled by the framework at all:
--      their 16.257 MHz dot enable is an NCO (ega_dot_clock.v:11-19) and reaches clk_57_ps as pulses 3 or
--      4 clocks apart, while scandoubler.v:64-91 latches one fixed pixel size and resamples at it. So the
--      framework scandoubler is dropped for them too and CORE/vhdl/analog_line_doubler.vhd, which measures
--      the line instead of the dot clock, takes over on the analog branch: video_analog_dbl_o. Result
--      ~43.6 kHz / 700 lines at the unchanged frame rate. See docs/analog-video.md section 2.
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
--            vga_mode13_active (clk_card_video, the muxed 28.636 / 25.2 MHz clock) and video_mode350_i is
--            ega_mode350 (clk_video_base, 28.636 MHz, ega_top.v:1383); both are treated as asynchronous:
--            2-FF ASYNC_REG synchronisers bring them into the QNICE domain, and a second pair brings
--            video_mode350_i into the video domain for video_analog_dbl_o. They are levels that change
--            once per mode set (vga_mode13_ctrl.v:16-23, ega_top.v:1379-1383 updates at vblank), so no
--            stretching is needed. The 15 kHz menu bit is crossed the other way, QNICE -> video, for the
--            same output; analog_line_doubler only samples it at a line boundary.
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
      video_mode350_i     : in  std_logic;   -- pcxt_core video_mode350_o (clk_video_base, asynchronous)
      video_analog_dbl_o  : out std_logic;   -- -> av_pipeline video_analog_dbl_i (analog_line_doubler)
      video_ce_ovl_o      : out std_logic    -- -> framework video_ce_ovl (2x pixel enable)
   );
end entity analog_video_ctl;

architecture rtl of analog_video_ctl is

   -- video_mode13_i / video_mode350_i synchronised into the QNICE domain
   signal qnice_mode13_meta  : std_logic := '0';
   signal qnice_mode13       : std_logic := '0';
   signal qnice_mode350_meta : std_logic := '0';
   signal qnice_mode350      : std_logic := '0';
   -- video_mode350_i and the 15 kHz menu bit synchronised into the video domain
   signal video_mode350_meta : std_logic := '0';
   signal video_mode350      : std_logic := '0';
   signal video_15khz_meta   : std_logic := '0';
   signal video_15khz        : std_logic := '0';
   attribute async_reg : string;
   attribute async_reg of qnice_mode13_meta  : signal is "true";
   attribute async_reg of qnice_mode13       : signal is "true";
   attribute async_reg of qnice_mode350_meta : signal is "true";
   attribute async_reg of qnice_mode350      : signal is "true";
   attribute async_reg of video_mode350_meta : signal is "true";
   attribute async_reg of video_mode350      : signal is "true";
   attribute async_reg of video_15khz_meta   : signal is "true";
   attribute async_reg of video_15khz        : signal is "true";

   signal qnice_scandoubler : std_logic := '0';
   signal qnice_retro15khz  : std_logic := '0';
   signal qnice_csync       : std_logic := '0';

   signal video_ce_2x       : std_logic := '0';
   signal video_analog_dbl  : std_logic := '0';

begin

   ---------------------------------------------------------------------------
   -- QNICE domain: the three framework controls
   ---------------------------------------------------------------------------

   p_qnice : process (qnice_clk_i)
   begin
      if rising_edge(qnice_clk_i) then
         qnice_mode13_meta  <= video_mode13_i;
         qnice_mode13       <= qnice_mode13_meta;
         qnice_mode350_meta <= video_mode350_i;
         qnice_mode350      <= qnice_mode350_meta;

         -- line-double only what the core emits at 15.7 kHz: mode 13h native is 31.5 kHz already, and
         -- the 350-line rasters carry a dot enable the framework doubler cannot resample (see the header)
         -- - analog_line_doubler.vhd handles those instead.
         qnice_scandoubler <= (not qnice_vga_15khz_i) and (not qnice_mode13) and (not qnice_mode350);
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
   -- video domain: overlay sampling enable, and the analog line doubler gate
   ---------------------------------------------------------------------------

   p_video : process (video_clk_i)
   begin
      if rising_edge(video_clk_i) then
         video_ce_2x        <= not video_ce_2x;

         video_mode350_meta <= video_mode350_i;
         video_mode350      <= video_mode350_meta;
         video_15khz_meta   <= qnice_vga_15khz_i;
         video_15khz        <= video_15khz_meta;

         -- Double the 350-line rasters to ~43.6 kHz for the VGA connector, but not in the 15 kHz
         -- settings: those target a 15.7 kHz set, which 43.6 kHz is no better for than 21.8 kHz, and the
         -- rest of the 15 kHz behaviour has to stay exactly as it was.
         video_analog_dbl   <= video_mode350 and (not video_15khz);
      end if;
   end process p_video;

   video_ce_ovl_o     <= video_ce_2x;
   video_analog_dbl_o <= video_analog_dbl;

end architecture rtl;
