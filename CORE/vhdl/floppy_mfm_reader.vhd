-------------------------------------------------------------------------------------------------------------
-- floppy_mfm_reader: MFM flux gaps -> bytes -> IBM System 34 ID / data fields with CRC, at 250 or 500 kbit/s
--
-- Shared by floppy_phy_spike.vhd and floppy_sector_engine.vhd (docs/floppy.md); lifted unchanged out of
-- the spike. clk_i = 50.000 MHz.
--   * flux_edge_i is one pulse per flux transition (floppy_drive_if). The gap between transitions is
--     measured in clocks and quantised like mega65-core mfm_quantise_gaps.vhdl:39-63 with the half cell hc
--     (50 clocks at 500 kbit/s, 100 at 250): 2 half cells for hc..2.5 hc, 3 for ..3.5 hc, 4 for ..5 hc,
--     otherwise invalid (resynchronise). No PLL: the fixed +-0.5 hc windows read this drive in mega65-core.
--   * a gap of n half cells yields n raw MFM bits (n-1 zeros then a one) into a 16-bit shift register; the
--     raw pattern 0x4489 is the A1 sync mark with the missing clock, which fixes the clock/data phase.
--   * bytes are the data bits after the mark. IDAM = FE C H R N CRC, DAM = FB (F8 deleted) then 128 << N
--     data bytes and CRC. CRC-16/CCITT poly 0x1021 preset FFFF over the three A1 marks and everything up to
--     the CRC, zero after the CRC bytes (crc1581.vhdl, mfm_decoder.vhdl:380-383).
-- Events (one-clock pulses): idam_o with idam_ok_o and id_*_o (stable at and after the pulse); dam_o when
-- a data field starts (its bytes follow as data_valid_o / data_o); dam_end_o with dam_ok_o after the data
-- CRC. The data length follows the N of the last good IDAM (512 for N = 2).
--
-- MEGA65 port done by silent-command in 2026 and licensed under GPL v3
-- MiSTer2MEGA65 done by sy2002 and MJoergen in 2022 and licensed under GPL v3
-------------------------------------------------------------------------------------------------------------

library ieee;
   use ieee.std_logic_1164.all;
   use ieee.numeric_std.all;

entity floppy_mfm_reader is
   generic (
      G_HD_HALF_CELL : natural := 50;            -- 500 kbit/s: 1 us half cell
      G_DD_HALF_CELL : natural := 100            -- 250 kbit/s: 2 us half cell
   );
   port (
      clk_i          : in    std_logic;
      rst_i          : in    std_logic;
      reset_i        : in    std_logic;          -- resynchronise: drop the bit stream and the decoder state
      rate_hd_i      : in    std_logic;          -- 1 = 500 kbit/s
      flux_edge_i    : in    std_logic;

      -- raw stream (debug / counters)
      sync_mark_o    : out   std_logic;
      byte_valid_o   : out   std_logic;
      byte_o         : out   std_logic_vector(7 downto 0);
      gap_len_o      : out   std_logic_vector(11 downto 0);

      -- ID fields
      idam_o         : out   std_logic;          -- FE seen after a mark (counted at the CRC check)
      idam_ok_o      : out   std_logic;          -- ... and its CRC was good (valid with idam_o)
      id_c_o         : out   std_logic_vector(7 downto 0);
      id_h_o         : out   std_logic_vector(7 downto 0);
      id_r_o         : out   std_logic_vector(7 downto 0);
      id_n_o         : out   std_logic_vector(7 downto 0);

      -- data fields
      dam_o          : out   std_logic;          -- FB / F8 seen after a mark: data bytes follow
      data_valid_o   : out   std_logic;
      data_o         : out   std_logic_vector(7 downto 0);
      dam_end_o      : out   std_logic;          -- data CRC checked
      dam_ok_o       : out   std_logic           -- ... and it was good (valid with dam_end_o)
   );
end entity floppy_mfm_reader;

