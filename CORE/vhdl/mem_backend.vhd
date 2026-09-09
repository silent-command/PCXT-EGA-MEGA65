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
--   0EC000-0EFFFF   16 KB XT-IDE BIOS           block RAM, ROM-written
--   0F0000-0FFFFF   64 KB PC/XT BIOS            block RAM, ROM-written
--   200000-3FFFFF    2 MB EMS pages             HyperRAM
--   anything else reads FF and ignores writes.
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
-- ROM port: as in mem_bram.vhd, the BIOS images are written here directly
-- from rom_loader.vhd (the core's own loader FSM drops the odd word).
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
      G_CACHE_SIZE        : natural := 8                         -- words per line
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

      -- ROM download port (rom_loader.vhd, clk_i): index 0 = PC/XT BIOS at
      -- F0000, 2 = XT-IDE at EC000, 3 = EGA BIOS at C0000
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
      hr_waitrequest_i    : in  std_logic
   );
end entity mem_backend;

architecture rtl of mem_backend is

   ---------------------------------------------------------------------------
   -- ROM windows in block RAM
   ---------------------------------------------------------------------------
   type ram64k_t  is array (0 to 65535)  of std_logic_vector(7 downto 0);
   type ram16k_t  is array (0 to 16383)  of std_logic_vector(7 downto 0);

   signal ega_ram   : ram16k_t;
   signal xtide_ram : ram16k_t;
   signal bios_ram  : ram64k_t;

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

   -- ROM port: two byte writes per word
   signal rom_phase : std_logic_vector(1 downto 0) := "00";
   signal rom_a     : unsigned(15 downto 0) := (others => '0');
   signal rom_d     : std_logic_vector(15 downto 0) := (others => '0');
   signal rom_idx   : std_logic_vector(7 downto 0) := (others => '0');
   signal rom_we    : std_logic;
   signal rom_wa    : unsigned(15 downto 0);
   signal rom_wd    : std_logic_vector(7 downto 0);
   signal rom_ega   : std_logic;
   signal rom_xtide : std_logic;
   signal rom_bios  : std_logic;

   signal we_ega, we_xtide, we_bios : std_logic;
   signal wa_ega    : unsigned(13 downto 0);
   signal wa_xtide  : unsigned(13 downto 0);
   signal wa_bios   : unsigned(15 downto 0);
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

   -- one read at a time into the cache (G_CACHE only, see g_cache)
   signal c_read         : std_logic;
   signal c_waitrequest  : std_logic;
   signal c_pending      : std_logic := '0';

   signal hyper_accept   : std_logic;
   signal rom_accept     : std_logic;
   signal none_accept    : std_logic;

