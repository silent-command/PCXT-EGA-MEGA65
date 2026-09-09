//============================================================================
//
//  This program is free software; you can redistribute it and/or modify it
//  under the terms of the GNU General Public License as published by the Free
//  Software Foundation; either version 2 of the License, or (at your option)
//  any later version.
//
//  This program is distributed in the hope that it will be useful, but WITHOUT
//  ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or
//  FITNESS FOR A PARTICULAR PURPOSE.  See the GNU General Public License for
//  more details.
//
//  You should have received a copy of the GNU General Public License along
//  with this program; if not, write to the Free Software Foundation, Inc.,
//  51 Franklin Street, Fifth Floor, Boston, MA 02110-1301 USA.
//
//============================================================================

//============================================================================
//
//  MEGA65: pcxt_core - the MEGA65 replacement for the MiSTer `emu` module.
//
//  Derived from PCXT-EGA.sv of the pinned submodule CORE/PCXT-EGA_MiSTer at
//  commit c6b4dc8 (2026-09-04). The body is kept as close to upstream as
//  possible so that `diff PCXT-EGA.sv pcxt_core.sv` stays reviewable and the
//  file can be rebased on upstream: the MiSTer framework signals keep their
//  upstream names and are rebuilt from the flat ANSI ports below. Every
//  non-trivial edit is marked with a `// MEGA65:` comment at the spot. Design
//  input: docs/emu-signal-map.md (port plan in section 3).
//
//  Removed:   CONF_STR / build_id.v, hps_io, hps_ext, pll, pll_system,
//             the clk_14_318 register divider, mt32pi (+ attenuation),
//             the 350-line DDRAM framebuffer path (ega_fb_capture,
//             ega_fb_readout, ega_ddr_arbiter, video_source_switch,
//             VGA_F1), the SDRAM_DQ pin tristate, the second SD card pins,
//             the COM2/HPS-MIDI/USER_IO pins, and all framework tie-offs
//             (ADC_BUS, VGA_SCALER/DISABLE, HDMI_*, LED_*, BUTTONS).
//  Replaced:  vga_video_clock_mux -> Xilinx BUFGMUX_CTRL;
//             video_mixer -> an inline copy of its pass-through behaviour.
//  Kept:      everything else, including the reset tree, the BIOS loader,
//             the splash/BIOS-hold logic, reset_pending_notice (with
//             OSD_STATUS tied 0), the output retime registers and the
//             jtframe_credits overlay.
//
//  SDRAM pins: the CHIPSET's KFSDRAM pin interface (sdram_*_o / sdram_dq_in_i)
//  is exported one-to-one. This module does not know what is behind them; a
//  separate memory shim re-purposes the pins (docs/emu-signal-map.md 3.7a).
//
//============================================================================

