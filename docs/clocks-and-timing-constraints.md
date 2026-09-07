# PCXT-EGA: clocks and timing constraints (Quartus SDC -> Vivado XDC)

Source tree: `CORE/PCXT-EGA_MiSTer` (git submodule, read-only). All `file:line` references below are relative to that directory. Line numbers are as of the submodule revision checked on 2026-09-07.

Constraint sources on MiSTer:

| File | Scope | Lines |
|---|---|---|
| `SYSTEM.sdc` | core-specific (this core) | 199 |
| `sys/sys_top.sdc` | MiSTer framework (sys_top) | 77 |
| `rtl/KFPC-XT/HDL/KF82xx/HDL/*.sdc`, `KFPS2KB/HDL/KFPS2KB.sdc` | stand-alone IP test builds only (each is `create_clock -period 200` on `clock` + 4 blanket I/O delays, e.g. `rtl/KFPC-XT/HDL/KF8237/HDL/KF8237.sdc:1-6`). Not loaded by `PCXT-EGA.qsf`. Drop. | 6 x 6 |

Load points on MiSTer: `files.qip:1` (`SDC_FILE SYSTEM.sdc`) and `sys/sys.qip:3` (`SDC_FILE sys_top.sdc`). The KF82xx/KFPS2KB SDCs are not referenced by any `.qip` or by `PCXT-EGA.qsf`.

Target: MEGA65 (Artix-7 `xc7a200tfbg484-2`), 100 MHz board clock, two MMCMs:

* MMCM A, VCO 630 MHz -> 28.636363 / 57.272727 / 57.272727 @ +90 deg / 25.2 / 14.318182 MHz
* MMCM B -> 100 / 50 MHz

---

## 1. Clock inventory

### 1.1 Real clocks (drive flip-flop clock pins)

| RTL name | Freq | MiSTer source | SDC name (`SYSTEM.sdc`) | Consumers (module / always block) |
|---|---|---|---|---|
| `CLK_50M` | 50 MHz | board pin, `sys/emu_ports.vh:2`; `sys/sys_top.sdc:2` | `FPGA_CLK1_50` | both PLL refclks `PCXT-EGA.sv:499,509`. MEGA65: replaced by 100 MHz input to both MMCMs. |
| `clk_100` | 100.000 MHz | `pll` outclk_0, `rtl/pll/pll_0002.v:33` (VCO 300 MHz `:226`, C0 hi2/lo1 `:97-98`) | `CLOCK_CORE` `SYSTEM.sdc:6` | `i8088.CORE_CLK` `PCXT-EGA.sv:1363` -> `mcl86_eu_core` (`always_ff @(posedge CORE_CLK_INT)` `rtl/8088/mcl86_eu_core.sv:558`), `mcl86_ucode` ROM (`rtl/8088/mcl86_eu_core.sv:294-297`), `mcl86_biu_max` FSM (`rtl/8088/mcl86_biu_max.sv:396`); `fake_286_flags_meta` sync `PCXT-EGA.sv:647`. |
| `clk_chipset` | 50.000 MHz | `pll` outclk_1, `rtl/pll/pll_0002.v:36` | `CLOCK_CHIP` `SYSTEM.sdc:7` | `CHIPSET.clock/clk_sys` `PCXT-EGA.sv:1182,1185` (all KF82xx peripherals, RAM/KFSDRAM via `rtl/KFPC-XT/HDL/RAM.sv:321`, OPL2 `Peripherals.sv:643`, SoundBlaster `:672`, SAA1099 `:775,789`, UART `:1545`, XT2IDE `:1485`, `ega_io_stretch` `:1067`, EGA VRAM CPU port `ega_vram_bram_frontend.sv:109`); `hps_io.clk_sys` `PCXT-EGA.sv:409`; `hps_ext` `:462`; `XT_CE_Generator` `:574`; reset counters `:596,689`; BIOS loader `:787`; mode latches `:627,634`; audio sum `:1453,1467`; UART/MIDI CE generators `:1517-1557`; `use_mmc` `:1718`; `SDRAM_CLK` output `:56`. **Negedge users:** `reset_cpu_ff/reset_cpu` `:654,662`, PS/2 input flops `:1092,1113`. |
| `clk_28_636` | 28.636363 MHz (315/11) | `pll_system` outclk_0, `rtl/pll_system/pll_system_0002.v:31` | `CLOCK_VIDEO_BASE` `SYSTEM.sdc:9` | Only two loads: clock-mux legacy input `PCXT-EGA.sv:523`; `clk_14_318` divider `:547-550`. |
| `clk_57_272` | 57.272727 MHz | `pll_system` outclk_1, `pll_system_0002.v:34` | `CLOCK_VIDEO_X2` `SYSTEM.sdc:10` | `CLK_VIDEO_PIPELINE` `PCXT-EGA.sv:1836`: OSD-status shadow regs `:394-399`; dot/pixel toggle synchronisers `:1783,1800`; `ce_pixel_28` `:1838`; `video_monochrome_converter` `:1871`; mode350/adots/alines sync `:1938`; `ega_fb_capture` `:1959`; `ega_fb_readout` `:1995`; `DDRAM_CLK` `:2021`; `ega_ddr_arbiter` `:2024`; `video_source_switch` `:2056`; `video_mixer` (sys) `:2096`; `VGA_*_video_src` `:2124`. |
| `clk_video_out_ps` | 57.272727 MHz, **+4365 ps = +90 deg** | `pll_system` outclk_2, `pll_system_0002.v:37-38` | `CLOCK_VIDEO_OUT_PS` `SYSTEM.sdc:11` | `CLK_VIDEO` to framework `PCXT-EGA.sv:1835`; `video_retime_reset_sync` `:536`; `video_credits_show*` `:1854`; `vga_f1_ps*` `:2084`; output retime `*_ps`/`*_hdmi` regs `:2138-2200`; `jtframe_credits` `:2211`; `VGA_DE_credits` `:2241`. Purpose (`:2137`): "Retimes the exact-frequency video output onto a phase-shifted sibling clock" so `VGA_*`/`CE_PIXEL` leave `emu` with a quarter-period of margin into the framework's `clk_vid` logic (`sys/sys_top.v:1707-1712,1784-1785`). |
| `clk_25_2` | 25.200 MHz | `pll_system` outclk_3, `pll_system_0002.v:40` | `CLOCK_VIDEO_VGA` `SYSTEM.sdc:12` | Clock-mux native input only `PCXT-EGA.sv:524`. |
| `clk_card_video` | 28.636363 **or** 25.2 MHz (muxed) | `vga_video_clock_mux` `PCXT-EGA.sv:522-527`; Quartus `cyclonev_clkselect` `rtl/video/vga_video_clock_mux.v:12-19`, plain `?:` otherwise `:21`. Select = `vga_mode13_active_video && vga_mode13_native_osd && !vga_mode13_wide_clock` `PCXT-EGA.sv:519-521`. | none (propagates as BASE/VGA) | `CHIPSET.clk_video` `PCXT-EGA.sv:1200` -> `PERIPHERALS.clk_video` `Chipset.sv:407` -> `ega_top.clk` `Peripherals.sv:1289` (CRTC, sequencer, `ega_dot_clock`, `vga_mode13_timing`, mode350 detector `ega_top.v:1360`); `video_io_*_sync` `Peripherals.sv:1162`; `video_reset_video_sync` `:226`; `ega_monitor_profile_*` `:233`; EGA VRAM CRT port `ega_vram_bram_frontend.sv:110,297`; VGA framebuffer video port `vga_a000_cpu_frontend.v:50`. |
| `clk_14_318` | 14.318182 MHz | **register divider** `reg clk_14_318` `PCXT-EGA.sv:488`, toggled on `clk_28_636` `:547-550` | `clk_14_318` generated, `SYSTEM.sdc:16,19` | splash FSM `PCXT-EGA.sv:958`; `splash_f12_pause` `:1031`; `bios_hold_notice` `:1068`; `reset_pending_notice` `:1734`; sampled into `clk_chipset` by `clk_uart_ff_1..3` `:1531-1536`. |
| `SDRAM_CLK` | 50 MHz | output port = `clk_chipset` `PCXT-EGA.sv:56` | `SDRAM_CLK` generated `SYSTEM.sdc:20` | external SDRAM; `KFSDRAM` itself runs on `clock` (`rtl/KFPC-XT/HDL/KFSDRAM/HDL/KFSDRAM.sv:136`). |

