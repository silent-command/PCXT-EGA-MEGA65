-------------------------------------------------------------------------------------------------------------
-- mem_backend_tb: self-checking bench for CORE/vhdl/mem_backend.vhd
--
-- Two copies of the DUT run side by side in one simulation, one with G_CACHE = true
-- (default line of 8 words) and one with G_CACHE = false, each behind its own model of
-- the framework's HyperRAM path (hr_model below: avm_arbit_general + hyperram_errata +
-- hyperram_config + hyperram_ctrl as seen from the core's Avalon port). The byte bus is
-- driven the way CORE/rtl/overlay/KFSDRAM.sv drives it: read/write held until
-- waitrequest drops, readdatavalid any time later, in order.
--
-- Clocks: byte bus 50 MHz, HyperRAM side 100 MHz with an unrelated phase.
--
-- Tests per copy: 0 reset ordering (hr_rst_i vs rst_i), 1 ROM port + ROM windows,
-- 2 HyperRAM regions, 3 ordering rules, 4 sequential fetch with latency measurement,
-- 5 random traffic against a reference array. Any read that never answers or request
-- that is never accepted is reported as a hang with the DUT's internal state (VHDL-2008
-- external names) and the bench resets the DUT and carries on. The last line is
-- "MBT RESULT: PASS/FAIL checks=N errors=M".
--
-- Run: powershell -File CORE/rtl/tb/run_mem_backend_tb.ps1
-------------------------------------------------------------------------------------------------------------

