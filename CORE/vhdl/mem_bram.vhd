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
      avm_waitrequest_o   : out std_logic
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

begin

   addr      <= unsigned(avm_address_i);
   sel_conv  <= '1' when addr(21 downto 18) = "0000"                         else '0';  -- 00000-3FFFF
   sel_ega   <= '1' when addr(21 downto 16) = "001100"                       else '0';  -- C0000-CFFFF
   sel_xtide <= '1' when addr(21 downto 14) = "00111011"                     else '0';  -- EC000-EFFFF
   sel_bios  <= '1' when addr(21 downto 16) = "001111"                       else '0';  -- F0000-FFFFF

   avm_waitrequest_o <= '0';

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
         if avm_write_i = '1' and sel_ega = '1' then
            ega_ram(to_integer(addr(15 downto 0))) <= avm_writedata_i;
         end if;
         q_ega <= ega_ram(to_integer(addr(15 downto 0)));
      end if;
   end process;

   p_xtide : process (clk_i)
   begin
      if rising_edge(clk_i) then
         if avm_write_i = '1' and sel_xtide = '1' then
            xtide_ram(to_integer(addr(13 downto 0))) <= avm_writedata_i;
         end if;
         q_xtide <= xtide_ram(to_integer(addr(13 downto 0)));
      end if;
   end process;

   p_bios : process (clk_i)
   begin
      if rising_edge(clk_i) then
         if avm_write_i = '1' and sel_bios = '1' then
            bios_ram(to_integer(addr(15 downto 0))) <= avm_writedata_i;
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