Framework clocks that `SYSTEM.sdc` names but the core does not generate: `CLOCK_HDMI` (`pll_hdmi`, `SYSTEM.sdc:13`), `CLOCK_H2F` (HPS 100 MHz, `:14`, `sys/sys_top.sdc:5`), `CLOCK_AUDIO` (24.576 MHz `sys/pll_audio/pll_audio_0002.v:22`, `SYSTEM.sdc:194`; consumed by `mt32pi.CLK_AUDIO` `PCXT-EGA.sv:1665`), `VCLK_SDIO` (virtual 50 MHz, `SYSTEM.sdc:21`), `FPGA_CLK2/3_50`, `spi_sck`, `hdmi_sck` (`sys/sys_top.sdc:3-7`).

### 1.2 Clock enables and pseudo-clocks (NOT clocks; do not constrain as clocks)

| Signal | Rate | Domain | Where |
|---|---|---|---|
| `clk_cpu` (virtual 8088 CLK pin) | 4.77 / 7.16 / 9.55 MHz, or 25 MHz toggle in turbo (`cpu_edge_num/den` 21/110, 63/220, 21/55, 1/1 of 50 MHz) | register in `clk_chipset` | `XT_CE_Generator.sv:50-88,123`; fed to `i8088.CLK` `PCXT-EGA.sv:1364`; only edge-detected in the BIU on `CORE_CLK` (`i8088.sv:65-67`, `mcl86_biu_max.sv:48-51,206-209,390-391`). |
| `cpu_ce_posedge/negedge`, `peripheral_ce` | 1-cycle pulses; peripheral_ce = 50 x 21/440 = 2.386 MHz | `clk_chipset` | `XT_CE_Generator.sv:13-16,26-27,106-135`. |
| `clk_en_opl2` | 3.579545 MHz CE | `clk_chipset` | `Peripherals.sv:628-637`. |
| `ce_saa` | 7.15909 MHz CE | `clk_chipset` | `Peripherals.sv:755-770`. |
| `clk_uart_en`, `clk_uart2_en` | 14.318 MHz edge CE; /8 = 1.7898 MHz CE | `clk_chipset` | `PCXT-EGA.sv:1531-1558`. |
| `clk_midi_en` | 12.5 MHz CE | `clk_chipset` | `PCXT-EGA.sv:1514-1528`. |
| EGA dot clock `ce_dot`, `ce_dot_early`, `ce_dot_2x`, `dot_toggle` | 14.318181 MHz (div2) or 16.257 MHz NCO (`59609/105000` of 28.636 MHz) | `clk_card_video` | `rtl/video/ega_dot_clock.v:26-40,55-62,64-96`. Exported as `ega_dot_toggle` and re-synchronised into `clk_57_272` `PCXT-EGA.sv:1780-1789`. |
| `vga_mode13_pixel_toggle` | one flip per mode-13h pixel | `clk_card_video` | `ega_top.v:911,1299`; sync `PCXT-EGA.sv:1797-1806`. |
| `ce_pixel_28`, `ce_pixel_video`, `CE_PIXEL` | /2 of 57.27; selected CE; retimed CE | `clk_57_272` / `clk_video_out_ps` | `PCXT-EGA.sv:1838,1807-1809,2184`. |

---

## 2. Every constraint in the two SDC files

Legend for the **Port** column: **KEEP** = translate to XDC; **KEEP*** = keep, but the target register list needs editing; **DROP-FW** = references MiSTer `sys/` framework signals or PLLs that do not exist on MEGA65; **DROP-STALE** = target register no longer exists in the RTL; **PORT-DEP** = keep only if the MEGA65 build has the corresponding external interface.

### 2.1 `SYSTEM.sdc` (core)