-------------------------------------------------------------------------------------------------------------
-- hr_model: the HyperRAM as the core sees it behind the framework's arbiter.
--   * after reset waitrequest stays '1' for G_INIT_HOLD clocks (hyperram_config: 150 us on hardware)
--   * a request is accepted in one clock while idle (waitrequest '0'); from then on waitrequest is '1'
--     for a random latency (G_LAT_MIN..G_LAT_MAX), all read beats (burst up to 255, consecutive or
--     gapped clocks) or the remaining write beats, plus a recovery gap (2..6)
--   * between transactions the arbiter hands the bus to the other masters about half the time
--     (waitrequest '1' for 1..G_HOLD_MAX clocks, the scaler's 64-word bursts), and while idle a
--     hold starts at random too
--   * the Avalon rule "a request presented while waitrequest is '1' stays until accepted" is checked
-------------------------------------------------------------------------------------------------------------
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use ieee.math_real.all;

entity hr_model is
   generic (
      G_ADDRESS_SIZE : natural  := 21;
      G_SEED         : positive := 1;
      G_INIT_HOLD    : natural  := 300;
      G_LAT_MIN      : natural  := 10;
      G_LAT_MAX      : natural  := 60;
      G_HOLD_MAX     : natural  := 80;
      G_GAP_MAX      : natural  := 3
   );
   port (
      clk_i               : in  std_logic;
      rst_i               : in  std_logic;
      avm_write_i         : in  std_logic;
      avm_read_i          : in  std_logic;
      avm_address_i       : in  std_logic_vector(G_ADDRESS_SIZE-1 downto 0);
      avm_writedata_i     : in  std_logic_vector(15 downto 0);
      avm_byteenable_i    : in  std_logic_vector(1 downto 0);
      avm_burstcount_i    : in  std_logic_vector(7 downto 0);
      avm_readdata_o      : out std_logic_vector(15 downto 0) := (others => '0');
      avm_readdatavalid_o : out std_logic := '0';
      avm_waitrequest_o   : out std_logic;
      state_o             : out natural;     -- 0 init, 1 idle, 2 hold, 3 latency, 4 read beats, 5 write beats, 6 recovery
      viol_o              : out natural := 0 -- Avalon rule violations seen
   );
end entity hr_model;

architecture sim of hr_model is
   constant ST_INIT : natural := 0;
   constant ST_IDLE : natural := 1;
   constant ST_HOLD : natural := 2;
   constant ST_LAT  : natural := 3;
   constant ST_RD   : natural := 4;
   constant ST_WR   : natural := 5;
   constant ST_REC  : natural := 6;

   type mem_t is array (0 to 2**G_ADDRESS_SIZE-1) of std_logic_vector(15 downto 0);

   signal st      : natural   := ST_INIT;
   signal waitreq : std_logic := '1';
begin
   avm_waitrequest_o <= waitreq;
   state_o           <= st;

   p_model : process (clk_i)
      variable mem      : mem_t := (others => (others => '0'));
      variable s1       : positive := G_SEED;
      variable s2       : positive := G_SEED * 31 + 7;
      variable r        : real;
      variable cnt      : natural := G_INIT_HOLD;
      variable gap      : natural := 0;
      variable beats    : natural := 0;
      variable cur      : natural := 0;
      variable viol     : natural := 0;
      variable is_rd    : boolean := false;
      variable req_held : boolean := false;
      variable v        : natural;

      procedure rnd(lo : natural; hi : natural; x : out natural) is
         variable y : natural;
      begin
         uniform(s1, s2, r);
         y := lo + natural(trunc(r * real(hi - lo + 1)));
         if y > hi then y := hi; end if;
         x := y;
      end procedure;

      procedure store is
      begin
         if avm_byteenable_i(0) = '1' then
            mem(cur)(7 downto 0) := avm_writedata_i(7 downto 0);
         end if;
         if avm_byteenable_i(1) = '1' then
            mem(cur)(15 downto 8) := avm_writedata_i(15 downto 8);
         end if;
         cur   := (cur + 1) mod 2**G_ADDRESS_SIZE;
         beats := beats - 1;
      end procedure;
   begin
      if rising_edge(clk_i) then
         avm_readdatavalid_o <= '0';

         -- Avalon rules
         if req_held and avm_write_i = '0' and avm_read_i = '0' then
            viol := viol + 1;
            report "hr_model: request withdrawn while waitrequest = '1'" severity error;
         end if;
         if avm_write_i = '1' and avm_read_i = '1' then
            viol := viol + 1;
            report "hr_model: read and write asserted together" severity error;
         end if;
         req_held := (avm_write_i = '1' or avm_read_i = '1') and waitreq = '1';

         case st is
            when ST_INIT =>
               if cnt > 0 then
                  cnt := cnt - 1;
               else
                  waitreq <= '0';
                  st      <= ST_IDLE;
               end if;

            when ST_IDLE =>                       -- waitreq is '0' here: a request is accepted at this edge
               if avm_write_i = '1' or avm_read_i = '1' then
                  is_rd := avm_read_i = '1';
                  cur   := to_integer(unsigned(avm_address_i));
                  beats := to_integer(unsigned(avm_burstcount_i));
                  if not is_rd then
                     store;
                  end if;
                  waitreq <= '1';
                  rnd(G_LAT_MIN, G_LAT_MAX, cnt);
                  st <= ST_LAT;
               else
                  uniform(s1, s2, r);
                  if r < 1.0 / 150.0 then          -- another master takes the bus while we are idle
                     rnd(1, G_HOLD_MAX, cnt);
                     waitreq <= '1';
                     st      <= ST_HOLD;
                  end if;
               end if;

            when ST_HOLD =>
               if cnt > 1 then
                  cnt := cnt - 1;
               else
                  waitreq <= '0';
                  st      <= ST_IDLE;
               end if;

            when ST_LAT =>
               if cnt > 1 then
                  cnt := cnt - 1;
               elsif is_rd then
                  gap := 0;
                  st  <= ST_RD;
               elsif beats > 0 then
                  waitreq <= '0';
                  st      <= ST_WR;
               else
                  rnd(2, 6, cnt);
                  st <= ST_REC;
               end if;

            when ST_RD =>
               if gap > 0 then
                  gap := gap - 1;
               else
                  avm_readdata_o      <= mem(cur);
                  avm_readdatavalid_o <= '1';
                  cur   := (cur + 1) mod 2**G_ADDRESS_SIZE;
                  beats := beats - 1;
                  uniform(s1, s2, r);
                  if r < 0.6 then
                     gap := 0;
                  else
                     rnd(1, G_GAP_MAX, gap);
                  end if;
                  if beats = 0 then
                     rnd(2, 6, cnt);
                     st <= ST_REC;
                  end if;
               end if;

            when ST_WR =>                         -- further beats of a write burst (the DUT never bursts writes)
               if avm_write_i = '1' then
                  store;
                  if beats = 0 then
                     waitreq <= '1';
                     rnd(2, 6, cnt);
                     st <= ST_REC;
                  end if;
               end if;

            when others =>                        -- ST_REC
               if cnt > 1 then
                  cnt := cnt - 1;
               else
                  uniform(s1, s2, r);
                  if r < 0.5 then                 -- the arbiter swaps to another master
                     rnd(1, G_HOLD_MAX, cnt);
                     st <= ST_HOLD;
                  else
                     waitreq <= '0';
                     st      <= ST_IDLE;
                  end if;
               end if;
         end case;

         if rst_i = '1' then
            st                  <= ST_INIT;
            cnt                 := G_INIT_HOLD;
            waitreq             <= '1';
            avm_readdatavalid_o <= '0';
            req_held            := false;
         end if;
         viol_o <= viol;
      end if;
   end process;
end architecture sim;


-------------------------------------------------------------------------------------------------------------
-- one DUT + model + master + checks
-------------------------------------------------------------------------------------------------------------
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use ieee.math_real.all;

entity mem_backend_harness is
   generic (
      G_NAME        : string;
      G_CACHE       : boolean;
      G_SEED        : positive;
      G_INIT_HOLD   : natural := 300;     -- model: waitrequest after reset (hr clocks)
      G_LAT_MIN     : natural := 10;
      G_LAT_MAX     : natural := 60;
      G_HOLD_MAX    : natural := 80;
      G_RANDOM_OPS  : natural := 3000;
      G_TRACE       : boolean := false    -- print every acceptance and readdatavalid (debug)
   );
   port (
      clk_i     : in  std_logic;
      hr_clk_i  : in  std_logic;
      done_o    : out boolean := false;
      checks_o  : out natural := 0;
      errors_o  : out natural := 0;
      hangs_o   : out natural := 0;
      seq_lat_o : out real    := 0.0;   -- average byte-bus clocks acceptance -> readdatavalid, sequential fetch
      seq_min_o : out natural := 0;
      seq_max_o : out natural := 0
   );
end entity mem_backend_harness;

architecture sim of mem_backend_harness is

   constant C_MEM_BITS       : natural := 21;
   constant C_ACCEPT_TIMEOUT : natural := 1000;
   constant C_DONE_TIMEOUT   : natural := 3000;

   signal rst               : std_logic := '1';
   signal hr_rst            : std_logic := '1';

   signal avm_address       : std_logic_vector(21 downto 0) := (others => '0');
   signal avm_writedata     : std_logic_vector(7 downto 0)  := (others => '0');
   signal avm_write         : std_logic := '0';
   signal avm_read          : std_logic := '0';
   signal avm_readdata      : std_logic_vector(7 downto 0);
   signal avm_readdatavalid : std_logic;
   signal avm_waitrequest   : std_logic;

   signal rom_wr            : std_logic := '0';
   signal rom_index         : std_logic_vector(7 downto 0)  := (others => '0');
   signal rom_addr          : std_logic_vector(24 downto 0) := (others => '0');
   signal rom_data          : std_logic_vector(15 downto 0) := (others => '0');

   signal hr_write          : std_logic;
   signal hr_read           : std_logic;
   signal hr_address        : std_logic_vector(31 downto 0);
   signal hr_writedata      : std_logic_vector(15 downto 0);
   signal hr_byteenable     : std_logic_vector(1 downto 0);
   signal hr_burstcount     : std_logic_vector(7 downto 0);
   signal hr_readdata       : std_logic_vector(15 downto 0);
   signal hr_readdatavalid  : std_logic;
   signal hr_waitrequest    : std_logic;
   signal hr_state          : natural;
   signal hr_viol           : natural;

   -- HyperRAM-side monitor (hr_clk domain)
   signal mon_wr_count : natural := 0;
   signal mon_wr_addr  : std_logic_vector(31 downto 0) := (others => '0');
   signal mon_wr_data  : std_logic_vector(15 downto 0) := (others => '0');
   signal mon_wr_be    : std_logic_vector(1 downto 0)  := (others => '0');
   signal mon_wr_burst : std_logic_vector(7 downto 0)  := (others => '0');
   signal mon_rd_count : natural := 0;
   signal mon_rd_addr  : std_logic_vector(31 downto 0) := (others => '0');
   signal mon_rd_burst : std_logic_vector(7 downto 0)  := (others => '0');
   signal mon_bad_hi   : natural := 0;   -- address bits above the model
   signal mon_both     : natural := 0;   -- read and write asserted together
   signal mon_beats    : natural := 0;   -- readdatavalid beats delivered to the DUT

   signal dump_trig    : std_logic := '0';

begin

   ---------------------------------------------------------------------------
   -- DUT
   ---------------------------------------------------------------------------
   i_dut : entity work.mem_backend
      generic map (
         G_HR_BASE    => x"00000000",
         G_CACHE      => G_CACHE,
         G_CACHE_SIZE => 8
      )
      port map (
         clk_i               => clk_i,
         rst_i               => rst,
         avm_address_i       => avm_address,
         avm_writedata_i     => avm_writedata,
         avm_write_i         => avm_write,
         avm_read_i          => avm_read,
         avm_readdata_o      => avm_readdata,
         avm_readdatavalid_o => avm_readdatavalid,
         avm_waitrequest_o   => avm_waitrequest,
         rom_wr_i            => rom_wr,
         rom_index_i         => rom_index,
         rom_addr_i          => rom_addr,
         rom_data_i          => rom_data,
         hr_clk_i            => hr_clk_i,
         hr_rst_i            => hr_rst,
         hr_write_o          => hr_write,
         hr_read_o           => hr_read,
         hr_address_o        => hr_address,
         hr_writedata_o      => hr_writedata,
         hr_byteenable_o     => hr_byteenable,
         hr_burstcount_o     => hr_burstcount,
         hr_readdata_i       => hr_readdata,
         hr_readdatavalid_i  => hr_readdatavalid,
         hr_waitrequest_i    => hr_waitrequest
      );

   ---------------------------------------------------------------------------
   -- HyperRAM path model
   ---------------------------------------------------------------------------
   i_mem : entity work.hr_model
      generic map (
         G_ADDRESS_SIZE => C_MEM_BITS,
         G_SEED         => G_SEED * 3 + 1,
         G_INIT_HOLD    => G_INIT_HOLD,
         G_LAT_MIN      => G_LAT_MIN,
         G_LAT_MAX      => G_LAT_MAX,
         G_HOLD_MAX     => G_HOLD_MAX
      )
      port map (
         clk_i               => hr_clk_i,
         rst_i               => hr_rst,
         avm_write_i         => hr_write,
         avm_read_i          => hr_read,
         avm_address_i       => hr_address(C_MEM_BITS-1 downto 0),
         avm_writedata_i     => hr_writedata,
         avm_byteenable_i    => hr_byteenable,
         avm_burstcount_i    => hr_burstcount,
         avm_readdata_o      => hr_readdata,
         avm_readdatavalid_o => hr_readdatavalid,
         avm_waitrequest_o   => hr_waitrequest,
         state_o             => hr_state,
         viol_o              => hr_viol
      );

   p_mon : process (hr_clk_i)
   begin
      if rising_edge(hr_clk_i) then
         if hr_write = '1' and hr_waitrequest = '0' then
            mon_wr_count <= mon_wr_count + 1;
            mon_wr_addr  <= hr_address;
            mon_wr_data  <= hr_writedata;
            mon_wr_be    <= hr_byteenable;
            mon_wr_burst <= hr_burstcount;
         end if;
         if hr_read = '1' and hr_waitrequest = '0' then
            mon_rd_count <= mon_rd_count + 1;
            mon_rd_addr  <= hr_address;
            mon_rd_burst <= hr_burstcount;
         end if;
         if (hr_write = '1' or hr_read = '1') and hr_waitrequest = '0' and
            unsigned(hr_address(31 downto C_MEM_BITS)) /= 0 then
            mon_bad_hi <= mon_bad_hi + 1;
         end if;
         if hr_write = '1' and hr_read = '1' then
            mon_both <= mon_both + 1;
         end if;
         if hr_readdatavalid = '1' then
            mon_beats <= mon_beats + 1;
         end if;
      end if;
   end process;

   ---------------------------------------------------------------------------
   -- hang report: the cache's registers (only exist with G_CACHE)
   ---------------------------------------------------------------------------
   gen_dbg_cache : if G_CACHE generate
      p_dbg : process
         alias c_count  is <<signal ^.i_dut.gen_cache.i_cache.cache_count   : natural range 0 to 8>>;
         alias c_burst  is <<signal ^.i_dut.gen_cache.i_cache.rd_burstcount : std_logic_vector(7 downto 0)>>;
         alias c_addr   is <<signal ^.i_dut.gen_cache.i_cache.cache_addr    : std_logic_vector(31 downto 0)>>;
         alias c_swait  is <<signal ^.i_dut.c_waitrequest : std_logic>>;   -- the cache's s_avm_waitrequest_o
         alias c_sread  is <<signal ^.i_dut.c_read        : std_logic>>;   -- the read the cache is offered
         alias c_pend   is <<signal ^.i_dut.c_pending     : std_logic>>;
         variable guess : string(1 to 10);
      begin
         wait on dump_trig;
         -- the cache's m_avm_read_o / m_avm_write_o are the harness's hr_read / hr_write
         if c_count = 8 then
            guess := "IDLE_ST   ";
         elsif c_burst /= x"00" or (c_count > 0 and c_count < 8) or hr_read = '1' then
            guess := "READING_ST";
         else
            guess := "IDLE_ST   ";
         end if;
         report "MBT [" & G_NAME & "] HANG avm_cache: state~" & guess & " cache_count=" & integer'image(c_count) &
                " rd_burstcount=" & to_hstring(c_burst) & " cache_addr=" & to_hstring(c_addr) &
                " m_read=" & to_string(hr_read) & " m_write=" & to_string(hr_write) &
                " s_read(offered)=" & to_string(c_sread) & " s_waitrequest=" & to_string(c_swait) &
                " backend c_pending=" & to_string(c_pend)
                severity note;
      end process;
   end generate gen_dbg_cache;

   ---------------------------------------------------------------------------
   -- byte-bus master, reference model and checks
   ---------------------------------------------------------------------------
   p_main : process
      -- DUT internals for the hang report
      alias d_out_count    is <<signal i_dut.out_count      : natural range 0 to 8>>;
      alias d_s_wait       is <<signal i_dut.s_waitrequest  : std_logic>>;
      alias d_s_rdv        is <<signal i_dut.s_readdatavalid: std_logic>>;
      alias d_m_read       is <<signal i_dut.m_read         : std_logic>>;
      alias d_m_write      is <<signal i_dut.m_write        : std_logic>>;
      alias d_m_wait       is <<signal i_dut.m_waitrequest  : std_logic>>;
      alias d_m_rdv        is <<signal i_dut.m_readdatavalid: std_logic>>;
      alias d_fifo_m_valid is <<signal i_dut.i_fifo.m_wr_fifo_valid : std_logic>>;
      alias d_fifo_m_ready is <<signal i_dut.i_fifo.m_wr_fifo_ready : std_logic>>;
      alias d_fifo_s_ready is <<signal i_dut.i_fifo.s_wr_fifo_ready : std_logic>>;

      -- address map helpers
      function is_rom(a : natural) return boolean is
      begin
         return (a >= 16#C0000# and a < 16#C4000#) or
                (a >= 16#EC000# and a < 16#F0000#) or
                (a >= 16#F0000# and a < 16#100000#);
      end function;

      function is_hyper(a : natural) return boolean is
      begin
         return a < 16#A0000# or (a >= 16#C4000# and a < 16#D0000#) or a >= 16#200000#;
      end function;

      -- mirrors the DUT's decode: BIOS and EGA on the low 6 index bits, XT-IDE on the full index
      function rom_base(idx : natural) return natural is
      begin
         if idx mod 64 = 0 then
            return 16#F0000#;
         elsif idx = 2 then
            return 16#EC000#;
         elsif idx mod 64 = 3 then
            return 16#C0000#;
         else
            return 16#100000#;   -- no ROM window: outside the reference array's mapped ranges
         end if;
      end function;

      -- deterministic ROM word pattern
      function rom_pat(idx : natural; a : natural) return natural is
         variable w : natural;
      begin
         w := ((a / 2) * 37 + idx * 4369 + 4660) mod 65536;
         w := to_integer(to_unsigned(w, 16) xor to_unsigned(((a / 2) mod 256) * 256, 16));
         return w;
      end function;

      function hx(v : natural; digits : natural) return string is
      begin
         return to_hstring(to_unsigned(v, digits * 4));
      end function;

      -- reference: -1 = unknown (ROM block RAM never written reads 'U' in simulation)
      type ref_t is array (0 to 2**22 - 1) of integer range -1 to 255;
      variable ref : ref_t;

      -- outstanding-read queue (in issue order)
      type exp_t is record
         addr  : natural;
         data  : integer;
         issue : natural;
      end record;
      type exp_q_t is array (0 to 255) of exp_t;
      variable exp_q    : exp_q_t;
      variable exp_head : natural := 0;
      variable exp_tail : natural := 0;

      variable cyc            : natural := 0;
      variable checks         : natural := 0;
      variable errors         : natural := 0;
      variable hangs          : natural := 0;
      variable last_done_edge : natural := 0;   -- edge at which the newest readdatavalid was sampled
      variable last_accept    : natural := 0;   -- edge at which the newest request was accepted
      variable accepted       : boolean := false;
      variable lat_en         : boolean := false;
      variable lat_sum        : natural := 0;
      variable lat_n          : natural := 0;
      variable lat_min        : natural := 0;
      variable lat_max        : natural := 0;
      variable wr_seen        : natural := 0;   -- HyperRAM writes expected so far
      variable rd_seen        : natural := 0;
      variable seed1          : positive := G_SEED;
      variable seed2          : positive := G_SEED * 7919 + 13;
      variable hyper_writes   : natural := 0;
      variable hyper_reads    : natural := 0;
      variable r              : real;
      variable n, k, a, d     : natural;
      variable idx0, idx1     : natural;
      variable c_w, c_r       : natural;
      variable e0             : natural;

      procedure msg(s : string) is
      begin
         report "MBT [" & G_NAME & "] " & s severity note;
      end procedure;

      procedure check(cond : boolean; s : string) is
      begin
         checks := checks + 1;
         if not cond then
            errors := errors + 1;
            report "MBT [" & G_NAME & "] FAIL @" & integer'image(cyc) & ": " & s severity error;
         end if;
      end procedure;

      procedure rnd(lo : natural; hi : natural; v : out natural) is
         variable x : natural;
      begin
         uniform(seed1, seed2, r);
         x := lo + natural(trunc(r * real(hi - lo + 1)));
         if x > hi then x := hi; end if;
         v := x;
      end procedure;

      -- one byte-bus clock; samples readdatavalid exactly as the master would
      procedure tick is
         variable e   : exp_t;
         variable lat : natural;
      begin
         wait until rising_edge(clk_i);
         cyc := cyc + 1;
         if avm_readdatavalid = '1' then
            if exp_tail = exp_head then
               check(false, "readdatavalid with no read outstanding, data " & to_hstring(avm_readdata));
            else
               e := exp_q(exp_head mod 256);
               exp_head := exp_head + 1;
               lat := cyc - e.issue;
               if G_TRACE then
                  msg("trace @" & integer'image(cyc) & " rdv " & to_hstring(avm_readdata) & " for " & hx(e.addr, 6) &
                      " issued @" & integer'image(e.issue) & " hr_rd=" & integer'image(mon_rd_count) &
                      " beats=" & integer'image(mon_beats));
               end if;
               if e.data >= 0 then
                  check(avm_readdata = std_logic_vector(to_unsigned(e.data, 8)),
                        "read " & hx(e.addr, 6) & " expected " & hx(e.data, 2) & " got " &
                        to_hstring(avm_readdata) & " (issued @" & integer'image(e.issue) &
                        ", latency " & integer'image(lat) & ", " &
                        integer'image(exp_tail - exp_head) & " still outstanding)");
               else
                  checks := checks + 1;
               end if;
               last_done_edge := cyc;
               if lat_en then
                  lat_sum := lat_sum + lat;
                  if lat_n = 0 or lat < lat_min then lat_min := lat; end if;
                  if lat > lat_max then lat_max := lat; end if;
                  lat_n := lat_n + 1;
               end if;
            end if;
         end if;
      end procedure;

      procedure idle(n : natural) is
      begin
         for i in 1 to n loop
            tick;
         end loop;
      end procedure;

      -- the state of everything at the moment of a hang
      procedure hang_dump(why : string) is
      begin
         hangs := hangs + 1;
         msg("HANG @" & integer'image(cyc) & ": " & why);
         msg("HANG byte bus: read=" & to_string(avm_read) & " write=" & to_string(avm_write) & " addr=" &
             to_hstring(avm_address) & " waitrequest=" & to_string(avm_waitrequest) & " rst=" & to_string(rst) &
             " hr_rst=" & to_string(hr_rst) & " reads outstanding in bench=" & integer'image(exp_tail - exp_head) &
             " (oldest " & hx(exp_q(exp_head mod 256).addr, 6) & " issued @" & integer'image(exp_q(exp_head mod 256).issue) & ")");
         msg("HANG backend: out_count=" & integer'image(d_out_count) & " fifo s_ready(=not s_waitrequest)=" &
             to_string(d_fifo_s_ready) & " s_readdatavalid=" & to_string(d_s_rdv) &
             " | hr side: fifo m_valid=" & to_string(d_fifo_m_valid) & " m_ready=" & to_string(d_fifo_m_ready) &
             " m_read=" & to_string(d_m_read) & " m_write=" & to_string(d_m_write) & " m_waitrequest=" &
             to_string(d_m_wait) & " m_readdatavalid=" & to_string(d_m_rdv));
         msg("HANG HyperRAM port: hr_read=" & to_string(hr_read) & " hr_write=" & to_string(hr_write) &
             " hr_waitrequest=" & to_string(hr_waitrequest) & " hr_burstcount=" & to_hstring(hr_burstcount) &
             " model state=" & integer'image(hr_state) & " (0 init 1 idle 2 hold 3 latency 4 rd 5 wr 6 recovery)" &
             " reads accepted=" & integer'image(mon_rd_count) & " beats returned=" & integer'image(mon_beats) &
             " writes accepted=" & integer'image(mon_wr_count));
         dump_trig <= not dump_trig;
         wait for 1 ps;
      end procedure;

      procedure recover is
      begin
         msg("recovering: resetting the DUT, dropping " & integer'image(exp_tail - exp_head) & " outstanding reads");
         avm_read  <= '0';
         avm_write <= '0';
         rst       <= '1';
         hr_rst    <= '1';
         idle(10);
         rst       <= '0';
         hr_rst    <= '0';
         idle(G_INIT_HOLD / 2 + 80);
         exp_head     := exp_tail;
         wr_seen      := mon_wr_count;
         rd_seen      := mon_rd_count;
         hyper_writes := mon_wr_count;   -- accesses still in the FIFO were lost with the reset
         hyper_reads  := mon_rd_count;
      end procedure;

      -- present a write; returns after the edge that accepted it
      procedure bus_write(a : natural; d : natural) is
         variable w : natural := 0;
      begin
         avm_address   <= std_logic_vector(to_unsigned(a, 22));
         avm_writedata <= std_logic_vector(to_unsigned(d, 8));
         avm_write     <= '1';
         accepted := false;
         loop
            tick;
            if avm_waitrequest = '0' then
               accepted := true;
               exit;
            end if;
            w := w + 1;
            if w > C_ACCEPT_TIMEOUT then
               check(false, "write " & hx(a, 6) & " not accepted within " & integer'image(C_ACCEPT_TIMEOUT) & " clocks");
               hang_dump("write " & hx(a, 6) & " never accepted (waitrequest never dropped)");
               recover;
               exit;
            end if;
         end loop;
         avm_write <= '0';
         if accepted then
            last_accept := cyc;
            if is_hyper(a) or is_rom(a) then
               ref(a) := d;
            end if;
            if is_hyper(a) then
               hyper_writes := hyper_writes + 1;
            end if;
         end if;
      end procedure;

      -- present a read; returns after the edge that accepted it, data checked later by tick
      procedure bus_read(a : natural) is
         variable w : natural := 0;
      begin
         avm_address <= std_logic_vector(to_unsigned(a, 22));
         avm_read    <= '1';
         accepted := false;
         loop
            tick;
            if avm_waitrequest = '0' then
               accepted := true;
               exit;
            end if;
            w := w + 1;
            if w > C_ACCEPT_TIMEOUT then
               check(false, "read " & hx(a, 6) & " not accepted within " & integer'image(C_ACCEPT_TIMEOUT) &
                     " clocks (" & integer'image(exp_tail - exp_head) & " reads outstanding)");
               hang_dump("read " & hx(a, 6) & " never accepted (waitrequest never dropped)");
               recover;
               exit;
            end if;
         end loop;
         avm_read <= '0';
         if accepted then
            last_accept := cyc;
            if G_TRACE then
               msg("trace @" & integer'image(cyc) & " read " & hx(a, 6) & " accepted after " & integer'image(w) &
                   " wait clocks, " & integer'image(exp_tail - exp_head) & " outstanding, hr_rd=" &
                   integer'image(mon_rd_count) & " beats=" & integer'image(mon_beats));
            end if;
            exp_q(exp_tail mod 256) := (addr => a, data => ref(a), issue => cyc);
            exp_tail := exp_tail + 1;
            if is_hyper(a) then
               hyper_reads := hyper_reads + 1;
            end if;
         end if;
      end procedure;

      -- wait until every issued read has answered
      procedure wait_done is
         variable w : natural := 0;
      begin
         while exp_head /= exp_tail loop
            tick;
            w := w + 1;
            if w > C_DONE_TIMEOUT then
               check(false, "timeout: " & integer'image(exp_tail - exp_head) & " read(s) never answered, oldest " &
                     hx(exp_q(exp_head mod 256).addr, 6) & " issued @" & integer'image(exp_q(exp_head mod 256).issue));
               hang_dump("read " & hx(exp_q(exp_head mod 256).addr, 6) & " never got its readdatavalid");
               recover;
               exit;
            end if;
         end loop;
      end procedure;

      procedure read_wait(a : natural) is
      begin
         bus_read(a);
         wait_done;
      end procedure;

      -- ROM download port: one word, gap clocks of silence after the pulse
      procedure rom_word(idx : natural; a : natural; w : natural; gap : natural := 2) is
      begin
         rom_index <= std_logic_vector(to_unsigned(idx, 8));
         rom_addr  <= std_logic_vector(to_unsigned(a, 25));
         rom_data  <= std_logic_vector(to_unsigned(w, 16));
         rom_wr    <= '1';
         tick;
         rom_wr    <= '0';
         idle(gap);
         if rom_base(idx) < 16#100000# then
            ref(rom_base(idx) + a)     := w mod 256;
            ref(rom_base(idx) + a + 1) := w / 256;
         end if;
      end procedure;

      -- the newest hyper write must show up on the HyperRAM bus as word a/2 with the right byteenable
      procedure hr_check_write(a : natural; d : natural) is
         variable w : natural := 0;
      begin
         wr_seen := hyper_writes;   -- the write just issued is the newest one on the HyperRAM bus
         while mon_wr_count < wr_seen loop
            tick;
            w := w + 1;
            if w > 1500 then
               check(false, "write " & hx(a, 6) & " never reached the HyperRAM bus");
               hang_dump("write " & hx(a, 6) & " never reached the HyperRAM bus");
               return;
            end if;
         end loop;
         check(mon_wr_count = wr_seen, "write " & hx(a, 6) & ": unexpected extra HyperRAM writes (" &
               integer'image(mon_wr_count) & " vs " & integer'image(wr_seen) & ")");
         check(unsigned(mon_wr_addr) = a / 2, "write " & hx(a, 6) & ": HyperRAM word address " &
               to_hstring(mon_wr_addr) & " expected " & hx(a / 2, 8));
         check(mon_wr_burst = x"01", "write " & hx(a, 6) & ": burstcount " & to_hstring(mon_wr_burst));
         if a mod 2 = 1 then
            check(mon_wr_be = "10", "write " & hx(a, 6) & ": byteenable " & to_string(mon_wr_be) & " expected 10");
            check(mon_wr_data(15 downto 8) = std_logic_vector(to_unsigned(d, 8)),
                  "write " & hx(a, 6) & ": high byte " & to_hstring(mon_wr_data(15 downto 8)) & " expected " & hx(d, 2));
         else
            check(mon_wr_be = "01", "write " & hx(a, 6) & ": byteenable " & to_string(mon_wr_be) & " expected 01");
            check(mon_wr_data(7 downto 0) = std_logic_vector(to_unsigned(d, 8)),
                  "write " & hx(a, 6) & ": low byte " & to_hstring(mon_wr_data(7 downto 0)) & " expected " & hx(d, 2));
         end if;
      end procedure;

      -- without the cache every byte read is exactly one word read on the HyperRAM bus
      procedure hr_check_read(a : natural) is
         variable w : natural := 0;
      begin
         if G_CACHE then
            return;
         end if;
         rd_seen := hyper_reads;    -- the read just issued is the newest one on the HyperRAM bus
         while mon_rd_count < rd_seen loop
            tick;
            w := w + 1;
            if w > 1500 then
               check(false, "read " & hx(a, 6) & " never reached the HyperRAM bus");
               return;
            end if;
         end loop;
         check(mon_rd_count = rd_seen, "read " & hx(a, 6) & ": unexpected extra HyperRAM reads");
         check(unsigned(mon_rd_addr) = a / 2, "read " & hx(a, 6) & ": HyperRAM word address " &
               to_hstring(mon_rd_addr) & " expected " & hx(a / 2, 8));
         check(mon_rd_burst = x"01", "read " & hx(a, 6) & ": burstcount " & to_hstring(mon_rd_burst));
      end procedure;

      procedure write_verify(a : natural; d : natural) is
      begin
         bus_write(a, d);
         hr_check_write(a, d);
         read_wait(a);
         hr_check_read(a);
      end procedure;

      function fmt2(x : real) return string is
         variable i : integer;
      begin
         i := integer(x * 100.0);
         if i mod 100 < 10 then
            return integer'image(i / 100) & ".0" & integer'image(i mod 100);
         else
            return integer'image(i / 100) & "." & integer'image(i mod 100);
         end if;
      end function;

      type nat_arr_t is array (natural range <>) of natural;
      constant C_ROM_IDX  : nat_arr_t := (0, 3, 2);
      constant C_ROM_SIZE : nat_arr_t := (65536, 16384, 16384);
      constant C_HYPER_A  : nat_arr_t := (16#000000#, 16#000001#, 16#000002#, 16#000003#, 16#012344#, 16#012345#,
                                          16#055555#, 16#09FFFE#, 16#09FFFF#,
                                          16#0C4000#, 16#0C4001#, 16#0C8765#, 16#0CFFFE#, 16#0CFFFF#,
                                          16#200000#, 16#200001#, 16#2ABCDE#, 16#2ABCDF#, 16#3FFFFE#, 16#3FFFFF#);
      constant C_NONE_A   : nat_arr_t := (16#0A0000#, 16#0AFFFF#, 16#0B0000#, 16#0BFFFF#, 16#0D0000#, 16#0D8000#,
                                          16#0DFFFF#, 16#100000#, 16#123456#, 16#1FFFFF#);

   begin
      -- reference initial state: HyperRAM model is zero, unmapped reads FF, ROM unknown
      for i in ref'range loop
         if is_hyper(i) then
            ref(i) := 0;
         elsif is_rom(i) then
            ref(i) := -1;
         else
            ref(i) := 255;
         end if;
      end loop;

      msg("start, G_CACHE=" & boolean'image(G_CACHE) & ", model: init hold " & integer'image(G_INIT_HOLD) &
          ", latency " & integer'image(G_LAT_MIN) & ".." & integer'image(G_LAT_MAX) & ", holds up to " &
          integer'image(G_HOLD_MAX) & " hr clocks");

      ------------------------------------------------------------------------
      -- 0. reset ordering between rst_i (byte side) and hr_rst_i (HyperRAM side)
      ------------------------------------------------------------------------
      msg("T0 reset ordering");
      -- (i) byte side out of reset, HyperRAM side still in reset for 200 hr clocks, a write and a read queued
      rst    <= '1';
      hr_rst <= '1';
      idle(10);
      rst    <= '0';
      idle(5);
      e0 := cyc;
      hr_rst <= transport '0' after 100 * 20 ns;   -- hr_rst_i stays high for 200 more HyperRAM clocks
      bus_write(16#00100#, 16#3C#);                -- presented now; the backend may queue it or hold it
      if last_accept < e0 + 100 then
         msg("(i) write accepted @" & integer'image(last_accept) & " while hr_rst_i was still high (queued)");
      else
         msg("(i) write held until hr_rst_i dropped, accepted @" & integer'image(last_accept));
      end if;
      bus_read(16#00100#);
      wait_done;                     -- a lost read shows up here as a hang
      read_wait(16#00100#);          -- and the write must have landed
      -- (ii) a request arriving 0..5 byte clocks before / after the edge where hr_rst_i drops
      for k in 0 to 5 loop
         hr_rst <= '1';
         idle(20);
         hr_rst <= transport '0' after k * 20 ns;
         bus_read(16#00200# + k);
         wait_done;
      end loop;
      for k in 0 to 5 loop
         hr_rst <= '1';
         idle(20);
         hr_rst <= '0';
         idle(k);
         bus_read(16#00300# + k);
         wait_done;
      end loop;
      -- (iii) HyperRAM side reset while a read is in flight, byte side not reset (reset button:
      -- hr_rst_i follows reset_core_n, rst_i only follows the clock lock); the read can never be
      -- answered, but afterwards the backend must serve the (also reset) CPU again
      bus_read(16#00400#);
      idle(2);
      hr_rst <= '1';
      idle(20);
      hr_rst <= '0';
      exp_head := exp_tail;          -- nobody expects that read any more
      idle(G_INIT_HOLD / 2 + 20);
      read_wait(16#F0000#);          -- ROM read: held for ever if out_count still counts the lost read
      read_wait(16#00400#);
      check(exp_head = exp_tail, "(iii) reads outstanding after the HyperRAM-side reset");
      hyper_reads  := mon_rd_count;  -- the in-flight read was dropped on purpose: resync the bus counters
      hyper_writes := mon_wr_count;

      ------------------------------------------------------------------------
      -- 1. ROM port and ROM windows
      ------------------------------------------------------------------------
      msg("T1 ROM port");
      for i in C_ROM_IDX'range loop
         idx0 := C_ROM_IDX(i);
         n    := C_ROM_SIZE(i);
         -- first and last words, some in the middle; last few with the minimum 2-clock spacing
         for w in 0 to 7 loop
            rom_word(idx0, 2 * w, rom_pat(idx0, 2 * w));
         end loop;
         for w in 0 to 7 loop
            rom_word(idx0, n / 2 - 8 + 2 * w, rom_pat(idx0, n / 2 - 8 + 2 * w));
         end loop;
         rom_word(idx0, 16#1000#, rom_pat(idx0, 16#1000#));
         rom_word(idx0, 16#2AAA#, rom_pat(idx0, 16#2AAA#));
         rom_word(idx0, 16#3FF0#, rom_pat(idx0, 16#3FF0#));
         for w in 0 to 7 loop
            rom_word(idx0, n - 16 + 2 * w, rom_pat(idx0, n - 16 + 2 * w), 1);
         end loop;
      end loop;
      -- index 0 is also matched on the low 6 bits only (rom_idx(5 downto 0) = 0): index 0x40 -> BIOS
      rom_word(16#40#, 16#0200#, 16#BEEF#);
      -- and an index that is no ROM at all must land nowhere
      rom_word(16#05#, 16#0300#, 16#DEAD#);
      idle(4);

      -- read everything written back, byte-wise, back to back
      for i in C_ROM_IDX'range loop
         idx0 := C_ROM_IDX(i);
         n    := C_ROM_SIZE(i);
         for b in 0 to 15 loop
            bus_read(rom_base(idx0) + b);
         end loop;
         for b in 0 to 15 loop
            bus_read(rom_base(idx0) + n / 2 - 8 + b);
         end loop;
         wait_done;
         for b in 0 to 1 loop
            bus_read(rom_base(idx0) + 16#1000# + b);
            bus_read(rom_base(idx0) + 16#2AAA# + b);
            bus_read(rom_base(idx0) + 16#3FF0# + b);
         end loop;
         for b in 0 to 15 loop
            bus_read(rom_base(idx0) + n - 16 + b);
         end loop;
         wait_done;
      end loop;
      read_wait(16#F0200#);
      read_wait(16#F0201#);
      -- index 5 must not have touched F0300 / EC300 / C0300 (all still unwritten, or hold the pattern)
      bus_write(16#F0300#, 16#01#);
      bus_write(16#EC300#, 16#02#);
      bus_write(16#C0300#, 16#03#);
      rom_word(16#05#, 16#0300#, 16#DEAD#);
      read_wait(16#F0300#);
      read_wait(16#EC300#);
      read_wait(16#C0300#);
      c_w := mon_wr_count;
      c_r := mon_rd_count;

      -- Avalon writes into the ROM windows land (the chipset protects the ROMs, not the backend)
      bus_write(16#F0010#, 16#5A#);
      bus_write(16#F0011#, 16#A5#);
      bus_write(16#FFFFF#, 16#C3#);
      bus_write(16#EC000#, 16#11#);
      bus_write(16#EFFFF#, 16#22#);
      bus_write(16#C0000#, 16#33#);
      bus_write(16#C3FFF#, 16#44#);
      bus_read(16#F0010#);
      bus_read(16#F0011#);
      bus_read(16#FFFFF#);
      bus_read(16#EC000#);
      bus_read(16#EFFFF#);
      bus_read(16#C0000#);
      bus_read(16#C3FFF#);
      bus_read(16#F0012#);   -- neighbour untouched
      wait_done;
      idle(40);
      check(mon_wr_count = c_w and mon_rd_count = c_r, "ROM accesses must not reach the HyperRAM bus");
      -- ROM read latency is one clock
      read_wait(16#F0000#);
      check(last_done_edge - last_accept = 1, "ROM read latency " & integer'image(last_done_edge - last_accept) & " expected 1");

      ------------------------------------------------------------------------
      -- 2. HyperRAM regions
      ------------------------------------------------------------------------
      msg("T2 HyperRAM regions");
      for i in C_HYPER_A'range loop
         a := C_HYPER_A(i);
         d := (a * 13 + 16#42#) mod 256;
         if d = 0 then d := 16#A5#; end if;
         write_verify(a, d);
      end loop;
      -- both halves of a word written separately, then read as the right bytes
      bus_write(16#01000#, 16#12#);
      hr_check_write(16#01000#, 16#12#);
      bus_write(16#01001#, 16#34#);
      hr_check_write(16#01001#, 16#34#);
      read_wait(16#01000#);
      read_wait(16#01001#);
      -- a byte write must not clobber its neighbour (byteenable honoured end to end)
      bus_write(16#02000#, 16#AA#);
      bus_write(16#02001#, 16#BB#);
      bus_write(16#02000#, 16#CC#);
      idle(30);
      read_wait(16#02001#);
      read_wait(16#02000#);
      bus_write(16#02001#, 16#DD#);
      idle(30);
      read_wait(16#02000#);
      read_wait(16#02001#);
      -- same in the EMS window and the UMB
      bus_write(16#3FFFFE#, 16#01#);
      bus_write(16#3FFFFF#, 16#02#);
      bus_write(16#3FFFFE#, 16#03#);
      idle(30);
      read_wait(16#3FFFFF#);
      read_wait(16#3FFFFE#);
      bus_write(16#0C4000#, 16#E1#);
      bus_write(16#0C4001#, 16#E2#);
      idle(30);
      read_wait(16#0C4001#);
      read_wait(16#0C4000#);
      -- edges of the regions: the byte next to each region end is unmapped / another region
      bus_write(16#09FFFF#, 16#77#);
      idle(30);
      read_wait(16#0A0000#);   -- unmapped: FF
      read_wait(16#09FFFF#);
      bus_write(16#0C3FFF#, 16#66#);  -- EGA ROM byte just below the UMB
      read_wait(16#0C3FFF#);
      read_wait(16#0C4000#);
      idle(10);
      check(mon_bad_hi = 0, "HyperRAM address bits above the model set " & integer'image(mon_bad_hi) & " times");

      ------------------------------------------------------------------------
      -- 3. ordering
      ------------------------------------------------------------------------
      msg("T3 ordering");
      -- (a) HyperRAM read then ROM read: ROM read held until the HyperRAM data is back, data in order
      bus_write(16#01234#, 16#5A#);
      hr_check_write(16#01234#, 16#5A#);
      for rep in 0 to 2 loop
         bus_read(16#01234# + rep);
         e0 := cyc;
         bus_read(16#F0000# + rep);
         check(accepted and exp_head = exp_tail - 1,
               "(a) ROM read accepted @" & integer'image(cyc) & " while the HyperRAM read issued @" & integer'image(e0) & " was still outstanding");
         check(last_done_edge < last_accept,
               "(a) ROM read accepted at the same edge as the HyperRAM data (" & integer'image(last_accept) & ")");
         wait_done;
      end loop;
      -- HyperRAM read then ROM write: held as well
      bus_read(16#01235#);
      e0 := cyc;
      bus_write(16#F0020#, 16#99#);
      check(accepted and exp_head = exp_tail and last_done_edge < last_accept,
            "(a) ROM write accepted @" & integer'image(last_accept) & " before the HyperRAM read issued @" & integer'image(e0) & " answered @" & integer'image(last_done_edge));
      read_wait(16#F0020#);
      -- HyperRAM read then unmapped read: held as well
      bus_read(16#01236#);
      e0 := cyc;
      bus_read(16#0A0000#);
      check(accepted and exp_head = exp_tail - 1 and last_done_edge < last_accept,
            "(a) unmapped read accepted @" & integer'image(last_accept) & " before the HyperRAM read issued @" & integer'image(e0) & " answered");
      wait_done;
      -- ROM read then HyperRAM read: nothing held, still in order
      bus_read(16#F0001#);
      bus_read(16#01234#);
      wait_done;
      -- HyperRAM read then HyperRAM write: write accepted while the read is outstanding, then read new data
      bus_read(16#01234#);
      bus_write(16#01234#, 16#A6#);
      check(exp_head = exp_tail - 1, "(a) HyperRAM write must not wait for an outstanding HyperRAM read");
      wait_done;
      read_wait(16#01234#);

      -- (b) two back-to-back HyperRAM reads (the KFSDRAM 2-beat pattern), in order
      bus_write(16#03000#, 16#10#);
      bus_write(16#03001#, 16#11#);
      bus_write(16#03002#, 16#12#);
      bus_write(16#03003#, 16#13#);
      bus_write(16#04000#, 16#40#);
      bus_write(16#200010#, 16#50#);
      idle(40);
      for rep in 0 to 1 loop
         bus_read(16#03000#); bus_read(16#03001#); wait_done;   -- same word, even then odd
         bus_read(16#03001#); bus_read(16#03000#); wait_done;   -- same word, odd then even
         bus_read(16#03000#); bus_read(16#03002#); wait_done;   -- adjacent words
         bus_read(16#03003#); bus_read(16#03000#); wait_done;   -- backwards
         bus_read(16#04000#); bus_read(16#200010#); wait_done;  -- far apart
         bus_read(16#03000#); bus_read(16#03000#); wait_done;   -- the very same byte
         bus_read(16#03002#); bus_read(16#03003#); idle(2); bus_read(16#03001#); wait_done;
         bus_read(16#03000#); bus_read(16#03001#); bus_read(16#03002#); bus_read(16#03003#); wait_done;
      end loop;
      -- 2-beat read pairs to unwritten words too (0 in the model)
      bus_read(16#06000#); bus_read(16#06001#); wait_done;
      bus_read(16#06002#); bus_read(16#06003#); wait_done;

      -- (c) write then read of the same byte returns the new value
      bus_write(16#05000#, 16#77#);
      bus_read(16#05000#);
      wait_done;
      -- fill the cache line with 05000-0500F, then write inside and outside it
      for b in 0 to 15 loop
         read_wait(16#05000# + b);
      end loop;
      bus_write(16#05003#, 16#99#);
      bus_read(16#05003#);
      wait_done;
      bus_write(16#05002#, 16#98#);
      read_wait(16#05002#);
      read_wait(16#05003#);
      bus_write(16#05010#, 16#97#);
      read_wait(16#05010#);
      bus_write(16#05000#, 16#96#);
      bus_write(16#05001#, 16#95#);
      bus_read(16#05000#);
      bus_read(16#05001#);
      wait_done;
      -- write while a read of the same byte is outstanding: the read returns the old value
      bus_read(16#05010#);
      bus_write(16#05010#, 16#94#);
      wait_done;
      read_wait(16#05010#);

      -- (d) unmapped addresses: FF, writes ignored, no HyperRAM traffic, same ordering rule
      c_w := mon_wr_count;
      c_r := mon_rd_count;
      for i in C_NONE_A'range loop
         bus_write(C_NONE_A(i), 16#11#);
         read_wait(C_NONE_A(i));
         check(last_done_edge - last_accept = 1, "(d) unmapped read latency " & integer'image(last_done_edge - last_accept) & " expected 1");
      end loop;
      for i in C_NONE_A'range loop
         bus_read(C_NONE_A(i));
      end loop;
      wait_done;
      idle(40);
      check(mon_wr_count = c_w and mon_rd_count = c_r, "(d) unmapped accesses reached the HyperRAM bus");
      -- unmapped read then HyperRAM read then unmapped read: in order, the last one held
      bus_read(16#0A0000#);
      bus_read(16#03001#);
      e0 := cyc;
      bus_read(16#0D0000#);
      check(accepted and exp_head = exp_tail - 1 and last_done_edge < last_accept,
            "(d) unmapped read accepted @" & integer'image(last_accept) & " before the HyperRAM read issued @" & integer'image(e0) & " answered");
      wait_done;

      ------------------------------------------------------------------------
      -- 4. sequential fetch, latency
      ------------------------------------------------------------------------
      msg("T4 sequential fetch");
      for b in 0 to 63 loop
         bus_write(16#08000# + b, (b * 5 + 16#30#) mod 256);
      end loop;
      idle(200);
      wr_seen := mon_wr_count;
      lat_en  := true;
      lat_sum := 0; lat_n := 0; lat_min := 0; lat_max := 0;
      for b in 0 to 63 loop
         read_wait(16#08000# + b);
      end loop;
      lat_en := false;
      check(lat_n = 64, "sequential: " & integer'image(lat_n) & " answers for 64 reads");
      seq_lat_o <= real(lat_sum) / real(lat_n);
      seq_min_o <= lat_min;
      seq_max_o <= lat_max;
      msg("sequential 64-byte fetch: average latency " & fmt2(real(lat_sum) / real(lat_n)) &
          " byte-bus clocks (min " & integer'image(lat_min) & ", max " & integer'image(lat_max) & "), " &
          integer'image(mon_rd_count - c_r) & " HyperRAM read commands since T3");
      -- the same again, this time the sequence crosses the end of conventional memory and is issued 2 at a time
      for b in 0 to 31 loop
         bus_write(16#09FFE0# + b, (b * 3 + 16#80#) mod 256);
      end loop;
      idle(200);
      for b in 0 to 15 loop
         bus_read(16#09FFE0# + 2 * b);
         bus_read(16#09FFE1# + 2 * b);
         wait_done;
      end loop;
      -- sequential fetch straight through a ROM boundary: C3FF0.. (ROM) into C4000.. (HyperRAM)
      for b in 0 to 15 loop
         bus_write(16#0C3FF0# + b, 16#C0# + b);
         bus_write(16#0C4000# + b, 16#D0# + b);
      end loop;
      idle(100);
      for b in 0 to 31 loop
         read_wait(16#0C3FF0# + b);
      end loop;

      ------------------------------------------------------------------------
      -- 5. random traffic against the reference array
      ------------------------------------------------------------------------
      msg("T5 random traffic, " & integer'image(G_RANDOM_OPS) & " operations");
      -- give the random ROM reads something known: 256 words at the start of each ROM
      for i in C_ROM_IDX'range loop
         for w in 0 to 255 loop
            rom_word(C_ROM_IDX(i), 2 * w, rom_pat(C_ROM_IDX(i), 2 * w), 1);
         end loop;
      end loop;
      for op in 1 to G_RANDOM_OPS loop
         -- region
         rnd(0, 99, k);
         if k < 40 then
            rnd(0, 16#9FFFF#, a);
         elsif k < 50 then
            rnd(16#C4000#, 16#CFFFF#, a);
         elsif k < 62 then
            rnd(16#200000#, 16#3FFFFF#, a);
         elsif k < 70 then
            rnd(0, 16#1FF#, a);                    -- hot spot: reuse the same bytes a lot
            a := a + 16#7000#;
         elsif k < 85 then
            rnd(0, 2, idx1);
            rnd(0, 16#3FF#, a);
            if idx1 = 0 then rnd(0, 16#FFFF#, n); else rnd(0, 16#3FFF#, n); end if;
            if k < 78 then a := rom_base(C_ROM_IDX(idx1)) + a; else a := rom_base(C_ROM_IDX(idx1)) + n; end if;
         else
            rnd(0, 2, idx1);
            if idx1 = 0 then rnd(16#A0000#, 16#BFFFF#, a);
            elsif idx1 = 1 then rnd(16#D0000#, 16#DFFFF#, a);
            else rnd(16#100000#, 16#1FFFFF#, a); end if;
         end if;
         -- operation
         rnd(0, 99, k);
         if k < 45 then
            rnd(0, 255, d);
            bus_write(a, d);
         elsif k < 92 then
            -- like KFSDRAM: at most two reads in flight
            n := 0;
            while exp_tail - exp_head >= 2 and n < C_DONE_TIMEOUT loop
               tick;
               n := n + 1;
            end loop;
            if n >= C_DONE_TIMEOUT then
               check(false, "random: reads never drain");
               hang_dump("random: outstanding reads never drain");
               recover;
            end if;
            bus_read(a);
         else
            -- burst of 2..4 consecutive bytes back to back, from an empty pipe
            wait_done;
            rnd(2, 4, n);
            if a + n > 16#3FFFFF# then a := 16#3FFFF0#; end if;
            for b in 0 to n - 1 loop
               bus_read(a + b);
            end loop;
         end if;
         -- gap
         rnd(0, 99, k);
         if k < 70 then
            rnd(0, 2, n);
         elsif k < 97 then
            rnd(3, 12, n);
         else
            rnd(20, 60, n);
         end if;
         idle(n);
      end loop;
      wait_done;
      idle(400);
      check(mon_wr_count = hyper_writes, "HyperRAM write count " & integer'image(mon_wr_count) &
            " expected " & integer'image(hyper_writes) & " (every byte write in a mapped non-ROM range, once)");
      check(mon_bad_hi = 0, "HyperRAM address bits above the model set " & integer'image(mon_bad_hi) & " times");
      check(mon_both = 0, "HyperRAM read and write asserted together " & integer'image(mon_both) & " times");
      check(hr_viol = 0, "HyperRAM model saw " & integer'image(hr_viol) & " Avalon rule violations");
      check(exp_head = exp_tail, "reads still outstanding at the end");

      -- pass on the totals
      msg("done: " & integer'image(checks) & " checks, " & integer'image(errors) & " errors, " &
          integer'image(hangs) & " hangs");
      checks_o <= checks;
      errors_o <= errors;
      hangs_o  <= hangs;
      done_o   <= true;
      wait;
   end process p_main;

end architecture sim;


-------------------------------------------------------------------------------------------------------------
-- top: clocks, the two harnesses, the verdict
-------------------------------------------------------------------------------------------------------------
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use std.env.all;

entity mem_backend_tb is
   generic (
      G_SEED : positive := 1        -- xelab -generic_top "G_SEED=n" for another random run
   );
end entity mem_backend_tb;

architecture sim of mem_backend_tb is
   signal clk       : std_logic := '0';
   signal hr_clk    : std_logic := '0';
   signal done_c    : boolean;
   signal done_n    : boolean;
   signal checks_c  : natural;
   signal checks_n  : natural;
   signal errors_c  : natural;
   signal errors_n  : natural;
   signal hangs_c   : natural;
   signal hangs_n   : natural;
   signal lat_c     : real;
   signal lat_n     : real;
   signal min_c, max_c, min_n, max_n : natural;

   function fmt2(x : real) return string is
      variable i : integer;
   begin
      i := integer(x * 100.0);
      if i mod 100 < 10 then
         return integer'image(i / 100) & ".0" & integer'image(i mod 100);
      else
         return integer'image(i / 100) & "." & integer'image(i mod 100);
      end if;
   end function;
begin

   clk <= not clk after 10 ns;              -- 50 MHz byte bus

   p_hr_clk : process                       -- 100 MHz, unrelated phase
   begin
      wait for 3.3 ns;
      loop
         hr_clk <= '1';
         wait for 5 ns;
         hr_clk <= '0';
         wait for 5 ns;
      end loop;
   end process;

   i_cache : entity work.mem_backend_harness
      generic map (G_NAME => "cache", G_CACHE => true, G_SEED => 11 * G_SEED)
      port map (clk_i => clk, hr_clk_i => hr_clk, done_o => done_c, checks_o => checks_c, errors_o => errors_c,
                hangs_o => hangs_c, seq_lat_o => lat_c, seq_min_o => min_c, seq_max_o => max_c);

   i_nocache : entity work.mem_backend_harness
      generic map (G_NAME => "nocache", G_CACHE => false, G_SEED => 23 * G_SEED)
      port map (clk_i => clk, hr_clk_i => hr_clk, done_o => done_n, checks_o => checks_n, errors_o => errors_n,
                hangs_o => hangs_n, seq_lat_o => lat_n, seq_min_o => min_n, seq_max_o => max_n);

   p_final : process
   begin
      wait until done_c and done_n;
      wait for 1 us;
      report "MBT LATENCY sequential 64-byte fetch, byte-bus clocks acceptance->readdatavalid: cache avg " &
             fmt2(lat_c) & " (min " & integer'image(min_c) & " max " & integer'image(max_c) & "), nocache avg " &
             fmt2(lat_n) & " (min " & integer'image(min_n) & " max " & integer'image(max_n) & ")" severity note;
      report "MBT SUMMARY cache: " & integer'image(checks_c) & " checks, " & integer'image(errors_c) &
             " errors, " & integer'image(hangs_c) & " hangs; nocache: " & integer'image(checks_n) & " checks, " &
             integer'image(errors_n) & " errors, " & integer'image(hangs_n) & " hangs" severity note;
      if errors_c + errors_n = 0 then
         report "MBT RESULT: PASS checks=" & integer'image(checks_c + checks_n) & " errors=0" severity note;
      else
         report "MBT RESULT: FAIL checks=" & integer'image(checks_c + checks_n) & " errors=" &
                integer'image(errors_c + errors_n) severity note;
      end if;
      finish;
   end process;

   p_watchdog : process
   begin
      wait for 400 ms;
      report "MBT RESULT: FAIL watchdog: simulation did not finish (cache done=" & boolean'image(done_c) &
             ", nocache done=" & boolean'image(done_n) & ")" severity note;
      finish;
   end process;

end architecture sim;
