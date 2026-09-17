-------------------------------------------------------------------------------------------------------------
-- floppy_phy_spike: MEGA65 R6 internal 3.5" floppy drive bring-up for PCXT-EGA on MiSTer2MEGA65
--
-- Physical-layer spike for the "real floppy" plan of docs/floppy.md, modelled on eth_phy_spike.vhd: bring
-- the drive up, count what it says, report on the serial status line, prove it on the board in one build.
-- The DOS-facing floppy controller (CORE/rtl/overlay/floppy.v, image based) is untouched; a later phase puts
-- a "physical drive" sector source behind it and reuses the reader below.
--
-- What it does, forever, on drive A only (the internal drive; drive B lines are left inactive in the top):
--   1. select the drive (kept selected so that TRACK0 / WPT / DSKCHG can be observed while idle: PC
--      drives only drive their outputs while selected), motor on, wait the spin-up time (500 ms);
--   2. recalibrate: if TRACK0 is already asserted step in once (a step with a disk present is what clears
--      the drive's latched DISK CHANGE), then step out until TRACK0 asserts, at most G_MAX_STEPS_HOME
--      steps (seek_ok records whether it did), settle;
--   3. read for G_INDEX_PULSES index pulses at 500 kbit/s (HD), then the same at 250 kbit/s (DD); a phase
--      also ends when no index pulse arrives for G_INDEX_TIMEOUT_CYCLES (no disk, motor not turning);
--   4. seek to track G_TEST_TRACK, read for G_INDEX_PULSES at whichever rate produced good ID headers in
--      step 3 (DD if neither did), seek back to track 0;
--   5. motor off, wait G_REPEAT_CYCLES, or less if the DISK CHANGE line changes state, then run again.
-- WRITE GATE and WRITE DATA are never asserted.
--
-- Drive interface (Shugart / PC 34-pin, every signal active low; M2M/MEGA65-R6.xdc:255-269,
-- M2M/vhdl/top_mega65-r6.vhd:191-205). Polarities and timing follow mega65-core, which drives this exact
-- mechanism (github.com/MEGA65/mega65-core master, checked 2026-09-17; sdcardio.vhdl runs at
-- cpu_frequency = 40.5 MHz, mega65r3.vhdl:807):
--   * motor and select are asserted together, low (sdcardio.vhdl:2357-2358 "f_motora <= not ...(5);
--     f_selecta <= not ...(5)"); drive 0 is the A lines (2353-2361).
--   * step: STEP pulled low for 500 cycles = 12.3 us then released (sdcardio.vhdl:2673-2675, 2060-2066
--     "Stepping pulses should be short"); here G_STEP_PULSE_CYCLES = 600 = 12 us. Direction: DIR = '1'
--     steps out towards track 0 (x"10" "head step out": f_stepdir <= '1', :2672-2674), DIR = '0' steps in
--     (x"18": f_stepdir <= '0', :2713-2716). The F011 step rate register defaults to 8 ms (f011_reg_step
--     x"80" in 16 kHz ticks, :460, :2695); PC BIOSes use 3-4 ms for 3.5" drives, so G_STEP_RATE_CYCLES =
--     3 ms with a 15 ms head settle (G_SETTLE_CYCLES) after the last pulse.
--   * spin-up: the F011 "wait for motor spin up" command is 16000 ticks of 16 kHz = 1 s (:2740-2742);
--     the PC BIOS value for 3.5" drives is 500 ms (the FDC's DOR motor-on to first command); 500 ms here.
--   * TRACK0, INDEX, WPT, DSKCHG are low when true (:2109 "f011_write_protected <= not f_writeprotect",
--     :2126-2128 "f011_track0 <= not f_track0; f011_over_index <= not f_index; f011_disk_changed <=
--     (not f_diskchanged) or ..."). mega65-core debounces INDEX over 8 samples (:1867-1877) and filters
--     RDATA over 4 samples (machine.vhdl:885-895: low only when four consecutive samples are low).
--   * DENSITY (pin 2, "F_REDWC" on the R6 schematic name) is only ever written from the $D6A0 debug
--     register in mega65-core (sdcardio.vhdl:3399-3407) and otherwise stays at its default '1' for both
--     DD and HD work (the HD/DD choice there is purely the decoder's cycles_per_interval, :3998-4000).
--     Most 3.5" PC drives sense the media through the HD hole and ignore the pin; the spike drives it
--     G_DENSITY_HD / G_DENSITY_DD per read phase so that the board can tell whether it matters.
--   * The inputs are asynchronous to everything: two-flop synchronisers (ASYNC_REG) and false paths in
--     CORE/CORE.xdc. No pull-ups in either XDC (the drive has its own).
--
-- MFM reader (clk_i = 50.000 MHz, CORE/vhdl/clk.vhd MMCM B CLKOUT1):
--   * RDATA is a short low pulse per flux transition. It is synchronised, filtered like machine.vhdl:892-895
--     (three consecutive low samples = 60 ns) and its falling edge (mfm_gaps.vhdl:60 "last_rdata='0' and
--     last_last_rdata='1'") is the flux event. The gap between events is measured in clock cycles
--     (mfm_gaps.vhdl:73-79).
--   * Rates: 500 kbit/s HD = 2 us bit cell = 1 us half cell = 50 cycles; 250 kbit/s DD = 4 us bit cell =
--     2 us half cell = 100 cycles. mega65-core's unit is the same half cell ("cycles_per_interval" 40 at HD
--     and 81 at DD for 40.5 MHz, sdcardio.vhdl:3998-4000, 950, 992; default cpu_frequency/500000 :467).
--   * Quantiser = mfm_quantise_gaps.vhdl:39-63 with cycles_per_interval = the half cell hc: a gap is
--     2 half cells (1.0 bit cell) when hc <= gap <= 2.5 hc, 3 (1.5) when <= 3.5 hc, 4 (2.0) when <= 5 hc,
--     otherwise invalid. That is a +-0.5 hc window around each nominal, +-0.5 us at HD, +-1 us at DD, which
--     leaves room for +-3 % spindle speed (0.12 hc on the longest gap) plus the drive's peak shift.
--     No PLL: the same fixed-window classifier reads this drive in mega65-core; a frequency-tracking
--     loop is a possible refinement for the read path (docs/floppy.md).
--   * Each gap of n half cells yields n raw MFM bits (n-1 zeros then a one) into a 16-bit shift register.
--     The sync mark is the raw pattern 0x4489 (A1 with the clock bit between data bits 4 and 5 missing);
--     it violates the MFM clocking rule at every alignment, so it cannot occur in data and it fixes the
--     clock/data phase: the raw bit after it is a clock bit. mfm_gaps_to_bits.vhdl:37 detects the same
--     mark as the gap sequence 2.0, 1.5, 2.0, 1.5 (the four gaps inside 0x4489).
--   * Bytes: data bits at the odd raw positions after the mark. IDAM = the byte FE after the mark(s):
--     C, H, R, N, CRC; DAM = FB (F8 = deleted data): 128 << N bytes, CRC. CRC-16/CCITT, poly 0x1021,
--     preset FFFF, over A1 A1 A1 FE C H R N (resp. A1 A1 A1 FB data...), zero after the two CRC bytes;
--     the C65 routine crc1581.vhdl:92-95 (toggle bits 0, 5, 12) is the same polynomial. The CRC is
--     preset at the first mark of a group and fed every mark, as mfm_decoder.vhdl:380-383 does.
--
-- Status words (rom_loader dbg_a/b/c -> m2m-rom.asm " fidx=", " fchr=", " fst="), stat_clk_i domain, moved
-- by the same toggle handshake as the Ethernet spike:
--   stat_a_o " fidx=": idam_crc_ok[7:0] & index_count[7:0]
--   stat_b_o " fchr=": last good C[7:0] & last good R[7:0]
--   stat_c_o " fst=":  rate_hd, track0_seen, write_protect, disk_changed, seek_ok, motor_on,
--                      dd_found, hd_found, max_R[7:0]
--   rate_hd = the rate of the last good IDAM; hd_found / dd_found = the rate found good IDAMs in step 3
--   of the current or last run; max_R = the largest sector number in a good IDAM of this run (9 = 720 KB,
--   18 = 1.44 MB); track0_seen is sticky since reset; disk_changed / write_protect are the live lines.
-- Everything is also on dbg_* taps in the clk_i domain.
--
-- What only the board can prove: docs/floppy.md.
--
-- MEGA65 port done by silent-command in 2026 and licensed under GPL v3
-- MiSTer2MEGA65 done by sy2002 and MJoergen in 2022 and licensed under GPL v3
-------------------------------------------------------------------------------------------------------------

library ieee;
   use ieee.std_logic_1164.all;
   use ieee.numeric_std.all;

entity floppy_phy_spike is
   generic (
      G_SPINUP_CYCLES        : natural   := 25_000_000;   -- motor on to first step: 500 ms at 50 MHz
      G_STEP_PULSE_CYCLES    : natural   := 600;          -- STEP low time: 12 us (mega65-core 12.3 us)
      G_STEP_RATE_CYCLES     : natural   := 150_000;      -- step to step: 3 ms
      G_SETTLE_CYCLES        : natural   := 750_000;      -- last step to read: 15 ms
      G_INDEX_PULSES         : natural   := 3;            -- revolutions per read phase
      G_INDEX_TIMEOUT_CYCLES : natural   := 50_000_000;   -- no index for 1 s ends a read phase
      G_REPEAT_CYCLES        : natural   := 150_000_000;  -- idle between runs: 3 s
      G_MAX_STEPS_HOME       : natural   := 85;           -- recalibrate step limit (80 tracks + margin)
      G_TEST_TRACK           : natural   := 40;           -- the far track of step 4
      G_HD_HALF_CELL         : natural   := 50;           -- 500 kbit/s: 1 us half cell
      G_DD_HALF_CELL         : natural   := 100;          -- 250 kbit/s: 2 us half cell
      G_DENSITY_HD           : std_logic := '1';          -- DENSITY pin while reading at 500 kbit/s
      G_DENSITY_DD           : std_logic := '0'           -- ... and at 250 kbit/s (polarity unproven)
   );
   port (
      clk_i             : in    std_logic;                -- 50.000 MHz
      rst_i             : in    std_logic;

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
      f_diskchanged_i   : in    std_logic;

      -- status words, stat_clk_i domain
      stat_clk_i        : in    std_logic;
      stat_a_o          : out   std_logic_vector(15 downto 0);
      stat_b_o          : out   std_logic_vector(15 downto 0);
      stat_c_o          : out   std_logic_vector(15 downto 0);

      -- debug taps, clk_i domain
      dbg_index_o       : out   std_logic_vector(15 downto 0);  -- index pulses
      dbg_syncs_o       : out   std_logic_vector(15 downto 0);  -- 0x4489 marks
      dbg_idam_o        : out   std_logic_vector(15 downto 0);  -- FE after a mark
      dbg_idam_ok_o     : out   std_logic_vector(15 downto 0);  -- ... with a good CRC
      dbg_dam_o         : out   std_logic_vector(15 downto 0);  -- FB/F8 after a mark
      dbg_dam_ok_o      : out   std_logic_vector(15 downto 0);  -- ... with a good CRC
      dbg_chrn_o        : out   std_logic_vector(31 downto 0);  -- last good C & H & R & N
      dbg_max_r_o       : out   std_logic_vector(7 downto 0);
      dbg_flags_o       : out   std_logic_vector(7 downto 0);   -- as stat_c_o(15 downto 8)
      dbg_state_o       : out   std_logic_vector(7 downto 0);   -- sequencer state code
      dbg_track_o       : out   std_logic_vector(7 downto 0);   -- head position by step count
      dbg_runs_o        : out   std_logic_vector(7 downto 0);   -- completed sequences
      dbg_steps_o       : out   std_logic_vector(15 downto 0);  -- step pulses issued
      dbg_last_gap_o    : out   std_logic_vector(11 downto 0);  -- last flux gap in clocks
      dbg_byte_o        : out   std_logic_vector(7 downto 0);   -- decoded byte stream (read path later)
      dbg_byte_valid_o  : out   std_logic;
      dbg_sync_mark_o   : out   std_logic
   );
end entity floppy_phy_spike;

architecture rtl of floppy_phy_spike is

   -- CRC-16/CCITT, poly 0x1021, msb first (crc1581.vhdl:92-95 bit by bit)
   function crc16_byte (crc : std_logic_vector(15 downto 0); d : std_logic_vector(7 downto 0))
      return std_logic_vector is
      variable c : std_logic_vector(15 downto 0) := crc;
      variable b : std_logic;
   begin
      for i in 7 downto 0 loop
         b := c(15) xor d(i);
         c := c(14 downto 0) & '0';
         if b = '1' then
            c := c xor x"1021";
         end if;
      end loop;
      return c;
   end function crc16_byte;

   function max_nat (a, b : natural) return natural is
   begin
      if a > b then return a; else return b; end if;
   end function max_nat;

   constant C_TIMER_MAX : natural := max_nat(max_nat(G_SPINUP_CYCLES, G_INDEX_TIMEOUT_CYCLES),
                                             max_nat(G_REPEAT_CYCLES, G_SETTLE_CYCLES));

   ---------------------------------------------------------------------------------------------
   -- Input synchronisers (ASYNC_REG, false paths from the ports in CORE.xdc)
   ---------------------------------------------------------------------------------------------
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

   -- filtered levels (active high) and edges
   signal index_hist    : std_logic_vector(3 downto 0) := (others => '1');
   signal index_low     : std_logic := '0';
   signal index_low_q   : std_logic := '0';
   signal index_edge    : std_logic := '0';
   signal rdata_hist    : std_logic_vector(2 downto 0) := (others => '1');
   signal rdata_low     : std_logic := '0';
   signal rdata_low_q   : std_logic := '0';
   signal flux_edge     : std_logic := '0';
   signal track0_n      : std_logic := '0';            -- 1 = at track 0
   signal wp_n          : std_logic := '0';            -- 1 = write protected
   signal dskchg_n      : std_logic := '0';            -- 1 = disk change latched
   signal dskchg_q      : std_logic := '0';

   ---------------------------------------------------------------------------------------------
   -- Reader
   ---------------------------------------------------------------------------------------------
   signal rate_hd       : std_logic := '0';            -- 1 = 500 kbit/s
   signal hc            : unsigned(8 downto 0);        -- half cell in clocks
   signal thr_lo        : unsigned(11 downto 0);       -- 1.0 hc
   signal thr_2         : unsigned(11 downto 0);       -- 2.5 hc
   signal thr_3         : unsigned(11 downto 0);       -- 3.5 hc
   signal thr_4         : unsigned(11 downto 0);       -- 5.0 hc
   signal gap_cnt       : unsigned(11 downto 0) := (others => '0');
   signal gap_len       : unsigned(11 downto 0) := (others => '0');
   signal bit_pend      : unsigned(2 downto 0) := (others => '0');   -- raw bits still to shift
   signal raw_sr        : std_logic_vector(15 downto 0) := (others => '0');
   signal raw_valid     : std_logic := '0';
   signal raw_bit       : std_logic := '0';
   signal sync_mark     : std_logic := '0';
   signal bit_phase     : std_logic := '0';            -- 1 = the next raw bit is a data bit
   signal data_sr       : std_logic_vector(7 downto 0) := (others => '0');
   signal nbits         : unsigned(2 downto 0) := (others => '0');
   signal byte_valid    : std_logic := '0';
   signal byte_val      : std_logic_vector(7 downto 0) := (others => '0');
   signal in_sync       : std_logic := '0';

   type t_dec is (D_IDLE, D_MARK, D_ID_C, D_ID_H, D_ID_R, D_ID_N, D_ID_CRC1, D_ID_CRC2,
                  D_DATA, D_DATA_CRC1, D_DATA_CRC2);
   signal dec           : t_dec := D_IDLE;
   signal crc           : std_logic_vector(15 downto 0) := (others => '1');
   signal id_c, id_h, id_r, id_n : std_logic_vector(7 downto 0) := (others => '0');
   signal data_left     : unsigned(10 downto 0) := (others => '0');
   signal sector_bytes  : unsigned(10 downto 0) := to_unsigned(512, 11);

   signal cnt_index     : unsigned(15 downto 0) := (others => '0');
   signal cnt_sync      : unsigned(15 downto 0) := (others => '0');
   signal cnt_idam      : unsigned(15 downto 0) := (others => '0');
   signal cnt_idam_ok   : unsigned(15 downto 0) := (others => '0');
   signal cnt_dam       : unsigned(15 downto 0) := (others => '0');
   signal cnt_dam_ok    : unsigned(15 downto 0) := (others => '0');
   signal cnt_steps     : unsigned(15 downto 0) := (others => '0');
   signal cnt_runs      : unsigned(7 downto 0)  := (others => '0');
   signal last_chrn     : std_logic_vector(31 downto 0) := (others => '0');
   signal max_r         : unsigned(7 downto 0) := (others => '0');
   signal last_rate_hd  : std_logic := '0';

   ---------------------------------------------------------------------------------------------
   -- Sequencer
   ---------------------------------------------------------------------------------------------
   type t_seq is (S_IDLE, S_MOTOR, S_HOME_IN, S_HOME_OUT, S_HOME_SETTLE, S_READ_HD, S_READ_DD,
                  S_SEEK_IN, S_SEEK_SETTLE, S_READ_T, S_SEEK_OUT, S_OUT_SETTLE, S_STOP);
   signal seq           : t_seq := S_MOTOR;
   signal timer         : natural range 0 to C_TIMER_MAX := 0;
   signal motor_on      : std_logic := '0';
   signal stepdir_out   : std_logic := '1';            -- 1 = towards track 0
   signal step_go       : std_logic := '0';
   signal step_timer    : natural range 0 to G_STEP_RATE_CYCLES := 0;
   constant C_DIR_SETUP_CYCLES : natural := 500;
   signal dir_timer     : natural range 0 to C_DIR_SETUP_CYCLES := 0;
   signal stepdir_q     : std_logic := '1';
   signal step_ready    : std_logic;
   signal step_n        : std_logic := '1';
   signal run_start     : std_logic := '0';
   signal steps_left    : natural range 0 to 255 := 0;
   signal head_track    : unsigned(7 downto 0) := (others => '0');
   signal seek_ok       : std_logic := '0';
   signal track0_seen   : std_logic := '0';
   signal hd_found      : std_logic := '0';
   signal dd_found      : std_logic := '0';
   signal ok_snapshot   : unsigned(15 downto 0) := (others => '0');
   signal idx_armed     : std_logic := '0';
   signal idx_left      : natural range 0 to 255 := 0;
   signal rate_t        : std_logic := '0';            -- the rate for the track-40 read
   signal dec_reset     : std_logic := '0';

   ---------------------------------------------------------------------------------------------
   -- Status crossing (toggle handshake, as eth_phy_spike.vhd)
   ---------------------------------------------------------------------------------------------
   signal stat_word_a   : std_logic_vector(15 downto 0);
   signal stat_word_b   : std_logic_vector(15 downto 0);
   signal stat_word_c   : std_logic_vector(15 downto 0);
   signal flags         : std_logic_vector(7 downto 0);
   signal src_snap      : std_logic_vector(47 downto 0) := (others => '0');
   signal src_req       : std_logic := '0';
   signal src_ack_meta  : std_logic := '0';
   signal src_ack_sync  : std_logic := '0';
   signal stat_req_meta : std_logic := '0';
   signal stat_req_sync : std_logic := '0';
   signal stat_ack      : std_logic := '0';
   signal stat_hold     : std_logic_vector(47 downto 0) := (others => '0');
   attribute ASYNC_REG of src_ack_meta  : signal is "TRUE";
   attribute ASYNC_REG of src_ack_sync  : signal is "TRUE";
   attribute ASYNC_REG of stat_req_meta : signal is "TRUE";
   attribute ASYNC_REG of stat_req_sync : signal is "TRUE";

begin

   ---------------------------------------------------------------------------------------------
   -- Pins
   ---------------------------------------------------------------------------------------------
   f_selecta_o <= '0';                       -- selected always (outputs of the drive are gated by it)
   f_motora_o  <= not motor_on;
   f_side1_o   <= '1';                       -- side 0
   f_stepdir_o <= stepdir_out;
   f_step_o    <= step_n;
   f_wdata_o   <= '1';                       -- never
   f_wgate_o   <= '1';                       -- never
   f_density_o <= G_DENSITY_HD when rate_hd = '1' else G_DENSITY_DD;

   ---------------------------------------------------------------------------------------------
   -- Synchronisers, filters, edges
   ---------------------------------------------------------------------------------------------
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
         index_low_q <= index_low;
         index_edge  <= index_low and not index_low_q;

         -- RDATA: low for three samples (60 ns) = a flux transition (machine.vhdl:892-895 uses four)
         rdata_hist  <= rdata_hist(1 downto 0) & rdata_sync;
         if rdata_hist = "000" then
            rdata_low <= '1';
         else
            rdata_low <= '0';
         end if;
         rdata_low_q <= rdata_low;
         flux_edge   <= rdata_low and not rdata_low_q;

         track0_n <= not track0_sync;
         wp_n     <= not wp_sync;
         dskchg_n <= not dskchg_sync;
         dskchg_q <= dskchg_n;
         if track0_n = '1' then
            track0_seen <= '1';
         end if;
         if rst_i = '1' then
            track0_seen <= '0';
         end if;
      end if;
   end process p_sync;

   ---------------------------------------------------------------------------------------------
   -- Gap measurement and quantiser (mfm_quantise_gaps.vhdl:39-63 with cycles_per_interval = hc)
   ---------------------------------------------------------------------------------------------
   hc     <= to_unsigned(G_HD_HALF_CELL, 9) when rate_hd = '1' else to_unsigned(G_DD_HALF_CELL, 9);
   thr_lo <= resize(hc, 12);                                             -- 1.0 hc
   thr_2  <= resize(hc, 12) + resize(hc, 12) + resize(hc(8 downto 1), 12);            -- 2.5 hc
   thr_3  <= shift_left(resize(hc, 12), 2) - resize(hc(8 downto 1), 12);              -- 3.5 hc
   thr_4  <= shift_left(resize(hc, 12), 2) + resize(hc, 12);                          -- 5.0 hc

   p_gaps : process (clk_i)
      variable v_n : unsigned(2 downto 0);
   begin
      if rising_edge(clk_i) then
         raw_valid <= '0';
         sync_mark <= '0';
         byte_valid <= '0';

         -- gap counter, saturating
         if flux_edge = '1' then
            gap_len <= gap_cnt;
            gap_cnt <= to_unsigned(1, 12);
         elsif gap_cnt /= x"FFF" then
            gap_cnt <= gap_cnt + 1;
         end if;

         -- classify the gap that just ended: n raw bits pending
         if flux_edge = '1' then
            if gap_cnt < thr_lo then
               v_n := "000";                                          -- too short: glitch
            elsif gap_cnt <= thr_2 then
               v_n := "010";
            elsif gap_cnt <= thr_3 then
               v_n := "011";
            elsif gap_cnt <= thr_4 then
               v_n := "100";
            else
               v_n := "000";                                          -- too long: no flux, lost
            end if;
            bit_pend <= v_n;
            if v_n = "000" then
               in_sync <= '0';                                        -- need a new mark
            end if;
         elsif bit_pend /= 0 then
            -- shift one raw bit per clock: zeros then the one
            bit_pend  <= bit_pend - 1;
            raw_valid <= '1';
            if bit_pend = 1 then
               raw_bit <= '1';
            else
               raw_bit <= '0';
            end if;
         end if;

         -- raw shift register, mark detection, byte assembly
         if raw_valid = '1' then
            raw_sr <= raw_sr(14 downto 0) & raw_bit;
            if (raw_sr(14 downto 0) & raw_bit) = x"4489" then
               sync_mark <= '1';
               in_sync   <= '1';
               bit_phase <= '0';                                      -- next raw bit is a clock bit
               nbits     <= (others => '0');
            elsif in_sync = '1' then
               bit_phase <= not bit_phase;
               if bit_phase = '1' then
                  data_sr <= data_sr(6 downto 0) & raw_bit;
                  if nbits = 7 then
                     byte_valid <= '1';
                     byte_val   <= data_sr(6 downto 0) & raw_bit;
                     nbits      <= (others => '0');
                  else
                     nbits <= nbits + 1;
                  end if;
               end if;
            end if;
         end if;

         if dec_reset = '1' or rst_i = '1' then
            bit_pend <= (others => '0');
            in_sync  <= '0';
            raw_sr   <= (others => '0');
            gap_cnt  <= (others => '0');
         end if;
      end if;
   end process p_gaps;

   ---------------------------------------------------------------------------------------------
   -- Byte-level decoder: IDAM / DAM with CRC (mfm_decoder.vhdl:369-513 in spirit)
   ---------------------------------------------------------------------------------------------
   p_dec : process (clk_i)
   begin
      if rising_edge(clk_i) then
         if sync_mark = '1' then
            -- every mark: (re)start a group; the CRC covers the marks themselves
            if dec = D_MARK then
               crc <= crc16_byte(crc, x"A1");
            else
               crc <= crc16_byte(x"FFFF", x"A1");
            end if;
            dec      <= D_MARK;
            cnt_sync <= cnt_sync + 1;
         elsif byte_valid = '1' then
            case dec is
               when D_IDLE =>
                  null;
               when D_MARK =>
                  crc <= crc16_byte(crc, byte_val);
                  if byte_val = x"FE" then
                     dec      <= D_ID_C;
                     cnt_idam <= cnt_idam + 1;
                  elsif byte_val = x"FB" or byte_val = x"F8" then
                     dec       <= D_DATA;
                     cnt_dam   <= cnt_dam + 1;
                     data_left <= sector_bytes;
                  else
                     dec <= D_IDLE;
                  end if;
               when D_ID_C =>
                  id_c <= byte_val; crc <= crc16_byte(crc, byte_val); dec <= D_ID_H;
               when D_ID_H =>
                  id_h <= byte_val; crc <= crc16_byte(crc, byte_val); dec <= D_ID_R;
               when D_ID_R =>
                  id_r <= byte_val; crc <= crc16_byte(crc, byte_val); dec <= D_ID_N;
               when D_ID_N =>
                  id_n <= byte_val; crc <= crc16_byte(crc, byte_val); dec <= D_ID_CRC1;
               when D_ID_CRC1 =>
                  crc <= crc16_byte(crc, byte_val); dec <= D_ID_CRC2;
               when D_ID_CRC2 =>
                  dec <= D_IDLE;
                  if crc16_byte(crc, byte_val) = x"0000" then
                     cnt_idam_ok   <= cnt_idam_ok + 1;
                     last_chrn     <= id_c & id_h & id_r & id_n;
                     last_rate_hd  <= rate_hd;
                     if unsigned(id_r) > max_r then
                        max_r <= unsigned(id_r);
                     end if;
                     case id_n is
                        when x"00"  => sector_bytes <= to_unsigned(128, 11);
                        when x"01"  => sector_bytes <= to_unsigned(256, 11);
                        when x"03"  => sector_bytes <= to_unsigned(1024, 11);
                        when others => sector_bytes <= to_unsigned(512, 11);
                     end case;
                  end if;
               when D_DATA =>
                  crc <= crc16_byte(crc, byte_val);
                  if data_left = 1 then
                     dec <= D_DATA_CRC1;
                  end if;
                  data_left <= data_left - 1;
               when D_DATA_CRC1 =>
                  crc <= crc16_byte(crc, byte_val); dec <= D_DATA_CRC2;
               when D_DATA_CRC2 =>
                  dec <= D_IDLE;
                  if crc16_byte(crc, byte_val) = x"0000" then
                     cnt_dam_ok <= cnt_dam_ok + 1;
                  end if;
            end case;
         end if;

         if index_edge = '1' then
            cnt_index <= cnt_index + 1;
         end if;

         if dec_reset = '1' then
            dec <= D_IDLE;
         end if;
         if run_start = '1' then
            max_r <= (others => '0');
         end if;
         if rst_i = '1' then
            dec          <= D_IDLE;
            cnt_sync     <= (others => '0');
            cnt_idam     <= (others => '0');
            cnt_idam_ok  <= (others => '0');
            cnt_dam      <= (others => '0');
            cnt_dam_ok   <= (others => '0');
            cnt_index    <= (others => '0');
            last_chrn    <= (others => '0');
            max_r        <= (others => '0');
            sector_bytes <= to_unsigned(512, 11);
         end if;
      end if;
   end process p_dec;

   ---------------------------------------------------------------------------------------------
   -- Step engine: STEP low for G_STEP_PULSE_CYCLES, next step no sooner than G_STEP_RATE_CYCLES
   ---------------------------------------------------------------------------------------------
   -- DIR set-up: no pulse within C_DIR_SETUP_CYCLES (10 us) of a direction change (the interface asks
   -- for 1 us before the pulse; the drive acts on the trailing edge, 12 us later still)
   step_ready <= '1' when step_timer = 0 and dir_timer = 0 and stepdir_out = stepdir_q else '0';

   p_step : process (clk_i)
   begin
      if rising_edge(clk_i) then
         stepdir_q <= stepdir_out;
         if stepdir_out /= stepdir_q then
            dir_timer <= C_DIR_SETUP_CYCLES;
         elsif dir_timer /= 0 then
            dir_timer <= dir_timer - 1;
         end if;

         if step_go = '1' and step_ready = '1' then
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

   ---------------------------------------------------------------------------------------------
   -- Sequencer
   ---------------------------------------------------------------------------------------------
   p_seq : process (clk_i)
      variable v_phase_done : boolean;
   begin
      if rising_edge(clk_i) then
         step_go   <= '0';
         dec_reset <= '0';
         run_start <= '0';
         if seq = S_MOTOR and timer = 0 then
            run_start <= '1';                                         -- clears the per-run maxima
         end if;

         -- read-phase bookkeeping, shared by the three read states
         v_phase_done := false;
         if seq = S_READ_HD or seq = S_READ_DD or seq = S_READ_T then
            if index_edge = '1' then
               timer <= 0;
               if idx_armed = '0' then
                  idx_armed <= '1';
                  idx_left  <= G_INDEX_PULSES;
               elsif idx_left <= 1 then
                  v_phase_done := true;
               else
                  idx_left <= idx_left - 1;
               end if;
            elsif timer = G_INDEX_TIMEOUT_CYCLES - 1 then
               v_phase_done := true;                                  -- no index: no disk / no spin
            else
               timer <= timer + 1;
            end if;
         end if;

         case seq is
            when S_IDLE =>
               motor_on <= '0';
               if timer = G_REPEAT_CYCLES - 1 or dskchg_n /= dskchg_q then
                  seq   <= S_MOTOR;
                  timer <= 0;
               else
                  timer <= timer + 1;
               end if;

            when S_MOTOR =>
               motor_on <= '1';
               hd_found <= '0';
               dd_found <= '0';
               seek_ok  <= '0';
               if timer = G_SPINUP_CYCLES - 1 then
                  timer <= 0;
                  if track0_n = '1' then
                     seq         <= S_HOME_IN;                        -- one step in first
                     stepdir_out <= '0';
                     steps_left  <= 1;
                  else
                     seq         <= S_HOME_OUT;
                     stepdir_out <= '1';
                     steps_left  <= G_MAX_STEPS_HOME;
                  end if;
               else
                  timer <= timer + 1;
               end if;

            when S_HOME_IN =>
               -- direction set-up before the pulse is the first G_STEP_RATE_CYCLES wait below
               if step_ready = '1' and step_go = '0' then
                  if steps_left = 0 then
                     seq         <= S_HOME_OUT;
                     stepdir_out <= '1';
                     steps_left  <= G_MAX_STEPS_HOME;
                  else
                     step_go    <= '1';
                     steps_left <= steps_left - 1;
                  end if;
               end if;

            when S_HOME_OUT =>
               if step_ready = '1' and step_go = '0' then
                  if track0_n = '1' then
                     seek_ok    <= '1';
                     head_track <= (others => '0');
                     seq        <= S_HOME_SETTLE;
                     timer      <= 0;
                  elsif steps_left = 0 then
                     seek_ok <= '0';                                  -- no TRACK0 within the limit
                     seq     <= S_HOME_SETTLE;
                     timer   <= 0;
                  else
                     step_go    <= '1';
                     steps_left <= steps_left - 1;
                  end if;
               end if;

            when S_HOME_SETTLE =>
               if timer = G_SETTLE_CYCLES - 1 then
                  timer       <= 0;
                  seq         <= S_READ_HD;
                  rate_hd     <= '1';
                  dec_reset   <= '1';
                  idx_armed   <= '0';
                  ok_snapshot <= cnt_idam_ok;
               else
                  timer <= timer + 1;
               end if;

            when S_READ_HD =>
               if v_phase_done then
                  if cnt_idam_ok /= ok_snapshot then
                     hd_found <= '1';
                  end if;
                  timer       <= 0;
                  seq         <= S_READ_DD;
                  rate_hd     <= '0';
                  dec_reset   <= '1';
                  idx_armed   <= '0';
                  ok_snapshot <= cnt_idam_ok;
               end if;

            when S_READ_DD =>
               if v_phase_done then
                  if cnt_idam_ok /= ok_snapshot then
                     dd_found <= '1';
                  end if;
                  timer       <= 0;
                  seq         <= S_SEEK_IN;
                  stepdir_out <= '0';
                  idx_armed   <= '0';
               end if;

            when S_SEEK_IN =>
               if step_ready = '1' and step_go = '0' then
                  if head_track >= G_TEST_TRACK then
                     seq   <= S_SEEK_SETTLE;
                     timer <= 0;
                  else
                     step_go    <= '1';
                     head_track <= head_track + 1;
                  end if;
               end if;

            when S_SEEK_SETTLE =>
               if timer = G_SETTLE_CYCLES - 1 then
                  timer     <= 0;
                  seq       <= S_READ_T;
                  rate_hd   <= hd_found;                              -- DD unless HD found headers
                  dec_reset <= '1';
                  idx_armed <= '0';
               else
                  timer <= timer + 1;
               end if;

            when S_READ_T =>
               if v_phase_done then
                  timer       <= 0;
                  seq         <= S_SEEK_OUT;
                  stepdir_out <= '1';
                  steps_left  <= G_MAX_STEPS_HOME;
                  idx_armed   <= '0';
               end if;

            when S_SEEK_OUT =>
               if step_ready = '1' and step_go = '0' then
                  if track0_n = '1' then
                     head_track <= (others => '0');
                     seq        <= S_OUT_SETTLE;
                     timer      <= 0;
                  elsif steps_left = 0 then
                     seek_ok <= '0';
                     seq     <= S_OUT_SETTLE;
                     timer   <= 0;
                  else
                     step_go    <= '1';
                     steps_left <= steps_left - 1;
                     if head_track /= 0 then
                        head_track <= head_track - 1;
                     end if;
                  end if;
               end if;

            when S_OUT_SETTLE =>
               if timer = G_SETTLE_CYCLES - 1 then
                  timer <= 0;
                  seq   <= S_STOP;
               else
                  timer <= timer + 1;
               end if;

            when S_STOP =>
               motor_on <= '0';
               cnt_runs <= cnt_runs + 1;
               timer    <= 0;
               seq      <= S_IDLE;
         end case;

         if rst_i = '1' then
            seq         <= S_MOTOR;
            timer       <= 0;
            motor_on    <= '0';
            stepdir_out <= '1';
            steps_left  <= 0;
            head_track  <= (others => '0');
            seek_ok     <= '0';
            hd_found    <= '0';
            dd_found    <= '0';
            rate_hd     <= '0';
            idx_armed   <= '0';
            cnt_runs    <= (others => '0');
         end if;
      end if;
   end process p_seq;

   ---------------------------------------------------------------------------------------------
   -- Status words, debug taps, crossing into stat_clk_i
   ---------------------------------------------------------------------------------------------
   flags       <= last_rate_hd & track0_seen & wp_n & dskchg_n & seek_ok & motor_on & dd_found & hd_found;
   stat_word_a <= std_logic_vector(cnt_idam_ok(7 downto 0)) & std_logic_vector(cnt_index(7 downto 0));
   stat_word_b <= last_chrn(31 downto 24) & last_chrn(15 downto 8);
   stat_word_c <= flags & std_logic_vector(max_r);

   dbg_index_o      <= std_logic_vector(cnt_index);
   dbg_syncs_o      <= std_logic_vector(cnt_sync);
   dbg_idam_o       <= std_logic_vector(cnt_idam);
   dbg_idam_ok_o    <= std_logic_vector(cnt_idam_ok);
   dbg_dam_o        <= std_logic_vector(cnt_dam);
   dbg_dam_ok_o     <= std_logic_vector(cnt_dam_ok);
   dbg_chrn_o       <= last_chrn;
   dbg_max_r_o      <= std_logic_vector(max_r);
   dbg_flags_o      <= flags;
   dbg_state_o      <= std_logic_vector(to_unsigned(t_seq'pos(seq), 8));
   dbg_track_o      <= std_logic_vector(head_track);
   dbg_runs_o       <= std_logic_vector(cnt_runs);
   dbg_steps_o      <= std_logic_vector(cnt_steps);
   dbg_last_gap_o   <= std_logic_vector(gap_len);
   dbg_byte_o       <= byte_val;
   dbg_byte_valid_o <= byte_valid;
   dbg_sync_mark_o  <= sync_mark;

   p_cdc_src : process (clk_i)
   begin
      if rising_edge(clk_i) then
         src_ack_meta <= stat_ack;
         src_ack_sync <= src_ack_meta;
         if src_req = src_ack_sync then                              -- previous snapshot delivered
            src_snap <= stat_word_a & stat_word_b & stat_word_c;
            src_req  <= not src_req;
         end if;
      end if;
   end process p_cdc_src;

   p_cdc_dst : process (stat_clk_i)
   begin
      if rising_edge(stat_clk_i) then
         stat_req_meta <= src_req;
         stat_req_sync <= stat_req_meta;
         if stat_req_sync /= stat_ack then
            stat_hold <= src_snap;                                   -- stable until acknowledged
            stat_ack  <= stat_req_sync;
         end if;
      end if;
   end process p_cdc_dst;

   stat_a_o <= stat_hold(47 downto 32);
   stat_b_o <= stat_hold(31 downto 16);
   stat_c_o <= stat_hold(15 downto 0);

end architecture rtl;