| # | Line | Type | From / To (exact) | Reason inferred from RTL | Port |
|---|---|---|---|---|---|
| 1 | 1 | `derive_pll_clocks` | - | auto-create PLL output clocks | KEEP (Vivado derives MMCM clocks automatically from the input `create_clock`) |
| 2 | 2 | `derive_clock_uncertainty` | - | - | KEEP (implicit in Vivado) |
| 3 | 19 | `create_generated_clock -name clk_14_318 -divide_by 2` | src `CLOCK_VIDEO_BASE` -> `emu:emu\|clk_14_318\|q` | register divider `PCXT-EGA.sv:547-550` | KEEP* (or replace by MMCM A output, see 4.1) |
| 4 | 20 | `create_generated_clock -name SDRAM_CLK` | src `CLOCK_CHIP` -> port `SDRAM_CLK` | `assign SDRAM_CLK = clk_chipset` `PCXT-EGA.sv:56` | PORT-DEP (external SDRAM) |
| 5 | 21 | `create_clock -name VCLK_SDIO -period 20` | virtual | MiSTer SDIO secondary SD interface | DROP-FW |
| 6 | 24 | `set_false_path -to` | `emu:emu\|splash_off` | `splash_off <= status[7]` on `clk_14_318` `PCXT-EGA.sv:960`; `status` is `clk_chipset` (hps_io `:409`). No synchroniser. | KEEP |
| 7 | 27 | `set_false_path` | `CLOCK_CHIP` -> `CLOCK_VIDEO_BASE` | 50 MHz chipset <-> 28.636 video: unrelated PLLs | KEEP (as clock group) |
| 8 | 28 | `set_false_path` | `CLOCK_VIDEO_BASE` -> `CLOCK_CHIP` | same | KEEP (group) |
| 9 | 29 | `set_false_path` | `CLOCK_CHIP` -> `CLOCK_VIDEO_X2` | 50 <-> 57.27 | KEEP (group) |
| 10 | 30 | `set_false_path` | `CLOCK_VIDEO_X2` -> `CLOCK_CHIP` | same | KEEP (group) |
| 11 | 31 | `set_false_path` | `CLOCK_CHIP` -> `CLOCK_VIDEO_OUT_PS` | 50 <-> 57.27+90 | KEEP (group) |
| 12 | 32 | `set_false_path` | `CLOCK_VIDEO_OUT_PS` -> `CLOCK_CHIP` | same | KEEP (group) |
| 13 | 33 | `set_false_path` | `CLOCK_CHIP` -> `CLOCK_VIDEO_VGA` | 50 <-> 25.2 | KEEP (group) |
| 14 | 34 | `set_false_path` | `CLOCK_VIDEO_VGA` -> `CLOCK_CHIP` | same | KEEP (group) |
| 15 | 35 | `set_false_path` | `CLOCK_CHIP` -> `clk_14_318` | 50 <-> 14.318 (splash/status) | KEEP (group) |
| 16 | 36 | `set_false_path` | `clk_14_318` -> `CLOCK_CHIP` | `clk_uart_ff_*` 3-FF sync `PCXT-EGA.sv:1531-1536`; `splashscreen`, `bios_hold`, `splash_paused` into chipset | KEEP (group) |
| 17 | 38 | `set_false_path` | `CLOCK_CORE` -> `CLOCK_VIDEO_BASE` | 100 MHz CPU <-> video | KEEP (group) |
| 18 | 39 | `set_false_path` | `CLOCK_VIDEO_BASE` -> `CLOCK_CORE` | same | KEEP (group) |
| 19 | 40 | `set_false_path` | `CLOCK_CORE` -> `CLOCK_VIDEO_X2` | same | KEEP (group) |
| 20 | 41 | `set_false_path` | `CLOCK_VIDEO_X2` -> `CLOCK_CORE` | same | KEEP (group) |
| 21 | 42 | `set_false_path` | `CLOCK_CORE` -> `CLOCK_VIDEO_OUT_PS` | same | KEEP (group) |
| 22 | 43 | `set_false_path` | `CLOCK_VIDEO_OUT_PS` -> `CLOCK_CORE` | same | KEEP (group) |
| 23 | 44 | `set_false_path` | `CLOCK_CORE` -> `CLOCK_VIDEO_VGA` | same | KEEP (group) |
| 24 | 45 | `set_false_path` | `CLOCK_VIDEO_VGA` -> `CLOCK_CORE` | same | KEEP (group) |
| 25 | 46 | `set_false_path` | `CLOCK_CORE` -> `clk_14_318` | same | KEEP (group) |
| 26 | 47 | `set_false_path` | `clk_14_318` -> `CLOCK_CORE` | same | KEEP (group) |
| 27 | 51 | `set_false_path` | `CLOCK_HDMI` -> `CLOCK_VIDEO_OUT_PS` | MiSTer HDMI_TX clock mux | DROP-FW |
| 28 | 52 | `set_false_path` | `CLOCK_VIDEO_OUT_PS` -> `CLOCK_HDMI` | same | DROP-FW |
| 29 | 56 | `set_false_path` | `CLOCK_VIDEO_OUT_PS` -> `VCLK_SDIO` | analog-video pins shared with SDIO | DROP-FW |
| 30 | 57 | `set_false_path` | `CLOCK_HDMI` -> `VCLK_SDIO` | same | DROP-FW |
| 31 | 60 | `set_max_delay 17.5` | `CLOCK_VIDEO_BASE` -> `CLOCK_VIDEO_OUT_PS` | 28.636 -> 57.27+90 retime; nothing in the RTL launches from `clk_28_636` into `clk_video_out_ps` any more (only `clk_card_video` when 28.636 is selected, via `video_credits_show_buf` `PCXT-EGA.sv:1854` which is from `clk_chipset`/`clk_14_318`) | KEEP* as `set_max_delay -datapath_only`, or subsume in async group |
| 32 | 61 | `set_max_delay 17.5` | `CLOCK_VIDEO_VGA` -> `CLOCK_VIDEO_OUT_PS` | 25.2 -> 57.27+90 | same as #31 |
| 33 | 70 | `set_max_delay 10` | `CLOCK_VIDEO_OUT_PS` -> `CLOCK_H2F` | HPS video status loopback | DROP-FW |
| 34 | 71 | `set_max_delay 10` | `CLOCK_HDMI` -> `CLOCK_H2F` | same | DROP-FW |
| 35 | 74-75 | `set_false_path` | `pll_hdmi_adj\|i_vss_delay` -> `pll_hdmi_adj\|ivss` | `sys/pll_hdmi_adj.vhd:137` `<ASYNC>` | DROP-FW |
| 36 | 79-81 | `set_false_path -to` | `emu\|video_retime_reset_sync[*]`, `u_PERIPHERALS\|video_reset_clock_sync[*]`, `u_PERIPHERALS\|video_reset_video_sync[*]` | async-assert / sync-release reset synchronisers `PCXT-EGA.sv:531-541`, `Peripherals.sv:208-231` (all `ASYNC_REG`) | KEEP |
| 37 | 84-86 | `set_false_path -to` | `ascal\|i_reset_na`, `o_reset_na`, `avl_reset_na` | MiSTer scaler | DROP-FW |
| 38 | 88-92 | `set_false_path -to` | `emu\|scale_video_ff[*]`, `screen_mode_video_ff[*]`, `border_video_ff`, `VIDEO_ARX[*]`, `VIDEO_ARY[*]` | OSD values latched from `clk_chipset` `status` into `clk_57_272` `PCXT-EGA.sv:379-399`; no synchroniser (quasi-static) | KEEP*: `border_video_ff` does not exist in RTL (DROP-STALE that member) |
| 39 | 94-95 | `set_max_delay 10` | `u_PERIPHERALS\|video_io_address[*]` -> `video_io_address_sync1[*]` | `clk_chipset` -> `clk_card_video` per-bit 2-FF sync `Peripherals.sv:1183-1184` | KEEP (`-datapath_only`) |
| 40 | 97-98 | `set_max_delay 10` | `video_io_data[*]` -> `video_io_data_sync1[*]` | same `:1185-1186` | KEEP |
| 41 | 100-101 | `set_max_delay 10` | `video_io_write_n` -> `video_io_write_n_sync1` | same `:1187-1188` | KEEP |
| 42 | 103-104 | `set_max_delay 10` | `video_io_read_n` -> `video_io_read_n_sync1` | same `:1189-1190` | KEEP |
| 43 | 106-107 | `set_max_delay 10` | `video_address_enable_n` -> `video_address_enable_n_sync1` | same `:1191-1192` | KEEP |
| 44 | 109-110 | `set_max_delay 10 -to` | `u_PERIPHERALS\|EGA_IO_DOUT_SYNC1[*]`, `EGA_IO_OE_SYNC1` | `clk_card_video` -> `clk_chipset` 2-FF `Peripherals.sv:1378-1384` | KEEP (`-datapath_only`) |
| 45 | 112-115 | `set_max_delay 10` | `hps_io\|video_calc\|vid_hcnt[*]`, `vid_nres[*]`, `vid_vcnt[*]` -> `video_calc\|dout[*]` | `sys/hps_io.sv:854-874` (`clk_vid` -> `clk_sys`) | DROP-FW |
| 46 | 117-118 | `set_max_delay 10` | `emu\|scale_video_ff[*]` -> `sl_r[*]` | `sys/sys_top.v:361-364` | DROP-FW |
| 47 | 120 | `set_max_delay 10 -to` | `u_PERIPHERALS\|swap_video_buffer_2` | register not in RTL | DROP-STALE |
| 48 | 122 | `set_max_delay 10 -to` | `emu\|video_pause_core_buf` | register not in RTL (replaced by `video_credits_show_buf` `PCXT-EGA.sv:1852-1857`, which is unconstrained today) | DROP-STALE; optionally re-target to `video_credits_show_buf` |
| 49 | 125-130 | `set_max_delay 10` | `osd:vga_osd\|info, infoh[*], osd_h[*], osd_w[*]` -> `osd_de[*], osd_hcnt2[*]` | `sys/sys_top.v:1403` | DROP-FW |
| 50 | 132-133 | `set_max_delay 10` | `osd:vga_osd\|osd_enable` -> `osd_en[*]` | same | DROP-FW |
| 51 | 135-136 | `set_max_delay 10` | `lowlat` -> `ascal\|i_mode[*]` | `sys/sys_top.v:329` | DROP-FW |
| 52 | 138-139 | `set_max_delay 10` | `LFB_FLT` -> `ascal\|i_mode[2]` | `sys/sys_top.v:834` | DROP-FW |
| 53 | 141-149 | `set_max_delay 10` | `LFB_EN` -> `hmaxi[*], hmini[*], state[0..2], vmaxi[*], vmini[*], ascal\|i_mode[2]` | `sys/sys_top.v:833,904` | DROP-FW |
| 54 | 151-154 | `set_max_delay 10` | `FREESCALE` -> `state[0..2]` | `sys/sys_top.v:327` | DROP-FW |
| 55 | 156-157 | `set_max_delay 10` | `HDMI_PR` -> `videow[*]` | `sys/sys_top.v:1061,905` | DROP-FW |
| 56 | 159-165 | `set_max_delay 10` | `cfg_done` -> `pll_hdmi_adj\|i_delay[*], i_de2, i_line[*], i_linecpt[*], i_vss_delay, i_vss2` | `sys/sys_top.v:330` | DROP-FW |
| 57 | 168 | `set_input_delay -max 10` | `VCLK_SDIO` -> `SDIO_DAT[*] SDIO_CMD` | MiSTer SDIO | DROP-FW |
| 58 | 169 | `set_input_delay -min 5` | same | | DROP-FW |
| 59 | 170 | `set_output_delay -max 5` | `VCLK_SDIO` -> `SDIO_DAT[*] SDIO_CMD SDIO_CLK` | | DROP-FW |
| 60 | 171 | `set_output_delay -min 0` | same | | DROP-FW |
| 61 | 174 | `set_input_delay -max 6` | `SDRAM_CLK` -> `SDRAM_DQ[*]` | KFSDRAM read data | PORT-DEP |
| 62 | 175 | `set_input_delay -min 3` | same | | PORT-DEP |
| 63 | 176 | `set_output_delay -max 2` | `SDRAM_CLK` -> `SDRAM_DQ[*] SDRAM_DQM* SDRAM_A[*] SDRAM_n* SDRAM_BA[*] SDRAM_CKE` | | PORT-DEP |
| 64 | 177 | `set_output_delay -min 1.5` | same | | PORT-DEP |
| 65 | 196-199 | `set_clock_groups -asynchronous` | `{CLOCK_VIDEO_X2}` / `{CLOCK_H2F}` / `{CLOCK_AUDIO}` | DDRAM frame buffer on `clk_57_272` vs HPS f2h bridge and audio PLL (`SYSTEM.sdc:179-193`) | DROP-FW (both other groups are framework); the memory the frame buffer uses on MEGA65 will need its own crossing |

