----------------------------------------------------------------------------------
-- MiSTer2MEGA65 Framework
--
-- MEGA65 main file that contains the whole machine
--
-- MiSTer2MEGA65 done by sy2002 and MJoergen in 2022 and licensed under GPL v3
----------------------------------------------------------------------------------

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

library work;
use work.globals.all;
use work.types_pkg.all;
use work.video_modes_pkg.all;
use work.vdrives_pkg.all;

library xpm;
use xpm.vcomponents.all;

entity MEGA65_Core is
generic (
   G_BOARD : string                                         -- Which platform are we running on.
);
port (
   --------------------------------------------------------------------------------------------------------
   -- QNICE Clock Domain
   --------------------------------------------------------------------------------------------------------

   -- Get QNICE clock from the framework: for the vdrives as well as for RAMs and ROMs
   qnice_clk_i             : in  std_logic;
   qnice_rst_i             : in  std_logic;

   -- Video and audio mode control
   qnice_dvi_o             : out std_logic;              -- 0=HDMI (with sound), 1=DVI (no sound)
   qnice_video_mode_o      : out video_mode_type;        -- Defined in video_modes_pkg.vhd
   qnice_osm_cfg_scaling_o : out std_logic_vector(8 downto 0);
   qnice_scandoubler_o     : out std_logic;              -- 0 = no scandoubler, 1 = scandoubler
   qnice_audio_mute_o      : out std_logic;
   qnice_audio_filter_o    : out std_logic;
   qnice_zoom_crop_o       : out std_logic;
   qnice_ascal_mode_o      : out std_logic_vector(1 downto 0);
   qnice_ascal_polyphase_o : out std_logic;
   qnice_ascal_triplebuf_o : out std_logic;
   qnice_retro15kHz_o      : out std_logic;              -- 0 = normal frequency, 1 = retro 15 kHz frequency
   qnice_csync_o           : out std_logic;              -- 0 = normal HS/VS, 1 = Composite Sync  

   -- Flip joystick ports
   qnice_flip_joyports_o   : out std_logic;

   -- On-Screen-Menu selections
   qnice_osm_control_i     : in  std_logic_vector(255 downto 0);

   -- QNICE general purpose register
   qnice_gp_reg_i          : in  std_logic_vector(255 downto 0);

   -- Core-specific devices
   qnice_dev_id_i          : in  std_logic_vector(15 downto 0);
   qnice_dev_addr_i        : in  std_logic_vector(27 downto 0);
   qnice_dev_data_i        : in  std_logic_vector(15 downto 0);
   qnice_dev_data_o        : out std_logic_vector(15 downto 0);
   qnice_dev_ce_i          : in  std_logic;
   qnice_dev_we_i          : in  std_logic;
   qnice_dev_wait_o        : out std_logic;

   --------------------------------------------------------------------------------------------------------
   -- HyperRAM Clock Domain
   --------------------------------------------------------------------------------------------------------

   hr_clk_i                : in  std_logic;
   hr_rst_i                : in  std_logic;
   hr_core_write_o         : out std_logic;
   hr_core_read_o          : out std_logic;
   hr_core_address_o       : out std_logic_vector(31 downto 0);
   hr_core_writedata_o     : out std_logic_vector(15 downto 0);
   hr_core_byteenable_o    : out std_logic_vector( 1 downto 0);
   hr_core_burstcount_o    : out std_logic_vector( 7 downto 0);
   hr_core_readdata_i      : in  std_logic_vector(15 downto 0);
   hr_core_readdatavalid_i : in  std_logic;
   hr_core_waitrequest_i   : in  std_logic;
   hr_high_i               : in  std_logic;  -- Core is too fast
   hr_low_i                : in  std_logic;  -- Core is too slow

   --------------------------------------------------------------------------------------------------------
   -- Video Clock Domain
   --------------------------------------------------------------------------------------------------------

   video_clk_o             : out std_logic;
   video_rst_o             : out std_logic;
   video_ce_o              : out std_logic;
   video_ce_ovl_o          : out std_logic;
   video_red_o             : out std_logic_vector(7 downto 0);
   video_green_o           : out std_logic_vector(7 downto 0);
   video_blue_o            : out std_logic_vector(7 downto 0);
   video_vs_o              : out std_logic;
   video_hs_o              : out std_logic;
   video_hblank_o          : out std_logic;
   video_vblank_o          : out std_logic;
   -- PCXT-EGA addition (docs/analog-video.md): 1 = line-double the VGA branch only (350-line rasters)
   video_analog_dbl_o      : out std_logic;

   --------------------------------------------------------------------------------------------------------
   -- Core Clock Domain
   --------------------------------------------------------------------------------------------------------

   clk_i                   : in  std_logic;              -- 100 MHz clock

   -- Share clock and reset with the framework
   main_clk_o              : out std_logic;              -- CORE's 54 MHz clock
   main_rst_o              : out std_logic;              -- CORE's reset, synchronized

   -- M2M's reset manager provides 2 signals:
   --    m2m:   Reset the whole machine: Core and Framework
   --    core:  Only reset the core
   main_reset_m2m_i        : in  std_logic;
   main_reset_core_i       : in  std_logic;

   main_pause_core_i       : in  std_logic;

   -- On-Screen-Menu selections
   main_osm_control_i      : in  std_logic_vector(255 downto 0);

   -- QNICE general purpose register converted to main clock domain
   main_qnice_gp_reg_i     : in  std_logic_vector(255 downto 0);

   -- Audio output (Signed PCM)
   main_audio_left_o       : out signed(15 downto 0);
   main_audio_right_o      : out signed(15 downto 0);

   -- M2M Keyboard interface (incl. power led and drive led)
   main_kb_key_num_i       : in  integer range 0 to 79;  -- cycles through all MEGA65 keys
   main_kb_key_pressed_n_i : in  std_logic;              -- low active: debounced feedback: is kb_key_num_i pressed right now?
   main_power_led_o        : out std_logic;
   main_power_led_col_o    : out std_logic_vector(23 downto 0);
   main_drive_led_o        : out std_logic;
   main_drive_led_col_o    : out std_logic_vector(23 downto 0);

   -- Joysticks and paddles input
   main_joy_1_up_n_i       : in  std_logic;
   main_joy_1_down_n_i     : in  std_logic;
   main_joy_1_left_n_i     : in  std_logic;
   main_joy_1_right_n_i    : in  std_logic;
   main_joy_1_fire_n_i     : in  std_logic;
   main_joy_1_up_n_o       : out std_logic;
   main_joy_1_down_n_o     : out std_logic;
   main_joy_1_left_n_o     : out std_logic;
   main_joy_1_right_n_o    : out std_logic;
   main_joy_1_fire_n_o     : out std_logic;
   main_joy_2_up_n_i       : in  std_logic;
   main_joy_2_down_n_i     : in  std_logic;
   main_joy_2_left_n_i     : in  std_logic;
   main_joy_2_right_n_i    : in  std_logic;
   main_joy_2_fire_n_i     : in  std_logic;
   main_joy_2_up_n_o       : out std_logic;
   main_joy_2_down_n_o     : out std_logic;
   main_joy_2_left_n_o     : out std_logic;
   main_joy_2_right_n_o    : out std_logic;
   main_joy_2_fire_n_o     : out std_logic;

   main_pot1_x_i           : in  std_logic_vector(7 downto 0);
   main_pot1_y_i           : in  std_logic_vector(7 downto 0);
   main_pot2_x_i           : in  std_logic_vector(7 downto 0);
   main_pot2_y_i           : in  std_logic_vector(7 downto 0);
   main_rtc_i              : in  std_logic_vector(64 downto 0);

   -- Ethernet PHY pins (PCXT-EGA addition: CORE/vhdl/eth_mac.vhd; KSZ8081RND in RMII mode on
   -- the R6). Passed through raw by top_mega65-r6.vhd, the MAC owns their clocking and timing.
   eth_clock_o             : out   std_logic;
   eth_led2_o              : out   std_logic;
   eth_mdc_o               : out   std_logic;
   eth_mdio_io             : inout std_logic;
   eth_reset_o             : out   std_logic;
   eth_rxd_i               : in    std_logic_vector(1 downto 0);
   eth_rxdv_i              : in    std_logic;
   eth_rxer_i              : in    std_logic;
   eth_txd_o               : out   std_logic_vector(1 downto 0);
   eth_txen_o              : out   std_logic;

   -- Internal 3.5" floppy drive, drive A lines (PCXT-EGA addition: CORE/vhdl/floppy_sector_engine.vhd,
   -- docs/floppy.md). Shugart interface, all active low, passed through raw by top_mega65-r6.vhd;
   -- the drive B lines (f_motorb_o, f_selectb_o) stay tied off inactive in the top.
   f_density_o             : out   std_logic;
   f_motora_o              : out   std_logic;
   f_selecta_o             : out   std_logic;
   f_side1_o               : out   std_logic;
   f_stepdir_o             : out   std_logic;
   f_step_o                : out   std_logic;
   f_wdata_o               : out   std_logic;
   f_wgate_o               : out   std_logic;
   f_index_i               : in    std_logic;
   f_track0_i              : in    std_logic;
   f_writeprotect_i        : in    std_logic;
   f_rdata_i               : in    std_logic;
   f_diskchanged_i         : in    std_logic;

   -- CBM-488/IEC serial port
   iec_reset_n_o           : out std_logic;
   iec_atn_n_o             : out std_logic;
   iec_clk_en_o            : out std_logic;
   iec_clk_n_i             : in  std_logic;
   iec_clk_n_o             : out std_logic;
   iec_data_en_o           : out std_logic;
   iec_data_n_i            : in  std_logic;
   iec_data_n_o            : out std_logic;
   iec_srq_en_o            : out std_logic;
   iec_srq_n_i             : in  std_logic;
   iec_srq_n_o             : out std_logic;

   -- C64 Expansion Port (aka Cartridge Port)
   cart_en_o               : out std_logic;  -- Enable port, active high
   cart_phi2_o             : out std_logic;
   cart_dotclock_o         : out std_logic;
   cart_dma_i              : in  std_logic;
   cart_reset_oe_o         : out std_logic;
   cart_reset_i            : in  std_logic;
   cart_reset_o            : out std_logic;
   cart_game_oe_o          : out std_logic;
   cart_game_i             : in  std_logic;
   cart_game_o             : out std_logic;
   cart_exrom_oe_o         : out std_logic;
   cart_exrom_i            : in  std_logic;
   cart_exrom_o            : out std_logic;
   cart_nmi_oe_o           : out std_logic;
   cart_nmi_i              : in  std_logic;
   cart_nmi_o              : out std_logic;
   cart_irq_oe_o           : out std_logic;
   cart_irq_i              : in  std_logic;
   cart_irq_o              : out std_logic;
   cart_roml_oe_o          : out std_logic;
   cart_roml_i             : in  std_logic;
   cart_roml_o             : out std_logic;
   cart_romh_oe_o          : out std_logic;
   cart_romh_i             : in  std_logic;
   cart_romh_o             : out std_logic;
   cart_ctrl_oe_o          : out std_logic; -- 0 : tristate (i.e. input), 1 : output
   cart_ba_i               : in  std_logic;
   cart_rw_i               : in  std_logic;
   cart_io1_i              : in  std_logic;
   cart_io2_i              : in  std_logic;
   cart_ba_o               : out std_logic;
   cart_rw_o               : out std_logic;
   cart_io1_o              : out std_logic;
   cart_io2_o              : out std_logic;
   cart_addr_oe_o          : out std_logic; -- 0 : tristate (i.e. input), 1 : output
   cart_a_i                : in  unsigned(15 downto 0);
   cart_a_o                : out unsigned(15 downto 0);
   cart_data_oe_o          : out std_logic; -- 0 : tristate (i.e. input), 1 : output
   cart_d_i                : in  unsigned( 7 downto 0);
   cart_d_o                : out unsigned( 7 downto 0)
);
end entity MEGA65_Core;

