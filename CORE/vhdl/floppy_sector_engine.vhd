-------------------------------------------------------------------------------------------------------------
-- floppy_sector_engine: the read path from the MEGA65 R6 internal 3.5" drive to the DOS-facing FDC
--
-- Phase 2 of docs/floppy.md. The emulated FDC (CORE/rtl/overlay/floppy.v, untouched) asks the framework for
-- 512-byte blocks by LBA; when "Drive A: internal drive" is on, the QNICE firmware (CORE/m2m-rom/flpdrv.asm)
-- turns each request for vdrive 0 into C/H/R and drives this engine through the registers in
-- rom_loader.vhd (4k window 0xFFFD of the PCXT ROM device). The engine sits on the drive pins through
-- floppy_drive_if.vhd and reads MFM through floppy_mfm_reader.vhd, both shared with the bring-up spike.
--
-- It is a track-cache engine rather than a single-sector reader: a READ_TRACK command seeks and then
-- captures every sector of the track whose ID header (C, H, N = 2, 1 <= R <= 18) matches, CRC-checked, into
-- an 18 x 512-byte block RAM slot per R, for one full revolution (G_CAP_INDEX index edges) or until all
-- sectors 1..spt are in. The next requests for the same track cost nothing: the firmware only asks for a
-- COPY, which streams slot R into the framework's block buffer (vd_glue.vhd port B, 512 clocks) - so DOS
-- reading a track sequentially never waits for a revolution per sector, which a sector-at-a-time design
-- would, because the firmware's turnaround (~1.4 ms) is about the inter-sector gap at 500 kbit/s.
--
-- Commands (cmd_valid_i one clock, arguments stable from then on; busy_o high until done; results hold
-- until the next command):
--   1 DETECT      motor on (spin-up), recalibrate, read at 500 kbit/s for G_DET_INDEX index edges, then at
--                 250 kbit/s: det_hd_o / det_dd_o say which rate produced good ID headers, det_max_r_o the
--                 largest sector number seen (18 = 1.44 MB, 9 = 720 KB). Clears the cache.
--   2 READ_TRACK  cyl / head / rate_hd; if the cache already holds this track (same cyl, head, rate) with
--                 sector `sector` valid and force = 0: done at once, no motor. Otherwise motor on,
--                 recalibrate if the head position is not known (first use, after a seek error, or
--                 force = 1), seek, settle, capture as above. valid_o / crcerr_o report the slots.
--   3 COPY        slot `sector` (1..18) -> buf_*_o, 512 bytes.
--   4 PROBE       one step in and one out, no motor: a step with a disk in clears the drive's DISK CHANGE
--                 latch, so dskchg_live_o afterwards says whether a disk is in (the firmware polls this
--                 every 2 s while the FDC is told "no media").
--   5 MOTOR_OFF   motor off now (the motor otherwise stops G_MOTOR_OFF_CYCLES after the last command).
-- err_o: 0 OK, 1 no index pulse for G_INDEX_TIMEOUT_CYCLES (no disk / motor), 2 recalibrate found no
-- TRACK0 within G_MAX_STEPS_HOME steps, 3 no good ID header at all (wrong rate, unformatted, no disk),
-- 4 headers seen but none of this track (seek error: the next READ_TRACK recalibrates), 5 bad argument,
-- 6 engine disabled.
-- enable_i (level): drive selected, motor allowed. While '0' every output is inactive and the cache is
-- dropped. A rising edge on DISK CHANGE sets dskchg_o (sticky) and drops the cache; chg_clr_i clears it.
-- wp_o is the live write-protect line. The DENSITY pin follows the rate through G_DENSITY_HD / _DD
-- (polarity unproven, docs/floppy.md).
--
-- MEGA65 port done by silent-command in 2026 and licensed under GPL v3
-- MiSTer2MEGA65 done by sy2002 and MJoergen in 2022 and licensed under GPL v3
-------------------------------------------------------------------------------------------------------------

library ieee;
   use ieee.std_logic_1164.all;
   use ieee.numeric_std.all;

library xpm;
   use xpm.vcomponents.all;