Totals, `SYSTEM.sdc`: 2 directives, 1 `create_clock`, 2 `create_generated_clock`, 29 `set_false_path`, 22 `set_max_delay`, 4 `set_input_delay`, 4 `set_output_delay`, 1 `set_clock_groups` = **63 constraints**.
Disposition: KEEP/KEEP* 33 (#3, #6-26, #31-32, #36, #38-44), PORT-DEP 5 (#4, #61-64), DROP-STALE 2 (#47, #48) plus one stale member of #38, DROP-FW 23.

### 2.2 `sys/sys_top.sdc` (framework) - all DROP-FW unless noted

| # | Line | Type | Targets | Note |
|---|---|---|---|---|
| 1-3 | 2-4 | `create_clock 50 MHz` | `FPGA_CLK1_50`, `FPGA_CLK2_50`, `FPGA_CLK3_50` | Replace by one `create_clock` on the MEGA65 100 MHz pin. |
| 4 | 5 | `create_clock 100 MHz` | `*\|h2f_user0_clk` | HPS |
| 5 | 6 | `create_clock 100 MHz -name spi_sck` | `spi\|sclk_out` | HPS SPI |
| 6 | 7 | `create_clock 10 MHz -name hdmi_sck` | `hdmi_i2c\|out_clk` | HDMI I2C |
| 7-8 | 9-10 | `derive_pll_clocks`, `derive_clock_uncertainty` | | implicit in Vivado |
| 9 | 13-22 | `set_clock_groups -exclusive` (9 groups) | `{*\|pll\|pll_inst\|...divclk}` (= `clk_100` + `clk_chipset`, one group), `{pll_hdmi...}`, `{pll_audio...}`, `{spi_sck}`, `{hdmi_sck}`, `{*\|h2f_user0_clk}`, `{FPGA_CLK1_50}`, `{FPGA_CLK2_50}`, `{FPGA_CLK3_50}` | **Important:** the pattern does not match `pll_system_inst`, so the video clocks were never in this group; and `clk_100`/`clk_chipset` are in the *same* group, i.e. timed as related. Translate as `-asynchronous` (see 4.2). |
| 10-17 | 24-31 | `set_false_path -from/-to` ports | `KEY*`, `BTN_*`, `LED_*`, `VGA_*`, `VGA_EN`, `AUDIO_SPDIF`, `AUDIO_L`, `AUDIO_R` | MiSTer pins; the MEGA65 top will need its own port false paths |
| 18-24 | 32-38 | `set_false_path` | `SW[*]`, `cfg[*]` (to/from), `VSET[*]`, `wcalc/hcalc`, `hdmi_width/height`, `deb_* btn_en btn_up` | sys_top regs |
| 25-26 | 40-41 | `set_multicycle_path -setup 2 / -hold 1` | `-to *_osd\|osd_vcnt*` | sys OSD (`sys/osd.v`) |
| 27-36 | 43-52 | `set_false_path` (10) | `*_osd\|v_cnt*`, `v_osd_start*`, `v_info_start*`, `h_osd_start*` (to and from), `rot*`, `dsp_width*`, `half` | sys OSD |
| 37-42 | 54-59 | `set_false_path` (6) | `WIDTH HFP HS HBP HEIGHT VFP VS VBP`, `FB_BASE FB_WIDTH FB_HEIGHT LFB_*`, `vol_att scaler_flt led_*` (to and from) | sys_top |
| 43-46 | 60-63 | `set_false_path -from` (4) | `aflt_* acx* acy* areset* arc*`, `arx* ary*`, `vs_line*`, `ColorBurst_Range* PhaseInc* pal_en cvbs yc_en` | sys audio filter / yc_out |
| 47-56 | 65-74 | `set_false_path -from` (10) | `ascal\|o_*` | sys scaler |
| 57 | 76 | `set_false_path -from` | `mcp23009\|flg_*` | I2C expander |
| 58 | 77 | `set_false_path -to` | `sysmem\|fpga_interfaces\|clocks_resets\|f2h*` | HPS |

Totals, `sys/sys_top.sdc`: 6 `create_clock`, 2 directives, 1 `set_clock_groups`, 47 `set_false_path`, 2 `set_multicycle_path` = **56 constraints**, all framework. Nothing in it references core registers.

---

## 3. Cross-domain crossings: synchronised in RTL vs. covered only by SDC

### 3.1 Crossings with explicit synchronisers / handshakes in RTL (false paths on them are safe as-is)

| # | Crossing | Mechanism | Location |
|---|---|---|---|
| S1 | `reset_wire`-family (`RESET`, `status[0]`, `buttons[1]`, PLL locks, splash) -> `clk_video_out_ps` | async assert, 2-FF sync release, `ASYNC_REG` | `PCXT-EGA.sv:530-541` |
| S2 | `video_reset` -> `clock` (50) and -> `clk_video` | two independent async-assert/sync-release 2-FF chains, `ASYNC_REG` | `Peripherals.sv:206-231` |
| S3 | `eff_fake286` (`clk_chipset`) -> `clk_100` | 2-FF `ASYNC_REG` (`fake_286_flags_meta`) | `PCXT-EGA.sv:640-648` |
| S4 | `ega_monitor_profile` (`clk_chipset`) -> `clk_video` | 2x2-FF `ASYNC_REG` | `Peripherals.sv:214-241` |
| S5 | ISA I/O bus (`clock`) -> EGA (`clk_video`) | posted-write stretcher in chipset domain (`ega_io_stretch`, guarantees min pulse width/gap) + per-bit 2-FF (`video_io_*_sync1/2`) + two-identical-samples qualifier in `ega_top` | `rtl/KFPC-XT/HDL/ega_io_stretch.sv:1-40`, `Peripherals.sv:1054-1079,1162-1193`, `rtl/video/ega_top.v:175-215` |
| S6 | `ega_mem_select/ega_mem_write` (`clock`) -> `clk_video` | 2-FF | `Peripherals.sv:1194-1197` |
| S7 | EGA read data/OE (`clk_video`) -> `clock` | 2-FF (`EGA_IO_DOUT_SYNC*`, `EGA_IO_OE_SYNC*`) | `Peripherals.sv:1231-1236,1378-1384,1860-1863` |
| S8 | `vga_mode13_active_video`, `vga_planar_memory_active_video` (`clk_video`) -> `clock` | 2-FF | `Peripherals.sv:198-203,1147-1160` |
| S9 | EGA config regs (`ega_top` on `clk_video`) -> VRAM CPU side (`clock`) | `cfg_toggle` + per-field 2-FF, latched on toggle edge | `rtl/KFPC-XT/HDL/ega_vram_bram_frontend.sv:67-84,148-243` |
| S10 | EGA VRAM CPU port (`clock`) vs CRT port (`clk_video`) | true dual-clock BRAM (`ega_vram .clk/.clk_vram`) | `ega_vram_bram_frontend.sv:109-110`, `rtl/video/ega_vram.v:78-81` |
| S11 | Mode-13h framebuffer CPU port (`clock`) vs video port (`clk_video`) | dual-clock BRAM (`vga_framebuffer`) | `rtl/video/vga_a000_cpu_frontend.v:42,50`, `rtl/video/vga_framebuffer.v:39` |
| S12 | `ega_dot_toggle`, `vga_mode13_pixel_toggle` (`clk_card_video`) -> `clk_57_272` | toggle + 2 FF + XOR (**only one stage is a true synchroniser**; relies on 2:1 phase-locked relation when 28.636 is selected) | `PCXT-EGA.sv:1773-1806` |
| S13 | `ega_mode350`, `ega_active_dots[11:0]`, `ega_active_lines[9:0]` (`clk_card_video`) -> `clk_57_272` | 2-FF per bit on multi-bit buses; valid because values change once per frame at vblank | `PCXT-EGA.sv:1931-1942`, `ega_top.v:1360-1375` |
| S14 | `pause_core` (`clock`) / `splash_paused` (`clk_14_318`) -> `clk_video_out_ps` | 2-FF | `PCXT-EGA.sv:1852-1857` |
| S15 | `crt480i_active & fb_field` (`clk_57_272`) -> `clk_video_out_ps` | 2-FF | `PCXT-EGA.sv:2080-2088` |
| S16 | `clk_57_272` -> `clk_video_out_ps` output retime | direct FF->FF, **timed** (same PLL, +90 deg) - not a false path | `PCXT-EGA.sv:2124-2200` |
| S17 | `clk_14_318` -> `clk_chipset` | 3-FF + edge detect (`clk_uart_ff_1..3`) | `PCXT-EGA.sv:1531-1536` |
| S18 | `bios_missing_*` (`clk_chipset`) -> `clk_14_318` | 2-FF `ASYNC_REG` | `rtl/KFPC-XT/HDL/bios_hold_notice.sv:35-44` |
| S19 | `reset_pending`, `OSD_STATUS` (`clk_chipset`) -> `clk_14_318` | 2/3-FF `ASYNC_REG` | `rtl/KFPC-XT/HDL/reset_pending_notice.sv:42-43` |
| S20 | `ps2_key` (`clk_chipset`) -> `clk_14_318` | 3-FF / 10-bit `ASYNC_REG` | `rtl/KFPC-XT/HDL/splash_f12_pause.sv:25-26` |
| S21 | `clk_cpu` (register in `clk_chipset`) -> `clk_100` | 2-FF resync + edge detect | `rtl/8088/mcl86_biu_max.sv:206-209,390-391` |
| S22 | PS/2 clock/data (hps_io, `clk_chipset`) -> negedge `clk_chipset` | 2-FF | `PCXT-EGA.sv:1087-1120` |

### 3.2 Crossings that rely only on the SDC false paths / clock groups (no synchroniser)

| # | Crossing | Why it is tolerated | Location |
|---|---|---|---|
| U1 | `status[7]` (`clk_chipset`) -> `splash_off` (`clk_14_318`) | single bit, quasi-static OSD | `PCXT-EGA.sv:960`; SDC #6 |
| U2 | `scale`, `screen_mode`, `ar` (`clk_chipset`) -> `scale_video_ff`, `screen_mode_video_ff`, `VIDEO_ARX/ARY` (`clk_57_272`) | quasi-static OSD; multi-bit but changed by the user only | `PCXT-EGA.sv:379-399`; SDC #38 |
| U3 | OSD-derived inputs into `ega_top` on `clk_card_video`: `thin_font`, `vga_mode13_native` (`status[10]`), `vga_mode13_osd`, `crt_h_offset`, `crt_v_offset`, `vsync_width_osd`, `hsync_width_osd`, `splashscreen` | quasi-static (resolved on `clk_chipset` by `xtegactl_resolve`, `PCXT-EGA.sv:290-335`); `splashscreen` comes from `clk_14_318` (`:1084`) | `Peripherals.sv:1358-1376`; covered only by SDC #7-26 |
| U4 | `status[35:34]` (`crt480i_osd`), `eff_crt_h/v` (`clk_chipset`) -> `fb_enable`, `ega_fb_readout` (`clk_57_272`) | quasi-static | `PCXT-EGA.sv:1927-1946,1993-2000` |
| U5 | `reset` (released synchronously to `clk_chipset`, `PCXT-EGA.sv:596-620`) used as **async reset** of `clk_video` flops | recovery/removal from an unrelated clock; hidden once the domains are declared asynchronous | `Peripherals.sv:1162-1176` (`always_ff @(posedge clk_video, posedge reset)`); also `Chipset`-level `reset` into `vga_a000_cpu_frontend` `Peripherals.sv:1450` |
| U6 | `clk_100` <-> `clk_chipset`: the entire CPU bus (`cpu_ad_out`, `data_bus`, `READY`, `INTR`, `reset_cpu`, `clk_cpu`, `biu_done`, `word_*`) | **timed as synchronous** (same PLL, 2:1, both in one `-exclusive` group `sys/sys_top.sdc:14`). Must stay that way on MEGA65: both from MMCM B, both on BUFG, 0 deg. | `PCXT-EGA.sv:1361-1397` |
| U7 | `clk_card_video`(28.636) <-> `clk_57_272` | timed as synchronous 2:1 (same PLL); the S12 toggle synchroniser depends on it (`PCXT-EGA.sv:1777-1779`). When the mux selects 25.2 MHz, the same paths become asynchronous and are covered by the 2-FF stages. | |
| U8 | Video clock mux select `vga_native_standard_clock` = f(`clk_card_video` signals, `status[10]`) | glitch-free hard mux on Quartus (`cyclonev_clkselect`); the plain `?:` fallback is a LUT clock | `PCXT-EGA.sv:518-527`, `rtl/video/vga_video_clock_mux.v:12-22` |
| U9 | `ega_dot_clock_sel`, `ega_scandouble_active` (`clk_card_video`) used directly at top level | exported to status/mixing only (`PCXT-EGA.sv:213-214,1807,1859`) | |

---

## 4. Proposed XDC (Vivado)

Placeholders: `<MMCMA>` / `<MMCMB>` = instance paths of the two MMCMs; `<VIDMUX>` = instance of the `BUFGMUX_CTRL` that replaces `vga_video_clock_mux`; `<EMU>` = hierarchical prefix of the ported `emu` module; `<PERIPH>` = `<EMU>/u_CHIPSET/u_PERIPHERALS`. Vivado names auto-derived MMCM clocks after the **output net**; name the nets `clk_100`, `clk_chipset`, `clk_28_636`, `clk_57_272`, `clk_video_out_ps`, `clk_25_2`, `clk_14_318` and the `get_clocks` below resolve without renaming. If the wizard nets are named differently, add `create_generated_clock -name <x> -source [get_pins <MMCMA>/CLKIN1] ...` overrides.

### 4.1 Clocks

```tcl
# Board input (MEGA65 100 MHz). Replaces sys_top.sdc:2-4.
create_clock -name clk_100_in -period 10.000 [get_ports clk_100_pin]

# MMCM A: 100 MHz -> VCO 630 MHz. 6.3x is not a multiple of 0.125, so use
#   DIVCLK_DIVIDE=5, CLKFBOUT_MULT_F=31.5  (PFD 20 MHz)   or
#   DIVCLK_DIVIDE=10, CLKFBOUT_MULT_F=63   (PFD 10 MHz, minimum)
# CLKOUT0 /22 = 28.636364   (clk_28_636)       (SYSTEM.sdc CLOCK_VIDEO_BASE)
# CLKOUT1 /11 = 57.272727   (clk_57_272)       (CLOCK_VIDEO_X2)
# CLKOUT2 /11 = 57.272727, CLKOUT2_PHASE = 90.0  (clk_video_out_ps)  (CLOCK_VIDEO_OUT_PS)
#         4365 ps / (1.5873 ns VCO / 8) = 22.0 phase steps -> exact.
# CLKOUT3 /25 = 25.200000   (clk_25_2)         (CLOCK_VIDEO_VGA)
# CLKOUT4 /44 = 14.318182   (clk_14_318)       replaces the register divider (SYSTEM.sdc:19)
# MMCM B: 100 MHz -> VCO 1000 MHz (M=10, D=1): CLKOUT0 /10 = 100 (clk_100), CLKOUT1 /20 = 50 (clk_chipset)
# Vivado derives all of these from clk_100_in; no create_generated_clock needed.

# Option kept for a 1:1 port that retains `reg clk_14_318` (PCXT-EGA.sv:547-550):
# create_generated_clock -name clk_14_318 -source [get_pins <EMU>/clk_14_318_reg/C] \
#     -divide_by 2 [get_pins <EMU>/clk_14_318_reg/Q]
# and route it through a BUFG (Vivado will otherwise warn about a register-driven clock net).

# Video clock mux (replaces cyclonev_clkselect, vga_video_clock_mux.v:14-19).
# Use BUFGMUX_CTRL (glitch-free): I0 = clk_28_636, I1 = clk_25_2, S = vga_native_standard_clock.
# Vivado propagates BOTH clocks through the mux output. Give each its own name on the
# output and declare them exclusive so Vivado never times 28.636 against 25.2 on that net.
create_generated_clock -name clk_card_video_28 -source [get_pins <VIDMUX>/I0] -divide_by 1 \
    -master_clock [get_clocks clk_28_636] [get_pins <VIDMUX>/O]
create_generated_clock -name clk_card_video_25 -source [get_pins <VIDMUX>/I1] -divide_by 1 \
    -master_clock [get_clocks clk_25_2] -add [get_pins <VIDMUX>/O]
set_clock_groups -physically_exclusive -group clk_card_video_28 -group clk_card_video_25
# The select is a data signal from the muxed domain itself + status[10]; BUFGMUX_CTRL is
# glitch-free by construction, so do not time it.
set_false_path -to [get_pins <VIDMUX>/S]

# SDRAM (only if the MEGA65 build drives an external SDRAM; SYSTEM.sdc:20,174-177)
# create_generated_clock -name SDRAM_CLK -source [get_pins <MMCMB>/CLKOUT1] -divide_by 1 [get_ports SDRAM_CLK]
# set_input_delay  -clock SDRAM_CLK -max 6   [get_ports {SDRAM_DQ[*]}]
# set_input_delay  -clock SDRAM_CLK -min 3   [get_ports {SDRAM_DQ[*]}]
# set_output_delay -clock SDRAM_CLK -max 2   [get_ports {SDRAM_DQ[*] SDRAM_DQM* SDRAM_A[*] SDRAM_n* SDRAM_BA[*] SDRAM_CKE}]
# set_output_delay -clock SDRAM_CLK -min 1.5 [get_ports {SDRAM_DQ[*] SDRAM_DQM* SDRAM_A[*] SDRAM_n* SDRAM_BA[*] SDRAM_CKE}]
```

### 4.2 Clock groups (replaces SYSTEM.sdc:27-47 and sys_top.sdc:13-22)

Quartus `set_clock_groups -exclusive` (sys_top.sdc:13) means "never active together / do not analyse between"; the Vivado spelling for "unrelated, do not time" is `-asynchronous`. Vivado's `-logically_exclusive` / `-physically_exclusive` are only for clocks that share a mux (used above for the video mux). The 20 pairwise `set_false_path -from/-to` clocks in `SYSTEM.sdc:27-47` collapse into one statement:

```tcl
set_clock_groups -asynchronous \
    -group [get_clocks {clk_100 clk_chipset}] \
    -group [get_clocks {clk_28_636 clk_57_272 clk_video_out_ps clk_card_video_28 clk_14_318}] \
    -group [get_clocks {clk_25_2 clk_card_video_25}]
```

Notes:
* `clk_100` and `clk_chipset` **must remain related** (U6): same MMCM, same group.
* `clk_28_636`, `clk_57_272`, `clk_video_out_ps` remain related to each other (S12 relies on the 2:1 phase; S16 relies on the 90 deg phase). Keep them in one group.
* `clk_25_2` is unrelated to the 57.27 family in the RTL's eyes (the toggle synchronisers handle it, `PCXT-EGA.sv:1777-1781`), so it can be its own group. If 25.2 is put in the same group as 57.27, Vivado will find a tiny common period (630 MHz VCO => related) and try to time 25.2 -> 57.27 paths at sub-nanosecond budgets. Keep it separate.
* `clk_14_318` as an MMCM output: with the register divider removed, the S17 sync still handles 14.318 -> 50. Group it with the video family (phase-locked to 28.636 as before).
* A `-asynchronous` group replaces the *pairwise* false paths but not the point-to-point `set_max_delay` bounds (4.4); those still apply within the groups only if `-datapath_only` is used, which ignores clock relationships.

### 4.3 False paths (surviving SYSTEM.sdc items #6, #36, #38)

```tcl
# SYSTEM.sdc:24  status[7] -> splash_off (U1)
set_false_path -to [get_cells <EMU>/splash_off_reg]

# SYSTEM.sdc:79-81  reset synchronisers (S1, S2): async assert, local-clock release.
set_false_path -to [get_pins -of_objects [get_cells {<EMU>/video_retime_reset_sync_reg[*] \
                                                     <PERIPH>/video_reset_clock_sync_reg[*] \
                                                     <PERIPH>/video_reset_video_sync_reg[*]}] -filter {REF_PIN_NAME =~ PRE || REF_PIN_NAME =~ CLR}]

# SYSTEM.sdc:88-92  OSD shadow registers on clk_57_272 (U2). border_video_ff dropped (not in RTL).
set_false_path -to [get_cells {<EMU>/scale_video_ff_reg[*] <EMU>/screen_mode_video_ff_reg[*] \
                               <EMU>/VIDEO_ARX_reg[*] <EMU>/VIDEO_ARY_reg[*]}]

# Vivado-only: every ASYNC_REG chain gets a bounded datapath rather than a bare false path
# (PCXT-EGA.sv:531,644; Peripherals.sv:208-217; bios_hold_notice.sv:35-36;
#  reset_pending_notice.sv:42-43; splash_f12_pause.sv:25-26). Optional but recommended:
# set_max_delay -datapath_only -from [all_clocks] -to [get_cells -hier -filter {ASYNC_REG == TRUE}] 10.0
```

### 4.4 Point-to-point max-delay bounds (SYSTEM.sdc #31-32, #39-44)

Quartus `set_max_delay` between clocks includes clock skew; the equivalent intent in Vivado (a CDC bound independent of the clock relationship) is `-datapath_only`. Values kept as in the SDC.

```tcl
# SYSTEM.sdc:94-107  chipset -> video I/O bus, first sync stage (S5)
set_max_delay -datapath_only 10.0 \
    -from [get_cells {<PERIPH>/video_io_address_reg[*] <PERIPH>/video_io_data_reg[*] \
                      <PERIPH>/video_io_write_n_reg <PERIPH>/video_io_read_n_reg \
                      <PERIPH>/video_address_enable_n_reg}] \
    -to   [get_cells {<PERIPH>/video_io_address_sync1_reg[*] <PERIPH>/video_io_data_sync1_reg[*] \
                      <PERIPH>/video_io_write_n_sync1_reg <PERIPH>/video_io_read_n_sync1_reg \
                      <PERIPH>/video_address_enable_n_sync1_reg}]

# SYSTEM.sdc:109-110  video -> chipset read data (S7)
set_max_delay -datapath_only 10.0 \
    -to [get_cells {<PERIPH>/EGA_IO_DOUT_SYNC1_reg[*] <PERIPH>/EGA_IO_OE_SYNC1_reg}]

# SYSTEM.sdc:60-61  28.636/25.2 -> clk_video_out_ps. With the groups in 4.2 these paths are
# already unconstrained; keep only if you want the bound back on the two real crossings:
set_max_delay -datapath_only 17.5 -from [get_clocks {clk_card_video_25 clk_card_video_28}] \
                                  -to   [get_clocks clk_video_out_ps]

# Not in the SDC, but equivalent registers exist in the RTL and are unbounded today:
#   S13 (PCXT-EGA.sv:1938-1942), S14 (:1854-1857), S15 (:2084-2088), S6 (Peripherals.sv:1194-1197),
#   S8 (:1147-1160), S9 (ega_vram_bram_frontend.sv:210-243).
# Recommend: set_max_delay -datapath_only 10.0 -to <first stage of each>.
```

### 4.5 Multicycle paths

None survive. The only `set_multicycle_path` in either SDC targets the framework OSD (`sys/sys_top.sdc:40-41`, `*_osd|osd_vcnt*`). The core's own slow logic is all clock-enable based (Section 1.2) and does not need multicycle exceptions; if timing on `clk_chipset` is ever a problem, the CE-qualified paths in the KF82xx blocks (`cpu_ce_*`, `peripheral_ce`, `clk_en_opl2`, `ce_saa`, `clk_uart*_en`) are candidates for `set_multicycle_path -setup N -from <CE-source>` but the MiSTer build never needed it.

### 4.6 I/O delays

All `set_input_delay` / `set_output_delay` in `SYSTEM.sdc:168-177` are SDIO (DROP-FW) or SDRAM (PORT-DEP, see 4.1). No core I/O delays otherwise.

---

## 5. Risks and Quartus-specific dependencies

### 5.1 Timing risk at 100 MHz (MCL86 EU)

* Documented critical path on Cyclone V: `ucode ROM -> operand mux -> carry[5..15] -> ALU output mux -> eu_biu_command`, closing at **88 MHz against 100** until the adder was rewritten (`rtl/8088/mcl86_eu_core.sv:486-490`, `rtl/8088/mcl86_adder.sv:47-56`). The rewrite (`assign full = a + b`, `mcl86_adder.sv:97-110`) maps to `CARRY4` on Artix-7, so the adder itself should be fine.
* The microcode ROM read is **unregistered at the BRAM output by design**: 4K x 32, one clock of latency, and the sequencer's 2-word lead depends on exactly that (`rtl/8088/mcl86_ucode.sv:39-42,75`). 4096 x 32 needs four `RAMB36E1` (1K x 36 each) plus an output mux; BRAM clock-to-out on -2 is about 2.1-2.5 ns without the optional output register, so ~3 ns of the 10 ns budget is gone before the decode (`mcl86_eu_core.sv:312-321`) and operand muxes (`:810,895` - 16-way `case`). The `DOA_REG` pipeline register cannot be enabled without changing the microcode timing. Expect this to be the path to watch; if it fails, the options are floorplanning the four BRAMs next to the EU, or accepting `clk_100` < 100 MHz - which changes the cycle-accurate timing constants (`XT_CE_Generator.sv:64-85`, `i8088.sv:58-63`) and the 4x-8x CORE_CLK/CLK ratio assumption (`i8088.sv:88`).
* `clk_100` <-> `clk_chipset` synchronous crossings (U6) are real 10 ns paths across two BUFGs; keep both on the same MMCM and check `report_clock_interaction` shows them as "Timed".
* `clk_57_272` -> `clk_video_out_ps` retime (S16) has a **4.365 ns** setup window (90 deg of 17.46 ns). It is FF->FF with no logic (`PCXT-EGA.sv:2124-2200`); Vivado will time it automatically. Do not let synthesis insert logic (e.g. reset muxing) on those nets; the async reset on `:2138` is fine.
* Negedge `clk_chipset` flops (`PCXT-EGA.sv:654-670,1092-1120`) create 10 ns half-period paths at 50 MHz - not a problem, but they show up in `report_timing` as posedge->negedge.
* `clk_25_2` -> `clk_57_272` paths (the toggle synchroniser inputs, S12) will be timed at a sub-ns budget if 25.2 lands in the same clock group as 57.27 (both from the 630 MHz VCO). Keep them in separate `-asynchronous` groups (4.2).

### 5.2 Quartus-specific constructs that will not carry over

| Construct | Where | Vivado behaviour / action |
|---|---|---|
| `altera_pll` instances (`pll_0002`, `pll_system_0002`) | `rtl/pll/pll_0002.v:26-242`, `rtl/pll_system/pll_system_0002.v:26-94`, `rtl/pll.v`, `rtl/pll_system.v` | Replace with two MMCME2_ADV / Clocking Wizard instances (4.1). `pll` is `pll_subtype("Reconfigurable")` with `reconfig_*` ports (`pll_0002.v:19-23,88`) - unused, tie off. |
| `cyclonev_clkselect` under `` `ifdef ALTERA_RESERVED_QIS `` | `rtl/video/vga_video_clock_mux.v:12-22` | Vivado takes the `else` branch: a LUT-built clock mux (glitches, no global buffer). Replace with `BUFGMUX_CTRL`. |
| `reg clk_14_318` register clock | `PCXT-EGA.sv:488,547-550` | Works but is a fabric-driven clock; Vivado inserts a BUFG only if told. Prefer MMCM A CLKOUT4 (4.1). |
| `(* ramstyle = "logic" *)` | `rtl/common/floppy.v:92,95,98,102,766,790,800` | Unknown attribute, ignored. Use `(* ram_style = "distributed" *)` or `"registers"` if inference matters (tiny arrays; harmless either way). |
| `(* ramstyle = "M10K, no_rw_check" *)` | `rtl/video/ega_fb_capture.v:275`, `rtl/video/ega_fb_readout.v:209-210`, `rtl/video/vga_framebuffer.v:39`, `rtl/video/video_scandoubler.v:76`, `rtl/common/jtframe_dual_ram.v:138`, `rtl/common/jtframe_ram.v:42` | Ignored. `no_rw_check` has no equivalent; Vivado infers read-during-write behaviour from the code, and dual-clock RAMs with the "wrong" pattern fall back to distributed RAM or fail to infer. Replace with `(* ram_style = "block" *)` and check synthesis' RAM inference report; the dual-clock ones (`vga_framebuffer`, `ega_vram`, line buffers) are the ones to verify. |
| `(* ramstyle = "M10K" *)` | `rtl/video/ega_splash_renderer.v:29`, `rtl/video/ega_vram.v:78-81` | Same; `ram_style = "block"`. |
| `// synthesis parallel_case` | `rtl/8088/mcl86_biu_max.sv:531,619,633`, `mcl86_biu_min.sv:456,501,516,527`, `mcl86_eu_core.sv:810,895` | Vivado recognises `(* parallel_case *)` attributes; comment-form pragmas are not guaranteed. On the EU operand muxes (`eu_core.sv:810,895`) losing it could add priority logic on the critical path. Convert to attributes and compare LUT depth. |
| `// synthesis translate_off/on` | `rtl/KFPC-XT/HDL/RAM.sv:572,586` | Supported by Vivado. |
| `(* ASYNC_REG = "TRUE" *)` | `PCXT-EGA.sv:531,644`; `Peripherals.sv:208-217`; `bios_hold_notice.sv:35-36`; `reset_pending_notice.sv:42-43`; `splash_f12_pause.sv:25-26` | Vivado-native; keeps the pairs adjacent and disables SRL packing. Nothing to do. |
| `initial` block ROM contents | `rtl/8088/mcl86_ucode.sv:55-57,75-80`; `.hex`/`.mem` files (`rtl/8088/mcl86_ucode.mem`, `rtl/common/font0.hex`, `rtl/video/splash_ega_320x200.hex`) | Supported (`$readmemh` at elaboration); paths are relative to the Vivado project run directory - use absolute or `-include_dirs`. |
| `derive_pll_clocks`, `derive_clock_uncertainty`, `get_registers`, `\|`-separated hierarchy names, `emu:emu` instance:type syntax | throughout both SDCs | Vivado: automatic derivation, `get_cells`, `/`-separated names, `_reg` suffix on inferred flops. |
| `altera_attribute`, `keep`, `preserve`, `noprune` | none found in `rtl/` or `PCXT-EGA.sv` | Nothing to translate. |

### 5.3 Structural items outside the SDC that the port must resolve

* `DDRAM_*` frame-buffer path (`ega_fb_capture`, `ega_fb_readout`, `ega_ddr_arbiter`, all on `clk_57_272`, `PCXT-EGA.sv:1959-2050`; `SYSTEM.sdc:179-199`) targets the MiSTer HPS DDR3 bridge. Whatever memory replaces it on MEGA65 (HyperRAM, SDRAM, or BRAM) must present its port in the `clk_57_272` domain or add its own CDC; the `-asynchronous` group in `SYSTEM.sdc:196` was the only constraint on that boundary.
* `SDRAM_CLK = clk_chipset` (`PCXT-EGA.sv:56`) with `KFSDRAM` timing tuned to the MiSTer SDRAM module (`SYSTEM.sdc:174-177`). If the MEGA65 build uses its own SDRAM, re-derive the I/O delays from that part's datasheet and add an ODDR-forwarded clock rather than driving the port from the BUFG net.
* `hps_io`, `hps_ext`, `mt32pi` (`CLK_AUDIO`, `USER_IN/OUT`), `video_mixer` and the `CLK_VIDEO`/`CE_PIXEL`/`VGA_*` contract (`sys/emu_ports.vh:11-16`) are framework; the MEGA65 framework equivalent decides whether `clk_video_out_ps` (the +90 deg copy) is still needed. If the MEGA65 side samples `VGA_*` on its own clock through a proper CDC/FIFO, the phase-shifted output and its retime stage (`PCXT-EGA.sv:2137-2200`) can be dropped, removing one MMCM output and the S16 4.4 ns path.
* U5: `reset` (chipset-synchronous release) drives the async reset of `clk_video` flops (`Peripherals.sv:1162`). Under an `-asynchronous` group this recovery check disappears; the RTL already has the right pattern next to it (`video_reset_video_sync`, `Peripherals.sv:226-231`) - consider using `video_reset_video` there instead.
