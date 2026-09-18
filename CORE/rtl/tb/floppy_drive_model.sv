// floppy_drive_model: a 3.5" PC floppy drive on the Shugart pins, for the benches of
// CORE/vhdl/floppy_phy_spike.vhd and CORE/vhdl/floppy_sector_engine.vhd (docs/floppy.md).
//
//   * outputs (TRACK0, WPT, DSKCHG, INDEX, RDATA) are only driven while DRIVE SELECT is low, as a real
//     drive's open-collector outputs are; DISK CHANGE latches on eject/insert and clears on a STEP pulse
//     with a disk in;
//   * STEP acts on the rising (trailing) edge when selected, DIR high = out (towards track 0); the model
//     checks pulse width, step-to-step interval, DIR set-up/hold around the pulse, that the motor was on
//     for the spin-up time before the first pulse (only when MOTOR_BEFORE_STEP is set: a seek without the
//     motor is legal, the spike just never does one);
//   * rotation: one revolution per pass over a synthetic IBM System 34 track (gap 4a, IAM, 18 or 9
//     sectors of 512 bytes with IDAM / DAM / CRCs, gap 3, gap 4b) built for the current head position and
//     the SIDE1 level, MFM-encoded with real 0x4489 / 0x5224 marks, played as 300 ns low pulses on RDATA
//     at the HD (1 us half cell) or DD (2 us) rate with +3 % / -3 % spindle speed error and +-12 %
//     half-cell jitter on every transition; INDEX low for 2 ms at the start of each revolution.
//     Sector BAD_ID_SECTOR has a corrupt ID CRC, sector BAD_DATA_SECTOR a corrupt data CRC (0 = none);
//     both can be changed at run time (bad_id / bad_data). Data byte k of sector s on cylinder c, head h
//     is data_byte(s, k, c, h).
//   * writing (phase 3): while WRITE GATE is low the drive records every falling edge of WRITE DATA as a
//     flux transition at its exact angular position (in units of the disk's own raw bit, fractional, so
//     the writer's clock ratio to the spindle is kept), erases the original bits it passes over and mutes
//     RDATA; the recording is kept per cylinder and side and replayed with jitter on later revolutions in
//     place of the erased bits, so a read afterwards decodes exactly what was written. Checks: WRITE GATE
//     only with the drive selected, the motor on, a disk in and not write protected; WRITE DATA only under
//     WRITE GATE, pulses 0.1..2.5 us wide, transitions at least 1.5 half cells apart; WRITE GATE must go
//     on inside gap 2 or the data sync field of a sector and off inside that sector's gap 3 (or the tail of its old data
//     field, when the disk turns slower than the writer assumes), at least
//     MIN_MARGIN bytes before the next ID sync field (last_wr_lead / last_wr_margin report the bytes from
//     the ID CRC to the splice and from WRITE GATE off to the next sync); no write across the index.
//     corrupt_next = 1 drops the CORRUPT_AT-th recorded transition of the next write (verify error).
//   * formatting (phase 4): with fmt_expect set by the bench the next write may start in gap 4a right
//     after the index and must end within a few bytes after the next index; it replaces the whole
//     recording of the track (a full-track write). The bench tells the model the layout it expects
//     (fmt_nsec, fmt_gap3) and the model builds the region map of a formatted track from it, scaled by the
//     writer's bit rate against the disk's spindle speed, so that later sector writes are checked against
//     the new gap 2 / gap 3 positions. speed_hd / speed_dd set the spindle speed factor per rate (< 1 =
//     fast), nsec_ovr / gap3_ovr override the synthetic track's layout (a MEGA65/1581-style 10-sector
//     track), disk_blank plays no flux at all (an unformatted disk); last_wr_full / last_wr_end report
//     the last write.
// The bench drives eject() / insert() and reads pos / dskchg / model_steps / revs hierarchically; the
// model's own checks count into n_pass / n_fail, which the bench adds to its totals.
`timescale 1ns/1ps

module floppy_drive_model #(
   parameter int SPINUP_CYC        = 50_000,   // cycles of 20 ns the motor must have run before a step
   parameter int STEP_RATE         = 15_000,   // minimum step interval in cycles
   parameter int STEP_PULSE        = 600,      // the DUT's STEP low time in cycles (for the interval check)
   parameter bit MOTOR_BEFORE_STEP = 1,        // check that the motor was on for SPINUP_CYC before a step
   parameter int BAD_ID_SECTOR     = 5,
   parameter int BAD_DATA_SECTOR   = 7,
   parameter int MIN_MARGIN        = 30,       // bytes WRITE GATE must go off before the next ID sync field
   parameter int CORRUPT_AT        = 300       // the transition dropped by corrupt_next
) (
   input  logic rst,
   input  wire  f_density, f_motora, f_selecta, f_side1, f_stepdir, f_step, f_wdata, f_wgate,
   output logic f_index, f_track0, f_wp, f_rdata, f_dskchg
);

   int n_pass = 0, n_fail = 0;
   task automatic check(input bit cond, input string msg);
      if (cond) n_pass++;
      else begin n_fail++; $display("FLP FAIL @%0t: (drive model) %s", $time, msg); end
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

   function automatic byte data_byte(input int s, input int k, input int cyl, input int head);
      return (s * 7 + k + cyl * 3 + head * 101) & 8'hFF;
   endfunction

   // ------------------------------------------------------------------------------------------
   // media, head, latched disk change, gated outputs
   // ------------------------------------------------------------------------------------------
   bit  disk_present = 0;
   bit  disk_hd      = 0;
   bit  disk_wp      = 0;
   bit  disk_blank   = 0;          // no flux transitions at all (unformatted)
   int  nsec_ovr     = 0;          // sectors per track of the synthetic track (0 = 18 / 9 by rate)
   int  gap3_ovr     = 0;          // its gap 3 (0 = 108 / 80 by rate)
   real speed_hd     = 1.03;       // spindle speed factor of the half cell: > 1 = slow, < 1 = fast
   real speed_dd     = 0.97;
   int  pos          = 5;          // head position at power-up
   bit  dskchg       = 1;          // latched until a step with a disk in
   int  bad_id       = BAD_ID_SECTOR;
   int  bad_data     = BAD_DATA_SECTOR;
   bit  sel;
   int  head;
   bit  wg_on;
   assign sel   = (f_selecta === 1'b0);
   assign head  = (f_side1 === 1'b0) ? 1 : 0;
   assign wg_on = sel && (f_wgate === 1'b0);

   always_comb begin
      f_track0 = (sel && pos == 0)                ? 1'b0 : 1'b1;
      f_wp     = (sel && disk_present && disk_wp) ? 1'b0 : 1'b1;
      f_dskchg = (sel && dskchg)                  ? 1'b0 : 1'b1;
   end

   // the written overlay, per cylinder and side (key = cylinder * 2 + side): recorded transitions and
   // erased raw bits; a new disk starts without any
   localparam int MAX_RAW = 12500 * 16;
   real wq[0:165][$];                  // transition positions in raw bits (fractional), sorted
   bit  er[0:165][0:MAX_RAW-1];        // erased raw bits
   bit  er_dirty[0:165];               // ... which keys have any (a new disk clears only those)
   bit  wq_dirty = 0;
   // a formatted track (full-track write): the layout the DUT wrote, in writer bytes, mapped onto the disk
   bit  fmt_expect = 0;                 // the bench expects the next write to be a full-track write
   int  fmt_nsec = 18, fmt_gap3 = 84;   // the layout the bench expects the DUT to write
   bit  fmt_valid[0:165];
   int  fmt_n[0:165], fmt_g3[0:165];
   real fmt_start[0:165];               // disk raw bit at which the format's WRITE GATE went on
   real fmt_scale[0:165];               // disk raw bits per writer raw bit
   int  last_wr_full = 0, last_wr_end = -1;

   task automatic eject();
      disk_present = 0; dskchg = 1;
   endtask
   task automatic insert(input bit hd, input bit wp);
      disk_present = 1; disk_hd = hd; disk_wp = wp; dskchg = 1; disk_blank = 0;
      for (int k = 0; k < 166; k++) begin
         wq[k].delete();
         fmt_valid[k] = 0;
         if (er_dirty[k]) begin
            for (int p = 0; p < MAX_RAW; p++) er[k][p] = 0;
            er_dirty[k] = 0;
         end
      end
      wq_dirty = 1;
   endtask

   // step timing checks and the step itself
   real t_step_fall = -1.0e9, t_step_rise = -1.0e9, t_dir_change = -1.0e9, t_motor_on = -1.0e9;
   int  model_steps = 0;
   always @(negedge f_motora) t_motor_on = $realtime;
   always @(f_stepdir) begin
      if (!rst && t_step_rise > 0)
         check($realtime - t_step_rise >= 1000.0, $sformatf("DIR changed %0.0f ns after a step (hold >= 1 us)", $realtime - t_step_rise));
      if (!rst && f_step === 1'b0)
         check(0, "DIR changed while STEP is low (the drive samples DIR at the trailing edge)");
      t_dir_change = $realtime;
   end
   always @(negedge f_step) if (!rst) begin
      t_step_fall = $realtime;
      check($realtime - t_dir_change >= 1000.0, $sformatf("DIR set-up %0.0f ns before STEP (>= 1 us)", $realtime - t_dir_change));
      check(sel, "STEP while DRIVE SELECT is low");
      if (MOTOR_BEFORE_STEP) check(f_motora === 1'b0, "STEP with the motor on");
      if (f_motora === 1'b0)
         check($realtime - t_motor_on >= SPINUP_CYC * 20.0, $sformatf("first STEP %0.1f ms after motor on (spin-up %0.1f ms)", ($realtime - t_motor_on) / 1.0e6, SPINUP_CYC * 20.0 / 1.0e6));
      if (t_step_rise > 0)
         check($realtime - t_step_rise >= STEP_RATE * 20.0 - STEP_PULSE * 20.0 - 1.0,
               $sformatf("step interval %0.1f us (>= %0.1f)", ($realtime - t_step_fall) / 1000.0, STEP_RATE * 20.0 / 1000.0));
      check(!wg_on, "STEP while WRITE GATE is asserted");
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

   // ------------------------------------------------------------------------------------------
   // track image: IBM System 34, 512-byte sectors, N = 2, with a region map for the write checks
   // ------------------------------------------------------------------------------------------
   localparam int R_GAP4A = 0, R_SYNC_ID = 1, R_ID = 2, R_GAP2 = 3, R_SYNC_D = 4, R_DATA = 5, R_GAP3 = 6;

   byte trk[];          // bytes
   bit  mrk[];          // 1 = A1/C2 mark with the missing clock
   int  region[];       // R_* per byte
   int  sec_of[];       // sector number per byte (gap 3 belongs to the sector before it)
   int  trk_len;
   int  cur_reg, cur_sec;

   task automatic put(input byte b, input bit m, ref int i);
      trk[i] = b; mrk[i] = m; region[i] = cur_reg; sec_of[i] = cur_sec; i++;
   endtask

   // the region map of a formatted track: the DUT's layout in writer bytes (146 bytes of lead-in, then
   // per sector 12 sync + 10 ID + 22 gap 2 + 12 sync + 518 data + gap 3)
   task automatic build_layout(input int nsec, input int gap3, ref int lreg[], ref int lsec[], output int n);
      int i = 0;
      n = 146 + nsec * (574 + gap3) + 8;
      lreg = new[n]; lsec = new[n];
      for (int k = 0; k < 146; k++) begin lreg[i] = R_GAP4A; lsec[i] = 0; i++; end
      for (int s = 1; s <= nsec; s++) begin
         for (int k = 0; k < 12;  k++) begin lreg[i] = R_SYNC_ID; lsec[i] = s; i++; end
         for (int k = 0; k < 10;  k++) begin lreg[i] = R_ID;      lsec[i] = s; i++; end
         for (int k = 0; k < 22;  k++) begin lreg[i] = R_GAP2;    lsec[i] = s; i++; end
         for (int k = 0; k < 12;  k++) begin lreg[i] = R_SYNC_D;  lsec[i] = s; i++; end
         for (int k = 0; k < 518; k++) begin lreg[i] = R_DATA;    lsec[i] = s; i++; end
         for (int k = 0; k < gap3; k++) begin lreg[i] = R_GAP3;   lsec[i] = s; i++; end
      end
      while (i < n) begin lreg[i] = R_GAP3; lsec[i] = nsec; i++; end
   endtask

   task automatic build_track(input bit hd, input int cyl, input int hd_side);
      int  i = 0, nsec, gap3, key, ln, j;
      byte hdr[8], dat[516];
      logic [15:0] c;
      int  lreg[], lsec[];
      nsec    = (nsec_ovr != 0) ? nsec_ovr : (hd ? 18 : 9);
      gap3    = (gap3_ovr != 0) ? gap3_ovr : (hd ? 108 : 80);
      trk_len = hd ? 12500 : 6250;
      key     = cyl * 2 + hd_side;
      if (fmt_valid[key]) begin
         // every original bit is erased; only the region map matters, in the DUT's layout scaled onto the disk
         trk = new[trk_len]; mrk = new[trk_len]; region = new[trk_len]; sec_of = new[trk_len];
         build_layout(fmt_n[key], fmt_g3[key], lreg, lsec, ln);
         for (i = 0; i < trk_len; i++) begin
            trk[i] = 8'h4E; mrk[i] = 0;
            j = int'($floor((real'(i) - fmt_start[key] / 16.0) / fmt_scale[key]));
            if (j < 0 || j >= ln) begin region[i] = R_GAP4A; sec_of[i] = 0; end
            else begin region[i] = lreg[j]; sec_of[i] = lsec[j]; end
         end
         return;
      end
      trk = new[trk_len]; mrk = new[trk_len]; region = new[trk_len]; sec_of = new[trk_len];
      cur_reg = R_GAP4A; cur_sec = 0;
      for (int k = 0; k < 80; k++) put(8'h4E, 0, i);                  // gap 4a
      for (int k = 0; k < 12; k++) put(8'h00, 0, i);
      for (int k = 0; k < 3;  k++) put(8'hC2, 1, i);                  // IAM
      put(8'hFC, 0, i);
      for (int k = 0; k < 50; k++) put(8'h4E, 0, i);                  // gap 1
      for (int s = 1; s <= nsec; s++) begin
         cur_sec = s;
         cur_reg = R_SYNC_ID;
         for (int k = 0; k < 12; k++) put(8'h00, 0, i);
         cur_reg = R_ID;
         for (int k = 0; k < 3;  k++) put(8'hA1, 1, i);
         hdr[0] = 8'hA1; hdr[1] = 8'hA1; hdr[2] = 8'hA1; hdr[3] = 8'hFE;
         hdr[4] = cyl; hdr[5] = hd_side; hdr[6] = s; hdr[7] = 2;
         c = crc16(hdr, 8);
         if (s == bad_id) c ^= 16'h0001;                               // corrupt ID CRC
         put(8'hFE, 0, i); put(hdr[4], 0, i); put(hdr[5], 0, i); put(hdr[6], 0, i); put(hdr[7], 0, i);
         put(c[15:8], 0, i); put(c[7:0], 0, i);
         cur_reg = R_GAP2;
         for (int k = 0; k < 22; k++) put(8'h4E, 0, i);               // gap 2
         cur_reg = R_SYNC_D;
         for (int k = 0; k < 12; k++) put(8'h00, 0, i);
         cur_reg = R_DATA;
         for (int k = 0; k < 3;  k++) put(8'hA1, 1, i);
         dat[0] = 8'hA1; dat[1] = 8'hA1; dat[2] = 8'hA1; dat[3] = 8'hFB;
         for (int k = 0; k < 512; k++) dat[4 + k] = data_byte(s, k, cyl, hd_side);
         c = crc16(dat, 516);
         if (s == bad_data) c ^= 16'h0100;                             // corrupt data CRC
         put(8'hFB, 0, i);
         for (int k = 0; k < 512; k++) put(dat[4 + k], 0, i);
         put(c[15:8], 0, i); put(c[7:0], 0, i);
         cur_reg = R_GAP3;
         for (int k = 0; k < gap3; k++) put(8'h4E, 0, i);             // gap 3
      end
      while (i < trk_len) put(8'h4E, 0, i);                           // gap 4b (gap 3 of the last sector)
   endtask

   // ------------------------------------------------------------------------------------------
   // the written overlay (declared with the media above): recording state
   // ------------------------------------------------------------------------------------------
   int  revs = 0;                       // revolutions played (also the write-across-index check)
   // recording state
   real cur_t0;                         // ideal start time of the raw bit being played
   int  cur_p = 0;                      // its index
   int  cur_key = 0;
   real cur_hc;                         // the disk's effective half cell
   real cur_wr[$];                      // transitions of the write in progress
   real wr_start_pos, wr_end_pos;
   int  wr_start_rev;
   int  wr_sector;
   int  writes = 0;
   int  last_wr_sector = 0, last_wr_lead = -1, last_wr_margin = -1, last_wr_pulses = 0;
   real last_wr_min_gap = 1.0e9;
   real t_wd_fall = -1.0e9, t_wd_prev = -1.0e9;
   bit  corrupt_next = 0;
   int  wr_bad = 0;                     // WRITE GATE went on somewhere illegal: skip the end checks

   function automatic real pos_now();
      return cur_p + ($realtime - cur_t0) / cur_hc;
   endfunction

   // WRITE GATE on: legal? where?
   always @(negedge f_wgate) if (!rst) begin
      int b0, j;
      check(sel, "WRITE GATE asserted while not selected");
      check(f_motora === 1'b0, "WRITE GATE asserted with the motor off");
      check(disk_present, "WRITE GATE asserted with no disk");
      check(!disk_wp, "WRITE GATE asserted on a write-protected disk");
      cur_wr.delete();
      wr_bad          = 0;
      last_wr_pulses  = 0;
      last_wr_min_gap = 1.0e9;
      t_wd_prev       = -1.0e9;
      wr_start_pos    = pos_now();
      wr_start_rev    = revs;
      b0 = int'($floor(wr_start_pos)) / 16;
      last_wr_full = 0;
      if (!disk_present || !sel || f_motora !== 1'b0 || b0 >= trk_len) begin
         wr_bad = 1;
      end else if (fmt_expect) begin
         // a full-track write: at the index, i.e. within the first bytes of gap 4a
         check(b0 < 4, $sformatf("format: WRITE GATE on at byte %0d after the index (< 4)", b0));
         if (b0 >= 4) wr_bad = 1;
         last_wr_full   = 1;
         last_wr_sector = 0;
         last_wr_lead   = b0;
      end else begin
         check(region[b0] == R_GAP2 || region[b0] == R_SYNC_D,
               $sformatf("WRITE GATE on at byte %0d, region %0d (must be gap 2 or the data sync field)", b0, region[b0]));
         if (region[b0] != R_GAP2 && region[b0] != R_SYNC_D) wr_bad = 1;
         wr_sector = sec_of[b0];
         j = b0;
         while (j > 0 && region[j] != R_ID) j--;
         last_wr_lead   = b0 - j - 1;                                   // gap bytes between the ID CRC and the splice
         last_wr_sector = wr_sector;
      end
   end

   // WRITE GATE off: end position, keep the recording, replace the old one
   always @(posedge f_wgate) if (!rst) begin
      int b1, j, key;
      real q[$];
      wr_end_pos = pos_now();
      writes++;
      if (last_wr_full) begin
         // a full-track write: exactly one index inside it, off within a few bytes after that index; the
         // recording replaces the whole track and the region map follows the layout the bench announced
         b1 = int'($floor(wr_end_pos)) / 16;
         last_wr_end = b1;
         check(revs == wr_start_rev + 1, $sformatf("format: %0d index pulses inside the write (1)", revs - wr_start_rev));
         check(b1 < 8, $sformatf("format: WRITE GATE off at byte %0d after the index (< 8)", b1));
         if (!wr_bad && revs == wr_start_rev + 1) begin
            key = cur_key;
            q.delete();
            for (int k = 0; k < cur_wr.size(); k++) q.push_back(cur_wr[k]);
            q.sort();
            wq[key] = q;
            wq_dirty = 1;
            fmt_valid[key] = 1;
            fmt_n[key]     = fmt_nsec;
            fmt_g3[key]    = fmt_gap3;
            fmt_start[key] = wr_start_pos;
            fmt_scale[key] = (disk_hd ? 1000.0 : 2000.0) / cur_hc;
         end
         fmt_expect = 0;
      end else begin
       check(revs == wr_start_rev, "write across the index");
       if (!wr_bad && revs == wr_start_rev) begin
         b1 = int'($floor(wr_end_pos)) / 16;
         if (b1 >= trk_len) b1 = trk_len - 1;
         // off inside the sector's own gap 3, or still inside the old data field when the disk turns slower
         // than the writer assumes (the old CRC's tail then stays behind the new field, in what is now gap 3)
         check((region[b1] == R_GAP3 || region[b1] == R_DATA) && sec_of[b1] == wr_sector,
               $sformatf("WRITE GATE off at byte %0d, region %0d of sector %0d (must be gap 3 or the old data field of sector %0d)", b1, region[b1], sec_of[b1], wr_sector));
         j = b1;
         while (j < trk_len && region[j] != R_SYNC_ID) j++;
         last_wr_margin = j - b1;
         check(last_wr_margin >= MIN_MARGIN, $sformatf("WRITE GATE off only %0d bytes before the next ID sync field (>= %0d)", last_wr_margin, MIN_MARGIN));
         if (corrupt_next) begin
            if (cur_wr.size() > CORRUPT_AT) cur_wr.delete(CORRUPT_AT);
            corrupt_next = 0;
         end
         key = cur_key;
         q.delete();
         for (int k = 0; k < wq[key].size(); k++) if (wq[key][k] < wr_start_pos || wq[key][k] >= wr_end_pos) q.push_back(wq[key][k]);
         for (int k = 0; k < cur_wr.size(); k++) q.push_back(cur_wr[k]);
         q.sort();
         wq[key] = q;
         wq_dirty = 1;
       end
      end
      cur_wr.delete();
   end

   // WRITE DATA: a transition at the falling edge, only under WRITE GATE
   always @(negedge f_wdata) if (!rst) begin
      t_wd_fall = $realtime;
      if (!wg_on) check(0, "WRITE DATA pulse without WRITE GATE");
      else begin
         cur_wr.push_back(pos_now());
         last_wr_pulses++;
         if (t_wd_prev > 0 && $realtime - t_wd_prev < last_wr_min_gap) last_wr_min_gap = $realtime - t_wd_prev;
         if (t_wd_prev > 0)
            check($realtime - t_wd_prev >= 1.5 * (disk_hd ? 1000.0 : 2000.0),
                  $sformatf("WRITE DATA transitions %0.0f ns apart (>= 1.5 half cells)", $realtime - t_wd_prev));
         t_wd_prev = $realtime;
      end
   end
   always @(posedge f_wdata) if (!rst && t_wd_fall > 0)
      check($realtime - t_wd_fall >= 100.0 && $realtime - t_wd_fall <= 2500.0,
            $sformatf("WRITE DATA pulse width %0.0f ns (0.1..2.5 us)", $realtime - t_wd_fall));

   // ------------------------------------------------------------------------------------------
   // rotation: MFM-encode and play the track with the written overlay, index at the start of each revolution
   // ------------------------------------------------------------------------------------------
   real hc_eff, jit;
   int  play_pos, play_head;

   task automatic pulse();
      if (sel && !wg_on) begin
         f_rdata = 0;
         f_rdata <= #300 1'b1;
      end
   endtask

   task automatic play_track();
      bit  prev_d = 0;
      bit  stop = 0;
      bit  wg0;
      int  p, wi = 0, key;
      real t_ideal = $realtime;
      real t_pulse;
      logic [15:0] raw;
      key = pos * 2 + head;
      cur_key = key;
      wq_dirty = 1;
      for (int i = 0; i < trk_len && !stop; i++) begin
         // the head moved or the side changed: the same angular position, the other track's data
         if (pos != play_pos || head != play_head) begin
            play_pos  = pos;
            play_head = head;
            build_track(disk_hd, pos, head);
            key = pos * 2 + head;
            cur_key = key;
            wq_dirty = 1;
         end
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
            p = i * 16 + (15 - b);
            cur_t0  = t_ideal;
            cur_p   = p;
            cur_hc  = hc_eff;
            t_ideal += hc_eff;
            wg0 = wg_on;
            if (wq_dirty) begin
               wi = 0;
               while (wi < wq[key].size() && wq[key][wi] < p) wi++;
               wq_dirty = 0;
            end
            // recorded transitions inside this raw bit
            while (wi < wq[key].size() && wq[key][wi] < p + 1) begin
               t_pulse = cur_t0 + (wq[key][wi] - p) * hc_eff + jit * (real'($urandom_range(0, 2000)) / 1000.0 - 1.0);
               if (t_pulse > $realtime) #(t_pulse - $realtime);
               pulse();
               wi++;
            end
            // the original bit, unless erased (or the disk is blank)
            if (raw[b] && !er[key][p] && !disk_blank) begin
               t_pulse = t_ideal + jit * (real'($urandom_range(0, 2000)) / 1000.0 - 1.0);
               if (t_pulse > $realtime) #(t_pulse - $realtime);
               pulse();
            end else begin
               if (t_ideal > $realtime) #(t_ideal - $realtime);
            end
            if (wg0 || wg_on) begin er[key][p] = 1; er_dirty[key] = 1; end   // written over
            if (f_motora !== 1'b0 || !disk_present) stop = 1;           // motor off / ejected
         end
      end
   endtask

   initial begin
      f_index = 1;
      f_rdata = 1;
      forever begin
         wait (f_motora === 1'b0 && disk_present);
         play_pos  = pos;
         play_head = head;
         build_track(disk_hd, pos, head);
         hc_eff = disk_hd ? 1000.0 * speed_hd : 2000.0 * speed_dd;      // +3 % / -3 % speed by default
         jit    = disk_hd ? 120.0 : 240.0;                              // +-12 % of a half cell
         revs++;
         if (sel) f_index = 0;
         fork
            begin #2ms; f_index = 1; end
         join_none
         play_track();
      end
   end

endmodule
