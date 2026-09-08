-- keyboard_tb: MEGA65 key scan -> keyboard.vhd -> PS/2 frames -> host decoder.
-- Presses a few keys the way the framework scanner reports them (1 kHz sweep
-- over key numbers 0..79) and decodes the PS/2 frames like the chipset would
-- (data sampled on the falling clock edge, 11-bit frames, odd parity).
-- Checks the byte sequences for: 'a', cursor-up (E0 prefix), ':' (forced
-- shift), shift+':' = '[' (forced unshift while shift is held), HELP = F12.
-- Then plays the chipset's keyboard reset command (clock low, data low,
-- release clock, shift FF on the device's falling edges) and expects the
-- device to clock 11 pulses and reply FA, AA.
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
   signal host_sending : boolean := false;
   signal dev_pulses : natural := 0;
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
   -- (ignored while the host itself is sending)
   p_rx : process
      variable frame : std_logic_vector(10 downto 0);
   begin
      wait until falling_edge(ps2_clk);
      if host_sending then
         dev_pulses <= dev_pulses + 1;
         report "pulse at " & time'image(now);
      else
         report "frame start at " & time'image(now);
         frame(0) := ps2_data;                     -- start bit
         for i in 1 to 10 loop
            wait until falling_edge(ps2_clk);
            frame(i) := ps2_data;
         end loop;
         if frame(0) = '0' and frame(10) = '1' then
            rx_bytes(rx_count) <= frame(8 downto 1);
            rx_count <= rx_count + 1;
         else
            report "bad frame: " & std_logic'image(frame(0)) & std_logic'image(frame(1)) & std_logic'image(frame(2)) & std_logic'image(frame(3)) & std_logic'image(frame(4)) & std_logic'image(frame(5)) & std_logic'image(frame(6)) & std_logic'image(frame(7)) & std_logic'image(frame(8)) & std_logic'image(frame(9)) & std_logic'image(frame(10)) severity warning;
            frame_errors <= frame_errors + 1;
         end if;
      end if;
   end process;

   -- wire monitor around the host command
   p_mon : process
   begin
      wait until rising_edge(clk);
      if false then
         report "t=" & time'image(now) & " host_clk=" & std_logic'image(host_clk) & " host_data=" & std_logic'image(host_data) & " dev_clk=" & std_logic'image(ps2_clk) & " dev_data=" & std_logic'image(ps2_data) & " rx=" & integer'image(<< signal .keyboard_tb.dut.i_ps2_tx.rx_state : natural range 0 to 12 >>) & " tx=" & integer'image(<< signal .keyboard_tb.dut.i_ps2_tx.tx_state : natural range 0 to 11 >>) & " reply=" & integer'image(<< signal .keyboard_tb.dut.i_ps2_tx.rx_reply : natural range 0 to 2 >>) & " count=" & integer'image(to_integer(<< signal .keyboard_tb.dut.i_ps2_tx.count : unsigned(6 downto 0) >>)) & " wptr=" & integer'image(to_integer(<< signal .keyboard_tb.dut.i_ps2_tx.wptr : unsigned(5 downto 0) >>)) & " rptr=" & integer'image(to_integer(<< signal .keyboard_tb.dut.i_ps2_tx.rptr : unsigned(5 downto 0) >>)) & " flush=" & std_logic'image(<< signal .keyboard_tb.dut.i_ps2_tx.q_flush : std_logic >>) & " rwe=" & std_logic'image(<< signal .keyboard_tb.dut.i_ps2_tx.reply_we : std_logic >>);
      end if;
   end process;

   p_stim : process
      variable pulses0 : natural := 0;
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
      -- KFPS2KB_Send_Data: clock low, data low, release clock, one bit per
      -- falling edge of the device clock: start, d0..d7, parity, stop
      procedure host_send(b : std_logic_vector(7 downto 0)) is
         variable frame : std_logic_vector(9 downto 0);
         variable par   : std_logic := '1';
      begin
         for i in 0 to 7 loop if b(i) = '1' then par := not par; end if; end loop;
         frame := par & b & '0';
         host_sending <= true;
         host_clk <= '0';  wait for 120 us;
         host_data <= '0'; wait for 120 us;
         host_data <= frame(0);                   -- start bit shows before the first device clock
         host_clk <= '1';
         for i in 1 to 9 loop                     -- d0..d7, parity: shifted on each falling edge
            wait until falling_edge(ps2_clk);
            wait for 1 us;
            host_data <= frame(i);
         end loop;
         wait until falling_edge(ps2_clk);        -- 10th edge: stop bit
         wait for 1 us;
         host_data <= '1';
         wait until falling_edge(ps2_clk);        -- 11th pulse: device acknowledge
         wait for 1 us;
         host_data <= '1';
         wait until rising_edge(ps2_clk);
         wait for 10 us;
         host_sending <= false;
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

      -- keyboard reset from the host, then a key
      pulses0 := dev_pulses;
      host_send(x"FF");
      wait for 5 ms;
      if dev_pulses - pulses0 /= 11 then
         report "device clocked " & integer'image(dev_pulses) & " pulses for the host command, expected 11" severity error;
         errors <= errors + 1; wait for 1 ns;
      end if;
      expect(26, x"FA", "ack");        expect(27, x"AA", "self test");
      press(60); unpress(60);                     -- space after the reset -> 29, F0 29
      wait for 3 ms;
      expect(28, x"29", "space make"); expect(29, x"F0", "space break");    expect(30, x"29", "space break code");

      report "bytes received: " & integer'image(rx_count) & ", errors: " & integer'image(errors) & ", frame errors: " & integer'image(frame_errors);
      if errors = 0 and frame_errors = 0 and rx_count = 31 then
         report "RESULT: PASS";
      else
         report "RESULT: FAIL";
      end if;
      done <= true;
      wait;
   end process;
end architecture;
