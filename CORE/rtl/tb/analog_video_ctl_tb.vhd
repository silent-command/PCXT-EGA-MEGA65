-------------------------------------------------------------------------------------------------------------
-- analog_video_ctl_tb: self-checking bench for CORE/vhdl/analog_video_ctl.vhd
--
-- Clocks: QNICE 50 MHz and video 57.27 MHz with an unrelated phase. video_mode13_i is driven from the
-- video clock, i.e. asynchronously to the QNICE side that consumes it.
--
-- Tests
--   1 default (31 kHz, mode13 = 0): scandoubler 1, retro15kHz 0, csync 0
--   2 mode13 rises: scandoubler drops within 4 QNICE clocks, exactly one transition, nothing else moves
--   3 mode13 falls: scandoubler returns, exactly one transition
--   4 15 kHz: scandoubler 0, retro15kHz 1, csync 0; mode13 toggling changes nothing
--   5 csync: only together with 15 kHz (15 kHz + csync -> 1; 31 kHz + csync -> 0 and scandoubler back)
--   6 50 asynchronous mode13 edges at odd spacings in 31 kHz mode: always settled within 4 QNICE
--     clocks, one transition per edge
--   7 video_ce_ovl_o alternates on every video clock
--   8 mode350 rises: scandoubler drops, video_analog_dbl_o rises, retro15kHz/csync unchanged
--   9 mode350 with 15 kHz selected: no doubling at all (scandoubler 0, analog_dbl 0)
--  10 mode350 and mode13 together, and 40 asynchronous mode350 edges at odd spacings
-- The last line is "AVC RESULT: PASS/FAIL checks=N errors=M".
--
-- Run: powershell -File CORE/rtl/tb/run_analog_video_ctl_tb.ps1
-------------------------------------------------------------------------------------------------------------
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use std.textio.all;

entity analog_video_ctl_tb is
end entity analog_video_ctl_tb;

