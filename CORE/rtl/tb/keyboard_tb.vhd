-- keyboard_tb: MEGA65 key scan -> keyboard.vhd -> PS/2 frames -> host decoder.
-- Presses a few keys the way the framework scanner reports them (1 kHz sweep
-- over key numbers 0..79) and decodes the PS/2 frames like the chipset would
-- (data sampled on the falling clock edge, 11-bit frames, odd parity).
-- Checks the byte sequences for: 'a', cursor-up (E0 prefix), ':' (forced
-- shift), shift+':' = '[' (forced unshift while shift is held), HELP (nothing:
-- it belongs to the framework), shift+F11 = F12, the ":" -> ";" report ('*'
-- typed after a physical Shift was used around a shifted '*' must still get
-- its forced shift, in both release orders), ']' with the right Shift held
-- (forced unshift must break the shift key the PC actually has down).
-- Then plays the chipset's keyboard reset command (clock low, data low,
-- release clock, shift FF on the device's falling edges) and expects the
-- device to clock 11 pulses and reply FA, AA. Finally the host inhibits the
-- clock in the middle of a frame (the byte must be sent again once the line
-- is released) and right after a frame's stop bit (it must not be repeated).
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
   type byte_arr is array (0 to 127) of std_logic_vector(7 downto 0);
   signal rx_bytes   : byte_arr := (others => x"00");
   signal rx_count   : natural := 0;
   signal errors     : natural := 0;
   signal frame_errors : natural := 0;
   signal aborted_frames : natural := 0;
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
   -- (ignored while the host itself is sending); a frame the host inhibits
   -- (clock pulled low) before its stop bit is dropped, as the chipset's
   -- receiver would drop it
   p_rx : process
      variable frame   : std_logic_vector(10 downto 0);
      variable aborted : boolean;
   begin
      wait until falling_edge(ps2_clk);
      if host_sending then
         dev_pulses <= dev_pulses + 1;
         report "pulse at " & time'image(now);
      else
         report "frame start at " & time'image(now);
         frame(0) := ps2_data;                     -- start bit
         aborted  := false;
         for i in 1 to 10 loop
            wait until falling_edge(ps2_clk) or host_clk = '0';
            if host_clk = '0' then aborted := true; exit; end if;
            frame(i) := ps2_data;
         end loop;
         if aborted then
            report "frame aborted by the host at " & time'image(now);
            aborted_frames <= aborted_frames + 1;
            wait until host_clk = '1';
         elsif frame(0) = '0' and frame(10) = '1' then
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
      variable n       : natural := 0;             -- next byte index to check
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
      -- the next byte in sequence
      procedure nx(b : std_logic_vector(7 downto 0); what : string) is
      begin
         expect(n, b, what);
         n := n + 1;
      end;
      -- so far exactly n bytes must have arrived
      procedure count_is(what : string) is
      begin
         if rx_count /= n then
            report "MISMATCH " & what & ": " & integer'image(rx_count) & " bytes received, expected " & integer'image(n)
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
      press(67);  unpress(67);                    -- HELP: framework key, nothing
      press(15);  press(69); unpress(69); unpress(15);  -- shift+F11 = F12 -> 12, F0 12 07, F0 07 12, F0 12
      wait for 5 ms;

      nx(x"1C", "a make");      nx(x"F0", "a break");      nx(x"1C", "a break code");
      nx(x"E0", "up prefix");   nx(x"75", "up make");
      nx(x"E0", "up brk pfx");  nx(x"F0", "up break");     nx(x"75", "up break code");
      nx(x"12", ": shift on");  nx(x"4C", ": code");
      nx(x"F0", ": break");     nx(x"4C", ": break code");
      nx(x"F0", ": shift off"); nx(x"12", ": shift off code");
      nx(x"12", "shift make");
      nx(x"F0", "[ unshift");   nx(x"12", "[ unshift code"); nx(x"54", "[ make");
      nx(x"F0", "[ break");     nx(x"54", "[ break code");   nx(x"12", "[ reshift");
      nx(x"F0", "shift brk");   nx(x"12", "shift brk code");
      nx(x"12", "shift make (F12)");
      nx(x"F0", "F12 unshift"); nx(x"12", "F12 unshift code"); nx(x"07", "F12 make");
      nx(x"F0", "F12 break");   nx(x"07", "F12 break code");   nx(x"12", "F12 reshift");
      nx(x"F0", "shift brk");   nx(x"12", "shift brk code");
      count_is("after F12");

      -- the ":" -> ";" report, as reproduced on the board with '*': a forced-
      -- shift key typed after a physical Shift was held around a shifted
      -- forced-shift key (key released first, then the Shift) lost its shift
      press(49); unpress(49);                                 -- '*'         -> 12 3E, F0 3E F0 12
      press(15); press(49); unpress(49); unpress(15);         -- shift+'*' = '}' -> 12, 5B, F0 5B, F0 12
      press(49); unpress(49);                                 -- '*' again   -> 12 3E, F0 3E F0 12   (was: 3E alone = "8")
      press(15); press(49); unpress(15); unpress(49);         -- '}' again, Shift released first -> 12, 5B, F0 12, F0 5B
      press(45); unpress(45);                                 -- ':'         -> 12 4C, F0 4C F0 12
      press(52); press(50); unpress(50); unpress(52);         -- right shift+';' = ']' -> 59, F0 59 5B, F0 5B 59, F0 59
      wait for 5 ms;

      nx(x"12", "* shift on");  nx(x"3E", "* code");   nx(x"F0", "* break"); nx(x"3E", "* break code"); nx(x"F0", "* shift off"); nx(x"12", "* shift off code");
      nx(x"12", "shift make");  nx(x"5B", "} code");   nx(x"F0", "} break"); nx(x"5B", "} break code"); nx(x"F0", "shift brk");    nx(x"12", "shift brk code");
      nx(x"12", "* shift on (after Shift)"); nx(x"3E", "* code (after Shift)"); nx(x"F0", "* break"); nx(x"3E", "* break code"); nx(x"F0", "* shift off"); nx(x"12", "* shift off code");
      nx(x"12", "shift make");  nx(x"5B", "} code");   nx(x"F0", "shift brk"); nx(x"12", "shift brk code"); nx(x"F0", "} break"); nx(x"5B", "} break code");
      nx(x"12", ": shift on (after Shift)"); nx(x"4C", ": code");   nx(x"F0", ": break"); nx(x"4C", ": break code"); nx(x"F0", ": shift off"); nx(x"12", ": shift off code");
      nx(x"59", "rshift make");
      nx(x"F0", "] unshift");   nx(x"59", "] unshift code"); nx(x"5B", "] make");
      nx(x"F0", "] break");     nx(x"5B", "] break code");   nx(x"59", "] reshift");
      nx(x"F0", "rshift brk");  nx(x"59", "rshift brk code");
      count_is("after the shift sequences");

      -- keyboard reset from the host, then a key
      pulses0 := dev_pulses;
      host_send(x"FF");
      wait for 5 ms;
      if dev_pulses - pulses0 /= 11 then
         report "device clocked " & integer'image(dev_pulses) & " pulses for the host command, expected 11" severity error;
         errors <= errors + 1; wait for 1 ns;
      end if;
      nx(x"FA", "ack");         nx(x"AA", "self test");
      press(60); unpress(60);                     -- space after the reset -> 29, F0 29
      wait for 3 ms;
      nx(x"29", "space make");  nx(x"F0", "space break");    nx(x"29", "space break code");
      count_is("after the reset");

      -- the host inhibits the clock in the middle of a frame (3 bits in): the
      -- device abandons the frame and sends the byte again once the line is
      -- released (PS/2: a byte interrupted before its stop bit is resent)
      pressed(60) <= '1';
      wait until falling_edge(ps2_clk);           -- start bit clocked
      wait for 250 us;                            -- ... three more bits
      host_clk <= '0';
      wait for 2 ms;
      host_clk <= '1';
      wait for 5 ms;
      unpress(60);
      if aborted_frames /= 1 then
         report "expected exactly one frame aborted by the mid-frame inhibit, saw " & integer'image(aborted_frames) severity error;
         errors <= errors + 1; wait for 1 ns;
      end if;
      nx(x"29", "space make resent after the inhibit"); nx(x"F0", "space break"); nx(x"29", "space break code");
      count_is("after the mid-frame inhibit (byte sent exactly once)");

      -- the host inhibits right after the stop bit was clocked (what the XT
      -- controller does on every byte): the byte is complete, not repeated
      pressed(60) <= '1';
      for i in 1 to 11 loop wait until falling_edge(ps2_clk); end loop;
      wait for 2 us;
      host_clk <= '0';
      wait for 2 ms;
      host_clk <= '1';
      wait for 5 ms;
      unpress(60);
      nx(x"29", "space make (inhibit after the stop bit)"); nx(x"F0", "space break"); nx(x"29", "space break code");
      count_is("after the post-stop-bit inhibit (byte not repeated)");

      report "bytes received: " & integer'image(rx_count) & ", errors: " & integer'image(errors) & ", frame errors: " & integer'image(frame_errors) & ", aborted frames: " & integer'image(aborted_frames);
      if errors = 0 and frame_errors = 0 and rx_count = n then
         report "RESULT: PASS";
      else
         report "RESULT: FAIL";
      end if;
      done <= true;
      wait;
   end process;
end architecture;
