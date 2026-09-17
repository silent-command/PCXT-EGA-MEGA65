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
-- Ethernet station address (docs/ethernet.md): the firmware reads the
-- MEGA65's MAC from the SD card's configuration sector (or falls back to a
-- default) and writes it here, device G_DEV_PCXT, 4k window 0xFFFE:
--   register 0..2 (word offsets): MAC bytes 0/1, 2/3, 4/5 (big-endian words)
--   register 3: bit 0 = valid, bit 1 = source (1 = MEGA65 config), readback only
-- The three words are captured into the core clock domain when the valid
-- bit arrives there (a level, through xpm_cdc_single), so eth_mac_o only
-- changes while eth_mac_valid_o is low and the card, which is held disabled
-- until eth_mac_valid_o, never sees a half-written address. The window is
-- one the auto-loader never touches (file offsets end at window 0x1FFF, the
-- framework's CSR is 0xFFFF), and its writes are excluded from the byte
-- pairing above. All four registers read back in the same window.
--
-- Internal floppy drive (docs/floppy.md, floppy_sector_engine.vhd): the firmware's flpdrv.asm drives the
-- sector engine through 4k window 0xFFFD of device G_DEV_PCXT (engine in the core clock, registers here
-- in the QNICE clock):
--   write 0: command (bits 3..0: 1 DETECT, 2 READ_TRACK, 3 COPY, 4 PROBE, 5 MOTOR_OFF); the write starts it
--   write 1: cylinder (7..0), head (8), rate 500 kbit/s (9), force (10)
--   write 2: sector R (4..0), sectors per track (12..8)
--   write 3: control: bit 0 enable (level), bit 1 clear the sticky disk-change flag (self-clearing),
--            bit 2 block error (level, to mgmt_bridge: the block the firmware acknowledges next carries
--            no data, see flp_blk_err_o)
--   read  0: status: 15 busy, 14 cache valid, 13 disk change (live line), 12 index seen, 11 motor on,
--            10 track 0, 9 disk change (sticky), 8 write protect, 7..0 error code of the last command
--   read  1: detect result: 9 DD found, 8 HD found, 7..0 largest sector number
--   read  2: valid slots, sectors 1..16;  read 3: CRC-error slots, sectors 1..16
--   read  4: cached cylinder (15..8), cache rate (5), cache head (4), CRC-error 18/17 (3..2), valid 18/17 (1..0)
--   read  5: engine state (15..8), head position (7..0)
--   read  6..8: index / good ID / good data counters (live, debug), 9: steps, 10: last C H, 11: last R N
-- Handshake: the command write toggles a request into the core clock (one cmd_valid pulse there, the
-- arguments were written before and are stable); the engine's completion toggles an acknowledge back,
-- so bit 15 (busy) is set by the write itself and clears only after the command ended - no race for a
-- firmware that writes and polls at once. The result words 0..5 are captured into the QNICE clock when
-- the acknowledge arrives (they were written at least three core clocks earlier and hold until the
-- next command); the live flags cross bit by bit; the counters are read raw (debug only).
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

      -- Ethernet station address for the NE1000 (core clock domain, see header)
      eth_mac_o        : out std_logic_vector(47 downto 0);
      eth_mac_valid_o  : out std_logic;

      -- Internal floppy drive: sector engine command interface (core clock domain, see header)
      flp_cmd_o        : out std_logic;                        -- one-clock pulse
      flp_cmd_code_o   : out std_logic_vector(3 downto 0);
      flp_arg0_o       : out std_logic_vector(15 downto 0);
      flp_arg1_o       : out std_logic_vector(15 downto 0);
      flp_enable_o     : out std_logic;
      flp_chg_clr_o    : out std_logic;                        -- one-clock pulse
      flp_blk_err_o    : out std_logic;                        -- level, for mgmt_bridge
      flp_busy_i       : in  std_logic := '0';
      flp_res_i        : in  std_logic_vector(95 downto 0) := (others => '0');   -- result words 0..5, word 0 in 15..0
      flp_live_i       : in  std_logic_vector(6 downto 0)  := (others => '0');   -- wp, chg sticky, track0, motor, index seen, chg live, cache valid
      flp_dbg_i        : in  std_logic_vector(95 downto 0) := (others => '0');   -- debug words 6..11

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

   -- MAC register window (see header)
   constant C_WIN_MAC   : std_logic_vector(15 downto 0) := x"FFFE";
   -- floppy engine register window (see header)
   constant C_WIN_FLP   : std_logic_vector(15 downto 0) := x"FFFD";

   -- QNICE side
   signal q_selected    : std_logic;
   signal q_csr         : std_logic;                       -- access to the CRT/ROM control window (0xFFFF)
   signal q_mac_win     : std_logic;                       -- access to the MAC register window (0xFFFE)
   signal q_mac         : std_logic_vector(47 downto 0) := (others => '0');
   signal q_mac_valid   : std_logic := '0';
   signal q_mac_src     : std_logic := '0';
   signal q_mac_rd      : std_logic_vector(15 downto 0);

   -- floppy engine registers, QNICE side
   signal q_flp_win     : std_logic;
   signal q_flp_cmd     : std_logic_vector(3 downto 0) := (others => '0');
   signal q_flp_arg0    : std_logic_vector(15 downto 0) := (others => '0');
   signal q_flp_arg1    : std_logic_vector(15 downto 0) := (others => '0');
   signal q_flp_enable  : std_logic := '0';
   signal q_flp_blk_err : std_logic := '0';
   signal q_flp_req     : std_logic := '0';                 -- command request toggle
   signal q_flp_ack     : std_logic;                        -- completion toggle, synchronised
   signal q_flp_ack_q   : std_logic := '0';
   signal q_flp_busy    : std_logic;
   signal q_flp_clr_tgl : std_logic := '0';                 -- disk-change clear toggle
   signal q_flp_res     : std_logic_vector(95 downto 0) := (others => '0');
   signal q_flp_live    : std_logic_vector(6 downto 0);
   signal q_flp_rd      : std_logic_vector(15 downto 0);
   -- floppy engine, core side
   signal c_flp_req     : std_logic;
   signal c_flp_req_q   : std_logic := '0';
   signal c_flp_ack     : std_logic := '0';
   signal c_flp_busy_q  : std_logic := '0';
   signal c_flp_clr     : std_logic;
   signal c_flp_clr_q   : std_logic := '0';
   signal c_flp_pend    : std_logic := '0';                 -- command issued, completion not yet seen
   signal c_flp_cmd_q   : std_logic := '0';
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
   signal c_mac_valid_s : std_logic;                       -- q_mac_valid, synchronised
   signal c_mac         : std_logic_vector(47 downto 0) := (others => '0');
   signal c_mac_valid   : std_logic := '0';

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

   -- MAC registers: only through the PCXT device id, never ROM data
   q_mac_win  <= '1' when qnice_dev_id_i = G_DEV_PCXT and qnice_dev_addr_i(27 downto 12) = C_WIN_MAC else '0';
   -- floppy engine registers: likewise
   q_flp_win  <= '1' when qnice_dev_id_i = G_DEV_PCXT and qnice_dev_addr_i(27 downto 12) = C_WIN_FLP else '0';

   q_pending  <= q_req_toggle xor q_ack_toggle;

   -- Wait while a word is pending, whenever this device is selected (like the
   -- framework's HyperRAM device): the CPU samples wait a cycle before its data
   -- strobe, so gating on ce/we would let a write slip through and be lost.
   qnice_dev_wait_o <= q_selected and q_pending;

   p_qnice : process (qnice_clk_i)
   begin
      if rising_edge(qnice_clk_i) then
         if q_selected = '1' and q_csr = '0' and q_mac_win = '0' and q_flp_win = '0' and qnice_dev_ce_i = '1' and qnice_dev_we_i = '1' and q_pending = '0' then
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

   -- MAC register writes (no wait: nothing is pending on this path)
   p_mac_qnice : process (qnice_clk_i)
   begin
      if rising_edge(qnice_clk_i) then
         if q_mac_win = '1' and qnice_dev_ce_i = '1' and qnice_dev_we_i = '1' then
            case qnice_dev_addr_i(3 downto 0) is
               when "0000" => q_mac(47 downto 32) <= qnice_dev_data_i;
               when "0001" => q_mac(31 downto 16) <= qnice_dev_data_i;
               when "0010" => q_mac(15 downto  0) <= qnice_dev_data_i;
               when "0011" => q_mac_valid <= qnice_dev_data_i(0);
                              q_mac_src   <= qnice_dev_data_i(1);
               when others => null;
            end case;
         end if;
         if qnice_rst_i = '1' then
            q_mac_valid <= '0';
            q_mac_src   <= '0';
         end if;
      end if;
   end process;

   q_mac_rd <= q_mac(47 downto 32)                  when qnice_dev_addr_i(3 downto 0) = "0000" else
               q_mac(31 downto 16)                  when qnice_dev_addr_i(3 downto 0) = "0001" else
               q_mac(15 downto  0)                  when qnice_dev_addr_i(3 downto 0) = "0010" else
               x"000" & "00" & q_mac_src & q_mac_valid when qnice_dev_addr_i(3 downto 0) = "0011" else
               x"EEEE";

   ---------------------------------------------------------------------------
   -- Floppy engine registers (see header)
   ---------------------------------------------------------------------------
   -- busy against the registered copy of the acknowledge: it clears in the same QNICE clock in which the
   -- results below are captured, so a read that sees "idle" always sees the new results
   q_flp_busy <= q_flp_req xor q_flp_ack_q;

   p_flp_qnice : process (qnice_clk_i)
   begin
      if rising_edge(qnice_clk_i) then
         if q_flp_win = '1' and qnice_dev_ce_i = '1' and qnice_dev_we_i = '1' then
            case qnice_dev_addr_i(3 downto 0) is
               when "0000" =>
                  if q_flp_busy = '0' then                 -- a command while busy is dropped
                     q_flp_cmd <= qnice_dev_data_i(3 downto 0);
                     q_flp_req <= not q_flp_req;
                  end if;
               when "0001" => q_flp_arg0 <= qnice_dev_data_i;
               when "0010" => q_flp_arg1 <= qnice_dev_data_i;
               when "0011" => q_flp_enable  <= qnice_dev_data_i(0);
                              q_flp_blk_err <= qnice_dev_data_i(2);
                              if qnice_dev_data_i(1) = '1' then
                                 q_flp_clr_tgl <= not q_flp_clr_tgl;
                              end if;
               when others => null;
            end case;
         end if;
         -- results: captured when the completion arrives (the engine wrote them >= 3 core clocks ago)
         q_flp_ack_q <= q_flp_ack;
         if q_flp_ack /= q_flp_ack_q then
            q_flp_res <= flp_res_i;
         end if;
         if qnice_rst_i = '1' then
            q_flp_enable  <= '0';
            q_flp_blk_err <= '0';
            q_flp_req     <= q_flp_ack_q;
         end if;
      end if;
   end process p_flp_qnice;

   q_flp_rd <= q_flp_busy & q_flp_live(6) & q_flp_live(5) & q_flp_live(4) & q_flp_live(3) &
               q_flp_live(2) & q_flp_live(1) & q_flp_live(0) & q_flp_res(7 downto 0)
                                                         when qnice_dev_addr_i(3 downto 0) = "0000" else
               q_flp_res(31 downto 16)                   when qnice_dev_addr_i(3 downto 0) = "0001" else
               q_flp_res(47 downto 32)                   when qnice_dev_addr_i(3 downto 0) = "0010" else
               q_flp_res(63 downto 48)                   when qnice_dev_addr_i(3 downto 0) = "0011" else
               q_flp_res(79 downto 64)                   when qnice_dev_addr_i(3 downto 0) = "0100" else
               q_flp_res(95 downto 80)                   when qnice_dev_addr_i(3 downto 0) = "0101" else
               flp_dbg_i(15 downto 0)                    when qnice_dev_addr_i(3 downto 0) = "0110" else
               flp_dbg_i(31 downto 16)                   when qnice_dev_addr_i(3 downto 0) = "0111" else
               flp_dbg_i(47 downto 32)                   when qnice_dev_addr_i(3 downto 0) = "1000" else
               flp_dbg_i(63 downto 48)                   when qnice_dev_addr_i(3 downto 0) = "1001" else
               flp_dbg_i(79 downto 64)                   when qnice_dev_addr_i(3 downto 0) = "1010" else
               flp_dbg_i(95 downto 80)                   when qnice_dev_addr_i(3 downto 0) = "1011" else
               x"EEEE";

   i_flp_req_sync : xpm_cdc_single
      generic map (DEST_SYNC_FF => 3, SRC_INPUT_REG => 0)
      port map (src_clk => qnice_clk_i, src_in => q_flp_req, dest_clk => core_clk_i, dest_out => c_flp_req);

   i_flp_ack_sync : xpm_cdc_single
      generic map (DEST_SYNC_FF => 3, SRC_INPUT_REG => 0)
      port map (src_clk => core_clk_i, src_in => c_flp_ack, dest_clk => qnice_clk_i, dest_out => q_flp_ack);

   i_flp_clr_sync : xpm_cdc_single
      generic map (DEST_SYNC_FF => 3, SRC_INPUT_REG => 0)
      port map (src_clk => qnice_clk_i, src_in => q_flp_clr_tgl, dest_clk => core_clk_i, dest_out => c_flp_clr);

   i_flp_enable_sync : xpm_cdc_single
      generic map (DEST_SYNC_FF => 3, SRC_INPUT_REG => 0)
      port map (src_clk => qnice_clk_i, src_in => q_flp_enable, dest_clk => core_clk_i, dest_out => flp_enable_o);

   i_flp_err_sync : xpm_cdc_single
      generic map (DEST_SYNC_FF => 3, SRC_INPUT_REG => 0)
      port map (src_clk => qnice_clk_i, src_in => q_flp_blk_err, dest_clk => core_clk_i, dest_out => flp_blk_err_o);

   i_flp_live_sync : xpm_cdc_array_single
      generic map (WIDTH => 7, DEST_SYNC_FF => 3, SRC_INPUT_REG => 0)
      port map (src_clk => core_clk_i, src_in => flp_live_i, dest_clk => qnice_clk_i, dest_out => q_flp_live);

   -- core side: one cmd pulse per request toggle; the acknowledge toggles once the engine has been
   -- idle for a clock after the pulse (it either finished or never started the command)
   p_flp_core : process (core_clk_i)
   begin
      if rising_edge(core_clk_i) then
         flp_cmd_o     <= '0';
         flp_chg_clr_o <= '0';
         c_flp_req_q   <= c_flp_req;
         c_flp_clr_q   <= c_flp_clr;
         c_flp_busy_q  <= flp_busy_i;
         c_flp_cmd_q   <= flp_cmd_o;
         if c_flp_clr /= c_flp_clr_q then
            flp_chg_clr_o <= '1';
         end if;
         if c_flp_req /= c_flp_req_q then
            flp_cmd_o      <= '1';
            flp_cmd_code_o <= q_flp_cmd;                  -- stable: written before the toggle
            flp_arg0_o     <= q_flp_arg0;
            flp_arg1_o     <= q_flp_arg1;
            c_flp_pend     <= '1';
         elsif c_flp_pend = '1' and flp_busy_i = '0' and c_flp_busy_q = '0' and flp_cmd_o = '0' and c_flp_cmd_q = '0' then
            c_flp_ack  <= not c_flp_ack;
            c_flp_pend <= '0';
         end if;
         if core_rst_i = '1' then
            c_flp_req_q <= c_flp_req;
            c_flp_clr_q <= c_flp_clr;
            c_flp_ack   <= '0';
            c_flp_pend  <= '0';
            flp_cmd_o   <= '0';
         end if;
      end if;
   end process p_flp_core;

   ---------------------------------------------------------------------------
   -- Clock domain crossing (toggle handshake, both ways)
   ---------------------------------------------------------------------------

   i_req_sync : xpm_cdc_single
      generic map (DEST_SYNC_FF => 3, SRC_INPUT_REG => 0)
      port map (src_clk => qnice_clk_i, src_in => q_req_toggle, dest_clk => core_clk_i, dest_out => c_req_toggle);

   i_ack_sync : xpm_cdc_single
      generic map (DEST_SYNC_FF => 3, SRC_INPUT_REG => 0)
      port map (src_clk => core_clk_i, src_in => c_ack_toggle, dest_clk => qnice_clk_i, dest_out => q_ack_toggle);

   i_mac_valid_sync : xpm_cdc_single
      generic map (DEST_SYNC_FF => 3, SRC_INPUT_REG => 0)
      port map (src_clk => qnice_clk_i, src_in => q_mac_valid, dest_clk => core_clk_i, dest_out => c_mac_valid_s);

   -- Capture the address once its valid flag has crossed: the firmware wrote
   -- the three words at least a QNICE bus cycle before the flag, and the flag
   -- needs three core clocks more, so q_mac is long stable when sampled here.
   -- Level-based so that a core reset (which clears the capture) or a
   -- firmware rewrite (flag low, words, flag high) both end with a fresh copy.
   p_mac_core : process (core_clk_i)
   begin
      if rising_edge(core_clk_i) then
         if c_mac_valid_s = '0' then
            c_mac_valid <= '0';
         elsif c_mac_valid = '0' then
            c_mac       <= q_mac;
            c_mac_valid <= '1';
         end if;
         if core_rst_i = '1' then
            c_mac_valid <= '0';
         end if;
      end if;
   end process;

   eth_mac_o       <= c_mac;
   eth_mac_valid_o <= c_mac_valid;

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
   -- 3/4/5 = checksums of pcxt.rom / ega_bios.rom / xtide.rom words, 6/7 = debug counters.
   -- Window 0xFFFE reads back the MAC registers instead, 0xFFFD the floppy engine registers.
   qnice_dev_data_o <= q_mac_rd                       when q_mac_win = '1' else
                       q_flp_rd                       when q_flp_win = '1' else
                       dbg_flags_i & "00000" & c_word_valid & c_download & c_rom_wait_q when qnice_dev_addr_i(3 downto 0) = "0000" else
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
