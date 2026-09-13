`timescale 1ns / 1ps
//---------------------------------------------------------------------------------------------------
// analog_pipeline_tb: the real MiSTer2MEGA65 analog (VGA connector) path of this port, driven with
// the PCXT-EGA 200-line raster and measured at the VGA pins.
//
// DUT = what CORE/vhdl/mega65.vhd and M2M/vhdl/av_pipeline/av_pipeline.vhd wire together:
//   CORE/vhdl/analog_video_ctl.vhd               menu -> qnice_scandoubler/retro15kHz/csync, video_ce_ovl
//   xpm_cdc_array_single (WIDTH only, as av_pipeline.vhd:272-296)  QNICE -> video clock CDC
//   M2M/vhdl/av_pipeline/analog_pipeline.vhd     video_mixer.sv (scandoubler.v, hq2x.sv, video_freezer.sv),
//                                                video_overlay.vhd (vga_recover_counters.vhd, vga_osm.vhd),
//                                                csync.sv, falling-edge output registers
// with the generics of CORE/vhdl/globals.vhd (720x576 OSM canvas, 16x16 font). Not modelled: the VDAC
// and the OSM content (overlay disabled, VRAM reads zero); the overlay pipeline is still in the path.
// Two xsim-only adaptations, neither touching M2M sources: analog_pipeline_wrap.vhd ties the
// "natural range 0 to 8" OSM scaling port (xelab cannot bind it from Verilog), and the runner compiles
// analog_pipeline.vhd from a copy in which the three "R => unsigned(video_red_i)" port-map conversions
// (analog_pipeline.vhd:141-143) are moved into signal assignments - xsim aborts at time 0 on the
// original ("Array sizes do not match"); Vivado synthesis binds the original correctly.
//
// Stimulus: the CGA/EGA 200-line raster as pcxt_core.sv emits it in clk_57_ps. 912 dots x 262 lines,
// one dot = 4 clocks (14.318 MHz), 640x200 active, HS positive 64 dots from dot 720, VS positive 3 lines
// from line 224 changing at the HS rising edge (UM6845R.v hsync_dot_rise). HS/VS are updated on the
// same clock as the pixel enable (pcxt_core.sv CE_PIXEL_video_hdmi stage), RGB / hblank / vblank one
// clock later (jtframe_credits.v:439-463, pxl_cen registers). Every active pixel encodes its position,
// R = x[7:0], G = y[7:0], B = {x[9:8], 6'b101010}, so the pins can be checked pixel by pixel.
//
// Cases
//   A  VGA 31 kHz  (scandoubler on)   4 phases of the pixel enable vs the free-running 2x overlay enable
//   B  VGA 15 kHz  (scandoubler off)  2 phases
//   C  VGA 15 kHz + CSync             2 phases, plus a dump of the composite sync pattern through VS
//   D  runtime switches 31 -> 15 kHz and 15 -> 31 kHz mid-frame: glitch length at the HS pin
// Each case prints one "RESULT" line; the last line is "APT RESULT: PASS/FAIL ...".
//
// Run: powershell -File CORE/rtl/tb/run_analog_pipeline_tb.ps1
//---------------------------------------------------------------------------------------------------

module analog_pipeline_tb #(
    parameter string FONT_FILE = "../../../M2M/font/Anikki-16x16-m2m.rom"
);

    localparam real T_VID = 17.461;   // 57.27 MHz  (clk_57_ps)
    localparam real T_QN  = 20.0;     // 50 MHz     (QNICE)

    // the port's 200-line raster, in dots / lines
    localparam int H_TOTAL  = 912;
    localparam int H_ACT    = 640;
    localparam int HS_START = 720;
    localparam int HS_LEN   = 64;
    localparam int V_TOTAL  = 262;
    localparam int V_ACT    = 200;
    localparam int VS_START = 224;
    localparam int VS_LEN   = 3;
    localparam int CPP      = 4;                      // clocks per dot
    localparam longint LINE_CLK  = H_TOTAL * CPP;     // 3648
    localparam longint FRAME_CLK = LINE_CLK * V_TOTAL;// 955776

    //-----------------------------------------------------------------------------------------------
    // clocks
    //-----------------------------------------------------------------------------------------------
    logic clk  = 1'b0;
    logic qclk = 1'b0;
    always #(T_VID / 2.0) clk  = ~clk;
    always #(T_QN  / 2.0) qclk = ~qclk;

    longint cyc = 0;
    always @(posedge clk) cyc <= cyc + 1;

    //-----------------------------------------------------------------------------------------------
    // menu bits -> analog_video_ctl -> framework CDC (exactly as mega65.vhd / av_pipeline.vhd)
    //-----------------------------------------------------------------------------------------------
    logic qn_15khz = 1'b0;
    logic qn_csync = 1'b0;
    logic qn_sd, qn_retro, qn_cs;
    logic ce_ovl;
    logic analog_dbl;                 // must stay 0 here: this bench drives no 350-line raster

    analog_video_ctl i_ctl (
        .qnice_clk_i         (qclk),
        .qnice_vga_15khz_i   (qn_15khz),
        .qnice_vga_csync_i   (qn_csync),
        .qnice_scandoubler_o (qn_sd),
        .qnice_retro15khz_o  (qn_retro),
        .qnice_csync_o       (qn_cs),
        .video_clk_i         (clk),
        .video_mode13_i      (1'b0),
        .video_mode350_i     (1'b0),
        .video_analog_dbl_o  (analog_dbl),
        .video_ce_ovl_o      (ce_ovl)
    );

    logic vid_sd, vid_retro, vid_cs;
    xpm_cdc_array_single #(.WIDTH(3)) i_cdc (
        .src_clk  (qclk),
        .src_in   ({qn_cs, qn_sd, qn_retro}),
        .dest_clk (clk),
        .dest_out ({vid_cs, vid_sd, vid_retro})
    );

    //-----------------------------------------------------------------------------------------------
    // synthetic core raster (clk_57_ps domain, the pcxt_core.sv output contract)
    //-----------------------------------------------------------------------------------------------
    int   hpos = 0, vpos = 0;      // dot / line currently emitted
    int   sub  = 0;                // clock within the dot
    int   hold = 0;                // idle clocks inserted before the next dot (phase shift)
    int   hold_req = 0;            // requested shift, applied once at line V_ACT+8
    int   frame_no = 0;
    logic ce   = 1'b0;
    logic hs_r = 1'b0, vs_r = 1'b0, hb_r = 1'b1, vb_r = 1'b1;
    logic [7:0] r_r = 8'd0, g_r = 8'd0, b_r = 8'd0;
    int   nx, ny;

    always_comb begin
        nx = (hpos == H_TOTAL - 1) ? 0 : hpos + 1;
        ny = (hpos == H_TOTAL - 1) ? ((vpos == V_TOTAL - 1) ? 0 : vpos + 1) : vpos;
    end

    always @(posedge clk) begin
        ce <= 1'b0;
        if (hold > 0) begin
            hold <= hold - 1;
        end else if (sub == CPP - 1) begin
            sub  <= 0;
            ce   <= 1'b1;                                      // CE_PIXEL: one clock per dot
            hpos <= nx;
            vpos <= ny;
            hs_r <= (nx >= HS_START) && (nx < HS_START + HS_LEN);   // VGA_HS coincident with CE
            if (nx == HS_START) vs_r <= (ny >= VS_START) && (ny < VS_START + VS_LEN);
            if (nx == 0 && ny == 0) frame_no <= frame_no + 1;
            if (nx == 0 && ny == V_ACT + 8 && hold_req != 0) begin
                hold     <= hold_req;
                hold_req <= 0;
            end
        end else begin
            sub <= sub + 1;
        end
        if (ce) begin                                          // one clock after CE: credits pxl_cen stage
            hb_r <= (hpos >= H_ACT);
            vb_r <= (vpos >= V_ACT);
            if (hpos < H_ACT && vpos < V_ACT) begin
                r_r <= hpos[7:0];
                g_r <= vpos[7:0];
                b_r <= {hpos[9:8], 6'b101010};
            end else begin
                r_r <= 8'd0;
                g_r <= 8'd0;
                b_r <= 8'd0;
            end
        end
    end

    //-----------------------------------------------------------------------------------------------
    // DUT: the framework analog pipeline with the port's generics
    //-----------------------------------------------------------------------------------------------
    logic [7:0] vga_r, vga_g, vga_b;
    logic       vga_hs, vga_vs, vdac_clk, vdac_syncn, vdac_blankn;
    logic [15:0] osm_vram_addr;

    // analog_line_doubler is inside analog_pipeline (gen_analog_dbl); this bench never drives a
    // 350-line raster, so it stays in bypass and every case below also proves the bypass is a
    // transparent, zero-latency copy of video_mixer's output.

    // analog_pipeline_wrap.vhd = the unmodified analog_pipeline with video_osm_cfg_scaling_i (a
    // "natural range 0 to 8", which xelab cannot bind from Verilog) tied to 0
    analog_pipeline_wrap #(
        .G_ANALOG_LINE_DOUBLER (1),
        .G_VGA_DX    (720),
        .G_VGA_DY    (576),
        .G_FONT_FILE (FONT_FILE),
        .G_FONT_DX   (16),
        .G_FONT_DY   (16)
    ) dut (
        .video_clk_i             (clk),
        .video_rst_i             (1'b0),
        .video_ce_i              (ce),
        .video_ce_ovl_i          (ce_ovl),
        .video_red_i             (r_r),
        .video_green_i           (g_r),
        .video_blue_i            (b_r),
        .video_hs_i              (hs_r),
        .video_vs_i              (vs_r),
        .video_hblank_i          (hb_r),
        .video_vblank_i          (vb_r),
        .video_analog_dbl_i      (analog_dbl),
        .audio_clk_i             (qclk),
        .audio_rst_i             (1'b0),
        .audio_left_i            (16'd0),
        .audio_right_i           (16'd0),
        .video_scandoubler_i     (vid_sd),
        .video_csync_i           (vid_cs),
        .video_retro15kHz_i      (vid_retro),
        .vga_red_o               (vga_r),
        .vga_green_o             (vga_g),
        .vga_blue_o              (vga_b),
        .vga_hs_o                (vga_hs),
        .vga_vs_o                (vga_vs),
        .vdac_clk_o              (vdac_clk),
        .vdac_syncn_o            (vdac_syncn),
        .vdac_blankn_o           (vdac_blankn),
        .video_osm_cfg_enable_i  (1'b0),
        .video_osm_cfg_xy_i      (16'd0),
        .video_osm_cfg_dxdy_i    (16'd0),
        .video_osm_vram_addr_o   (osm_vram_addr),
        .video_osm_vram_data_i   (16'd0)
    );

    //-----------------------------------------------------------------------------------------------
    // measurement state (everything sampled on the rising edge; the pins change on the falling edge)
    //-----------------------------------------------------------------------------------------------
    logic   measuring = 1'b0;     // accumulate sync statistics
    logic   check_en  = 1'b0;     // run the pixel checker
    logic   in_vs_gate = 1'b0;    // 1 around the raster's VS (case C: composite sync region)
    int     exp_hold  = 2;        // clocks each output pixel must be held
    int     exp_rep   = 2;        // output lines per input line
    int     errors    = 0;        // pixel-checker errors in the current window
    int     total_fail = 0;
    int     total_pass = 0;
    int     max_print = 12;

    // HS pin
    logic   hs_q = 1'b0, vs_q = 1'b0;
    longint hs_rise_t = -1, hs_fall_t = -1, vs_rise_t = -1;
    longint hs_high = 0, hs_low = 0, hs_per = 0;
    longint st_per_min, st_per_max, st_hi_min, st_hi_max, st_lo_min, st_lo_max;
    longint st_vs_per, st_vs_hi;
    int     st_lines, st_lines_gen, st_hs_n, st_vs_n;
    int     hs_in_frame = 0;          // HS rises between VS-pin rises
    int     hs_in_genframe = 0;       // HS rises between raster VS rises
    logic   gen_vs_q = 1'b0;
    longint gen_vs_fall_t = 0;

    // pixels
    logic [7:0] r_q = 8'd0, g_q = 8'd0, b_q = 8'd0;
    logic   in_line = 1'b0;
    int     pix_hold = 0, line_pix = 0, cur_x = 0, cur_y = 0;
    int     prev_line_y = -1, same_y = 0;
    int     st_pix_min, st_pix_max, st_act_lines, act_in_frame = 0;
    longint st_bp_min, st_bp_max, st_fp_min, st_fp_max, line_end_t = -1;
    int     st_par0 = 0, st_par1 = 0;   // ce_ovl value seen at the pixel enable
    logic   vs_pin_moved = 1'b0;

    // runtime switch
    logic   sw_active = 1'b0;
    logic   sw_done   = 1'b0;
    longint sw_t = 0, sw_settle = 0, sw_new_per = 0, sw_new_hi = 0;
    int     sw_nominal_run = 0, sw_abnormal = 0, sw_first_bad = 0;

    // composite-sync run-length recorder (case C)
    localparam int RL_MAX = 96;
    logic   rl_en = 1'b0;
    int     rl_n = 0;
    longint rl_len [0:RL_MAX-1];
    logic   rl_lvl [0:RL_MAX-1];
    longint rl_cur = 0;
    logic   rl_q = 1'b1;

    function automatic int dec_x(input logic [7:0] r, input logic [7:0] b);
        dec_x = {b[7:6], r};
    endfunction

    task automatic err(input string s);
        if (check_en) begin
            errors++;
            if (errors <= max_print) $display("  ERR @%0t cyc=%0d: %s", $time, cyc, s);
        end
    endtask

    task automatic clear_stats();
        st_per_min = 1 << 40; st_per_max = 0; st_hi_min = 1 << 40; st_hi_max = 0;
        st_lo_min = 1 << 40; st_lo_max = 0;
        st_vs_per = 0; st_vs_hi = 0; st_lines = 0; st_lines_gen = 0; st_hs_n = 0; st_vs_n = 0;
        st_pix_min = 1 << 30; st_pix_max = 0; st_act_lines = 0;
        st_bp_min = 1 << 40; st_bp_max = 0; st_fp_min = 1 << 40; st_fp_max = 0;
        st_par0 = 0; st_par1 = 0; errors = 0; prev_line_y = -1; same_y = 0;
        vs_pin_moved = 1'b0;
    endtask

    // window around the raster's VS in which the composite sync carries the serration pattern:
    // from the VS rising edge until two lines after it falls (the pins lag the raster by < 1 line)
    always @(posedge clk) begin
        gen_vs_q <= vs_r;
        if (vs_r && !gen_vs_q) in_vs_gate <= 1'b1;
        if (!vs_r && gen_vs_q) gen_vs_fall_t <= cyc;
        if (in_vs_gate && !vs_r && !gen_vs_q && (cyc - gen_vs_fall_t) > 2 * LINE_CLK) in_vs_gate <= 1'b0;
    end

    // parity of the overlay enable against the pixel enable
    always @(posedge clk) begin
        if (ce && measuring) begin
            if (ce_ovl) st_par1++; else st_par0++;
        end
    end

    // sync pins
    always @(posedge clk) begin
        hs_q <= vga_hs;
        vs_q <= vga_vs;

        if (vs_r && !gen_vs_q) begin                  // raster frame boundary
            if (measuring) st_lines_gen = hs_in_genframe;
            hs_in_genframe = 0;
        end

        if (vga_hs && !hs_q) begin
            hs_in_frame++;
            if (!in_vs_gate) hs_in_genframe++;
            if (hs_rise_t >= 0) begin
                hs_per = cyc - hs_rise_t;
                hs_low = cyc - hs_fall_t;
                if (measuring && !in_vs_gate) begin
                    st_hs_n++;
                    if (hs_per < st_per_min) st_per_min = hs_per;
                    if (hs_per > st_per_max) st_per_max = hs_per;
                    if (hs_low < st_lo_min) st_lo_min = hs_low;
                    if (hs_low > st_lo_max) st_lo_max = hs_low;
                end
                if (sw_active && !sw_done) begin
                    if (hs_per == sw_new_per && hs_high == sw_new_hi) begin
                        sw_nominal_run++;
                        if (sw_nominal_run == 3) begin
                            sw_done   = 1'b1;
                            sw_settle = (cyc - 3 * sw_new_per) - sw_t;
                        end
                    end else begin
                        sw_nominal_run = 0;
                        sw_abnormal++;
                    end
                end
                if (line_end_t >= 0 && measuring) begin
                    if (cyc - line_end_t < st_fp_min) st_fp_min = cyc - line_end_t;
                    if (cyc - line_end_t > st_fp_max) st_fp_max = cyc - line_end_t;
                end
            end
            hs_rise_t = cyc;
        end
        if (!vga_hs && hs_q) begin
            hs_high = cyc - hs_rise_t;
            if (measuring && !in_vs_gate) begin
                if (hs_high < st_hi_min) st_hi_min = hs_high;
                if (hs_high > st_hi_max) st_hi_max = hs_high;
            end
            hs_fall_t = cyc;
        end

        if (vga_vs !== vs_q) vs_pin_moved = 1'b1;
        if (vga_vs && !vs_q) begin
            if (vs_rise_t >= 0 && measuring) begin
                st_vs_per = cyc - vs_rise_t;
                st_lines  = hs_in_frame;
                st_vs_n++;
            end
            vs_rise_t = cyc;
            hs_in_frame = 0;
        end
        if (!vga_vs && vs_q) begin
            if (measuring) st_vs_hi = cyc - vs_rise_t;
        end
    end

    // composite sync run lengths
    always @(posedge clk) begin
        if (rl_en) begin
            if (vga_hs !== rl_q || rl_n == 0) begin
                if (rl_n > 0 && rl_n <= RL_MAX) begin
                    rl_len[rl_n-1] = rl_cur;
                    rl_lvl[rl_n-1] = rl_q;
                end
                if (rl_n < RL_MAX) rl_n++;
                rl_cur = 1;
            end else begin
                rl_cur++;
            end
            rl_q <= vga_hs;
        end
    end

    // pixel checker: every active pixel must be the expected one, held exp_hold clocks, 640 per line,
    // each input line repeated exp_rep times, 200 input lines per frame
    always @(posedge clk) begin
        logic active;
        int   x, y;
        active = (vga_b != 8'd0) || (vga_r != 8'd0) || (vga_g != 8'd0);
        x = dec_x(vga_r, vga_b);
        y = vga_g;

        if (active) begin
            if (!in_line) begin
                in_line  = 1'b1;
                line_pix = 0;
                cur_x    = x;
                cur_y    = y;
                pix_hold = 1;
                if (x != 0) err($sformatf("line starts at x=%0d (y=%0d)", x, y));
                if (vga_b[5:0] != 6'b101010) err($sformatf("bad marker %02x/%02x/%02x", vga_r, vga_g, vga_b));
                if (measuring && hs_rise_t >= 0) begin
                    if (cyc - hs_rise_t < st_bp_min) st_bp_min = cyc - hs_rise_t;
                    if (cyc - hs_rise_t > st_bp_max) st_bp_max = cyc - hs_rise_t;
                end
            end else if ({vga_r, vga_g, vga_b} != {r_q, g_q, b_q}) begin
                if (pix_hold != exp_hold) err($sformatf("pixel x=%0d y=%0d held %0d clocks (expected %0d)", cur_x, cur_y, pix_hold, exp_hold));
                line_pix++;
                if (x != cur_x + 1) err($sformatf("x jumps %0d -> %0d (y=%0d)", cur_x, x, y));
                if (y != cur_y) err($sformatf("y changes mid-line %0d -> %0d at x=%0d", cur_y, y, x));
                if (vga_b[5:0] != 6'b101010) err($sformatf("bad marker %02x/%02x/%02x", vga_r, vga_g, vga_b));
                cur_x    = x;
                pix_hold = 1;
            end else begin
                pix_hold++;
            end
        end else if (in_line) begin
            if (pix_hold != exp_hold) err($sformatf("last pixel x=%0d y=%0d held %0d clocks (expected %0d)", cur_x, cur_y, pix_hold, exp_hold));
            line_pix++;
            if (line_pix != H_ACT) err($sformatf("line y=%0d has %0d pixels", cur_y, line_pix));
            if (cur_x != H_ACT - 1) err($sformatf("line y=%0d ends at x=%0d", cur_y, cur_x));
            if (measuring) begin
                if (line_pix < st_pix_min) st_pix_min = line_pix;
                if (line_pix > st_pix_max) st_pix_max = line_pix;
                st_act_lines++;
            end
            act_in_frame++;
            if (cur_y == prev_line_y) begin
                same_y++;
            end else begin
                if (prev_line_y >= 0 && same_y != exp_rep) err($sformatf("y=%0d output %0d times (expected %0d)", prev_line_y, same_y, exp_rep));
                if (prev_line_y >= 0 && cur_y != prev_line_y + 1 && cur_y != 0) err($sformatf("y jumps %0d -> %0d", prev_line_y, cur_y));
                if (prev_line_y >= 0 && cur_y == 0 && prev_line_y != V_ACT - 1) err($sformatf("frame ends at y=%0d", prev_line_y));
                same_y = 1;
            end
            prev_line_y = cur_y;
            line_end_t  = cyc;
            in_line     = 1'b0;
        end
        r_q <= vga_r;
        g_q <= vga_g;
        b_q <= vga_b;
    end

    // active lines per frame (counted between the raster's VS rises, so it also works with csync)
    int st_act_frame = 0;
    always @(posedge clk) begin
        if (vs_r && !gen_vs_q) begin
            if (measuring) st_act_frame = act_in_frame;
            act_in_frame = 0;
        end
    end

    //-----------------------------------------------------------------------------------------------
    // sequencer
    //-----------------------------------------------------------------------------------------------
    task automatic wait_frames(input int n);
        int target;
        target = frame_no + n;
        wait (frame_no >= target);
        @(posedge clk);
    endtask

    task automatic measure(input string name, input int frames, input int phase,
                           input longint e_per, input longint e_hi, input int e_lines,
                           input longint e_vs_hi, input logic csync);
        logic ok;
        real  hkhz, vhz;
        clear_stats();
        @(posedge clk);
        measuring = 1'b1;
        check_en  = 1'b1;
        wait_frames(frames);
        measuring = 1'b0;
        check_en  = 1'b0;
        ok = 1'b1;
        if (st_per_min != e_per || st_per_max != e_per) ok = 0;
        if (!csync) begin
            if (st_hi_min != e_hi || st_hi_max != e_hi) ok = 0;            // positive HS pulse
        end else begin
            if (st_lo_min != e_hi || st_lo_max != e_hi) ok = 0;            // active-low composite sync
            if (st_hi_min != e_per - e_hi || st_hi_max != e_per - e_hi) ok = 0;
        end
        if (!csync) begin
            if (st_lines != e_lines) ok = 0;
            if (st_vs_per != FRAME_CLK) ok = 0;
            if (st_vs_hi != e_vs_hi) ok = 0;
            if (st_vs_n < 1) ok = 0;
        end else begin
            if (vs_pin_moved) ok = 0;          // VS pin must be held at 1 with csync
            if (vga_vs !== 1'b1) ok = 0;
        end
        if (st_pix_min != H_ACT || st_pix_max != H_ACT) ok = 0;
        if (st_act_frame != V_ACT * exp_rep) ok = 0;
        if (errors != 0) ok = 0;
        if (st_par0 != 0 && st_par1 != 0) ok = 0;   // enable parity must be constant
        hkhz = 57272.0 / real'(e_per);
        vhz  = 57272000.0 / real'(FRAME_CLK);
        $display("RESULT %s phase=%0d: %s | HS period %0d..%0d clk (%.2f kHz nominal), HS %s pulse %0d..%0d clk, HS low %0d..%0d clk | VS %s period %0d clk (%.2f Hz) high %0d clk, lines/frame %0d (VS pin) %0d (HS outside VS gate) | active %0d..%0d px/line, %0d lines/frame, back porch %0d..%0d clk, front porch %0d..%0d clk | ce_ovl@ce: %0d x 0, %0d x 1 | pixel errors %0d",
                 name, phase, ok ? "PASS" : "FAIL",
                 st_per_min, st_per_max, hkhz,
                 (st_hi_max < st_lo_min) ? "positive" : "NEGATIVE",
                 st_hi_min, st_hi_max, st_lo_min, st_lo_max,
                 csync ? (vs_pin_moved ? "MOVED" : "held 1") : "positive",
                 st_vs_per, vhz, st_vs_hi, st_lines, st_lines_gen,
                 st_pix_min, st_pix_max, st_act_frame, st_bp_min, st_bp_max, st_fp_min, st_fp_max,
                 st_par0, st_par1, errors);
        if (ok) total_pass++; else total_fail++;
    endtask

    int ph = 0;                       // accumulated pixel-enable shift in clocks (mod 4)
    task automatic set_phase(input int k);
        hold_req = k;
        ph = (ph + k) % CPP;
        wait_frames(1);
    endtask

    task automatic dump_runs(input string name);
        int i;
        $write("CSYNC %s HS-pin run lengths through VS (level:clocks):", name);
        for (i = 0; i < rl_n && i < RL_MAX; i++) $write(" %0d:%0d", rl_lvl[i], rl_len[i]);
        $display("");
    endtask

    task automatic switch_test(input string name, input logic to_15k, input longint new_per, input longint new_hi);
        int f;
        // mid-frame, mid-line
        wait (vpos == 100 && hpos == 300);
        @(posedge qclk);
        sw_t = cyc; sw_done = 1'b0; sw_nominal_run = 0; sw_abnormal = 0;
        sw_new_per = new_per; sw_new_hi = new_hi;
        sw_active = 1'b1;
        qn_15khz  = to_15k;
        wait (sw_done);
        sw_active = 1'b0;
        // is the first full frame after the switch clean?
        exp_hold = to_15k ? 4 : 2;
        exp_rep  = to_15k ? 1 : 2;
        wait_frames(1);
        clear_stats();
        measuring = 1'b1; check_en = 1'b1;
        wait_frames(1);
        measuring = 1'b0; check_en = 1'b0;
        $display("RESULT %s: settled %0d clk (%.1f us, %.2f old lines) after the menu bit changed, %0d off-nominal HS pulses; first full frame after the switch: %0d px errors, active %0d..%0d px/line, %0d lines -> %s",
                 name, sw_settle, real'(sw_settle) * T_VID / 1000.0, real'(sw_settle) / real'(LINE_CLK),
                 sw_abnormal, errors, st_pix_min, st_pix_max, st_act_frame,
                 (errors == 0 && st_act_frame == V_ACT * exp_rep && sw_settle < 2 * LINE_CLK) ? "PASS" : "FAIL");
        if (errors == 0 && st_act_frame == V_ACT * exp_rep && sw_settle < 2 * LINE_CLK) total_pass++; else total_fail++;
    endtask

    initial begin
        int k;
        $display("APT analog_pipeline_tb: 912x262 dots @ 14.318 MHz (4 clk/dot), 640x200 active, HS +%0d dots @%0d, VS +%0d lines @%0d; line %0d clk, frame %0d clk",
                 HS_LEN, HS_START, VS_LEN, VS_START, LINE_CLK, FRAME_CLK);

        // ---- A: VGA 31 kHz (default) ----
        qn_15khz = 1'b0; qn_csync = 1'b0;
        exp_hold = 2; exp_rep = 2;
        wait_frames(3);                                   // doubler measures, buffers fill
        measure("A_sd_on", 2, ph, LINE_CLK / 2, HS_LEN * CPP / 2, 2 * V_TOTAL, VS_LEN * LINE_CLK, 1'b0);
        for (k = 1; k <= 3; k++) begin
            set_phase(1);                                 // shift the pixel enable by one clock
            wait_frames(2);
            measure("A_sd_on", 2, ph, LINE_CLK / 2, HS_LEN * CPP / 2, 2 * V_TOTAL, VS_LEN * LINE_CLK, 1'b0);
        end

        // ---- B: VGA 15 kHz ----
        qn_15khz = 1'b1; qn_csync = 1'b0;
        exp_hold = 4; exp_rep = 1;
        wait_frames(2);
        measure("B_15k", 2, ph, LINE_CLK, HS_LEN * CPP, V_TOTAL, VS_LEN * LINE_CLK, 1'b0);
        set_phase(1);
        wait_frames(2);
        measure("B_15k", 2, ph, LINE_CLK, HS_LEN * CPP, V_TOTAL, VS_LEN * LINE_CLK, 1'b0);

        // ---- C: VGA 15 kHz + CSync ----
        qn_15khz = 1'b1; qn_csync = 1'b1;
        wait_frames(2);
        // record the composite sync through one VS
        wait (vpos == VS_START - 2 && hpos == 0);
        rl_n = 0; rl_cur = 0; rl_en = 1'b1;
        wait (vpos == VS_START + VS_LEN + 3 && hpos == 0);
        rl_en = 1'b0;
        dump_runs("C_15k_csync");
        measure("C_15k_csync", 2, ph, LINE_CLK, HS_LEN * CPP, V_TOTAL, 0, 1'b1);
        set_phase(1);
        wait_frames(2);
        measure("C_15k_csync", 2, ph, LINE_CLK, HS_LEN * CPP, V_TOTAL, 0, 1'b1);

        // ---- D: runtime switching ----
        qn_csync = 1'b0;
        qn_15khz = 1'b0;
        exp_hold = 2; exp_rep = 2;
        wait_frames(3);
        switch_test("D_31k_to_15k", 1'b1, LINE_CLK, HS_LEN * CPP);
        wait_frames(1);
        switch_test("D_15k_to_31k", 1'b0, LINE_CLK / 2, HS_LEN * CPP / 2);

        $display("APT RESULT: %s pass=%0d fail=%0d", (total_fail == 0) ? "PASS" : "FAIL", total_pass, total_fail);
        $finish;
    end

endmodule