architecture rtl of floppy_mfm_reader is

   -- CRC-16/CCITT, poly 0x1021, msb first (crc1581.vhdl:92-95 bit by bit)
   function crc16_byte (crc : std_logic_vector(15 downto 0); d : std_logic_vector(7 downto 0))
      return std_logic_vector is
      variable c : std_logic_vector(15 downto 0) := crc;
      variable b : std_logic;
   begin
      for i in 7 downto 0 loop
         b := c(15) xor d(i);
         c := c(14 downto 0) & '0';
         if b = '1' then
            c := c xor x"1021";
         end if;
      end loop;
      return c;
   end function crc16_byte;

   signal hc            : unsigned(8 downto 0);
   signal thr_lo        : unsigned(11 downto 0);       -- 1.0 hc
   signal thr_2         : unsigned(11 downto 0);       -- 2.5 hc
   signal thr_3         : unsigned(11 downto 0);       -- 3.5 hc
   signal thr_4         : unsigned(11 downto 0);       -- 5.0 hc
   signal gap_cnt       : unsigned(11 downto 0) := (others => '0');
   signal gap_len       : unsigned(11 downto 0) := (others => '0');
   signal bit_pend      : unsigned(2 downto 0) := (others => '0');
   signal raw_sr        : std_logic_vector(15 downto 0) := (others => '0');
   signal raw_valid     : std_logic := '0';
   signal raw_bit       : std_logic := '0';
   signal sync_mark     : std_logic := '0';
   signal bit_phase     : std_logic := '0';
   signal data_sr       : std_logic_vector(7 downto 0) := (others => '0');
   signal nbits         : unsigned(2 downto 0) := (others => '0');
   signal byte_valid    : std_logic := '0';
   signal byte_val      : std_logic_vector(7 downto 0) := (others => '0');
   signal in_sync       : std_logic := '0';

   type t_dec is (D_IDLE, D_MARK, D_ID_C, D_ID_H, D_ID_R, D_ID_N, D_ID_CRC1, D_ID_CRC2,
                  D_DATA, D_DATA_CRC1, D_DATA_CRC2);
   signal dec           : t_dec := D_IDLE;
   signal crc           : std_logic_vector(15 downto 0) := (others => '1');
   signal id_c, id_h, id_r, id_n : std_logic_vector(7 downto 0) := (others => '0');
   signal data_left     : unsigned(10 downto 0) := (others => '0');
   signal sector_bytes  : unsigned(10 downto 0) := to_unsigned(512, 11);

