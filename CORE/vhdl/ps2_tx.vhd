-------------------------------------------------------------------------------------------------------------
-- PCXT-EGA on MiSTer2MEGA65: PS/2 keyboard device emulation (both directions)
--
-- Emulates the keyboard end of a PS/2 link, the way MiSTer's hps_io ps2_device
-- plus the ARM do for this core.
--
-- Device -> host: bytes queued by the key translator are sent as 11-bit frames
-- (start, 8 data bits LSB first, odd parity, stop) with the device driving the
-- clock at clk / (2 * G_DIV) = 12.5 kHz. Each bit is placed on the data line
-- while the clock is high and the clock then goes low for half a bit, so a
-- receiver sampling on the falling edge sees stable data. A frame starts only
-- while the host leaves both lines high; the XT keyboard controller pulls its
-- clock low while a scancode interrupt is pending, and a frame in flight is
-- abandoned then. As the PS/2 protocol requires, a byte whose stop bit had not
-- been clocked when the host inhibited the line is sent again once the line is
-- released: the byte leaves the queue only at its stop bit's clock edge. (The
-- XT controller raises its interrupt, and so inhibits the clock, right at that
-- edge on every byte - such a byte is complete and is not repeated.)
--
-- Host -> device: the chipset's KFPS2KB_Send_Data issues a keyboard reset (FF)
-- whenever the BIOS enables the keyboard via port B bit 6: clock low, then data
-- low (request to send), then it releases the clock and shifts one bit per
-- falling edge of the device clock: start, 8 data bits, parity, stop. The
-- device clocks 11 pulses, samples the bits on its rising edges and pulls data
-- low on the 11th (acknowledge). The chipset holds its receive path locked
-- until this completes, so without it the keyboard is dead. Replies: FA for
-- every command, plus AA (self test passed) after FF. Pending scancodes are
-- flushed on a received command, as the MiSTer emulation does.
--
-- MiSTer2MEGA65 done by sy2002 and MJoergen in 2022 and licensed under GPL v3
-------------------------------------------------------------------------------------------------------------

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity ps2_tx is
   generic (
      G_DIV       : natural := 2000;      -- half bit period in clocks (2000 @ 50 MHz = 12.5 kHz)
      G_FIFO_BITS : natural := 6          -- 64 bytes of queue
   );
   port (
      clk_i          : in  std_logic;
      rst_i          : in  std_logic;

      -- byte queue
      data_i         : in  std_logic_vector(7 downto 0);
      we_i           : in  std_logic;
      full_o         : out std_logic;
      empty_o        : out std_logic;

      -- host -> device lines (from the chipset)
      host_clk_i     : in  std_logic;
      host_data_i    : in  std_logic;

      -- device -> host lines (into the chipset)
      ps2_clk_o      : out std_logic;
      ps2_data_o     : out std_logic
   );
end entity ps2_tx;

architecture rtl of ps2_tx is

   type fifo_t is array (0 to 2**G_FIFO_BITS-1) of std_logic_vector(7 downto 0);
   signal fifo      : fifo_t;
   signal wptr      : unsigned(G_FIFO_BITS-1 downto 0) := (others => '0');
   signal rptr      : unsigned(G_FIFO_BITS-1 downto 0) := (others => '0');
   signal count     : unsigned(G_FIFO_BITS downto 0)   := (others => '0');

   signal div       : natural range 0 to G_DIV-1 := 0;
   signal bit_clk   : std_logic := '1';     -- internal bit clock, high = first half
   signal tick      : std_logic;            -- one clock per half bit period

   -- transmit: tx_state = bit currently presented on the data line
   --   0 idle, 1 start, 2..9 data bits, 10 parity, 11 stop
   signal tx_state  : natural range 0 to 11 := 0;
   signal tx_byte   : std_logic_vector(7 downto 0);
   signal parity    : std_logic;
   signal idle_gap  : natural range 0 to 3 := 0;    -- bit times of silence between frames

   -- receive: rx_state = clock pulse being generated, 1..11; 12 = finish
   signal rx_state  : natural range 0 to 12 := 0;
   signal rx_byte   : std_logic_vector(7 downto 0);
   signal rx_reply  : natural range 0 to 2 := 0;    -- reply bytes still to queue

   signal host_clk_q  : std_logic_vector(2 downto 0) := "111";
   signal host_data_q : std_logic_vector(1 downto 0) := "11";
   signal host_idle   : std_logic;
   signal host_rts    : std_logic;          -- host released its clock while holding data low

   signal clk_out   : std_logic := '1';
   signal data_out  : std_logic := '1';

   -- queue control, shared by the translator (we_i) and the reply logic
   signal q_push    : std_logic;
   signal q_push_d  : std_logic_vector(7 downto 0);
   signal q_flush   : std_logic := '0';
   signal reply_we  : std_logic := '0';
   signal reply_d   : std_logic_vector(7 downto 0) := x"FA";

