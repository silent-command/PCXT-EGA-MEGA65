-------------------------------------------------------------------------------------------------------------
-- PCXT-EGA on MiSTer2MEGA65: block RAM backend for the byte-wide Avalon bus
--
-- Slave for the bus that CORE/rtl/overlay/KFSDRAM.sv drives on the chipset's
-- SDRAM pins: 22-bit byte address, 8-bit data, single beat, waitrequest,
-- readdatavalid. This is the Phase 3 bring-up memory; the HyperRAM backend
-- replaces it later without touching the core.
--
-- Map (the RAM.sv decoder only ever presents these ranges, see
-- docs/emu-signal-map.md 3.7):
--   00000-3FFFF  256 KB conventional RAM        (64 RAMB36)
--   C0000-CFFFF   64 KB EGA BIOS window          (16 RAMB36)
--   EC000-EFFFF   16 KB XT-IDE BIOS               (4 RAMB36)
--   F0000-FFFFF   64 KB PC/XT BIOS               (16 RAMB36)
-- Everything else reads as FF and ignores writes, so the BIOS memory scan
-- stops at 256 KB and the UMB/EMS ranges look empty.
--
-- ROM port: the BIOS images are written here directly from rom_loader.vhd
-- (the same ioctl-style stream that pcxt_core sees), one 16-bit word per
-- rom_wr_i pulse, two byte writes. The core's own loader FSM writes the
-- same words through the Avalon side a little later, but it was found to
-- drop the odd word depending on the arrival timing of the bytes from the
-- SD card (a missing EGA BIOS checksum byte = no video). A ROM write has
-- priority over an Avalon write in the same clock; the machine is in reset
-- while ROMs stream, so the only Avalon traffic then is the FSM's duplicate
-- of the very same word.
--
-- Timing: zero wait states, read data one clock after acceptance.
--
-- MiSTer2MEGA65 done by sy2002 and MJoergen in 2022 and licensed under GPL v3
-------------------------------------------------------------------------------------------------------------

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity mem_bram is
   port (
      clk_i               : in  std_logic;
      rst_i               : in  std_logic;

      avm_address_i       : in  std_logic_vector(21 downto 0);
      avm_writedata_i     : in  std_logic_vector(7 downto 0);
      avm_write_i         : in  std_logic;
      avm_read_i          : in  std_logic;
      avm_readdata_o      : out std_logic_vector(7 downto 0);
      avm_readdatavalid_o : out std_logic;
      avm_waitrequest_o   : out std_logic;

      -- ROM download port (rom_loader.vhd, same clock): index 0 = PC/XT BIOS
      -- at F0000, 2 = XT-IDE at EC000, 3 = EGA BIOS at C0000; rom_addr_i is
      -- the even byte offset within the file, rom_data_i the little-endian word
      rom_wr_i            : in  std_logic := '0';
      rom_index_i         : in  std_logic_vector(7 downto 0) := (others => '0');
      rom_addr_i          : in  std_logic_vector(24 downto 0) := (others => '0');
      rom_data_i          : in  std_logic_vector(15 downto 0) := (others => '0')
   );
end entity mem_bram;