architecture sim of analog_video_ctl_tb is

   constant C_QNICE_PERIOD : time := 20 ns;       -- 50 MHz
   constant C_VIDEO_PERIOD : time := 17.461 ns;   -- 57.27 MHz

   signal qnice_clk         : std_logic := '0';
   signal video_clk         : std_logic := '0';
   signal qnice_vga_15khz   : std_logic := '0';
   signal qnice_vga_csync   : std_logic := '0';
   signal video_mode13      : std_logic := '0';
   signal video_mode350     : std_logic := '0';
   signal qnice_scandoubler : std_logic;
   signal qnice_retro15khz  : std_logic;
   signal qnice_csync       : std_logic;
   signal video_ce_ovl      : std_logic;
   signal video_analog_dbl  : std_logic;

   -- transition counters, sampled per QNICE clock (what the framework's CDC sees)
   signal cnt_sd     : natural := 0;
   signal cnt_retro  : natural := 0;
   signal cnt_csync  : natural := 0;

   signal done       : boolean := false;

begin

   qnice_clk <= not qnice_clk after C_QNICE_PERIOD / 2 when not done;
   video_clk <= not video_clk after C_VIDEO_PERIOD / 2 when not done;

   i_dut : entity work.analog_video_ctl
      port map (
         qnice_clk_i         => qnice_clk,
         qnice_vga_15khz_i   => qnice_vga_15khz,
         qnice_vga_csync_i   => qnice_vga_csync,
         qnice_scandoubler_o => qnice_scandoubler,
         qnice_retro15khz_o  => qnice_retro15khz,
         qnice_csync_o       => qnice_csync,
         video_clk_i         => video_clk,
         video_mode13_i      => video_mode13,
         video_mode350_i     => video_mode350,
         video_analog_dbl_o  => video_analog_dbl,
         video_ce_ovl_o      => video_ce_ovl
      );

   p_monitor : process (qnice_clk)
      variable sd_q, retro_q, cs_q : std_logic := 'U';
   begin
      if rising_edge(qnice_clk) then
         if sd_q    /= 'U' and qnice_scandoubler /= sd_q    then cnt_sd    <= cnt_sd    + 1; end if;
         if retro_q /= 'U' and qnice_retro15khz  /= retro_q then cnt_retro <= cnt_retro + 1; end if;
         if cs_q    /= 'U' and qnice_csync       /= cs_q    then cnt_csync <= cnt_csync + 1; end if;
         sd_q    := qnice_scandoubler;
         retro_q := qnice_retro15khz;
         cs_q    := qnice_csync;
      end if;
   end process p_monitor;

   p_test : process
      variable checks : natural := 0;
      variable errors : natural := 0;
      variable base_sd, base_retro, base_cs : natural;
      variable l : line;

      procedure check(cond : boolean; msg : string) is
      begin
         checks := checks + 1;
         if not cond then
            errors := errors + 1;
            report "AVC ERROR: " & msg severity error;
         end if;
      end procedure check;

      procedure wait_qnice(n : natural) is
      begin
         for i in 1 to n loop
            wait until rising_edge(qnice_clk);
         end loop;
         wait for 1 ns;
      end procedure wait_qnice;

      -- drive mode13 from the video clock (asynchronous to QNICE)
      procedure set_mode13(v : std_logic) is
      begin
         wait until rising_edge(video_clk);
         video_mode13 <= v;
      end procedure set_mode13;

      -- ega_mode350 comes from clk_video_base, i.e. asynchronous to both consumers
      procedure set_mode350(v : std_logic) is
      begin
         wait until rising_edge(video_clk);
         video_mode350 <= v;
      end procedure set_mode350;

      procedure expect_dbl(v : std_logic; msg : string) is
      begin
         check(video_analog_dbl = v, msg & ": analog_dbl=" & std_logic'image(video_analog_dbl) & " expected " & std_logic'image(v));
      end procedure expect_dbl;

      procedure snapshot is
      begin
         base_sd    := cnt_sd;
         base_retro := cnt_retro;
         base_cs    := cnt_csync;
      end procedure snapshot;

      procedure expect(sd, retro, cs : std_logic; msg : string) is
      begin
         check(qnice_scandoubler = sd,    msg & ": scandoubler=" & std_logic'image(qnice_scandoubler) & " expected " & std_logic'image(sd));
         check(qnice_retro15khz  = retro, msg & ": retro15khz="  & std_logic'image(qnice_retro15khz)  & " expected " & std_logic'image(retro));
         check(qnice_csync       = cs,    msg & ": csync="       & std_logic'image(qnice_csync)       & " expected " & std_logic'image(cs));
      end procedure expect;

      procedure expect_transitions(sd, retro, cs : natural; msg : string) is
      begin
         check(cnt_sd    - base_sd    = sd,    msg & ": scandoubler transitions=" & integer'image(cnt_sd - base_sd)       & " expected " & integer'image(sd));
         check(cnt_retro - base_retro = retro, msg & ": retro15khz transitions="  & integer'image(cnt_retro - base_retro) & " expected " & integer'image(retro));
         check(cnt_csync - base_cs    = cs,    msg & ": csync transitions="       & integer'image(cnt_csync - base_cs)    & " expected " & integer'image(cs));
      end procedure expect_transitions;

      variable ce_q : std_logic;
      variable ce_ok : boolean;
   begin
      -- Test 1: defaults
      wait_qnice(10);
      expect('1', '0', '0', "T1 default 31 kHz");

      -- Test 2: mode 13h appears
      snapshot;
      set_mode13('1');
      wait_qnice(4);
      expect('0', '0', '0', "T2 mode13 on");
      wait_qnice(50);
      expect_transitions(1, 0, 0, "T2");

      -- Test 3: mode 13h leaves
      snapshot;
      set_mode13('0');
      wait_qnice(4);
      expect('1', '0', '0', "T3 mode13 off");
      wait_qnice(50);
      expect_transitions(1, 0, 0, "T3");

      -- Test 4: 15 kHz output, mode13 must not matter
      snapshot;
      qnice_vga_15khz <= '1';
      wait_qnice(4);
      expect('0', '1', '0', "T4 15 kHz");
      expect_transitions(1, 1, 0, "T4 switch");
      snapshot;
      for i in 1 to 6 loop
         set_mode13(not video_mode13);
         wait_qnice(7);
         expect('0', '1', '0', "T4 15 kHz with mode13 toggling");
      end loop;
      expect_transitions(0, 0, 0, "T4 mode13 toggles");
      check(video_mode13 = '0', "T4 bench: mode13 back at 0");

      -- Test 5: csync
      snapshot;
      qnice_vga_csync <= '1';
      wait_qnice(4);
      expect('0', '1', '1', "T5 15 kHz + csync");
      qnice_vga_15khz <= '0';                  -- csync bit still set, but 31 kHz selected
      wait_qnice(4);
      expect('1', '0', '0', "T5 31 kHz ignores csync");
      wait_qnice(20);
      expect_transitions(1, 1, 2, "T5");   -- sd 0->1, retro 1->0, csync 0->1->0
      qnice_vga_csync <= '0';
      wait_qnice(4);

      -- Test 6: many asynchronous mode13 edges in 31 kHz mode
      for i in 1 to 50 loop
         snapshot;
         set_mode13('1');
         for j in 1 to (i mod 5) loop         -- odd spacings relative to the QNICE clock
            wait until rising_edge(video_clk);
         end loop;
         wait_qnice(4);
         expect('0', '0', '0', "T6 edge " & integer'image(i) & " on");
         wait_qnice(3);
         expect_transitions(1, 0, 0, "T6 edge " & integer'image(i) & " on");
         snapshot;
         set_mode13('0');
         for j in 1 to ((i * 3) mod 7) loop
            wait until rising_edge(video_clk);
         end loop;
         wait_qnice(4);
         expect('1', '0', '0', "T6 edge " & integer'image(i) & " off");
         wait_qnice(3);
         expect_transitions(1, 0, 0, "T6 edge " & integer'image(i) & " off");
      end loop;

      -- Test 7: overlay enable alternates every video clock
      ce_ok := true;
      wait until rising_edge(video_clk);
      wait for 1 ns;
      ce_q := video_ce_ovl;
      for i in 1 to 200 loop
         wait until rising_edge(video_clk);
         wait for 1 ns;
         if video_ce_ovl = ce_q then
            ce_ok := false;
         end if;
         ce_q := video_ce_ovl;
      end loop;
      check(ce_ok, "T7 video_ce_ovl_o does not alternate every video clock");

      -- Test 8: the 350-line raster hands the analog output to analog_line_doubler
      qnice_vga_15khz <= '0';
      qnice_vga_csync <= '0';
      wait_qnice(6);
      expect('1', '0', '0', "T8 precondition 31 kHz");
      expect_dbl('0', "T8 precondition");
      snapshot;
      set_mode350('1');
      wait_qnice(4);
      expect('0', '0', '0', "T8 mode350 on: framework scandoubler must be off");
      expect_dbl('1', "T8 mode350 on");
      wait_qnice(50);
      expect_transitions(1, 0, 0, "T8");
      snapshot;
      set_mode350('0');
      wait_qnice(4);
      expect('1', '0', '0', "T8 mode350 off");
      expect_dbl('0', "T8 mode350 off");
      wait_qnice(50);
      expect_transitions(1, 0, 0, "T8 off");

      -- Test 9: the 15 kHz items keep their old behaviour - nothing is doubled, by either doubler
      snapshot;
      qnice_vga_15khz <= '1';
      set_mode350('1');
      wait_qnice(8);
      expect('0', '1', '0', "T9 15 kHz + mode350");
      expect_dbl('0', "T9 15 kHz + mode350");
      qnice_vga_csync <= '1';
      wait_qnice(6);
      expect('0', '1', '1', "T9 15 kHz + csync + mode350");
      expect_dbl('0', "T9 15 kHz + csync + mode350");
      -- back to 31 kHz with mode350 still set: the doubler takes over again
      qnice_vga_csync <= '0';
      qnice_vga_15khz <= '0';
      wait_qnice(8);
      expect('0', '0', '0', "T9 back to 31 kHz with mode350");
      expect_dbl('1', "T9 back to 31 kHz with mode350");

      -- Test 10: mode350 together with mode13, then many asynchronous mode350 edges
      set_mode13('1');
      wait_qnice(6);
      expect('0', '0', '0', "T10 mode350 + mode13");
      expect_dbl('1', "T10 mode350 + mode13");   -- mode350 owns the analog raster
      set_mode13('0');
      set_mode350('0');
      wait_qnice(6);
      expect('1', '0', '0', "T10 both off");
      expect_dbl('0', "T10 both off");

      for i in 1 to 40 loop
         snapshot;
         set_mode350('1');
         for j in 1 to (i mod 6) loop
            wait until rising_edge(video_clk);
         end loop;
         wait_qnice(5);
         expect('0', '0', '0', "T10 edge " & integer'image(i) & " on");
         expect_dbl('1', "T10 edge " & integer'image(i) & " on");
         wait_qnice(3);
         expect_transitions(1, 0, 0, "T10 edge " & integer'image(i) & " on");
         snapshot;
         set_mode350('0');
         for j in 1 to ((i * 5) mod 9) loop
            wait until rising_edge(video_clk);
         end loop;
         wait_qnice(5);
         expect('1', '0', '0', "T10 edge " & integer'image(i) & " off");
         expect_dbl('0', "T10 edge " & integer'image(i) & " off");
         wait_qnice(3);
         expect_transitions(1, 0, 0, "T10 edge " & integer'image(i) & " off");
      end loop;

      -- Result
      write(l, string'("AVC RESULT: "));
      if errors = 0 then
         write(l, string'("PASS"));
      else
         write(l, string'("FAIL"));
      end if;
      write(l, string'(" checks=") & integer'image(checks) & " errors=" & integer'image(errors));
      writeline(output, l);
      done <= true;
      wait;
   end process p_test;

end architecture sim;
