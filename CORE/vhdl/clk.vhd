-------------------------------------------------------------------------------------------------------------
-- PCXT-EGA on MiSTer2MEGA65: clock generator
--
-- Two MMCME2_ADV blocks replace the core's Altera PLLs (pll, pll_system) and its
-- register-divided 14.318 MHz clock. See docs/clocks-and-timing-constraints.md.
--
--   MMCM A, VCO 630 MHz (100 MHz / 5 * 31.5), the NTSC colour-burst family:
--      CLKOUT0  /22        28.636364 MHz   clk_28_o      video base (EGA/CGA)
--      CLKOUT1  /11        57.272727 MHz   clk_57_o      video pipeline
--      CLKOUT2  /11 +90deg 57.272727 MHz   clk_57_ps_o   output retime + credits overlay
--      CLKOUT3  /25        25.200000 MHz   clk_25_o      VGA mode 13h native pixel clock
--      CLKOUT4  /44        14.318182 MHz   clk_14_o      UART / splash
--   MMCM B, VCO 1000 MHz (100 MHz * 10):
--      CLKOUT0  /10       100 MHz          clk_100_o     MCL86 core clock
--      CLKOUT1  /20        50 MHz          clk_50_o      chipset (cur_rate = 50_000_000)
--   clk_100 and clk_50 come from one MMCM on purpose: on MiSTer they were timed as
--   related clocks and the RAM/BIU paths rely on that.
--
-- Resets are the MMCM lock signals, synchronised into each destination domain.
--
-- MiSTer2MEGA65 done by sy2002 and MJoergen in 2022 and licensed under GPL v3
-------------------------------------------------------------------------------------------------------------

library ieee;
use ieee.std_logic_1164.all;

library unisim;
use unisim.vcomponents.all;

library xpm;
use xpm.vcomponents.all;

entity clk is
   port (
      sys_clk_i       : in  std_logic;   -- expects 100 MHz

      -- Chipset domain. main_clk_o/main_rst_o are the names the M2M framework
      -- template uses for "the core's clock"; for this core that is the 50 MHz
      -- chipset clock, so the two pairs are identical.
      main_clk_o      : out std_logic;   -- 50 MHz
      main_rst_o      : out std_logic;
      clk_50_o        : out std_logic;   -- 50 MHz (same net as main_clk_o)
      rst_50_o        : out std_logic;

      -- CPU domain
      clk_100_o       : out std_logic;   -- 100 MHz
      rst_100_o       : out std_logic;

      -- Video family
      clk_28_o        : out std_logic;   -- 28.636 MHz
      clk_57_o        : out std_logic;   -- 57.273 MHz
      clk_57_ps_o     : out std_logic;   -- 57.273 MHz, +90 degrees
      clk_25_o        : out std_logic;   -- 25.2 MHz
      clk_14_o        : out std_logic;   -- 14.318 MHz
      video_rst_o     : out std_logic;   -- synchronised to clk_57_o

      locked_o        : out std_logic    -- both MMCMs locked
   );
end entity clk;

architecture rtl of clk is

   signal clkfb_a          : std_logic;
   signal clkfb_a_mmcm     : std_logic;
   signal clkfb_b          : std_logic;
   signal clkfb_b_mmcm     : std_logic;

   signal clk_28_mmcm      : std_logic;
   signal clk_57_mmcm      : std_logic;
   signal clk_57_ps_mmcm   : std_logic;
   signal clk_25_mmcm      : std_logic;
   signal clk_14_mmcm      : std_logic;
   signal clk_100_mmcm     : std_logic;
   signal clk_50_mmcm      : std_logic;

   signal clk_57           : std_logic;
   signal clk_100          : std_logic;
   signal clk_50           : std_logic;

   signal locked_a         : std_logic;
   signal locked_b         : std_logic;
   signal unlocked         : std_logic;

   signal rst_50           : std_logic;