begin

   ---------------------------------------------------------------------------
   -- decode
   ---------------------------------------------------------------------------
   addr      <= unsigned(avm_address_i);
   sel_ega   <= '1' when addr(21 downto 14) = "00110000" else '0';   -- C0000-C3FFF
   sel_xtide <= '1' when addr(21 downto 14) = "00111011" else '0';   -- EC000-EFFFF
   sel_bios  <= '1' when addr(21 downto 16) = "001111"   else '0';   -- F0000-FFFFF
   sel_rom   <= sel_ega or sel_xtide or sel_bios;
   -- conventional (0-9FFFF), UMB (C4000-CFFFF), EMS pages (200000-3FFFFF)
   sel_hyper <= '1' when sel_rom = '0' and
                        (addr(21 downto 17) < "00101" or                       -- 000000-09FFFF
                         (addr(21 downto 16) = "001100" and addr(15 downto 14) /= "00") or -- C4000-CFFFF
                         addr(21) = '1')                                       -- 200000-3FFFFF
                else '0';
   sel_none  <= not (sel_rom or sel_hyper);

   hyper_busy <= '1' when out_count /= 0 else '0';

   -- acceptance: ROM/unmapped accesses wait while HyperRAM reads are outstanding
   rom_accept   <= (avm_read_i or avm_write_i) and sel_rom  and not hyper_busy;
   none_accept  <= (avm_read_i or avm_write_i) and sel_none and not hyper_busy;
   hyper_accept <= (avm_read_i or avm_write_i) and sel_hyper and not s_waitrequest;

   avm_waitrequest_o <= '0'            when (avm_read_i or avm_write_i) = '0' else
                        s_waitrequest  when sel_hyper = '1' else
                        hyper_busy;

   ---------------------------------------------------------------------------
   -- ROM port sequencer and block RAMs
   ---------------------------------------------------------------------------
   p_rom : process (clk_i)
   begin
      if rising_edge(clk_i) then
         if rom_wr_i = '1' then
            rom_a     <= unsigned(rom_addr_i(15 downto 0));
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

   we_ega   <= (rom_we and rom_ega)   or (rom_accept and avm_write_i and sel_ega);
   wa_ega   <= rom_wa(13 downto 0) when (rom_we and rom_ega) = '1' else addr(13 downto 0);
   wd_ega   <= rom_wd when (rom_we and rom_ega) = '1' else avm_writedata_i;

   we_xtide <= (rom_we and rom_xtide) or (rom_accept and avm_write_i and sel_xtide);
   wa_xtide <= rom_wa(13 downto 0) when (rom_we and rom_xtide) = '1' else addr(13 downto 0);
   wd_xtide <= rom_wd when (rom_we and rom_xtide) = '1' else avm_writedata_i;

   we_bios  <= (rom_we and rom_bios)  or (rom_accept and avm_write_i and sel_bios);
   wa_bios  <= rom_wa when (rom_we and rom_bios) = '1' else addr(15 downto 0);
   wd_bios  <= rom_wd when (rom_we and rom_bios) = '1' else avm_writedata_i;

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
         q_bios <= bios_ram(to_integer(addr(15 downto 0)));
      end if;
   end process;

   ---------------------------------------------------------------------------
   -- HyperRAM requests and the outstanding-read queue
   ---------------------------------------------------------------------------
   s_write      <= avm_write_i and sel_hyper;
   s_read       <= avm_read_i  and sel_hyper;
   s_address    <= std_logic_vector(G_HR_BASE + resize(addr(21 downto 1), 32));
   s_writedata  <= avm_writedata_i & avm_writedata_i;
   s_byteenable <= "10" when addr(0) = '1' else "01";

   p_out : process (clk_i)
      variable v_push : boolean;
      variable v_pop  : boolean;
   begin
      if rising_edge(clk_i) then
         v_push := (hyper_accept and avm_read_i) = '1';
         v_pop  := s_readdatavalid = '1';
         if v_push then
            out_lsb <= out_lsb(C_OUT_MAX-2 downto 0) & addr(0);
         end if;
         if v_push and not v_pop then
            out_count <= out_count + 1;
         elsif v_pop and not v_push then
            out_count <= out_count - 1;
         end if;

         rom_valid_q <= rom_accept and avm_read_i;
         none_q      <= none_accept and avm_read_i;
         sel_q       <= sel_bios & sel_xtide & sel_ega;

         if rst_i = '1' then
            out_count   <= 0;
            rom_valid_q <= '0';
            none_q      <= '0';
         end if;
      end if;
   end process;

   -- the oldest outstanding read is at index out_count-1 (shift register)
   avm_readdatavalid_o <= rom_valid_q or none_q or s_readdatavalid;
   avm_readdata_o <= q_ega   when rom_valid_q = '1' and sel_q(0) = '1' else
                     q_xtide when rom_valid_q = '1' and sel_q(1) = '1' else
                     q_bios  when rom_valid_q = '1' and sel_q(2) = '1' else
                     x"FF"   when none_q = '1' else
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
         s_rst_i               => rst_i,
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
         m_avm_readdatavalid_i => m_readdatavalid
      );

   gen_cache : if G_CACHE generate
      -- avm_cache must not see a second read while it is still fetching the first:
      -- when that read is to the very word arriving from the HyperRAM (the two
      -- bytes of a 16-bit access, the overlay's 2-beat pattern) the cache accepts
      -- it in the clock of the first data beat and answers both reads with a
      -- single readdatavalid, so one read is lost and out_count never drains.
      -- Hold the FIFO's read until the previous one has answered; writes pass.
      c_read        <= m_read and not c_pending;
      m_waitrequest <= c_waitrequest or (m_read and c_pending);

      p_pending : process (hr_clk_i)
      begin
         if rising_edge(hr_clk_i) then
            if c_read = '1' and c_waitrequest = '0' then
               c_pending <= '1';
            elsif m_readdatavalid = '1' then
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
      m_waitrequest   <= hr_waitrequest_i;
   end generate gen_nocache;

end architecture rtl;