architecture rtl of mem_bram is

   -- one process per region so each infers its own block RAM array
   type ram256k_t is array (0 to 262143) of std_logic_vector(7 downto 0);
   type ram64k_t  is array (0 to 65535)  of std_logic_vector(7 downto 0);
   type ram16k_t  is array (0 to 16383)  of std_logic_vector(7 downto 0);

   signal conv_ram  : ram256k_t;
   signal ega_ram   : ram64k_t;
   signal xtide_ram : ram16k_t;
   signal bios_ram  : ram64k_t;

   attribute ram_style : string;
   attribute ram_style of conv_ram  : signal is "block";
   attribute ram_style of ega_ram   : signal is "block";
   attribute ram_style of xtide_ram : signal is "block";
   attribute ram_style of bios_ram  : signal is "block";

   signal addr      : unsigned(21 downto 0);
   signal sel_conv  : std_logic;
   signal sel_ega   : std_logic;
   signal sel_xtide : std_logic;
   signal sel_bios  : std_logic;

   signal q_conv    : std_logic_vector(7 downto 0);
   signal q_ega     : std_logic_vector(7 downto 0);
   signal q_xtide   : std_logic_vector(7 downto 0);
   signal q_bios    : std_logic_vector(7 downto 0);

   signal sel_q     : std_logic_vector(3 downto 0);
   signal valid_q   : std_logic;

   -- ROM port: two byte writes per word
   signal rom_phase : std_logic_vector(1 downto 0) := "00";   -- "01" low byte, "10" high byte
   signal rom_a     : unsigned(15 downto 0) := (others => '0');
   signal rom_d     : std_logic_vector(15 downto 0) := (others => '0');
   signal rom_idx   : std_logic_vector(7 downto 0) := (others => '0');
   signal rom_we    : std_logic;
   signal rom_wa    : unsigned(15 downto 0);
   signal rom_wd    : std_logic_vector(7 downto 0);
   signal rom_ega   : std_logic;
   signal rom_xtide : std_logic;
   signal rom_bios  : std_logic;

   -- write side after the ROM/Avalon priority mux
   signal we_ega    : std_logic;
   signal we_xtide  : std_logic;
   signal we_bios   : std_logic;
   signal wa_ega    : unsigned(15 downto 0);
   signal wa_xtide  : unsigned(13 downto 0);
   signal wa_bios   : unsigned(15 downto 0);
   signal wd_ega    : std_logic_vector(7 downto 0);
   signal wd_xtide  : std_logic_vector(7 downto 0);
   signal wd_bios   : std_logic_vector(7 downto 0);

begin

   addr      <= unsigned(avm_address_i);
   sel_conv  <= '1' when addr(21 downto 18) = "0000"                         else '0';  -- 00000-3FFFF
   sel_ega   <= '1' when addr(21 downto 16) = "001100"                       else '0';  -- C0000-CFFFF
   sel_xtide <= '1' when addr(21 downto 14) = "00111011"                     else '0';  -- EC000-EFFFF
   sel_bios  <= '1' when addr(21 downto 16) = "001111"                       else '0';  -- F0000-FFFFF

   avm_waitrequest_o <= '0';

   ---------------------------------------------------------------------------
   -- ROM port sequencer
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

   -- ROM writes win; the Avalon write they displace is the FSM's copy of the same word
   we_ega   <= (rom_we and rom_ega)   or (avm_write_i and sel_ega);
   wa_ega   <= rom_wa when (rom_we and rom_ega) = '1' else addr(15 downto 0);
   wd_ega   <= rom_wd when (rom_we and rom_ega) = '1' else avm_writedata_i;

   we_xtide <= (rom_we and rom_xtide) or (avm_write_i and sel_xtide);
   wa_xtide <= rom_wa(13 downto 0) when (rom_we and rom_xtide) = '1' else addr(13 downto 0);
   wd_xtide <= rom_wd when (rom_we and rom_xtide) = '1' else avm_writedata_i;

   we_bios  <= (rom_we and rom_bios)  or (avm_write_i and sel_bios);
   wa_bios  <= rom_wa when (rom_we and rom_bios) = '1' else addr(15 downto 0);
   wd_bios  <= rom_wd when (rom_we and rom_bios) = '1' else avm_writedata_i;

   ---------------------------------------------------------------------------
   -- memories
   ---------------------------------------------------------------------------
   p_conv : process (clk_i)
   begin
      if rising_edge(clk_i) then
         if avm_write_i = '1' and sel_conv = '1' then
            conv_ram(to_integer(addr(17 downto 0))) <= avm_writedata_i;
         end if;
         q_conv <= conv_ram(to_integer(addr(17 downto 0)));
      end if;
   end process;

   p_ega : process (clk_i)
   begin
      if rising_edge(clk_i) then
         if we_ega = '1' then
            ega_ram(to_integer(wa_ega)) <= wd_ega;
         end if;
         q_ega <= ega_ram(to_integer(addr(15 downto 0)));
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

   p_out : process (clk_i)
   begin
      if rising_edge(clk_i) then
         valid_q <= avm_read_i;
         sel_q   <= sel_bios & sel_xtide & sel_ega & sel_conv;
         if rst_i = '1' then
            valid_q <= '0';
         end if;
      end if;
   end process;

   avm_readdatavalid_o <= valid_q;
   avm_readdata_o      <= q_conv  when sel_q(0) = '1' else
                          q_ega   when sel_q(1) = '1' else
                          q_xtide when sel_q(2) = '1' else
                          q_bios  when sel_q(3) = '1' else
                          x"FF";

end architecture rtl;
