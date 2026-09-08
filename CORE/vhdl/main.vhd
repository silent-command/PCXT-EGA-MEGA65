----------------------------------------------------------------------------------
-- PCXT-EGA on MiSTer2MEGA65
--
-- Wrapper around the core (pcxt_core.sv) plus the MEGA65-side pieces that run
-- in the core's clock domains: the block RAM memory backend behind the
-- KFSDRAM overlay's byte bus, and (later) the keyboard, mouse and the
-- floppy/IDE management bridge.
--
-- Phase 3 state: no keyboard, no mouse, no disks. PS/2 lines idle, joysticks
-- released, OSM choices at their MiSTer defaults. Goal: splash and BIOS POST
-- on HDMI.
--
-- MiSTer2MEGA65 done by sy2002 and MJoergen in 2022 and licensed under GPL v3
----------------------------------------------------------------------------------

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

library work;
use work.video_modes_pkg.all;

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
      video_ce_ovl_o          : out std_logic;
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

      -- On-Screen-Menu selections (clk_main_i domain)
      osm_control_i           : in  std_logic_vector(255 downto 0);

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
         led_disk_o                : out std_logic
      );
   end component pcxt_core;

   -- core outputs
   signal core_video_de       : std_logic;
   signal core_video_hblank   : std_logic;
   signal core_video_vblank   : std_logic;
   signal core_audio_left     : std_logic_vector(15 downto 0);
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

begin

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
         video_ce_o                => video_ce_o,
         video_red_o               => video_red_o,
         video_green_o             => video_green_o,
         video_blue_o              => video_blue_o,
         video_hs_o                => video_hs_o,
         video_vs_o                => video_vs_o,
         video_hblank_o            => core_video_hblank,
         video_vblank_o            => core_video_vblank,
         video_de_o                => core_video_de,
         video_mode13_o            => open,
         video_mode13_native_clk_o => open,
         video_mode350_o           => open,
         video_active_dots_o       => open,
         video_active_lines_o      => open,
         video_aspect_o            => open,
         video_scanlines_o         => open,

         audio_left_o              => core_audio_left,
         audio_right_o             => core_audio_right,
         audio_mix_o               => open,

         -- Phase 3: no keyboard or mouse yet, PS/2 lines idle high
         ps2_kbd_clk_i             => '1',
         ps2_kbd_data_i            => '1',
         ps2_kbd_clk_o             => open,
         ps2_kbd_data_o            => open,
         ps2_key_i                 => (others => '0'),
         ps2_mouse_clk_i           => '1',
         ps2_mouse_data_i          => '1',
         ps2_mouse_clk_o           => open,
         ps2_mouse_data_o          => open,
         joy0_i                    => (others => '0'),
         joy1_i                    => (others => '0'),
         joya0_i                   => (others => '0'),
         joya1_i                   => (others => '0'),

         -- OSM: MiSTer defaults (all status bits zero) until config.vhd grows the menu
         osm_cpu_speed_i           => "00",
         osm_cpu_8086_i            => '0',
         osm_fake286_i             => '0',
         osm_splash_off_i          => '0',
         osm_bios_writable_i       => "00",
         osm_audio220_i            => "00",
         osm_opl2_i                => "00",
         osm_tandy_i               => '0',
         osm_speaker_vol_i         => "00",
         osm_audio_boost_i         => "00",
         osm_stereo_mix_i          => "00",
         osm_crt_h_i               => "0000",
         osm_crt_v_i               => "000",
         osm_vsync_w_i             => "000",
         osm_hsync_w_i             => "000",
         osm_scandoubler_fx_i      => "00",
         osm_aspect_i              => "00",
         osm_display_i             => "000",
         osm_vga13_tv_i            => '0',
         osm_monitor_i             => "00",
         osm_ems_disable_i         => '1',                  -- no EMS backend in the BRAM build
         osm_umb_disable_i         => '1',                  -- no UMB backend in the BRAM build
         osm_joy1_i                => "00",
         osm_joy2_i                => "00",
         osm_joy_sync_i            => '0',
         osm_joy_swap_i            => '0',
         osm_sb_irq7_i             => '0',
         osm_mpu401_disable_i      => '1',                  -- nothing behind the MPU-401
         osm_floppy_wp_i           => "00",

         bios_missing_pcxt_o       => bios_missing_pcxt_o,
         bios_missing_ega_o        => bios_missing_ega_o,
         reset_pending_o           => open,
         pause_o                   => open,
         splash_active_o           => splash_active_o,

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
         sdram_initialized_o       => open,

         -- Phase 3: no floppy/IDE bridge yet
         mgmt_addr_i               => (others => '0'),
         mgmt_dout_i               => (others => '0'),
         mgmt_din_o                => open,
         mgmt_wr_i                 => '0',
         mgmt_rd_i                 => '0',
         mgmt_req_o                => open,
         fdd_present_o             => open,
         led_disk_o                => led_disk_o
      ); -- i_pcxt_core

   -- Blanking for the framework: video_de_o is aligned with the RGB output,
   -- the core's own blank outputs lead it by a few pixels (see the wrapper
   -- notes), so derive the horizontal blank from DE.
   video_hblank_o <= not core_video_de;
   video_vblank_o <= core_video_vblank;

   -- The framework samples the overlay with video_ce_ovl_o; the core's pixel
   -- clock enable is the natural choice until the analog path is tuned.
   video_ce_ovl_o <= video_ce_o;

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

   i_mem : entity work.mem_bram
      port map (
         clk_i               => clk_main_i,
         rst_i               => reset_cold,
         avm_address_i       => avm_address,
         avm_writedata_i     => avm_writedata,
         avm_write_i         => avm_write,
         avm_read_i          => avm_read,
         avm_readdata_o      => avm_readdata,
         avm_readdatavalid_o => avm_readdatavalid,
         avm_waitrequest_o   => avm_waitrequest
      ); -- i_mem

end architecture synthesis;
