----------------------------------------------------------------------------------
-- PCXT-EGA on MiSTer2MEGA65
--
-- Wrapper around the core (pcxt_core.sv) plus the MEGA65-side pieces that run
-- in the core's clock domains: the block RAM memory backend behind the
-- KFSDRAM overlay's byte bus, and (later) the keyboard, mouse and the
-- floppy/IDE management bridge.
--
-- Phase 4 state: keyboard via keyboard.vhd (MEGA65 keys -> PS/2 set 2), no
-- mouse, no disks. Joysticks released, OSM choices at their MiSTer defaults.
--
-- MiSTer2MEGA65 done by sy2002 and MJoergen in 2022 and licensed under GPL v3
----------------------------------------------------------------------------------

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

library work;
use work.video_modes_pkg.all;
use work.vdrives_pkg.all;

entity main is
   generic (
      G_VDNUM                 : natural                     -- amount of virtual drives
   );
   port (
      -- Clocks from clk.vhd. clk_main_i is the 50 MHz chipset clock, the
      -- domain of everything the framework exchanges with this entity.
      clk_main_i              : in  std_logic;              -- 50 MHz chipset
      clk_core_i              : in  std_logic;              -- 100 MHz MCL86
      clk_video_base_i        : in  std_logic;              -- 28.636 MHz
      clk_video_x2_i          : in  std_logic;              -- 57.273 MHz
      clk_video_out_ps_i      : in  std_logic;              -- 57.273 MHz +90 deg: domain of video_*_o
      clk_video_vga_i         : in  std_logic;              -- 25.2 MHz
      clk_14_318_i            : in  std_logic;              -- 14.318 MHz
      clk_locked_i            : in  std_logic;              -- both MMCMs locked

      reset_soft_i            : in  std_logic;              -- warm: OSM / reset button, ROMs survive
      reset_hard_i            : in  std_logic;              -- cold: whole machine, ROMs are re-streamed
      pause_i                 : in  std_logic;

      -- MiSTer core main clock speed:
      -- Make sure you pass very exact numbers here, because they are used for avoiding clock drift at derived clocks
      clk_main_speed_i        : in  natural;

      -- Video output, clk_video_out_ps_i domain
      video_ce_o              : out std_logic;
      video_mode13_o          : out std_logic;              -- private 31.5 kHz raster active (clk_card_video, async)
      video_red_o             : out std_logic_vector(7 downto 0);
      video_green_o           : out std_logic_vector(7 downto 0);
      video_blue_o            : out std_logic_vector(7 downto 0);
      video_vs_o              : out std_logic;
      video_hs_o              : out std_logic;
      video_hblank_o          : out std_logic;
      video_vblank_o          : out std_logic;

      -- Audio output (Signed PCM), clk_main_i domain
      audio_left_o            : out signed(15 downto 0);
      audio_right_o           : out signed(15 downto 0);

      -- BIOS ROM download stream from rom_loader.vhd (clk_main_i domain)
      rom_download_i          : in  std_logic;
      rom_index_i             : in  std_logic_vector(7 downto 0);
      rom_wr_i                : in  std_logic;
      rom_addr_i              : in  std_logic_vector(24 downto 0);
      rom_data_i              : in  std_logic_vector(15 downto 0);
      rom_wait_o              : out std_logic;

      -- Status for the OSM / LEDs
      bios_missing_pcxt_o     : out std_logic;
      bios_missing_ega_o      : out std_logic;
      splash_active_o         : out std_logic;
      led_disk_o              : out std_logic;

      -- Debug counters for the firmware log (rom_loader readback 6/7, m2m-rom.asm DBG_CORE_STATUS)
      dbg_bus_reads_o         : out std_logic_vector(15 downto 0);   -- reads in F0000-FFFFF (BIOS fetches)
      dbg_vsync_o             : out std_logic_vector(15 downto 0);   -- pixel enables per frame / 64
      dbg_keys_o              : out std_logic_vector(15 downto 0);   -- last read address, bits 21..6
      dbg_flags_o             : out std_logic_vector(7 downto 0);    -- hold/pause state, see p_dbg

      -- On-Screen-Menu selections (clk_main_i domain)
      osm_control_i           : in  std_logic_vector(255 downto 0);

      -- Virtual drives (framework vdrives): 0 = floppy A, 1 = floppy B, 2 = hard disk.
      -- img_* and drive_mounted_i are in the clk_main_i domain, sd_* in the QNICE domain.
      clk_qnice_i             : in  std_logic;

      -- HyperRAM (framework hr_core_* Avalon master, hr_clk_i domain): conventional RAM, UMB, EMS
      hr_clk_i                : in  std_logic;
      hr_rst_i                : in  std_logic;
      hr_write_o              : out std_logic;
      hr_read_o               : out std_logic;
      hr_address_o            : out std_logic_vector(31 downto 0);
      hr_writedata_o          : out std_logic_vector(15 downto 0);
      hr_byteenable_o         : out std_logic_vector(1 downto 0);
      hr_burstcount_o         : out std_logic_vector(7 downto 0);
      hr_readdata_i           : in  std_logic_vector(15 downto 0);
      hr_readdatavalid_i      : in  std_logic;
      hr_waitrequest_i        : in  std_logic;
      img_mounted_i           : in  std_logic_vector(2 downto 0);
      img_readonly_i          : in  std_logic;
      img_size_i              : in  std_logic_vector(31 downto 0);
      drive_mounted_i         : in  std_logic_vector(2 downto 0);
      sd_lba_o                : out vd_vec_array(2 downto 0)(31 downto 0);
      sd_blk_cnt_o            : out vd_vec_array(2 downto 0)(5 downto 0);
      sd_rd_o                 : out vd_std_array(2 downto 0);
      sd_wr_o                 : out vd_std_array(2 downto 0);
      sd_ack_i                : in  vd_std_array(2 downto 0);
      sd_buff_addr_i          : in  std_logic_vector(AW downto 0);
      sd_buff_dout_i          : in  std_logic_vector(DW downto 0);
      sd_buff_din_o           : out vd_vec_array(2 downto 0)(DW downto 0);
      sd_buff_wr_i            : in  std_logic;

      -- M2M Keyboard interface
      kb_key_num_i            : in  integer range 0 to 79;    -- cycles through all MEGA65 keys
      kb_key_pressed_n_i      : in  std_logic;                -- low active: debounced feedback: is kb_key_num_i pressed right now?

      -- MEGA65 joysticks and paddles/mouse/potentiometers
      joy_1_up_n_i            : in  std_logic;
      joy_1_down_n_i          : in  std_logic;
      joy_1_left_n_i          : in  std_logic;
      joy_1_right_n_i         : in  std_logic;
      joy_1_fire_n_i          : in  std_logic;

      joy_2_up_n_i            : in  std_logic;
      joy_2_down_n_i          : in  std_logic;
      joy_2_left_n_i          : in  std_logic;
      joy_2_right_n_i         : in  std_logic;
      joy_2_fire_n_i          : in  std_logic;

      pot1_x_i                : in  std_logic_vector(7 downto 0);
      pot1_y_i                : in  std_logic_vector(7 downto 0);
      pot2_x_i                : in  std_logic_vector(7 downto 0);
      pot2_y_i                : in  std_logic_vector(7 downto 0)
   );