// MEGA65: the shipped MiSTer build sets all seven feature macros to 1 through
// config.tcl; the same defaults are made explicit here (still overridable).
`ifndef ENABLE_MIDI
`define ENABLE_MIDI 1
`endif
`ifndef ENABLE_OPL2
`define ENABLE_OPL2 1
`endif
`ifndef ENABLE_CMS
`define ENABLE_CMS 1
`endif
`ifndef ENABLE_EMS
`define ENABLE_EMS 1
`endif
`ifndef ENABLE_UMB
`define ENABLE_UMB 1
`endif
`ifndef ENABLE_TANDY_AUDIO
`define ENABLE_TANDY_AUDIO 1
`endif
`ifndef ENABLE_SB
`define ENABLE_SB 1
`endif

module pcxt_core
    (
        // MEGA65: flat ANSI ports, docs/emu-signal-map.md section 3.
        // 3.1 clocks and resets (the two MMCMs live in clk.vhd)
        input  wire        clk_core_i,             // 100 MHz, i8088 core clock (clk_100)
        input  wire        clk_chipset_i,          // 50 MHz chipset clock (clk_chipset)
        input  wire        clk_video_base_i,       // 28.636 MHz (clk_28_636)
        input  wire        clk_video_x2_i,         // 57.272 MHz video pipeline (clk_57_272)
        input  wire        clk_video_out_ps_i,     // 57.272 MHz phase shifted (clk_video_out_ps)
        input  wire        clk_video_vga_i,        // 25.2 MHz mode-13h native (clk_25_2)
        input  wire        clk_14_318_i,           // 14.318 MHz UART reference / splash timebase
        input  wire        pll_locked_i,           // both MMCMs locked
        input  wire        reset_i,                // cold / core-load reset (RESET)
        input  wire        reset_osd_i,            // "Reset & apply settings" pulse (status[0])
        input  wire        reset_button_i,         // user reset key (buttons[1])
        // 3.2 video out, all in video_clk_o
        output wire        video_clk_o,
        output wire        video_ce_o,
        output wire  [7:0] video_red_o,
        output wire  [7:0] video_green_o,
        output wire  [7:0] video_blue_o,
        output wire        video_hs_o,
        output wire        video_vs_o,
        output wire        video_hblank_o,
        output wire        video_vblank_o,
        output wire        video_de_o,
        output wire        video_mode13_o,             // hint: private 31.5 kHz VGA raster active
        output wire        video_mode13_native_clk_o,  // hint: the 25.2 MHz clock is selected
        output wire        video_mode350_o,            // hint: 350-line 21.8 kHz raster (clk_video_base_i domain)
        output wire [11:0] video_active_dots_o,        // hint (clk_video_base_i domain, changes at vblank)
        output wire  [9:0] video_active_lines_o,       // hint (clk_video_base_i domain, changes at vblank)
        output wire  [1:0] video_aspect_o,             // OSM aspect choice (status[9:8])
        output wire  [1:0] video_scanlines_o,          // VGA_SL: {50%, 25%}
        // 3.3 audio, signed, registered on clk_chipset_i
        output wire [15:0] audio_left_o,
        output wire [15:0] audio_right_o,
        output wire  [1:0] audio_mix_o,                // 0 none, 1 25%, 2 50%, 3 100%
        // 3.4 keyboard, mouse, joysticks
        input  wire        ps2_kbd_clk_i,          // device -> host
        input  wire        ps2_kbd_data_i,
        output wire        ps2_kbd_clk_o,          // host -> device
        output wire        ps2_kbd_data_o,
        input  wire [10:0] ps2_key_i,              // {toggle, pressed, extended, set-2 code}
        input  wire        ps2_mouse_clk_i,        // device -> host
        input  wire        ps2_mouse_data_i,
        output wire        ps2_mouse_clk_o,        // host -> device
        output wire        ps2_mouse_data_o,
        input  wire [13:0] joy0_i,                 // [0] right [1] left [2] down [3] up [4] fire1 [5] fire2
        input  wire [13:0] joy1_i,
        input  wire [15:0] joya0_i,                // {Y[15:8], X[7:0]} signed, 0 = centred
        input  wire [15:0] joya1_i,
        // 3.5 OSM options, one per status field, quasi-static in clk_chipset_i
        input  wire  [1:0] osm_cpu_speed_i,        // status[18:17]: 4.77, 7.16, 9.54, Max
        input  wire        osm_cpu_8086_i,         // status[63], reset-applied
        input  wire        osm_fake286_i,          // status[53]
        input  wire        osm_splash_off_i,       // status[7]
        input  wire  [1:0] osm_bios_writable_i,    // status[31:30]: None, EC00, Main, All
        input  wire  [1:0] osm_audio220_i,         // status[29:28]: C/MS, Sound Blaster, Disabled
        input  wire  [1:0] osm_opl2_i,             // status[43:42]: Adlib, SB FM, Disabled
        input  wire        osm_tandy_i,            // status[55]
        input  wire  [1:0] osm_speaker_vol_i,      // status[33:32]
        input  wire  [1:0] osm_audio_boost_i,      // status[37:36]: No, 2x, 4x
        input  wire  [1:0] osm_stereo_mix_i,       // status[39:38], passed to audio_mix_o
        input  wire  [3:0] osm_crt_h_i,            // status[49:46]
        input  wire  [2:0] osm_crt_v_i,            // status[52:50]
        input  wire  [2:0] osm_vsync_w_i,          // status[66:64]: Auto, 1..7
        input  wire  [2:0] osm_hsync_w_i,          // status[69:67]: Auto, 1..7
        input  wire  [1:0] osm_scandoubler_fx_i,   // status[2:1]: only VGA_SL survives
        input  wire  [1:0] osm_aspect_i,           // status[9:8], hint only
        input  wire  [2:0] osm_display_i,          // status[16:14]: Full Color, Green, Amber, B&W, ...
        input  wire        osm_vga13_tv_i,         // status[10]: 1 = TV 60Hz raster for mode 13h
        input  wire  [1:0] osm_monitor_i,          // status[45:44]: 5154, 5153, 5151; reset-applied
        input  wire        osm_ems_disable_i,      // status[5]
        input  wire        osm_umb_disable_i,      // status[12]
        input  wire  [1:0] osm_joy1_i,             // status[24:23]: [0] digital, [1] disabled
        input  wire  [1:0] osm_joy2_i,             // status[26:25]
        input  wire        osm_joy_sync_i,         // status[27]
        input  wire        osm_joy_swap_i,         // status[54]
        input  wire        osm_sb_irq7_i,          // status[70]: 0 = IRQ5, 1 = IRQ7
        input  wire        osm_mpu401_disable_i,   // status[56]
        input  wire  [1:0] osm_floppy_wp_i,        // status[20:19]: None, A:, B:, A: & B:
        // 3.5 status outputs for the OSM / help screen
        output wire        bios_missing_pcxt_o,
        output wire        bios_missing_ega_o,
        output wire        reset_pending_o,        // a reset-applied option differs from the running one
        output wire        pause_o,                // F12 pause (pause_core)
        output wire        splash_active_o,        // splash or BIOS hold on screen (splashscreen)
        // 3.6 ROM download, ioctl-shaped (16-bit words, addr advances by 2)
        input  wire        rom_download_i,         // ioctl_download: high for the whole file
        input  wire  [7:0] rom_index_i,            // ioctl_index: 0 PCXT BIOS, 2 EC00/XTIDE, 3 EGA BIOS
        input  wire        rom_wr_i,               // ioctl_wr: one clk_chipset_i strobe per word
        input  wire [24:0] rom_addr_i,             // ioctl_addr: even byte offset in the file
        input  wire [15:0] rom_data_i,             // ioctl_data: little-endian word
        output wire        rom_wait_o,             // ioctl_wait: 1 = hold the next word
        // 3.7(a) the CHIPSET's SDRAM pins, exported for the memory shim
        output wire [12:0] sdram_a_o,
        output wire  [1:0] sdram_ba_o,
        output wire        sdram_cke_o,
        output wire        sdram_ncs_o,
        output wire        sdram_nras_o,
        output wire        sdram_ncas_o,
        output wire        sdram_nwe_o,
        output wire [15:0] sdram_dq_out_o,
        output wire        sdram_dq_io_o,          // 0 = the chipset drives the data pins
        input  wire [15:0] sdram_dq_in_i,
        output wire        sdram_dqml_o,
        output wire        sdram_dqmh_o,
        output wire        sdram_initialized_o,    // initilized_sdram: KFSDRAM reached IDLE once
        // 3.8 mgmt bus (bridge in main.vhd), clk_chipset_i, single-cycle strobes
        input  wire [15:0] mgmt_addr_i,
        input  wire [15:0] mgmt_dout_i,            // bridge -> core (mgmt_dout)
        output wire [15:0] mgmt_din_o,             // core -> bridge (mgmt_din)
        input  wire        mgmt_wr_i,
        input  wire        mgmt_rd_i,
        output wire  [7:0] mgmt_req_o,             // [7] FDD write, [6] FDD read, [2:0] IDE request
        output wire  [1:0] fdd_present_o,
        // 3.9 misc
        output wire        led_disk_o,              // any FDD or IDE request pending
    // 3.10 debug: raw chipset video signals before the mixer/retime stages
    output wire        dbg_de_o,
    output wire        dbg_hb_o,
    output wire        dbg_vb_o,
        // floppy CPU<->FDC path probes
    output wire [15:0] dbg_fdc0_o,
    output wire [15:0] dbg_fdc1_o,
    output wire [15:0] dbg_fdc2_o
    );

    ///////// MEGA65: MiSTer framework signals the body still refers to /////////
    // Declared here under their upstream names; the ports feed them (inputs)
    // or are fed by them (outputs, see the MEGA65 PORTS block at the end).

    wire        RESET      = reset_i;
    wire        OSD_STATUS = 1'b0;    // no "OSD closed" event: reset_pending_notice never fires
    wire        CLK_VIDEO;
    wire        CE_PIXEL;
    wire  [7:0] VGA_R, VGA_G, VGA_B;
    wire        VGA_HS, VGA_VS, VGA_DE;
    wire  [1:0] VGA_SL;
    wire [15:0] AUDIO_L, AUDIO_R;
    wire  [1:0] AUDIO_MIX;
    // COM2 / HPS-MIDI pins do not exist: inputs at their idle level, outputs internal
    wire        UART_RXD = 1'b1, UART_CTS = 1'b1, UART_DSR = 1'b1;
    wire        UART_TXD, UART_RTS, UART_DTR;
    wire  [6:0] USER_IN = 7'h7F;
    // second SD card: no card, MISO idle high
    wire        SD_MISO = 1'b1;
    // the CHIPSET's SDRAM pins, exported (docs/emu-signal-map.md 3.7a)
    wire        SDRAM_CLK, SDRAM_CKE, SDRAM_nCS, SDRAM_nRAS, SDRAM_nCAS, SDRAM_nWE;
    wire [12:0] SDRAM_A;
    wire  [1:0] SDRAM_BA;
    wire        SDRAM_DQML, SDRAM_DQMH;

    assign SDRAM_CLK = clk_chipset;



    //////////////////////////////////////////////////////////////////
    // Status Bit Map:
    //              Upper                          Lower
    // 0         1         2         3          4         5         6
    // 01234567890123456789012345678901 23456789012345678901234567890123
    // 0123456789ABCDEFGHIJKLMNOPQRSTUV 0123456789ABCDEFGHIJKLMNOPQRSTUV
    // XXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXX XXXXXXXXXXXXXXXXXXXXXXX.....XXXX
    //
    // The first 64 status bits are fully allocated. The extended status
    // vector continues at bit 64; its first six bits carry the VSync and
    // HSync width options and bit 70 carries the Sound Blaster IRQ choice,
    // so those settings remain available to the OSD and are also persisted
    // by the normal core CFG file.
    //
    // Spend the extended status bits carefully. Anything already reachable through XTEGACTL
    // is a candidate to give its bit back the same way - Sync Joy to CPU
    // Speed, Fake 286 FLAGS and MT32-pi Mode are each one more bit, and the
    // CRT H and V offsets another seven, all without losing the setting.

    // MEGA65: no CONF_STR; the menu lives in the MEGA65 OSM and arrives as
    // the osm_*_i ports (docs/emu-signal-map.md 1.1 maps every entry).

    wire forced_scandoubler;
    wire vga_mode13_active_video;
    wire vga_mode13_pixel_toggle;
    wire ega_dot_toggle;
    wire ega_dot_clock_sel;
    wire ega_scandouble_active;
    wire ega_vmode_toggle;
    wire        ega_mode350;
    wire [11:0] ega_active_dots;
    wire [9:0]  ega_active_lines;
    wire [1:0] buttons;
    wire [127:0] status;
    // This setting chooses only the Mode 13h output raster.  The extension
    // itself starts disabled and VGATSR enables it through XTEGACTL, so
    // changing Native/TV timing can never remove a live video device.
    // Native restores the original 31.4 kHz / 70 Hz raster; TV 60Hz is the
    // CRT-TV-compatible 15.7 kHz profile.
    wire       vga_mode13_native_osd = ~status[10];
    // Status bit 63 is the pending CPU selection. The value presented to the
    // BIU is latched only during reset; changing the menu alone cannot change
    // queue depth or bus width while an instruction is in flight.
    wire        cpu_type_8086_osd = status[63];
    // Status bit 53 makes PUSHF report zero in reserved FLAGS bits 12:15,
    // matching a real-mode 80286 for legacy CPU probes.  Unlike the CPU type
    // this is applied live: it only gates a mux on the PUSHF operand path, so
    // the worst a mid-run change can do is decide the PUSHF of that instant.
    wire        fake_286_flags_osd = status[53];
    wire        is8086_applied;
    // Status bits 45:44 are the pending physical-monitor switch selection.
    // ega_monitor_profile_applied is only updated while the machine is held
    // in reset, just as a real EGA card samples its switches during POST.
    wire  [1:0] ega_monitor_profile_osd = status[45:44];
    wire  [1:0] ega_monitor_profile_applied;
    // XTEGACTL. The register file is decoded down in the chipset; what the
    // fields mean is resolved here, where the menu status lives. Every field
    // reads zero as "leave it to the OSD", so with nothing written the machine
    // behaves exactly as the menu says.
    wire [7:0]  xtegactl_cpu, xtegactl_exp, xtegactl_vid, xtegactl_inp, xtegactl_midi, xtegactl_exp2;
    wire [7:0]  xtegactl_crt, xtegactl_sync;
    wire [39:0] xtegactl_status_effective;
    wire [17:0] xtegactl_status_osd_match;
    wire [1:0]  eff_speed;
    wire        eff_fake286;
    wire [1:0]  eff_opl2;
    wire        eff_cms, eff_ems, eff_umb, eff_vga13;
    wire        eff_sb;
    wire  [2:0] eff_sb_irq;
    wire [3:0]  eff_crt_h;
    wire [2:0]  eff_crt_v;
    wire [2:0]  eff_vsync_w, eff_hsync_w;
    wire        eff_joy1_digital, eff_joy1_disable;
    wire        eff_joy2_digital, eff_joy2_disable;
    wire        eff_joy_sync, eff_joy_swap, eff_mt32_gm, eff_tandy, eff_mpu401;

    // Audio at 220h. With both cards built this is one three-way field in
    // status[29:28]: 0 = C/MS, 1 = Sound Blaster, 2 = neither. With only one
    // built there is nothing to choose between, so bit 29 stays the plain
    // Enabled/Disabled it has always been and bit 28 is left to Swap
    // Joysticks. Either way these two are never both high, which is what
    // 226h/227h requires.
    wire       a220_three_way = (`ENABLE_CMS && `ENABLE_SB) ? 1'b1 : 1'b0;
    wire [1:0] a220_sel       = status[29:28];
    wire       a220_cms       = `ENABLE_CMS
                             ? (a220_three_way ? (a220_sel == 2'd0) : ~status[29])
                             : 1'b0;
    wire       a220_sb        = `ENABLE_SB
                             ? (a220_three_way ? (a220_sel == 2'd1) : ~status[29])
                             : 1'b0;
    wire [2:0] sb_irq_osd     = status[70] ? 3'd7 : 3'd5;
    wire       sb_irq7        = (eff_sb_irq == 3'd7);

    xtegactl_resolve xtegactl_apply (
        .reg_cpu          (xtegactl_cpu),
        .reg_exp          (xtegactl_exp),
        .reg_vid          (xtegactl_vid),
        .reg_inp          (xtegactl_inp),
        .reg_midi         (xtegactl_midi),
        .reg_exp2         (xtegactl_exp2),
        .osd_speed        (status[18:17]),
        .osd_fake286      (fake_286_flags_osd),
        .osd_opl2         (status[43:42]),
        .osd_cms          (a220_cms),
        .osd_sb           (a220_sb),
        .osd_sb_irq       (sb_irq_osd),
        .build_sb         (`ENABLE_SB ? 1'b1 : 1'b0),
        .reg_crt          (xtegactl_crt),
        .reg_sync         (xtegactl_sync),
        .osd_crt_h        (status[49:46]),
        .osd_crt_v        (status[52:50]),
        .osd_vsync_w      (status[66:64]),
        .osd_hsync_w      (status[69:67]),
        .osd_ems          (~status[5]),
        .osd_umb          (~status[12]),
        .osd_joy1_digital (status[23]),
        .osd_joy1_disable (status[24]),
        .osd_joy2_digital (status[25]),
        .osd_joy2_disable (status[26]),
        .osd_joy_sync     (status[27]),
        .osd_joy_swap     (status[54]),
        .osd_mt32_gm      (status[41]),
        .osd_tandy        (status[55]),
        .osd_mpu401       (~status[56]),
        .build_tandy      (`ENABLE_TANDY_AUDIO ? 1'b1 : 1'b0),
        .eff_speed        (eff_speed),
        .eff_fake286      (eff_fake286),
        .eff_opl2         (eff_opl2),
        .eff_cms          (eff_cms),
        .eff_sb           (eff_sb),
        .eff_sb_irq       (eff_sb_irq),
        .eff_ems          (eff_ems),
        .eff_umb          (eff_umb),
        .eff_vga13        (eff_vga13),
        .eff_joy1_digital (eff_joy1_digital),
        .eff_joy1_disable (eff_joy1_disable),
        .eff_joy2_digital (eff_joy2_digital),
        .eff_joy2_disable (eff_joy2_disable),
        .eff_joy_sync     (eff_joy_sync),
        .eff_joy_swap     (eff_joy_swap),
        .eff_mt32_gm      (eff_mt32_gm),
        .eff_tandy        (eff_tandy),
        .eff_mpu401       (eff_mpu401),
        .eff_crt_h        (eff_crt_h),
        .eff_crt_v        (eff_crt_v),
        .eff_vsync_w      (eff_vsync_w),
        .eff_hsync_w      (eff_hsync_w),
        .status_effective (xtegactl_status_effective),
        .status_osd_match (xtegactl_status_osd_match)
    );

    wire [7:0]  uart_mode;

    //Keyboard Ps2
    wire        ps2_kbd_clk_out;
    wire        ps2_kbd_data_out;
    wire        ps2_kbd_clk_in;
    wire        ps2_kbd_data_in;
    // Decoded key stream, used only to catch F12 while the machine is in reset.
    wire [10:0] ps2_key;

    //Mouse PS2
    wire        ps2_mouse_clk_out;
    wire        ps2_mouse_data_out;
    wire        ps2_mouse_clk_in;
    wire        ps2_mouse_data_in;

    wire        ioctl_download;
    wire  [7:0] ioctl_index;
    wire        ioctl_wr;
    wire [24:0] ioctl_addr;
    wire [15:0] ioctl_data;
    reg         ioctl_wait;


    wire [13:0] joy0, joy1;
    wire [15:0] joya0, joya1;
    // Bit order set by tandy_pcjr_joy: P1 type, P1 disable, P2 type, P2
    // disable, turbo sync.
    wire [4:0]  joy_opts = {eff_joy_sync, eff_joy2_disable, eff_joy2_digital,
                            eff_joy1_disable, eff_joy1_digital};

    wire [1:0] scale = status[2:1];
    wire [2:0] screen_mode = status[16:14];
    wire [1:0] ar = status[9:8];
    // A zero XTEGACTL field defers to the OSD; a non-zero value is a
    // per-program override. The OSD fields live in the first six extended
    // status bits, beyond the legacy 64-bit map.
    wire [2:0] vsync_width_osd = eff_vsync_w;
    wire [2:0] hsync_width_osd = eff_hsync_w;

    reg [1:0]   scale_video_ff;
    reg [2:0]   screen_mode_video_ff;
    wire        video_scandoubler_en = (scale_video_ff > 0) || forced_scandoubler;
    // bits 2:0 have no h0/h1/h2 entries in CONF_STR; bit3 exposes MT32-pi -
    // gated on the MPU-401 itself being enabled as well as mt32-pi being
    // detected, since a disabled MPU-401 leaves nothing for the page to
    // configure; bits 5:4 reveal the two "halted, no BIOS" lines at the top
    // of the menu.
    wire [15:0] status_menumask = {10'd0, bios_missing_ega, bios_missing_pcxt,
                                   (`ENABLE_MIDI & mt32_available & eff_mpu401), 3'b111};

    wire VGA_VBlank_border;
    wire std_hsyncwidth;
    wire pause_core;

    always @(posedge clk_57_272)
    begin
        scale_video_ff          <= scale;
        screen_mode_video_ff    <= screen_mode;
        // MEGA65: VIDEO_ARX/ARY dropped; the OSM aspect choice leaves as video_aspect_o
    end

    // MEGA65: hps_io is gone. The status vector is rebuilt bit for bit from
    // the OSM inputs (docs/emu-signal-map.md 1.2 / 3.5) so every status[...]
    // reader below stays as upstream wrote it. Fields with no MEGA65 owner
    // read 0: MT32-pi (4:3, 6, 13, 40, 41, 62:60), 2nd SD card (22:21),
    // 350-line CRT (35:34, the DDRAM framebuffer path is gone), and the
    // unused 11, 59:57 and 127:71.
    assign status[0]      = reset_osd_i;            // R0  Reset & apply settings
    assign status[2:1]    = osm_scandoubler_fx_i;   // O12 Scandoubler Fx (VGA_SL only)
    assign status[4:3]    = 2'b00;                  // O34 MT32-pi ROM
    assign status[5]      = osm_ems_disable_i;      // O5  2MB EMS: 1 = disabled
    assign status[6]      = 1'b0;                   // O6  USER I/O: MIDI
    assign status[7]      = osm_splash_off_i;       // O7  Boot Splash Screen: 1 = no
    assign status[9:8]    = osm_aspect_i;           // O89 Aspect ratio
    assign status[10]     = osm_vga13_tv_i;         // OA  VGA 13h+ CRT: 1 = TV 60Hz
    assign status[11]     = 1'b0;                   //     unused
    assign status[12]     = osm_umb_disable_i;      // OC  UMB: 1 = disabled
    assign status[13]     = 1'b0;                   // OD  Use MT32-pi
    assign status[16:14]  = osm_display_i;          // OEG Display
    assign status[18:17]  = osm_cpu_speed_i;        // OHI CPU Speed
    assign status[20:19]  = osm_floppy_wp_i;        // OJK Write Protect
    assign status[22:21]  = 2'b00;                  // OLM 2nd SD card: disabled
    assign status[24:23]  = osm_joy1_i;             // ONO Joystick 1
    assign status[26:25]  = osm_joy2_i;             // OPQ Joystick 2
    assign status[27]     = osm_joy_sync_i;         // OR  Sync Joy to CPU Speed
    assign status[29:28]  = osm_audio220_i;         // OST Audio 220h
    assign status[31:30]  = osm_bios_writable_i;    // OUV BIOS Writable
    assign status[33:32]  = osm_speaker_vol_i;      // o01 Speaker Volume
    assign status[35:34]  = 2'b00;                  // o23 350-line CRT: native
    assign status[37:36]  = osm_audio_boost_i;      // o45 Audio Boost
    assign status[39:38]  = osm_stereo_mix_i;       // o67 Stereo Mix
    assign status[40]     = 1'b0;                   // r8  Reset Hanging Notes
    assign status[41]     = 1'b0;                   // o9  MT32-pi Mode
    assign status[43:42]  = osm_opl2_i;             // oAB OPL2
    assign status[45:44]  = osm_monitor_i;          // oCD Monitor
    assign status[49:46]  = osm_crt_h_i;            // oEH CRT H offset
    assign status[52:50]  = osm_crt_v_i;            // oIK CRT V offset
    assign status[53]     = osm_fake286_i;          // oL  Fake 286 FLAGS
    assign status[54]     = osm_joy_swap_i;         // oM  Swap Joysticks
    assign status[55]     = osm_tandy_i;            // oN  Tandy Sound
    assign status[56]     = osm_mpu401_disable_i;   // oO  MPU-401: 1 = disabled
    assign status[59:57]  = 3'b000;                 //     unused
    assign status[62:60]  = 3'b000;                 // oSU MT32-pi SoundFont
    assign status[63]     = osm_cpu_8086_i;         // oV  CPU Type
    assign status[66:64]  = osm_vsync_w_i;          // O[66:64] VSync Width
    assign status[69:67]  = osm_hsync_w_i;          // O[69:67] HSync Width
    assign status[70]     = osm_sb_irq7_i;          // O[70] Sound Blaster IRQ
    assign status[127:71] = 57'd0;

    assign buttons            = {reset_button_i, 1'b0};   // [1] reset key, [0] OSD button (unused)
    assign forced_scandoubler = 1'b0;                     // dead upstream as well (signal map 1.2, bits 2:1)
    assign uart_mode          = 8'd0;                     // no HPS UART menu, so no HPS MIDI

    assign ps2_key            = ps2_key_i;
    assign ps2_kbd_clk_in     = ps2_kbd_clk_i;            // device -> host, into the 2-FF stages below
    assign ps2_kbd_data_in    = ps2_kbd_data_i;
    assign ps2_kbd_clk_o      = ps2_kbd_clk_out;          // host -> device (keyboard reset)
    assign ps2_kbd_data_o     = ps2_kbd_data_out;
    assign ps2_mouse_clk_out  = ps2_mouse_clk_i;          // device -> host, straight into MSMouseWrapper
    assign ps2_mouse_data_out = ps2_mouse_data_i;
    assign ps2_mouse_clk_o    = ps2_mouse_clk_in;         // host -> device (mouse init commands)
    assign ps2_mouse_data_o   = ps2_mouse_data_in;

    assign joy0  = joy0_i;
    assign joy1  = joy1_i;
    assign joya0 = joya0_i;
    assign joya1 = joya1_i;

    // ROM download: the loader FSM below consumes this unchanged (signal map 3.6)
    assign ioctl_download = rom_download_i;
    assign ioctl_index    = rom_index_i;
    assign ioctl_wr       = rom_wr_i;
    assign ioctl_addr     = rom_addr_i;
    assign ioctl_data     = rom_data_i;
    assign rom_wait_o     = ioctl_wait;


    wire [15:0] mgmt_din;
    wire [15:0] mgmt_dout;
    wire [15:0] mgmt_addr;
    wire        mgmt_rd;
    wire        mgmt_wr;
    wire  [7:0] mgmt_req;
    assign mgmt_req[5:3] = 3'b000;

    // MEGA65: hps_ext is gone; the mgmt bus comes straight from the bridge
    // in main.vhd (docs/mgmt-bus-and-storage-regs.md section 1).
    assign mgmt_dout  = mgmt_dout_i;
    assign mgmt_addr  = mgmt_addr_i;
    assign mgmt_rd    = mgmt_rd_i;
    assign mgmt_wr    = mgmt_wr_i;
    assign mgmt_din_o = mgmt_din;
    assign mgmt_req_o = mgmt_req;

    //
    ///////////////////////   CLOCKS   /////////////////////////////
    //

    wire clk_sys;
    wire pll_locked;

    wire clk_100;
    wire clk_28_636;
    wire clk_25_2;
    wire clk_57_272;
    wire clk_video_out_ps;
    wire clk_card_video;
    wire clk_14_318;    // MEGA65: from the MMCM, not the register divider
    wire clk_cpu;
    logic cpu_ce_posedge;
    logic cpu_ce_negedge;
    logic peripheral_ce;
    wire clk_chipset;

    localparam [27:0] cur_rate = 28'd50000000;

    // MEGA65: both PLLs are MMCMs in clk.vhd; the clocks arrive as ports
    // and one lock covers both.
    assign clk_100     = clk_core_i;
    assign clk_chipset = clk_chipset_i;
    assign pll_locked  = pll_locked_i;

    wire pll_system_locked;

    assign clk_28_636        = clk_video_base_i;
    assign clk_57_272        = clk_video_x2_i;
    assign clk_video_out_ps  = clk_video_out_ps_i;
    assign clk_25_2          = clk_video_vga_i;
    assign clk_14_318        = clk_14_318_i;
    assign pll_system_locked = pll_locked_i;

    wire vga_mode13_wide_clock;
    wire vga_native_standard_clock = vga_mode13_active_video &&
                                     vga_mode13_native_osd &&
                                     !vga_mode13_wide_clock;
    // MEGA65: vga_video_clock_mux (a Cyclone V clkselect) becomes the Xilinx
    // glitch-free clock mux; the select logic above is unchanged.
    BUFGMUX_CTRL vga_video_clock_select (
        .I0 (clk_28_636),
        .I1 (clk_25_2),
        .S  (vga_native_standard_clock),
        .O  (clk_card_video)
    );

    wire reset_wire = RESET | status[0] | buttons[1] | !pll_locked | !pll_system_locked  | splashscreen | splash_pending;
    wire video_retime_reset = RESET | status[0] | buttons[1] | !pll_locked | !pll_system_locked | splash_pending;
    (* ASYNC_REG = "TRUE" *) logic [1:0] video_retime_reset_sync = 2'b11;
    wire video_retime_reset_local = video_retime_reset_sync[1];

    // The output retime registers run on the phase-shifted video clock.
    // Reset asserts asynchronously but is released only on that clock.
    always_ff @(posedge clk_video_out_ps or posedge video_retime_reset) begin
        if (video_retime_reset)
            video_retime_reset_sync <= 2'b11;
        else
            video_retime_reset_sync <= {video_retime_reset_sync[0], 1'b0};
    end
    wire reset_sdram_wire = RESET | !pll_locked;

    //////////////////////////////////////////////////////////////////

    // MEGA65: the clk_14_318 register divider is gone; the MMCM supplies it.

    //////////////////////////////////////////////////////////////////

    logic  biu_done;
    logic  [7:0] clock_cycle_counter_division_ratio;
    logic  [7:0] clock_cycle_counter_decrement_value;
    logic        shift_read_timing;
    logic  [1:0] ram_read_wait_cycle;
    logic  [1:0] ram_write_wait_cycle;
    logic        cycle_accrate;
    logic  [1:0] clk_select;
    wire   [1:0] clk_select_next = eff_speed;

    always @(posedge clk_chipset, posedge reset)
    begin
        if (reset)
            clk_select <= 2'b00;
        else if (biu_done)
            clk_select <= clk_select_next;
    end

    XT_CE_Generator u_XT_CE_Generator
    (
        .clock                              (clk_chipset),
        .reset                              (reset),
        .clk_select_load                    (biu_done),
        .clk_select                         (clk_select_next),
        .cpu_clk_pin                        (clk_cpu),
        .cpu_ce_posedge                     (cpu_ce_posedge),
        .cpu_ce_negedge                     (cpu_ce_negedge),
        .peripheral_ce                      (peripheral_ce),
        .cycle_accrate                      (cycle_accrate),
        .clock_cycle_counter_division_ratio (clock_cycle_counter_division_ratio),
        .clock_cycle_counter_decrement_value(clock_cycle_counter_decrement_value),
        .shift_read_timing                  (shift_read_timing),
        .ram_read_wait_cycle                (ram_read_wait_cycle),
        .ram_write_wait_cycle               (ram_write_wait_cycle)
    );
    //////////////////////////////////////////////////////////////////

    logic reset = 1'b1;
    logic [15:0] reset_count = 16'h0000;
    logic reset_sdram = 1'b1;
    logic [15:0] reset_sdram_count = 16'h0000;

    always @(posedge clk_chipset, posedge reset_wire)
    begin
        if (reset_wire)
        begin
            reset <= 1'b1;
            reset_count <= 16'h0000;
        end
        else if (reset)
        begin
            if (reset_count != 16'hffff)
            begin
                reset <= 1'b1;
                reset_count <= reset_count + 16'h0001;
            end
            else
            begin
                reset <= 1'b0;
                reset_count <= reset_count;
            end
        end
        else
        begin
            reset <= 1'b0;
            reset_count <= reset_count;
        end
    end

    // Track the OSD selection throughout the stretched reset interval so the
    // final stable value is ready before the CPU starts executing the BIOS.
    // Changes made while the machine is running remain pending until reset.
    ega_monitor_profile_latch monitor_profile_latch (
        .clock        (clk_chipset),
        .reset_active (reset),
        .selected     (ega_monitor_profile_osd),
        .applied      (ega_monitor_profile_applied)
    );

    cpu_type_latch cpu_type_apply_latch (
        .clock                 (clk_chipset),
        .reset_active          (reset),
        .selected_8086         (cpu_type_8086_osd),
        .is8086                (is8086_applied)
    );

    // Fake 286 FLAGS is live, so it now crosses from the chipset domain that
    // hps_io drives into the core clock the EU mux is evaluated on. While it
    // was reset-latched the value only ever moved with the CPU held in reset
    // and no synchronizer was needed; a running change needs one.
    (* ASYNC_REG = "TRUE" *) logic [1:0] fake_286_flags_meta = 2'b00;
    wire fake_286_flags_applied = fake_286_flags_meta[1];

    always_ff @(posedge clk_100)
        fake_286_flags_meta <= {fake_286_flags_meta[0], eff_fake286};

    logic reset_cpu_ff = 1'b1;
    logic reset_cpu = 1'b1;
    logic [15:0] reset_cpu_count = 16'h0000;

    always @(negedge clk_chipset, posedge reset)
    begin
        if (reset)
            reset_cpu_ff <= 1'b1;
        else
            reset_cpu_ff <= reset;
    end

    always @(negedge clk_chipset, posedge reset)
    begin
        if (reset)
        begin
            reset_cpu <= 1'b1;
            reset_cpu_count <= 16'h0000;
        end
        else if (reset_cpu)
        begin
            reset_cpu <= reset_cpu_ff;
            reset_cpu_count <= 16'h0000;
        end
        else
        begin
            if (reset_cpu_count != 16'h002A)
            begin
                reset_cpu <= reset_cpu_ff;
                reset_cpu_count <= reset_cpu_count + 16'h0001;
            end
            else
            begin
                reset_cpu <= 1'b0;
                reset_cpu_count <= reset_cpu_count;
            end
        end
    end

    always @(posedge clk_chipset, posedge reset_sdram_wire)
    begin
        if (reset_sdram_wire)
        begin
            reset_sdram <= 1'b1;
            reset_sdram_count <= 16'h0000;
        end
        else if (reset_sdram)
        begin
            if (reset_sdram_count != 16'hffff)
            begin
                reset_sdram <= 1'b1;
                reset_sdram_count <= reset_sdram_count + 16'h0001;
            end
            else
            begin
                reset_sdram <= 1'b0;
                reset_sdram_count <= reset_sdram_count;
            end
        end
        else
        begin
            reset_sdram <= 1'b0;
            reset_sdram_count <= reset_sdram_count;
        end
    end

    //
    ///////////////////////   BIOS LOADER   ////////////////////////////
    //

    reg [4:0]  bios_load_state = 4'h0;
    reg [2:0]  bios_protect_flag;
    reg        bios_access_request;
    reg [19:0] bios_access_address;
    reg [15:0] bios_write_data;
    reg        bios_write_n;
    reg [7:0]  bios_write_wait_cnt;
    reg        bios_write_byte_cnt;
    wire       ega_bios_loaded;
    wire       ega_bios_write_protect;
    wire [1:0] ega_video_switches;
    wire select_pcxt  = (ioctl_index[5:0] == 0) && (ioctl_addr[24:16] == 9'b000000000);
    wire select_xtide = ioctl_index == 2;
    wire select_ega_bios = (ioctl_index[5:0] == 3) && (ioctl_addr[24:16] == 9'b000000000);

    // File identity, rather than the current address, defines the lifetime of
    // an upload.  ioctl_addr is not guaranteed to have the new file's first
    // address until its first data beat arrives.
    wire ega_bios_download_active = ioctl_download && (ioctl_index[5:0] == 6'd3);
    wire ega_bios_write_complete = (bios_load_state == 4'h04) &&
                                   bios_write_byte_cnt && select_ega_bios;

    // The loader returns to state 01 between every 16-bit word.  Treating that
    // state as the start of a new EGA download cleared the presence flag again
    // after every word (and once more at end-of-file), so the XT motherboard
    // switches continued to advertise CGA even though an EGA ROM was present.
    ega_bios_loaded_latch ega_bios_presence (
        .clock              (clk_chipset),
        .reset              (reset_sdram),
        .sdram_initialized  (initilized_sdram),
        .download_active    (ega_bios_download_active),
        .write_complete     (ega_bios_write_complete),
        .loaded             (ega_bios_loaded),
        .write_protect      (ega_bios_write_protect),
        .video_switches     (ega_video_switches)
    );

    // Same rule for the main BIOS.  Without it the 8088 is released into an
    // erased F000 segment, runs off into whatever the SDRAM happens to hold and
    // reprograms the CRTC to a raster nothing can display - which is what the
    // "splash, then black screen" reports on 15 kHz sets turned out to be.
    wire pcxt_bios_loaded;
    wire pcxt_bios_download_active = ioctl_download && (ioctl_index[5:0] == 6'd0);
    wire pcxt_bios_write_complete = (bios_load_state == 4'h04) &&
                                    bios_write_byte_cnt && select_pcxt;

    rom_presence_latch pcxt_bios_presence (
        .clock              (clk_chipset),
        .reset              (reset_sdram),
        .sdram_initialized  (initilized_sdram),
        .download_active    (pcxt_bios_download_active),
        .write_complete     (pcxt_bios_write_complete),
        .loaded             (pcxt_bios_loaded)
    );

    // Reported one at a time, main BIOS first: an EGA ROM is no use without a
    // machine to run it on, so naming both at once would only be noise.
    wire bios_missing_pcxt = ~pcxt_bios_loaded;
    wire bios_missing_ega  = pcxt_bios_loaded & ~ega_bios_loaded;

    wire [19:0] bios_access_address_wire = select_pcxt  ? { 4'b1111, ioctl_addr[15:0]} :
         select_xtide ? { 6'b111011, ioctl_addr[13:0]} :
         select_ega_bios ? { 4'b1100, ioctl_addr[15:0]} :
         20'hFFFFF;

    wire bios_load_n = ~(ioctl_download & (select_pcxt | select_xtide | select_ega_bios));

    always @(posedge clk_chipset, posedge reset_sdram)
    begin
        if (reset_sdram)
        begin
            bios_protect_flag   <= 3'b011;
            bios_access_request <= 1'b0;
            bios_access_address <= 20'hFFFFF;
            bios_write_data     <= 16'hFFFF;
            bios_write_n        <= 1'b1;
            bios_write_wait_cnt <= 'h0;
            bios_write_byte_cnt <= 1'h0;
            ioctl_wait          <= 1'b1;
            bios_load_state     <= 4'h00;
        end
        else if (~initilized_sdram)
        begin
            bios_protect_flag   <= 3'b011;
            bios_access_request <= 1'b0;
            bios_access_address <= 20'hFFFFF;
            bios_write_data     <= 16'hFFFF;
            bios_write_n        <= 1'b1;
            bios_write_wait_cnt <= 'h0;
            bios_write_byte_cnt <= 1'h0;
            ioctl_wait          <= 1'b1;
            bios_load_state     <= 4'h00;
        end
        else
        begin
            casez (bios_load_state)
                4'h00:
                begin
                    bios_protect_flag   <= {ega_bios_write_protect, ~status[31:30]};  // ega/f000/ec00 protection
                    bios_access_address <= 20'hFFFFF;
                    bios_write_data     <= 16'hFFFF;
                    bios_write_n        <= 1'b1;
                    bios_write_wait_cnt <= 'h0;
                    bios_write_byte_cnt <= 1'h0;
                    if (~ioctl_download)
                    begin
                        bios_access_request <= 1'b0;
                        ioctl_wait          <= 1'b0;
                    end
                    else
                    begin
                        bios_access_request <= 1'b1;
                        ioctl_wait          <= 1'b1;
                    end

                    if ((ioctl_download) && (~processor_ready) && (address_direction))
                        bios_load_state <= 4'h01;
                    else
                        bios_load_state <= 4'h00;
                end
                4'h01:
                begin
                    bios_protect_flag   <= 3'b000;
                    bios_access_request <= 1'b1;
                    bios_write_byte_cnt <= 1'h0;
                    if (~ioctl_download)
                    begin
                        bios_access_address <= 20'hFFFFF;
                        bios_write_data     <= 16'hFFFF;
                        bios_write_n        <= 1'b1;
                        bios_write_wait_cnt <= 'h0;
                        ioctl_wait          <= 1'b0;
                        bios_load_state     <= 4'h00;
                    end
                    else if ((~ioctl_wr) || (bios_load_n))
                    begin
                        bios_access_address <= 20'hFFFFF;
                        bios_write_data     <= 16'hFFFF;
                        bios_write_n        <= 1'b1;
                        bios_write_wait_cnt <= 'h0;
                        ioctl_wait          <= 1'b0;
                        bios_load_state     <= 4'h01;
                    end
                    else
                    begin
                        bios_access_address <= bios_access_address_wire;
                        bios_write_data     <= ioctl_data;
                        bios_write_n        <= 1'b1;
                        bios_write_wait_cnt <= 'h0;
                        ioctl_wait          <= 1'b1;
                        bios_load_state     <= 4'h02;
                    end
                end
                4'h02:
                begin
                    bios_protect_flag   <= 3'b000;
                    bios_access_request <= 1'b1;
                    bios_access_address <= bios_access_address;
                    bios_write_data     <= bios_write_data;
                    bios_write_byte_cnt <= bios_write_byte_cnt;
                    ioctl_wait          <= 1'b1;
                    bios_write_wait_cnt <= bios_write_wait_cnt + 'h1;

                    if (bios_write_wait_cnt != 'd20)
                    begin
                        bios_write_n        <= 1'b0;
                        bios_load_state     <= 4'h02;
                    end
                    else
                    begin
                        bios_write_n        <= 1'b1;
                        bios_load_state     <= 4'h03;
                    end
                end
                4'h03:
                begin
                    bios_protect_flag   <= 3'b000;
                    bios_access_request <= 1'b1;
                    bios_access_address <= bios_access_address;
                    bios_write_data     <= bios_write_data;
                    bios_write_n        <= 1'b1;
                    bios_write_byte_cnt <= bios_write_byte_cnt;
                    ioctl_wait          <= 1'b1;
                    bios_write_wait_cnt <= bios_write_wait_cnt + 'h1;

                    if (bios_write_wait_cnt != 'h40)
                        bios_load_state     <= 4'h03;
                    else
                        bios_load_state     <= 4'h04;
                end
                4'h04:
                begin
                    bios_protect_flag   <= 3'b000;
                    bios_access_request <= 1'b1;
                    bios_access_address <= bios_access_address + 'h1;
                    bios_write_data     <= {8'hFF, bios_write_data[15:8]};
                    bios_write_n        <= 1'b1;
                    bios_write_wait_cnt <= 'h0;
                    bios_write_byte_cnt <= ~bios_write_byte_cnt;
                    ioctl_wait          <= 1'b1;
                    if (bios_write_byte_cnt == 1'b0)
                        bios_load_state     <= 4'h02;
                    else
                        bios_load_state     <= 4'h01;
                end
                default:
                begin
                    bios_protect_flag   <= {ega_bios_write_protect, 2'b11};
                    bios_access_request <= 1'b0;
                    bios_access_address <= 20'hFFFFF;
                    bios_write_data     <= 16'hFFFF;
                    bios_write_n        <= 1'b1;
                    bios_write_wait_cnt <= 'h0;
                    bios_write_byte_cnt <= 1'h0;
                    ioctl_wait          <= 1'b0;
                    bios_load_state     <= 4'h00;
                end
            endcase
        end
    end


    //////////////////////////////////////////////////////////////////

    //
    // Splash screen
    //
    reg splash_off = 1'b1;
    reg [24:0] splash_cnt = 0;
    reg [3:0] splash_cnt2 = 0;
    reg splash_timed = 1'b0;
    reg splash_pending = 1'b1;
    reg [23:0] splash_boot_cnt = 24'd0;
    reg phys_reset_hold = 0;
    reg [23:0] phys_reset_cnt = 24'd0;
    localparam [23:0] PHYS_RESET_HOLD = 24'd2863600;
    localparam [23:0] SPLASH_BOOT_WAIT = 24'd14318000;

    always @ (posedge clk_14_318)
    begin
        splash_off <= status[7];
        if (RESET || buttons[1])
        begin
            phys_reset_hold <= 1'b1;
            phys_reset_cnt <= 24'd0;
        end
        else if (phys_reset_hold)
        begin
            if (phys_reset_cnt == PHYS_RESET_HOLD)
                phys_reset_hold <= 1'b0;
            else
                phys_reset_cnt <= phys_reset_cnt + 24'd1;
        end

        if (splash_pending)
        begin
            if (~splash_off)
            begin
                splash_timed <= 1'b1;
                splash_cnt <= 0;
                splash_cnt2 <= 0;
                splash_pending <= 1'b0;
                splash_boot_cnt <= 24'd0;
            end
            else if (splash_boot_cnt == SPLASH_BOOT_WAIT)
            begin
                splash_pending <= 1'b0;
            end
            else
            begin
                splash_boot_cnt <= splash_boot_cnt + 24'd1;
            end
        end
        else if (splash_timed)
        begin
            if (splash_off)
            begin
                splash_timed <= 0;
            end
            else if (splash_paused)
            begin
                // F12: hold the picture, and with it the machine, until asked
                // again.  Turning the splash off in the OSD still dismisses it,
                // so this cannot be a way to get stuck.
                splash_cnt <= splash_cnt;
            end
            else if(splash_cnt2 == 5) // 5 seconds delay
            begin
                splash_timed <= 0;
            end
            else if (splash_cnt == 14318000)
            begin // 1 second at 14.318Mhz
                splash_cnt2 <= splash_cnt2 + 1;
                splash_cnt <= 0;
            end
            else
                splash_cnt <= splash_cnt + 1;
        end

    end

    //
    // Splash pause
    //
    // The legend the splash draws is only true if F12 reaches something while
    // the splash is up.  The keyboard controller that decodes it is inside the
    // machine, and the machine is in reset for as long as the splash is on
    // screen, so it has to be caught out here instead.
    wire splash_paused;

    splash_f12_pause splash_pause (
        .clock         (clk_14_318),
        .splash_active (splash_timed),
        .ps2_key       (ps2_key),
        .paused        (splash_paused)
    );

    //
    // Missing BIOS hold
    //
    // Both ROMs arrive over ioctl while the machine is already held in reset
    // for the splash, so the check costs nothing extra: at the moment that hold
    // would be released, either they are there or they are not.
    //
    // If one is missing the hold simply never ends.  The 8088 therefore never
    // executes, never touches the CRTC, and the raster stays on the power-on
    // 640x200 that the splash is authored for - which is the whole point, since
    // that is the one mode every 15 kHz television can lock to.  A set that
    // could show the splash can show this.
    //
    // The splash is put back up for it even when the OSD has it switched off.
    // A held black frame is indistinguishable from the failure it is meant to
    // explain, and the picture is what draws the eye to the notice.
    //
    // splash_pending is only ever cleared and splash_timed is only ever set
    // from it, so the boot phase falls exactly once and the hold takes over on
    // that same edge, with no clock in which the CPU could start.
    wire bios_hold;
    wire [7:0] info;
    wire info_req;
    wire [7:0] bios_info;
    wire       bios_info_req;
    // Driven by reset_pending_notice, instantiated with the MMC block below
    // because the 2nd SD card mapping it watches is declared there.
    wire [7:0] pending_info;
    wire       pending_info_req;

    bios_hold_notice bios_notice (
        .clock             (clk_14_318),
        .splash_boot_phase (splash_pending | splash_timed),
        .bios_missing_pcxt (bios_missing_pcxt),
        .bios_missing_ega  (bios_missing_ega),
        .hold              (bios_hold),
        .info              (bios_info),
        .info_req          (bios_info_req)
    );

    // The halt notice wins the info box: its machine is stopped, and the
    // reset-pending one is only worth reading on a machine that is running.
    // reset_pending_notice is held off by the same signal, so in practice the
    // two never ask at once.
    assign info     = bios_info_req ? bios_info : pending_info;
    assign info_req = bios_info_req | pending_info_req;

    wire splashscreen = splash_timed | bios_hold;

    //
    // Input F/F PS2_CLK
    //
    logic   device_clock_ff;
    logic   device_clock;

    always_ff @(negedge clk_chipset, posedge reset)
    begin
        if (reset)
        begin
            device_clock_ff <= 1'b0;
            device_clock    <= 1'b0;
        end
        else
        begin
            device_clock_ff <= ps2_kbd_clk_in;
            device_clock    <= device_clock_ff ;
        end
    end


    //
    // Input F/F PS2_DAT
    //
    logic   device_data_ff;
    logic   device_data;

    always_ff @(negedge clk_chipset, posedge reset)
    begin
        if (reset)
        begin
            device_data_ff <= 1'b0;
            device_data    <= 1'b0;
        end
        else
        begin
            device_data_ff <= ps2_kbd_data_in;
            device_data    <= device_data_ff;
        end
    end


    wire [7:0] data_bus;
    wire INTA_n;
    wire [19:0] cpu_ad_out;
    reg  [19:0] cpu_address;
    wire [7:0] cpu_data_bus;
    wire [15:0] data_bus_word;          // 8086 wide read
    wire [15:0] cpu_data_bus_word;       // 8086 wide write
    wire        word_read_possible;      // SDRAM can serve the latched address wide
    wire        word_read_request;
    wire        word_write_request;
    wire processor_ready;
    wire interrupt_to_cpu;
    wire address_latch_enable;
    wire address_direction;

    wire lock_n;
    wire [2:0]processor_status;

    wire [3:0]   dma_acknowledge_n;

    logic   [7:0]   port_b_out;
    logic   [7:0]   port_c_in;
    wire    [1:0]   fdd_present;
    reg     [7:0]   sw;

    wire    [5:0]   sw_base;
    wire    [1:0]   sw_floppy;

    // sw_base[5:4] is the motherboard video switch pair the BIOS copies into bits
    // 5:4 of the equipment word at 40:10. 2'b00 means "adapter with its own option
    // ROM" (EGA), 2'b10 means CGA 80x25. Loading the EGA BIOS is what installs the
    // card, so track it: otherwise the equipment word claims CGA and software that
    // trusts it, such as Titus The Fox, picks the CGA path and renders nothing.
    assign  sw_base = {ega_video_switches, 4'b1101};
    assign  sw_floppy = fdd_present[1] ? 2'b01 : 2'b00;
    assign  sw = {sw_floppy, sw_base}; // DIP switches (video adapter and floppy count)
    assign  port_c_in[3:0] = port_b_out[3] ? sw[7:4] : sw[3:0];


    wire ems_enabled_sel = `ENABLE_EMS ? eff_ems : 1'b0;
    wire [1:0] ems_address_sel = 2'b01; // Fixed D000 page frame avoids EGA and XT-IDE ROM conflicts.
    wire umb_enabled_sel = `ENABLE_UMB ? eff_umb : 1'b0;
    wire mpu401_enabled_sel = `ENABLE_MIDI ? eff_mpu401 : 1'b0;

    always @(posedge clk_chipset)
    begin
        if (address_latch_enable)
            cpu_address <= cpu_ad_out;
        else
            cpu_address <= cpu_address;
    end

    CHIPSET #(.clk_rate(cur_rate)) u_CHIPSET
	(
		.clock                              (clk_chipset),
		.cpu_ce_posedge                     (cpu_ce_posedge),
		.cpu_ce_negedge                     (cpu_ce_negedge),
		.clk_sys                            (clk_chipset),
		.peripheral_ce                      (peripheral_ce),
		.clk_select                         (clk_select),
		.reset                              (reset_cpu),
		.video_reset                        (video_retime_reset),
		.sdram_reset                        (reset_sdram),
		.cpu_address                        (cpu_address),
		.cpu_data_bus                       (cpu_data_bus),
		.processor_status                   (processor_status),
		.processor_lock_n                   (lock_n),
	//	.processor_transmit_or_receive_n    (processor_transmit_or_receive_n),
		.processor_ready                    (processor_ready),
		.interrupt_to_cpu                   (interrupt_to_cpu),
		.splashscreen                       (splashscreen),
		.std_hsyncwidth                     (std_hsyncwidth),
		.clk_video                        (clk_card_video),
		.de_o                               (de_o),
		.VGA_R                              (r),
		.VGA_G                              (g),
		.VGA_B                              (b),
		.VGA_HSYNC                          (HSync),
		.VGA_VSYNC                          (VSync),
		.VGA_HBlank                         (HBlank),
		.VGA_VBlank                         (VBlank),
		.VGA_VBlank_border                  (VGA_VBlank_border),
		.vga_mode13_osd                    (eff_vga13),
		.vga_mode13_native                 (vga_mode13_native_osd),
		.ega_monitor_profile               (ega_monitor_profile_applied),
		.vga_mode13_active_out             (vga_mode13_active_video),
		.vga_mode13_wide_clock_out         (vga_mode13_wide_clock),
		.vga_mode13_pixel_toggle_out        (vga_mode13_pixel_toggle),
	//	.address                            (address),
		.address_ext                        (bios_access_address),
		.ext_access_request                 (bios_access_request),
		.address_direction                  (address_direction),
		.data_bus                           (data_bus),
		// Private 16-bit SDRAM path, beside the public 8-bit chipset bus.
		.word_read_request                  (word_read_request),
		.word_write_request                 (word_write_request),
		.data_bus_word_in                   (cpu_data_bus_word),
		.data_bus_word                      (data_bus_word),
		.word_read_possible                 (word_read_possible),
		.data_bus_ext                       (bios_write_data[7:0]),
	//	.data_bus_direction                 (data_bus_direction),
		.address_latch_enable               (address_latch_enable),
	//  .io_channel_check                   (),
		.io_channel_ready                   (1'b1),
		.interrupt_request                  (0),    // use?	-> It does not seem to be necessary.
	//  .io_read_n                          (io_read_n),
		.io_read_n_ext                      (1'b1),
	//  .io_read_n_direction                (io_read_n_direction),
	//  .io_write_n                         (io_write_n),
		.io_write_n_ext                     (1'b1),
	//  .io_write_n_direction               (io_write_n_direction),
	//  .memory_read_n                      (memory_read_n),
		.memory_read_n_ext                  (1'b1),
	//  .memory_read_n_direction            (memory_read_n_direction),
	//  .memory_write_n                     (memory_write_n),
		.memory_write_n_ext                 (bios_write_n),
	//  .memory_write_n_direction           (memory_write_n_direction),
		.dma_request                        (0),    // use?	-> I don't know if it will ever be necessary, at least not during testing.
		.dma_acknowledge_n                  (dma_acknowledge_n),
	//  .address_enable_n                   (address_enable_n),
	//  .terminal_count_n                   (terminal_count_n)
		.port_b_out                         (port_b_out),
		.port_c_in                          (port_c_in),
		.port_b_in                          (port_b_out),
		.speaker_out                        (speaker_out),
		.ps2_clock                          (device_clock),
		.ps2_data                           (device_data),
		.ps2_clock_out                      (ps2_kbd_clk_out),
		.ps2_data_out                       (ps2_kbd_data_out),
		.ps2_mouseclk_in                    (ps2_mouse_clk_out),
		.ps2_mousedat_in                    (ps2_mouse_data_out),
		.ps2_mouseclk_out                   (ps2_mouse_clk_in),
		.ps2_mousedat_out                   (ps2_mouse_data_in),
		.joy_opts                           (joy_opts),           //Joy0-Disabled, Joy0-Type, Joy1-Disabled, Joy1-Type, turbo_sync
		.joy0                               (eff_joy_swap ? joy1 : joy0),
		.joy1                               (eff_joy_swap ? joy0 : joy1),
		.joya0                              (eff_joy_swap ? joya1 : joya0),
		.joya1                              (eff_joy_swap ? joya0 : joya1),
		.jtopl2_snd_e                       (jtopl2_snd_e),
		.tandy_snd_e                        (tandy_snd_e),
		.tandy_en                           (eff_tandy),
		.opl2_io                            (eff_opl2),
		.sb_en                              (eff_sb),
		.sb_irq7                            (sb_irq7),
		.sb_snd_l                           (sb_snd_l),
		.sb_snd_r                           (sb_snd_r),
		.cms_en                             (eff_cms),
		.o_cms_l                            (cms_l_snd_e),
		.o_cms_r                            (cms_r_snd_e),
		.clk_uart                           (clk_uart2_en),
		.uart2_rx                           (uart_rx),
		.uart2_tx                           (uart_tx),
		.uart2_cts_n                        (uart_cts),
		.uart2_dcd_n                        (uart_dcd),
		.uart2_dsr_n                        (uart_dsr),
		.uart2_rts_n                        (uart_rts),
		.uart2_dtr_n                        (uart_dtr),
		.clk_midi                           (clk_midi_en),
		.midi_rx                            (midi_rx),
		.midi_tx                            (midi_tx),
		.mpu401_enabled                     (mpu401_enabled_sel),
		.enable_sdram                       (1'b1),
		.initilized_sdram                   (initilized_sdram),
		.sdram_clock                        (SDRAM_CLK),
		.sdram_address                      (SDRAM_A),
		.sdram_cke                          (SDRAM_CKE),
		.sdram_cs                           (SDRAM_nCS),
		.sdram_ras                          (SDRAM_nRAS),
		.sdram_cas                          (SDRAM_nCAS),
		.sdram_we                           (SDRAM_nWE),
		.sdram_ba                           (SDRAM_BA),
		.sdram_dq_in                        (SDRAM_DQ_IN),
		.sdram_dq_out                       (SDRAM_DQ_OUT),
		.sdram_dq_io                        (SDRAM_DQ_IO),
		.sdram_ldqm                         (SDRAM_DQML),
		.sdram_udqm                         (SDRAM_DQMH),
		.ems_enabled                        (ems_enabled_sel),
		.ems_address                        (ems_address_sel),
		.umb_enabled                        (umb_enabled_sel),
		.bios_protect_flag                  (bios_protect_flag),
		.use_mmc                            (use_mmc),
		.spi_clk                            (spi_clk),
		.spi_cs                             (spi_cs),
		.spi_mosi                           (spi_mosi),
		.spi_miso                           (spi_miso),
		.mgmt_readdata                      (mgmt_din),
		.mgmt_writedata                     (mgmt_dout),
		.mgmt_address                       (mgmt_addr),
		.mgmt_write                         (mgmt_wr),
		.mgmt_read                          (mgmt_rd),
		.floppy_wp                          (status[20:19]),
		.fdd_present                        (fdd_present),
		.fdd_request                        (mgmt_req[7:6]),
		.ide0_request                       (mgmt_req[2:0]),
		.xtegactl_cpu                       (xtegactl_cpu),
		.xtegactl_exp                       (xtegactl_exp),
		.xtegactl_vid                       (xtegactl_vid),
		.xtegactl_inp                       (xtegactl_inp),
		.xtegactl_midi                      (xtegactl_midi),
		.xtegactl_exp2                      (xtegactl_exp2),
		.xtegactl_crt                       (xtegactl_crt),
		.xtegactl_sync                      (xtegactl_sync),
		.xtegactl_status_effective          (xtegactl_status_effective),
		.xtegactl_status_osd_match          (xtegactl_status_osd_match),
		.wait_count_clk_en                  (cpu_ce_negedge),
		.ram_read_wait_cycle                (ram_read_wait_cycle),
		.ram_write_wait_cycle               (ram_write_wait_cycle),
		.pause_core                         (pause_core),
		.video_scandoubler_en                  (video_scandoubler_en),
		.ega_dot_toggle                     (ega_dot_toggle),
		.ega_dot_clock_sel                  (ega_dot_clock_sel),
		.ega_scandouble_active              (ega_scandouble_active),
		.ega_vmode_toggle_out               (ega_vmode_toggle),
		.ega_mode350                        (ega_mode350),
		.ega_active_dots                    (ega_active_dots),
		.ega_active_lines                   (ega_active_lines),
		.crt_h_offset                       (eff_crt_h),
		.crt_v_offset                       (eff_crt_v),
		.vsync_width_osd                    (vsync_width_osd),
		.hsync_width_osd                    (hsync_width_osd)
	);

    wire [15:0] SDRAM_DQ_IN;
    wire [15:0] SDRAM_DQ_OUT;
    wire        SDRAM_DQ_IO;
    wire        initilized_sdram;

    // MEGA65: no pin tristate; the data-in and data-out halves are exported separately
    assign SDRAM_DQ_IN = sdram_dq_in_i;

    wire s6_3_mux;
    wire [2:0] SEGMENT;

    i8088 B1 	
	(
		.CORE_CLK(clk_100),
		.CLK(clk_cpu),

		.RESET(reset_cpu),
		.READY(processor_ready && ~pause_core),
		.NMI(1'b0),
		.INTR(interrupt_to_cpu),

		.ad_out(cpu_ad_out),
		.dout(cpu_data_bus),
		.din(data_bus),

		.lock_n(lock_n),
		.s6_3_mux(s6_3_mux),
		.s2_s0_out(processor_status),
		.SEGMENT(SEGMENT),

		.biu_done(biu_done),
		.cycle_accrate(cycle_accrate),
		.clock_cycle_counter_division_ratio(clock_cycle_counter_division_ratio),
		.clock_cycle_counter_decrement_value(clock_cycle_counter_decrement_value),
		.shift_read_timing(shift_read_timing),

		// The CPU type is frozen outside reset so queue depth and bus width
		// cannot change in the middle of an instruction or bus cycle. Fake 286
		// FLAGS carries no such state and tracks the menu as it is changed.
		.is8086(is8086_applied),
		.fake286_flags(fake_286_flags_applied),
		.word_read_request(word_read_request),
		.word_write_request(word_write_request),
		.data_bus_word_out(cpu_data_bus_word),
		.data_bus_word(data_bus_word),
		.word_access_possible(word_read_possible)
	);

    //
    ////////////////////////////  AUDIO  ///////////////////////////////////
    //

    wire [15:0] cms_l_snd_e;
    wire [16:0] cms_l_snd = {cms_l_snd_e[15],cms_l_snd_e};
    wire [15:0] cms_r_snd_e;
    wire [16:0] cms_r_snd = {cms_r_snd_e[15],cms_r_snd_e};
	 
    // Sound Blaster Pro: DAC and FM together, after its own mixer. When the
    // card is switched off this is the OPL2 passed through untouched, and
    // jtopl2_snd below is zero - the FM only ever reaches the sum once.
    wire [15:0] sb_snd_l, sb_snd_r;
    wire [16:0] sb_l_snd = {sb_snd_l[15], sb_snd_l};
    wire [16:0] sb_r_snd = {sb_snd_r[15], sb_snd_r};

    wire [15:0] jtopl2_snd_e;
    wire [16:0] jtopl2_snd = {jtopl2_snd_e[15], jtopl2_snd_e};
    // Tandy 1000 sound. Sign-extended from 11 bits and scaled the way the
    // parent PCXT does it, except for where the level comes from: the parent
    // has a "Tandy Volume" menu option and this fork has no status bit left to
    // spend on one, so it rides the Speaker Volume setting instead. Both are
    // internal beeper-class sources, and turning one down without the other is
    // not something a user is likely to want.
    wire [10:0] tandy_snd_e;
    wire [16:0] tandy_snd = `ENABLE_TANDY_AUDIO
        ? {{{2{tandy_snd_e[10]}}, {4{tandy_snd_e[10]}}, tandy_snd_e} << status[33:32], 2'b00}
        : 17'd0;
    wire [16:0] spk_vol =  {2'b00, {3'b000,~speaker_out} << status[33:32], 11'd0};
    wire        speaker_out;

    localparam [3:0] comp_f1 = 4;
    localparam [3:0] comp_a1 = 2;
    localparam       comp_x1 = ((32767 * (comp_f1 - 1)) / ((comp_f1 * comp_a1) - 1)) + 1; // +1 to make sure it won't overflow
    localparam       comp_b1 = comp_x1 * comp_a1;

    localparam [3:0] comp_f2 = 8;
    localparam [3:0] comp_a2 = 4;
    localparam       comp_x2 = ((32767 * (comp_f2 - 1)) / ((comp_f2 * comp_a2) - 1)) + 1; // +1 to make sure it won't overflow
    localparam       comp_b2 = comp_x2 * comp_a2;

    function [15:0] compr;
        input [15:0] inp;
        reg [15:0] v, v1, v2;
        begin
            v  = inp[15] ? (~inp) + 1'd1 : inp;
            v1 = (v < comp_x1[15:0]) ? (v * comp_a1) : (((v - comp_x1[15:0])/comp_f1) + comp_b1[15:0]);
            v2 = (v < comp_x2[15:0]) ? (v * comp_a2) : (((v - comp_x2[15:0])/comp_f2) + comp_b2[15:0]);
            v  = status[37] ? v2 : v1;
            compr = inp[15] ? ~(v-1'd1) : v;
        end
    endfunction

    reg [15:0] cmp_l;
    reg [15:0] out_l;
    always @(posedge clk_chipset)
    begin
        reg [16:0] tmp_l;

        tmp_l <= jtopl2_snd + cms_l_snd + tandy_snd + spk_vol + mt32_l_snd + sb_l_snd;

        // clamp the output
        out_l <= (^tmp_l[16:15]) ? {tmp_l[16], {15{tmp_l[15]}}} : tmp_l[15:0];

        cmp_l <= compr(out_l);
    end
	 
    reg [15:0] cmp_r;
    reg [15:0] out_r;
    always @(posedge clk_chipset)
    begin
        reg [16:0] tmp_r;

        tmp_r <= jtopl2_snd + cms_r_snd + tandy_snd + spk_vol + mt32_r_snd + sb_r_snd;

        // clamp the output
        out_r <= (^tmp_r[16:15]) ? {tmp_r[16], {15{tmp_r[15]}}} : tmp_r[15:0];

        cmp_r <= compr(out_r);
    end

    assign AUDIO_L   = pause_core ? 1'b0 : status[37:36] ? cmp_l : out_l;
    assign AUDIO_R   = pause_core ? 1'b0 : status[37:36] ? cmp_r : out_r;
    assign AUDIO_MIX = status[39:38];

    //
    ////////////////////////////  UART  ///////////////////////////////////
    //

    //assign USER_OUT = {1'b1, 1'b1, uart_dtr, 1'b1, uart_rts, uart_tx, 1'b1};

    //
    // Pin | USB Name |   |Signal
    // ----+----------+---+-------------
    // 0   | D+       | I |RX
    // 1   | D-       | O |TX
    // 2   | TX-      | O |RTS
    // 3   | GND_d    | I |CTS
    // 4   | RX+      | O |DTR
    // 5   | RX-      | I |DSR
    // 6   | TX+      | I |DCD
    //

    logic clk_uart_ff_1;
    logic clk_uart_ff_2;
    logic clk_uart_ff_3;
    logic clk_uart_en;
    logic clk_uart2_en;
    logic [2:0] clk_uart2_counter;

    // MIDI baud reference for the MPU-401. Derived straight from the 50MHz
    // clk_chipset rather than the 14.318MHz UART reference, because 50MHz
    // divides exactly: 50e6 / (4 * 16 * 25) = 31250 baud, zero error.
    // (The 14.318MHz path can only reach 30858 baud, -1.25%.) ao486 likewise
    // feeds its MPU a dedicated exact-rate clock instead of the COM reference.
    logic [1:0] clk_midi_counter = 2'd0;
    logic       clk_midi_en = 1'b0;

    always @(posedge clk_chipset)
    begin
        if (clk_midi_counter == 2'd3)
        begin
            clk_midi_counter <= 2'd0;
            clk_midi_en      <= 1'b1;
        end
        else
        begin
            clk_midi_counter <= clk_midi_counter + 2'd1;
            clk_midi_en      <= 1'b0;
        end
    end

    always @(posedge clk_chipset)
    begin
        clk_uart_ff_1 <= clk_14_318;
        clk_uart_ff_2 <= clk_uart_ff_1;
        clk_uart_ff_3 <= clk_uart_ff_2;
        clk_uart_en   <= ~clk_uart_ff_3 & clk_uart_ff_2;
    end

    always @(posedge clk_chipset)
    begin
        if (clk_uart_en)
        begin
            if (3'd7 != clk_uart2_counter)
            begin
                clk_uart2_counter <= clk_uart2_counter +3'd1;
                clk_uart2_en <= 1'b0;
            end
            else
            begin
                clk_uart2_counter <= 3'd0;
                clk_uart2_en <= 1'b1;
            end
        end
        else
        begin
            clk_uart2_counter <= clk_uart2_counter;
            clk_uart2_en <= 1'b0;
        end
    end

    wire uart_tx, uart_rts, uart_dtr;

    // Selecting MIDI in the MiSTer UART menu hands these pins to the HPS, which
    // bridges them to a USB MIDI device. That gives the MPU-401 a second possible
    // destination besides the mt32-pi on the user port, and is the only way to
    // reach a USB MIDI interface - the user port cannot see one. ao486 gates the
    // same way on uart_mode >= 3.
    //
    // COM2, not COM1, is what normally owns these pins here (COM1 is the internal
    // serial mouse), so COM2 is the port that has to let go of them.
    wire hps_midi = `ENABLE_MIDI && (uart_mode >= 8'd3);

    assign UART_TXD = hps_midi ? midi_tx : uart_tx;
    assign UART_RTS = ~hps_midi & uart_rts;
    assign UART_DTR = ~hps_midi & uart_dtr;

    // Idle high, never low: a UART input held at 0 is a break condition, the same
    // trap the USER_OUT default fell into. Holding DCD deasserted also keeps the
    // handover from looking like a carrier transition to a guest with COM2 open.
    wire uart_rx  = hps_midi | UART_RXD;
    wire uart_cts = hps_midi | UART_CTS;
    wire uart_dsr = hps_midi | UART_DSR;
    wire uart_dcd = hps_midi | UART_DTR;


    /// UART2

    // USER_IO is time-shared between the COM2 passthrough (default) and the
    // MT32-pi bridge below - only one can be connected at a time.
    // Default (0) is MT32-pi, matching ao486: at core load, before the saved
    // config arrives, we must already be in the safe non-driving state.
    wire user_io_mt32 = `ENABLE_MIDI && ~status[6];

    // The COM2-over-USER_IO path is dead code in this core: uart2_tx/rts/dtr have
    // no driver, so they synthesise to constant 0 and would actively pull pins
    // 1, 2 and 4 low. Pins 2 and 4 are *outputs* of an attached mt32-pi (I2S), so
    // that is a direct output-vs-output contention, and pin 1 low is a permanent
    // MIDI break. COM2 is also the power-on default before the saved config is
    // applied, so this happened on every core load. Release the pins instead;
    // ao486 never hits this because its COM2 signals are real and idle high.
    // MEGA65: no user port, USER_OUT is gone.

    //
    // Pin | USB Name |   |Signal
    // ----+----------+---+-------------
    // 0   | D+       | I |RX
    // 1   | D-       | O |TX
    // 2   | TX-      | O |RTS
    // 3   | GND_d    | I |CTS
    // 4   | RX+      | O |DTR
    // 5   | RX-      | I |DSR
    // 6   | TX+      | I |DCD
    //

    wire uart2_tx, uart2_rts, uart2_dtr;

    wire uart2_rx  = user_io_mt32 | USER_IN[0];
    wire uart2_cts = user_io_mt32 | USER_IN[3];
    wire uart2_dsr = user_io_mt32 | USER_IN[5];
    wire uart2_dcd = user_io_mt32 | USER_IN[6];

    //
    ////////////////////////////  MT32-pi  //////////////////////////////////
    //
    // MEGA65: there is no user port, so no mt32-pi. The MPU-401 still exists
    // for games that probe 330h: midi_tx transmits into the void and midi_rx
    // idles high (a UART input held low would be a break condition).
    //

    wire        mt32_available = 1'b0;
    wire        midi_tx;              // driven by the CHIPSET's mpu401 instance
    wire        midi_rx = 1'b1;
    wire [16:0] mt32_l_snd = 17'd0;
    wire [16:0] mt32_r_snd = 17'd0;

    //
    ///////////////////////   MMC     ///////////////////////
    //
    logic [1:0]  use_mmc;
    logic spi_clk;
    logic spi_cs;
    logic spi_mosi;
    logic spi_miso;

    always @(posedge clk_chipset)
        if (reset)
            use_mmc <= status[22:21];
        else
            use_mmc <= use_mmc;

    // Every menu option that is sampled only while reset is asserted. Each one
    // exposes both the selection and what the machine is actually running on,
    // so a plain comparison is all "pending" means. It reads false throughout
    // reset, because that is exactly when the latches track their source, so
    // this cannot fire on the way out of a cold boot.
    wire reset_pending = (cpu_type_8086_osd       != is8086_applied)
                       | (ega_monitor_profile_osd != ega_monitor_profile_applied)
                       | (status[22:21]           != use_mmc);

    reset_pending_notice reset_notice (
        .clock      (clk_14_318),
        .pending    (reset_pending),
        .osd_status (OSD_STATUS),
        .suppress   (bios_hold),
        .info       (pending_info),
        .info_req   (pending_info_req)
    );

    // MEGA65: no second SD card. spi_clk/cs/mosi stay internal; MISO idles high.
    assign  spi_miso    = SD_MISO;

    //
    ///////////////////////   VIDEO   ///////////////////////
    //

    wire HBlank;
    wire HSync;
    wire VBlank;
    wire VSync;
    wire de_o;
    wire [5:0] r, g, b;
    reg [7:0] raux_video, gaux_video, baux_video;
	 wire [7:0] VGA_R_AUX, VGA_G_AUX, VGA_B_AUX;
    wire CLK_VIDEO_PIPELINE;
    wire CE_PIXEL_CREDITS;

    // MEGA65: driven by the inline video_mixer replacement below, so regs
    reg   [7:0] VGA_R_video;
    reg   [7:0] VGA_G_video;
    reg   [7:0] VGA_B_video;
    reg         VGA_HS_video;
    reg         VGA_VS_video;
    reg         VGA_DE_video;
    reg         CE_PIXEL_video;
    reg         ce_pixel_28 = 1'b0;
    wire        vga_video_direct = vga_mode13_active_video;

    // The EGA dot rate is no longer a fixed 14.318 MHz: in the 16.257 MHz
    // modes consecutive dots can land on adjacent clk_28_636 edges, which in
    // this domain would be a single wide level with only one rising edge.  The
    // EGA exports a toggle instead, one flip per dot.  Exactly one
    // synchroniser stage before the XOR: both clocks come from pll_system with
    // a 2:1 ratio and no phase shift, and a second stage would push the enable
    // past the end of the short dots of the 16.257 MHz pattern.
    reg         ega_dot_toggle_d = 1'b0;
    reg         ega_dot_toggle_dd = 1'b0;

    always @(posedge clk_57_272)
    begin
        ega_dot_toggle_d  <= ega_dot_toggle;
        ega_dot_toggle_dd <= ega_dot_toggle_d;
    end

    wire        ce_pixel_dot = ega_dot_toggle_d ^ ega_dot_toggle_dd;

    // vga_mode13_active_video drives either the Native VGA or 15 kHz CRT-TV
    // raster (rtl/video/vga_mode13_timing.v), whose real pixel rate is one
    // flip per displayed pixel, not per video-clock cycle. Same
    // toggle-crossing idiom as ce_pixel_dot above, so the framework's
    // active-window measurement (the OSD Information line) reports the real
    // pixel count instead of the raw dot-clock count.
    reg         vga_mode13_pixel_toggle_d = 1'b0;
    reg         vga_mode13_pixel_toggle_dd = 1'b0;

    always @(posedge clk_57_272)
    begin
        vga_mode13_pixel_toggle_d  <= vga_mode13_pixel_toggle;
        vga_mode13_pixel_toggle_dd <= vga_mode13_pixel_toggle_d;
    end

    wire        ce_pixel_mode13 = vga_mode13_pixel_toggle_d ^ vga_mode13_pixel_toggle_dd;
    wire        ce_pixel_video = ega_scandouble_active ? ce_pixel_28
                                : vga_video_direct       ? ce_pixel_mode13
                                : ce_pixel_dot;

    reg  [7:0]  VGA_R_video_src = 8'd0;
    reg  [7:0]  VGA_G_video_src = 8'd0;
    reg  [7:0]  VGA_B_video_src = 8'd0;
    reg         VGA_HS_video_src = 1'b0;
    reg         VGA_VS_video_src = 1'b0;
    reg         VGA_DE_video_src = 1'b0;
    reg         LHBL_video_src = 1'b1;
    reg         LVBL_video_src = 1'b1;
    reg         CE_PIXEL_video_src = 1'b0;
    reg  [7:0]  VGA_R_video_ps = 8'd0;
    reg  [7:0]  VGA_G_video_ps = 8'd0;
    reg  [7:0]  VGA_B_video_ps = 8'd0;
    reg         VGA_HS_video_ps = 1'b0;
    reg         VGA_VS_video_ps = 1'b0;
    reg         VGA_DE_video_ps = 1'b0;
    reg         LHBL_video_ps = 1'b1;
    reg         LVBL_video_ps = 1'b1;
    reg         CE_PIXEL_video_ps = 1'b0;
    reg         CE_PIXEL_video_ps_d = 1'b0;
    reg  [7:0]  VGA_R_video_hdmi, VGA_G_video_hdmi, VGA_B_video_hdmi;
    reg         VGA_HS_video_hdmi, VGA_VS_video_hdmi, VGA_DE_video_hdmi;
    reg         LHBL_video_hdmi, LVBL_video_hdmi;
    reg         CE_PIXEL_video_hdmi = 1'b0;

    assign CLK_VIDEO = clk_video_out_ps;
    assign CLK_VIDEO_PIPELINE = clk_57_272;

    always @(posedge clk_57_272)
        ce_pixel_28 <= ~ce_pixel_28;

    assign VGA_SL = {scale_video_ff==3, scale_video_ff==2};

    wire   scandoubler = video_scandoubler_en;

    wire color = (screen_mode_video_ff == 3'd0);

    // The credits are the reason to pause at all, so they follow the splash
    // hold as well as the machine's own pause key.  Only the overlay does:
    // audio and CPU ready still key off pause_core alone, because during the
    // splash there is no machine running to silence or stall.
    reg        video_credits_show_buf;
    reg        video_credits_show;

    always @ (posedge clk_video_out_ps) begin
        video_credits_show_buf  <= pause_core | splash_paused;
        video_credits_show      <= video_credits_show_buf;
    end

    wire LHBL = (ega_scandouble_active || vga_video_direct) ? HBlank : ~de_o;
    wire LVBL = VBlank;

    wire haux_video, vaux_video, hbaux_video, vbaux_video;

    // Sync and blanking go through the converter with the colour so they come
    // out of it with the same delay.  Mode 13h only takes the undelayed pair
    // below in Full Color: once a monochrome Display option is picked it has
    // to run through the converter like every other mode, both for the tint
    // and to stay time-aligned with it, or the picture is full colour again.
    video_monochrome_converter video_mono
	(
		.clk_vid(CLK_VIDEO_PIPELINE),
		.ce_pix(ce_pixel_video),

		.R({r, 2'b00}),
		.G({g, 2'b00}),
		.B({b, 2'b00}),

		.HSync(HSync),
		.VSync(VSync),
		.HBlank(LHBL),
		.VBlank(LVBL),

		.gfx_mode(screen_mode_video_ff),

		.R_OUT(raux_video),
		.G_OUT(gaux_video),
		.B_OUT(baux_video),

		.HSync_OUT(haux_video),
		.VSync_OUT(vaux_video),
		.HBlank_OUT(hbaux_video),
		.VBlank_OUT(vbaux_video)
	);

    wire       pre2x_LHBL, pre2x_LVBL;
    wire [7:0] pre2x_r, pre2x_g, pre2x_b;
    wire [23:0] credits_rgb_out;
    wire vga_video_direct_color = vga_video_direct && color;
    wire [7:0] bypass_r = vga_video_direct_color ? {r, r[5:4]} : raux_video;
    wire [7:0] bypass_g = vga_video_direct_color ? {g, g[5:4]} : gaux_video;
    wire [7:0] bypass_b = vga_video_direct_color ? {b, b[5:4]} : baux_video;
    wire bypass_hs = vga_video_direct_color ? HSync : haux_video;
    wire bypass_vs = vga_video_direct_color ? VSync : vaux_video;
    wire bypass_hb = vga_video_direct_color ? LHBL  : hbaux_video;
    wire bypass_vb = vga_video_direct_color ? LVBL  : vbaux_video;

    // MEGA65: the 350-line DDRAM framebuffer path (ega_fb_capture,
    // ega_fb_readout, ega_ddr_arbiter, video_source_switch, VGA_F1) is gone;
    // the MEGA65 scaler takes the 21.8 kHz raster as it is. Its source muxes
    // collapse to the bypass.
    wire [7:0] video_mixer_r = bypass_r;
    wire [7:0] video_mixer_g = bypass_g;
    wire [7:0] video_mixer_b = bypass_b;
    wire video_mixer_hs = bypass_hs;
    wire video_mixer_vs = bypass_vs;
    wire video_mixer_hb = bypass_hb;
    wire video_mixer_vb = bypass_vb;
    wire ce_pixel_mixer = ce_pixel_video;

    // The credits overlay and the framework's active-window measurement follow
    // whichever raster is actually being emitted.
    wire LHBL_out = LHBL;
    wire LVBL_out = LVBL;


    // MEGA65: sys/video_mixer.sv #(.GAMMA(1)) replaced by an inline copy of
    // what it does with scandoubler=0, HDMI_FREEZE=0 and no gamma table
    // (gamma_en=0), stage for stage so nothing downstream moves by a pixel:
    //  1. video_freezer: a plain pass-through while not frozen (no register).
    //  2. gamma_corr: even with gamma_en=0 it re-registers RGB, sync and
    //     blank on the rising edge of ce_pix, one pixel behind
    //     (sys/gamma_corr.sv, the gamma_en=0 branch of RGB_out).
    //  3. the mixer output stage (sys/video_mixer.sv:172-217): one clock
    //     register, then a CE_PIXEL-gated one, with VGA_DE updated on the
    //     HBlank edges only and CE_PIXEL reduced to the rising edge of ce_pix
    //     once a frame has shown ce_pix to be a level rather than a pulse.
    reg [7:0] mixer_R_gamma, mixer_G_gamma, mixer_B_gamma;
    reg       mixer_hs_g, mixer_vs_g, mixer_hb_g, mixer_vb_g;

    always @(posedge CLK_VIDEO_PIPELINE) begin : video_mixer_gamma_stage
        reg [7:0] R_in, G_in, B_in;
        reg       hs, vs, hb, vb;
        reg       old_ce;

        old_ce <= ce_pixel_mixer;
        if (~old_ce & ce_pixel_mixer) begin
            {R_in, G_in, B_in} <= {video_mixer_r, video_mixer_g, video_mixer_b};
            hs <= video_mixer_hs; vs <= video_mixer_vs;
            hb <= video_mixer_hb; vb <= video_mixer_vb;

            {mixer_R_gamma, mixer_G_gamma, mixer_B_gamma} <= {R_in, G_in, B_in};
            mixer_hs_g <= hs; mixer_vs_g <= vs;
            mixer_hb_g <= hb; mixer_vb_g <= vb;
        end
    end

    always @(posedge CLK_VIDEO_PIPELINE) begin : video_mixer_output_stage
        reg [7:0] r, g, b;
        reg       hde, vde, hs, vs, old_vs;
        reg       old_hde;
        reg       old_ce;
        reg       ce_osc, fs_osc;

        old_ce <= ce_pixel_mixer;
        ce_osc <= ce_osc | (old_ce ^ ce_pixel_mixer);

        old_vs <= vs;
        if (~old_vs & vs) begin
            fs_osc <= ce_osc;
            ce_osc <= 0;
        end

        CE_PIXEL_video <= fs_osc ? (~old_ce & ce_pixel_mixer) : ce_pixel_mixer;

        r <= mixer_R_gamma;
        g <= mixer_G_gamma;
        b <= mixer_B_gamma;

        hde <= ~mixer_hb_g;
        vde <= ~mixer_vb_g;
        vs  <=  mixer_vs_g;
        hs  <=  mixer_hs_g;

        if (CE_PIXEL_video) begin
            VGA_R_video <= r;
            VGA_G_video <= g;
            VGA_B_video <= b;

            VGA_VS_video <= vs;
            VGA_HS_video <= hs;

            old_hde <= hde;
            if (old_hde ^ hde) VGA_DE_video <= vde & hde;
        end
    end

    always @(posedge clk_57_272)
    begin
        VGA_R_video_src <= VGA_R_video;
        VGA_G_video_src <= VGA_G_video;
        VGA_B_video_src <= VGA_B_video;
        VGA_HS_video_src <= VGA_HS_video;
        VGA_VS_video_src <= VGA_VS_video;
        VGA_DE_video_src <= VGA_DE_video;
        LHBL_video_src <= LHBL_out;
        LVBL_video_src <= LVBL_out;
        CE_PIXEL_video_src <= CE_PIXEL_video;
    end

    // Retimes the exact-frequency video output onto a phase-shifted sibling clock.
    always @(posedge clk_video_out_ps or posedge video_retime_reset_local)
    begin
        if (video_retime_reset_local)
        begin
            VGA_R_video_ps <= 8'd0;
            VGA_G_video_ps <= 8'd0;
            VGA_B_video_ps <= 8'd0;
            VGA_HS_video_ps <= 1'b0;
            VGA_VS_video_ps <= 1'b0;
            VGA_DE_video_ps <= 1'b0;
            LHBL_video_ps <= 1'b1;
            LVBL_video_ps <= 1'b1;
            CE_PIXEL_video_ps <= 1'b0;
            CE_PIXEL_video_ps_d <= 1'b0;
            VGA_R_video_hdmi <= 8'd0;
            VGA_G_video_hdmi <= 8'd0;
            VGA_B_video_hdmi <= 8'd0;
            VGA_HS_video_hdmi <= 1'b0;
            VGA_VS_video_hdmi <= 1'b0;
            VGA_DE_video_hdmi <= 1'b0;
            LHBL_video_hdmi <= 1'b1;
            LVBL_video_hdmi <= 1'b1;
            CE_PIXEL_video_hdmi <= 1'b0;
        end
        else
        begin
            CE_PIXEL_video_hdmi <= CE_PIXEL_video_ps & ~CE_PIXEL_video_ps_d;
            if (CE_PIXEL_video_ps & ~CE_PIXEL_video_ps_d)
            begin
                VGA_R_video_hdmi <= VGA_R_video_ps;
                VGA_G_video_hdmi <= VGA_G_video_ps;
                VGA_B_video_hdmi <= VGA_B_video_ps;
                VGA_HS_video_hdmi <= VGA_HS_video_ps;
                VGA_VS_video_hdmi <= VGA_VS_video_ps;
                VGA_DE_video_hdmi <= VGA_DE_video_ps;
                LHBL_video_hdmi <= LHBL_video_ps;
                LVBL_video_hdmi <= LVBL_video_ps;
            end

            CE_PIXEL_video_ps_d <= CE_PIXEL_video_ps;
            CE_PIXEL_video_ps <= CE_PIXEL_video_src;
            VGA_R_video_ps <= VGA_R_video_src;
            VGA_G_video_ps <= VGA_G_video_src;
            VGA_B_video_ps <= VGA_B_video_src;
            VGA_HS_video_ps <= VGA_HS_video_src;
            VGA_VS_video_ps <= VGA_VS_video_src;
            VGA_DE_video_ps <= VGA_DE_video_src;
            LHBL_video_ps <= LHBL_video_src;
            LVBL_video_ps <= LVBL_video_src;
        end
    end

    assign VGA_R_AUX  =  VGA_R_video_hdmi;
    assign VGA_G_AUX  =  VGA_G_video_hdmi;
    assign VGA_B_AUX  =  VGA_B_video_hdmi;
    assign VGA_HS =  VGA_HS_video_hdmi;
    assign VGA_VS =  VGA_VS_video_hdmi;
    assign CE_PIXEL  =  CE_PIXEL_video_hdmi;
    assign CE_PIXEL_CREDITS = CE_PIXEL_video_hdmi;
    wire credits_hb = LHBL_video_hdmi;
    wire credits_vb = LVBL_video_hdmi;
    jtframe_credits #(
        .PAGES  (4),
        .COLW   (8),
        .BLKPOL (1)
    // Reset from the domain it actually runs in.  The machine's reset is held
    // for as long as the splash is on screen, which would have kept the
    // overlay blank exactly where it is now wanted.  Nothing is lost by the
    // change: the scroll position is re-seeded on every rising edge of
    // enable regardless, so each pause still starts the credits from the top.
    ) u_credits(
        .rst        ( video_retime_reset_local ),
        .clk        ( clk_video_out_ps ),
        .pxl_cen    ( CE_PIXEL_CREDITS ),

        // input image
        .HB         ( credits_hb  ),
        .VB         ( credits_vb ),
        .rgb_in     ( { VGA_R_AUX, VGA_G_AUX, VGA_B_AUX } ),
        .rotate     ( 2'd0  ),
        .toggle     ( 1'b0  ),
        .fast_scroll( 1'b0  ),
        .border     ( 1'b0 ),

        .vram_din   ( 8'h0  ),
        .vram_dout  (       ),
        .vram_addr  ( 8'h0  ),
        .vram_we    ( 1'b0  ),
        .vram_ctrl  ( 3'b0  ),
        .enable     ( video_credits_show ),

        // output image
        .HB_out     ( pre2x_LHBL      ),
        .VB_out     ( pre2x_LVBL      ),
        .rgb_out    ( credits_rgb_out )
    );

    // The credits block registers RGB once on CE_PIXEL, even while its overlay
    // is disabled.  Register the already-processed DE on that same event; using
    // VGA_DE_video_hdmi directly opens the active window one pixel before the
    // corresponding credits_rgb_out sample and clips the last pixel instead.
    reg VGA_DE_credits = 1'b0;
    always @(posedge clk_video_out_ps or posedge video_retime_reset_local) begin
        if (video_retime_reset_local)
            VGA_DE_credits <= 1'b0;
        else if (CE_PIXEL_CREDITS)
            VGA_DE_credits <= VGA_DE_video_hdmi;
    end

    assign VGA_DE = VGA_DE_credits;
    assign {VGA_R, VGA_G, VGA_B} = credits_rgb_out;


    //
    ///////////////////////   MEGA65 PORTS   ///////////////////////
    //
    // Everything the MiSTer framework used to take from `emu`, now as ports.

    // video: the upstream CLK_VIDEO / CE_PIXEL sampling contract is kept
    assign video_clk_o    = CLK_VIDEO;
    assign video_ce_o     = CE_PIXEL;
    assign video_red_o    = VGA_R;
    assign video_green_o  = VGA_G;
    assign video_blue_o   = VGA_B;
    assign video_hs_o     = VGA_HS;
    assign video_vs_o     = VGA_VS;
    // blanking as the credits overlay emits it, aligned with VGA_R/G/B and VGA_DE
    assign video_hblank_o = pre2x_LHBL;
    assign video_vblank_o = pre2x_LVBL;
    assign video_de_o     = VGA_DE;
    // hints for the scaler (the geometry ones are raw chipset outputs in clk_card_video)
    assign video_mode13_o            = vga_mode13_active_video;
    assign video_mode13_native_clk_o = vga_native_standard_clock;
    assign video_mode350_o           = ega_mode350;
    assign video_active_dots_o       = ega_active_dots;
    assign video_active_lines_o      = ega_active_lines;
    assign video_aspect_o            = ar;
    assign video_scanlines_o         = VGA_SL;

    // audio
    assign audio_left_o  = AUDIO_L;
    assign audio_right_o = AUDIO_R;
    assign audio_mix_o   = AUDIO_MIX;

    // status for the OSM / help screen
    assign bios_missing_pcxt_o = bios_missing_pcxt;
    assign bios_missing_ega_o  = bios_missing_ega;
    assign reset_pending_o     = reset_pending;
    assign pause_o             = pause_core;
    assign splash_active_o     = splashscreen;

    // the CHIPSET's SDRAM pins (signal map 3.7a)
    assign sdram_a_o           = SDRAM_A;
    assign sdram_ba_o          = SDRAM_BA;
    assign sdram_cke_o         = SDRAM_CKE;
    assign sdram_ncs_o         = SDRAM_nCS;
    assign sdram_nras_o        = SDRAM_nRAS;
    assign sdram_ncas_o        = SDRAM_nCAS;
    assign sdram_nwe_o         = SDRAM_nWE;
    assign sdram_dq_out_o      = SDRAM_DQ_OUT;
    assign sdram_dq_io_o       = SDRAM_DQ_IO;
    assign sdram_dqml_o        = SDRAM_DQML;
    assign sdram_dqmh_o        = SDRAM_DQMH;
    assign sdram_initialized_o = initilized_sdram;

    // storage
    assign fdd_present_o = fdd_present;
    assign led_disk_o    = |mgmt_req[7:6] | |mgmt_req[2:0];
    assign dbg_de_o      = de_o;
    assign dbg_hb_o      = HBlank;
    assign dbg_vb_o      = VBlank;

    // floppy CPU<->FDC path probes (hierarchical taps; no submodule edit)
    wire fdc_iowr   = u_CHIPSET.u_PERIPHERALS.fdd_io_write;
    wire [2:0] fdc_ioad = u_CHIPSET.u_PERIPHERALS.fdd_io_address;
    // READ-start diagnosis: latch the four hang conditions and key values at
    // each cmd_read_write_start pulse (why floppy.v refuses to begin a read)
    wire       fr_start = u_CHIPSET.u_PERIPHERALS.floppy.cmd_read_write_start;
    wire       fr_wr    = u_CHIPSET.u_PERIPHERALS.floppy.cmd_write_normal_start;  // WRITE DATA start
    reg [7:0] p_dor, p_rwstart, p_wrstart;
    always @(posedge clk_chipset) begin
        if (fdc_iowr && fdc_ioad == 3'd2) p_dor <= p_dor + 8'd1;
        if (fr_start) p_rwstart <= p_rwstart + 8'd1;
        if (fr_wr)    p_wrstart <= p_wrstart + 8'd1;
        if (reset) begin p_dor<=0; p_rwstart<=0; p_wrstart<=0; end
    end
    assign dbg_fdc0_o = {p_wrstart, p_rwstart};   // dor= : {WRITE-DATA starts, read+write starts}
    assign dbg_fdc1_o = 16'd0;                    // (main.vhd overrides reg7/reg8 with bridge-side counts)
    assign dbg_fdc2_o = {p_rwstart, p_dor};       // (unused; main.vhd overrides)

endmodule
