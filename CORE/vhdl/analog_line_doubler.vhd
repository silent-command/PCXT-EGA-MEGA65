-------------------------------------------------------------------------------------------------------------
-- analog_line_doubler: line doubler for the ANALOG (VGA connector) branch only, PCXT-EGA on MiSTer2MEGA65
--
-- Why this exists
--   The EGA/MDA 350-line rasters (ega_top.v:1383 ega_mode350, "more than 240 displayed lines and not the
--   private VGA path") scan at 18.4 - 21.9 kHz. That is where the BIOS screen and DOS text live with the
--   default 5154 monitor profile, and it is below the ~30 kHz an LCD VGA monitor needs, so the connector
--   shows "out of range" today. 2 x 21.8 kHz = 43.6 kHz is inside the range of nearly every multisync
--   input, but neither doubler the port already has can produce it:
--
--   * the framework's own doubler, M2M/vhdl/controllers/MiSTer/scandoubler.v inside video_mixer.sv
--     (analog_pipeline.vhd:134-157), measures ONE integer pixel size - the number of clk_57_ps clocks
--     between two ce_pix pulses in the visible area (scandoubler.v:64-91) - and then resamples the input
--     at that fixed spacing (:85-89) and replays at pixsz/2 (:126-144). The 16.257 MHz EGA dot enable is
--     an NCO in the 28.636 MHz domain (ega_dot_clock.v:11-19, 59609/105000, restarted once per CRTC line)
--     whose toggle is crossed into clk_57_ps with one synchroniser and an XOR (pcxt_core.sv:1762-1771),
--     so the enables land on alternate video clocks only and are 2 OR 4 clocks apart - measured over a
--     bench run: 194375 gaps of 2 against 618071 of 4, mean 3.5215, i.e. 16.2635 MHz. With a single
--     latched pixsz the 24 % short dots are lost: analog_pipeline_350_tb case A measures 488 of the 640
--     columns surviving. video_mixer.sv:27 states the precondition that is being violated.
--   * the core's own generic doubler, CORE/PCXT-EGA_MiSTer/rtl/video/video_scandoubler.v, is forced off
--     for these modes (ega_top.v:1043-1050) because 2 x 16.257 MHz cannot be made in the 28.636 MHz
--     domain it runs in. It also regenerates HS from hard-coded pulse widths (HS_START_80 / HS_WIDTH_80 =
--     748 / 110 source dots, :96-99) chosen for a 912-dot CGA line rather than from the measured input,
--     which is wrong for a 744-dot 16.257 MHz line.
--
-- What this module does instead
--   It never looks at a dot clock. Per source line it measures, at the input pixel enable,
--     line_pix  the number of pixel enables between two rising edges of HS, and
--     line_clk  the number of video clocks between the same two edges,
--   stores the line - colour AND hs/vs/hblank/vblank, one entry per source pixel - in a ping-pong line
--   buffer, and replays that buffer twice during the following source line, each replay spread over
--   line_clk/2 clocks by a Bresenham rate divider that adds line_pix per clock modulo line_clk/2.
--   That divider emits EXACTLY line_pix pulses in exactly line_clk/2 clocks (the accumulator returns to
--   its seed value there, and it can never reach 0 while line_pix > 0), so every source column is replayed
--   once and only once in each half line: no column skipped, none duplicated, whatever the dot clock or
--   the dot-to-clock spacing pattern is. Because HS, blanking and colour all come out of the same buffer
--   entry, the regenerated sync and blanking keep the input's geometry exactly, at half the duration -
--   nothing is derived from a table of magic positions.
--
--   Output line rate is 2x the input, output frame rate is unchanged (VS and VBLANK are replayed from the
--   buffer as well, so they still last the same number of source lines and the frame period is identical).
--   For the 350-line rasters that is 43.72 kHz with 700 active lines at the unchanged 60.05 Hz, measured
--   at the VGA pins through the whole framework analog path by CORE/rtl/tb/analog_pipeline_350_tb.sv:
--   640 columns per line, zero columns skipped or duplicated, in all three sampling phases.
--
--   Latency: one source line (the buffer being read is the one completed at the last HS edge) plus three
--   video clocks. That is invisible on an analog output and nothing downstream is latency-sensitive.
--
-- Placement, and why it is exactly where it is
--   The framework feeds ONE video stream to both output pipelines (M2M/vhdl/av_pipeline/av_pipeline.vhd),
--   so doubling upstream of that would also double the HDMI input and the ascal frame-buffer bandwidth in
--   the shared HyperRAM. This module is therefore instantiated inside M2M/vhdl/av_pipeline/
--   analog_pipeline.vhd only (gen_analog_dbl); the digital pipeline and i_video_counters keep the raw
--   core raster.
--
--   Inside analog_pipeline it sits BESIDE video_mixer, not in front of it, and a mux picks between the
--   two just before i_video_overlay. The reason is video_mixer.sv:185-194: when ce_pix is a real clock
--   enable, video_mixer sets CE_PIXEL to "~old_ce & ce_pix", the RISING EDGE of the enable, so two
--   enables on adjacent video clocks collapse into one pixel. The doubled enable here is 32.5 MHz in a
--   57.27 MHz domain, i.e. gaps of 1 or 2 clocks with about 24 % of them 1 - and CORE/rtl/tb/
--   analog_pipeline_350_tb.sv measured exactly that loss (486 of 640 columns) when this module was first
--   placed in front of the mixer. Everything downstream of the mux samples on a LEVEL
--   (vga_recover_counters.vhd:48) or on every clock, so the doubled stream passes through intact.
--   A pixel enable faster than CLK_VIDEO / 2 cannot go through this framework's video_mixer at all.
--
--   For the same reason the overlay's sampling enable has to follow: while this module owns the stream,
--   analog_pipeline.vhd feeds video_overlay's vga_ce_i from video_ce_o below instead of the free-running
--   clk/2 of analog_video_ctl.vhd, which at 28.6 MHz is slower than the doubled pixel rate and would drop
--   columns by itself.
--
-- Bypass
--   With video_dbl_i = '0' - and until the geometry of a whole line has been measured - every output is a
--   direct combinational copy of the corresponding input, so the analog path is bit-for-bit what it was
--   before this module existed and adds no latency. video_dbl_i is only re-evaluated at a line boundary,
--   so enabling or disabling it never cuts a line in half; it costs at most one bad frame, the same as the
--   framework's own scandoubler switch.
--
-- The framework's scandoubler must be OFF while this one runs: CORE/vhdl/analog_video_ctl.vhd clears
-- qnice_scandoubler_o for the 350-line modes and produces video_dbl_i (video_analog_dbl_o) for this
-- module. Bench: CORE/rtl/tb/analog_pipeline_350_tb.sv. Design notes: docs/analog-video.md section 2.
--
-- MiSTer2MEGA65 done by sy2002 and MJoergen in 2022 and licensed under GPL v3
-------------------------------------------------------------------------------------------------------------

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity analog_line_doubler is
   generic (
      -- longest source line in dots; 912 is the CGA/EGA 14.318 MHz line, the 16.257 MHz lines are shorter
      G_MAX_DOTS : natural := 1024
   );
   port (
      video_clk_i    : in  std_logic;
      video_rst_i    : in  std_logic;
      -- 1 = double this stream. Video clock domain, sampled at line boundaries only.
      video_dbl_i    : in  std_logic;

      video_ce_i     : in  std_logic;
      video_ce_ovl_i : in  std_logic;
      video_red_i    : in  std_logic_vector(7 downto 0);
      video_green_i  : in  std_logic_vector(7 downto 0);
      video_blue_i   : in  std_logic_vector(7 downto 0);
      video_hs_i     : in  std_logic;
      video_vs_i     : in  std_logic;
      video_hblank_i : in  std_logic;
      video_vblank_i : in  std_logic;

      video_ce_o     : out std_logic;
      video_ce_ovl_o : out std_logic;
      video_red_o    : out std_logic_vector(7 downto 0);
      video_green_o  : out std_logic_vector(7 downto 0);
      video_blue_o   : out std_logic_vector(7 downto 0);
      video_hs_o     : out std_logic;
      video_vs_o     : out std_logic;
      video_hblank_o : out std_logic;
      video_vblank_o : out std_logic;

      -- 1 while the doubled stream is on the outputs (for debug / status only)
      video_active_o : out std_logic
   );
end entity analog_line_doubler;

architecture rtl of analog_line_doubler is

   function f_log2(n : natural) return natural is
      variable v : natural := n - 1;
      variable r : natural := 0;
   begin
      while v > 0 loop
         r := r + 1;
         v := v / 2;
      end loop;
      if r = 0 then
         return 1;
      else
         return r;
      end if;
   end function f_log2;

   constant C_AW : natural := f_log2(G_MAX_DOTS);   -- pixel index inside one line buffer
   constant C_CW : natural := 14;                   -- video clocks per line (16384 is 3.5 x the longest)
   constant C_DW : natural := 28;                   -- {hs, vs, hblank, vblank, r(8), g(8), b(8)}

   -- input sampling: one clock after the pixel enable, where the core presents colour and blanking
   -- (pcxt_core.sv retime stage; HS/VS change on the enable itself, RGB and the blanks one clock later)
   signal s_ce      : std_logic := '0';
   signal hs_s      : std_logic := '0';
   signal hs_rise   : std_logic;

   -- write side
   signal wr_ptr    : unsigned(C_AW-1 downto 0) := (others => '0');
   signal wr_buf    : std_logic := '0';
   signal wr_sel    : std_logic;
   signal wr_idx    : unsigned(C_AW-1 downto 0);
   signal wr_a      : natural range 0 to 2*G_MAX_DOTS-1 := 0;
   signal wr_d      : std_logic_vector(C_DW-1 downto 0);
   signal clk_cnt   : unsigned(C_CW-1 downto 0) := (others => '0');

   -- geometry of the last completed line, latched at its closing HS rising edge
   signal new_pix   : unsigned(C_AW downto 0);
   signal new_half  : unsigned(C_CW-1 downto 0);
   signal geom_ok   : std_logic;
   signal line_pix  : unsigned(C_AW downto 0)   := (others => '0');
   signal half_clk  : unsigned(C_CW-1 downto 0) := (others => '0');
   signal dbl_run   : std_logic := '0';

   -- read side
   signal acc       : unsigned(C_CW downto 0) := (others => '0');   -- < half_clk + line_pix
   signal pulse     : std_logic;
   signal o_pix     : unsigned(C_AW downto 0) := (others => '0');
   signal rd_buf    : std_logic := '0';
   signal rd_a      : natural range 0 to 2*G_MAX_DOTS-1 := 0;
   signal ce_out    : std_logic := '0';
   signal ram_q     : std_logic_vector(C_DW-1 downto 0) := (others => '0');

   -- one entry per source pixel, two lines (ping-pong). Simple dual port: written on the input pixel
   -- enable, read every clock from the other half.
   type t_ram is array (0 to 2*G_MAX_DOTS-1) of std_logic_vector(C_DW-1 downto 0);
   signal ram : t_ram;
   attribute ram_style : string;
   attribute ram_style of ram : signal is "block";

begin

   ---------------------------------------------------------------------------
   -- input sampling and the HS rising edge that delimits a line
   ---------------------------------------------------------------------------

   p_sample : process (video_clk_i)
   begin
      if rising_edge(video_clk_i) then
         if video_rst_i = '1' then
            s_ce <= '0';
            hs_s <= '0';
         else
            s_ce <= video_ce_i;
            if s_ce = '1' then
               hs_s <= video_hs_i;
            end if;
         end if;
      end if;
   end process p_sample;

   hs_rise <= s_ce and video_hs_i and (not hs_s);

   ---------------------------------------------------------------------------
   -- line buffer write port
   ---------------------------------------------------------------------------

   -- the pixel that carries the HS rising edge is index 0 of the next buffer
   wr_sel <= (not wr_buf) when hs_rise = '1' else wr_buf;
   wr_idx <= (others => '0') when hs_rise = '1' else wr_ptr;
   wr_a   <= to_integer(wr_idx) when wr_sel = '0' else to_integer(wr_idx) + G_MAX_DOTS;
   wr_d   <= video_hs_i & video_vs_i & video_hblank_i & video_vblank_i &
             video_red_i & video_green_i & video_blue_i;

   rd_a   <= to_integer(o_pix(C_AW-1 downto 0)) when rd_buf = '0'
             else to_integer(o_pix(C_AW-1 downto 0)) + G_MAX_DOTS;

   p_ram : process (video_clk_i)
   begin
      if rising_edge(video_clk_i) then
         if s_ce = '1' then
            ram(wr_a) <= wr_d;
         end if;
         ram_q <= ram(rd_a);
      end if;
   end process p_ram;

   ---------------------------------------------------------------------------
   -- geometry measurement
   ---------------------------------------------------------------------------

   -- number of pixel enables in the line that has just closed, and half its length in video clocks
   new_pix  <= resize(wr_ptr, C_AW+1);
   new_half <= '0' & clk_cnt(C_CW-1 downto 1);

   -- The Bresenham divider needs at least one pixel and fewer pixels than half a line has clocks
   -- (i.e. the doubled pixel rate must stay below the video clock). Everything the core can emit in a
   -- 350-line mode satisfies this by a wide margin: 744 dots in 2620 clocks -> 744 < 1310.
   geom_ok <= '1' when new_pix > 1 and new_pix < new_half and
                       clk_cnt > 8 and wr_ptr < G_MAX_DOTS-1
              else '0';

   ---------------------------------------------------------------------------
   -- readout: two replays of the stored line per source line
   ---------------------------------------------------------------------------

   -- acc >= half_clk means "emit the next stored pixel now"
   pulse <= '1' when dbl_run = '1' and acc >= ('0' & half_clk) else '0';

   p_line : process (video_clk_i)
   begin
      if rising_edge(video_clk_i) then
         if video_rst_i = '1' then
            wr_ptr   <= (others => '0');
            wr_buf   <= '0';
            clk_cnt  <= (others => '0');
            line_pix <= (others => '0');
            half_clk <= (others => '0');
            dbl_run  <= '0';
            acc      <= (others => '0');
            o_pix    <= (others => '0');
            rd_buf   <= '0';
            ce_out   <= '0';
         elsif hs_rise = '1' then
            -- close the line: publish its geometry, swap the buffers, restart the replay
            wr_buf   <= not wr_buf;
            wr_ptr   <= to_unsigned(1, C_AW);            -- index 0 is being written this clock
            clk_cnt  <= to_unsigned(1, C_CW);
            line_pix <= new_pix;
            half_clk <= new_half;
            rd_buf   <= wr_buf;                          -- the buffer just completed
            dbl_run  <= video_dbl_i and geom_ok;
            -- seed the accumulator so the first pixel of the replay comes out on the next clock
            acc      <= '0' & new_half;
            o_pix    <= (others => '0');
            ce_out   <= '0';
         else
            if clk_cnt /= (clk_cnt'range => '1') then
               clk_cnt <= clk_cnt + 1;
            end if;
            if s_ce = '1' and wr_ptr < G_MAX_DOTS-1 then
               wr_ptr <= wr_ptr + 1;
            end if;

            -- free-running rate divider: exactly line_pix pulses per half_clk clocks
            if pulse = '1' then
               acc <= acc - ('0' & half_clk) + resize(line_pix, acc'length);
               if o_pix + 1 >= line_pix then
                  o_pix <= (others => '0');              -- start the second replay of the same line
               else
                  o_pix <= o_pix + 1;
               end if;
            elsif dbl_run = '1' then
               acc <= acc + resize(line_pix, acc'length);
            end if;
            ce_out <= pulse;
         end if;
      end if;
   end process p_line;

   ---------------------------------------------------------------------------
   -- output: the replayed line, or a transparent copy of the input
   ---------------------------------------------------------------------------

   video_ce_o     <= ce_out                 when dbl_run = '1' else video_ce_i;
   -- the overlay re-samples the picture on this enable (analog_pipeline.vhd:184 ->
   -- vga_recover_counters.vhd:46-54), so while doubling it has to run at the doubled pixel rate;
   -- the free-running clk/2 that analog_video_ctl.vhd supplies is slower than 32.5 MHz and would
   -- drop columns
   -- (analog_pipeline.vhd does the same selection itself for video_overlay's vga_ce_i; this output is
   --  kept so the module is usable stand-alone and in the bench)
   video_ce_ovl_o <= ce_out                 when dbl_run = '1' else video_ce_ovl_i;
   video_hs_o     <= ram_q(27)              when dbl_run = '1' else video_hs_i;
   video_vs_o     <= ram_q(26)              when dbl_run = '1' else video_vs_i;
   video_hblank_o <= ram_q(25)              when dbl_run = '1' else video_hblank_i;
   video_vblank_o <= ram_q(24)              when dbl_run = '1' else video_vblank_i;
   video_red_o    <= ram_q(23 downto 16)    when dbl_run = '1' else video_red_i;
   video_green_o  <= ram_q(15 downto  8)    when dbl_run = '1' else video_green_i;
   video_blue_o   <= ram_q( 7 downto  0)    when dbl_run = '1' else video_blue_i;
   video_active_o <= dbl_run;

end architecture rtl;