begin

   -------------------------------------------------------------------------------------
   -- MMCM A: 630 MHz VCO, NTSC family
   -------------------------------------------------------------------------------------

   i_mmcm_a : MMCME2_ADV
      generic map (
         BANDWIDTH            => "OPTIMIZED",
         CLKOUT4_CASCADE      => FALSE,
         COMPENSATION         => "ZHOLD",
         STARTUP_WAIT         => FALSE,
         CLKIN1_PERIOD        => 10.0,       -- 100 MHz in
         REF_JITTER1          => 0.010,
         DIVCLK_DIVIDE        => 5,          -- PFD 20 MHz
         CLKFBOUT_MULT_F      => 31.500,     -- VCO 630 MHz
         CLKFBOUT_PHASE       => 0.000,
         CLKFBOUT_USE_FINE_PS => FALSE,
         CLKOUT0_DIVIDE_F     => 22.000,     -- 28.636364 MHz
         CLKOUT0_PHASE        => 0.000,
         CLKOUT0_DUTY_CYCLE   => 0.500,
         CLKOUT0_USE_FINE_PS  => FALSE,
         CLKOUT1_DIVIDE       => 11,         -- 57.272727 MHz
         CLKOUT1_PHASE        => 0.000,
         CLKOUT1_DUTY_CYCLE   => 0.500,
         CLKOUT1_USE_FINE_PS  => FALSE,
         CLKOUT2_DIVIDE       => 11,         -- 57.272727 MHz, +90 deg (4.365 ns)
         CLKOUT2_PHASE        => 90.000,
         CLKOUT2_DUTY_CYCLE   => 0.500,
         CLKOUT2_USE_FINE_PS  => FALSE,
         CLKOUT3_DIVIDE       => 25,         -- 25.2 MHz
         CLKOUT3_PHASE        => 0.000,
         CLKOUT3_DUTY_CYCLE   => 0.500,
         CLKOUT3_USE_FINE_PS  => FALSE,
         CLKOUT4_DIVIDE       => 44,         -- 14.318182 MHz
         CLKOUT4_PHASE        => 0.000,
         CLKOUT4_DUTY_CYCLE   => 0.500,
         CLKOUT4_USE_FINE_PS  => FALSE
      )
      port map (
         CLKFBOUT            => clkfb_a_mmcm,
         CLKOUT0             => clk_28_mmcm,
         CLKOUT1             => clk_57_mmcm,
         CLKOUT2             => clk_57_ps_mmcm,
         CLKOUT3             => clk_25_mmcm,
         CLKOUT4             => clk_14_mmcm,
         CLKFBIN             => clkfb_a,
         CLKIN1              => sys_clk_i,
         CLKIN2              => '0',
         CLKINSEL            => '1',
         DADDR               => (others => '0'),
         DCLK                => '0',
         DEN                 => '0',
         DI                  => (others => '0'),
         DO                  => open,
         DRDY                => open,
         DWE                 => '0',
         PSCLK               => '0',
         PSEN                => '0',
         PSINCDEC            => '0',
         PSDONE              => open,
         LOCKED              => locked_a,
         CLKINSTOPPED        => open,
         CLKFBSTOPPED        => open,
         PWRDWN              => '0',
         RST                 => '0'
      );

   -------------------------------------------------------------------------------------
   -- MMCM B: 1000 MHz VCO, CPU and chipset
   -------------------------------------------------------------------------------------

   i_mmcm_b : MMCME2_ADV
      generic map (
         BANDWIDTH            => "OPTIMIZED",
         CLKOUT4_CASCADE      => FALSE,
         COMPENSATION         => "ZHOLD",
         STARTUP_WAIT         => FALSE,
         CLKIN1_PERIOD        => 10.0,       -- 100 MHz in
         REF_JITTER1          => 0.010,
         DIVCLK_DIVIDE        => 1,
         CLKFBOUT_MULT_F      => 10.000,     -- VCO 1000 MHz
         CLKFBOUT_PHASE       => 0.000,
         CLKFBOUT_USE_FINE_PS => FALSE,
         CLKOUT0_DIVIDE_F     => 10.000,     -- 100 MHz
         CLKOUT0_PHASE        => 0.000,
         CLKOUT0_DUTY_CYCLE   => 0.500,
         CLKOUT0_USE_FINE_PS  => FALSE,
         CLKOUT1_DIVIDE       => 20,         -- 50 MHz
         CLKOUT1_PHASE        => 0.000,
         CLKOUT1_DUTY_CYCLE   => 0.500,
         CLKOUT1_USE_FINE_PS  => FALSE
      )
      port map (
         CLKFBOUT            => clkfb_b_mmcm,
         CLKOUT0             => clk_100_mmcm,
         CLKOUT1             => clk_50_mmcm,
         CLKFBIN             => clkfb_b,
         CLKIN1              => sys_clk_i,
         CLKIN2              => '0',
         CLKINSEL            => '1',
         DADDR               => (others => '0'),
         DCLK                => '0',
         DEN                 => '0',
         DI                  => (others => '0'),
         DO                  => open,
         DRDY                => open,
         DWE                 => '0',
         PSCLK               => '0',
         PSEN                => '0',
         PSINCDEC            => '0',
         PSDONE              => open,
         LOCKED              => locked_b,
         CLKINSTOPPED        => open,
         CLKFBSTOPPED        => open,
         PWRDWN              => '0',
         RST                 => '0'
      );

   -------------------------------------------------------------------------------------
   -- Global buffers
   -------------------------------------------------------------------------------------

   clkfb_a_bufg   : BUFG port map (I => clkfb_a_mmcm,   O => clkfb_a);
   clkfb_b_bufg   : BUFG port map (I => clkfb_b_mmcm,   O => clkfb_b);
   clk_28_bufg    : BUFG port map (I => clk_28_mmcm,    O => clk_28_o);
   clk_57_bufg    : BUFG port map (I => clk_57_mmcm,    O => clk_57);
   clk_57_ps_bufg : BUFG port map (I => clk_57_ps_mmcm, O => clk_57_ps_o);
   clk_25_bufg    : BUFG port map (I => clk_25_mmcm,    O => clk_25_o);
   clk_14_bufg    : BUFG port map (I => clk_14_mmcm,    O => clk_14_o);
   clk_100_bufg   : BUFG port map (I => clk_100_mmcm,   O => clk_100);
   clk_50_bufg    : BUFG port map (I => clk_50_mmcm,    O => clk_50);

   clk_57_o   <= clk_57;
   clk_100_o  <= clk_100;
   clk_50_o   <= clk_50;
   main_clk_o <= clk_50;

   -------------------------------------------------------------------------------------
   -- Resets: asserted while either MMCM is unlocked, released synchronously per domain
   -------------------------------------------------------------------------------------

   unlocked <= not (locked_a and locked_b);
   locked_o <= not unlocked;

   i_rst_50 : xpm_cdc_async_rst
      generic map (RST_ACTIVE_HIGH => 1, DEST_SYNC_FF => 6)
      port map (src_arst => unlocked, dest_clk => clk_50, dest_arst => rst_50);

   i_rst_100 : xpm_cdc_async_rst
      generic map (RST_ACTIVE_HIGH => 1, DEST_SYNC_FF => 6)
      port map (src_arst => unlocked, dest_clk => clk_100, dest_arst => rst_100_o);

   i_rst_57 : xpm_cdc_async_rst
      generic map (RST_ACTIVE_HIGH => 1, DEST_SYNC_FF => 6)
      port map (src_arst => unlocked, dest_clk => clk_57, dest_arst => video_rst_o);

   rst_50_o   <= rst_50;
   main_rst_o <= rst_50;

end architecture rtl;
