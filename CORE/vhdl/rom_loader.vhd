-------------------------------------------------------------------------------------------------------------
-- PCXT-EGA on MiSTer2MEGA65: QNICE ROM device -> MiSTer ioctl download stream
--
-- The M2M firmware auto-loads the BIOS files listed in globals.vhd
-- (C_CRTROMS_AUTO) before it releases the core: for every byte of a file it
-- selects the target device id, sets the 4k window to byte_offset/4096 and
-- writes the byte to 0x7000 + (byte_offset mod 4096). From the device's side
-- that is one qnice_dev_we strobe per byte with the linear byte offset on
-- qnice_dev_addr and the byte in the low half of qnice_dev_data. There is no
-- end-of-file signal and the auto-loader never tells the device the file
-- size (the CSR protocol in 4k window 0xFFFF - status, file size - is only
-- used for manually loaded ROMs, which this core has none of); writes into
-- that window are ignored here so that they can never be mistaken for data.
-- Any file size up to 32 MB streams through unchanged (25-bit byte offset);
-- mem_backend.vhd decides where a 32/64/96/128 KB pcxt.rom lands.
--
-- The PCXT-EGA core's BIOS loader (kept unchanged inside pcxt_core.sv) wants
-- the MiSTer hps_io ioctl protocol instead: 16-bit little-endian words, one
-- rom_wr pulse per word, rom_addr = even byte offset, rom_index = ROM slot,
-- rom_download high for the whole file, rom_wait = do not send the next word.
--
-- This entity pairs the bytes into words on the QNICE clock, hands each word
-- to the core clock with a toggle handshake (the core side consumes a word
-- in ~172 clocks, the firmware needs far longer per byte, so QNICE is only
-- ever stalled through qnice_dev_wait_o for a few core clocks) and derives
-- rom_download from activity: it rises with the first word of a file and
-- falls G_TIMEOUT core clocks after the last one. The core's "loaded" latch
-- sets on the first completed word, so a spurious drop would only cost a
-- re-latch, but the timeout is long enough for an SD-card sector fetch.
--
-- One instance serves all three ROMs: the device id selects the slot.
--
-- MiSTer2MEGA65 done by sy2002 and MJoergen in 2022 and licensed under GPL v3
-------------------------------------------------------------------------------------------------------------

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

library xpm;
use xpm.vcomponents.all;

entity rom_loader is
   generic (
      G_DEV_PCXT     : std_logic_vector(15 downto 0) := x"0110";   -- QNICE device ids (>= 0x0100)
      G_DEV_EGA      : std_logic_vector(15 downto 0) := x"0111";
      G_DEV_XTIDE    : std_logic_vector(15 downto 0) := x"0112";
      G_TIMEOUT      : natural := 12_500_000;           -- core clocks of silence that end a download (250 ms at 50 MHz)
      G_WORD_TIMEOUT : natural := 500_000               -- core clocks a word may wait for rom_wait (10 ms); then it is dropped
   );
   port (
      -- QNICE side
      qnice_clk_i      : in  std_logic;
      qnice_rst_i      : in  std_logic;
      qnice_dev_id_i   : in  std_logic_vector(15 downto 0);
      qnice_dev_addr_i : in  std_logic_vector(27 downto 0);
      qnice_dev_data_i : in  std_logic_vector(15 downto 0);
      qnice_dev_ce_i   : in  std_logic;
      qnice_dev_we_i   : in  std_logic;
      qnice_dev_wait_o : out std_logic;
      qnice_dev_data_o : out std_logic_vector(15 downto 0);  -- status readback (see p_readback)

      -- Core side (pcxt_core ROM download port, clk_chipset domain)
      core_clk_i       : in  std_logic;
      core_rst_i       : in  std_logic;
      rom_download_o   : out std_logic;
      rom_index_o      : out std_logic_vector(7 downto 0);
      rom_wr_o         : out std_logic;
      rom_addr_o       : out std_logic_vector(24 downto 0);
      rom_data_o       : out std_logic_vector(15 downto 0);
      rom_wait_i       : in  std_logic;

      -- debug counters from the core, shown in the status readback (6, 7)
      dbg_a_i          : in  std_logic_vector(15 downto 0) := (others => '0');
      dbg_b_i          : in  std_logic_vector(15 downto 0) := (others => '0');
      dbg_c_i          : in  std_logic_vector(15 downto 0) := (others => '0');
      dbg_flags_i      : in  std_logic_vector(7 downto 0)  := (others => '0')   -- readback 0, bits 15..8
   );
end entity rom_loader;

