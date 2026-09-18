-------------------------------------------------------------------------------------------------------------
-- floppy_mfm_writer: bytes -> MFM flux transitions on WRITE DATA, with WRITE GATE, at 250 or 500 kbit/s
--
-- Phase 3 of docs/floppy.md, used by floppy_sector_engine.vhd for WRITE_SECTOR. clk_i = 50.000 MHz.
--   * One raw MFM bit per half cell: G_HD_HALF_CELL (50 clocks, 1 us) at 500 kbit/s, G_DD_HALF_CELL (100)
--     at 250 kbit/s - exactly the cells the reader (floppy_mfm_reader.vhd) quantises against.
--   * MFM rule: a data byte becomes 16 raw bits, clock bit then data bit for every data bit, the clock bit
--     being '1' only between two '0' data bits (mega65-core mfm_bits_to_gaps.vhdl bit_queue assignments,
--     the previous byte's last data bit carried across). A byte flagged mark_i is the A1 sync mark with the
--     missing clock, raw 0x4489, which the reader detects as such; one flagged mark_c2_i is the C2 mark of
--     the index address mark (raw 0x5224, phase 4: FORMAT_TRACK writes C2 C2 C2 FC after gap 4a).
--   * A raw '1' is a flux transition: WRITE DATA is pulsed low for half a half cell (25 / 50 clocks,
--     0.5 / 1 us) starting at the middle of the raw bit cell, like mega65-core (f_write low from
--     transition_point = cycles_per_interval / 2 to the end of the interval); the drive acts on the falling
--     edge, and that edge is what our own reader takes as the flux event.
--   * Write precompensation (optional, precomp_i clocks, 0 = off): a transition whose nearer neighbour is
--     before it is written precomp_i clocks early, one whose nearer neighbour is after it that much late
--     (neighbour distances 2, 3 and >= 4 half cells compared), the standard peak-shift rule (WD177x: "1/8
--     of a cycle", the 82077 default 125 ns). The 7-raw-bit window is mega65-core's (three bits of past
--     and future around the bit being written).
--   * Handshake: start_i (pulse) asserts WRITE GATE and starts the cell timer; byte_i / mark_i must be
--     valid then and after every next_o pulse within a few clocks (the next byte is taken 16 half cells
--     later). When the writer needs a byte and stop_i is '1' it drains its 3-bit window, keeps WRITE GATE
--     for one more data cell after the last transition and pulses done_o. active_o is the WRITE GATE level.
--     abort_i drops everything at once (drive deselected).
--
-- MEGA65 port done by silent-command in 2026 and licensed under GPL v3
-- MiSTer2MEGA65 done by sy2002 and MJoergen in 2022 and licensed under GPL v3
-------------------------------------------------------------------------------------------------------------

library ieee;
   use ieee.std_logic_1164.all;
   use ieee.numeric_std.all;

entity floppy_mfm_writer is
   generic (
      G_HD_HALF_CELL : natural := 50;            -- 500 kbit/s: 1 us raw bit
      G_DD_HALF_CELL : natural := 100            -- 250 kbit/s: 2 us raw bit
   );
   port (
      clk_i          : in    std_logic;
      rst_i          : in    std_logic;
      rate_hd_i      : in    std_logic;          -- 1 = 500 kbit/s, sampled at start_i
      precomp_i      : in    unsigned(4 downto 0);   -- write precompensation in clocks, 0 = off
      start_i        : in    std_logic;          -- pulse: WRITE GATE on, first byte taken at once
      abort_i        : in    std_logic;          -- level: stop now
      byte_i         : in    std_logic_vector(7 downto 0);
      mark_i         : in    std_logic;          -- byte_i is an A1 sync mark (raw 0x4489)
      mark_c2_i      : in    std_logic := '0';   -- byte_i is a C2 index mark (raw 0x5224)
      stop_i         : in    std_logic;          -- no more bytes: finish after the current one
      next_o         : out   std_logic;          -- pulse: byte_i was taken, present the next one
      active_o       : out   std_logic;          -- WRITE GATE (active high)
      done_o         : out   std_logic;          -- pulse: WRITE GATE released after the last transition
      wgate_o        : out   std_logic;          -- active high, to floppy_drive_if
      wdata_o        : out   std_logic           -- active high pulse, to floppy_drive_if
   );
end entity floppy_mfm_writer;

architecture rtl of floppy_mfm_writer is

   -- MFM-encode one byte after the previous byte's last data bit
   function mfm_encode (d : std_logic_vector(7 downto 0); last_d : std_logic) return std_logic_vector is
      variable raw  : std_logic_vector(15 downto 0);
      variable prev : std_logic := last_d;
   begin
      for i in 7 downto 0 loop
         raw(2 * i + 1) := (not prev) and (not d(i));    -- clock bit
         raw(2 * i)     := d(i);                         -- data bit
         prev           := d(i);
      end loop;
      return raw;
   end function mfm_encode;

   type t_w is (W_IDLE, W_RUN, W_TAIL);
   signal w           : t_w := W_IDLE;
   signal hc          : natural range 0 to 255 := G_DD_HALF_CELL;
   signal cell_cnt    : natural range 0 to 255 := 0;
   signal q           : std_logic_vector(15 downto 0) := (others => '0');
   signal q_cnt       : natural range 0 to 16 := 0;
   signal last_d      : std_logic := '0';
   signal win         : std_logic_vector(6 downto 0) := (others => '0');   -- 6..4 past, 3 current, 2..0 future
   signal draining    : std_logic := '0';
   signal drain_cnt   : natural range 0 to 7 := 0;
   signal adj         : integer range -31 to 31 := 0;
   signal fire_at     : natural range 0 to 255 := 0;
   signal pulse_cnt   : natural range 0 to 255 := 0;
   signal tail_cnt    : natural range 0 to 511 := 0;
   signal wgate       : std_logic := '0';
   signal wdata       : std_logic := '0';
   signal next_p      : std_logic := '0';
   signal done_p      : std_logic := '0';

begin

   p_w : process (clk_i)
      variable v_q      : std_logic_vector(15 downto 0);
      variable v_cnt    : natural range 0 to 16;
      variable v_bit    : std_logic;
      variable v_before : natural range 0 to 3;   -- 1 = neighbour 2 half cells before, 2 = 3, 3 = further
      variable v_after  : natural range 0 to 3;
      variable v_p      : natural range 0 to 31;
   begin
      if rising_edge(clk_i) then
         next_p <= '0';
         done_p <= '0';

         -- the WRITE DATA pulse, independent of the cell timer so that precompensation moves only its edge
         if pulse_cnt /= 0 then
            pulse_cnt <= pulse_cnt - 1;
            if pulse_cnt = 1 then
               wdata <= '0';
            end if;
         end if;

         case w is
            when W_IDLE =>
               wgate <= '0';
               if start_i = '1' then
                  if rate_hd_i = '1' then
                     hc <= G_HD_HALF_CELL;
                  else
                     hc <= G_DD_HALF_CELL;
                  end if;
                  wgate     <= '1';
                  cell_cnt  <= 0;
                  q_cnt     <= 0;
                  last_d    <= '0';
                  win       <= (others => '0');
                  draining  <= '0';
                  drain_cnt <= 0;
                  adj       <= 0;
                  w         <= W_RUN;
               end if;

            when W_RUN =>
               if cell_cnt = 0 then
                  -- raw bit boundary: shift the window, refill the byte queue when empty
                  v_q   := q;
                  v_cnt := q_cnt;
                  if v_cnt = 0 then
                     if draining = '1' then
                        v_q := (others => '0');
                        v_cnt := 1;                                -- keep shifting zeros
                        if drain_cnt = 4 then                      -- last real bit left the window
                           w        <= W_TAIL;
                           tail_cnt <= 2 * hc;
                        else
                           drain_cnt <= drain_cnt + 1;
                        end if;
                     elsif stop_i = '1' then
                        draining <= '1';
                        v_q      := (others => '0');
                        v_cnt    := 1;
                     else
                        if mark_i = '1' then
                           v_q    := x"4489";
                           last_d <= '1';
                        elsif mark_c2_i = '1' then
                           v_q    := x"5224";                      -- C2 with the missing clock, last data bit 0
                           last_d <= '0';
                        else
                           v_q    := mfm_encode(byte_i, last_d);
                           last_d <= byte_i(0);
                        end if;
                        v_cnt  := 16;
                        next_p <= '1';
                     end if;
                  end if;
                  v_bit := v_q(15);
                  win   <= win(5 downto 0) & v_bit;
                  q     <= v_q(14 downto 0) & '0';
                  q_cnt <= v_cnt - 1;
                  cell_cnt <= 1;
               else
                  if cell_cnt = 1 then
                     -- the bit now at win(3) is written in this cell: place its transition
                     if win(5) = '1' then    v_before := 1;
                     elsif win(6) = '1' then v_before := 2;
                     else                    v_before := 3; end if;
                     if win(2) = '1' then    v_after := 1;
                     elsif win(1) = '1' then v_after := 2;
                     else                    v_after := 3; end if;
                     v_p := to_integer(precomp_i);
                     if v_p > hc / 2 - 3 then
                        v_p := hc / 2 - 3;                          -- keep the transition inside its cell
                     end if;
                     if precomp_i = 0 or win(3) = '0' or v_before = v_after then
                        adj <= 0;
                     elsif v_before < v_after then
                        adj <= -v_p;                                -- read peak pushed late: write early
                     else
                        adj <= v_p;                                 -- read peak pushed early: write late
                     end if;
                  end if;
                  if cell_cnt = hc / 2 + adj and win(3) = '1' and cell_cnt >= 2 then
                     wdata     <= '1';
                     pulse_cnt <= hc / 2;
                  end if;
                  if cell_cnt = hc - 1 then
                     cell_cnt <= 0;
                  else
                     cell_cnt <= cell_cnt + 1;
                  end if;
               end if;

            when W_TAIL =>
               if tail_cnt = 0 then
                  wgate  <= '0';
                  done_p <= '1';
                  w      <= W_IDLE;
               else
                  tail_cnt <= tail_cnt - 1;
               end if;
         end case;

         if abort_i = '1' or rst_i = '1' then
            w         <= W_IDLE;
            wgate     <= '0';
            wdata     <= '0';
            pulse_cnt <= 0;
            next_p    <= '0';
            done_p    <= '0';
         end if;
      end if;
   end process p_w;

   next_o   <= next_p;
   done_o   <= done_p;
   active_o <= wgate;
   wgate_o  <= wgate;
   wdata_o  <= wdata;

end architecture rtl;
