`timescale 1ns / 1ps
//---------------------------------------------------------------------------------------------------
// analog_pipeline_350_tb: the real MiSTer2MEGA65 analog (VGA connector) path of this port, driven with
// the PCXT-EGA 350-line raster (EGA 640x350 / MDA-style, 16.257 MHz NCO dot enable) and measured at the
// VGA pins. Sibling of analog_pipeline_tb.sv, which does the same for the 200-line raster.
//
// DUT = what CORE/vhdl/mega65.vhd, M2M/vhdl/top_mega65-r6.vhd and M2M/vhdl/av_pipeline/av_pipeline.vhd
// wire together for the analog branch:
//   CORE/vhdl/analog_video_ctl.vhd        menu + video_mode350 -> qnice_scandoubler / retro15kHz / csync,
//                                         video_analog_dbl, video_ce_ovl
//   xpm_cdc_array_single (WIDTH only, as av_pipeline.vhd:272-296)   QNICE -> video clock CDC
//   M2M/vhdl/av_pipeline/analog_pipeline.vhd   video_mixer.sv (scandoubler.v, hq2x.sv, video_freezer.sv),
//                                         CORE/vhdl/analog_line_doubler.vhd beside it (gen_analog_dbl),
//                                         video_overlay.vhd (vga_recover_counters.vhd, vga_osm.vhd),
//                                         csync.sv, falling-edge output registers
// with the generics of CORE/vhdl/globals.vhd. The two xsim-only adaptations are the same as in
// analog_pipeline_tb.sv and are described there and in run_analog_pipeline_350_tb.ps1; no M2M source is
// modified for the bench.
//
// Stimulus: the EGA 350-line raster as pcxt_core.sv emits it in clk_57_ps.
//   * 744 dots x 364 lines, 640x350 active, HS positive 64 dots from dot 664, VS positive 3 lines from
//     line 355 changing at the HS rising edge (UM6845R.v hsync_dot_rise). 16.257 MHz / 21.85 kHz / 60 Hz.
//   * the dot enable is the real mechanism, not a divider: ega_dot_clock.v:11-19 runs an NCO of
//     59609/105000 in the 28.636 MHz domain, restarted once per CRTC line (line_lock, :80-86), and
//     pcxt_core.sv:1762-1771 crosses it into the 57.27 MHz domain as a toggle plus one synchroniser and
//     an XOR. Dots therefore land on alternate video clocks only and are 2 OR 4 clocks apart (76 % / 24 %
//     for an average of 3.523), which is exactly what the framework's scandoubler cannot resample: it
//     latches ONE pixel size in the visible area (scandoubler.v:64-91) and samples at that fixed spacing.
//   * HS/VS are updated on the same clock as the pixel enable, RGB / hblank / vblank one clock later,
//     the pcxt_core.sv retime + jtframe_credits pxl_cen contract that analog_pipeline_tb.sv also models.
//   * every active pixel encodes its position: R = x[7:0], G = y[7:0], B = {x[9:8], y[9:8], 4'b1010},
//     so the pins can be checked column by column and line by line over a 640x350 grid.
//
// Cases ("before" = the analog path as it behaved before analog_line_doubler.vhd existed)
//   A  before, 31 kHz menu: analog_video_ctl does not know about the 350-line raster, so the FRAMEWORK
//      scandoubler is on. Evidence only - this is the corruption the new module exists to avoid.
//   B  before, 15 kHz menu: everything off, the native 21.8 kHz raster straight through. Pixel-exact.
//   C  after, 31 kHz menu: framework scandoubler off, analog_line_doubler on. 43.7 kHz, 700 active
//      lines, unchanged frame rate, and the pixel sequence must be the input line replayed twice with
//      no column skipped or duplicated.
//   D  after, 15 kHz menu: must be byte-identical to B - the 15 kHz settings are not to change.
//   E  runtime entry into and exit from a 350-line mode, mid-frame.
// Each case prints one "RESULT" line; the last line is "A350 RESULT: PASS/FAIL ...".
//
// Run: powershell -File CORE/rtl/tb/run_analog_pipeline_350_tb.ps1
//---------------------------------------------------------------------------------------------------

module analog_pipeline_350_tb #(
    parameter string FONT_FILE = "../../../M2M/font/Anikki-16x16-m2m.rom"
);

    localparam real T_VID = 17.461;   // 57.27 MHz  (clk_57_ps)
    localparam real T_QN  = 20.0;     // 50 MHz     (QNICE)

    // the port's 350-line raster, in dots / lines
    localparam int H_TOTAL  = 744;    // 93 character clocks of 8 dots
    localparam int H_ACT    = 640;
    localparam int HS_START = 664;
    localparam int HS_LEN   = 64;
    localparam int V_TOTAL  = 364;
    localparam int V_ACT    = 350;
    localparam int VS_START = 355;
    localparam int VS_LEN   = 3;

    // ega_dot_clock.v:15,:28-29 - the exact 16.257 MHz ratio against 315/11 MHz
    localparam int NCO_INC = 59609;
    localparam int NCO_MOD = 105000;

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
    // menu bits + the core's mode hints -> analog_video_ctl -> framework CDC
    // (exactly as mega65.vhd / av_pipeline.vhd wire them)
    //-----------------------------------------------------------------------------------------------
    logic qn_15khz  = 1'b0;
    logic qn_csync  = 1'b0;
    logic core_m350 = 1'b0;       // pcxt_core video_mode350_o
    logic ctl_m350  = 1'b0;       // what analog_video_ctl is told (0 in the "before" cases)
    logic qn_sd, qn_retro, qn_cs;
    logic ce_ovl, analog_dbl;

    analog_video_ctl i_ctl (
        .qnice_clk_i         (qclk),
        .qnice_vga_15khz_i   (qn_15khz),
        .qnice_vga_csync_i   (qn_csync),
        .qnice_scandoubler_o (qn_sd),
        .qnice_retro15khz_o  (qn_retro),
        .qnice_csync_o       (qn_cs),
        .video_clk_i         (clk),
        .video_mode13_i      (1'b0),
        .video_mode350_i     (ctl_m350),
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
    // synthetic 350-line core raster (clk_57_ps domain, the pcxt_core.sv output contract)
    //-----------------------------------------------------------------------------------------------
    int   hpos = 0, vpos = 0;
    int   acc  = NCO_INC;
    logic ph   = 1'b1;             // 1 = the clock on which the 28.636 MHz accumulator steps
    int   hold = 0, hold_req = 0;  // insert idle clocks to shift the generator's phase against clk
    int   frame_no = 0;
    logic ce   = 1'b0;
    logic hs_r = 1'b0, vs_r = 1'b0, hb_r = 1'b1, vb_r = 1'b1;
    logic [7:0] r_r = 8'd0, g_r = 8'd0, b_r = 8'd0;
    int   nx, ny;

    wire acc_wrap = (acc + NCO_INC) >= NCO_MOD;
    wire ce_pre   = (hold == 0) && (ph == 1'b1) && acc_wrap;   // the dot lands on the next clock

    always_comb begin
        nx = (hpos == H_TOTAL - 1) ? 0 : hpos + 1;
        ny = (hpos == H_TOTAL - 1) ? ((vpos == V_TOTAL - 1) ? 0 : vpos + 1) : vpos;
    end

    always @(posedge clk) begin
        if (hold > 0) begin
            hold <= hold - 1;
            ce   <= 1'b0;
        end else begin
            ph <= ~ph;
            if (ph == 1'b1) begin
                if (ce_pre && hpos == H_TOTAL - 1)
                    acc <= NCO_INC;                            // ega_dot_clock.v:85 line lock
                else if (acc_wrap)
                    acc <= acc + NCO_INC - NCO_MOD;
                else
                    acc <= acc + NCO_INC;
            end

            ce <= ce_pre;
            if (ce_pre) begin                                  // CE_PIXEL and the syncs move together
                hpos <= nx;
                vpos <= ny;
                hs_r <= (nx >= HS_START) && (nx < HS_START + HS_LEN);
                if (nx == HS_START) vs_r <= (ny >= VS_START) && (ny < VS_START + VS_LEN);
                if (nx == 0 && ny == 0) frame_no <= frame_no + 1;
                if (nx == 0 && ny == V_ACT + 4 && hold_req != 0) begin
                    hold     <= hold_req;
                    hold_req <= 0;
                end
            end
            if (ce) begin                                      // one clock later: credits pxl_cen stage
                hb_r <= (hpos >= H_ACT);
                vb_r <= (vpos >= V_ACT);
                if (hpos < H_ACT && vpos < V_ACT) begin
                    r_r <= hpos[7:0];
                    g_r <= vpos[7:0];
                    b_r <= {hpos[9:8], vpos[9:8], 4'b1010};
                end else begin
                    r_r <= 8'd0;
                    g_r <= 8'd0;
                    b_r <= 8'd0;
                end
            end
        end
    end

    // geometry of the stimulus, measured rather than assumed
    logic   in_hs_q = 1'b0, in_vs_q = 1'b0;
    longint in_hs_t = -1, in_vs_t = -1;
    longint in_line_clk = 0, in_frame_clk = 0;
    int     in_dots = 0, in_dots_line = 0;
    int     gap_min = 1 << 20, gap_max = 0, gap_n = 0;
    longint gap_sum = 0, last_ce_t = -1;
    int     gap_hist [0:7];

    always @(posedge clk) begin
        in_hs_q <= hs_r;
        in_vs_q <= vs_r;
        if (hs_r && !in_hs_q) begin
            if (in_hs_t >= 0) begin
                in_line_clk = cyc - in_hs_t;
                in_dots     = in_dots_line;
            end
            in_hs_t = cyc;
            in_dots_line = 0;
        end
        if (vs_r && !in_vs_q) begin
            if (in_vs_t >= 0) in_frame_clk = cyc - in_vs_t;
            in_vs_t = cyc;
        end
        if (ce) begin
            in_dots_line++;
            if (last_ce_t >= 0) begin
                automatic int g = int'(cyc - last_ce_t);
                if (g < gap_min) gap_min = g;
                if (g > gap_max) gap_max = g;
                if (g < 8) gap_hist[g]++;
                gap_sum += g;
                gap_n++;
            end
            last_ce_t = cyc;
        end
    end

    //-----------------------------------------------------------------------------------------------
    // DUT: the framework analog path with analog_line_doubler inside it (analog_pipeline.vhd
    // gen_analog_dbl, beside video_mixer - see the header of analog_line_doubler.vhd for why it
    // cannot sit in front of the mixer)
    //-----------------------------------------------------------------------------------------------
    logic [7:0] vga_r, vga_g, vga_b;
    logic       vga_hs, vga_vs, vdac_clk, vdac_syncn, vdac_blankn;
    logic [15:0] osm_vram_addr;

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
    // measurement (everything sampled on the rising edge; the pins change on the falling edge)
    //-----------------------------------------------------------------------------------------------
    logic   measuring = 1'b0;
    logic   check_en  = 1'b0;
    int     exp_rep   = 1;        // output lines per input line
    int     hold_lo   = 2;        // clocks each output pixel must be held, min / max
    int     hold_hi   = 4;
    int     errors    = 0;
    int     total_fail = 0;
    int     total_pass = 0;
    int     max_print = 10;

    logic   hs_q = 1'b0, vs_q = 1'b0;
    longint hs_rise_t = -1, hs_fall_t = -1, vs_rise_t = -1;
    longint hs_high = 0, hs_low = 0, hs_per = 0;
    longint st_per_min, st_per_max, st_hi_min, st_hi_max, st_lo_min, st_lo_max;
    longint st_vs_per, st_vs_hi;
    int     st_lines, st_hs_n, st_vs_n;
    int     hs_in_frame = 0;
    logic   gen_vs_q = 1'b0;

    logic [7:0] r_q = 8'd0, g_q = 8'd0, b_q = 8'd0;
    logic   in_line = 1'b0;
    int     pix_hold = 0, line_pix = 0, cur_x = 0, cur_y = 0;
    int     prev_line_y = -1, same_y = 0;
    int     st_pix_min, st_pix_max, st_hold_min, st_hold_max, st_act_lines, act_in_frame = 0;
    int     st_act_frame = 0;
    int     st_bad_cols = 0;      // columns that are missing or repeated (the case-A evidence)

    // runtime switch
    logic   sw_active = 1'b0, sw_done = 1'b0;
    longint sw_t = 0, sw_settle = 0, sw_new_per = 0;
    int     sw_nominal_run = 0, sw_abnormal = 0;

    function automatic int dec_x(input logic [7:0] r, input logic [7:0] b);
        dec_x = {b[7:6], r};
    endfunction

    function automatic int dec_y(input logic [7:0] g, input logic [7:0] b);
        dec_y = {b[5:4], g};
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
        st_vs_per = 0; st_vs_hi = 0; st_lines = 0; st_hs_n = 0; st_vs_n = 0;
        st_pix_min = 1 << 30; st_pix_max = 0; st_act_lines = 0;
        st_hold_min = 1 << 30; st_hold_max = 0; st_bad_cols = 0;
        errors = 0; prev_line_y = -1; same_y = 0;
    endtask

    // sync pins
    always @(posedge clk) begin
        hs_q <= vga_hs;
        vs_q <= vga_vs;
        gen_vs_q <= vs_r;

        if (vga_hs && !hs_q) begin
            hs_in_frame++;
            if (hs_rise_t >= 0) begin
                hs_per = cyc - hs_rise_t;
                hs_low = cyc - hs_fall_t;
                if (measuring) begin
                    st_hs_n++;
                    if (hs_per < st_per_min) st_per_min = hs_per;
                    if (hs_per > st_per_max) st_per_max = hs_per;
                    if (hs_low < st_lo_min) st_lo_min = hs_low;
                    if (hs_low > st_lo_max) st_lo_max = hs_low;
                end
                if (sw_active && !sw_done) begin
                    if (hs_per >= sw_new_per - 3 && hs_per <= sw_new_per + 3) begin
                        sw_nominal_run++;
                        if (sw_nominal_run == 4) begin
                            sw_done   = 1'b1;
                            sw_settle = (cyc - 4 * sw_new_per) - sw_t;
                        end
                    end else begin
                        sw_nominal_run = 0;
                        sw_abnormal++;
                    end
                end
            end
            hs_rise_t = cyc;
        end
        if (!vga_hs && hs_q) begin
            hs_high = cyc - hs_rise_t;
            if (measuring) begin
                if (hs_high < st_hi_min) st_hi_min = hs_high;
                if (hs_high > st_hi_max) st_hi_max = hs_high;
            end
            hs_fall_t = cyc;
        end

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

    // pixel checker: every active pixel must be the expected one, 640 per line, in order,
    // each input line repeated exp_rep times, V_ACT input lines per frame
    always @(posedge clk) begin
        logic active;
        int   x, y;
        active = (vga_b != 8'd0) || (vga_r != 8'd0) || (vga_g != 8'd0);
        x = dec_x(vga_r, vga_b);
        y = dec_y(vga_g, vga_b);

        if (active) begin
            if (!in_line) begin
                in_line  = 1'b1;
                line_pix = 0;
                cur_x    = x;
                cur_y    = y;
                pix_hold = 1;
                if (x != 0) begin err($sformatf("line starts at x=%0d (y=%0d)", x, y)); st_bad_cols++; end
                if (vga_b[3:0] != 4'b1010) err($sformatf("bad marker %02x/%02x/%02x", vga_r, vga_g, vga_b));
            end else if ({vga_r, vga_g, vga_b} != {r_q, g_q, b_q}) begin
                if (measuring) begin
                    if (pix_hold < st_hold_min) st_hold_min = pix_hold;
                    if (pix_hold > st_hold_max) st_hold_max = pix_hold;
                end
                if (pix_hold < hold_lo || pix_hold > hold_hi)
                    err($sformatf("pixel x=%0d y=%0d held %0d clocks (expected %0d..%0d)", cur_x, cur_y, pix_hold, hold_lo, hold_hi));
                line_pix++;
                if (x != cur_x + 1) begin
                    err($sformatf("x jumps %0d -> %0d (y=%0d)", cur_x, x, y));
                    st_bad_cols++;
                end
                if (y != cur_y) err($sformatf("y changes mid-line %0d -> %0d at x=%0d", cur_y, y, x));
                if (vga_b[3:0] != 4'b1010) err($sformatf("bad marker %02x/%02x/%02x", vga_r, vga_g, vga_b));
                cur_x    = x;
                pix_hold = 1;
            end else begin
                pix_hold++;
            end
        end else if (in_line) begin
            line_pix++;
            if (line_pix != H_ACT) begin
                err($sformatf("line y=%0d has %0d pixels", cur_y, line_pix));
                st_bad_cols++;
            end
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
            in_line     = 1'b0;
        end
        r_q <= vga_r;
        g_q <= vga_g;
        b_q <= vga_b;
    end

    // active lines per frame, counted between the raster's own VS rises
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

    // evidence = 1: print the numbers but do not let them decide pass/fail (case A)
    task automatic measure(input string name, input int frames, input int phase,
                           input int e_rep, input logic evidence);
        logic ok;
        real  hkhz, vhz;
        longint e_per;
        clear_stats();
        @(posedge clk);
        measuring = 1'b1;
        check_en  = 1'b1;
        wait_frames(frames);
        measuring = 1'b0;
        check_en  = 1'b0;
        e_per = in_line_clk / e_rep;
        ok = 1'b1;
        // the regenerated line period may wobble by one clock between the two halves of a line;
        // the exact doubling is proved by the line count per frame and the unchanged frame period
        if (st_per_min < e_per - 2 || st_per_max > e_per + 2) ok = 0;
        if (st_hi_max >= st_lo_min) ok = 0;                       // HS must be a positive pulse
        if (st_lines != V_TOTAL * e_rep) ok = 0;
        if (st_vs_per != in_frame_clk) ok = 0;
        if (st_vs_hi != VS_LEN * in_line_clk) ok = 0;
        if (st_vs_n < 1) ok = 0;
        if (st_pix_min != H_ACT || st_pix_max != H_ACT) ok = 0;
        if (st_act_frame != V_ACT * e_rep) ok = 0;
        if (errors != 0) ok = 0;
        hkhz = 57272.0 / real'(e_per);
        vhz  = 57272000.0 / real'(in_frame_clk);
        $display("RESULT %s phase=%0d: %s%s | HS period %0d..%0d clk (nominal %0d = %.2f kHz), HS positive pulse %0d..%0d clk, low %0d..%0d clk | VS positive period %0d clk (%.2f Hz) high %0d clk, %0d lines/frame (expected %0d) | active %0d..%0d px/line, %0d lines/frame (expected %0d), pixel hold %0d..%0d clk | column faults %0d, pixel errors %0d",
                 name, phase, ok ? "PASS" : "FAIL", evidence ? " (EVIDENCE ONLY)" : "",
                 st_per_min, st_per_max, e_per, hkhz,
                 st_hi_min, st_hi_max, st_lo_min, st_lo_max,
                 st_vs_per, vhz, st_vs_hi, st_lines, V_TOTAL * e_rep,
                 st_pix_min, st_pix_max, st_act_frame, V_ACT * e_rep,
                 st_hold_min, st_hold_max, st_bad_cols, errors);
        if (!evidence) begin
            if (ok) total_pass++; else total_fail++;
        end
    endtask

    int ph_n = 0;
    task automatic set_phase(input int k);
        hold_req = k;
        ph_n = ph_n + k;
        wait_frames(2);
    endtask

    // strict = 1: the frame after the switch must also be pixel-exact. strict = 0 is used when the
    // destination state is the framework scandoubler on a 350-line raster, which is corrupt by
    // construction (case A) - only the sync settle time is meaningful there.
    task automatic switch_test(input string name, input logic to_350, input int e_rep, input logic strict);
        wait (vpos == 120 && hpos == 300);
        @(posedge clk);
        sw_t = cyc; sw_done = 1'b0; sw_nominal_run = 0; sw_abnormal = 0;
        sw_new_per = in_line_clk / e_rep;
        sw_active = 1'b1;
        ctl_m350  = to_350;
        core_m350 = to_350;
        fork
            wait (sw_done);
            begin  // never hang the bench if the new rate never settles
                repeat (40 * V_TOTAL * 800) @(posedge clk);
                if (!sw_done) begin sw_settle = -1; sw_done = 1'b1; end
            end
        join_any
        disable fork;
        sw_active = 1'b0;
        exp_rep = e_rep;
        hold_lo = strict ? ((e_rep == 2) ? 1 : 2) : 0;
        hold_hi = strict ? ((e_rep == 2) ? 2 : 4) : (1 << 20);
        wait_frames(2);
        clear_stats();
        measuring = 1'b1; check_en = 1'b1;
        wait_frames(1);
        measuring = 1'b0; check_en = 1'b0;
        $display("RESULT %s: settled %0d clk (%.1f us, %.2f source lines) after the hint changed, %0d off-nominal HS periods; next full frame: %0d px errors, active %0d..%0d px/line, %0d lines -> %s",
                 name, sw_settle, real'(sw_settle) * T_VID / 1000.0, real'(sw_settle) / real'(in_line_clk),
                 sw_abnormal, errors, st_pix_min, st_pix_max, st_act_frame,
                 ((!strict || errors == 0) && st_act_frame == V_ACT * e_rep && sw_settle >= 0 && sw_settle < 3 * in_line_clk) ? "PASS" : "FAIL");
        if ((!strict || errors == 0) && st_act_frame == V_ACT * e_rep && sw_settle >= 0 && sw_settle < 3 * in_line_clk) total_pass++; else total_fail++;
    endtask

    initial begin
        int i;
        for (i = 0; i < 8; i++) gap_hist[i] = 0;

        wait_frames(3);
        $display("A350 analog_pipeline_350_tb: %0dx%0d dots, %0dx%0d active, HS +%0d dots @%0d, VS +%0d lines @%0d",
                 H_TOTAL, V_TOTAL, H_ACT, V_ACT, HS_LEN, HS_START, VS_LEN, VS_START);
        $display("A350 stimulus measured: %0d dots/line, line %0d clk (%.3f kHz), frame %0d clk (%.2f Hz); CE_PIXEL gaps %0d..%0d clk, mean %.4f (2 clk x %0d, 4 clk x %0d) -> %.4f MHz dot rate",
                 in_dots, in_line_clk, 57272.0 / real'(in_line_clk), in_frame_clk, 57272000.0 / real'(in_frame_clk),
                 gap_min, gap_max, real'(gap_sum) / real'(gap_n), gap_hist[2], gap_hist[4],
                 57.272 * real'(gap_n) / real'(gap_sum));

        // ---- A: BEFORE - analog_video_ctl does not know about mode350, framework scandoubler on ----
        qn_15khz = 1'b0; qn_csync = 1'b0; ctl_m350 = 1'b0; core_m350 = 1'b0;
        exp_rep = 2; hold_lo = 0; hold_hi = 1 << 20;     // do not police the hold: this case is broken
        wait_frames(4);
        measure("A_before_31k_framework_sd", 2, ph_n, 2, 1'b1);

        // ---- B: BEFORE - 15 kHz menu, nothing doubled: the native 21.8 kHz raster ----
        qn_15khz = 1'b1;
        exp_rep = 1; hold_lo = 2; hold_hi = 4;
        wait_frames(3);
        measure("B_before_15k_native", 2, ph_n, 1, 1'b0);

        // ---- C: AFTER - 31 kHz menu with the 350-line hint: analog_line_doubler ----
        qn_15khz = 1'b0; ctl_m350 = 1'b1; core_m350 = 1'b1;
        exp_rep = 2; hold_lo = 1; hold_hi = 2;
        wait_frames(4);
        measure("C_after_31k_doubled", 2, ph_n, 2, 1'b0);
        for (i = 1; i <= 2; i++) begin
            set_phase(1);                                 // shift the generator one clock against clk
            wait_frames(3);
            measure("C_after_31k_doubled", 2, ph_n, 2, 1'b0);
        end

        // ---- D: AFTER - 15 kHz menu must be exactly what it was in B ----
        qn_15khz = 1'b1;
        exp_rep = 1; hold_lo = 2; hold_hi = 4;
        wait_frames(3);
        measure("D_after_15k_native", 2, ph_n, 1, 1'b0);

        // ---- E: runtime entry / exit of a 350-line mode ----
        qn_15khz = 1'b0;
        ctl_m350 = 1'b0; core_m350 = 1'b0;
        exp_rep = 2; hold_lo = 0; hold_hi = 1 << 20;
        wait_frames(4);
        switch_test("E_enter_350", 1'b1, 2, 1'b1);
        wait_frames(2);
        exp_rep = 2; hold_lo = 0; hold_hi = 1 << 20;
        switch_test("E_leave_350", 1'b0, 2, 1'b0);

        $display("A350 RESULT: %s pass=%0d fail=%0d", (total_fail == 0) ? "PASS" : "FAIL", total_pass, total_fail);
        $finish;
    end

endmodule