architecture rtl of rom_loader is

   -- ioctl indices the core decodes (PCXT-EGA.sv: select_pcxt idx 0, xtide 2, ega 3)
   constant C_IDX_PCXT  : std_logic_vector(7 downto 0) := x"00";
   constant C_IDX_XTIDE : std_logic_vector(7 downto 0) := x"02";
   constant C_IDX_EGA   : std_logic_vector(7 downto 0) := x"03";

   -- QNICE side
   signal q_selected    : std_logic;
   signal q_csr         : std_logic;                       -- access to the CRT/ROM control window (0xFFFF)
   signal q_index       : std_logic_vector(7 downto 0);
   signal q_low_byte    : std_logic_vector(7 downto 0);
   signal q_word        : std_logic_vector(15 downto 0);
   signal q_word_addr   : std_logic_vector(23 downto 0);   -- word offset (byte offset / 2)
   signal q_word_index  : std_logic_vector(7 downto 0);
   signal q_req_toggle  : std_logic := '0';
   signal q_ack_toggle  : std_logic;                       -- from core, synchronised
   signal q_pending     : std_logic;

   -- core side
   signal c_req_toggle  : std_logic;                       -- from QNICE, synchronised
   signal c_req_seen    : std_logic := '0';
   signal c_ack_toggle  : std_logic := '0';
   signal c_word_valid  : std_logic := '0';
   signal c_timeout     : natural range 0 to G_TIMEOUT;
   signal c_settle      : natural range 0 to 15;         -- cycles to let the core see rom_download before the first word
   signal c_word_wait   : natural range 0 to G_WORD_TIMEOUT;
   signal c_words_ok    : unsigned(15 downto 0) := (others => '0');
   signal c_words_drop  : unsigned(15 downto 0) := (others => '0');
   signal c_sum_pcxt    : unsigned(15 downto 0) := (others => '0');   -- 16-bit sums of the delivered words
   signal c_sum_ega     : unsigned(15 downto 0) := (others => '0');
   signal c_sum_xtide   : unsigned(15 downto 0) := (others => '0');
   signal c_rom_wait_q  : std_logic := '0';
   signal c_download    : std_logic := '0';