end entity main;

architecture synthesis of main is

   -- The SystemVerilog wrapper (CORE/rtl/pcxt_core.sv), flat ports only
   component pcxt_core is
      port (
         clk_core_i                : in  std_logic;
         clk_chipset_i             : in  std_logic;
         clk_video_base_i          : in  std_logic;
         clk_video_x2_i            : in  std_logic;
         clk_video_out_ps_i        : in  std_logic;
         clk_video_vga_i           : in  std_logic;
         clk_14_318_i              : in  std_logic;
         pll_locked_i              : in  std_logic;
         reset_i                   : in  std_logic;
         reset_osd_i               : in  std_logic;
         reset_button_i            : in  std_logic;
         video_clk_o               : out std_logic;
         video_ce_o                : out std_logic;
         video_red_o               : out std_logic_vector(7 downto 0);
         video_green_o             : out std_logic_vector(7 downto 0);
         video_blue_o              : out std_logic_vector(7 downto 0);
         video_hs_o                : out std_logic;
         video_vs_o                : out std_logic;
         video_hblank_o            : out std_logic;
         video_vblank_o            : out std_logic;
         video_de_o                : out std_logic;
         video_mode13_o            : out std_logic;
         video_mode13_native_clk_o : out std_logic;
         video_mode350_o           : out std_logic;
         video_active_dots_o       : out std_logic_vector(11 downto 0);
         video_active_lines_o      : out std_logic_vector(9 downto 0);
         video_aspect_o            : out std_logic_vector(1 downto 0);
         video_scanlines_o         : out std_logic_vector(1 downto 0);
         audio_left_o              : out std_logic_vector(15 downto 0);
         audio_right_o             : out std_logic_vector(15 downto 0);
         audio_mix_o               : out std_logic_vector(1 downto 0);
         ps2_kbd_clk_i             : in  std_logic;
         ps2_kbd_data_i            : in  std_logic;
         ps2_kbd_clk_o             : out std_logic;
         ps2_kbd_data_o            : out std_logic;
         ps2_key_i                 : in  std_logic_vector(10 downto 0);
         ps2_mouse_clk_i           : in  std_logic;
         ps2_mouse_data_i          : in  std_logic;
         ps2_mouse_clk_o           : out std_logic;
         ps2_mouse_data_o          : out std_logic;
         joy0_i                    : in  std_logic_vector(13 downto 0);
         joy1_i                    : in  std_logic_vector(13 downto 0);
         joya0_i                   : in  std_logic_vector(15 downto 0);
         joya1_i                   : in  std_logic_vector(15 downto 0);
         osm_cpu_speed_i           : in  std_logic_vector(1 downto 0);
         osm_cpu_8086_i            : in  std_logic;
         osm_fake286_i             : in  std_logic;
         osm_splash_off_i          : in  std_logic;
         osm_bios_writable_i       : in  std_logic_vector(1 downto 0);
         osm_audio220_i            : in  std_logic_vector(1 downto 0);
         osm_opl2_i                : in  std_logic_vector(1 downto 0);
         osm_tandy_i               : in  std_logic;
         osm_speaker_vol_i         : in  std_logic_vector(1 downto 0);
         osm_audio_boost_i         : in  std_logic_vector(1 downto 0);
         osm_stereo_mix_i          : in  std_logic_vector(1 downto 0);
         osm_crt_h_i               : in  std_logic_vector(3 downto 0);
         osm_crt_v_i               : in  std_logic_vector(2 downto 0);
         osm_vsync_w_i             : in  std_logic_vector(2 downto 0);
         osm_hsync_w_i             : in  std_logic_vector(2 downto 0);
         osm_scandoubler_fx_i      : in  std_logic_vector(1 downto 0);
         osm_aspect_i              : in  std_logic_vector(1 downto 0);
         osm_display_i             : in  std_logic_vector(2 downto 0);
         osm_vga13_tv_i            : in  std_logic;
         osm_monitor_i             : in  std_logic_vector(1 downto 0);
         osm_ems_disable_i         : in  std_logic;
         osm_umb_disable_i         : in  std_logic;
         osm_joy1_i                : in  std_logic_vector(1 downto 0);
         osm_joy2_i                : in  std_logic_vector(1 downto 0);
         osm_joy_sync_i            : in  std_logic;
         osm_joy_swap_i            : in  std_logic;
         osm_sb_irq7_i             : in  std_logic;
         osm_mpu401_disable_i      : in  std_logic;
         osm_floppy_wp_i           : in  std_logic_vector(1 downto 0);
         bios_missing_pcxt_o       : out std_logic;
         bios_missing_ega_o        : out std_logic;
         reset_pending_o           : out std_logic;
         pause_o                   : out std_logic;
         splash_active_o           : out std_logic;
         rom_download_i            : in  std_logic;
         rom_index_i               : in  std_logic_vector(7 downto 0);
         rom_wr_i                  : in  std_logic;
         rom_addr_i                : in  std_logic_vector(24 downto 0);
         rom_data_i                : in  std_logic_vector(15 downto 0);
         rom_wait_o                : out std_logic;
         sdram_a_o                 : out std_logic_vector(12 downto 0);
         sdram_ba_o                : out std_logic_vector(1 downto 0);
         sdram_cke_o               : out std_logic;
         sdram_ncs_o               : out std_logic;
         sdram_nras_o              : out std_logic;
         sdram_ncas_o              : out std_logic;
         sdram_nwe_o               : out std_logic;
         sdram_dq_out_o            : out std_logic_vector(15 downto 0);
         sdram_dq_io_o             : out std_logic;
         sdram_dq_in_i             : in  std_logic_vector(15 downto 0);
         sdram_dqml_o              : out std_logic;
         sdram_dqmh_o              : out std_logic;
         sdram_initialized_o       : out std_logic;
         mgmt_addr_i               : in  std_logic_vector(15 downto 0);
         mgmt_dout_i               : in  std_logic_vector(15 downto 0);
         mgmt_din_o                : out std_logic_vector(15 downto 0);
         mgmt_wr_i                 : in  std_logic;
         mgmt_rd_i                 : in  std_logic;
         mgmt_req_o                : out std_logic_vector(7 downto 0);
         fdd_present_o             : out std_logic_vector(1 downto 0);
         led_disk_o                : out std_logic;
         dbg_de_o                  : out std_logic;
         dbg_hb_o                  : out std_logic;
         dbg_vb_o                  : out std_logic
      );
   end component pcxt_core;

   -- core outputs
   signal core_video_de       : std_logic;
   signal core_video_hblank   : std_logic;
   signal core_video_vblank   : std_logic;
   signal core_audio_left     : std_logic_vector(15 downto 0);
   signal osm_opl2, osm_speaker, osm_boost, osm_monitor, osm_joy1, osm_joy2, osm_floppy_wp : std_logic_vector(1 downto 0);
   signal osm_display         : std_logic_vector(2 downto 0);
   signal osm_vga13_tv        : std_logic;
   signal joy0_vec, joy1_vec  : std_logic_vector(13 downto 0);
   signal core_audio_right    : std_logic_vector(15 downto 0);

   -- the byte bus that the KFSDRAM overlay carries on the SDRAM pins
   -- (mapping documented in CORE/rtl/overlay/KFSDRAM.sv)
   signal sdram_a             : std_logic_vector(12 downto 0);
   signal sdram_ba            : std_logic_vector(1 downto 0);
   signal sdram_nras          : std_logic;
   signal sdram_nwe           : std_logic;
   signal sdram_dq_out        : std_logic_vector(15 downto 0);
   signal sdram_dq_in         : std_logic_vector(15 downto 0);

   signal avm_address         : std_logic_vector(21 downto 0);
   signal avm_writedata       : std_logic_vector(7 downto 0);
   signal avm_read            : std_logic;
   signal avm_write           : std_logic;
   signal avm_readdata        : std_logic_vector(7 downto 0);
   signal avm_readdatavalid   : std_logic;
   signal avm_waitrequest     : std_logic;

   signal reset_cold          : std_logic;

   -- the SystemVerilog storage bridge (CORE/rtl/mgmt_bridge.sv)
   component mgmt_bridge is
      port (
         clk             : in  std_logic;
         reset           : in  std_logic;
         mgmt_addr       : out std_logic_vector(15 downto 0);
         mgmt_dout       : out std_logic_vector(15 downto 0);
         mgmt_din        : in  std_logic_vector(15 downto 0);
         mgmt_wr         : out std_logic;
         mgmt_rd         : out std_logic;
         mgmt_req        : in  std_logic_vector(7 downto 0);
         img_mounted     : in  std_logic_vector(2 downto 0);
         img_size        : in  std_logic_vector(31 downto 0);
         img_readonly    : in  std_logic;
         drive_mounted   : in  std_logic_vector(2 downto 0);
         blk_rd          : out std_logic_vector(2 downto 0);
         blk_wr          : out std_logic_vector(2 downto 0);
         blk_lba         : out std_logic_vector(31 downto 0);
         blk_ack         : in  std_logic_vector(2 downto 0);
         buf_addr        : out std_logic_vector(8 downto 0);
         buf_wdata       : out std_logic_vector(7 downto 0);
         buf_we          : out std_logic;
         buf_rdata       : in  std_logic_vector(7 downto 0)
      );
   end component mgmt_bridge;

   -- keyboard: emulated PS/2 device
   signal ps2_kbd_clk         : std_logic;
   signal ps2_kbd_data        : std_logic;
   signal ps2_host_clk        : std_logic;
   signal ps2_host_data       : std_logic;
   signal ps2_key             : std_logic_vector(10 downto 0);

   -- OSM decode
   signal osm_cpu_speed       : std_logic_vector(1 downto 0);

   -- debug counters
   signal core_video_vs       : std_logic;
   signal dbg_bus_reads       : unsigned(15 downto 0) := (others => '0');
   signal dbg_vsync           : unsigned(15 downto 0) := (others => '0');
   signal vs_sync             : std_logic_vector(2 downto 0) := (others => '0');
   signal dbg_keys            : unsigned(15 downto 0) := (others => '0');
   signal core_video_ce       : std_logic;
   signal raw_de, raw_hb, raw_vb : std_logic;
   signal de_cnt, hb_cnt, vb_cnt : unsigned(21 downto 0) := (others => '0');
   signal de_per_frame, hb_per_frame, vb_per_frame : std_logic_vector(15 downto 0) := (others => '0');
   signal vs_q2               : std_logic := '0';
   signal c_writes            : unsigned(15 downto 0) := (others => '0');
   signal f_writes            : unsigned(17 downto 0) := (others => '0');
   signal c_reads             : unsigned(17 downto 0) := (others => '0');
   signal dbg_hrd, dbg_hrv, dbg_hwr : std_logic_vector(15 downto 0);
   signal mreq7_q, mreq6_q, blkwr_q, blkack_q : std_logic := '0';
   signal wr_req_cnt, rd_req_cnt, blk_wr_cnt, blk_ack_cnt : unsigned(7 downto 0) := (others => '0');
   signal ce_cnt              : unsigned(21 downto 0) := (others => '0');
   signal ce_per_frame        : std_logic_vector(15 downto 0) := (others => '0');
   signal vs_q                : std_logic := '0';
   signal key_toggle_q        : std_logic := '0';
   signal core_bm_pcxt        : std_logic;
   signal core_bm_ega         : std_logic;
   signal core_splash         : std_logic;
   signal splash_sync         : std_logic_vector(1 downto 0) := "00";   -- clk_14 -> clk_main
   signal core_pause          : std_logic;
   signal core_sdram_init     : std_logic;

   -- storage bridge <-> vd_glue (clk_main_i domain)
   signal mgmt_addr           : std_logic_vector(15 downto 0);
   signal mgmt_dout           : std_logic_vector(15 downto 0);
   signal mgmt_din            : std_logic_vector(15 downto 0);
   signal mgmt_wr             : std_logic;
   signal mgmt_rd             : std_logic;
   signal mgmt_req            : std_logic_vector(7 downto 0);
   signal blk_rd              : std_logic_vector(2 downto 0);
   signal blk_wr              : std_logic_vector(2 downto 0);
   signal blk_lba             : std_logic_vector(31 downto 0);
   signal blk_ack             : std_logic_vector(2 downto 0);
   signal buf_addr            : std_logic_vector(8 downto 0);
   signal buf_wdata           : std_logic_vector(7 downto 0);
   signal buf_we              : std_logic;
   signal buf_rdata           : std_logic_vector(7 downto 0);

