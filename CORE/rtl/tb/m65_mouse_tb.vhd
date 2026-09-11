-- m65_mouse_tb: self-checking bench for m65_mouse_ps2.vhd (MEGA65 joystick port -> PS/2 mouse device).
--
-- The host model behaves like MSMouseWrapper (CORE/rtl/overlay/MSMouseWrapper.v): to send a command it
-- pulls its clock low for 100 us, then drops data and releases the clock in the same instant, and shifts
-- one bit per falling edge of the device clock (8 data, odd parity, stop); on the 11th clock it checks the
-- device's ACK. Device bytes are sampled on the falling edge of the device clock while the host is quiet.
--
-- Sequence: FF -> FA AA 00; F2/F3/E8/E6/E9 replies; unknown command and bad parity -> FE; no packets
-- before F4; F4 -> FA; 1351 pot deltas (sign, magnitude, 6-bit wraparound, noise bit), packet rate bound,
-- 1351 buttons (fire = left, up = right); a host inhibit in the middle of a packet (retransmission);
-- Amiga quadrature on (right,down) / (left,up) and its buttons (fire, POTX, POTY); mode 00 is silent;
-- FF while streaming stops reporting; F5; remote mode F0/EB; FE resend.
-- Run with run_m65_mouse_tb.ps1 (xsim). Prints "RESULT: PASS (n checks)" or "RESULT: FAIL".

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity m65_mouse_tb is
end entity m65_mouse_tb;

architecture sim of m65_mouse_tb is

   constant C_BAT_MS    : natural := 20;
   constant C_REPORT_MS : natural := 10;

   signal clk        : std_logic := '0';
   signal rst        : std_logic := '1';
   signal mode       : std_logic_vector(1 downto 0) := "01";
   signal up_n       : std_logic := '1';
   signal down_n     : std_logic := '1';
   signal left_n     : std_logic := '1';
   signal right_n    : std_logic := '1';
   signal fire_n     : std_logic := '1';
   signal pot_x      : std_logic_vector(7 downto 0) := x"40";
   signal pot_y      : std_logic_vector(7 downto 0) := x"40";
   signal host_clk   : std_logic := '1';
   signal host_data  : std_logic := '1';
   signal ps2_clk    : std_logic;
   signal ps2_data   : std_logic;

   -- host receiver
   type byte_arr is array (0 to 255) of std_logic_vector(7 downto 0);
   type time_arr is array (0 to 255) of time;
   signal rx_q        : byte_arr := (others => x"00");
   signal rx_t        : time_arr := (others => 0 ns);   -- start bit time of each byte
   signal rx_wr       : natural := 0;
   signal frame_errs  : natural := 0;
   signal rate_errs   : natural := 0;
   signal aborted     : natural := 0;                    -- frames dropped by a host inhibit
   signal host_sending : boolean := false;
   signal done        : boolean := false;