architecture synthesis of MEGA65_Core is

---------------------------------------------------------------------------------------------
-- Clocks and active high reset signals for each clock domain
---------------------------------------------------------------------------------------------

signal main_clk               : std_logic;               -- Core main clock (50 MHz chipset)
signal main_rst               : std_logic;
signal clk_100                : std_logic;
signal clk_28                 : std_logic;
signal clk_57                 : std_logic;
signal clk_57_ps              : std_logic;
signal clk_25                 : std_logic;
signal clk_14                 : std_logic;
signal clk_locked             : std_logic;
signal video_rst              : std_logic;
signal clk_50_ps              : std_logic;               -- 50 MHz +90 deg: Ethernet MAC (eth_mac.vhd)
signal rst_50_ps              : std_logic;

-- ROM download stream (rom_loader.vhd -> main.vhd), main_clk domain
signal main_rom_download      : std_logic;
signal main_rom_index         : std_logic_vector(7 downto 0);
signal main_rom_wr            : std_logic;
signal main_rom_addr          : std_logic_vector(24 downto 0);
signal main_rom_data          : std_logic_vector(15 downto 0);
signal main_rom_wait          : std_logic;
signal main_led_disk          : std_logic;

-- QNICE clock domain
signal qnice_rom_wait         : std_logic;
signal qnice_rom_data         : std_logic_vector(15 downto 0);