entity floppy_sector_engine is
   generic (
      G_SPINUP_CYCLES        : natural   := 25_000_000;   -- motor on to first use: 500 ms at 50 MHz
      G_STEP_PULSE_CYCLES    : natural   := 600;          -- STEP low time: 12 us
      G_STEP_RATE_CYCLES     : natural   := 150_000;      -- step to step: 3 ms
      G_SETTLE_CYCLES        : natural   := 750_000;      -- last step to read: 15 ms
      G_SIDE_SETTLE_CYCLES   : natural   := 5_000;        -- head switch without a seek: 100 us
      G_INDEX_TIMEOUT_CYCLES : natural   := 50_000_000;   -- no index for 1 s: no disk
      G_MOTOR_OFF_CYCLES     : natural   := 100_000_000;  -- motor off 2 s after the last command
      G_MAX_STEPS_HOME       : natural   := 85;           -- recalibrate step limit
      G_MAX_TRACK            : natural   := 82;           -- highest cylinder accepted
      G_DET_INDEX            : natural   := 2;            -- index edges per detect phase (>= 1 revolution)
      G_CAP_INDEX            : natural   := 2;            -- index edges per track capture (>= 1 revolution)
      G_HD_HALF_CELL         : natural   := 50;
      G_DD_HALF_CELL         : natural   := 100;
      G_DENSITY_HD           : std_logic := '1';
      G_DENSITY_DD           : std_logic := '0'
   );
   port (
      clk_i             : in    std_logic;                -- 50.000 MHz
      rst_i             : in    std_logic;

      -- command interface
      enable_i          : in    std_logic;
      chg_clr_i         : in    std_logic;                -- pulse: clear dskchg_o
      cmd_valid_i       : in    std_logic;                -- pulse
      cmd_i             : in    std_logic_vector(3 downto 0);
      cmd_cyl_i         : in    std_logic_vector(7 downto 0);
      cmd_head_i        : in    std_logic;
      cmd_rate_hd_i     : in    std_logic;
      cmd_force_i       : in    std_logic;                -- recalibrate first, re-read even if cached
      cmd_sector_i      : in    std_logic_vector(4 downto 0);   -- R for COPY / the cache-hit test
      cmd_spt_i         : in    std_logic_vector(4 downto 0);   -- sectors per track for the early exit (0 = none)

      -- results (hold from busy_o falling until the next command)
      busy_o            : out   std_logic;
      err_o             : out   std_logic_vector(7 downto 0);
      det_max_r_o       : out   std_logic_vector(7 downto 0);
      det_hd_o          : out   std_logic;
      det_dd_o          : out   std_logic;
      valid_o           : out   std_logic_vector(17 downto 0);  -- bit 0 = sector 1
      crcerr_o          : out   std_logic_vector(17 downto 0);
      cache_cyl_o       : out   std_logic_vector(7 downto 0);
      cache_head_o      : out   std_logic;
      cache_rate_o      : out   std_logic;
      head_track_o      : out   std_logic_vector(7 downto 0);
      state_o           : out   std_logic_vector(7 downto 0);

      -- live flags
      cache_valid_o     : out   std_logic;
      wp_o              : out   std_logic;
      dskchg_o          : out   std_logic;                -- sticky
      dskchg_live_o     : out   std_logic;
      track0_o          : out   std_logic;
      motor_o           : out   std_logic;
      index_seen_o      : out   std_logic;                -- during the last command

      -- debug counters
      cnt_index_o       : out   std_logic_vector(15 downto 0);
      cnt_idam_ok_o     : out   std_logic_vector(15 downto 0);
      cnt_dam_ok_o      : out   std_logic_vector(15 downto 0);
      cnt_steps_o       : out   std_logic_vector(15 downto 0);
      last_chrn_o       : out   std_logic_vector(31 downto 0);

      -- COPY: slot -> the framework's block buffer (vd_glue port B)
      buf_addr_o        : out   std_logic_vector(8 downto 0);
      buf_data_o        : out   std_logic_vector(7 downto 0);
      buf_we_o          : out   std_logic;

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
end entity floppy_sector_engine;

architecture rtl of floppy_sector_engine is

   constant C_CMD_DETECT   : std_logic_vector(3 downto 0) := x"1";
   constant C_CMD_READ     : std_logic_vector(3 downto 0) := x"2";
   constant C_CMD_COPY     : std_logic_vector(3 downto 0) := x"3";
   constant C_CMD_PROBE    : std_logic_vector(3 downto 0) := x"4";
   constant C_CMD_MOTOROFF : std_logic_vector(3 downto 0) := x"5";

   constant C_E_OK         : std_logic_vector(7 downto 0) := x"00";
   constant C_E_NO_INDEX   : std_logic_vector(7 downto 0) := x"01";
   constant C_E_RECAL      : std_logic_vector(7 downto 0) := x"02";
   constant C_E_NO_IDAM    : std_logic_vector(7 downto 0) := x"03";
   constant C_E_WRONG_TRK  : std_logic_vector(7 downto 0) := x"04";
   constant C_E_BAD_ARG    : std_logic_vector(7 downto 0) := x"05";
   constant C_E_DISABLED   : std_logic_vector(7 downto 0) := x"06";

   function max_nat (a, b : natural) return natural is
   begin
      if a > b then return a; else return b; end if;
   end function max_nat;

   constant C_TIMER_MAX : natural := max_nat(max_nat(G_SPINUP_CYCLES, G_INDEX_TIMEOUT_CYCLES),
                                             max_nat(G_MOTOR_OFF_CYCLES, G_SETTLE_CYCLES));

   ---------------------------------------------------------------------------------------------
   -- drive interface and reader
   ---------------------------------------------------------------------------------------------
   signal index_edge    : std_logic;
   signal flux_edge     : std_logic;
   signal track0_n      : std_logic;
   signal wp_n          : std_logic;
   signal dskchg_n      : std_logic;
   signal dskchg_q      : std_logic := '0';
   signal step_ready    : std_logic;
   signal motor_on      : std_logic := '0';
   signal spun_up       : std_logic := '0';
   signal side1         : std_logic := '0';
   signal rate_hd       : std_logic := '0';
   signal density       : std_logic;
   signal stepdir_out   : std_logic := '1';
   signal step_go       : std_logic := '0';
   signal dec_reset     : std_logic := '0';

   signal idam          : std_logic;
   signal idam_ok       : std_logic;
   signal id_c, id_h, id_r, id_n : std_logic_vector(7 downto 0);
   signal dam           : std_logic;
   signal data_valid    : std_logic;
   signal data_byte     : std_logic_vector(7 downto 0);
   signal dam_end       : std_logic;
   signal dam_ok        : std_logic;

   ---------------------------------------------------------------------------------------------
   -- sequencer
   ---------------------------------------------------------------------------------------------
   type t_seq is (S_IDLE, S_MOTOR, S_HOME_IN, S_HOME_OUT, S_HOME_SETTLE, S_DET_HD, S_DET_DD,
                  S_SEEK, S_SEEK_SETTLE, S_CAPTURE, S_COPY, S_PROBE_IN, S_PROBE_OUT, S_PROBE_WAIT,
                  S_DONE);
   signal seq           : t_seq := S_IDLE;
   signal timer         : natural range 0 to C_TIMER_MAX := 0;
   signal cmd           : std_logic_vector(3 downto 0) := (others => '0');
   signal a_cyl         : unsigned(7 downto 0) := (others => '0');
   signal a_head        : std_logic := '0';
   signal a_rate        : std_logic := '0';
   signal a_force       : std_logic := '0';
   signal a_sector      : unsigned(4 downto 0) := (others => '0');
   signal a_spt         : unsigned(4 downto 0) := (others => '0');
   signal steps_left    : natural range 0 to 255 := 0;
   signal stepped       : std_logic := '0';
   signal head_track    : unsigned(7 downto 0) := (others => '0');
   signal homed         : std_logic := '0';
   signal err           : std_logic_vector(7 downto 0) := (others => '0');
   signal idx_cnt       : natural range 0 to 15 := 0;
   signal index_seen    : std_logic := '0';
   signal saw_idam      : std_logic := '0';
   signal saw_match     : std_logic := '0';
   signal det_hd        : std_logic := '0';
   signal det_dd        : std_logic := '0';
   signal det_max_r     : unsigned(7 downto 0) := (others => '0');
   signal phase_ok      : std_logic := '0';       -- a good IDAM in the current detect phase
   signal motor_timer   : natural range 0 to C_TIMER_MAX := 0;
   signal dskchg_sticky : std_logic := '0';

   -- cache
   signal cache_valid   : std_logic := '0';
   signal cache_cyl     : unsigned(7 downto 0) := (others => '0');
   signal cache_head    : std_logic := '0';
   signal cache_rate    : std_logic := '0';
   signal valid         : std_logic_vector(17 downto 0) := (others => '0');
   signal crcerr        : std_logic_vector(17 downto 0) := (others => '0');
   signal spt_mask      : std_logic_vector(17 downto 0);
   signal armed         : std_logic := '0';
   signal capturing     : std_logic := '0';
   signal cap_slot      : unsigned(4 downto 0) := (others => '0');
   signal cap_idx       : unsigned(8 downto 0) := (others => '0');
   signal wr_addr       : std_logic_vector(13 downto 0) := (others => '0');
   signal wr_data       : std_logic_vector(7 downto 0) := (others => '0');
   signal wr_en         : std_logic_vector(0 downto 0) := "0";
   signal rd_addr       : std_logic_vector(13 downto 0);
   signal rd_data       : std_logic_vector(7 downto 0);
   signal copy_i        : unsigned(9 downto 0) := (others => '0');   -- 0..512
   signal copy_we1      : std_logic := '0';
   signal copy_addr1    : unsigned(8 downto 0) := (others => '0');

   -- counters
   signal cnt_index     : unsigned(15 downto 0) := (others => '0');
   signal cnt_idam_ok   : unsigned(15 downto 0) := (others => '0');
   signal cnt_dam_ok    : unsigned(15 downto 0) := (others => '0');
   signal last_chrn     : std_logic_vector(31 downto 0) := (others => '0');

   signal hit           : std_logic;              -- READ_TRACK cache hit
   signal cmd_slot      : natural range 0 to 17;  -- cmd_sector_i - 1, clamped
   signal cmd_sec_ok    : std_logic;              -- cmd_sector_i in 1..18
   signal rd_slot       : unsigned(4 downto 0);   -- a_sector - 1, clamped
   signal cap_done      : std_logic;              -- every sector 1..spt captured

begin

   ---------------------------------------------------------------------------------------------
   -- pins, reader
   ---------------------------------------------------------------------------------------------
   density <= G_DENSITY_HD when rate_hd = '1' else G_DENSITY_DD;

   i_drive : entity work.floppy_drive_if
      generic map (
         G_STEP_PULSE_CYCLES => G_STEP_PULSE_CYCLES,
         G_STEP_RATE_CYCLES  => G_STEP_RATE_CYCLES
      )
      port map (
         clk_i            => clk_i,
         rst_i            => rst_i,
         select_i         => enable_i,
         motor_i          => motor_on,
         side1_i          => side1,
         density_i        => density,
         stepdir_out_i    => stepdir_out,
         step_go_i        => step_go,
         step_ready_o     => step_ready,
         index_edge_o     => index_edge,
         flux_edge_o      => flux_edge,
         track0_o         => track0_n,
         wp_o             => wp_n,
         dskchg_o         => dskchg_n,
         cnt_steps_o      => cnt_steps_o,
         f_density_o      => f_density_o,
         f_motora_o       => f_motora_o,
         f_selecta_o      => f_selecta_o,
         f_side1_o        => f_side1_o,
         f_stepdir_o      => f_stepdir_o,
         f_step_o         => f_step_o,
         f_wdata_o        => f_wdata_o,
         f_wgate_o        => f_wgate_o,
         f_index_i        => f_index_i,
         f_track0_i       => f_track0_i,
         f_writeprotect_i => f_writeprotect_i,
         f_rdata_i        => f_rdata_i,
         f_diskchanged_i  => f_diskchanged_i
      );

   i_reader : entity work.floppy_mfm_reader
      generic map (
         G_HD_HALF_CELL => G_HD_HALF_CELL,
         G_DD_HALF_CELL => G_DD_HALF_CELL
      )
      port map (
         clk_i        => clk_i,
         rst_i        => rst_i,
         reset_i      => dec_reset,
         rate_hd_i    => rate_hd,
         flux_edge_i  => flux_edge,
         sync_mark_o  => open,
         byte_valid_o => open,
         byte_o       => open,
         gap_len_o    => open,
         idam_o       => idam,
         idam_ok_o    => idam_ok,
         id_c_o       => id_c,
         id_h_o       => id_h,
         id_r_o       => id_r,
         id_n_o       => id_n,
         dam_o        => dam,
         data_valid_o => data_valid,
         data_o       => data_byte,
         dam_end_o    => dam_end,
         dam_ok_o     => dam_ok
      );

   ---------------------------------------------------------------------------------------------
   -- track cache: 18 slots x 512 bytes, written by the capture, read by COPY
   ---------------------------------------------------------------------------------------------
   i_cache : xpm_memory_sdpram
      generic map (
         MEMORY_SIZE        => 18 * 512 * 8,
         MEMORY_PRIMITIVE   => "block",
         CLOCKING_MODE      => "common_clock",
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
         BYTE_WRITE_WIDTH_A => 8,
         ADDR_WIDTH_A       => 14,
         READ_DATA_WIDTH_B  => 8,
         ADDR_WIDTH_B       => 14,
         READ_RESET_VALUE_B => "0",
         READ_LATENCY_B     => 1,
         WRITE_MODE_B       => "read_first"
      )
      port map (
         sleep          => '0',
         clka           => clk_i,
         ena            => '1',
         wea            => wr_en,
         addra          => wr_addr,
         dina           => wr_data,
         injectsbiterra => '0',
         injectdbiterra => '0',
         clkb           => clk_i,
         rstb           => '0',
         enb            => '1',
         regceb         => '1',
         addrb          => rd_addr,
         doutb          => rd_data,
         sbiterrb       => open,
         dbiterrb       => open
      );

   rd_slot <= a_sector - 1 when a_sector >= 1 and a_sector <= 18 else (others => '0');
   rd_addr <= std_logic_vector(rd_slot) & std_logic_vector(copy_i(8 downto 0));

   -- capture write port: one byte per data_valid while a matching data field is being captured
   p_capture_wr : process (clk_i)
   begin
      if rising_edge(clk_i) then
         wr_en(0) <= data_valid and capturing;
         wr_addr  <= std_logic_vector(cap_slot) & std_logic_vector(cap_idx);
         wr_data  <= data_byte;
         if data_valid = '1' and capturing = '1' then
            cap_idx <= cap_idx + 1;
         end if;
         if dam = '1' then
            cap_idx <= (others => '0');
         end if;
      end if;
   end process p_capture_wr;

   -- COPY read pipeline: address (copy_i) -> BRAM (1) -> registered output (2)
   p_copy : process (clk_i)
   begin
      if rising_edge(clk_i) then
         copy_we1   <= '1' when (seq = S_COPY and copy_i < 512) else '0';
         copy_addr1 <= copy_i(8 downto 0);
         buf_we_o   <= copy_we1;
         buf_addr_o <= std_logic_vector(copy_addr1);
         buf_data_o <= rd_data;
      end if;
   end process p_copy;

   g_mask : for i in 0 to 17 generate
      spt_mask(i) <= '1' when a_spt > i else '0';
   end generate g_mask;
   cap_done <= '1' when a_spt /= 0 and a_spt <= 18 and (valid or not spt_mask) = (17 downto 0 => '1') else '0';

   cmd_sec_ok <= '1' when unsigned(cmd_sector_i) >= 1 and unsigned(cmd_sector_i) <= 18 else '0';
   cmd_slot   <= to_integer(unsigned(cmd_sector_i)) - 1 when cmd_sec_ok = '1' else 0;
   hit <= '1' when cache_valid = '1' and cache_cyl = unsigned(cmd_cyl_i) and cache_head = cmd_head_i and
                   cache_rate = cmd_rate_hd_i and cmd_force_i = '0' and cmd_sec_ok = '1' and
                   valid(cmd_slot) = '1' else '0';

   ---------------------------------------------------------------------------------------------
   -- sequencer
   ---------------------------------------------------------------------------------------------
   p_seq : process (clk_i)
      variable v_r     : integer range 0 to 255;
      variable v_match : boolean;
   begin
      if rising_edge(clk_i) then
         step_go   <= '0';
         dec_reset <= '0';

         -- drive status bookkeeping
         dskchg_q <= dskchg_n;
         if dskchg_n = '1' and dskchg_q = '0' then
            dskchg_sticky <= '1';
            cache_valid   <= '0';
         end if;
         if chg_clr_i = '1' then
            dskchg_sticky <= '0';
         end if;
         if index_edge = '1' then
            cnt_index <= cnt_index + 1;
            if seq /= S_IDLE then
               index_seen <= '1';
            end if;
         end if;
         if idam = '1' and idam_ok = '1' then
            cnt_idam_ok <= cnt_idam_ok + 1;
            last_chrn   <= id_c & id_h & id_r & id_n;
         end if;
         if dam_end = '1' and dam_ok = '1' then
            cnt_dam_ok <= cnt_dam_ok + 1;
         end if;

         -- motor-off timer (runs while idle)
         if seq = S_IDLE and motor_on = '1' then
            if motor_timer = G_MOTOR_OFF_CYCLES - 1 then
               motor_on <= '0';
               spun_up  <= '0';
            else
               motor_timer <= motor_timer + 1;
            end if;
         else
            motor_timer <= 0;
         end if;

         -- capture: arm on a matching ID header, take the data field that follows it
         if seq = S_CAPTURE then
            if idam = '1' then
               v_r     := to_integer(unsigned(id_r));
               v_match := idam_ok = '1' and unsigned(id_c) = a_cyl and id_h(0) = a_head and
                          id_h(7 downto 1) = "0000000" and id_n = x"02" and v_r >= 1 and v_r <= 18;
               armed <= '0';
               if idam_ok = '1' then
                  saw_idam <= '1';
               end if;
               if v_match then
                  saw_match <= '1';
                  if valid(v_r - 1) = '0' then
                     armed    <= '1';
                     cap_slot <= to_unsigned(v_r - 1, 5);
                  end if;
               end if;
            end if;
            if dam = '1' then
               capturing <= armed;
               armed     <= '0';
            end if;
            if dam_end = '1' and capturing = '1' then
               capturing <= '0';
               if dam_ok = '1' then
                  valid(to_integer(cap_slot))  <= '1';
                  crcerr(to_integer(cap_slot)) <= '0';
               else
                  crcerr(to_integer(cap_slot)) <= '1';
               end if;
            end if;
         else
            armed     <= '0';
            capturing <= '0';
         end if;

         -- detect phases: any good ID header counts, the largest R is remembered
         if (seq = S_DET_HD or seq = S_DET_DD) and idam = '1' and idam_ok = '1' then
            phase_ok <= '1';
            if unsigned(id_r) > det_max_r then
               det_max_r <= unsigned(id_r);
            end if;
         end if;

         case seq is
            when S_IDLE =>
               if cmd_valid_i = '1' then
                  cmd        <= cmd_i;
                  a_cyl      <= unsigned(cmd_cyl_i);
                  a_head     <= cmd_head_i;
                  a_rate     <= cmd_rate_hd_i;
                  a_force    <= cmd_force_i;
                  a_sector   <= unsigned(cmd_sector_i);
                  a_spt      <= unsigned(cmd_spt_i);
                  err        <= C_E_OK;
                  index_seen <= '0';
                  stepped    <= '0';
                  timer      <= 0;
                  seq        <= S_DONE;
                  if enable_i = '0' then
                     err <= C_E_DISABLED;
                  elsif cmd_i = C_CMD_DETECT then
                     det_hd      <= '0';
                     det_dd      <= '0';
                     det_max_r   <= (others => '0');
                     cache_valid <= '0';
                     seq         <= S_MOTOR;
                  elsif cmd_i = C_CMD_READ then
                     if unsigned(cmd_cyl_i) > G_MAX_TRACK then
                        err <= C_E_BAD_ARG;
                     elsif hit = '1' then
                        null;                                         -- served from the cache
                     else
                        seq <= S_MOTOR;
                     end if;
                  elsif cmd_i = C_CMD_COPY then
                     if unsigned(cmd_sector_i) < 1 or unsigned(cmd_sector_i) > 18 then
                        err <= C_E_BAD_ARG;
                     else
                        copy_i <= (others => '0');
                        seq    <= S_COPY;
                     end if;
                  elsif cmd_i = C_CMD_PROBE then
                     stepdir_out <= '0';
                     seq         <= S_PROBE_IN;
                  elsif cmd_i = C_CMD_MOTOROFF then
                     motor_on <= '0';
                     spun_up  <= '0';
                  else
                     err <= C_E_BAD_ARG;
                  end if;
               end if;

            when S_MOTOR =>
               motor_on <= '1';
               if spun_up = '1' then
                  timer <= 0;
                  if cmd = C_CMD_DETECT or homed = '0' or a_force = '1' then
                     if track0_n = '1' then
                        seq         <= S_HOME_IN;                     -- one step in first
                        stepdir_out <= '0';
                        steps_left  <= 1;
                     else
                        seq         <= S_HOME_OUT;
                        stepdir_out <= '1';
                        steps_left  <= G_MAX_STEPS_HOME;
                     end if;
                  else
                     seq <= S_SEEK;
                  end if;
               elsif timer = G_SPINUP_CYCLES - 1 then
                  spun_up <= '1';
               else
                  timer <= timer + 1;
               end if;

            when S_HOME_IN =>
               if step_ready = '1' and step_go = '0' then
                  if steps_left = 0 then
                     seq         <= S_HOME_OUT;
                     stepdir_out <= '1';
                     steps_left  <= G_MAX_STEPS_HOME;
                  else
                     step_go     <= '1';
                     cache_valid <= '0';
                     steps_left  <= steps_left - 1;
                  end if;
               end if;

            when S_HOME_OUT =>
               if step_ready = '1' and step_go = '0' then
                  if track0_n = '1' then
                     homed      <= '1';
                     head_track <= (others => '0');
                     seq        <= S_HOME_SETTLE;
                     timer      <= 0;
                  elsif steps_left = 0 then
                     homed <= '0';
                     err   <= C_E_RECAL;
                     seq   <= S_HOME_SETTLE;
                     timer <= 0;
                  else
                     step_go     <= '1';
                     cache_valid <= '0';
                     steps_left  <= steps_left - 1;
                  end if;
               end if;

            when S_HOME_SETTLE =>
               if timer = G_SETTLE_CYCLES - 1 then
                  timer <= 0;
                  if cmd = C_CMD_DETECT then
                     seq       <= S_DET_HD;
                     side1     <= '0';
                     rate_hd   <= '1';
                     dec_reset <= '1';
                     idx_cnt   <= 0;
                     phase_ok  <= '0';
                  elsif err = C_E_RECAL then
                     seq <= S_DONE;
                  else
                     seq <= S_SEEK;
                  end if;
               else
                  timer <= timer + 1;
               end if;

            when S_DET_HD | S_DET_DD =>
               if index_edge = '1' then
                  timer <= 0;
                  if idx_cnt + 1 >= G_DET_INDEX then
                     idx_cnt <= 0;
                     if seq = S_DET_HD then
                        det_hd    <= phase_ok;
                        seq       <= S_DET_DD;
                        rate_hd   <= '0';
                        dec_reset <= '1';
                        phase_ok  <= '0';
                     else
                        det_dd <= phase_ok;
                        seq    <= S_DONE;
                     end if;
                  else
                     idx_cnt <= idx_cnt + 1;
                  end if;
               elsif timer = G_INDEX_TIMEOUT_CYCLES - 1 then
                  timer <= 0;
                  if err = C_E_OK then
                     err <= C_E_NO_INDEX;
                  end if;
                  if seq = S_DET_HD then
                     seq       <= S_DET_DD;
                     rate_hd   <= '0';
                     dec_reset <= '1';
                     phase_ok  <= '0';
                     idx_cnt   <= 0;
                  else
                     seq <= S_DONE;
                  end if;
               else
                  timer <= timer + 1;
               end if;

            when S_SEEK =>
               if step_ready = '1' and step_go = '0' then
                  if head_track = a_cyl then
                     seq   <= S_SEEK_SETTLE;
                     timer <= 0;
                  elsif head_track < a_cyl then
                     stepdir_out <= '0';
                     if stepdir_out = '0' then
                        step_go     <= '1';
                        stepped     <= '1';
                        cache_valid <= '0';
                        head_track  <= head_track + 1;
                     end if;
                  else
                     stepdir_out <= '1';
                     if stepdir_out = '1' then
                        step_go     <= '1';
                        stepped     <= '1';
                        cache_valid <= '0';
                        head_track  <= head_track - 1;
                     end if;
                  end if;
               end if;

            when S_SEEK_SETTLE =>
               side1   <= a_head;
               rate_hd <= a_rate;
               if (stepped = '1' and timer = G_SETTLE_CYCLES - 1) or
                  (stepped = '0' and timer = G_SIDE_SETTLE_CYCLES - 1) then
                  timer     <= 0;
                  seq       <= S_CAPTURE;
                  dec_reset <= '1';
                  idx_cnt   <= 0;
                  saw_idam  <= '0';
                  saw_match <= '0';
                  if cache_valid = '0' or cache_cyl /= a_cyl or cache_head /= a_head or
                     cache_rate /= a_rate or a_force = '1' then
                     valid  <= (others => '0');
                     crcerr <= (others => '0');
                  end if;
                  cache_valid <= '1';
                  cache_cyl   <= a_cyl;
                  cache_head  <= a_head;
                  cache_rate  <= a_rate;
               else
                  timer <= timer + 1;
               end if;

            when S_CAPTURE =>
               if index_edge = '1' then
                  timer <= 0;
                  if idx_cnt + 1 >= G_CAP_INDEX then
                     seq <= S_DONE;
                  else
                     idx_cnt <= idx_cnt + 1;
                  end if;
               elsif cap_done = '1' and capturing = '0' then
                  seq <= S_DONE;
               elsif timer = G_INDEX_TIMEOUT_CYCLES - 1 then
                  err <= C_E_NO_INDEX;
                  seq <= S_DONE;
               else
                  timer <= timer + 1;
               end if;
               if seq = S_CAPTURE and (index_edge = '1' and idx_cnt + 1 >= G_CAP_INDEX) then
                  if saw_match = '0' then
                     if saw_idam = '1' then
                        err   <= C_E_WRONG_TRK;
                        homed <= '0';                                 -- the head is not where we think
                     else
                        err <= C_E_NO_IDAM;
                     end if;
                     cache_valid <= '0';
                  end if;
               end if;

            when S_COPY =>
               if copy_i = 512 + 2 then                              -- pipeline drained
                  seq <= S_DONE;
               else
                  copy_i <= copy_i + 1;
               end if;

            when S_PROBE_IN =>
               if step_ready = '1' and step_go = '0' then
                  step_go     <= '1';
                  cache_valid <= '0';
                  seq         <= S_PROBE_OUT;
               end if;

            when S_PROBE_OUT =>
               -- the direction changes only once the step engine is ready again (the drive samples DIR
               -- at the trailing edge of STEP, so DIR must hold through the pulse), and in its own
               -- cycle: a step requested together with a DIR change is not honoured
               if step_ready = '1' and step_go = '0' then
                  if stepdir_out = '0' then
                     stepdir_out <= '1';
                  else
                     step_go <= '1';
                     seq     <= S_PROBE_WAIT;
                  end if;
               end if;

            when S_PROBE_WAIT =>
               if step_ready = '1' and step_go = '0' then
                  seq <= S_DONE;
               end if;

            when S_DONE =>
               seq <= S_IDLE;
         end case;

         if enable_i = '0' then
            motor_on    <= '0';
            spun_up     <= '0';
            cache_valid <= '0';
            homed       <= '0';
         end if;

         if rst_i = '1' then
            seq           <= S_IDLE;
            timer         <= 0;
            motor_on      <= '0';
            spun_up       <= '0';
            motor_timer   <= 0;
            stepdir_out   <= '1';
            side1         <= '0';
            rate_hd       <= '0';
            homed         <= '0';
            head_track    <= (others => '0');
            err           <= (others => '0');
            det_hd        <= '0';
            det_dd        <= '0';
            det_max_r     <= (others => '0');
            cache_valid   <= '0';
            valid         <= (others => '0');
            crcerr        <= (others => '0');
            dskchg_sticky <= '0';
            index_seen    <= '0';
            cnt_index     <= (others => '0');
            cnt_idam_ok   <= (others => '0');
            cnt_dam_ok    <= (others => '0');
            last_chrn     <= (others => '0');
            armed         <= '0';
            capturing     <= '0';
         end if;
      end if;
   end process p_seq;

   ---------------------------------------------------------------------------------------------
   -- outputs
   ---------------------------------------------------------------------------------------------
   busy_o        <= '0' when seq = S_IDLE else '1';
   err_o         <= err;
   det_max_r_o   <= std_logic_vector(det_max_r);
   det_hd_o      <= det_hd;
   det_dd_o      <= det_dd;
   valid_o       <= valid;
   crcerr_o      <= crcerr;
   cache_cyl_o   <= std_logic_vector(cache_cyl);
   cache_head_o  <= cache_head;
   cache_rate_o  <= cache_rate;
   cache_valid_o <= cache_valid;
   head_track_o  <= std_logic_vector(head_track);
   state_o       <= std_logic_vector(to_unsigned(t_seq'pos(seq), 8));
   wp_o          <= wp_n;
   dskchg_o      <= dskchg_sticky;
   dskchg_live_o <= dskchg_n;
   track0_o      <= track0_n;
   motor_o       <= motor_on;
   index_seen_o  <= index_seen;
   cnt_index_o   <= std_logic_vector(cnt_index);
   cnt_idam_ok_o <= std_logic_vector(cnt_idam_ok);
   cnt_dam_ok_o  <= std_logic_vector(cnt_dam_ok);
   last_chrn_o   <= last_chrn;

end architecture rtl;
