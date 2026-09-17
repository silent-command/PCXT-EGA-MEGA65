-------------------------------------------------------------------------------------------------------------
-- floppy_drive_if: pin side of the MEGA65 R6 internal 3.5" floppy drive (Shugart / PC 34-pin, drive A lines)
--
-- Shared by floppy_phy_spike.vhd (the bring-up spike) and floppy_sector_engine.vhd (the read path behind the
-- DOS-facing FDC), see docs/floppy.md. Everything here was lifted unchanged out of the spike, which is what
-- the board has been driven with:
--   * the eight outputs are all active low on the cable; the control inputs of this entity are active high;
--   * the five inputs are asynchronous: two-flop ASYNC_REG synchronisers here, false paths in CORE/CORE.xdc;
--     INDEX is debounced over four samples (80 ns), RDATA over three (60 ns) and the falling edge of the
--     filtered RDATA is the flux event (mega65-core machine.vhdl:885-895, mfm_gaps.vhdl:60);
--   * TRACK0 / WPT / DSKCHG are reported as active-high levels;
--   * the step engine: STEP low for G_STEP_PULSE_CYCLES (12 us, mega65-core 12.3 us), no next pulse within
--     G_STEP_RATE_CYCLES (3 ms), no pulse within C_DIR_SETUP_CYCLES (10 us) of a DIR change. The caller
--     raises step_go_i for one clock while step_ready_o is '1'; stepdir_out_i = '1' steps out towards
--     track 0 (mega65-core sdcardio.vhdl:2672-2674 / 2713-2716).
-- Polarity and timing evidence: docs/floppy.md, "Reset-to-track-0 and timing evidence".
--
-- MEGA65 port done by silent-command in 2026 and licensed under GPL v3
-- MiSTer2MEGA65 done by sy2002 and MJoergen in 2022 and licensed under GPL v3
-------------------------------------------------------------------------------------------------------------

library ieee;
   use ieee.std_logic_1164.all;
   use ieee.numeric_std.all;

entity floppy_drive_if is
   generic (
      G_STEP_PULSE_CYCLES : natural := 600;       -- STEP low time: 12 us at 50 MHz
      G_STEP_RATE_CYCLES  : natural := 150_000    -- step to step: 3 ms
   );
   port (
      clk_i             : in    std_logic;        -- 50.000 MHz
      rst_i             : in    std_logic;

      -- controls, active high
      select_i          : in    std_logic;        -- DRIVE SELECT A
      motor_i           : in    std_logic;        -- MOTOR ON A
      side1_i           : in    std_logic;        -- head 1
      density_i         : in    std_logic;        -- level put on the DENSITY pin as is (polarity unproven)
      stepdir_out_i     : in    std_logic;        -- 1 = step out (towards track 0), 0 = step in
      step_go_i         : in    std_logic;        -- one pulse per step, only while step_ready_o
      step_ready_o      : out   std_logic;

      -- drive status, active high, clk_i domain
      index_edge_o      : out   std_logic;        -- one pulse per INDEX assertion
      flux_edge_o       : out   std_logic;        -- one pulse per flux transition on RDATA
      track0_o          : out   std_logic;
      wp_o              : out   std_logic;
      dskchg_o          : out   std_logic;
      cnt_steps_o       : out   std_logic_vector(15 downto 0);

      -- drive pins, all active low
      f_density_o       : out   std_logic;
      f_motora_o        : out   std_logic;
      f_selecta_o       : out   std_logic;
      f_side1_o         : out   std_logic;
      f_stepdir_o       : out   std_logic;
      f_step_o          : out   std_logic;
      f_wdata_o         : out   std_logic;
      f_wgate_o         : out   std_logic;
      f_index_i         : in    std_logic;
      f_track0_i        : in    std_logic;
      f_writeprotect_i  : in    std_logic;
      f_rdata_i         : in    std_logic;
      f_diskchanged_i   : in    std_logic
   );
end entity floppy_drive_if;