begin

   hc     <= to_unsigned(G_HD_HALF_CELL, 9) when rate_hd_i = '1' else to_unsigned(G_DD_HALF_CELL, 9);
   thr_lo <= resize(hc, 12);
   thr_2  <= resize(hc, 12) + resize(hc, 12) + resize(hc(8 downto 1), 12);
   thr_3  <= shift_left(resize(hc, 12), 2) - resize(hc(8 downto 1), 12);
   thr_4  <= shift_left(resize(hc, 12), 2) + resize(hc, 12);

   p_gaps : process (clk_i)
      variable v_n : unsigned(2 downto 0);
   begin
      if rising_edge(clk_i) then
         raw_valid  <= '0';
         sync_mark  <= '0';
         byte_valid <= '0';

         if flux_edge_i = '1' then
            gap_len <= gap_cnt;
            gap_cnt <= to_unsigned(1, 12);
         elsif gap_cnt /= x"FFF" then
            gap_cnt <= gap_cnt + 1;
         end if;

         if flux_edge_i = '1' then
            if gap_cnt < thr_lo then
               v_n := "000";
            elsif gap_cnt <= thr_2 then
               v_n := "010";
            elsif gap_cnt <= thr_3 then
               v_n := "011";
            elsif gap_cnt <= thr_4 then
               v_n := "100";
            else
               v_n := "000";
            end if;
            bit_pend <= v_n;
            if v_n = "000" then
               in_sync <= '0';
            end if;
         elsif bit_pend /= 0 then
            bit_pend  <= bit_pend - 1;
            raw_valid <= '1';
            if bit_pend = 1 then
               raw_bit <= '1';
            else
               raw_bit <= '0';
            end if;
         end if;

         if raw_valid = '1' then
            raw_sr <= raw_sr(14 downto 0) & raw_bit;
            if (raw_sr(14 downto 0) & raw_bit) = x"4489" then
               sync_mark <= '1';
               in_sync   <= '1';
               bit_phase <= '0';
               nbits     <= (others => '0');
            elsif in_sync = '1' then
               bit_phase <= not bit_phase;
               if bit_phase = '1' then
                  data_sr <= data_sr(6 downto 0) & raw_bit;
                  if nbits = 7 then
                     byte_valid <= '1';
                     byte_val   <= data_sr(6 downto 0) & raw_bit;
                     nbits      <= (others => '0');
                  else
                     nbits <= nbits + 1;
                  end if;
               end if;
            end if;
         end if;

         if reset_i = '1' or rst_i = '1' then
            bit_pend <= (others => '0');
            in_sync  <= '0';
            raw_sr   <= (others => '0');
            gap_cnt  <= (others => '0');
         end if;
      end if;
   end process p_gaps;

   p_dec : process (clk_i)
   begin
      if rising_edge(clk_i) then
         idam_o       <= '0';
         idam_ok_o    <= '0';
         dam_o        <= '0';
         data_valid_o <= '0';
         dam_end_o    <= '0';
         dam_ok_o     <= '0';

         if sync_mark = '1' then
            if dec = D_MARK then
               crc <= crc16_byte(crc, x"A1");
            else
               crc <= crc16_byte(x"FFFF", x"A1");
            end if;
            dec <= D_MARK;
         elsif byte_valid = '1' then
            case dec is
               when D_IDLE =>
                  null;
               when D_MARK =>
                  crc <= crc16_byte(crc, byte_val);
                  if byte_val = x"FE" then
                     dec <= D_ID_C;
                  elsif byte_val = x"FB" or byte_val = x"F8" then
                     dec       <= D_DATA;
                     dam_o     <= '1';
                     data_left <= sector_bytes;
                  else
                     dec <= D_IDLE;
                  end if;
               when D_ID_C =>
                  id_c <= byte_val; crc <= crc16_byte(crc, byte_val); dec <= D_ID_H;
               when D_ID_H =>
                  id_h <= byte_val; crc <= crc16_byte(crc, byte_val); dec <= D_ID_R;
               when D_ID_R =>
                  id_r <= byte_val; crc <= crc16_byte(crc, byte_val); dec <= D_ID_N;
               when D_ID_N =>
                  id_n <= byte_val; crc <= crc16_byte(crc, byte_val); dec <= D_ID_CRC1;
               when D_ID_CRC1 =>
                  crc <= crc16_byte(crc, byte_val); dec <= D_ID_CRC2;
               when D_ID_CRC2 =>
                  dec    <= D_IDLE;
                  idam_o <= '1';
                  if crc16_byte(crc, byte_val) = x"0000" then
                     idam_ok_o <= '1';
                     case id_n is
                        when x"00"  => sector_bytes <= to_unsigned(128, 11);
                        when x"01"  => sector_bytes <= to_unsigned(256, 11);
                        when x"03"  => sector_bytes <= to_unsigned(1024, 11);
                        when others => sector_bytes <= to_unsigned(512, 11);
                     end case;
                  end if;
               when D_DATA =>
                  crc          <= crc16_byte(crc, byte_val);
                  data_valid_o <= '1';
                  data_o       <= byte_val;
                  if data_left = 1 then
                     dec <= D_DATA_CRC1;
                  end if;
                  data_left <= data_left - 1;
               when D_DATA_CRC1 =>
                  crc <= crc16_byte(crc, byte_val); dec <= D_DATA_CRC2;
               when D_DATA_CRC2 =>
                  dec       <= D_IDLE;
                  dam_end_o <= '1';
                  if crc16_byte(crc, byte_val) = x"0000" then
                     dam_ok_o <= '1';
                  end if;
            end case;
         end if;

         if reset_i = '1' then
            dec <= D_IDLE;
         end if;
         if rst_i = '1' then
            dec          <= D_IDLE;
            sector_bytes <= to_unsigned(512, 11);
         end if;
      end if;
   end process p_dec;

   sync_mark_o  <= sync_mark;
   byte_valid_o <= byte_valid;
   byte_o       <= byte_val;
   gap_len_o    <= std_logic_vector(gap_len);
   id_c_o       <= id_c;
   id_h_o       <= id_h;
   id_r_o       <= id_r;
   id_n_o       <= id_n;

end architecture rtl;
