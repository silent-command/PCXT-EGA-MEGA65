-------------------------------------------------------------------------------------------------------------
-- PCXT-EGA on MiSTer2MEGA65: PS/2 device-side transmitter
--
-- Emulates the keyboard end of a PS/2 link, the way MiSTer's hps_io ps2_device
-- does for this core: bytes queued by the key translator are sent as 11-bit
-- frames (start, 8 data bits LSB first, odd parity, stop) with the device
-- driving the clock at G_CLK_HZ / (2 * G_DIV) = 12.5 kHz. A frame starts only
-- while the host leaves both lines high; the XT keyboard controller pulls its
-- clock low while a scancode interrupt is pending and during keyboard reset,
-- and no frame is started or continued in that state (the chipset in this
-- core never sends commands to the keyboard, so nothing is received).
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

   signal tx_state  : natural range 0 to 11 := 0;   -- 0 idle, 1..8 data, 9 parity, 10 stop, 11 gap
   signal tx_byte   : std_logic_vector(7 downto 0);
   signal parity    : std_logic;
   signal idle_gap  : natural range 0 to 3 := 0;    -- bit times of silence between frames

   signal host_clk_q  : std_logic_vector(1 downto 0) := "11";
   signal host_data_q : std_logic_vector(1 downto 0) := "11";
   signal host_idle   : std_logic;

   signal clk_out   : std_logic := '1';
   signal data_out  : std_logic := '1';

begin

   full_o  <= '1' when count = 2**G_FIFO_BITS else '0';
   empty_o <= '1' when count = 0 else '0';

   host_idle <= host_clk_q(1) and host_data_q(1);

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
         host_clk_q  <= host_clk_q(0) & host_clk_i;
         host_data_q <= host_data_q(0) & host_data_i;
         if rst_i = '1' then
            div  <= 0;
            tick <= '0';
         end if;
      end if;
   end process;

   p_tx : process (clk_i)
      variable pop : boolean;
   begin
      if rising_edge(clk_i) then
         pop := false;

         -- queue write
         if we_i = '1' and count /= 2**G_FIFO_BITS then
            fifo(to_integer(wptr)) <= data_i;
            wptr <= wptr + 1;
         end if;

         if tick = '1' then
            bit_clk <= not bit_clk;

            if bit_clk = '1' then
               ---------------------------------------------------------------
               -- first half of a bit ends: present the next data bit while the
               -- clock line is high, then the clock goes low for the second half
               ---------------------------------------------------------------
               case tx_state is
                  when 0 =>
                     -- idle: wait for a byte, host lines high, and a gap since
                     -- the previous frame
                     if idle_gap > 0 then
                        idle_gap <= idle_gap - 1;
                     elsif count /= 0 and host_idle = '1' then
                        tx_byte  <= fifo(to_integer(rptr));
                        pop      := true;
                        parity   <= '1';
                        data_out <= '0';             -- start bit
                        tx_state <= 1;
                     end if;
                  when 1 to 8 =>
                     data_out <= tx_byte(0);
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
                     tx_state <= 0;
                     idle_gap <= 2;
                  when others =>
                     tx_state <= 0;
               end case;

               -- the device clocks each presented bit with a low pulse;
               -- if the host inhibits (clock low), hold the clock high and
               -- abandon the frame: the host will not read it anyway and the
               -- byte is lost, exactly as with a real keyboard
               if (tx_state >= 1 and tx_state <= 10) or (tx_state = 0 and count /= 0 and host_idle = '1' and idle_gap = 0) then
                  clk_out <= '0';
               end if;
            else
               -- second half ends: clock back high
               clk_out <= '1';
               if tx_state /= 0 and host_clk_q(1) = '0' then
                  tx_state <= 0;                     -- inhibited mid-frame
                  data_out <= '1';
                  idle_gap <= 3;
               end if;
            end if;
         end if;

         if pop then
            rptr <= rptr + 1;
         end if;

         -- occupancy
         if (we_i = '1' and count /= 2**G_FIFO_BITS) and not pop then
            count <= count + 1;
         elsif pop and not (we_i = '1' and count /= 2**G_FIFO_BITS) then
            count <= count - 1;
         end if;

         if rst_i = '1' then
            wptr     <= (others => '0');
            rptr     <= (others => '0');
            count    <= (others => '0');
            tx_state <= 0;
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
