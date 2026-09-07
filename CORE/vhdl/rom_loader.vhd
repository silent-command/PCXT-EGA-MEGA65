-------------------------------------------------------------------------------------------------------------
-- PCXT-EGA on MiSTer2MEGA65: QNICE ROM device -> MiSTer ioctl download stream
--
-- The M2M firmware auto-loads the BIOS files listed in globals.vhd
-- (C_CRTROMS_AUTO) before it releases the core: for every byte of a file it
-- selects the target device id, sets the 4k window to byte_offset/4096 and
-- writes the byte to 0x7000 + (byte_offset mod 4096). From the device's side
-- that is one qnice_dev_we strobe per byte with the linear byte offset on
-- qnice_dev_addr and the byte in the low half of qnice_dev_data. There is no
-- end-of-file signal.
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
      G_TIMEOUT      : natural := 12_500_000            -- core clocks of silence that end a download (250 ms at 50 MHz)
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

      -- Core side (pcxt_core ROM download port, clk_chipset domain)
      core_clk_i       : in  std_logic;
      core_rst_i       : in  std_logic;
      rom_download_o   : out std_logic;
      rom_index_o      : out std_logic_vector(7 downto 0);
      rom_wr_o         : out std_logic;
      rom_addr_o       : out std_logic_vector(24 downto 0);
      rom_data_o       : out std_logic_vector(15 downto 0);
      rom_wait_i       : in  std_logic
   );
end entity rom_loader;

architecture rtl of rom_loader is

   -- ioctl indices the core decodes (PCXT-EGA.sv: select_pcxt idx 0, xtide 2, ega 3)
   constant C_IDX_PCXT  : std_logic_vector(7 downto 0) := x"00";
   constant C_IDX_XTIDE : std_logic_vector(7 downto 0) := x"02";
   constant C_IDX_EGA   : std_logic_vector(7 downto 0) := x"03";

   -- QNICE side
   signal q_selected    : std_logic;
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

   q_pending  <= q_req_toggle xor q_ack_toggle;

   -- A write is stalled while the previous word has not been consumed yet.
   qnice_dev_wait_o <= q_selected and qnice_dev_ce_i and qnice_dev_we_i and q_pending;

   p_qnice : process (qnice_clk_i)
   begin
      if rising_edge(qnice_clk_i) then
         if q_selected = '1' and qnice_dev_ce_i = '1' and qnice_dev_we_i = '1' and q_pending = '0' then
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
            c_download   <= '1';
            c_timeout    <= G_TIMEOUT;
         end if;

         -- hand the word to the core once it is ready for it
         if c_word_valid = '1' and rom_wait_i = '0' then
            rom_wr_o     <= '1';
            c_word_valid <= '0';
            c_ack_toggle <= not c_ack_toggle;
         end if;

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
            rom_wr_o     <= '0';
         end if;
      end if;
   end process;

   rom_download_o <= c_download;

end architecture rtl;