architecture rtl of floppy_drive_if is

   constant C_DIR_SETUP_CYCLES : natural := 500;  -- 10 us

   signal index_meta, index_sync   : std_logic := '1';
   signal track0_meta, track0_sync : std_logic := '1';
   signal wp_meta, wp_sync         : std_logic := '1';
   signal rdata_meta, rdata_sync   : std_logic := '1';
   signal dskchg_meta, dskchg_sync : std_logic := '1';
   attribute ASYNC_REG : string;
   attribute ASYNC_REG of index_meta  : signal is "TRUE";
   attribute ASYNC_REG of index_sync  : signal is "TRUE";
   attribute ASYNC_REG of track0_meta : signal is "TRUE";
   attribute ASYNC_REG of track0_sync : signal is "TRUE";
   attribute ASYNC_REG of wp_meta     : signal is "TRUE";
   attribute ASYNC_REG of wp_sync     : signal is "TRUE";
   attribute ASYNC_REG of rdata_meta  : signal is "TRUE";
   attribute ASYNC_REG of rdata_sync  : signal is "TRUE";
   attribute ASYNC_REG of dskchg_meta : signal is "TRUE";
   attribute ASYNC_REG of dskchg_sync : signal is "TRUE";

   signal index_hist    : std_logic_vector(3 downto 0) := (others => '1');
   signal index_low     : std_logic := '0';
   signal index_low_q   : std_logic := '0';
   signal rdata_hist    : std_logic_vector(2 downto 0) := (others => '1');
   signal rdata_low     : std_logic := '0';
   signal rdata_low_q   : std_logic := '0';

   signal step_timer    : natural range 0 to G_STEP_RATE_CYCLES := 0;
   signal dir_timer     : natural range 0 to C_DIR_SETUP_CYCLES := 0;
   signal stepdir_q     : std_logic := '1';
   signal step_n        : std_logic := '1';
   signal cnt_steps     : unsigned(15 downto 0) := (others => '0');

begin

   f_selecta_o <= not select_i;
   f_motora_o  <= not motor_i;
   f_side1_o   <= not side1_i;
   f_density_o <= density_i;
   f_stepdir_o <= stepdir_out_i;
   f_step_o    <= step_n;
   f_wdata_o   <= '1';                       -- never (read path only)
   f_wgate_o   <= '1';

   p_sync : process (clk_i)
   begin
      if rising_edge(clk_i) then
         index_meta  <= f_index_i;        index_sync  <= index_meta;
         track0_meta <= f_track0_i;       track0_sync <= track0_meta;
         wp_meta     <= f_writeprotect_i; wp_sync     <= wp_meta;
         rdata_meta  <= f_rdata_i;        rdata_sync  <= rdata_meta;
         dskchg_meta <= f_diskchanged_i;  dskchg_sync <= dskchg_meta;

         -- INDEX: low for four samples (80 ns) = asserted; falling edge = one pulse
         index_hist  <= index_hist(2 downto 0) & index_sync;
         if index_hist = "0000" then
            index_low <= '1';
         elsif index_hist = "1111" then
            index_low <= '0';
         end if;
         index_low_q  <= index_low;
         index_edge_o <= index_low and not index_low_q;

         -- RDATA: low for three samples (60 ns) = a flux transition
         rdata_hist  <= rdata_hist(1 downto 0) & rdata_sync;
         if rdata_hist = "000" then
            rdata_low <= '1';
         else
            rdata_low <= '0';
         end if;
         rdata_low_q <= rdata_low;
         flux_edge_o <= rdata_low and not rdata_low_q;

         track0_o <= not track0_sync;
         wp_o     <= not wp_sync;
         dskchg_o <= not dskchg_sync;
      end if;
   end process p_sync;

   -- DIR set-up: no pulse within C_DIR_SETUP_CYCLES of a direction change (the interface asks for 1 us
   -- before the pulse; the drive acts on the trailing edge, 12 us later still)
   step_ready_o <= '1' when step_timer = 0 and dir_timer = 0 and stepdir_out_i = stepdir_q else '0';
   cnt_steps_o  <= std_logic_vector(cnt_steps);

   p_step : process (clk_i)
   begin
      if rising_edge(clk_i) then
         stepdir_q <= stepdir_out_i;
         if stepdir_out_i /= stepdir_q then
            dir_timer <= C_DIR_SETUP_CYCLES;
         elsif dir_timer /= 0 then
            dir_timer <= dir_timer - 1;
         end if;

         if step_go_i = '1' and step_timer = 0 and dir_timer = 0 and stepdir_out_i = stepdir_q then
            step_timer <= G_STEP_RATE_CYCLES;
            step_n     <= '0';
            cnt_steps  <= cnt_steps + 1;
         elsif step_timer /= 0 then
            step_timer <= step_timer - 1;
            if step_timer = G_STEP_RATE_CYCLES - G_STEP_PULSE_CYCLES then
               step_n <= '1';
            end if;
         end if;
         if rst_i = '1' then
            step_timer <= 0;
            dir_timer  <= 0;
            step_n     <= '1';
            cnt_steps  <= (others => '0');
         end if;
      end if;
   end process p_step;

end architecture rtl;