---------------------------------------------------------------------------------------------
-- main_clk (MiSTer core's clock)
---------------------------------------------------------------------------------------------

---------------------------------------------------------------------------------------------
-- qnice_clk
---------------------------------------------------------------------------------------------

---------------------------------------------------------------------------------------------
-- Democore & example stuff: Delete before starting to port your own core
---------------------------------------------------------------------------------------------

-- Democore menu items
-- Menu line numbers (bit numbers in qnice_osm_control_i), see config.vhd OPTM_ITEMS
constant C_MENU_HDMI_16_9_50   : natural := 21;
constant C_MENU_HDMI_16_9_60   : natural := 22;
constant C_MENU_HDMI_4_3_50    : natural := 23;
constant C_MENU_HDMI_5_4_50    : natural := 24;
constant C_MENU_HDMI_640_60    : natural := 25;
constant C_MENU_HDMI_720_5994  : natural := 26;
constant C_MENU_SVGA_800_60    : natural := 27;
constant C_MENU_VGA_15KHZ      : natural := 63;
constant C_MENU_VGA_15KHZ_CS   : natural := 64;
constant C_MENU_CRT_EMULATION  : natural := 92;
constant C_MENU_HDMI_ZOOM      : natural := 93;
constant C_MENU_IMPROVE_AUDIO  : natural := 94;

-- analog VGA modes (docs/analog-video.md)
signal main_video_mode13       : std_logic;   -- core's private 31.5 kHz raster active (async)
signal main_video_mode350      : std_logic;   -- core's 350-line 18.4-21.9 kHz raster active (async)
signal qnice_vga_15khz         : std_logic;   -- either 15 kHz menu item

-- QNICE clock domain
signal qnice_demo_vd_data_o   : std_logic_vector(15 downto 0);
signal qnice_demo_vd_ce       : std_logic;
signal qnice_demo_vd_we       : std_logic;

-- vdrives <-> main (floppy A, floppy B, hard disk)
signal main_img_mounted       : std_logic_vector(C_VDNUM-1 downto 0);
signal main_img_readonly      : std_logic;
signal main_img_size          : std_logic_vector(31 downto 0);
signal main_drive_mounted     : std_logic_vector(C_VDNUM-1 downto 0);
signal qnice_sd_lba           : vd_vec_array(C_VDNUM-1 downto 0)(31 downto 0);
signal qnice_sd_blk_cnt       : vd_vec_array(C_VDNUM-1 downto 0)(5 downto 0);
signal qnice_sd_rd            : vd_std_array(C_VDNUM-1 downto 0);
signal qnice_sd_wr            : vd_std_array(C_VDNUM-1 downto 0);
signal qnice_sd_ack           : vd_std_array(C_VDNUM-1 downto 0);
signal qnice_sd_buff_addr     : std_logic_vector(AW downto 0);
signal qnice_sd_buff_dout     : std_logic_vector(DW downto 0);
signal qnice_sd_buff_din      : vd_vec_array(C_VDNUM-1 downto 0)(DW downto 0);
signal qnice_sd_buff_wr       : std_logic;
signal main_cache_dirty       : std_logic_vector(C_VDNUM-1 downto 0);

-- debug counters from main.vhd, read back through rom_loader
signal main_dbg_bus_reads     : std_logic_vector(15 downto 0);
signal main_dbg_vsync         : std_logic_vector(15 downto 0);
signal main_dbg_keys          : std_logic_vector(15 downto 0);
signal main_dbg_flags         : std_logic_vector(7 downto 0);

-- NE1000 Ethernet card (docs/ethernet.md): the MAC (eth_mac.vhd, PHY pins, clk_50_ps) exchanges byte
-- streams with the card inside main.vhd in the main_clk domain. The station address comes from the
-- firmware through rom_loader.vhd (the MEGA65's own MAC from the SD card's configuration sector, or
-- the locally administered default 02:4D:36:35:00:01, m2m-rom.asm ETH_SET_MAC); main_eth_mac_valid
-- rises once all six bytes are there and gates the card. The menu (main.vhd) decides on/off and IRQ.
signal main_eth_mac           : std_logic_vector(47 downto 0);
signal main_eth_mac_valid     : std_logic;
signal main_eth_rx_empty      : std_logic;
signal main_eth_rx_rd         : std_logic;
signal main_eth_rx_data       : std_logic_vector(8 downto 0);
signal main_eth_tx_full       : std_logic;
signal main_eth_tx_wr         : std_logic;
signal main_eth_tx_data       : std_logic_vector(8 downto 0);
signal main_eth_tx_done       : std_logic;

-- Internal floppy drive read path (docs/floppy.md, floppy_sector_engine.vhd): the firmware drives the
-- engine through rom_loader's register window (QNICE clock there, main_clk here); the engine's COPY
-- writes blocks into main.vhd's vd_glue buffer and the block-error flag reaches mgmt_bridge.
signal main_flp_cmd           : std_logic;
signal main_flp_cmd_code      : std_logic_vector(3 downto 0);
signal main_flp_arg0          : std_logic_vector(15 downto 0);
signal main_flp_arg1          : std_logic_vector(15 downto 0);
signal main_flp_enable        : std_logic;
signal main_flp_chg_clr       : std_logic;
signal main_flp_vfy_clr       : std_logic;
signal main_flp_blk_err       : std_logic;
signal main_flp_busy          : std_logic;
signal main_flp_err           : std_logic_vector(7 downto 0);
signal main_flp_det_max_r     : std_logic_vector(7 downto 0);
signal main_flp_det_hd        : std_logic;
signal main_flp_det_dd        : std_logic;
signal main_flp_valid         : std_logic_vector(17 downto 0);
signal main_flp_crcerr        : std_logic_vector(17 downto 0);
signal main_flp_cache_cyl     : std_logic_vector(7 downto 0);
signal main_flp_cache_head    : std_logic;
signal main_flp_cache_rate    : std_logic;
signal main_flp_head_track    : std_logic_vector(7 downto 0);
signal main_flp_state         : std_logic_vector(7 downto 0);
signal main_flp_live          : std_logic_vector(8 downto 0);
signal main_flp_res           : std_logic_vector(95 downto 0);
signal main_flp_dbg           : std_logic_vector(95 downto 0);
signal main_flp_cnt_index     : std_logic_vector(15 downto 0);
signal main_flp_cnt_idam_ok   : std_logic_vector(15 downto 0);
signal main_flp_cnt_dam_ok    : std_logic_vector(15 downto 0);
signal main_flp_cnt_steps     : std_logic_vector(15 downto 0);
signal main_flp_last_chrn     : std_logic_vector(31 downto 0);
signal main_flp_buf_addr      : std_logic_vector(8 downto 0);
signal main_flp_buf_data      : std_logic_vector(7 downto 0);
signal main_flp_buf_we        : std_logic;
signal main_flp_buf_rd        : std_logic;
signal main_flp_buf_rdata     : std_logic_vector(7 downto 0);

begin

   -- HyperRAM is driven by main.vhd's memory backend (see mem_backend.vhd)

   -- Tristate all expansion port drivers that we can directly control
   -- @TODO: As soon as we support modules that can act as busmaster, we need to become more flexible here
   cart_ctrl_oe_o       <= '0';
   cart_addr_oe_o       <= '0';
   cart_data_oe_o       <= '0';

   -- Due to a bug in the R5/R6 boards, the cartridge port needs to be enabled for joystick port 2 to work 
   cart_en_o            <= '1';

   cart_reset_oe_o      <= '0';
   cart_game_oe_o       <= '0';
   cart_exrom_oe_o      <= '0';
   cart_nmi_oe_o        <= '0';
   cart_irq_oe_o        <= '0';
   cart_roml_oe_o       <= '0';
   cart_romh_oe_o       <= '0';

   -- Default values for all signals
   cart_phi2_o          <= '0';
   cart_reset_o         <= '1';
   cart_dotclock_o      <= '0';
   cart_game_o          <= '1';
   cart_exrom_o         <= '1';
   cart_nmi_o           <= '1';
   cart_irq_o           <= '1';
   cart_roml_o          <= '0';
   cart_romh_o          <= '0';
   cart_ba_o            <= '0';
   cart_rw_o            <= '0';
   cart_io1_o           <= '0';
   cart_io2_o           <= '0';
   cart_a_o             <= (others => '0');
   cart_d_o             <= (others => '0');

   main_joy_1_up_n_o    <= '1';
   main_joy_1_down_n_o  <= '1';
   main_joy_1_left_n_o  <= '1';
   main_joy_1_right_n_o <= '1';
   main_joy_1_fire_n_o  <= '1';
   main_joy_2_up_n_o    <= '1';
   main_joy_2_down_n_o  <= '1';
   main_joy_2_left_n_o  <= '1';
   main_joy_2_right_n_o <= '1';
   main_joy_2_fire_n_o  <= '1';


   -- MMCME2_ADV clock generators (see clk.vhd): 100/50 MHz for CPU and chipset,
   -- the 28.636/57.273/57.273+90/25.2/14.318 MHz family for video
   clk_gen : entity work.clk
      port map (
         sys_clk_i         => clk_i,           -- expects 100 MHz
         main_clk_o        => main_clk,        -- 50 MHz chipset clock
         main_rst_o        => main_rst,
         clk_50_o          => open,
         rst_50_o          => open,
         clk_50_ps_o       => clk_50_ps,       -- Ethernet MAC clock (+90 deg)
         rst_50_ps_o       => rst_50_ps,
         clk_100_o         => clk_100,
         rst_100_o         => open,
         clk_28_o          => clk_28,
         clk_57_o          => clk_57,
         clk_57_ps_o       => clk_57_ps,
         clk_25_o          => clk_25,
         clk_14_o          => clk_14,
         video_rst_o       => video_rst,
         locked_o          => clk_locked
      ); -- clk_gen

   main_clk_o  <= main_clk;
   main_rst_o  <= main_rst;
   video_clk_o <= clk_57_ps;                   -- the core's output retime domain
   video_rst_o <= video_rst;

   ---------------------------------------------------------------------------------------------
   -- main_clk (MiSTer core's clock)
   ---------------------------------------------------------------------------------------------

   -- MEGA65's power led: By default, it is on and glows green when the MEGA65 is powered on.
   -- We switch it to blue when a long reset is detected and as long as the user keeps pressing the preset button
   main_power_led_o     <= '1';
   -- Diagnostic: red while the core's MMCMs are not locked (the core cannot
   -- run and the ROM loader would stall), blue during a long reset, else green.
   main_power_led_col_o <= x"FF0000" when clk_locked = '0' else
                           x"0000FF" when main_reset_m2m_i else
                           x"00FF00";

   -- main.vhd contains the actual MiSTer core
   i_main : entity work.main
      generic map (
         G_VDNUM              => C_VDNUM
      )
      port map (
         clk_main_i           => main_clk,
         clk_core_i           => clk_100,
         clk_video_base_i     => clk_28,
         clk_video_x2_i       => clk_57,
         clk_video_out_ps_i   => clk_57_ps,
         clk_video_vga_i      => clk_25,
         clk_14_318_i         => clk_14,
         clk_locked_i         => clk_locked,
         reset_soft_i         => main_reset_core_i,
         reset_hard_i         => main_reset_m2m_i,
         pause_i              => main_pause_core_i,

         clk_main_speed_i     => CORE_CLK_SPEED,

         -- Video output
         -- Raw EGA/CGA/VGA rasters in the clk_57_ps domain, re-timed by the framework's scaler
         video_ce_o           => video_ce_o,
         video_mode13_o       => main_video_mode13,
         video_mode350_o      => main_video_mode350,
         video_red_o          => video_red_o,
         video_green_o        => video_green_o,
         video_blue_o         => video_blue_o,
         video_vs_o           => video_vs_o,
         video_hs_o           => video_hs_o,
         video_hblank_o       => video_hblank_o,
         video_vblank_o       => video_vblank_o,

         -- audio output (pcm format, signed values)
         audio_left_o         => main_audio_left_o,
         audio_right_o        => main_audio_right_o,

         -- BIOS ROMs streamed by rom_loader
         rom_download_i       => main_rom_download,
         rom_index_i          => main_rom_index,
         rom_wr_i             => main_rom_wr,
         rom_addr_i           => main_rom_addr,
         rom_data_i           => main_rom_data,
         rom_wait_o           => main_rom_wait,

         bios_missing_pcxt_o  => open,
         bios_missing_ega_o   => open,
         splash_active_o      => open,
         led_disk_o           => main_led_disk,
         dbg_bus_reads_o      => main_dbg_bus_reads,
         dbg_vsync_o          => main_dbg_vsync,
         dbg_keys_o           => main_dbg_keys,
         dbg_flags_o          => main_dbg_flags,

         osm_control_i        => main_osm_control_i,

         -- virtual drives: floppy A, floppy B, hard disk
         clk_qnice_i          => qnice_clk_i,
         hr_clk_i             => hr_clk_i,
         hr_rst_i             => hr_rst_i,
         hr_write_o           => hr_core_write_o,
         hr_read_o            => hr_core_read_o,
         hr_address_o         => hr_core_address_o,
         hr_writedata_o       => hr_core_writedata_o,
         hr_byteenable_o      => hr_core_byteenable_o,
         hr_burstcount_o      => hr_core_burstcount_o,
         hr_readdata_i        => hr_core_readdata_i,
         hr_readdatavalid_i   => hr_core_readdatavalid_i,
         hr_waitrequest_i     => hr_core_waitrequest_i,
         img_mounted_i        => main_img_mounted,
         img_readonly_i       => main_img_readonly,
         img_size_i           => main_img_size,
         drive_mounted_i      => main_drive_mounted,
         sd_lba_o             => qnice_sd_lba,
         sd_blk_cnt_o         => qnice_sd_blk_cnt,
         sd_rd_o              => qnice_sd_rd,
         sd_wr_o              => qnice_sd_wr,
         sd_ack_i             => qnice_sd_ack,
         sd_buff_addr_i       => qnice_sd_buff_addr,
         sd_buff_dout_i       => qnice_sd_buff_dout,
         sd_buff_din_o        => qnice_sd_buff_din,
         sd_buff_wr_i         => qnice_sd_buff_wr,
         flp_buf_addr_i       => main_flp_buf_addr,
         flp_buf_data_i       => main_flp_buf_data,
         flp_buf_we_i         => main_flp_buf_we,
         flp_buf_rd_i         => main_flp_buf_rd,
         flp_buf_rdata_o      => main_flp_buf_rdata,
         flp_blk_err_i        => main_flp_blk_err,

         -- M2M Keyboard interface
         kb_key_num_i         => main_kb_key_num_i,
         kb_key_pressed_n_i   => main_kb_key_pressed_n_i,

         -- MEGA65 joysticks and paddles/mouse/potentiometers
         joy_1_up_n_i         => main_joy_1_up_n_i ,
         joy_1_down_n_i       => main_joy_1_down_n_i,
         joy_1_left_n_i       => main_joy_1_left_n_i,
         joy_1_right_n_i      => main_joy_1_right_n_i,
         joy_1_fire_n_i       => main_joy_1_fire_n_i,

         joy_2_up_n_i         => main_joy_2_up_n_i,
         joy_2_down_n_i       => main_joy_2_down_n_i,
         joy_2_left_n_i       => main_joy_2_left_n_i,
         joy_2_right_n_i      => main_joy_2_right_n_i,
         joy_2_fire_n_i       => main_joy_2_fire_n_i,

         pot1_x_i             => main_pot1_x_i,
         pot1_y_i             => main_pot1_y_i,
         pot2_x_i             => main_pot2_x_i,
         pot2_y_i             => main_pot2_y_i,

         -- NE1000 Ethernet card: station address and its valid flag (i_rom_loader), MAC streams (i_eth_mac below)
         eth_enable_i         => main_eth_mac_valid,
         eth_mac_addr_i       => main_eth_mac,
         eth_rx_empty_i       => main_eth_rx_empty,
         eth_rx_rd_o          => main_eth_rx_rd,
         eth_rx_data_i        => main_eth_rx_data,
         eth_tx_full_i        => main_eth_tx_full,
         eth_tx_wr_o          => main_eth_tx_wr,
         eth_tx_data_o        => main_eth_tx_data,
         eth_tx_done_i        => main_eth_tx_done
      ); -- i_main

   ---------------------------------------------------------------------------------------------
   -- Ethernet MAC (PCXT-EGA addition, see eth_mac.vhd): PHY reset + MDIO, RMII receive and transmit
   -- engines with dual-clock FIFOs towards the NE1000 card inside main.vhd. The PHY is clocked with
   -- the 50 MHz chipset clock (forwarded through an ODDR inside), the MAC runs on its +90 degree copy,
   -- the card side of the FIFOs is main_clk. Reset is the MMCM lock only, so the PHY is not re-reset
   -- by M2M or core resets (the card is, through the chipset reset in main.vhd).
   ---------------------------------------------------------------------------------------------
   i_eth_mac : entity work.eth_mac
      port map (
         clk_ref_i         => main_clk,
         clk_i             => clk_50_ps,
         rst_i             => rst_50_ps,
         eth_clock_o       => eth_clock_o,
         eth_reset_o       => eth_reset_o,
         eth_mdc_o         => eth_mdc_o,
         eth_mdio_io       => eth_mdio_io,
         eth_rxd_i         => eth_rxd_i,
         eth_rxdv_i        => eth_rxdv_i,
         eth_rxer_i        => eth_rxer_i,
         eth_txd_o         => eth_txd_o,
         eth_txen_o        => eth_txen_o,
         eth_led2_o        => eth_led2_o,
         sys_clk_i         => main_clk,
         sys_rst_i         => main_rst,
         rx_rd_i           => main_eth_rx_rd,
         rx_data_o         => main_eth_rx_data,
         rx_empty_o        => main_eth_rx_empty,
         tx_wr_i           => main_eth_tx_wr,
         tx_data_i         => main_eth_tx_data,
         tx_full_o         => main_eth_tx_full,
         tx_done_o         => main_eth_tx_done,
         link_up_o         => open,
         dbg_rx_frames_o   => open,
         dbg_rx_crc_ok_o   => open,
         dbg_tx_frames_o   => open,
         dbg_phy_o         => open
      ); -- i_eth_mac

   ---------------------------------------------------------------------------------------------
   -- Internal floppy drive: sector engine (PCXT-EGA addition, floppy_sector_engine.vhd and
   -- docs/floppy.md). Drives the internal 3.5" drive (select, motor, seek) and reads MFM at both
   -- rates into a track cache; the firmware (flpdrv.asm) commands it through i_rom_loader's
   -- register window when "A: internal drive" is on. Runs on the 50 MHz chipset clock; the drive
   -- inputs are asynchronous (synchronised inside, false paths in CORE.xdc). Reset is the clock-lock
   -- reset only, like the Ethernet MAC. Phase 3 added WRITE_SECTOR (floppy_mfm_writer.vhd) with the block
   -- buffer read back through vd_glue. The bring-up spike (floppy_phy_spike.vhd) is no longer
   -- instantiated; it shares floppy_drive_if / floppy_mfm_reader with the engine.
   ---------------------------------------------------------------------------------------------
   i_floppy_sector_engine : entity work.floppy_sector_engine
      port map (
         clk_i             => main_clk,
         rst_i             => main_rst,
         enable_i          => main_flp_enable,
         chg_clr_i         => main_flp_chg_clr,
         vfy_clr_i         => main_flp_vfy_clr,
         cmd_valid_i       => main_flp_cmd,
         cmd_i             => main_flp_cmd_code,
         cmd_cyl_i         => main_flp_arg0(7 downto 0),
         cmd_head_i        => main_flp_arg0(8),
         cmd_rate_hd_i     => main_flp_arg0(9),
         cmd_force_i       => main_flp_arg0(10),
         cmd_sector_i      => main_flp_arg1(4 downto 0),
         cmd_spt_i         => main_flp_arg1(12 downto 8),
         busy_o            => main_flp_busy,
         err_o             => main_flp_err,
         det_max_r_o       => main_flp_det_max_r,
         det_hd_o          => main_flp_det_hd,
         det_dd_o          => main_flp_det_dd,
         valid_o           => main_flp_valid,
         crcerr_o          => main_flp_crcerr,
         cache_cyl_o       => main_flp_cache_cyl,
         cache_head_o      => main_flp_cache_head,
         cache_rate_o      => main_flp_cache_rate,
         head_track_o      => main_flp_head_track,
         state_o           => main_flp_state,
         cache_valid_o     => main_flp_live(6),
         wp_o              => main_flp_live(0),
         dskchg_o          => main_flp_live(1),
         dskchg_live_o     => main_flp_live(5),
         track0_o          => main_flp_live(2),
         motor_o           => main_flp_live(3),
         index_seen_o      => main_flp_live(4),
         vfy_pend_o        => main_flp_live(7),
         vfy_fail_o        => main_flp_live(8),
         cnt_index_o       => main_flp_cnt_index,
         cnt_idam_ok_o     => main_flp_cnt_idam_ok,
         cnt_dam_ok_o      => main_flp_cnt_dam_ok,
         cnt_steps_o       => main_flp_cnt_steps,
         last_chrn_o       => main_flp_last_chrn,
         buf_addr_o        => main_flp_buf_addr,
         buf_data_o        => main_flp_buf_data,
         buf_we_o          => main_flp_buf_we,
         buf_rd_o          => main_flp_buf_rd,
         buf_rdata_i       => main_flp_buf_rdata,
         f_density_o       => f_density_o,
         f_motora_o        => f_motora_o,
         f_selecta_o       => f_selecta_o,
         f_side1_o         => f_side1_o,
         f_stepdir_o       => f_stepdir_o,
         f_step_o          => f_step_o,
         f_wdata_o         => f_wdata_o,
         f_wgate_o         => f_wgate_o,
         f_index_i         => f_index_i,
         f_track0_i        => f_track0_i,
         f_writeprotect_i  => f_writeprotect_i,
         f_rdata_i         => f_rdata_i,
         f_diskchanged_i   => f_diskchanged_i
      ); -- i_floppy_sector_engine

   -- result words 0..5 and debug words 6..11 as rom_loader's register window shows them (see there)
   main_flp_res <= main_flp_state & main_flp_head_track &                                              -- 5
                   main_flp_cache_cyl & "00" & main_flp_cache_rate & main_flp_cache_head &
                      main_flp_crcerr(17 downto 16) & main_flp_valid(17 downto 16) &                    -- 4
                   main_flp_crcerr(15 downto 0) &                                                       -- 3
                   main_flp_valid(15 downto 0) &                                                        -- 2
                   "000000" & main_flp_det_dd & main_flp_det_hd & main_flp_det_max_r &                  -- 1
                   x"00" & main_flp_err;                                                                -- 0
   main_flp_dbg <= main_flp_last_chrn(15 downto 0) & main_flp_last_chrn(31 downto 16) &                -- 11, 10
                   main_flp_cnt_steps & main_flp_cnt_dam_ok & main_flp_cnt_idam_ok & main_flp_cnt_index; -- 9, 8, 7, 6

   ---------------------------------------------------------------------------------------------
   -- Audio and video settings (QNICE clock domain)
   ---------------------------------------------------------------------------------------------

   -- Due to a discussion on the MEGA65 discord (https://discord.com/channels/719326990221574164/794775503818588200/1039457688020586507)
   -- we decided to choose a naming convention for the PAL modes that might be more intuitive for the end users than it is
   -- for the programmers: "4:3" means "meant to be run on a 4:3 monitor", "5:4 on a 5:4 monitor".
   -- The technical reality is though, that in our "5:4" mode we are actually doing a 4/3 aspect ratio adjustment
   -- while in the 4:3 mode we are outputting a 5:4 image. This is kind of odd, but it seemed that our 4/3 aspect ratio
   -- adjusted image looks best on a 5:4 monitor and the other way round.
   -- Not sure if this will stay forever or if we will come up with a better naming convention.
   i_analog_video_ctl : entity work.analog_video_ctl
      port map (
         qnice_clk_i         => qnice_clk_i,
         qnice_vga_15khz_i   => qnice_vga_15khz,
         qnice_vga_csync_i   => qnice_osm_control_i(C_MENU_VGA_15KHZ_CS),
         qnice_scandoubler_o => qnice_scandoubler_o,
         qnice_retro15khz_o  => qnice_retro15kHz_o,
         qnice_csync_o       => qnice_csync_o,
         video_clk_i         => clk_57_ps,
         video_mode13_i      => main_video_mode13,
         video_mode350_i     => main_video_mode350,
         video_analog_dbl_o  => video_analog_dbl_o,
         video_ce_ovl_o      => video_ce_ovl_o
      ); -- i_analog_video_ctl
   qnice_vga_15khz <= qnice_osm_control_i(C_MENU_VGA_15KHZ) or qnice_osm_control_i(C_MENU_VGA_15KHZ_CS);

   qnice_video_mode_o <= C_VIDEO_SVGA_800_60   when qnice_osm_control_i(C_MENU_SVGA_800_60)    = '1' else
                         C_VIDEO_HDMI_720_5994 when qnice_osm_control_i(C_MENU_HDMI_720_5994)  = '1' else
                         C_VIDEO_HDMI_640_60   when qnice_osm_control_i(C_MENU_HDMI_640_60)    = '1' else
                         C_VIDEO_HDMI_5_4_50   when qnice_osm_control_i(C_MENU_HDMI_5_4_50)    = '1' else
                         C_VIDEO_HDMI_4_3_50   when qnice_osm_control_i(C_MENU_HDMI_4_3_50)    = '1' else
                         C_VIDEO_HDMI_16_9_60  when qnice_osm_control_i(C_MENU_HDMI_16_9_60)   = '1' else
                         C_VIDEO_HDMI_16_9_50;

   -- Use On-Screen-Menu selections to configure several audio and video settings
   -- Video and audio mode control
   qnice_dvi_o                <= '0';                                         -- 0=HDMI (with sound), 1=DVI (no sound)
   qnice_audio_mute_o         <= '0';                                         -- audio is not muted
   qnice_audio_filter_o       <= qnice_osm_control_i(C_MENU_IMPROVE_AUDIO);   -- 0 = raw audio, 1 = use filters from globals.vhd
   qnice_zoom_crop_o          <= qnice_osm_control_i(C_MENU_HDMI_ZOOM);       -- 0 = no zoom/crop
   
   -- These two signals are often used as a pair (i.e. both '1'), particularly when
   -- you want to run old analog cathode ray tube monitors or TVs (via SCART)
   -- If you want to provide your users a choice, then a good choice is:
   --    "Standard VGA":                     qnice_retro15kHz_o=0 and qnice_csync_o=0
   --    "Retro 15 kHz with HSync and VSync" qnice_retro15kHz_o=1 and qnice_csync_o=0
   --    "Retro 15 kHz with CSync"           qnice_retro15kHz_o=1 and qnice_csync_o=1
   -- qnice_scandoubler_o, qnice_retro15kHz_o, qnice_csync_o and video_ce_ovl_o
   -- come from i_analog_video_ctl below (VGA menu group, docs/analog-video.md)
   qnice_osm_cfg_scaling_o    <= (others => '1');

   -- ascal filters that are applied while processing the input
   -- 00 : Nearest Neighbour
   -- 01 : Bilinear
   -- 10 : Sharp Bilinear
   -- 11 : Bicubic
   qnice_ascal_mode_o         <= "00";

   -- If polyphase is '1' then the ascal filter mode is ignored and polyphase filters are used instead
   -- @TODO: Right now, the filters are hardcoded in the M2M framework, we need to make them changeable inside m2m-rom.asm
   qnice_ascal_polyphase_o    <= qnice_osm_control_i(C_MENU_CRT_EMULATION);

   -- ascal triple-buffering
   -- @TODO: Right now, the M2M framework only supports OFF, so do not touch until the framework is upgraded
   qnice_ascal_triplebuf_o    <= '0';

   -- Flip joystick ports (i.e. the joystick in port 2 is used as joystick 1 and vice versa)
   qnice_flip_joyports_o      <= '0';

   ---------------------------------------------------------------------------------------------
   -- Core specific device handling (QNICE clock domain)
   ---------------------------------------------------------------------------------------------

   core_specific_devices : process(all)
   begin
      -- make sure that this is x"EEEE" by default and avoid a register here by having this default value
      qnice_dev_data_o     <= x"EEEE";
      qnice_dev_wait_o     <= '0';

      -- Demo core specific: Delete before starting to port your core
      qnice_demo_vd_ce     <= '0';
      qnice_demo_vd_we     <= '0';

      case qnice_dev_id_i is

         -- Demo core specific stuff: delete before porting your own core
         when C_DEV_DEMO_VD =>
            qnice_demo_vd_ce     <= qnice_dev_ce_i;
            qnice_demo_vd_we     <= qnice_dev_we_i;
            qnice_dev_data_o     <= qnice_demo_vd_data_o;

         -- BIOS ROM files, auto-loaded by the firmware into rom_loader (see globals.vhd)
         when C_DEV_ROM_PCXT | C_DEV_ROM_EGA | C_DEV_ROM_XTIDE =>
            qnice_dev_wait_o     <= qnice_rom_wait;
            qnice_dev_data_o     <= qnice_rom_data;

         when others => null;
      end case;
   end process core_specific_devices;

   ---------------------------------------------------------------------------------------------
   -- Dual Clocks
   ---------------------------------------------------------------------------------------------

   -- Put your dual-clock devices such as RAMs and ROMs here

   -- QNICE byte writes of the auto-loaded BIOS files -> the core's ioctl-style ROM port
   i_rom_loader : entity work.rom_loader
      generic map (
         G_DEV_PCXT        => C_DEV_ROM_PCXT,
         G_DEV_EGA         => C_DEV_ROM_EGA,
         G_DEV_XTIDE       => C_DEV_ROM_XTIDE
      )
      port map (
         qnice_clk_i       => qnice_clk_i,
         qnice_rst_i       => qnice_rst_i,
         qnice_dev_id_i    => qnice_dev_id_i,
         qnice_dev_addr_i  => qnice_dev_addr_i,
         qnice_dev_data_i  => qnice_dev_data_i,
         qnice_dev_ce_i    => qnice_dev_ce_i,
         qnice_dev_we_i    => qnice_dev_we_i,
         qnice_dev_wait_o  => qnice_rom_wait,
         qnice_dev_data_o  => qnice_rom_data,
         core_clk_i        => main_clk,
         core_rst_i        => main_rst,             -- clock-lock reset only: main_reset_m2m_i is held during autoload
         rom_download_o    => main_rom_download,
         rom_index_o       => main_rom_index,
         rom_wr_o          => main_rom_wr,
         rom_addr_o        => main_rom_addr,
         rom_data_o        => main_rom_data,
         rom_wait_i        => main_rom_wait,
         eth_mac_o         => main_eth_mac,
         eth_mac_valid_o   => main_eth_mac_valid,
         flp_cmd_o         => main_flp_cmd,
         flp_cmd_code_o    => main_flp_cmd_code,
         flp_arg0_o        => main_flp_arg0,
         flp_arg1_o        => main_flp_arg1,
         flp_enable_o      => main_flp_enable,
         flp_chg_clr_o     => main_flp_chg_clr,
         flp_vfy_clr_o     => main_flp_vfy_clr,
         flp_blk_err_o     => main_flp_blk_err,
         flp_busy_i        => main_flp_busy,
         flp_res_i         => main_flp_res,
         flp_live_i        => main_flp_live,
         flp_dbg_i         => main_flp_dbg,
         dbg_a_i           => main_dbg_bus_reads,
         dbg_b_i           => main_dbg_vsync,
         dbg_c_i           => main_dbg_keys,
         dbg_flags_i       => main_dbg_flags
      ); -- i_rom_loader
   --
   -- Use the M2M framework's official RAM/ROM: dualport_2clk_ram
   -- and make sure that the you configure the port that works with QNICE as a falling edge
   -- by setting G_FALLING_A or G_FALLING_B (depending on which port you use) to true.

   ---------------------------------------------------------------------------------------
   -- Virtual drive handler
   --
   -- Only added for demo-purposes at this place, so that we can demonstrate the
   -- firmware's ability to browse files and folders. It is very likely, that the
   -- virtual drive handler needs to be placed somewhere else, for example inside
   -- main.vhd. We advise to delete this before starting to port a core and re-adding
   -- it later (and at the right place), if and when needed.
   ---------------------------------------------------------------------------------------

   -- @TODO:
   -- a) In case that this is handled in main.vhd, you need to add the appropriate ports to i_main
   -- b) You might want to change the drive led's color (just like the C64 core does) as long as
   --    the cache is dirty (i.e. as long as the write process is not finished, yet)
   -- Diagnostics. While a ROM download runs: green = flowing, red = the core
   -- holds rom_wait (loader stuck). Otherwise: red = a storage request is
   -- pending on the mgmt bus (the bridge is serving it, or stuck if solid),
   -- green = a hard disk image is mounted, blue = idle without a hard disk.
   main_drive_led_o     <= '1';
   main_drive_led_col_o <= x"FF0000" when main_rom_download = '1' and main_rom_wait = '1' else
                           x"00FF00" when main_rom_download = '1' else
                           x"FF0000" when main_led_disk = '1' else
                           x"00FF00" when main_drive_mounted(2) = '1' else
                           x"0000FF";

   i_vdrives : entity work.vdrives
      generic map (
         VDNUM       => C_VDNUM
      )
      port map
      (
         clk_qnice_i       => qnice_clk_i,
         clk_core_i        => main_clk,
         -- Mounts survive a core reset: like MiSTer, the PC is reset after mounting
         -- so the BIOS finds the hard disk at POST. (M2M default: reset unmounts.)
         reset_core_i      => '0',

         -- Core clock domain
         img_mounted_o     => main_img_mounted,
         img_readonly_o    => main_img_readonly,
         img_size_o        => main_img_size,
         img_type_o        => open,
         drive_mounted_o   => main_drive_mounted,

         -- Cache output signals: The dirty flags can be used to enforce data consistency
         -- (for example by ignoring/delaying a reset or delaying a drive unmount/mount, etc.)
         -- The flushing flags can be used to signal the fact that the caches are currently
         -- flushing to the user, for example using a special color/signal for example
         -- at the drive led
         cache_dirty_o     => main_cache_dirty,
         cache_flushing_o  => open,

         -- QNICE clock domain
         sd_lba_i          => qnice_sd_lba,
         sd_blk_cnt_i      => qnice_sd_blk_cnt,
         sd_rd_i           => qnice_sd_rd,
         sd_wr_i           => qnice_sd_wr,
         sd_ack_o          => qnice_sd_ack,

         sd_buff_addr_o    => qnice_sd_buff_addr,
         sd_buff_dout_o    => qnice_sd_buff_dout,
         sd_buff_din_i     => qnice_sd_buff_din,
         sd_buff_wr_o      => qnice_sd_buff_wr,

         -- QNICE interface (MMIO, 4k-segmented)
         -- qnice_addr is 28-bit because we have a 16-bit window selector and a 4k window: 65536*4096 = 268.435.456 = 2^28
         qnice_addr_i      => qnice_dev_addr_i,
         qnice_data_i      => qnice_dev_data_i,
         qnice_data_o      => qnice_demo_vd_data_o,
         qnice_ce_i        => qnice_demo_vd_ce,
         qnice_we_i        => qnice_demo_vd_we
      ); -- i_vdrives

end architecture synthesis;

