// floppy_phy_spike_tb: bench for CORE/vhdl/floppy_phy_spike.vhd (MEGA65 R6 internal floppy drive spike).
//
// Models a 3.5" PC drive on the Shugart pins:
//   * outputs (TRACK0, WPT, DSKCHG, INDEX, RDATA) are only driven while DRIVE SELECT is low, as a real
//     drive's open-collector outputs are; DISK CHANGE latches on eject/insert and clears on a STEP pulse
//     with a disk in;
//   * STEP acts on the rising (trailing) edge when selected, DIR high = out (towards track 0); the model
//     checks pulse width, step-to-step interval, DIR set-up/hold around the pulse, that the motor was on
//     for the spin-up time before the first pulse, and that WRITE GATE / WRITE DATA never fall;
//   * rotation: one revolution per pass over a synthetic IBM System 34 track (gap 4a, IAM, 18 or 9
//     sectors of 512 bytes with IDAM / DAM / CRCs, gap 3, gap 4b) built for the current head position,
//     MFM-encoded with real 0x4489 / 0x5224 marks, played as 300 ns low pulses on RDATA at the HD
//     (1 us half cell) or DD (2 us) rate with +3 % / -3 % spindle speed error and +-12 % half-cell
//     jitter on every transition; INDEX low for 2 ms at the start of each revolution. Sector 5 has a
//     corrupt ID CRC, sector 7 a corrupt data CRC.
// The DUT's timers are shortened through generics; the model's timing checks are scaled the same way.
// The status words are read through the DUT's clock crossing into an unrelated 41.7 MHz clock.
//   powershell -File run_floppy_phy_spike_tb.ps1
`timescale 1ns/1ps

module floppy_phy_spike_tb;

   // ------------------------------------------------------------------------------------------
   // scaled-down DUT timings (cycles of 20 ns)
   // ------------------------------------------------------------------------------------------
   localparam int SPINUP_CYC   = 50_000;      // 1 ms motor spin-up
   localparam int STEP_PULSE   = 600;         // 12 us (the real value)
   localparam int STEP_RATE    = 15_000;      // 300 us step to step
   localparam int SETTLE_CYC   = 25_000;      // 0.5 ms head settle
   localparam int IDX_PULSES   = 2;           // revolutions per read phase
   localparam int IDX_TIMEOUT  = 12_500_000;  // 250 ms without index ends a phase (> 1 revolution)
   localparam int REPEAT_CYC   = 2_500_000;   // 50 ms between runs
   localparam int MAX_HOME     = 85;
   localparam int TEST_TRACK   = 40;

   // sequencer state codes (t_seq'pos in the DUT)
   localparam int S_IDLE = 0, S_MOTOR = 1, S_HOME_IN = 2, S_HOME_OUT = 3, S_HOME_SETTLE = 4,
                  S_READ_HD = 5, S_READ_DD = 6, S_SEEK_IN = 7, S_SEEK_SETTLE = 8, S_READ_T = 9,
                  S_SEEK_OUT = 10, S_OUT_SETTLE = 11, S_STOP = 12;

   // ------------------------------------------------------------------------------------------
   // clocks and reset
   // ------------------------------------------------------------------------------------------
   logic clk      = 0;   // 50 MHz
   logic stat_clk = 0;   // 41.7 MHz, unrelated
   logic rst      = 1;
   always #10 clk = ~clk;
   always #12 stat_clk = ~stat_clk;

   // ------------------------------------------------------------------------------------------
   // DUT
   // ------------------------------------------------------------------------------------------
   wire        f_density, f_motora, f_selecta, f_side1, f_stepdir, f_step, f_wdata, f_wgate;
   logic       f_index = 1, f_track0 = 1, f_wp = 1, f_rdata = 1, f_dskchg = 1;
   wire [15:0] stat_a, stat_b, stat_c;
   wire [15:0] dbg_index, dbg_syncs, dbg_idam, dbg_idam_ok, dbg_dam, dbg_dam_ok, dbg_steps;
   wire [31:0] dbg_chrn;
   wire [7:0]  dbg_max_r, dbg_flags, dbg_state, dbg_track, dbg_runs;
   wire [11:0] dbg_last_gap;
   wire [7:0]  dbg_byte;
   wire        dbg_byte_valid, dbg_sync_mark;

   floppy_phy_spike #(
      .G_SPINUP_CYCLES        (SPINUP_CYC),
      .G_STEP_PULSE_CYCLES    (STEP_PULSE),
      .G_STEP_RATE_CYCLES     (STEP_RATE),
      .G_SETTLE_CYCLES        (SETTLE_CYC),
      .G_INDEX_PULSES         (IDX_PULSES),
      .G_INDEX_TIMEOUT_CYCLES (IDX_TIMEOUT),
      .G_REPEAT_CYCLES        (REPEAT_CYC),
      .G_MAX_STEPS_HOME       (MAX_HOME),
      .G_TEST_TRACK           (TEST_TRACK)
   ) dut (
      .clk_i            (clk),
      .rst_i            (rst),
      .f_density_o      (f_density),
      .f_motora_o       (f_motora),
      .f_selecta_o      (f_selecta),
      .f_side1_o        (f_side1),
      .f_stepdir_o      (f_stepdir),
      .f_step_o         (f_step),
      .f_wdata_o        (f_wdata),
      .f_wgate_o        (f_wgate),
      .f_index_i        (f_index),
      .f_track0_i       (f_track0),
      .f_writeprotect_i (f_wp),
      .f_rdata_i        (f_rdata),
      .f_diskchanged_i  (f_dskchg),
      .stat_clk_i       (stat_clk),
      .stat_a_o         (stat_a),
      .stat_b_o         (stat_b),
      .stat_c_o         (stat_c),
      .dbg_index_o      (dbg_index),
      .dbg_syncs_o      (dbg_syncs),
      .dbg_idam_o       (dbg_idam),
      .dbg_idam_ok_o    (dbg_idam_ok),
      .dbg_dam_o        (dbg_dam),
      .dbg_dam_ok_o     (dbg_dam_ok),
      .dbg_chrn_o       (dbg_chrn),
      .dbg_max_r_o      (dbg_max_r),
      .dbg_flags_o      (dbg_flags),
      .dbg_state_o      (dbg_state),
      .dbg_track_o      (dbg_track),
      .dbg_runs_o       (dbg_runs),
      .dbg_steps_o      (dbg_steps),
      .dbg_last_gap_o   (dbg_last_gap),
      .dbg_byte_o       (dbg_byte),
      .dbg_byte_valid_o (dbg_byte_valid),
      .dbg_sync_mark_o  (dbg_sync_mark)
   );

   // ------------------------------------------------------------------------------------------
   // bookkeeping
   // ------------------------------------------------------------------------------------------
   int n_pass = 0, n_fail = 0;
   task automatic check(input bit cond, input string msg);
      if (cond) n_pass++;
      else begin n_fail++; $display("FLP FAIL @%0t: %s", $time, msg); end
   endtask

   // CRC-16/CCITT, poly 0x1021, preset FFFF (independent of the DUT's function)
   function automatic logic [15:0] crc16(input byte d[], input int n);
      logic [15:0] c = 16'hFFFF;
      for (int i = 0; i < n; i++) begin
         c ^= {d[i], 8'h00};
         for (int b = 0; b < 8; b++) c = c[15] ? ((c << 1) ^ 16'h1021) : (c << 1);
      end
      return c;
   endfunction

   // ------------------------------------------------------------------------------------------
   // drive model: media, head, latched disk change, gated outputs
   // ------------------------------------------------------------------------------------------
   bit  disk_present = 0;
   bit  disk_hd      = 0;
   bit  disk_wp      = 0;
   int  pos          = 5;          // head position at power-up
   bit  dskchg       = 1;          // latched until a step with a disk in
   bit  sel;
   assign sel = (f_selecta === 1'b0);

   always_comb begin
      f_track0 = (sel && pos == 0)              ? 1'b0 : 1'b1;
      f_wp     = (sel && disk_present && disk_wp) ? 1'b0 : 1'b1;
      f_dskchg = (sel && dskchg)                ? 1'b0 : 1'b1;
   end

   task automatic eject();
      disk_present = 0; dskchg = 1;
   endtask
   task automatic insert(input bit hd, input bit wp);
      disk_present = 1; disk_hd = hd; disk_wp = wp; dskchg = 1;
   endtask

   // step timing checks and the step itself
   real t_step_fall = -1.0e9, t_step_rise = -1.0e9, t_dir_change = -1.0e9, t_motor_on = -1.0e9;
   int  model_steps = 0;
   always @(negedge f_motora) t_motor_on = $realtime;
   always @(f_stepdir) begin
      if (!rst && t_step_rise > 0)
         check($realtime - t_step_rise >= 1000.0, $sformatf("DIR changed %0.0f ns after a step (hold >= 1 us)", $realtime - t_step_rise));
      t_dir_change = $realtime;
   end
   always @(negedge f_step) if (!rst) begin
      t_step_fall = $realtime;
      check($realtime - t_dir_change >= 1000.0, $sformatf("DIR set-up %0.0f ns before STEP (>= 1 us)", $realtime - t_dir_change));
      check(sel, "STEP while DRIVE SELECT is low");
      check(f_motora === 1'b0, "STEP with the motor on");
      check($realtime - t_motor_on >= SPINUP_CYC * 20.0, $sformatf("first STEP %0.1f ms after motor on (spin-up %0.1f ms)", ($realtime - t_motor_on) / 1.0e6, SPINUP_CYC * 20.0 / 1.0e6));
      if (t_step_rise > 0)
         check($realtime - t_step_rise >= STEP_RATE * 20.0 - STEP_PULSE * 20.0 - 1.0,
               $sformatf("step interval %0.1f us (>= %0.1f)", ($realtime - t_step_fall) / 1000.0, STEP_RATE * 20.0 / 1000.0));
   end
   always @(posedge f_step) if (!rst) begin
      check($realtime - t_step_fall >= 1000.0 && $realtime - t_step_fall <= 20000.0,
            $sformatf("STEP pulse width %0.1f us (1..20)", ($realtime - t_step_fall) / 1000.0));
      t_step_rise = $realtime;
      if (sel) begin
         model_steps++;
         if (f_stepdir) begin if (pos > 0) pos--; end
         else           begin if (pos < 82) pos++; end
         if (disk_present) dskchg = 0;
      end
   end

   // never write, never side 1
   always @(negedge f_wgate) if (!rst) check(0, "WRITE GATE asserted");
   always @(negedge f_wdata) if (!rst) check(0, "WRITE DATA asserted");
   always @(negedge f_side1) if (!rst) check(0, "SIDE1 asserted");

   // ------------------------------------------------------------------------------------------
   // track image: IBM System 34, 512-byte sectors, N = 2
   // ------------------------------------------------------------------------------------------
   byte trk[];          // bytes
   bit  mrk[];          // 1 = A1/C2 mark with the missing clock
   int  trk_len;

   task automatic put(input byte b, input bit m, ref int i);
      trk[i] = b; mrk[i] = m; i++;
   endtask

   task automatic build_track(input bit hd, input int cyl);
      int  i = 0, nsec, gap3;
      byte hdr[8], dat[516];
      logic [15:0] c;
      nsec    = hd ? 18 : 9;
      gap3    = hd ? 108 : 80;
      trk_len = hd ? 12500 : 6250;
      trk = new[trk_len]; mrk = new[trk_len];
      for (int k = 0; k < 80; k++) put(8'h4E, 0, i);                  // gap 4a
      for (int k = 0; k < 12; k++) put(8'h00, 0, i);
      for (int k = 0; k < 3;  k++) put(8'hC2, 1, i);                  // IAM
      put(8'hFC, 0, i);
      for (int k = 0; k < 50; k++) put(8'h4E, 0, i);                  // gap 1
      for (int s = 1; s <= nsec; s++) begin
         for (int k = 0; k < 12; k++) put(8'h00, 0, i);
         for (int k = 0; k < 3;  k++) put(8'hA1, 1, i);
         hdr[0] = 8'hA1; hdr[1] = 8'hA1; hdr[2] = 8'hA1; hdr[3] = 8'hFE;
         hdr[4] = cyl; hdr[5] = 0; hdr[6] = s; hdr[7] = 2;
         c = crc16(hdr, 8);
         if (s == 5) c ^= 16'h0001;                                     // corrupt ID CRC
         put(8'hFE, 0, i); put(hdr[4], 0, i); put(hdr[5], 0, i); put(hdr[6], 0, i); put(hdr[7], 0, i);
         put(c[15:8], 0, i); put(c[7:0], 0, i);
         for (int k = 0; k < 22; k++) put(8'h4E, 0, i);               // gap 2
         for (int k = 0; k < 12; k++) put(8'h00, 0, i);
         for (int k = 0; k < 3;  k++) put(8'hA1, 1, i);
         dat[0] = 8'hA1; dat[1] = 8'hA1; dat[2] = 8'hA1; dat[3] = 8'hFB;
         for (int k = 0; k < 512; k++) dat[4 + k] = (s * 7 + k + cyl) & 8'hFF;
         c = crc16(dat, 516);
         if (s == 7) c ^= 16'h0100;                                     // corrupt data CRC
         put(8'hFB, 0, i);
         for (int k = 0; k < 512; k++) put(dat[4 + k], 0, i);
         put(c[15:8], 0, i); put(c[7:0], 0, i);
         for (int k = 0; k < gap3; k++) put(8'h4E, 0, i);             // gap 3
      end
      while (i < trk_len) put(8'h4E, 0, i);                           // gap 4b
   endtask

   // ------------------------------------------------------------------------------------------
   // rotation: MFM-encode and play the track, index at the start of each revolution
   // ------------------------------------------------------------------------------------------
   int  revs = 0;
   real hc_eff, jit;

   task automatic play_track();
      bit  prev_d = 0;
      bit  stop = 0;
      real t_ideal = $realtime;
      real t_pulse;
      logic [15:0] raw;
      for (int i = 0; i < trk_len && !stop; i++) begin
         if (mrk[i]) begin
            raw    = (trk[i] == 8'hA1) ? 16'h4489 : 16'h5224;
            prev_d = trk[i][0];
         end else begin
            for (int b = 7; b >= 0; b--) begin
               raw[2 * b + 1] = ~prev_d & ~trk[i][b];
               raw[2 * b]     = trk[i][b];
               prev_d = trk[i][b];
            end
         end
         for (int b = 15; b >= 0 && !stop; b--) begin
            t_ideal += hc_eff;
            if (raw[b]) begin
               t_pulse = t_ideal + jit * (real'($urandom_range(0, 2000)) / 1000.0 - 1.0);
               if (t_pulse > $realtime) #(t_pulse - $realtime);
               f_rdata = 0;
               f_rdata <= #300 1'b1;
            end else begin
               if (t_ideal > $realtime) #(t_ideal - $realtime);
            end
            if (f_motora !== 1'b0 || !disk_present) stop = 1;           // motor off / ejected
         end
      end
   endtask

   initial begin
      forever begin
         wait (f_motora === 1'b0 && disk_present);
         build_track(disk_hd, pos);
         hc_eff = disk_hd ? 1000.0 * 1.03 : 2000.0 * 0.97;              // +3 % / -3 % speed
         jit    = disk_hd ? 120.0 : 240.0;                              // +-12 % of a half cell
         revs++;
         f_index = 0;
         fork
            begin #2ms; f_index = 1; end
         join_none
         play_track();
      end
   end

   // ------------------------------------------------------------------------------------------
   // helpers
   // ------------------------------------------------------------------------------------------
   task automatic wait_state(input int s, input string name);
      fork
         begin wait (dbg_state == s); end
         begin #2s; check(0, $sformatf("timeout waiting for %s", name)); end
      join_any
      disable fork;
      #100;
   endtask

   int snap_idam, snap_idam_ok, snap_dam, snap_dam_ok, snap_sync, snap_index;
   task automatic snapshot();
      snap_idam = dbg_idam; snap_idam_ok = dbg_idam_ok; snap_dam = dbg_dam; snap_dam_ok = dbg_dam_ok;
      snap_sync = dbg_syncs; snap_index = dbg_index;
   endtask

   // flags: rate_hd, track0_seen, wp, dskchg, seek_ok, motor_on, dd_found, hd_found
   function automatic string flagstr(input logic [7:0] f);
      return $sformatf("rate_hd=%0d trk0=%0d wp=%0d chg=%0d seek=%0d mot=%0d dd=%0d hd=%0d", f[7], f[6], f[5], f[4], f[3], f[2], f[1], f[0]);
   endfunction

   task automatic check_stat_words(input string when);
      #1000;                                                           // a few crossings
      check(stat_a == {dbg_idam_ok[7:0], dbg_index[7:0]}, $sformatf("%s: stat_a %04x = {idam_ok, index} %02x%02x", when, stat_a, dbg_idam_ok[7:0], dbg_index[7:0]));
      check(stat_b == {dbg_chrn[31:24], dbg_chrn[15:8]}, $sformatf("%s: stat_b %04x = {C, R} %02x%02x", when, stat_b, dbg_chrn[31:24], dbg_chrn[15:8]));
      check(stat_c == {dbg_flags, dbg_max_r}, $sformatf("%s: stat_c %04x = {flags, max_r} %02x%02x", when, stat_c, dbg_flags, dbg_max_r));
   endtask

   // ------------------------------------------------------------------------------------------
   // the test
   // ------------------------------------------------------------------------------------------
   int d_idam, d_ok, d_dam, d_dam_ok, d_sync, d_idx;
   byte b8[8];

   initial begin
      // known answers for the bench's own CRC: A1 A1 A1 FE 00 00 01 02 -> CRC, then zero after appending it
      begin
         logic [15:0] c;
         b8 = '{8'hA1, 8'hA1, 8'hA1, 8'hFE, 8'h00, 8'h00, 8'h01, 8'h02};
         c = crc16(b8, 8);
         check(c == 16'hCA6F, $sformatf("bench crc16 of A1 A1 A1 FE 00 00 01 02 = %04x (CA6F)", c));
      end

      insert(1, 0);                                                    // HD disk, not protected
      pos = 5; dskchg = 1;
      #200; rst = 0;

      check(f_wgate === 1'b1 && f_wdata === 1'b1, "WGATE/WDATA idle after reset");
      check(f_selecta === 1'b0, "drive A selected after reset");

      // --- run 1: HD disk ---
      wait_state(S_MOTOR, "S_MOTOR");
      #100;
      check(f_motora === 1'b0, "motor on in S_MOTOR");
      check(f_dskchg === 1'b0, "DSKCHG asserted before the first step");

      wait_state(S_READ_HD, "S_READ_HD (run 1)");
      check(pos == 0, $sformatf("recalibrated to track 0 (model at %0d)", pos));
      check(model_steps == 5, $sformatf("recalibrate from track 5 = 5 steps out (model saw %0d)", model_steps));
      check(dbg_steps == model_steps, $sformatf("DUT step counter %0d = model %0d", dbg_steps, model_steps));
      check(f_dskchg === 1'b1, "DSKCHG cleared by the recalibrate step");
      check(f_track0 === 1'b0, "TRACK0 asserted at track 0");
      check(dbg_flags[3] == 1'b1, {"seek_ok after recalibrate: ", flagstr(dbg_flags)});
      check(dbg_flags[6] == 1'b1, "track0_seen");
      check(dbg_flags[4] == 1'b0, "disk_changed flag clear after the step");
      check(dbg_flags[5] == 1'b0, "write_protect flag clear (unprotected disk)");
      check(f_density === 1'b1, "DENSITY = G_DENSITY_HD while reading at 500 kbit/s");
      snapshot();

      wait_state(S_READ_DD, "S_READ_DD (run 1)");
      d_idam = dbg_idam - snap_idam; d_ok = dbg_idam_ok - snap_idam_ok; d_dam = dbg_dam - snap_dam;
      d_dam_ok = dbg_dam_ok - snap_dam_ok; d_sync = dbg_syncs - snap_sync; d_idx = dbg_index - snap_index;
      $display("FLP run 1 HD phase: index +%0d sync +%0d idam +%0d ok +%0d dam +%0d ok +%0d", d_idx, d_sync, d_idam, d_ok, d_dam, d_dam_ok);
      check(d_idx == IDX_PULSES + 1, $sformatf("HD phase: %0d index pulses (arm + %0d)", d_idx, IDX_PULSES));
      check(d_ok >= 17 * IDX_PULSES && d_ok <= 17 * (IDX_PULSES + 1), $sformatf("HD phase: %0d good IDAMs (17 per revolution)", d_ok));
      check(d_idam >= 18 * IDX_PULSES && d_idam <= 18 * (IDX_PULSES + 1), $sformatf("HD phase: %0d IDAMs (18 per revolution)", d_idam));
      check(d_idam - d_ok >= IDX_PULSES, $sformatf("HD phase: %0d IDAMs rejected (the corrupt ID CRC of sector 5)", d_idam - d_ok));
      check(d_dam_ok >= 17 * IDX_PULSES && d_dam_ok <= 17 * (IDX_PULSES + 1), $sformatf("HD phase: %0d good DAMs (17 per revolution)", d_dam_ok));
      check(d_dam - d_dam_ok >= IDX_PULSES, $sformatf("HD phase: %0d DAMs rejected (the corrupt data CRC of sector 7)", d_dam - d_dam_ok));
      check(d_sync >= 108 * IDX_PULSES, $sformatf("HD phase: %0d marks (108 per revolution)", d_sync));
      check(dbg_flags[0] == 1'b1, {"hd_found after the HD phase: ", flagstr(dbg_flags)});
      check(dbg_flags[7] == 1'b1, "rate_hd of the last good IDAM");
      check(dbg_max_r == 18, $sformatf("max R = %0d (18: 1.44 MB)", dbg_max_r));
      check(dbg_chrn[31:24] == 0 && dbg_chrn[23:16] == 0 && dbg_chrn[7:0] == 2, $sformatf("last C/H/N = %0d/%0d/%0d (0/0/2)", dbg_chrn[31:24], dbg_chrn[23:16], dbg_chrn[7:0]));
      check(f_density === 1'b0, "DENSITY = G_DENSITY_DD while reading at 250 kbit/s");
      snapshot();

      wait_state(S_SEEK_IN, "S_SEEK_IN (run 1)");
      d_ok = dbg_idam_ok - snap_idam_ok; d_idx = dbg_index - snap_index;
      $display("FLP run 1 DD phase on the HD disk: index +%0d sync +%0d idam +%0d ok +%0d", d_idx, dbg_syncs - snap_sync, dbg_idam - snap_idam, d_ok);
      check(d_idx == IDX_PULSES + 1, $sformatf("DD phase: %0d index pulses", d_idx));
      check(d_ok == 0, $sformatf("DD phase on an HD disk: %0d good IDAMs (0)", d_ok));
      check(dbg_flags[1] == 1'b0, {"dd_found clear: ", flagstr(dbg_flags)});
      check(dbg_max_r == 18, "max R still 18");

      wait_state(S_READ_T, "S_READ_T (run 1)");
      check(pos == TEST_TRACK, $sformatf("seek in: model at track %0d (%0d)", pos, TEST_TRACK));
      check(dbg_track == TEST_TRACK, $sformatf("DUT head_track %0d", dbg_track));
      check(f_density === 1'b1, "track-40 read at the HD rate (DENSITY = HD)");
      snapshot();

      wait_state(S_SEEK_OUT, "S_SEEK_OUT (run 1)");
      d_ok = dbg_idam_ok - snap_idam_ok;
      $display("FLP run 1 track %0d: idam ok +%0d, last CHRN %08x", TEST_TRACK, d_ok, dbg_chrn);
      check(d_ok >= 17 * IDX_PULSES, $sformatf("track-40 phase: %0d good IDAMs", d_ok));
      check(dbg_chrn[31:24] == TEST_TRACK, $sformatf("last C = %0d (%0d)", dbg_chrn[31:24], TEST_TRACK));
      check(dbg_flags[7] == 1'b1, "rate_hd still HD");

      wait_state(S_IDLE, "S_IDLE (run 1)");
      check(pos == 0, $sformatf("seek out: model at track %0d (0)", pos));
      check(f_track0 === 1'b0, "TRACK0 asserted after the return");
      check(f_motora === 1'b1, "motor off in idle");
      check(f_selecta === 1'b0, "drive stays selected in idle");
      check(dbg_flags[3] == 1'b1, "seek_ok after the whole run");
      check(dbg_runs == 1, $sformatf("runs = %0d (1)", dbg_runs));
      check(dbg_steps == 5 + 2 * TEST_TRACK, $sformatf("total steps %0d (%0d)", dbg_steps, 5 + 2 * TEST_TRACK));
      check_stat_words("after run 1");
      check(stat_c[15:8] == dbg_flags && stat_c[7:0] == 18, $sformatf("stat_c = %04x", stat_c));

      // --- disk swap while idle: eject (DSKCHG asserts, run starts at once), insert a DD disk ---
      #5ms;
      eject();
      #2000;
      check(dbg_state != S_IDLE, "eject (DSKCHG edge) starts a run at once");
      check(dbg_flags[4] == 1'b1, {"disk_changed flag set: ", flagstr(dbg_flags)});
      #200us;
      insert(0, 1);                                                    // DD disk, write protected

      wait_state(S_READ_HD, "S_READ_HD (run 2)");
      check(pos == 0, "recalibrated (already at 0: one step in, one out)");
      check(f_dskchg === 1'b1, "DSKCHG cleared by the step with the new disk in");
      check(dbg_flags[4] == 1'b0, "disk_changed flag clear again");
      check(dbg_flags[5] == 1'b1, {"write_protect flag set: ", flagstr(dbg_flags)});
      check(dbg_max_r == 0, "max R cleared at the start of a run");
      snapshot();

      wait_state(S_READ_DD, "S_READ_DD (run 2)");
      d_ok = dbg_idam_ok - snap_idam_ok;
      $display("FLP run 2 HD phase on the DD disk: idam +%0d ok +%0d", dbg_idam - snap_idam, d_ok);
      check(d_ok == 0, $sformatf("HD phase on a DD disk: %0d good IDAMs (0)", d_ok));
      check(dbg_flags[0] == 1'b0, "hd_found clear");
      snapshot();

      wait_state(S_SEEK_IN, "S_SEEK_IN (run 2)");
      d_idam = dbg_idam - snap_idam; d_ok = dbg_idam_ok - snap_idam_ok; d_dam = dbg_dam - snap_dam;
      d_dam_ok = dbg_dam_ok - snap_dam_ok; d_sync = dbg_syncs - snap_sync; d_idx = dbg_index - snap_index;
      $display("FLP run 2 DD phase: index +%0d sync +%0d idam +%0d ok +%0d dam +%0d ok +%0d", d_idx, d_sync, d_idam, d_ok, d_dam, d_dam_ok);
      check(d_ok >= 8 * IDX_PULSES && d_ok <= 8 * (IDX_PULSES + 1), $sformatf("DD phase: %0d good IDAMs (8 per revolution)", d_ok));
      check(d_idam - d_ok >= IDX_PULSES, $sformatf("DD phase: %0d IDAMs rejected", d_idam - d_ok));
      check(d_dam_ok >= 8 * IDX_PULSES, $sformatf("DD phase: %0d good DAMs (8 per revolution)", d_dam_ok));
      check(d_dam - d_dam_ok >= IDX_PULSES, $sformatf("DD phase: %0d DAMs rejected", d_dam - d_dam_ok));
      check(dbg_flags[1] == 1'b1, {"dd_found: ", flagstr(dbg_flags)});
      check(dbg_flags[7] == 1'b0, "rate_hd = DD for the last good IDAM");
      check(dbg_max_r == 9, $sformatf("max R = %0d (9: 720 KB)", dbg_max_r));

      wait_state(S_READ_T, "S_READ_T (run 2)");
      check(pos == TEST_TRACK, $sformatf("run 2 seek in: model at %0d", pos));
      check(f_density === 1'b0, "track-40 read at the DD rate (DENSITY = DD)");
      snapshot();

      wait_state(S_SEEK_OUT, "S_SEEK_OUT (run 2)");
      d_ok = dbg_idam_ok - snap_idam_ok;
      check(d_ok >= 8 * IDX_PULSES, $sformatf("run 2 track-40 phase: %0d good IDAMs", d_ok));
      check(dbg_chrn[31:24] == TEST_TRACK, $sformatf("run 2 last C = %0d", dbg_chrn[31:24]));

      wait_state(S_IDLE, "S_IDLE (run 2)");
      check(pos == 0, "run 2: back at track 0");
      check(dbg_runs == 2, $sformatf("runs = %0d (2)", dbg_runs));
      check_stat_words("after run 2");
      check(stat_b == {8'd40, stat_b[7:0]} && stat_b[7:0] >= 1 && stat_b[7:0] <= 9, $sformatf("stat_b = %04x (C = 40, R in 1..9)", stat_b));

      // --- the periodic restart ---
      begin
         real t0;
         t0 = $realtime;
         wait_state(S_MOTOR, "S_MOTOR (periodic restart)");
         check($realtime - t0 <= REPEAT_CYC * 20.0 + 1000.0, $sformatf("restart after %0.1f ms (repeat %0.1f ms)", ($realtime - t0) / 1.0e6, REPEAT_CYC * 20.0 / 1.0e6));
      end

      // --- no disk: the phases time out and the sequencer keeps going ---
      eject();
      wait_state(S_IDLE, "S_IDLE (run 3, no disk)");
      wait_state(S_MOTOR, "S_MOTOR after the ejected run");
      wait_state(S_READ_HD, "S_READ_HD (run 4, no disk)");
      begin
         real t0;
         t0 = $realtime;
         wait_state(S_READ_DD, "S_READ_DD (run 4, no disk)");
         check($realtime - t0 >= IDX_TIMEOUT * 20.0 - 100.0 && $realtime - t0 <= IDX_TIMEOUT * 20.0 + 1000.0,
               $sformatf("HD phase without index timed out after %0.1f ms (%0.1f)", ($realtime - t0) / 1.0e6, IDX_TIMEOUT * 20.0 / 1.0e6));
      end

      $display("FLP counters: index %0d marks %0d idam %0d ok %0d dam %0d ok %0d steps %0d runs %0d revolutions %0d",
               dbg_index, dbg_syncs, dbg_idam, dbg_idam_ok, dbg_dam, dbg_dam_ok, dbg_steps, dbg_runs, revs);
      if (n_fail == 0) $display("FLP RESULT: PASS (%0d checks)", n_pass);
      else             $display("FLP RESULT: FAIL (%0d failed, %0d passed)", n_fail, n_pass);
      $finish;
   end

   initial begin
      #8s;
      $display("FLP RESULT: FAIL (timeout; %0d failed, %0d passed so far)", n_fail, n_pass);
      $finish;
   end

endmodule