begin

   -- Options menu decode (bit numbers = line numbers in config.vhd OPTM_ITEMS)
   -- CPU speed: lines 9..12 (4.77 / 7.16 / 9.54 / Max), status[18:17]
   osm_cpu_speed <= "11" when osm_control_i(12) = '1' else
                    "10" when osm_control_i(11) = '1' else
                    "01" when osm_control_i(10) = '1' else
                    "00";
   -- FM synth: lines 33..35 (Adlib / Sound Blaster FM / none), status[43:42]
   osm_opl2      <= "10" when osm_control_i(35) = '1' else
                    "01" when osm_control_i(34) = '1' else
                    "00";
   -- Speaker volume: lines 40..43, status[33:32]
   osm_speaker   <= "11" when osm_control_i(43) = '1' else
                    "10" when osm_control_i(42) = '1' else
                    "01" when osm_control_i(41) = '1' else
                    "00";
   -- Audio boost: lines 45..47 (none / 2x / 4x), status[37:36]
   osm_boost     <= "10" when osm_control_i(47) = '1' else
                    "01" when osm_control_i(46) = '1' else
                    "00";
   -- Monitor: lines 53..55 (5154 / 5153 / 5151), status[45:44], applied at reset
   osm_monitor   <= "10" when osm_control_i(55) = '1' else
                    "01" when osm_control_i(54) = '1' else
                    "00";
   -- Tint: lines 57..60 (full color / green / amber / b&w), status[16:14]
   osm_display   <= "011" when osm_control_i(60) = '1' else
                    "010" when osm_control_i(59) = '1' else
                    "001" when osm_control_i(58) = '1' else
                    "000";
   -- Joysticks: lines 70/71 toggles. The MEGA65 sticks are digital, so "on"
   -- selects the core's digital mode ([0]) and "off" disables the port ([1]).
   osm_joy1      <= "01" when osm_control_i(70) = '1' else "10";
   osm_joy2      <= "01" when osm_control_i(71) = '1' else "10";
   -- Floppy write protect: lines 70 (A:) and 71 (B:), status[20:19] = {B, A}
   osm_floppy_wp <= osm_control_i(75) & osm_control_i(74);
   -- VGA: lines 62..64 (31 kHz / 15 kHz / 15 kHz + csync). The 15 kHz items also
   -- select the core's 60 Hz TV raster for mode 13h (status[10]); the analog
   -- pipeline controls live in mega65.vhd (analog_video_ctl).
   osm_vga13_tv  <= osm_control_i(63) or osm_control_i(64);

   -- MEGA65 joystick ports -> game port: [0] right [1] left [2] down [3] up [4] fire
   joy0_vec <= "000000000" & (not joy_1_fire_n_i) & (not joy_1_up_n_i) & (not joy_1_down_n_i)
                           & (not joy_1_left_n_i) & (not joy_1_right_n_i);
   joy1_vec <= "000000000" & (not joy_2_fire_n_i) & (not joy_2_up_n_i) & (not joy_2_down_n_i)
                           & (not joy_2_left_n_i) & (not joy_2_right_n_i);

   -- Cold reset re-streams the ROMs (see the reset tree in docs/emu-signal-map.md).
   -- Only a lost clock lock counts. reset_hard_i cannot be used: the framework's
   -- top level ORs the firmware's CSR reset into it, and the firmware holds that
   -- reset while it streams the ROMs, which must land while the core is only
   -- warm-reset (reset_soft_i). A whole-machine reset restarts the firmware,
   -- which re-streams the ROMs anyway.
   reset_cold <= not clk_locked_i;

   i_pcxt_core : pcxt_core
      port map (
         clk_core_i                => clk_core_i,
         clk_chipset_i             => clk_main_i,
         clk_video_base_i          => clk_video_base_i,
         clk_video_x2_i            => clk_video_x2_i,
         clk_video_out_ps_i        => clk_video_out_ps_i,
         clk_video_vga_i           => clk_video_vga_i,
         clk_14_318_i              => clk_14_318_i,
         pll_locked_i              => clk_locked_i,
         reset_i                   => reset_cold,
         reset_osd_i               => reset_soft_i,
         reset_button_i            => '0',

         video_clk_o               => open,                 -- = clk_video_out_ps_i
         video_ce_o                => core_video_ce,
         video_red_o               => video_red_o,
         video_green_o             => video_green_o,
         video_blue_o              => video_blue_o,
         video_hs_o                => video_hs_o,
         video_vs_o                => core_video_vs,
         video_hblank_o            => core_video_hblank,
         video_vblank_o            => core_video_vblank,
         video_de_o                => core_video_de,
         video_mode13_o            => video_mode13_o,
         video_mode13_native_clk_o => open,
         video_mode350_o           => open,
         video_active_dots_o       => open,
         video_active_lines_o      => open,
         video_aspect_o            => open,
         video_scanlines_o         => open,

         audio_left_o              => core_audio_left,
         audio_right_o             => core_audio_right,
         audio_mix_o               => open,

         -- keyboard: PS/2 device emulated from the MEGA65 keys (keyboard.vhd)
         ps2_kbd_clk_i             => ps2_kbd_clk,
         ps2_kbd_data_i            => ps2_kbd_data,
         ps2_kbd_clk_o             => ps2_host_clk,
         ps2_kbd_data_o            => ps2_host_data,
         ps2_key_i                 => ps2_key,
         ps2_mouse_clk_i           => '1',
         ps2_mouse_data_i          => '1',
         ps2_mouse_clk_o           => open,
         ps2_mouse_data_o          => open,
         joy0_i                    => joy0_vec,
         joy1_i                    => joy1_vec,
         joya0_i                   => (others => '0'),
         joya1_i                   => (others => '0'),

         -- OSM: MiSTer defaults (all status bits zero) until config.vhd grows the menu
         osm_cpu_speed_i           => osm_cpu_speed,
         osm_cpu_8086_i            => osm_control_i(14),
         osm_fake286_i             => osm_control_i(15),
         osm_splash_off_i          => '0',
         osm_bios_writable_i       => "00",
         osm_audio220_i            => "00",
         osm_opl2_i                => osm_opl2,
         osm_tandy_i               => osm_control_i(37),
         osm_speaker_vol_i         => osm_speaker,
         osm_audio_boost_i         => osm_boost,
         osm_stereo_mix_i          => "00",
         osm_crt_h_i               => "0000",
         osm_crt_v_i               => "000",
         osm_vsync_w_i             => "000",
         osm_hsync_w_i             => "000",
         osm_scandoubler_fx_i      => "00",
         osm_aspect_i              => "00",
         osm_display_i             => osm_display,
         osm_vga13_tv_i            => osm_vga13_tv,
         osm_monitor_i             => osm_monitor,
         osm_ems_disable_i         => '0',                  -- 2 MB EMS, page frame D000, pages in HyperRAM
         osm_umb_disable_i         => '0',                  -- UMB C4000-CFFFF (HyperRAM)
         osm_joy1_i                => osm_joy1,
         osm_joy2_i                => osm_joy2,
         osm_joy_sync_i            => '0',
         osm_joy_swap_i            => osm_control_i(72),
         osm_sb_irq7_i             => osm_control_i(38),
         osm_mpu401_disable_i      => '1',                  -- nothing behind the MPU-401
         osm_floppy_wp_i           => osm_floppy_wp,

         bios_missing_pcxt_o       => core_bm_pcxt,
         bios_missing_ega_o        => core_bm_ega,
         reset_pending_o           => open,
         pause_o                   => core_pause,
         splash_active_o           => core_splash,

         rom_download_i            => rom_download_i,
         rom_index_i               => rom_index_i,
         rom_wr_i                  => rom_wr_i,
         rom_addr_i                => rom_addr_i,
         rom_data_i                => rom_data_i,
         rom_wait_o                => rom_wait_o,

         sdram_a_o                 => sdram_a,
         sdram_ba_o                => sdram_ba,
         sdram_cke_o               => open,
         sdram_ncs_o               => open,
         sdram_nras_o              => sdram_nras,
         sdram_ncas_o              => open,
         sdram_nwe_o               => sdram_nwe,
         sdram_dq_out_o            => sdram_dq_out,
         sdram_dq_io_o             => open,
         sdram_dq_in_i             => sdram_dq_in,
         sdram_dqml_o              => open,
         sdram_dqmh_o              => open,
         sdram_initialized_o       => core_sdram_init,

         -- floppy/IDE storage bridge (Phase 5)
         mgmt_addr_i               => mgmt_addr,
         mgmt_dout_i               => mgmt_dout,
         mgmt_din_o                => mgmt_din,
         mgmt_wr_i                 => mgmt_wr,
         mgmt_rd_i                 => mgmt_rd,
         mgmt_req_o                => mgmt_req,
         fdd_present_o             => open,
         led_disk_o                => led_disk_o,
         dbg_de_o                  => raw_de,
         dbg_hb_o                  => raw_hb,
         dbg_vb_o                  => raw_vb
      ); -- i_pcxt_core

   ---------------------------------------------------------------------------
   -- Storage: floppy A/B and the hard disk are images on the SD card, served
   -- by the framework (vdrives). mgmt_bridge plays the MiSTer ARM against the
   -- core's mgmt bus, vd_glue crosses into the QNICE domain and owns the
   -- 512-byte block buffer.
   ---------------------------------------------------------------------------

   i_mgmt_bridge : mgmt_bridge
      port map (
         clk             => clk_main_i,
         reset           => reset_cold,
         mgmt_addr       => mgmt_addr,
         mgmt_dout       => mgmt_dout,
         mgmt_din        => mgmt_din,
         mgmt_wr         => mgmt_wr,
         mgmt_rd         => mgmt_rd,
         mgmt_req        => mgmt_req,
         img_mounted     => img_mounted_i,
         img_size        => img_size_i,
         img_readonly    => img_readonly_i,
         drive_mounted   => drive_mounted_i,
         blk_rd          => blk_rd,
         blk_wr          => blk_wr,
         blk_lba         => blk_lba,
         blk_ack         => blk_ack,
         buf_addr        => buf_addr,
         buf_wdata       => buf_wdata,
         buf_we          => buf_we,
         buf_rdata       => buf_rdata
      ); -- i_mgmt_bridge

   i_vd_glue : entity work.vd_glue
      generic map (
         G_VDNUM        => 3
      )
      port map (
         core_clk_i     => clk_main_i,
         core_rst_i     => reset_cold,
         blk_rd_i       => blk_rd,
         blk_wr_i       => blk_wr,
         blk_lba_i      => blk_lba,
         blk_ack_o      => blk_ack,
         buf_addr_i     => buf_addr,
         buf_wdata_i    => buf_wdata,
         buf_we_i       => buf_we,
         buf_rdata_o    => buf_rdata,
         qnice_clk_i    => clk_qnice_i,
         sd_lba_o       => sd_lba_o,
         sd_blk_cnt_o   => sd_blk_cnt_o,
         sd_rd_o        => sd_rd_o,
         sd_wr_o        => sd_wr_o,
         sd_ack_i       => sd_ack_i,
         sd_buff_addr_i => sd_buff_addr_i,
         sd_buff_dout_i => sd_buff_dout_i,
         sd_buff_din_o  => sd_buff_din_o,
         sd_buff_wr_i   => sd_buff_wr_i
      ); -- i_vd_glue

   video_vs_o <= core_video_vs;

   -- Debug counters: chipset-bus reads (is the CPU/DMA alive?) and vsyncs
   -- (is the EGA producing frames?). Read asynchronously by the firmware.
   p_dbg : process (clk_main_i)
   begin
      if rising_edge(clk_main_i) then
         if avm_read = '1' and avm_address(21 downto 16) = "001111" then   -- F0000-FFFFF
            dbg_bus_reads <= dbg_bus_reads + 1;
         end if;
         if avm_read = '1' then
            dbg_keys <= unsigned(avm_address(21 downto 6));
         end if;
         vs_sync <= vs_sync(1 downto 0) & core_video_vs;
         splash_sync <= splash_sync(0) & core_splash;
         if vs_sync(1) = '1' and vs_sync(2) = '0' then
            dbg_vsync <= dbg_vsync + 1;
         end if;
      end if;
   end process;
   -- Status line (rom_loader regs 6/7/8, printed by the firmware at start and on every OSM selection)
   dbg_bus_reads_o <= dbg_hrd;                                                       -- bist= : HyperRAM self test {done, mismatches}
   dbg_vsync_o     <= std_logic_vector(wr_req_cnt) & std_logic_vector(rd_req_cnt);  -- req=  : {FDD write requests, FDD read requests}
   dbg_keys_o      <= std_logic_vector(blk_ack_cnt) & std_logic_vector(blk_wr_cnt); -- blk=  : {block acks, block writes} for drive A

   p_dbg_wr : process (clk_main_i)
   begin
      if rising_edge(clk_main_i) then
         mreq7_q <= mgmt_req(7); mreq6_q <= mgmt_req(6);
         blkwr_q <= blk_wr(0);   blkack_q <= blk_ack(0);
         if mgmt_req(7) = '1' and mreq7_q = '0' then wr_req_cnt <= wr_req_cnt + 1; end if;
         if mgmt_req(6) = '1' and mreq6_q = '0' then rd_req_cnt <= rd_req_cnt + 1; end if;
         if blk_wr(0)   = '1' and blkwr_q = '0' then blk_wr_cnt <= blk_wr_cnt + 1; end if;
         if blk_ack(0)  = '1' and blkack_q = '0' then blk_ack_cnt <= blk_ack_cnt + 1; end if;
      end if;
   end process;

   p_dbg_mem : process (clk_main_i)
   begin
      if rising_edge(clk_main_i) then
         if avm_write = '1' and avm_address(21 downto 16) = "001100" and c_writes /= x"FFFF" then
            c_writes <= c_writes + 1;
         end if;
         if avm_write = '1' and avm_address(21 downto 16) = "001111" and f_writes /= (f_writes'range => '1') then
            f_writes <= f_writes + 1;
         end if;
         if avm_read = '1' and avm_address(21 downto 16) = "001100" and c_reads /= (c_reads'range => '1') then
            c_reads <= c_reads + 1;
         end if;
      end if;
   end process;
   dbg_flags_o     <= '0' & reset_soft_i & reset_cold & core_sdram_init & core_pause & splash_sync(1) & core_bm_ega & core_bm_pcxt;

   bios_missing_pcxt_o <= core_bm_pcxt;
   bios_missing_ega_o  <= core_bm_ega;
   splash_active_o     <= core_splash;

   video_ce_o <= core_video_ce;

   -- pixel enables per frame, in the domain of the core's video outputs
   p_dbg_ce : process (clk_video_out_ps_i)
   begin
      if rising_edge(clk_video_out_ps_i) then
         vs_q <= core_video_vs;
         if core_video_vs = '1' and vs_q = '0' then
            ce_per_frame <= std_logic_vector(ce_cnt(21 downto 6));
            ce_cnt <= (others => '0');
         elsif core_video_ce = '1' then
            ce_cnt <= ce_cnt + 1;
         end if;
      end if;
   end process;

   -- Blanking for the framework: video_de_o is aligned with the RGB output,
   -- the core's own blank outputs lead it by a few pixels (see the wrapper
   -- notes), so derive the horizontal blank from DE.
   video_hblank_o <= not core_video_de;
   video_vblank_o <= core_video_vblank;

   -- video_ce_ovl is produced by analog_video_ctl in mega65.vhd (2x pixel enable).

   ---------------------------------------------------------------------------
   -- Keyboard
   ---------------------------------------------------------------------------

   i_keyboard : entity work.keyboard
      port map (
         clk_main_i      => clk_main_i,
         rst_i           => reset_cold,
         key_num_i       => kb_key_num_i,
         key_pressed_n_i => kb_key_pressed_n_i,
         ps2_host_clk_i  => ps2_host_clk,
         ps2_host_data_i => ps2_host_data,
         ps2_clk_o       => ps2_kbd_clk,
         ps2_data_o      => ps2_kbd_data,
         ps2_key_o       => ps2_key
      ); -- i_keyboard

   audio_left_o  <= signed(core_audio_left);
   audio_right_o <= signed(core_audio_right);

   ---------------------------------------------------------------------------
   -- Memory backend behind the KFSDRAM overlay's byte bus
   ---------------------------------------------------------------------------

   avm_address    <= sdram_dq_out(15 downto 9) & sdram_ba & sdram_a;
   avm_writedata  <= sdram_dq_out(7 downto 0);
   avm_read       <= not sdram_nras;
   avm_write      <= not sdram_nwe;
   sdram_dq_in    <= "000000" & avm_readdatavalid & avm_waitrequest & avm_readdata;

   i_mem : entity work.mem_backend
      generic map (
         G_CACHE => false            -- the framework avm_cache returned more responses than reads on hardware
      )
      port map (
         clk_i               => clk_main_i,
         rst_i               => reset_cold,
         avm_address_i       => avm_address,
         avm_writedata_i     => avm_writedata,
         avm_write_i         => avm_write,
         avm_read_i          => avm_read,
         avm_readdata_o      => avm_readdata,
         avm_readdatavalid_o => avm_readdatavalid,
         avm_waitrequest_o   => avm_waitrequest,
         rom_wr_i            => rom_wr_i,
         rom_index_i         => rom_index_i,
         rom_addr_i          => rom_addr_i,
         rom_data_i          => rom_data_i,
         hr_clk_i            => hr_clk_i,
         hr_rst_i            => hr_rst_i,
         hr_write_o          => hr_write_o,
         hr_read_o           => hr_read_o,
         hr_address_o        => hr_address_o,
         hr_writedata_o      => hr_writedata_o,
         hr_byteenable_o     => hr_byteenable_o,
         hr_burstcount_o     => hr_burstcount_o,
         hr_readdata_i       => hr_readdata_i,
         hr_readdatavalid_i  => hr_readdatavalid_i,
         hr_waitrequest_i    => hr_waitrequest_i,
         dbg_hrd_o           => dbg_hrd,
         dbg_hrv_o           => dbg_hrv,
         dbg_hwr_o           => dbg_hwr
      ); -- i_mem

end architecture synthesis;
