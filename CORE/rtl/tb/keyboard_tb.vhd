-- keyboard_tb: MEGA65 key scan -> keyboard.vhd -> PS/2 frames -> host decoder.
-- Presses a few keys the way the framework scanner reports them (1 kHz sweep
-- over key numbers 0..79) and decodes the PS/2 frames like the chipset would
-- (data sampled on the falling clock edge, 11-bit frames, odd parity).
-- Checks the byte sequences for: 'a', cursor-up (E0 prefix), ':' (forced
-- shift), shift+':' = '[' (forced unshift while shift is held), HELP = F12.
-- Run with run_keyboard_tb.sh (GHDL).

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity keyboard_tb is
end entity;

architecture sim of keyboard_tb is
   signal clk        : std_logic := '0';
   signal rst        : std_logic := '1';
   signal key_num    : integer range 0 to 79 := 0;
   signal key_pressed_n : std_logic := '1';
   signal pressed    : std_logic_vector(79 downto 0) := (others => '0');
   signal host_clk   : std_logic := '1';
   signal host_data  : std_logic := '1';
   signal ps2_clk    : std_logic;
   signal ps2_data   : std_logic;
   signal ps2_key    : std_logic_vector(10 downto 0);

   -- decoded bytes
   type byte_arr is array (0 to 63) of std_logic_vector(7 downto 0);
   signal rx_bytes   : byte_arr := (others => x"00");
   signal rx_count   : natural := 0;
   signal errors     : natural := 0;
   signal frame_errors : natural := 0;
   signal done       : boolean := false;
begin
   clk <= not clk after 10 ns when not done;      -- 50 MHz

   dut : entity work.keyboard
      port map (
         clk_main_i => clk, rst_i => rst,
         key_num_i => key_num, key_pressed_n_i => key_pressed_n,
         ps2_host_clk_i => host_clk, ps2_host_data_i => host_data,
         ps2_clk_o => ps2_clk, ps2_data_o => ps2_data, ps2_key_o => ps2_key);

   -- framework scanner model: 1 kHz sweep, ~12.5 us per key
   p_scan : process
   begin
      wait until rst = '0';
      loop
         for k in 0 to 79 loop
            key_num <= k;
            key_pressed_n <= not pressed(k);
            wait for 12500 ns;
         end loop;
      end loop;
   end process;

   -- host receiver: sample data on the falling edge of the device clock
   p_rx : process
      variable frame : std_logic_vector(10 downto 0);
   begin
      wait until falling_edge(ps2_clk);
      frame(0) := ps2_data;                     -- start bit
      for i in 1 to 10 loop
         wait until falling_edge(ps2_clk);
         frame(i) := ps2_data;
      end loop;
      if frame(0) = '0' and frame(10) = '1' then
         rx_bytes(rx_count) <= frame(8 downto 1);
         rx_count <= rx_count + 1;
      else
         report "bad frame" severity warning;
         frame_errors <= frame_errors + 1;
      end if;
   end process;

   p_stim : process
      procedure press(k : integer)   is begin pressed(k) <= '1'; wait for 3 ms; end;
      procedure unpress(k : integer) is begin pressed(k) <= '0'; wait for 3 ms; end;
      procedure expect(idx : natural; b : std_logic_vector(7 downto 0); what : string) is
      begin
         if idx >= rx_count or rx_bytes(idx) /= b then
            report "MISMATCH " & what & ": byte " & integer'image(idx) & " expected " &
                   integer'image(to_integer(unsigned(b))) & " got " &
                   integer'image(to_integer(unsigned(rx_bytes(idx)))) & " (count " & integer'image(rx_count) & ")"
                   severity error;
            errors <= errors + 1;
            wait for 1 ns;
         end if;
      end;
   begin
      wait for 200 ns;
      rst <= '0';
      wait for 2 ms;

      press(10);  unpress(10);                    -- 'a'           -> 1C, F0 1C
      press(73);  unpress(73);                    -- cursor up     -> E0 75, E0 F0 75
      press(45);  unpress(45);                    -- ':'           -> 12 4C, F0 4C F0 12
      press(15);  press(45); unpress(45); unpress(15);  -- shift+':' = '[' -> 12, F0 12 54, F0 54 12, F0 12
      press(67);  unpress(67);                    -- HELP = F12    -> 07, F0 07
      wait for 5 ms;

      expect(0,  x"1C", "a make");     expect(1,  x"F0", "a break");   expect(2,  x"1C", "a break code");
      expect(3,  x"E0", "up prefix");  expect(4,  x"75", "up make");
      expect(5,  x"E0", "up brk pfx"); expect(6,  x"F0", "up break");  expect(7,  x"75", "up break code");
      expect(8,  x"12", ": shift on"); expect(9,  x"4C", ": code");
      expect(10, x"F0", ": break");    expect(11, x"4C", ": break code");
      expect(12, x"F0", ": shift off");expect(13, x"12", ": shift off code");
      expect(14, x"12", "shift make");
      expect(15, x"F0", "[ unshift");  expect(16, x"12", "[ unshift code"); expect(17, x"54", "[ make");
      expect(18, x"F0", "[ break");    expect(19, x"54", "[ break code");   expect(20, x"12", "[ reshift");
      expect(21, x"F0", "shift brk");  expect(22, x"12", "shift brk code");
      expect(23, x"07", "F12 make");   expect(24, x"F0", "F12 break");      expect(25, x"07", "F12 break code");

      report "bytes received: " & integer'image(rx_count) & ", errors: " & integer'image(errors);
      if errors = 0 and frame_errors = 0 and rx_count = 26 then
         report "RESULT: PASS";
      else
         report "RESULT: FAIL";
      end if;
      done <= true;
      wait;
   end process;
end architecture;