begin

   clk <= not clk after 10 ns when not done;             -- 50 MHz

   dut : entity work.m65_mouse_ps2
      generic map (
         G_BAT_MS    => C_BAT_MS,
         G_REPORT_MS => C_REPORT_MS
      )
      port map (
         clk_i         => clk,
         rst_i         => rst,
         mode_i        => mode,
         joy_up_n_i    => up_n,
         joy_down_n_i  => down_n,
         joy_left_n_i  => left_n,
         joy_right_n_i => right_n,
         joy_fire_n_i  => fire_n,
         pot_x_i       => pot_x,
         pot_y_i       => pot_y,
         host_clk_i    => host_clk,
         host_data_i   => host_data,
         ps2_clk_o     => ps2_clk,
         ps2_data_o    => ps2_data
      );

   ---------------------------------------------------------------------------
   -- host receiver: samples device data on the falling device clock, checks
   -- the frame and the bit rate, drops a frame when the host inhibits
   ---------------------------------------------------------------------------
   p_host_rx : process
      variable frame  : std_logic_vector(10 downto 0);
      variable par    : std_logic;
      variable t0, t1 : time;
      variable abort  : boolean;
   begin
      loop
         wait until falling_edge(ps2_clk);
         next when host_sending or host_clk = '0';
         t0 := now;
         frame(0) := ps2_data;
         abort := false;
         for i in 1 to 10 loop
            wait until falling_edge(ps2_clk) or host_clk = '0' for 1 ms;
            if host_clk = '0' or ps2_clk /= '0' then
               abort := true;
               exit;
            end if;
            frame(i) := ps2_data;
            if i = 1 then
               t1 := now - t0;
               if t1 < 60 us or t1 > 100 us then
                  rate_errs <= rate_errs + 1;
                  report "bit period " & time'image(t1) & " outside 60..100 us" severity error;
               end if;
            end if;
         end loop;
         if abort then
            aborted <= aborted + 1;
            report "frame aborted by host inhibit at " & time'image(now);
         else
            par := '1';
            for i in 1 to 8 loop
               par := par xor frame(i);
            end loop;
            if frame(0) /= '0' or frame(10) /= '1' or frame(9) /= par then
               frame_errs <= frame_errs + 1;
               report "bad frame at " & time'image(t0) severity error;
            end if;
            rx_q(rx_wr) <= frame(8 downto 1);
            rx_t(rx_wr) <= t0;
            rx_wr <= rx_wr + 1;
            wait for 0 ns;
         end if;
      end loop;
   end process p_host_rx;

   ---------------------------------------------------------------------------
   -- test sequence
   ---------------------------------------------------------------------------
   p_test : process
      variable checks : natural := 0;
      variable errors : natural := 0;
      variable rx_rd  : natural := 0;
      variable t0     : time;
      variable b1, b2, b3 : std_logic_vector(7 downto 0);
      variable dx, dy : integer;
      variable sum    : integer;
      variable n0     : natural;

      procedure check(cond : boolean; what : string) is
      begin
         checks := checks + 1;
         if not cond then
            errors := errors + 1;
            report "FAIL: " & what & " (t=" & time'image(now) & ")" severity error;
         end if;
      end procedure;

      function hex(v : std_logic_vector(7 downto 0)) return string is
         constant digits : string := "0123456789ABCDEF";
      begin
         return digits(to_integer(unsigned(v(7 downto 4))) + 1) & digits(to_integer(unsigned(v(3 downto 0))) + 1);
      end function;

      -- wait for a falling edge of the device clock, false on timeout
      procedure wait_fall(constant tmo : time; variable ok : out boolean) is
         variable t : time;
      begin
         t := now;
         wait until falling_edge(ps2_clk) for tmo;
         ok := (now - t) < tmo;
      end procedure;

      -- MSMouseWrapper-style host transmission
      procedure host_send(constant b : std_logic_vector(7 downto 0); constant bad_parity : boolean := false) is
         variable par : std_logic;
         variable ok  : boolean;
         variable t   : time;
      begin
         wait for 70 us;                                  -- MSMouseWrapper's PS2PERIOD before it reacts to a byte
         host_sending <= true;
         host_clk  <= '0';                                -- inhibit
         wait for 100 us;
         host_data <= '0';                                -- request to send: data low, clock released
         host_clk  <= '1';
         par := '1';
         for i in 0 to 7 loop
            par := par xor b(i);
         end loop;
         if bad_parity then
            par := not par;
         end if;
         for i in 0 to 7 loop
            wait_fall(2 ms, ok);
            check(ok, "device clock for host bit " & integer'image(i) & " of " & hex(b));
            host_data <= b(i);
         end loop;
         wait_fall(2 ms, ok);
         check(ok, "device clock for parity of " & hex(b));
         host_data <= par;
         wait_fall(2 ms, ok);
         check(ok, "device clock for stop of " & hex(b));
         host_data <= '1';
         wait_fall(2 ms, ok);
         check(ok, "device clock for ack of " & hex(b));
         check(ps2_data = '0', "device ACK bit low at 11th clock of " & hex(b));
         t := now;
         wait until rising_edge(ps2_clk) for 200 us;
         check((now - t) < 200 us, "11th clock released for " & hex(b));
         wait for 5 us;
         check(ps2_data = '1', "device released data after ACK of " & hex(b));
         t := now;
         wait until falling_edge(ps2_clk) for 100 us;
         check((now - t) >= 100 us, "device generated exactly 11 clocks for " & hex(b));
         host_sending <= false;
      end procedure;

      procedure expect_byte(constant b : std_logic_vector(7 downto 0); constant what : string;
                            constant tmo : time := 100 ms) is
         variable t : time;
      begin
         t := now;
         if rx_wr <= rx_rd then
            wait until rx_wr > rx_rd for tmo;
         end if;
         if rx_wr > rx_rd then
            check(rx_q(rx_rd) = b, what & ": expected " & hex(b) & " got " & hex(rx_q(rx_rd)));
            rx_rd := rx_rd + 1;
         else
            check(false, what & ": expected " & hex(b) & ", nothing received in " & time'image(tmo));
         end if;
      end procedure;

      -- wait for a whole 3-byte packet, decode it
      procedure get_packet(variable dx, dy : out integer; variable b1 : out std_logic_vector(7 downto 0);
                           constant what : string; constant tmo : time := 100 ms) is
         variable v1, v2, v3 : std_logic_vector(7 downto 0);
      begin
         if rx_wr < rx_rd + 3 then
            wait until rx_wr >= rx_rd + 3 for tmo;
         end if;
         if rx_wr >= rx_rd + 3 then
            v1 := rx_q(rx_rd);
            v2 := rx_q(rx_rd + 1);
            v3 := rx_q(rx_rd + 2);
            rx_rd := rx_rd + 3;
            check(v1(3) = '1', what & ": packet sync bit (byte 1 = " & hex(v1) & ")");
            check(v1(7 downto 6) = "00", what & ": no overflow flags (byte 1 = " & hex(v1) & ")");
            dx := to_integer(signed(v1(4) & v2));
            dy := to_integer(signed(v1(5) & v3));
            b1 := v1;
         else
            check(false, what & ": no packet within " & time'image(tmo) & " (have " &
                         integer'image(rx_wr - rx_rd) & " bytes)");
            dx := 0;
            dy := 0;
            b1 := x"00";
         end if;
      end procedure;

      procedure expect_packet(constant edx, edy : integer; constant ebtn : std_logic_vector(2 downto 0);
                              constant what : string) is
         variable dx, dy : integer;
         variable b1     : std_logic_vector(7 downto 0);
      begin
         get_packet(dx, dy, b1, what);
         check(dx = edx, what & ": dX expected " & integer'image(edx) & " got " & integer'image(dx));
         check(dy = edy, what & ": dY expected " & integer'image(edy) & " got " & integer'image(dy));
         check(b1(2 downto 0) = ebtn, what & ": buttons (byte 1 = " & hex(b1) & ")");
      end procedure;

      procedure expect_quiet(constant t : time; constant what : string) is
      begin
         wait for t;
         check(rx_wr = rx_rd, what & ": expected no bytes, got " & integer'image(rx_wr - rx_rd));
         rx_rd := rx_wr;
      end procedure;

      -- Amiga quadrature: one step of the MEGA65's +1 sequence on a line pair (a, b) starting
      -- from and ending at the idle state "11": 11 -> a0 -> 00 -> 0b ... see mouse_input.vhdl.
      -- X+ (right) on (right, down): 11 -> 10 -> 00 -> 01 -> 11
      procedure amiga_x(constant steps : integer) is
         variable q : std_logic_vector(1 downto 0);
      begin
         for i in 1 to abs(steps) loop
            q := right_n & down_n;
            if steps > 0 then
               case q is
                  when "11" => right_n <= '1'; down_n <= '0';
                  when "10" => right_n <= '0'; down_n <= '0';
                  when "00" => right_n <= '0'; down_n <= '1';
                  when others => right_n <= '1'; down_n <= '1';
               end case;
            else
               case q is
                  when "11" => right_n <= '0'; down_n <= '1';
                  when "01" => right_n <= '0'; down_n <= '0';
                  when "00" => right_n <= '1'; down_n <= '0';
                  when others => right_n <= '1'; down_n <= '1';
               end case;
            end if;
            wait for 500 us;
         end loop;
      end procedure;
      -- Y+ (up) on (left, up): 11 -> 01 -> 00 -> 10 -> 11
      procedure amiga_y(constant steps : integer) is
         variable q : std_logic_vector(1 downto 0);
      begin
         for i in 1 to abs(steps) loop
            q := left_n & up_n;
            if steps > 0 then
               case q is
                  when "11" => left_n <= '0'; up_n <= '1';
                  when "01" => left_n <= '0'; up_n <= '0';
                  when "00" => left_n <= '1'; up_n <= '0';
                  when others => left_n <= '1'; up_n <= '1';
               end case;
            else
               case q is
                  when "11" => left_n <= '1'; up_n <= '0';
                  when "10" => left_n <= '0'; up_n <= '0';
                  when "00" => left_n <= '0'; up_n <= '1';
                  when others => left_n <= '1'; up_n <= '1';
               end case;
            end if;
            wait for 500 us;
         end loop;
      end procedure;

      -- move the 1351 position by dpos counts (pot bits 6..1), keeping bit 0 and 7
      procedure pot_move(signal pot : inout std_logic_vector(7 downto 0); constant dpos : integer) is
         variable pos : unsigned(5 downto 0);
      begin
         pos := unsigned(pot(6 downto 1)) + to_unsigned(dpos mod 64, 6);
         pot <= pot(7) & std_logic_vector(pos) & pot(0);
      end procedure;

   begin
      wait for 200 ns;
      rst <= '0';

      ------------------------------------------------------------------ 1. power-up init, like MSMouseWrapper
      wait for 1 ms;
      host_send(x"FF");
      expect_byte(x"FA", "reset ack");
      t0 := now;
      expect_byte(x"AA", "BAT");
      check(now - t0 >= (C_BAT_MS - 2) * 1 ms, "BAT after the self test delay");
      expect_byte(x"00", "mouse ID after BAT");
      expect_quiet(5 ms, "after reset");

      ------------------------------------------------------------------ 2. no packets before F4
      pot_move(pot_x, 5);
      fire_n <= '0';
      expect_quiet(30 ms, "movement before enable");
      fire_n <= '1';

      ------------------------------------------------------------------ 3. command replies
      host_send(x"F2");
      expect_byte(x"FA", "F2 ack");
      expect_byte(x"00", "F2 ID");
      host_send(x"F3");
      expect_byte(x"FA", "F3 ack");
      host_send(x"64");
      expect_byte(x"FA", "F3 argument ack");
      host_send(x"E8");
      expect_byte(x"FA", "E8 ack");
      host_send(x"03");
      expect_byte(x"FA", "E8 argument ack");
      host_send(x"E6");
      expect_byte(x"FA", "E6 ack");
      host_send(x"E9");
      expect_byte(x"FA", "E9 ack");
      expect_byte(x"00", "E9 status (stream, disabled, 1:1, no buttons)");
      expect_byte(x"03", "E9 resolution");
      expect_byte(x"64", "E9 sample rate");
      expect_quiet(2 ms, "after E9");

      ------------------------------------------------------------------ 4. unknown command, parity error
      host_send(x"99");
      expect_byte(x"FE", "unknown command");
      host_send(x"FF", bad_parity => true);
      expect_byte(x"FE", "parity error");
      expect_quiet(30 ms, "no BAT after a corrupted reset");

      ------------------------------------------------------------------ 5. enable
      host_send(x"F4");
      expect_byte(x"FA", "F4 ack");
      expect_quiet(15 ms, "no packet without motion");

      ------------------------------------------------------------------ 6. 1351 deltas
      pot_move(pot_x, 5);
      pot_move(pot_y, -3);
      expect_packet(5, -3, "000", "1351 +5/-3");
      expect_quiet(25 ms, "single packet for one move");

      -- wraparound: 63 -> 1 is +2, not -62; bit 0 is noise
      pot_x <= pot_x(7) & "111111" & pot_x(0);
      get_packet(dx, dy, b1, "1351 to position 63");
      check(dy = 0, "1351 to 63: dY 0");
      pot_x <= pot_x(7) & "000001" & pot_x(0);
      expect_packet(2, 0, "000", "1351 wrap 63 -> 1");
      pot_x(0) <= not pot_x(0);
      pot_x(7) <= not pot_x(7);
      expect_quiet(25 ms, "noise bit and bit 7 ignored");
      pot_move(pot_y, 31);
      expect_packet(0, 31, "000", "1351 +31 (max per sample)");
      pot_move(pot_y, -32);
      expect_packet(0, -32, "000", "1351 -32 (min per sample)");

      ------------------------------------------------------------------ 7. packet rate bound
      n0 := rx_wr;
      sum := 0;
      for i in 1 to 4 loop
         pot_move(pot_x, 1);
         wait for 3 ms;
      end loop;
      wait for 25 ms;
      check((rx_wr - n0) mod 3 = 0, "rate test: whole packets");
      check((rx_wr - n0) <= 6, "rate test: at most 2 packets for 12 ms of motion");
      while rx_wr >= rx_rd + 3 loop
         get_packet(dx, dy, b1, "rate test packet");
         sum := sum + dx;
         if rx_rd - 3 > n0 then
            check(rx_t(rx_rd - 3) - rx_t(rx_rd - 6) >= (C_REPORT_MS * 1 ms) - 500 us,
                  "rate test: packets at least " & integer'image(C_REPORT_MS) & " ms apart");
         end if;
      end loop;
      check(sum = 4, "rate test: motion sums to +4, got " & integer'image(sum));

      ------------------------------------------------------------------ 8. 1351 buttons
      fire_n <= '0';
      expect_packet(0, 0, "001", "1351 left button press");
      fire_n <= '1';
      expect_packet(0, 0, "000", "1351 left button release");
      up_n <= '0';
      expect_packet(0, 0, "010", "1351 right button press (up line)");
      up_n <= '1';
      expect_packet(0, 0, "000", "1351 right button release");
      pot_move(pot_x, -7);
      expect_packet(-7, 0, "000", "1351 -7");
      expect_quiet(15 ms, "after buttons");

      ------------------------------------------------------------------ 9. host inhibit in mid packet
      pot_move(pot_x, 4);
      wait until falling_edge(ps2_clk);                    -- packet byte 1 start bit
      wait for 250 us;                                     -- ~3 bits in
      host_clk <= '0';
      wait for 300 us;
      host_clk <= '1';
      expect_packet(4, 0, "000", "packet re-sent after host inhibit");
      check(aborted = 1, "host inhibit dropped one frame");
      expect_quiet(15 ms, "after inhibit");

      ------------------------------------------------------------------ 10. Amiga mouse
      mode  <= "10";
      pot_x <= x"00";                                      -- right button released
      pot_y <= x"00";                                      -- middle button released
      wait for 2 ms;
      expect_quiet(15 ms, "mode switch is silent");
      amiga_x(4);
      expect_packet(4, 0, "000", "Amiga X+ 4 steps (right)");
      amiga_x(-4);
      expect_packet(-4, 0, "000", "Amiga X- 4 steps (left)");
      amiga_y(4);
      expect_packet(0, 4, "000", "Amiga Y+ 4 steps (up)");
      amiga_y(-3);
      expect_packet(0, -3, "000", "Amiga Y- 3 steps (down)");
      amiga_y(-1);
      expect_packet(0, -1, "000", "Amiga Y- 1 step back to idle");
      fire_n <= '0';
      expect_packet(0, 0, "001", "Amiga left button");
      pot_x <= x"FF";
      expect_packet(0, 0, "011", "Amiga right button (POTX grounded)");
      fire_n <= '1';
      pot_y <= x"F0";
      expect_packet(0, 0, "110", "Amiga middle button (POTY grounded)");
      pot_x <= x"00";
      pot_y <= x"00";
      expect_packet(0, 0, "000", "Amiga buttons released");
      amiga_x(2);
      amiga_y(2);
      wait for 30 ms;                                      -- may be split over two packets
      sum := 0;
      n0 := 0;
      while rx_wr >= rx_rd + 3 loop
         get_packet(dx, dy, b1, "Amiga diagonal");
         sum := sum + dx + dy;
         n0 := n0 + 1;
      end loop;
      check(n0 >= 1 and n0 <= 2, "Amiga diagonal: 1 or 2 packets");
      check(sum = 4, "Amiga diagonal sums to +4, got " & integer'image(sum));
      amiga_x(-2);
      amiga_y(-2);
      wait for 30 ms;
      rx_rd := rx_wr;

      ------------------------------------------------------------------ 11. mode 00
      mode <= "00";
      wait for 2 ms;
      amiga_x(4);
      fire_n <= '0';
      up_n <= '0';
      pot_move(pot_x, 9);
      expect_quiet(30 ms, "mode 00 reports nothing");
      fire_n <= '1';
      up_n <= '1';
      amiga_x(-4);
      expect_quiet(20 ms, "mode 00 still silent");

      ------------------------------------------------------------------ 12. reset while streaming
      mode <= "01";
      pot_x <= x"40";
      pot_y <= x"40";
      wait for 15 ms;
      rx_rd := rx_wr;
      host_send(x"FF");
      expect_byte(x"FA", "2nd reset ack");
      expect_byte(x"AA", "2nd BAT");
      expect_byte(x"00", "2nd ID");
      pot_move(pot_x, 6);
      expect_quiet(30 ms, "reporting off after reset");
      host_send(x"F4");
      expect_byte(x"FA", "re-enable ack");
      pot_move(pot_y, 2);
      expect_packet(0, 2, "000", "1351 after re-enable (motion during disabled state dropped)");
      host_send(x"F5");
      expect_byte(x"FA", "F5 ack");
      pot_move(pot_y, 2);
      expect_quiet(30 ms, "F5 stops reporting");

      ------------------------------------------------------------------ 13. remote mode, resend
      host_send(x"F4");
      expect_byte(x"FA", "F4 ack again");
      host_send(x"F0");
      expect_byte(x"FA", "F0 ack");
      pot_move(pot_x, 3);
      pot_move(pot_y, -1);
      expect_quiet(30 ms, "remote mode does not stream");
      host_send(x"EB");
      expect_byte(x"FA", "EB ack");
      expect_packet(3, -1, "000", "EB packet");
      host_send(x"EB");
      expect_byte(x"FA", "2nd EB ack");
      expect_packet(0, 0, "000", "2nd EB packet is empty");
      host_send(x"EA");
      expect_byte(x"FA", "EA ack");
      host_send(x"FE");
      expect_byte(x"FA", "FE resends the last byte");
      pot_move(pot_x, 1);
      expect_packet(1, 0, "000", "stream mode again");

      ------------------------------------------------------------------ done
      wait for 5 ms;
      check(frame_errs = 0, "frame errors: " & integer'image(frame_errs));
      check(rate_errs = 0, "bit rate errors: " & integer'image(rate_errs));
      check(rx_wr = rx_rd, "no unexpected bytes at the end");
      report "bytes received: " & integer'image(rx_wr) & ", checks: " & integer'image(checks) &
             ", errors: " & integer'image(errors);
      if errors = 0 then
         report "RESULT: PASS (" & integer'image(checks) & " checks)";
      else
         report "RESULT: FAIL (" & integer'image(errors) & " of " & integer'image(checks) & " checks)";
      end if;
      done <= true;
      wait;
   end process p_test;

end architecture sim;