begin

   full_o  <= '1' when count = 2**G_FIFO_BITS else '0';
   empty_o <= '1' when count = 0 else '0';

   host_idle <= host_clk_q(1) and host_data_q(1);
   host_rts  <= host_clk_q(1) and not host_data_q(1);   -- clock released, data held low

   -- the reply logic has priority over the translator for the queue
   q_push   <= reply_we or we_i;
   q_push_d <= reply_d when reply_we = '1' else data_i;

   -- half-bit-period ticks
   p_div : process (clk_i)
   begin
      if rising_edge(clk_i) then
         tick <= '0';
         if div = G_DIV-1 then
            div  <= 0;
            tick <= '1';
         else
            div <= div + 1;
         end if;
         host_clk_q  <= host_clk_q(1 downto 0) & host_clk_i;
         host_data_q <= host_data_q(0) & host_data_i;
         if rst_i = '1' then
            div  <= 0;
            tick <= '0';
         end if;
      end if;
   end process;

   p_link : process (clk_i)
      variable pop  : boolean;
      variable push : boolean;
   begin
      if rising_edge(clk_i) then
         pop  := false;
         push := false;
         reply_we <= '0';

         -- queue write (translator or reply)
         if q_push = '1' and count /= 2**G_FIFO_BITS and q_flush = '0' then
            fifo(to_integer(wptr)) <= q_push_d;
            wptr <= wptr + 1;
            push := true;
         end if;

         -- the host pulled its clock low: abandon a frame at once (a real keyboard
         -- does the same; the host does not wait for it). The byte is still at
         -- the head of the queue unless its stop bit has been clocked, so it is
         -- sent again when the host releases the line.
         if tx_state /= 0 and host_clk_q(1) = '0' then
            tx_state <= 0;
            data_out <= '1';
            clk_out  <= '1';
            idle_gap <= 3;
         end if;

         -- reply bytes, one per clock, after the command has been received
         if rx_reply > 0 and reply_we = '0' then
            reply_we <= '1';
            if rx_reply = 2 then
               reply_d <= x"FA";
            else
               reply_d <= x"AA";
            end if;
            rx_reply <= rx_reply - 1;
         end if;

         if tick = '1' then
            bit_clk <= not bit_clk;

            if bit_clk = '1' then
               ---------------------------------------------------------------
               -- first half of a bit ends: the clock goes low. Transmit: the
               -- bit on the data line has been stable for half a bit. Receive:
               -- pulse the host, the 11th pulse carries the acknowledge.
               ---------------------------------------------------------------
               if rx_state /= 0 then
                  if rx_state <= 11 then
                     clk_out <= '0';
                     if rx_state = 11 then
                        data_out <= '0';
                     end if;
                  end if;
               elsif tx_state /= 0 then
                  clk_out <= '0';
                  if tx_state = 11 then
                     pop := true;                  -- stop bit clocked: the byte is delivered
                  end if;
               elsif idle_gap > 0 then
                  idle_gap <= idle_gap - 1;
               end if;
            else
               ---------------------------------------------------------------
               -- second half ends: the clock goes high. Transmit: present the
               -- next bit. Receive: sample the host's bit.
               ---------------------------------------------------------------
               clk_out <= '1';
               if rx_state /= 0 then
                  case rx_state is
                     when 1 to 8 =>
                        rx_byte <= host_data_q(1) & rx_byte(7 downto 1);   -- LSB first
                        rx_state <= rx_state + 1;
                     when 9 | 10 =>
                        rx_state <= rx_state + 1;                          -- parity, stop
                     when 11 =>
                        data_out <= '1';                                   -- release ack
                        rx_state <= 12;
                     when 12 =>
                        -- command complete: queue the reply
                        q_flush <= '0';
                        wptr <= (others => '0');
                        rptr <= (others => '0');
                        count <= (others => '0');
                        if rx_byte = x"FF" then
                           rx_reply <= 2;                                  -- FA, AA
                        else
                           rx_reply <= 1;                                  -- FA
                        end if;
                        rx_state <= 0;
                        idle_gap <= 2;
                     when others =>
                        rx_state <= 0;
                  end case;
               elsif tx_state /= 0 and host_clk_q(1) = '0' then
                  tx_state <= 0;                     -- inhibited mid-frame: resent later
                  data_out <= '1';
                  idle_gap <= 3;
               elsif host_rts = '1' and tx_state = 0 then
                  -- host request to send: clock released while data is held low,
                  -- which the host keeps up until the device clocks the start bit.
                  -- Started here, at a bit boundary, so that state 1 gets its pulse.
                  rx_state <= 1;
                  q_flush  <= '1';                  -- drop pending scancodes, like MiSTer
               else
                  case tx_state is
                     when 0 =>
                        if idle_gap = 0 and count /= 0 and host_idle = '1' then
                           tx_byte  <= fifo(to_integer(rptr));   -- popped at the stop bit
                           parity   <= '1';
                           data_out <= '0';             -- start bit
                           tx_state <= 1;
                        end if;
                     when 1 to 8 =>
                        data_out <= tx_byte(0);         -- data bits
                        if tx_byte(0) = '1' then parity <= not parity; end if;
                        tx_byte  <= '0' & tx_byte(7 downto 1);
                        tx_state <= tx_state + 1;
                     when 9 =>
                        data_out <= parity;
                        tx_state <= 10;
                     when 10 =>
                        data_out <= '1';                -- stop bit
                        tx_state <= 11;
                     when 11 =>
                        tx_state <= 0;                  -- stop bit has been clocked
                        idle_gap <= 2;
                  end case;
               end if;
            end if;
         end if;

         if pop then
            rptr <= rptr + 1;
         end if;

         -- occupancy (the flush above overrides on the same clock)
         if push and not pop then
            count <= count + 1;
         elsif pop and not push then
            count <= count - 1;
         end if;

         if rst_i = '1' then
            wptr     <= (others => '0');
            rptr     <= (others => '0');
            count    <= (others => '0');
            tx_state <= 0;
            rx_state <= 0;
            rx_reply <= 0;
            q_flush  <= '0';
            bit_clk  <= '1';
            clk_out  <= '1';
            data_out <= '1';
            idle_gap <= 0;
         end if;
      end if;
   end process;

   ps2_clk_o  <= clk_out;
   ps2_data_o <= data_out;

end architecture rtl;
