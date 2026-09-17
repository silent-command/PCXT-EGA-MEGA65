-------------------------------------------------------------------------------------------------------------
-- PCXT-EGA on MiSTer2MEGA65: memory backend for the byte-wide Avalon bus
-- (Phase 6: HyperRAM behind everything that is not a ROM window)
--
-- Slave for the bus that CORE/rtl/overlay/KFSDRAM.sv drives on the chipset's
-- SDRAM pins: 22-bit byte address, 8-bit data, single beat, waitrequest,
-- readdatavalid (in order, any number of reads outstanding).
--
-- Map (the RAM.sv decoder only ever presents these ranges, see
-- docs/emu-signal-map.md 3.7):
--   000000-09FFFF  640 KB conventional RAM     HyperRAM
--   0C0000-0C3FFF   16 KB EGA BIOS              block RAM, ROM-written
--   0C4000-0CFFFF   48 KB UMB                   HyperRAM
--   0D0000-0DFFFF   64 KB EMS page frame        (never presented: the chipset
--                                               maps it to the pages below)
--   0E0000-0FFFFF  128 KB system BIOS window    block RAM, ROM-written (pcxt.rom)
--   0EC000-0EFFFF   16 KB XT-IDE BIOS           block RAM, ROM-written (xtide.rom, if loaded:
--                                               it wins over pcxt.rom in this range)
--   200000-3FFFFF    2 MB EMS pages             HyperRAM
--   anything else reads FF and ignores writes.
--
-- pcxt.rom placement: the image is stored by file offset (bios_ram(0) = file
-- byte 0) and placed so that its last byte sits at FFFFF: a 64 KB file at
-- F0000, 32 KB at F8000, 96 KB at E8000, 128 KB at E0000 (a longer file is
-- cut to its first 128 KB). The firmware streams the file without telling the
-- device its size, so the size is the highest word offset written so far plus
-- one word; a write of word 0 starts a new image. One exception mirrors what
-- MiSTer does with the 128 KB flash images of skiselev/8088_bios (XTIDE at
-- offset 0, BIOS body at A000-FFFF, upper half all FF): a 128 KB image whose
-- upper half holds nothing but FFFF words is treated as the 64 KB image in
-- its lower half, i.e. file byte 0 lands at F0000 and E0000-EFFFF read FF.
-- Bytes of the window below the image read FF. The window is read-only on
-- the Avalon side: the core's loader FSM writes each word a second time at
-- F0000 + file offset, which is the wrong place for anything but a 64 KB
-- image, and the chipset (RAM.sv write_protect) never lets CPU writes through
-- anyway. The EGA and XT-IDE windows keep accepting Avalon writes as before.
--
-- HyperRAM: word (16-bit) addressed, 4 M words. The framework's scaler owns
-- the bottom (RAMBASE 0, 2 MB for 720x576), so the PC lives at word
-- G_HR_BASE = 0x200000 (byte 4 MB): word = G_HR_BASE + byte_address/2,
-- which places the EMS pages at words 0x300000-0x3FFFFF, the top of the
-- 8 MB. Byte writes use byteenable; reads fetch the word and pick the byte.
-- The Avalon master lives in the HyperRAM clock; the framework's avm_fifo
-- does the clock crossing and an avm_cache line in front of the HyperRAM
-- serves the 8088's sequential fetches.
--
-- Ordering: block-RAM reads answer one clock after acceptance, HyperRAM reads
-- much later, so a block-RAM access is held off (waitrequest) while any
-- HyperRAM read is outstanding. HyperRAM accesses are never held off by the
-- ROM side; the FIFO applies its own back-pressure.
--
-- Resets: rst_i (clock lock) and hr_rst_i (framework, also on the reset
-- button) are independent. hr_rst_i is synchronised into clk_i and resets the
-- byte side too (out_count, the command FIFO, acceptance), because the cache,
-- arbiter and controller forget every transaction when they reset; nothing is
-- offered to the cache while hr_rst_i is high.
--
-- ROM port: as in mem_bram.vhd, the BIOS images are written here directly
-- from rom_loader.vhd (the core's own loader FSM drops the odd word). Each
-- window takes the first bytes of its file (128 KB / 16 KB / 16 KB); words
-- beyond that are dropped instead of wrapping.
--
-- MiSTer2MEGA65 done by sy2002 and MJoergen in 2022 and licensed under GPL v3
-------------------------------------------------------------------------------------------------------------

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity mem_backend is
   generic (
      G_HR_BASE           : unsigned(31 downto 0) := x"00200000";  -- HyperRAM word address of XT byte 0
      G_CACHE             : boolean := true;                     -- avm_cache line in front of the HyperRAM
      G_CACHE_SIZE        : natural := 8;                        -- words per line
      G_BIST              : boolean := true                      -- HyperRAM self test after reset (the bench turns it off)
   );
   port (
      clk_i               : in  std_logic;                       -- chipset clock, byte bus domain
      rst_i               : in  std_logic;

      -- byte-wide Avalon slave (KFSDRAM.sv overlay)
      avm_address_i       : in  std_logic_vector(21 downto 0);
      avm_writedata_i     : in  std_logic_vector(7 downto 0);
      avm_write_i         : in  std_logic;
      avm_read_i          : in  std_logic;
      avm_readdata_o      : out std_logic_vector(7 downto 0);
      avm_readdatavalid_o : out std_logic;
      avm_waitrequest_o   : out std_logic;

      -- ROM download port (rom_loader.vhd, clk_i): index 0 = PC/XT BIOS
      -- (E0000-FFFFF, top-aligned), 2 = XT-IDE at EC000, 3 = EGA BIOS at C0000
      rom_wr_i            : in  std_logic := '0';
      rom_index_i         : in  std_logic_vector(7 downto 0) := (others => '0');
      rom_addr_i          : in  std_logic_vector(24 downto 0) := (others => '0');
      rom_data_i          : in  std_logic_vector(15 downto 0) := (others => '0');

      -- HyperRAM Avalon master (framework hr_core_*), hr_clk_i domain
      hr_clk_i            : in  std_logic;
      hr_rst_i            : in  std_logic;
      hr_write_o          : out std_logic;
      hr_read_o           : out std_logic;
      hr_address_o        : out std_logic_vector(31 downto 0);
      hr_writedata_o      : out std_logic_vector(15 downto 0);
      hr_byteenable_o     : out std_logic_vector(1 downto 0);
      hr_burstcount_o     : out std_logic_vector(7 downto 0);
      hr_readdata_i       : in  std_logic_vector(15 downto 0);
      hr_readdatavalid_i  : in  std_logic;
      hr_waitrequest_i    : in  std_logic;

      -- debug counters (clk_i): HyperRAM reads accepted, read data returned, writes accepted
      dbg_hrd_o           : out std_logic_vector(15 downto 0);
      dbg_hrv_o           : out std_logic_vector(15 downto 0);
      dbg_hwr_o           : out std_logic_vector(15 downto 0)
   );
end entity mem_backend;

architecture rtl of mem_backend is

   ---------------------------------------------------------------------------
   -- ROM windows in block RAM
   ---------------------------------------------------------------------------
   type ram128k_t is array (0 to 131071) of std_logic_vector(7 downto 0);
   type ram16k_t  is array (0 to 16383)  of std_logic_vector(7 downto 0);

   signal ega_ram   : ram16k_t;
   signal xtide_ram : ram16k_t;
   signal bios_ram  : ram128k_t;      -- pcxt.rom by file offset

   attribute ram_style : string;
   attribute ram_style of ega_ram   : signal is "block";
   attribute ram_style of xtide_ram : signal is "block";
   attribute ram_style of bios_ram  : signal is "block";

   signal addr      : unsigned(21 downto 0);
   signal sel_ega   : std_logic;
   signal sel_xtide : std_logic;
   signal sel_bios  : std_logic;
   signal sel_rom   : std_logic;
   signal sel_hyper : std_logic;     -- a valid non-ROM range
   signal sel_none  : std_logic;     -- unmapped: FF, writes ignored

   signal q_ega     : std_logic_vector(7 downto 0);
   signal q_xtide   : std_logic_vector(7 downto 0);
   signal q_bios    : std_logic_vector(7 downto 0);
   signal sel_q     : std_logic_vector(2 downto 0);
   signal none_q    : std_logic;
   signal rom_valid_q : std_logic;

   -- pcxt.rom placement (see header): the image ends at FFFFF
   signal pcxt_last  : unsigned(15 downto 0) := (others => '0');   -- highest word offset written since word 0
   signal pcxt_top   : std_logic := '0';   -- a word other than FFFF was written at file offset >= 64 KB
   signal pcxt_seen  : std_logic := '0';   -- some pcxt.rom word has been written
   signal xtide_seen : std_logic := '0';   -- some xtide.rom word has been written: EC000-EFFFF is its window
   signal bios_base  : unsigned(16 downto 0) := (others => '1');   -- window offset (from E0000) of file byte 0
   signal bios_off   : unsigned(16 downto 0);   -- window offset - bios_base = file offset (read address)
   signal bios_ok    : std_logic;               -- the byte is inside the image
   signal bios_ok_q  : std_logic;

   -- ROM port: two byte writes per word
   signal rom_phase : std_logic_vector(1 downto 0) := "00";
   signal rom_a     : unsigned(16 downto 0) := (others => '0');
   signal rom_d     : std_logic_vector(15 downto 0) := (others => '0');
   signal rom_idx   : std_logic_vector(7 downto 0) := (others => '0');
   signal rom_fits  : std_logic;                -- the word is inside its window's file-size limit
   signal rom_we    : std_logic;
   signal rom_wa    : unsigned(16 downto 0);
   signal rom_wd    : std_logic_vector(7 downto 0);
   signal rom_ega   : std_logic;
   signal rom_xtide : std_logic;
   signal rom_bios  : std_logic;

   signal we_ega, we_xtide, we_bios : std_logic;
   signal wa_ega    : unsigned(13 downto 0);
   signal wa_xtide  : unsigned(13 downto 0);
   signal wa_bios   : unsigned(16 downto 0);
   signal wd_ega, wd_xtide, wd_bios : std_logic_vector(7 downto 0);

   ---------------------------------------------------------------------------
   -- HyperRAM side
   ---------------------------------------------------------------------------
   signal s_write        : std_logic;
   signal s_read         : std_logic;
   signal s_address      : std_logic_vector(31 downto 0);
   signal s_writedata    : std_logic_vector(15 downto 0);
   signal s_byteenable   : std_logic_vector(1 downto 0);
   signal s_readdata     : std_logic_vector(15 downto 0);
   signal s_readdatavalid: std_logic;
   signal s_waitrequest  : std_logic;

   signal m_write        : std_logic;
   signal m_read         : std_logic;
   signal m_address      : std_logic_vector(31 downto 0);
   signal m_writedata    : std_logic_vector(15 downto 0);
   signal m_byteenable   : std_logic_vector(1 downto 0);
   signal m_burstcount   : std_logic_vector(7 downto 0);
   signal m_readdata     : std_logic_vector(15 downto 0);
   signal m_readdatavalid: std_logic;
   signal m_waitrequest  : std_logic;

   -- outstanding HyperRAM reads: which byte of the word each one wants
   constant C_OUT_MAX    : natural := 8;
   signal out_lsb        : std_logic_vector(C_OUT_MAX-1 downto 0) := (others => '0');
   signal out_count      : natural range 0 to C_OUT_MAX := 0;
   signal hyper_busy     : std_logic;

   -- hr_rst_i seen from clk_i: the backend resets as a whole when the HyperRAM
   -- side resets (reset button: hr_rst_i follows reset_core_n, rst_i does not).
   -- Everything the byte side remembers about HyperRAM transactions (out_count,
   -- commands queued in the FIFO) is void once the cache/arbiter/controller
   -- have been reset, and a command handed to the cache while it is in reset
   -- is silently dropped (its waitrequest is 0 in reset), so accept nothing
   -- and drop the queue while either reset is active.
   signal hr_rst_meta    : std_logic := '1';
   signal hr_rst_sync    : std_logic := '1';
   signal rst_all        : std_logic;

   -- Reads that were accepted before rst_all rose can never be answered by
   -- the HyperRAM side (its FIFO, arbiter and controller forget them). The
   -- byte-side master is the chipset's KFSDRAM (CORE/rtl/overlay/KFSDRAM.sv),
   -- which the reset button does NOT reset (RAM.sv/KFSDRAM only see the clock
   -- lock reset, so the ROM presence latches survive a core reset); once it has
   -- had a read accepted it waits for readdatavalid for ever. Leaving out_count
   -- to be cleared silently therefore hangs the CPU on its first RAM access
   -- after the reset - before POST reprograms the EGA, which stays on whatever
   -- the reset left (black or bars). So the outstanding reads are drained with
   -- one dummy beat each (data FF) while the reset is active; the CPU is in
   -- reset at the same time, so the data is never used.
   signal flush_valid    : std_logic := '0';

   -- one read at a time into the cache (G_CACHE only, see gen_cache)
   signal c_read         : std_logic;
   signal c_waitrequest  : std_logic;
   signal c_pending      : std_logic := '0';
   signal f_readdatavalid: std_logic;     -- what the FIFO's read side takes back

   signal hyper_accept   : std_logic;

   -- built-in self test of the HyperRAM path, runs once after reset while the
   -- machine is still held: 3 x 64 bytes at 0x001000 (conventional), 0x0C4000
   -- (UMB) and 0x200000 (EMS page 0), written then read back one at a time.
   type bist_state_t is (B_WAIT, B_WRITE, B_WR_GAP, B_READ, B_RD_WAIT, B_DONE);
   signal bist_state     : bist_state_t := B_WAIT;
   signal bist_wait      : unsigned(15 downto 0) := (others => '0');
   signal bist_idx       : unsigned(7 downto 0) := (others => '0');
   signal bist_addr      : unsigned(21 downto 0);
   signal bist_data      : std_logic_vector(7 downto 0);
   signal bist_got       : std_logic_vector(7 downto 0);
   signal bist_err       : unsigned(14 downto 0) := (others => '0');
   signal bist_first     : std_logic_vector(15 downto 0) := (others => '0');   -- {expected, got}
   signal bist_fadr      : std_logic_vector(15 downto 0) := (others => '0');   -- byte address bits 15..0
   signal bist_active    : std_logic;
   signal bist_done      : std_logic;
   signal bist_write     : std_logic;
   signal bist_read      : std_logic;
   signal dbg_hrd, dbg_hrv, dbg_hwr : unsigned(15 downto 0) := (others => '0');
   signal rom_accept     : std_logic;
   signal none_accept    : std_logic;

begin

   ---------------------------------------------------------------------------
   -- decode
   ---------------------------------------------------------------------------
   addr      <= unsigned(avm_address_i);
   sel_ega   <= '1' when addr(21 downto 14) = "00110000" else '0';   -- C0000-C3FFF
   sel_xtide <= '1' when addr(21 downto 14) = "00111011" and xtide_seen = '1' else '0';   -- EC000-EFFFF, xtide.rom loaded
   sel_bios  <= '1' when addr(21 downto 17) = "00111" and sel_xtide = '0' else '0';       -- E0000-FFFFF otherwise
   sel_rom   <= sel_ega or sel_xtide or sel_bios;

   -- where in the image a BIOS-window byte is, and whether the image covers it
   bios_off  <= addr(16 downto 0) - bios_base;
   bios_ok   <= '1' when pcxt_seen = '1' and addr(16 downto 0) >= bios_base else '0';
   -- conventional (0-9FFFF), UMB (C4000-CFFFF), EMS pages (200000-3FFFFF)
   sel_hyper <= '1' when sel_rom = '0' and
                        (addr(21 downto 17) < "00101" or                       -- 000000-09FFFF
                         (addr(21 downto 16) = "001100" and addr(15 downto 14) /= "00") or -- C4000-CFFFF
                         addr(21) = '1')                                       -- 200000-3FFFFF
                else '0';
   sel_none  <= not (sel_rom or sel_hyper);

   hyper_busy <= '1' when out_count /= 0 else '0';

   p_hr_rst_sync : process (clk_i)
   begin
      if rising_edge(clk_i) then
         hr_rst_meta <= hr_rst_i;
         hr_rst_sync <= hr_rst_meta;
      end if;
   end process;
   rst_all <= rst_i or hr_rst_sync;

   -- acceptance: ROM/unmapped accesses wait while HyperRAM reads are outstanding,
   -- nothing is accepted while either side is in reset
   rom_accept   <= (avm_read_i or avm_write_i) and sel_rom  and not hyper_busy and not rst_all and not bist_active;
   none_accept  <= (avm_read_i or avm_write_i) and sel_none and not hyper_busy and not rst_all and not bist_active;
   hyper_accept <= (avm_read_i or avm_write_i) and sel_hyper and not s_waitrequest and not rst_all and not bist_active;

   avm_waitrequest_o <= '0'            when (avm_read_i or avm_write_i) = '0' else
                        '1'            when rst_all = '1' or bist_active = '1' else
                        s_waitrequest  when sel_hyper = '1' else
                        hyper_busy;

   ---------------------------------------------------------------------------
   -- ROM port sequencer and block RAMs
   ---------------------------------------------------------------------------
   -- words past a window's size (128 KB BIOS, 16 KB EGA / XT-IDE) are dropped
   rom_fits  <= '1' when (rom_index_i(5 downto 0) = "000000" and rom_addr_i(24 downto 17) = "00000000") or
                         (rom_index_i = x"02"                 and rom_addr_i(24 downto 14) = "00000000000") or
                         (rom_index_i(5 downto 0) = "000011" and rom_addr_i(24 downto 14) = "00000000000")
                else '0';

   p_rom : process (clk_i)
   begin
      if rising_edge(clk_i) then
         if rom_wr_i = '1' and rom_fits = '1' then
            rom_a     <= unsigned(rom_addr_i(16 downto 0));
            rom_d     <= rom_data_i;
            rom_idx   <= rom_index_i;
            rom_phase <= "01";
         elsif rom_phase = "01" then
            rom_phase <= "10";
         else
            rom_phase <= "00";
         end if;
         if rst_i = '1' then
            rom_phase <= "00";
         end if;
      end if;
   end process;

   rom_we    <= rom_phase(0) or rom_phase(1);
   rom_wa    <= rom_a when rom_phase(0) = '1' else rom_a + 1;
   rom_wd    <= rom_d(7 downto 0) when rom_phase(0) = '1' else rom_d(15 downto 8);
   rom_bios  <= '1' when rom_idx(5 downto 0) = "000000" else '0';
   rom_xtide <= '1' when rom_idx = x"02" else '0';
   rom_ega   <= '1' when rom_idx(5 downto 0) = "000011" else '0';

   -- pcxt.rom placement: size and "upper half blank" tracked per word as it
   -- streams in, the window offset of file byte 0 derived from them. Word 0
   -- starts a new image. Not reset: the image survives a core reset, so its
   -- placement must too (rst_i is the cold reset, before any ROM is loaded).
   p_place : process (clk_i)
      variable v_word : unsigned(15 downto 0);
   begin
      if rising_edge(clk_i) then
         if rom_wr_i = '1' and rom_index_i(5 downto 0) = "000000" and rom_addr_i(24 downto 17) = "00000000" then
            v_word    := unsigned(rom_addr_i(16 downto 1));
            pcxt_seen <= '1';
            if v_word = 0 then
               pcxt_last <= (others => '0');
               pcxt_top  <= '0';
            else
               if v_word > pcxt_last then
                  pcxt_last <= v_word;
               end if;
               if rom_addr_i(16) = '1' and rom_data_i /= x"FFFF" then
                  pcxt_top <= '1';
               end if;
            end if;
         end if;
         if rom_wr_i = '1' and rom_index_i = x"02" then
            xtide_seen <= '1';
         end if;
         -- base = 20000h - 2 * (pcxt_last + 1) = 2 * not pcxt_last; a 128 KB
         -- image with a blank upper half is its lower 64 KB at F0000
         if pcxt_last(15) = '1' and pcxt_top = '0' then
            bios_base <= '1' & x"0000";
         else
            bios_base <= (not pcxt_last) & '0';
         end if;
      end if;
   end process;

   we_ega   <= (rom_we and rom_ega)   or (rom_accept and avm_write_i and sel_ega);
   wa_ega   <= rom_wa(13 downto 0) when (rom_we and rom_ega) = '1' else addr(13 downto 0);
   wd_ega   <= rom_wd when (rom_we and rom_ega) = '1' else avm_writedata_i;

   we_xtide <= (rom_we and rom_xtide) or (rom_accept and avm_write_i and sel_xtide);
   wa_xtide <= rom_wa(13 downto 0) when (rom_we and rom_xtide) = '1' else addr(13 downto 0);
   wd_xtide <= rom_wd when (rom_we and rom_xtide) = '1' else avm_writedata_i;

   -- BIOS window: ROM port only (Avalon writes are accepted and dropped, see header)
   we_bios  <= rom_we and rom_bios;
   wa_bios  <= rom_wa;
   wd_bios  <= rom_wd;

   p_ega : process (clk_i)
   begin
      if rising_edge(clk_i) then
         if we_ega = '1' then
            ega_ram(to_integer(wa_ega)) <= wd_ega;
         end if;
         q_ega <= ega_ram(to_integer(addr(13 downto 0)));
      end if;
   end process;

   p_xtide : process (clk_i)
   begin
      if rising_edge(clk_i) then
         if we_xtide = '1' then
            xtide_ram(to_integer(wa_xtide)) <= wd_xtide;
         end if;
         q_xtide <= xtide_ram(to_integer(addr(13 downto 0)));
      end if;
   end process;

   p_bios : process (clk_i)
   begin
      if rising_edge(clk_i) then
         if we_bios = '1' then
            bios_ram(to_integer(wa_bios)) <= wd_bios;
         end if;
         q_bios <= bios_ram(to_integer(bios_off));
      end if;
   end process;

   ---------------------------------------------------------------------------
   -- HyperRAM requests and the outstanding-read queue
   ---------------------------------------------------------------------------
   s_write      <= bist_write when bist_active = '1' else avm_write_i and sel_hyper;
   s_read       <= bist_read  when bist_active = '1' else avm_read_i  and sel_hyper;
   s_address    <= std_logic_vector(G_HR_BASE + resize(bist_addr(21 downto 1), 32)) when bist_active = '1' else
                   std_logic_vector(G_HR_BASE + resize(addr(21 downto 1), 32));
   s_writedata  <= bist_data & bist_data when bist_active = '1' else avm_writedata_i & avm_writedata_i;
   s_byteenable <= "10" when (bist_active = '1' and bist_addr(0) = '1') or (bist_active = '0' and addr(0) = '1') else "01";

   ---------------------------------------------------------------------------
   -- self test
   ---------------------------------------------------------------------------
   bist_active <= '0' when bist_state = B_DONE else '1';
   bist_done   <= not bist_active;
   bist_write  <= '1' when bist_state = B_WRITE else '0';
   bist_read   <= '1' when bist_state = B_READ  else '0';
   bist_addr   <= "0000000001" & "000000" & bist_idx(5 downto 0) when bist_idx(7 downto 6) = "00" else   -- 0x001000 + i
                  "0011000100" & "000000" & bist_idx(5 downto 0) when bist_idx(7 downto 6) = "01" else   -- 0x0C4000 + i
                  "1000000000" & "000000" & bist_idx(5 downto 0);                                    -- 0x200000 + i
   bist_data   <= std_logic_vector(bist_idx xor x"5A");
   bist_got    <= s_readdata(15 downto 8) when bist_addr(0) = '1' else s_readdata(7 downto 0);

   p_bist : process (clk_i)
   begin
      if rising_edge(clk_i) then
         case bist_state is
            when B_WAIT =>
               bist_wait <= bist_wait + 1;
               if bist_wait = x"FFFF" and s_waitrequest = '0' then
                  bist_idx   <= (others => '0');
                  bist_state <= B_WRITE;
               end if;
            when B_WRITE =>
               if s_waitrequest = '0' then
                  if bist_idx = 191 then
                     bist_wait  <= (others => '0');
                     bist_state <= B_WR_GAP;
                  else
                     bist_idx <= bist_idx + 1;
                  end if;
               end if;
            when B_WR_GAP =>
               bist_wait <= bist_wait + 1;
               if bist_wait = x"0FFF" then
                  bist_idx   <= (others => '0');
                  bist_state <= B_READ;
               end if;
            when B_READ =>
               if s_waitrequest = '0' then
                  bist_state <= B_RD_WAIT;
               end if;
            when B_RD_WAIT =>
               if s_readdatavalid = '1' then
                  if bist_got /= bist_data then
                     if bist_err = 0 then
                        bist_first <= bist_data & bist_got;
                        bist_fadr  <= std_logic_vector(bist_addr(15 downto 0));
                     end if;
                     bist_err <= bist_err + 1;
                  end if;
                  if bist_idx = 191 then
                     bist_state <= B_DONE;
                  else
                     bist_idx   <= bist_idx + 1;
                     bist_state <= B_READ;
                  end if;
               end if;
            when B_DONE =>
               null;
         end case;
         if rst_all = '1' then
            if G_BIST then
               bist_state <= B_WAIT;
            else
               bist_state <= B_DONE;
            end if;
            bist_wait  <= (others => '0');
            bist_err   <= (others => '0');
         end if;
      end if;
   end process;

   p_out : process (clk_i)
      variable v_push  : boolean;
      variable v_real  : boolean;
      variable v_flush : boolean;
      variable v_pop   : boolean;
   begin
      if rising_edge(clk_i) then
         v_push  := (hyper_accept and avm_read_i) = '1';          -- never while rst_all
         v_real  := s_readdatavalid = '1' and bist_active = '0';
         -- reset with reads outstanding: answer them with dummy beats, one per clock
         v_flush := rst_all = '1' and out_count /= 0 and not v_real;
         v_pop   := v_real or v_flush;
         if v_flush then
            flush_valid <= '1';
         else
            flush_valid <= '0';
         end if;
         if v_push then
            out_lsb <= out_lsb(C_OUT_MAX-2 downto 0) & addr(0);
         end if;
         if v_push and not v_pop then
            out_count <= out_count + 1;
         elsif v_pop and not v_push then
            out_count <= out_count - 1;
         end if;

         rom_valid_q <= rom_accept and avm_read_i;
         if (hyper_accept and avm_read_i) = '1'  then dbg_hrd <= dbg_hrd + 1; end if;
         if (hyper_accept and avm_write_i) = '1' then dbg_hwr <= dbg_hwr + 1; end if;
         if s_readdatavalid = '1'                 then dbg_hrv <= dbg_hrv + 1; end if;
         none_q      <= none_accept and avm_read_i;
         sel_q       <= sel_bios & sel_xtide & sel_ega;
         bios_ok_q   <= bios_ok;

         if rst_all = '1' then
            -- out_count is not cleared here: v_flush drains it beat by beat
            rom_valid_q <= '0';
            none_q      <= '0';
         end if;
      end if;
   end process;

   dbg_hrd_o <= bist_done & std_logic_vector(bist_err);   -- bit 15 = self test finished, 14..0 = mismatches of 192
   dbg_hrv_o <= bist_first;                               -- first mismatch: expected & got
   dbg_hwr_o <= bist_fadr;                                -- first mismatch: byte address (15..0)

   -- the oldest outstanding read is at index out_count-1 (shift register)
   avm_readdatavalid_o <= rom_valid_q or none_q or flush_valid or (s_readdatavalid and not bist_active);
   avm_readdata_o <= q_ega   when rom_valid_q = '1' and sel_q(0) = '1' else
                     q_xtide when rom_valid_q = '1' and sel_q(1) = '1' else
                     q_bios  when rom_valid_q = '1' and sel_q(2) = '1' and bios_ok_q = '1' else
                     x"FF"   when none_q = '1' or rom_valid_q = '1' or flush_valid = '1' else   -- outside the image / read lost in a reset
                     s_readdata(15 downto 8) when out_count > 0 and out_lsb(out_count-1) = '1' else
                     s_readdata(7 downto 0);

   ---------------------------------------------------------------------------
   -- clock crossing into the HyperRAM domain, optional read cache
   ---------------------------------------------------------------------------
   i_fifo : entity work.avm_fifo
      generic map (
         G_WR_DEPTH     => 16,
         G_RD_DEPTH     => 16,
         G_FILL_SIZE    => 1,
         G_ADDRESS_SIZE => 32,
         G_DATA_SIZE    => 16
      )
      port map (
         s_clk_i               => clk_i,
         s_rst_i               => rst_all,
         s_avm_waitrequest_o   => s_waitrequest,
         s_avm_write_i         => s_write,
         s_avm_read_i          => s_read,
         s_avm_address_i       => s_address,
         s_avm_writedata_i     => s_writedata,
         s_avm_byteenable_i    => s_byteenable,
         s_avm_burstcount_i    => x"01",
         s_avm_readdata_o      => s_readdata,
         s_avm_readdatavalid_o => s_readdatavalid,
         m_clk_i               => hr_clk_i,
         m_rst_i               => hr_rst_i,
         m_avm_waitrequest_i   => m_waitrequest,
         m_avm_write_o         => m_write,
         m_avm_read_o          => m_read,
         m_avm_address_o       => m_address,
         m_avm_writedata_o     => m_writedata,
         m_avm_byteenable_o    => m_byteenable,
         m_avm_burstcount_o    => m_burstcount,
         m_avm_readdata_i      => m_readdata,
         m_avm_readdatavalid_i => f_readdatavalid
      );

   gen_cache : if G_CACHE generate
      -- avm_cache must not see a second read while it is still fetching the first:
      -- when that read is to the very word arriving from the HyperRAM (the two
      -- bytes of a 16-bit access, the overlay's 2-beat pattern) the cache accepts
      -- it in the clock of the first data beat and answers both reads with a
      -- single readdatavalid, so one read is lost and out_count never drains.
      -- Hold the FIFO's read until the previous one has answered; writes pass.
      -- Nothing is offered to the cache while it is in reset: its waitrequest
      -- is 0 then and it would take the command from the FIFO and drop it.
      c_read        <= m_read and not c_pending;
      m_waitrequest <= c_waitrequest or (m_read and c_pending) or hr_rst_i;

      -- With one read outstanding at a time, exactly one readdatavalid per read
      -- is legitimate: the first one after acceptance. Anything the cache
      -- produces while no read is pending would be a surplus response that
      -- the overlay would attribute to its next read, so it is not forwarded.
      f_readdatavalid <= m_readdatavalid and c_pending;

      p_pending : process (hr_clk_i)
      begin
         if rising_edge(hr_clk_i) then
            if c_read = '1' and c_waitrequest = '0' then
               c_pending <= '1';
            elsif f_readdatavalid = '1' then
               c_pending <= '0';
            end if;
            if hr_rst_i = '1' then
               c_pending <= '0';
            end if;
         end if;
      end process;

      i_cache : entity work.avm_cache
         generic map (
            G_CACHE_SIZE   => G_CACHE_SIZE,
            G_ADDRESS_SIZE => 32,
            G_DATA_SIZE    => 16
         )
         port map (
            clk_i                 => hr_clk_i,
            rst_i                 => hr_rst_i,
            s_avm_waitrequest_o   => c_waitrequest,
            s_avm_write_i         => m_write,
            s_avm_read_i          => c_read,
            s_avm_address_i       => m_address,
            s_avm_writedata_i     => m_writedata,
            s_avm_byteenable_i    => m_byteenable,
            s_avm_burstcount_i    => m_burstcount,
            s_avm_readdata_o      => m_readdata,
            s_avm_readdatavalid_o => m_readdatavalid,
            m_avm_waitrequest_i   => hr_waitrequest_i,
            m_avm_write_o         => hr_write_o,
            m_avm_read_o          => hr_read_o,
            m_avm_address_o       => hr_address_o,
            m_avm_writedata_o     => hr_writedata_o,
            m_avm_byteenable_o    => hr_byteenable_o,
            m_avm_burstcount_o    => hr_burstcount_o,
            m_avm_readdata_i      => hr_readdata_i,
            m_avm_readdatavalid_i => hr_readdatavalid_i
         );
   end generate gen_cache;

   gen_nocache : if not G_CACHE generate
      hr_write_o      <= m_write;
      hr_read_o       <= m_read;
      hr_address_o    <= m_address;
      hr_writedata_o  <= m_writedata;
      hr_byteenable_o <= m_byteenable;
      hr_burstcount_o <= m_burstcount;
      m_readdata      <= hr_readdata_i;
      m_readdatavalid <= hr_readdatavalid_i;
      f_readdatavalid <= m_readdatavalid;
      m_waitrequest   <= hr_waitrequest_i;
   end generate gen_nocache;

end architecture rtl;
