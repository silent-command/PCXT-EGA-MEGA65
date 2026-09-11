-------------------------------------------------------------------------------------------------------------
-- PCXT-EGA on MiSTer2MEGA65: PS/2 mouse DEVICE emulated from the MEGA65 joystick port 1
--
-- The core's serial-mouse bridge (MSMouseWrapper, CORE/rtl/overlay/MSMouseWrapper.v, instantiated in
-- CORE/PCXT-EGA_MiSTer/rtl/KFPC-XT/HDL/Peripherals.sv:1005 on `clock` = clk_chipset = 50 MHz, see
-- CORE/rtl/pcxt_core.sv:1233) is a PS/2 HOST that talks to a real PS/2 mouse. main.vhd currently ties
-- the device side to '1'. This entity is that mouse: it drives ps2_mouse_clk_i / ps2_mouse_data_i of
-- pcxt_core (device -> host) and listens on ps2_mouse_clk_o / ps2_mouse_data_o (host -> device).
--
-- What MSMouseWrapper does (line numbers in CORE/rtl/overlay/MSMouseWrapper.v, identical to upstream
-- plus a trailing `default_nettype):
--   :217-223  1 ms after the clock starts (no reset input!) it sends 0xFF (reset)
--   :227-256  expects 0xFA, then 0xAA, then 0x00 (BAT ok + mouse ID 0); any other byte restarts at 0xFF
--   :251-266  then sends 0xF4 (enable stream reporting) and expects 0xFA
--   :274-297  then consumes standard 3-byte packets forever: byte 1 must have bit 3 = 1 (sync, :180/:278),
--             bit 0 = left, bit 1 = right, bit 4 = X sign, bit 5 = Y sign (:176-179); bytes 2/3 are dX/dY
--             (it uses bits 7:1 with the sign bit prepended, :174-175, and negates Y for the serial
--             mouse). It never sends 0xF3 / 0xF2 / 0xF6 / 0xE8 and never asks for Intellimouse, so the
--             device reports ID 0x00 and plain 3-byte packets.
--   host -> device timing (:350-392): clock low for 100 us (:352-353), then data low and clock released
--             in the same cycle (:359 + ps2clk_out<=1), then one data bit per FALLING edge of the device
--             clock: 8 data bits LSB first, odd parity, stop; the 11th clock is the device's ACK bit
--             (not checked, :377-386).
--   device -> host (:94-131): bits are sampled on the falling edge of the device clock, only while the
--             host is not transmitting; after the stop bit the receiver ignores clock edges for one
--             bit period (PS2PERIOD, :116), so frames need a gap of more than 67 us between them.
--
-- PS/2 device protocol implemented here: device-generated clock at G_PS2_HZ (12.5 kHz, spec 10-16.7),
-- 11-bit frames (start, 8 data LSB first, odd parity, stop), data changed while the clock is high and
-- stable across the falling edge; host inhibit (host clock low) abandons a frame at once and the byte
-- is re-sent later; host request-to-send (clock released while data is held low) is answered with 11
-- device clocks, the bits are sampled while the clock is high (rising edge + 40 us), parity and stop
-- bit are checked and the ACK bit is driven low around the 11th clock. Commands:
--   FF reset -> FA, then after G_BAT_MS: AA 00; defaults, reporting off      F6 set defaults -> FA
--   F4 enable reporting -> FA        F5 disable -> FA        F3 set sample rate -> FA, argument -> FA
--   F2 read ID -> FA 00              E8 set resolution -> FA, argument -> FA
--   E6/E7 scaling 1:1 / 2:1 -> FA    EA stream mode -> FA    F0 remote mode -> FA    EB read data -> FA + packet
--   E9 status request -> FA status resolution rate            FE resend -> last byte
--   anything else, or a frame with bad parity / stop bit -> FE
-- Packets: byte 1 = Yovf Xovf Ysign Xsign 1 M R L, byte 2 = dX, byte 3 = dY (PS/2: +Y = up), 9-bit
-- deltas clamped to +-255 with the overflow flags. In stream mode a packet goes out at most every
-- G_REPORT_MS ms and only when there was movement or a button change since the last one.
--
-- MEGA65 side (all clk_i domain; main.vhd ports):
--   mode_i = 00 : no mouse (the PS/2 device still answers commands, so the host's one-shot init at
--                 power-up completes and a later mode switch just starts reporting)
--   mode_i = 01 : Commodore 1351 in proportional mode. Position is in the pot readings the way the C64
--                 driver reads it (1351 manual driver: bits 6..1 of POTX/POTY are a 6-bit position that
--                 wraps, bit 0 is noise): every millisecond the 6-bit difference to the previous sample
--                 is sign-extended and accumulated. POTX grows to the right, POTY grows upwards, which
--                 is the PS/2 sense as well. The framework already turns the MEGA65's raw pot count
--                 into SID polarity (M2M/vhdl/qnice_wrapper.vhd:569, x"FF" - value); should the mouse
--                 move mirrored on hardware, set G_POT_INVERTED. Left button = fire (pin 6), right
--                 button = up (pin 1, the 1351's right button line).
--   mode_i = 10 : Amiga mouse. Pins (Amiga Hardware Reference Manual, game port): 1 = V pulse,
--                 2 = H pulse, 3 = VQ pulse, 4 = HQ pulse, 6 = left button, 9 = right button, 5 =
--                 middle button. On the C64-style port these are up/down/left/right/fire/POTX/POTY,
--                 so X quadrature is (right, down) and Y quadrature is (left, up). The transition
--                 tables are the ones the MEGA65 itself uses to present an Amiga mouse as a 1351
--                 (M2M/vhdl/controllers/M65/mouse_input.vhdl:243-273; there X+1 = right, Y+1 = up in
--                 1351 terms). Right/middle button: the pot line is grounded, which mouse_input.vhdl:239
--                 reads as raw pot bit 7 = 0, i.e. after the framework's inversion pot_x_i(7) = '1'
--                 (pot near 255 = pressed, near 0 = released); G_AMIGA_RMB_POT_HIGH flips that.
--   mode_i = 11 : reserved, behaves like 00.
-- rst_i only drops accumulated motion. The PS/2 link and the command state deliberately ignore it:
-- MSMouseWrapper has no reset and sends its 0xFF one millisecond after the chipset clock starts, while
-- the core is still held in reset by the framework; the reply has to go out then.
--
-- The joystick lines are the framework's debounced ones (M2M/vhdl/framework.vhd:505, 1 ms), which
-- limits the Amiga quadrature rate to one transition per millisecond per line.
--
-- MiSTer2MEGA65 done by sy2002 and MJoergen in 2022 and licensed under GPL v3
-------------------------------------------------------------------------------------------------------------

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity m65_mouse_ps2 is
   generic (
      G_CLK_HZ             : natural := 50_000_000; -- clk_i
      G_PS2_HZ             : natural := 12_500;     -- device bit clock, 10_000 .. 16_700
      G_REPORT_MS          : natural := 10;         -- minimum spacing of stream packets, ms
      G_BAT_MS             : natural := 20;         -- self test time after 0xFF before AA 00, ms
      G_POT_INVERTED       : boolean := false;      -- true: pot_x_i/pot_y_i shrink when moving right/up
      G_AMIGA_RMB_POT_HIGH : boolean := true        -- true: Amiga right/middle button pressed = pot(7) = '1'
   );
   port (
      clk_i          : in  std_logic;                     -- clk_main_i, 50 MHz chipset clock
      rst_i          : in  std_logic;                     -- drops motion only, see header

      mode_i         : in  std_logic_vector(1 downto 0);  -- 00 off, 01 C1351, 10 Amiga

      -- MEGA65 joystick port 1 (active low) and its pot lines
      joy_up_n_i     : in  std_logic;
      joy_down_n_i   : in  std_logic;
      joy_left_n_i   : in  std_logic;
      joy_right_n_i  : in  std_logic;
      joy_fire_n_i   : in  std_logic;
      pot_x_i        : in  std_logic_vector(7 downto 0);
      pot_y_i        : in  std_logic_vector(7 downto 0);

      -- host -> device (pcxt_core ps2_mouse_clk_o / ps2_mouse_data_o)
      host_clk_i     : in  std_logic;
      host_data_i    : in  std_logic;

      -- device -> host (pcxt_core ps2_mouse_clk_i / ps2_mouse_data_i)
      ps2_clk_o      : out std_logic;
      ps2_data_o     : out std_logic
   );
end entity m65_mouse_ps2;

architecture rtl of m65_mouse_ps2 is

   constant C_HALF_BIT : natural := G_CLK_HZ / (2 * G_PS2_HZ);   -- 2000 clocks = 40 us
   constant C_MS       : natural := G_CLK_HZ / 1000;

   ---------------------------------------------------------------------------
   -- link (PS/2 line level)
   ---------------------------------------------------------------------------
   signal div         : natural range 0 to C_HALF_BIT-1 := 0;
   signal tick        : std_logic := '0';                 -- one clock per half bit
   signal bit_clk     : std_logic := '1';                 -- '1' = first half of a bit

   signal host_clk_q  : std_logic_vector(2 downto 0) := "111";
   signal host_data_q : std_logic_vector(2 downto 0) := "111";
   signal host_idle   : std_logic;
   signal host_rts    : std_logic;

   -- transmit: tx_state = bit on the data line: 0 idle, 1 start, 2..9 data, 10 parity, 11 stop
   signal tx_state    : natural range 0 to 11 := 0;
   signal tx_sr       : std_logic_vector(7 downto 0) := (others => '0');
   signal tx_par      : std_logic := '1';
   signal idle_gap    : natural range 0 to 3 := 0;        -- bit times of silence between frames
   signal tx_pop      : std_logic := '0';                 -- frame complete, byte consumed
   signal link_idle   : std_logic;

   -- receive: rx_state = device clock pulse being generated 1..11, 12 = settle
   signal rx_state    : natural range 0 to 12 := 0;
   signal rx_sr       : std_logic_vector(7 downto 0) := (others => '0');
   signal rx_par      : std_logic := '0';
   signal rx_stop     : std_logic := '0';
   signal rx_done     : std_logic := '0';                 -- one clock: a host byte is in rx_sr
   signal rx_ok       : std_logic;

   signal clk_out     : std_logic := '1';
   signal data_out    : std_logic := '1';

   ---------------------------------------------------------------------------
   -- transmit buffer, loaded whole by the command / packet logic
   ---------------------------------------------------------------------------
   type buf_t is array (0 to 3) of std_logic_vector(7 downto 0);
   signal tx_buf      : buf_t := (others => (others => '0'));
   signal tx_cnt      : natural range 0 to 4 := 0;        -- bytes still to send
   signal tx_idx      : natural range 0 to 3 := 0;
   signal tx_data     : std_logic_vector(7 downto 0);
   signal last_byte   : std_logic_vector(7 downto 0) := x"FA";

   ---------------------------------------------------------------------------
   -- mouse state
   ---------------------------------------------------------------------------
   signal reporting   : std_logic := '0';
   signal remote      : std_logic := '0';
   signal scaling     : std_logic := '0';
   signal expect_arg  : std_logic := '0';
   signal arg_is_rate : std_logic := '0';
   signal sample_rate : std_logic_vector(7 downto 0) := x"64";
   signal resolution  : std_logic_vector(7 downto 0) := x"02";
   signal bat_pending : std_logic := '0';
   signal bat_cnt     : natural range 0 to G_BAT_MS := 0;

   signal ms_div      : natural range 0 to C_MS-1 := 0;
   signal ms_tick     : std_logic := '0';
   signal rep_cnt     : natural range 0 to G_REPORT_MS-1 := 0;
   signal rep_tick    : std_logic := '0';

   -- inputs: joy_q = fire & right & left & down & up (active low), two register stages plus history
   signal joy_q1      : std_logic_vector(4 downto 0) := "11111";
   signal joy_q2      : std_logic_vector(4 downto 0) := "11111";
   signal joy_q3      : std_logic_vector(4 downto 0) := "11111";
   signal pot_x_q     : std_logic_vector(7 downto 0) := (others => '0');
   signal pot_y_q     : std_logic_vector(7 downto 0) := (others => '0');
   signal mode_q      : std_logic_vector(1 downto 0) := "00";
   signal mode_qq     : std_logic_vector(1 downto 0) := "00";

   signal pos_x_prev  : unsigned(5 downto 0) := (others => '0');
   signal pos_y_prev  : unsigned(5 downto 0) := (others => '0');
   signal pot_valid   : std_logic := '0';

   signal acc_x       : signed(8 downto 0) := (others => '0');   -- -255 .. 255
   signal acc_y       : signed(8 downto 0) := (others => '0');
   signal ovf_x       : std_logic := '0';
   signal ovf_y       : std_logic := '0';
   signal btn         : std_logic_vector(2 downto 0) := "000";   -- M R L
   signal btn_sent    : std_logic_vector(2 downto 0) := "000";

begin

   host_idle <= host_clk_q(2) and host_data_q(2);
   host_rts  <= host_clk_q(2) and not host_data_q(2);       -- clock released while data is held low
   link_idle <= '1' when tx_state = 0 and rx_state = 0 and idle_gap = 0 else '0';
   tx_data   <= tx_buf(tx_idx);
   -- odd parity: the nine bits (8 data + parity) xor to '1'
   rx_ok     <= (rx_sr(0) xor rx_sr(1) xor rx_sr(2) xor rx_sr(3) xor rx_sr(4) xor rx_sr(5) xor
                 rx_sr(6) xor rx_sr(7) xor rx_par) and rx_stop;

   ---------------------------------------------------------------------------
   -- PS/2 line engine
   ---------------------------------------------------------------------------
   p_link : process (clk_i)
   begin
      if rising_edge(clk_i) then
         tick <= '0';
         if div = C_HALF_BIT-1 then
            div  <= 0;
            tick <= '1';
         else
            div <= div + 1;
         end if;
         host_clk_q  <= host_clk_q(1 downto 0) & host_clk_i;
         host_data_q <= host_data_q(1 downto 0) & host_data_i;

         rx_done <= '0';
         tx_pop  <= '0';

         -- host inhibit: abandon the frame now, the byte stays in the buffer and is sent again.
         -- Once the stop bit has been clocked (state 11, clock low) the host has the byte, so
         -- an inhibit then (a command follows) must not trigger a repeat.
         if tx_state /= 0 and host_clk_q(2) = '0' and not (tx_state = 11 and bit_clk = '0') then
            tx_state <= 0;
            data_out <= '1';
            clk_out  <= '1';
            idle_gap <= 3;
         end if;

         if tick = '1' then
            bit_clk <= not bit_clk;

            if bit_clk = '1' then
               ---------------------------------------------------------------
               -- first half of a bit ends: the clock goes low. The data bit has
               -- been stable for 40 us, the host samples it on this edge.
               ---------------------------------------------------------------
               if rx_state /= 0 then
                  if rx_state <= 11 then
                     clk_out <= '0';
                  end if;
               elsif tx_state /= 0 then
                  clk_out <= '0';
               elsif idle_gap > 0 then
                  idle_gap <= idle_gap - 1;
               end if;
            else
               ---------------------------------------------------------------
               -- second half ends: the clock goes high. Transmit: present the
               -- next bit. Receive: sample the host's bit (it changes it on the
               -- falling edge, 40 us ago).
               ---------------------------------------------------------------
               clk_out <= '1';
               if rx_state /= 0 then
                  case rx_state is
                     when 1 to 8 =>
                        rx_sr    <= host_data_q(2) & rx_sr(7 downto 1);   -- LSB first
                        rx_state <= rx_state + 1;
                     when 9 =>
                        rx_par   <= host_data_q(2);
                        rx_state <= 10;
                     when 10 =>
                        rx_stop  <= host_data_q(2);
                        data_out <= '0';                                  -- ACK bit, clocked next
                        rx_state <= 11;
                     when 11 =>
                        data_out <= '1';                                  -- ACK released
                        rx_state <= 12;
                     when others =>
                        rx_done  <= '1';
                        rx_state <= 0;
                        idle_gap <= 2;
                  end case;
               elsif host_rts = '1' and tx_state = 0 then
                  -- request to send. The host keeps data low until our first clock; the
                  -- first pulse is generated at the next half-bit boundary.
                  rx_state <= 1;
               else
                  case tx_state is
                     when 0 =>
                        if idle_gap = 0 and tx_cnt /= 0 and host_idle = '1' then
                           tx_sr    <= tx_data;
                           tx_par   <= '1';
                           data_out <= '0';                               -- start bit
                           tx_state <= 1;
                        end if;
                     when 1 to 8 =>
                        data_out <= tx_sr(0);
                        if tx_sr(0) = '1' then
                           tx_par <= not tx_par;
                        end if;
                        tx_sr    <= '0' & tx_sr(7 downto 1);
                        tx_state <= tx_state + 1;
                     when 9 =>
                        data_out <= tx_par;
                        tx_state <= 10;
                     when 10 =>
                        data_out <= '1';                                  -- stop bit
                        tx_state <= 11;
                     when 11 =>
                        tx_state <= 0;                                    -- stop bit was clocked
                        idle_gap <= 2;                                    -- > PS2PERIOD for the host's receiver
                        tx_pop   <= '1';
                  end case;
               end if;
            end if;
         end if;
      end if;
   end process p_link;

   ps2_clk_o  <= clk_out;
   ps2_data_o <= data_out;

   ---------------------------------------------------------------------------
   -- commands, motion, packets
   ---------------------------------------------------------------------------
   p_mouse : process (clk_i)
      variable v_ax, v_ay     : signed(9 downto 0);
      variable v_ovx, v_ovy   : std_logic;
      variable v_potx, v_poty : std_logic_vector(7 downto 0);
      variable v_pos_x        : unsigned(5 downto 0);
      variable v_pos_y        : unsigned(5 downto 0);
      variable v_d6           : signed(5 downto 0);
      variable v_q            : std_logic_vector(3 downto 0);
      variable v_rmb, v_mmb   : std_logic;
      variable v_b1           : std_logic_vector(7 downto 0);
   begin
      if rising_edge(clk_i) then
         ------------------------------------------------------------ inputs
         joy_q1  <= joy_fire_n_i & joy_right_n_i & joy_left_n_i & joy_down_n_i & joy_up_n_i;
         joy_q2  <= joy_q1;
         joy_q3  <= joy_q2;
         pot_x_q <= pot_x_i;
         pot_y_q <= pot_y_i;
         mode_q  <= mode_i;
         mode_qq <= mode_q;

         ------------------------------------------------------------ timers
         ms_tick  <= '0';
         rep_tick <= '0';
         if ms_div = C_MS-1 then
            ms_div  <= 0;
            ms_tick <= '1';
         else
            ms_div <= ms_div + 1;
         end if;
         if ms_tick = '1' then
            if rep_cnt = G_REPORT_MS-1 then
               rep_cnt  <= 0;
               rep_tick <= '1';
            else
               rep_cnt <= rep_cnt + 1;
            end if;
            if bat_cnt /= 0 then
               bat_cnt <= bat_cnt - 1;
            end if;
         end if;

         ------------------------------------------------------------ motion
         v_ax  := resize(acc_x, 10);
         v_ay  := resize(acc_y, 10);
         v_ovx := ovf_x;
         v_ovy := ovf_y;
         if G_POT_INVERTED then
            v_potx := not pot_x_q;
            v_poty := not pot_y_q;
         else
            v_potx := pot_x_q;
            v_poty := pot_y_q;
         end if;

         case mode_q is
            when "01" =>
               -- 1351: 6-bit position in pot bits 6..1, delta with wraparound, once per ms
               if ms_tick = '1' then
                  v_pos_x := unsigned(v_potx(6 downto 1));
                  v_pos_y := unsigned(v_poty(6 downto 1));
                  if pot_valid = '1' then
                     v_d6 := signed(v_pos_x - pos_x_prev);
                     v_ax := v_ax + resize(v_d6, 10);
                     v_d6 := signed(v_pos_y - pos_y_prev);
                     v_ay := v_ay + resize(v_d6, 10);
                  end if;
                  pos_x_prev <= v_pos_x;
                  pos_y_prev <= v_pos_y;
                  pot_valid  <= '1';
               end if;
               btn <= '0' & (not joy_q2(0)) & (not joy_q2(4));      -- right = up line, left = fire

            when "10" =>
               -- Amiga: X on (right, down) = (HQ, H), Y on (left, up) = (VQ, V), tables from
               -- mouse_input.vhdl:243-273
               pot_valid <= '0';
               v_q := joy_q2(3) & joy_q2(1) & joy_q3(3) & joy_q3(1);
               case v_q is
                  when "0010" | "1011" | "1101" | "0100" => v_ax := v_ax + 1;
                  when "1110" | "0111" | "0001" | "1000" => v_ax := v_ax - 1;
                  when others => null;
               end case;
               v_q := joy_q2(2) & joy_q2(0) & joy_q3(2) & joy_q3(0);
               case v_q is
                  when "1110" | "0111" | "0001" | "1000" => v_ay := v_ay + 1;
                  when "0010" | "1011" | "1101" | "0100" => v_ay := v_ay - 1;
                  when others => null;
               end case;
               if G_AMIGA_RMB_POT_HIGH then
                  v_rmb := pot_x_q(7);
                  v_mmb := pot_y_q(7);
               else
                  v_rmb := not pot_x_q(7);
                  v_mmb := not pot_y_q(7);
               end if;
               btn <= v_mmb & v_rmb & (not joy_q2(4));

            when others =>
               pot_valid <= '0';
               btn <= "000";
         end case;

         -- clamp to the 9-bit PS/2 range, flag overflow
         if v_ax > 255 then
            v_ax  := to_signed(255, 10);
            v_ovx := '1';
         elsif v_ax < -255 then
            v_ax  := to_signed(-255, 10);
            v_ovx := '1';
         end if;
         if v_ay > 255 then
            v_ay  := to_signed(255, 10);
            v_ovy := '1';
         elsif v_ay < -255 then
            v_ay  := to_signed(-255, 10);
            v_ovy := '1';
         end if;

         v_b1 := v_ovy & v_ovx & v_ay(8) & v_ax(8) & '1' & btn;

         ------------------------------------------------------------ commands and transmit buffer
         if rx_done = '1' then
            -- a host byte replaces whatever was queued (the host's inhibit already killed the frame)
            tx_idx <= 0;
            tx_cnt <= 1;
            tx_buf(0) <= x"FA";
            if rx_ok = '0' then
               tx_buf(0) <= x"FE";                                   -- bad parity / stop: resend
            elsif expect_arg = '1' then
               expect_arg <= '0';
               if arg_is_rate = '1' then
                  sample_rate <= rx_sr;
               else
                  resolution <= rx_sr;
               end if;
            else
               case rx_sr is
                  when x"FF" =>                                      -- reset
                     reporting   <= '0';
                     remote      <= '0';
                     scaling     <= '0';
                     sample_rate <= x"64";
                     resolution  <= x"02";
                     bat_pending <= '1';
                     bat_cnt     <= G_BAT_MS;
                     v_ax := (others => '0');
                     v_ay := (others => '0');
                     v_ovx := '0';
                     v_ovy := '0';
                  when x"F6" =>                                      -- set defaults
                     reporting   <= '0';
                     remote      <= '0';
                     scaling     <= '0';
                     sample_rate <= x"64";
                     resolution  <= x"02";
                     v_ax := (others => '0');
                     v_ay := (others => '0');
                     v_ovx := '0';
                     v_ovy := '0';
                  when x"F5" =>                                      -- disable reporting
                     reporting <= '0';
                  when x"F4" =>                                      -- enable reporting
                     reporting <= '1';
                     btn_sent  <= btn;
                     v_ax := (others => '0');
                     v_ay := (others => '0');
                     v_ovx := '0';
                     v_ovy := '0';
                  when x"F3" =>                                      -- set sample rate, argument follows
                     expect_arg  <= '1';
                     arg_is_rate <= '1';
                  when x"F2" =>                                      -- read ID
                     tx_buf(1) <= x"00";
                     tx_cnt    <= 2;
                  when x"F0" =>                                      -- remote mode
                     remote <= '1';
                  when x"EA" =>                                      -- stream mode
                     remote <= '0';
                  when x"EB" =>                                      -- read data (one packet)
                     tx_buf(1) <= v_b1;
                     tx_buf(2) <= std_logic_vector(v_ax(7 downto 0));
                     tx_buf(3) <= std_logic_vector(v_ay(7 downto 0));
                     tx_cnt    <= 4;
                     btn_sent  <= btn;
                     v_ax := (others => '0');
                     v_ay := (others => '0');
                     v_ovx := '0';
                     v_ovy := '0';
                  when x"E9" =>                                      -- status request
                     tx_buf(1) <= '0' & remote & reporting & scaling & '0' & btn(0) & btn(2) & btn(1);
                     tx_buf(2) <= resolution;
                     tx_buf(3) <= sample_rate;
                     tx_cnt    <= 4;
                  when x"E8" =>                                      -- set resolution, argument follows
                     expect_arg  <= '1';
                     arg_is_rate <= '0';
                  when x"E7" =>                                      -- scaling 2:1
                     scaling <= '1';
                  when x"E6" =>                                      -- scaling 1:1
                     scaling <= '0';
                  when x"FE" =>                                      -- resend
                     tx_buf(0) <= last_byte;
                  when others =>
                     tx_buf(0) <= x"FE";
               end case;
            end if;

         elsif tx_pop = '1' then
            last_byte <= tx_buf(tx_idx);
            if tx_idx /= 3 then
               tx_idx <= tx_idx + 1;
            else
               tx_idx <= 0;
            end if;
            if tx_cnt /= 0 then
               tx_cnt <= tx_cnt - 1;
            end if;

         elsif bat_pending = '1' and bat_cnt = 0 and tx_cnt = 0 and link_idle = '1' then
            -- self test passed, mouse ID 0
            tx_buf(0)   <= x"AA";
            tx_buf(1)   <= x"00";
            tx_idx      <= 0;
            tx_cnt      <= 2;
            bat_pending <= '0';

         elsif rep_tick = '1' and reporting = '1' and remote = '0' and bat_pending = '0' and
               expect_arg = '0' and tx_cnt = 0 and link_idle = '1' then
            if v_ax /= 0 or v_ay /= 0 or v_ovx = '1' or v_ovy = '1' or btn /= btn_sent then
               tx_buf(0) <= v_b1;
               tx_buf(1) <= std_logic_vector(v_ax(7 downto 0));
               tx_buf(2) <= std_logic_vector(v_ay(7 downto 0));
               tx_idx    <= 0;
               tx_cnt    <= 3;
               btn_sent  <= btn;
               v_ax  := (others => '0');
               v_ay  := (others => '0');
               v_ovx := '0';
               v_ovy := '0';
            end if;
         end if;

         ------------------------------------------------------------ motion reset
         if rst_i = '1' or mode_q /= mode_qq then
            v_ax  := (others => '0');
            v_ay  := (others => '0');
            v_ovx := '0';
            v_ovy := '0';
            pot_valid <= '0';
         end if;

         acc_x <= v_ax(8 downto 0);
         acc_y <= v_ay(8 downto 0);
         ovf_x <= v_ovx;
         ovf_y <= v_ovy;
      end if;
   end process p_mouse;

end architecture rtl;