begin

   ---------------------------------------------------------------------------
   -- QNICE side: pair bytes into words
   ---------------------------------------------------------------------------

   q_selected <= '1' when qnice_dev_id_i = G_DEV_PCXT or
                          qnice_dev_id_i = G_DEV_EGA  or
                          qnice_dev_id_i = G_DEV_XTIDE else '0';

   q_index    <= C_IDX_PCXT  when qnice_dev_id_i = G_DEV_PCXT  else
                 C_IDX_EGA   when qnice_dev_id_i = G_DEV_EGA   else
                 C_IDX_XTIDE;

   -- M2M CRTROM_CSR_4KWIN: status / file size from the firmware, not ROM data
   q_csr      <= '1' when qnice_dev_addr_i(27 downto 12) = x"FFFF" else '0';

   q_pending  <= q_req_toggle xor q_ack_toggle;

   -- Wait while a word is pending, whenever this device is selected (like the
   -- framework's HyperRAM device): the CPU samples wait a cycle before its data
   -- strobe, so gating on ce/we would let a write slip through and be lost.
   qnice_dev_wait_o <= q_selected and q_pending;

   p_qnice : process (qnice_clk_i)
   begin
      if rising_edge(qnice_clk_i) then
         if q_selected = '1' and q_csr = '0' and qnice_dev_ce_i = '1' and qnice_dev_we_i = '1' and q_pending = '0' then
            if qnice_dev_addr_i(0) = '0' then
               q_low_byte <= qnice_dev_data_i(7 downto 0);
            else
               q_word       <= qnice_dev_data_i(7 downto 0) & q_low_byte;
               q_word_addr  <= qnice_dev_addr_i(24 downto 1);
               q_word_index <= q_index;
               q_req_toggle <= not q_req_toggle;
            end if;
         end if;
         if qnice_rst_i = '1' then
            q_req_toggle <= '0';
         end if;
      end if;
   end process;

   ---------------------------------------------------------------------------
   -- Clock domain crossing (toggle handshake, both ways)
   ---------------------------------------------------------------------------

   i_req_sync : xpm_cdc_single
      generic map (DEST_SYNC_FF => 3, SRC_INPUT_REG => 0)
      port map (src_clk => qnice_clk_i, src_in => q_req_toggle, dest_clk => core_clk_i, dest_out => c_req_toggle);

   i_ack_sync : xpm_cdc_single
      generic map (DEST_SYNC_FF => 3, SRC_INPUT_REG => 0)
      port map (src_clk => core_clk_i, src_in => c_ack_toggle, dest_clk => qnice_clk_i, dest_out => q_ack_toggle);

   ---------------------------------------------------------------------------
   -- Core side: one rom_wr per word, download level from activity
   ---------------------------------------------------------------------------

   p_core : process (core_clk_i)
   begin
      if rising_edge(core_clk_i) then
         rom_wr_o <= '0';

         -- new word from QNICE: q_word/q_word_addr/q_word_index are stable
         -- until we acknowledge, so they can be sampled here safely
         if c_req_toggle /= c_req_seen and c_word_valid = '0' then
            c_req_seen   <= c_req_toggle;
            c_word_valid <= '1';
            rom_data_o   <= q_word;
            rom_addr_o   <= q_word_addr & '0';
            rom_index_o  <= q_word_index;
            c_timeout    <= G_TIMEOUT;
            if c_download = '0' then
               c_download <= '1';
               c_settle   <= 15;   -- the core's loader FSM leaves idle a few clocks after rom_download rises
            end if;
         end if;

         if c_settle > 0 then
            c_settle <= c_settle - 1;
         end if;

         -- hand the word to the core once it is ready for it; a core that never
         -- becomes ready must not freeze the firmware, so the word is dropped
         -- after G_WORD_TIMEOUT and counted in c_words_drop
         if c_word_valid = '1' and rom_wait_i = '0' and c_settle = 0 then
            rom_wr_o     <= '1';
            c_word_valid <= '0';
            c_ack_toggle <= not c_ack_toggle;
            c_words_ok   <= c_words_ok + 1;
            c_word_wait  <= 0;
            if q_word_index = C_IDX_PCXT then
               c_sum_pcxt <= c_sum_pcxt + unsigned(q_word);
            elsif q_word_index = C_IDX_EGA then
               c_sum_ega <= c_sum_ega + unsigned(q_word);
            elsif q_word_index = C_IDX_XTIDE then
               c_sum_xtide <= c_sum_xtide + unsigned(q_word);
            end if;
         elsif c_word_valid = '1' then
            if c_word_wait = G_WORD_TIMEOUT then
               c_word_valid <= '0';
               c_ack_toggle <= not c_ack_toggle;
               c_words_drop <= c_words_drop + 1;
               c_word_wait  <= 0;
            else
               c_word_wait  <= c_word_wait + 1;
            end if;
         else
            c_word_wait <= 0;
         end if;
         c_rom_wait_q <= rom_wait_i;

         -- download ends after a period of silence
         if c_word_valid = '0' then
            if c_timeout > 0 then
               c_timeout <= c_timeout - 1;
            else
               c_download <= '0';
            end if;
         end if;

         if core_rst_i = '1' then
            c_req_seen   <= c_req_toggle;
            c_ack_toggle <= '0';
            c_word_valid <= '0';
            c_download   <= '0';
            c_timeout    <= 0;
            c_settle     <= 0;
            c_word_wait  <= 0;
            c_words_ok   <= (others => '0');
            c_words_drop <= (others => '0');
            c_sum_pcxt   <= (others => '0');
            c_sum_ega    <= (others => '0');
            c_sum_xtide  <= (others => '0');
            rom_wr_o     <= '0';
         end if;
      end if;
   end process;

   rom_download_o <= c_download;

   ---------------------------------------------------------------------------
   -- Status readback for the QNICE side (debug): word offset 0 = flags,
   -- 1 = words delivered, 2 = words dropped. The counters are in the core
   -- clock domain and only read while the loader is quiet, so no CDC.
   ---------------------------------------------------------------------------
   -- 3/4/5 = checksums of pcxt.rom / ega_bios.rom / xtide.rom words, 6/7 = debug counters
   qnice_dev_data_o <= dbg_flags_i & "00000" & c_word_valid & c_download & c_rom_wait_q when qnice_dev_addr_i(3 downto 0) = "0000" else
                       std_logic_vector(c_words_ok)   when qnice_dev_addr_i(3 downto 0) = "0001" else
                       std_logic_vector(c_words_drop) when qnice_dev_addr_i(3 downto 0) = "0010" else
                       std_logic_vector(c_sum_pcxt)   when qnice_dev_addr_i(3 downto 0) = "0011" else
                       std_logic_vector(c_sum_ega)    when qnice_dev_addr_i(3 downto 0) = "0100" else
                       std_logic_vector(c_sum_xtide)  when qnice_dev_addr_i(3 downto 0) = "0101" else
                       dbg_a_i                        when qnice_dev_addr_i(3 downto 0) = "0110" else
                       dbg_b_i                        when qnice_dev_addr_i(3 downto 0) = "0111" else
                       dbg_c_i                        when qnice_dev_addr_i(3 downto 0) = "1000" else
                       x"EEEE";

end architecture rtl;
