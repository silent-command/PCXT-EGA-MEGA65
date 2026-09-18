// floppy_sector_engine_tb: bench for CORE/vhdl/floppy_sector_engine.vhd (the read path from the MEGA65 R6
// internal floppy drive to the DOS-facing FDC, docs/floppy.md phase 2).
//
// The drive is floppy_drive_model.sv (shared with the spike bench): synthetic System 34 tracks for every
// cylinder and both sides, at the HD or DD rate, with speed error and jitter; sector 5 has a corrupt ID
// CRC and sector 7 a corrupt data CRC unless the bench says otherwise. The DUT's timers are shortened
// through generics; the model's timing checks are scaled the same way.
//
// Scenario: a disabled engine refuses commands; DETECT on an HD disk (recalibrate from track 5, HD found,
// max R 18); READ_TRACK cylinder 0 head 0 captures 16 of 18 sectors (5 and 7 rejected) and every valid
// sector is COPYed and compared byte for byte; the rejected sector stays invalid after a plain and a
// forced (recalibrating) re-read; COPY of sector 0 / 19 is refused; the wrong rate finds no header;
// seeks to cylinder 40 head 1, head 0 (side switch without a seek) and cylinder 3, each track verified;
// a cache hit answers without the motor and within a few clocks; the motor stops after the idle time and
// spins up again before the next seek; eject sets the sticky disk-change flag and drops the cache, PROBE
// tells no disk from a disk without the motor; a DD disk (write protected) is detected (DD found, max R 9),
// read and verified, a request for sector 12 with 18 sectors per track stays invalid; with no disk
// READ_TRACK and DETECT end in "no index"; a clean track fills completely and exits before the second
// index.
// Phase 3 (writes, on the clean HD disk and then a DD disk): WRITE_SECTOR of one sector, the drive model
// records the flux transitions and the sector reads back byte-exact after a forced re-read of the whole
// track with every neighbour intact (the model checks that WRITE GATE went on in gap 2 / the data sync and
// off in the sector's own gap 3 with a margin before the next ID field, and reports the splice position);
// a write-protected disk is refused before WRITE GATE; a write after a seek; three consecutive sectors
// written back to back within one revolution (a DOS multi-sector write) and a read of a just-written
// sector before its verify; a write the model corrupts fails its background verify and the flag clears;
// a seek waits for the pending verify; bad arguments, a sector the track does not have, no disk; the same
// at 250 kbit/s on the DD disk; write precompensation is on from cylinder 20 in this bench (4 clocks).
// Phase 4 (FORMAT_TRACK): a blank HD disk on a 3 % fast spindle is detected as "index, no headers";
// C0 H0 is formatted with 18 sectors (the model checks WRITE GATE on within 4 bytes of the index and off
// within 8 bytes of the next one, one index inside the write), the engine's own read-back finds all 18
// sectors, every sector compares as 512 x the fill byte, the gap 4b count says how much of the fast
// revolution was left; the same track formatted with the BIOS table's gap 3 of 0x6C overruns the index
// (err 11), which is why the default is 0x54; C40 H1 after a seek, then a WRITE_SECTOR on the freshly
// formatted track (the splice lands in our own gap 2) and a full compare; write protect refused before
// WRITE GATE; a MEGA65/1581-style DD disk with 10 sectors and a short gap 3 is formatted with 9 (both
// sides), its old sector 10 is gone; no disk (no index); bad arguments.
// Disabling drops the motor, the select and the cache.
//   powershell -File run_floppy_sector_engine_tb.ps1
`timescale 1ns/1ps

module floppy_sector_engine_tb;

   localparam int SPINUP_CYC   = 50_000;      // 1 ms motor spin-up
   localparam int STEP_PULSE   = 600;         // 12 us (the real value)
   localparam int STEP_RATE    = 15_000;      // 300 us step to step
   localparam int SETTLE_CYC   = 25_000;      // 0.5 ms head settle
   localparam int SIDE_CYC     = 5_000;       // 100 us side switch
   localparam int IDX_TIMEOUT  = 12_500_000;  // 250 ms without index = no disk (> 1 revolution)
   localparam int MOTOR_OFF    = 25_000_000;  // 500 ms idle -> motor off
   localparam int MAX_HOME     = 85;

   localparam logic [3:0] CMD_DETECT = 4'd1, CMD_READ = 4'd2, CMD_COPY = 4'd3, CMD_PROBE = 4'd4, CMD_MOTOROFF = 4'd5,
                          CMD_WRITE = 4'd6, CMD_FORMAT = 4'd7;
   localparam logic [7:0] E_OK = 8'd0, E_NO_INDEX = 8'd1, E_RECAL = 8'd2, E_NO_IDAM = 8'd3, E_WRONG_TRK = 8'd4,
                          E_BAD_ARG = 8'd5, E_DISABLED = 8'd6, E_WPROT = 8'd7, E_NO_SECTOR = 8'd9,
                          E_FMT_VFY = 8'd10, E_FMT_OVER = 8'd11;

   // ------------------------------------------------------------------------------------------
   // clock, reset, DUT
   // ------------------------------------------------------------------------------------------
   logic clk = 0;
   logic rst = 1;
   always #10 clk = ~clk;

   logic        enable = 0, chg_clr = 0, vfy_clr = 0, cmd_valid = 0;
   logic [3:0]  cmd = 0;
   logic [7:0]  cmd_cyl = 0;
   logic        cmd_head = 0, cmd_rate = 0, cmd_force = 0;
   logic [4:0]  cmd_sector = 0, cmd_spt = 0;
   logic [7:0]  cmd_fill = 8'hF6, cmd_gap3 = 8'h00;
   wire  [15:0] fmt_tail;
   wire         busy;
   wire [7:0]   err, det_max_r, cache_cyl, head_track, state;
   wire         det_hd, det_dd, cache_head, cache_rate, cache_valid, wp, dskchg, dskchg_live, track0, motor, index_seen;
   wire         vfy_pend, vfy_fail;
   wire [17:0]  valid, crcerr;
   wire [15:0]  cnt_index, cnt_idam_ok, cnt_dam_ok, cnt_steps;
   wire [31:0]  last_chrn;
   wire [8:0]   buf_addr;
   wire [7:0]   buf_data;
   wire         buf_we, buf_rd;
   logic [7:0]  buf_rdata = 8'h00;
   wire         f_density, f_motora, f_selecta, f_side1, f_stepdir, f_step, f_wdata, f_wgate;
   wire         f_index, f_track0, f_wp, f_rdata, f_dskchg;

   floppy_sector_engine #(
      .G_SPINUP_CYCLES        (SPINUP_CYC),
      .G_STEP_PULSE_CYCLES    (STEP_PULSE),
      .G_STEP_RATE_CYCLES     (STEP_RATE),
      .G_SETTLE_CYCLES        (SETTLE_CYC),
      .G_SIDE_SETTLE_CYCLES   (SIDE_CYC),
      .G_INDEX_TIMEOUT_CYCLES (IDX_TIMEOUT),
      .G_MOTOR_OFF_CYCLES     (MOTOR_OFF),
      .G_MAX_STEPS_HOME       (MAX_HOME),
      .G_PRECOMP_CYCLES       (4),
      .G_PRECOMP_FROM_CYL     (20)
   ) dut (
      .clk_i (clk), .rst_i (rst),
      .enable_i (enable), .chg_clr_i (chg_clr), .vfy_clr_i (vfy_clr), .cmd_valid_i (cmd_valid), .cmd_i (cmd),
      .cmd_cyl_i (cmd_cyl), .cmd_head_i (cmd_head), .cmd_rate_hd_i (cmd_rate), .cmd_force_i (cmd_force),
      .cmd_sector_i (cmd_sector), .cmd_spt_i (cmd_spt), .cmd_fill_i (cmd_fill), .cmd_gap3_i (cmd_gap3),
      .fmt_tail_o (fmt_tail),
      .busy_o (busy), .err_o (err), .det_max_r_o (det_max_r), .det_hd_o (det_hd), .det_dd_o (det_dd),
      .valid_o (valid), .crcerr_o (crcerr), .cache_cyl_o (cache_cyl), .cache_head_o (cache_head),
      .cache_rate_o (cache_rate), .head_track_o (head_track), .state_o (state),
      .cache_valid_o (cache_valid), .wp_o (wp), .dskchg_o (dskchg), .dskchg_live_o (dskchg_live),
      .track0_o (track0), .motor_o (motor), .index_seen_o (index_seen), .vfy_pend_o (vfy_pend), .vfy_fail_o (vfy_fail),
      .cnt_index_o (cnt_index), .cnt_idam_ok_o (cnt_idam_ok), .cnt_dam_ok_o (cnt_dam_ok), .cnt_steps_o (cnt_steps),
      .last_chrn_o (last_chrn),
      .buf_addr_o (buf_addr), .buf_data_o (buf_data), .buf_we_o (buf_we), .buf_rd_o (buf_rd), .buf_rdata_i (buf_rdata),
      .f_density_o (f_density), .f_motora_o (f_motora), .f_selecta_o (f_selecta), .f_side1_o (f_side1),
      .f_stepdir_o (f_stepdir), .f_step_o (f_step), .f_wdata_o (f_wdata), .f_wgate_o (f_wgate),
      .f_index_i (f_index), .f_track0_i (f_track0), .f_writeprotect_i (f_wp), .f_rdata_i (f_rdata),
      .f_diskchanged_i (f_dskchg)
   );

   floppy_drive_model #(
      .SPINUP_CYC (SPINUP_CYC), .STEP_RATE (STEP_RATE), .STEP_PULSE (STEP_PULSE), .MOTOR_BEFORE_STEP (0)
   ) model (
      .rst (rst),
      .f_density (f_density), .f_motora (f_motora), .f_selecta (f_selecta), .f_side1 (f_side1),
      .f_stepdir (f_stepdir), .f_step (f_step), .f_wdata (f_wdata), .f_wgate (f_wgate),
      .f_index (f_index), .f_track0 (f_track0), .f_wp (f_wp), .f_rdata (f_rdata), .f_dskchg (f_dskchg)
   );

   // ------------------------------------------------------------------------------------------
   // bookkeeping
   // ------------------------------------------------------------------------------------------
   int n_pass = 0, n_fail = 0;
   task automatic check(input bit cond, input string msg);
      if (cond) n_pass++;
      else begin n_fail++; $display("FLP FAIL @%0t: %s", $time, msg); end
   endtask

   // the vd_glue block buffer as the COPY sees it (written) and as WRITE_SECTOR reads it (one clock latency)
   byte  bbuf [0:511];
   int   bwrites = 0;
   always @(posedge clk) begin
      if (buf_we) begin bbuf[buf_addr] = buf_data; bwrites++; end
      buf_rdata <= bbuf[buf_addr];
   end

   // what every sector should hold: the model's pattern, or the pattern id it was written with
   int pat_tbl [0:82][0:1][0:18];
   function automatic byte wpat(input int id, input int s, input int k, input int c, input int h);
      return ((k * (id + 3) + s * 13 + c * 7 + h * 29) ^ (k >> 2) ^ (id * 'h5A)) & 8'hFF;
   endfunction
   function automatic byte exp_byte(input int s, input int k, input int c, input int h);
      if (pat_tbl[c][h][s] >= 1000) return byte'(pat_tbl[c][h][s] - 1000);      // formatted: the fill byte
      if (pat_tbl[c][h][s] != 0) return wpat(pat_tbl[c][h][s], s, k, c, h);
      return model.data_byte(s, k, c, h);
   endfunction

   // busy must never be low while a command is in flight for more than this
   task automatic wait_done(input string what, input real max_ms);
      fork
         begin @(negedge busy); end
         begin #(max_ms * 1ms); check(0, $sformatf("timeout waiting for %s", what)); end
      join_any
      disable fork;
      @(posedge clk); #1;
   endtask

   real t_cmd;
   task automatic run(input logic [3:0] c, input int cyl, input int head, input bit rate, input bit frc,
                      input int sector, input int spt, input string what, input real max_ms);
      @(posedge clk);
      cmd = c; cmd_cyl = cyl; cmd_head = head; cmd_rate = rate; cmd_force = frc;
      cmd_sector = sector; cmd_spt = spt;
      #1;
      if ($test$plusargs("FLPDBG"))
         $display("FLP DBG %s: cmd %0d C%0d H%0d rate %0d force %0d sector %0d spt %0d | hit %0d cache_valid %0d cache C%0d H%0d rate %0d valid %018b cmd_slot %0d sec_ok %0d seq %0d busy %0d",
                  what, c, cyl, head, rate, frc, sector, spt, dut.hit, dut.cache_valid, dut.cache_cyl, dut.cache_head, dut.cache_rate, dut.valid, dut.cmd_slot, dut.cmd_sec_ok, state, busy);
      cmd_valid = 1;                                   // high from 1 ns after this edge ...
      @(posedge clk);
      #1;
      cmd_valid = 0;                                   // ... to 1 ns after the next: sampled exactly once
      t_cmd = $realtime;
      if (busy) wait_done(what, max_ms);
      else begin @(posedge clk); #1; end
   endtask

   // COPY sector s and compare with the model's data for cylinder c, head h
   task automatic copy_check(input int s, input int c, input int h);
      int bad = 0;
      for (int k = 0; k < 512; k++) bbuf[k] = 8'hEE;
      bwrites = 0;
      run(CMD_COPY, 0, 0, 0, 0, s, 0, $sformatf("COPY %0d", s), 1.0);
      check(err == E_OK, $sformatf("COPY %0d: err %0d", s, err));
      check(bwrites == 512, $sformatf("COPY %0d: %0d buffer writes (512)", s, bwrites));
      for (int k = 0; k < 512; k++) if (bbuf[k] !== exp_byte(s, k, c, h)) bad++;
      check(bad == 0, $sformatf("COPY %0d (C%0d H%0d): %0d bytes differ", s, c, h, bad));
   endtask

   function automatic logic [17:0] expect_valid(input int nsec, input int bad_id, input int bad_data);
      logic [17:0] v = 0;
      for (int s = 1; s <= nsec; s++) if (s != bad_id && s != bad_data) v[s - 1] = 1;
      return v;
   endfunction

   // read a track and verify every valid sector
   task automatic read_track_check(input int c, input int h, input bit hd, input int nsec, input string what);
      logic [17:0] ev = expect_valid(nsec, model.bad_id, model.bad_data);
      run(CMD_READ, c, h, hd, 0, 1, nsec, what, 1500.0);
      check(err == E_OK, $sformatf("%s: err %0d", what, err));
      check(model.pos == c, $sformatf("%s: model at track %0d (%0d)", what, model.pos, c));
      check(head_track == c, $sformatf("%s: head_track %0d", what, head_track));
      check(cache_valid && cache_cyl == c && cache_head == h[0] && cache_rate == hd,
            $sformatf("%s: cache C%0d H%0d rate %0d valid %0d", what, cache_cyl, cache_head, cache_rate, cache_valid));
      check(valid == ev, $sformatf("%s: valid %018b (expected %018b)", what, valid, ev));
      if (model.bad_data != 0) check(crcerr[model.bad_data - 1] == 1'b1, $sformatf("%s: crcerr set for sector %0d", what, model.bad_data));
      for (int s = 1; s <= nsec; s++) if (ev[s - 1]) copy_check(s, c, h);
   endtask

   // WRITE sector s of C c, H h at rate hd with pattern id; expects err e (0: remembered as written)
   task automatic write_sector(input int s, input int c, input int h, input bit hd, input int id,
                               input logic [7:0] e, input string what);
      int w0 = model.writes;
      for (int k = 0; k < 512; k++) bbuf[k] = wpat(id, s, k, c, h);
      run(CMD_WRITE, c, h, hd, 0, s, 0, what, 1500.0);
      check(err == e, $sformatf("%s: err %0d (expected %0d)", what, err, e));
      if (e == E_OK) begin
         if (err == E_OK) pat_tbl[c][h][s] = id;
         check(model.writes == w0 + 1, $sformatf("%s: %0d writes recorded by the drive (1)", what, model.writes - w0));
         check(model.last_wr_sector == s, $sformatf("%s: the drive saw the write on sector %0d", what, model.last_wr_sector));
         check(model.last_wr_lead >= 12 && model.last_wr_lead <= 24,
               $sformatf("%s: WRITE GATE on %0d gap bytes after the ID CRC (12..24)", what, model.last_wr_lead));
         check(model.last_wr_pulses > 2500 && model.last_wr_pulses < 8600,
               $sformatf("%s: %0d flux transitions written", what, model.last_wr_pulses));
         $display("FLP write %s: splice %0d bytes after the ID CRC, WRITE GATE off %0d bytes before the next ID sync, %0d transitions, min gap %0.0f ns",
                  what, model.last_wr_lead, model.last_wr_margin, model.last_wr_pulses, model.last_wr_min_gap);
      end else begin
         check(model.writes == w0, $sformatf("%s: no write reached the drive", what));
      end
   endtask

   // FORMAT C c, H h at rate hd with nsec sectors, fill byte and gap 3 (0 = the engine's default); expects err e
   task automatic format_track(input int c, input int h, input bit hd, input int nsec, input byte fill,
                               input byte gap3, input logic [7:0] e, input string what);
      int  w0 = model.writes;
      real t0 = $realtime;
      logic [17:0] ev = 0;
      for (int s = 1; s <= nsec; s++) ev[s - 1] = 1;
      model.fmt_expect = (e == E_OK || e == E_FMT_OVER || e == E_FMT_VFY);
      model.fmt_nsec   = nsec;
      model.fmt_gap3   = (gap3 != 0) ? int'(gap3) : (hd ? 84 : 80);
      cmd_fill = fill; cmd_gap3 = gap3;
      run(CMD_FORMAT, c, h, hd, 0, 0, nsec, what, 2500.0);
      check(err == e, $sformatf("%s: err %0d (expected %0d)", what, err, e));
      check(f_wgate === 1'b1, $sformatf("%s: WRITE GATE released", what));
      if (e == E_OK) begin
         if (err == E_OK) begin
            for (int s = 0; s < 19; s++) pat_tbl[c][h][s] = (s >= 1 && s <= nsec) ? 1000 + (int'(fill) & 32'hFF) : 0;   // byte is signed
         end
         check(model.writes == w0 + 1, $sformatf("%s: %0d writes recorded by the drive (1)", what, model.writes - w0));
         check(model.last_wr_full == 1, $sformatf("%s: the drive saw a full-track write", what));
         check(model.pos == c && head_track == c, $sformatf("%s: head on cylinder %0d (model %0d, engine %0d)", what, c, model.pos, head_track));
         check(cache_valid && cache_cyl == c && cache_head == h[0] && cache_rate == hd,
               $sformatf("%s: cache C%0d H%0d rate %0d valid %0d", what, cache_cyl, cache_head, cache_rate, cache_valid));
         check(valid == ev, $sformatf("%s: read-back valid %018b (expected %018b)", what, valid, ev));
         check(crcerr == 0, $sformatf("%s: read-back CRC errors %018b", what, crcerr));
         check(fmt_tail > 0, $sformatf("%s: %0d gap 4b bytes written before the index (> 0)", what, fmt_tail));
         check(!vfy_pend && !vfy_fail, $sformatf("%s: no verify pending or failed", what));
         $display("FLP format %s: WRITE GATE on %0d bytes after the index, off %0d bytes after the next, %0d transitions, %0d gap 4b bytes, %0.1f ms",
                  what, model.last_wr_lead, model.last_wr_end, model.last_wr_pulses, fmt_tail, ($realtime - t0) / 1.0e6);
      end else if (e == E_FMT_OVER) begin
         check(model.writes == w0 + 1, $sformatf("%s: the (overrunning) write reached the drive", what));
         check(fmt_tail == 0, $sformatf("%s: no gap 4b byte written (%0d)", what, fmt_tail));
         for (int s = 0; s < 19; s++) pat_tbl[c][h][s] = -1;                        // the track is unusable
         $display("FLP format %s: overrun, the index came while writing sector %0d (%0d transitions)", what, dut.fr_sec, model.last_wr_pulses);
      end else begin
         check(model.writes == w0, $sformatf("%s: no write reached the drive", what));
      end
      model.fmt_expect = 0;
      cmd_fill = 8'hF6; cmd_gap3 = 8'h00;
   endtask

   // wait for the background verify of every written sector
   task automatic wait_verify(input string what, input bit expect_fail);
      fork
         begin wait (!vfy_pend); end
         begin #700ms; check(0, $sformatf("%s: verify still pending after 700 ms", what)); end
      join_any
      disable fork;
      @(posedge clk); #1;
      check(vfy_fail == expect_fail, $sformatf("%s: vfy_fail %0d (expected %0d)", what, vfy_fail, expect_fail));
   endtask

   // ------------------------------------------------------------------------------------------
   // the test
   // ------------------------------------------------------------------------------------------
   real t0, t1;
   int  steps0;

   initial begin
      model.insert(1, 0);                                              // HD disk, not protected
      model.pos = 5; model.dskchg = 1;
      #200; rst = 0;
      #200;

      // --- disabled ---
      check(f_selecta === 1'b1 && f_motora === 1'b1, "disabled: drive not selected, motor off");
      run(CMD_READ, 0, 0, 1, 0, 1, 18, "READ while disabled", 1.0);
      check(err == E_DISABLED, $sformatf("READ while disabled: err %0d (6)", err));
      check(f_motora === 1'b1, "READ while disabled: motor stays off");

      // --- enable: the drive's latched DISK CHANGE appears as an edge ---
      enable = 1;
      #2us;
      check(f_selecta === 1'b0, "enabled: drive selected");
      check(dskchg_live, "enabled: DISK CHANGE line asserted (power-up latch)");
      check(dskchg, "enabled: sticky disk-change flag set");
      @(posedge clk); chg_clr = 1; @(posedge clk); chg_clr = 0; #100;
      check(!dskchg, "chg_clr clears the sticky flag");

      // --- DETECT on the HD disk ---
      steps0 = model.model_steps;
      run(CMD_DETECT, 0, 0, 0, 0, 0, 0, "DETECT (HD)", 1500.0);
      check(err == E_OK, $sformatf("DETECT HD: err %0d", err));
      check(model.pos == 0, $sformatf("DETECT: recalibrated (model at %0d)", model.pos));
      check(model.model_steps - steps0 == 5, $sformatf("DETECT: 5 steps out from track 5 (%0d)", model.model_steps - steps0));
      check(det_hd && !det_dd, $sformatf("DETECT HD: hd %0d dd %0d", det_hd, det_dd));
      check(det_max_r == 18, $sformatf("DETECT HD: max R %0d (18)", det_max_r));
      check(motor, "DETECT: motor on afterwards");
      check(!dskchg_live, "DETECT: the recalibrate step cleared the drive's latch");
      check(!wp, "HD disk: not write protected");
      check(index_seen, "DETECT: index seen");
      check(!cache_valid, "DETECT: cache dropped");

      // --- READ_TRACK C0 H0 and every sector ---
      read_track_check(0, 0, 1, 18, "READ C0 H0 HD");
      check(crcerr[6] && !valid[6] && !valid[4] && !crcerr[4],
            "C0 H0: sector 7 data CRC error flagged, sector 5 (bad ID) never captured");

      // --- the bad sector stays bad: plain re-read (cache miss on sector 7), then forced ---
      steps0 = model.model_steps;
      run(CMD_READ, 0, 0, 1, 0, 7, 18, "READ C0 H0 sector 7 (bad)", 1500.0);
      check(err == E_OK && !valid[6] && crcerr[6], "re-read: sector 7 still invalid with CRC error");
      check(valid == expect_valid(18, 5, 7), "re-read: the other sectors kept");
      check(model.model_steps == steps0, "re-read on the same track: no step");
      run(CMD_READ, 0, 0, 1, 1, 7, 18, "READ C0 H0 sector 7 forced", 1500.0);
      check(err == E_OK && !valid[6] && crcerr[6], "forced re-read: sector 7 still invalid");
      check(model.model_steps == steps0 + 2, $sformatf("forced re-read recalibrated (1 in, 1 out: %0d steps)", model.model_steps - steps0));
      check(model.pos == 0, "forced re-read: back at track 0");

      // --- bad arguments ---
      run(CMD_COPY, 0, 0, 0, 0, 0, 0, "COPY 0", 1.0);
      check(err == E_BAD_ARG, $sformatf("COPY sector 0: err %0d (5)", err));
      run(CMD_COPY, 0, 0, 0, 0, 19, 0, "COPY 19", 1.0);
      check(err == E_BAD_ARG, $sformatf("COPY sector 19: err %0d (5)", err));
      run(CMD_READ, 83, 0, 1, 0, 1, 18, "READ C83", 1.0);
      check(err == E_BAD_ARG, $sformatf("READ cylinder 83: err %0d (5)", err));
      run(4'd9, 0, 0, 0, 0, 0, 0, "bad command", 1.0);
      check(err == E_BAD_ARG, $sformatf("unknown command: err %0d (5)", err));

      // --- wrong rate: DD windows on an HD disk decode nothing ---
      run(CMD_READ, 0, 0, 0, 0, 1, 18, "READ C0 H0 at DD on the HD disk", 1500.0);
      check(err == E_NO_IDAM, $sformatf("wrong rate: err %0d (3)", err));
      check(!cache_valid, "wrong rate: cache dropped");

      // --- seeks: cylinder 40 head 1, head 0 without a seek, cylinder 3 ---
      steps0 = model.model_steps;
      read_track_check(40, 1, 1, 18, "READ C40 H1 HD");
      check(model.model_steps - steps0 == 40, $sformatf("seek to 40: %0d steps", model.model_steps - steps0));
      steps0 = model.model_steps;
      read_track_check(40, 0, 1, 18, "READ C40 H0 HD");
      check(model.model_steps == steps0, "side switch: no step");
      read_track_check(3, 0, 1, 18, "READ C3 H0 HD");
      check(model.model_steps - steps0 == 37, $sformatf("seek 40 -> 3: %0d steps", model.model_steps - steps0));

      // --- cache hit: no motor needed, answered at once ---
      t0 = $realtime;
      run(CMD_READ, 3, 0, 1, 0, 2, 18, "READ C3 H0 sector 2 (hit)", 1.0);
      check(err == E_OK, "cache hit: err 0");
      check($realtime - t0 < 2000.0, $sformatf("cache hit: answered in %0.0f ns", $realtime - t0));
      copy_check(2, 3, 0);
      if ($test$plusargs("FLPSTOP")) begin
         n_pass += model.n_pass; n_fail += model.n_fail;
         $display("FLP RESULT: STOPPED after the cache-hit test (%0d failed, %0d passed)", n_fail, n_pass);
         $finish;
      end

      // --- motor-off timer, then spin-up before the next seek ---
      #(MOTOR_OFF * 20ns + 200us);
      check(f_motora === 1'b1, "motor off after the idle time");
      check(cache_valid, "cache survives the motor stop");
      run(CMD_READ, 3, 0, 1, 0, 9, 18, "READ C3 H0 sector 9 (hit, motor off)", 1.0);
      check(err == E_OK && f_motora === 1'b1, "cache hit with the motor off: no spin-up");
      t0 = $realtime;
      read_track_check(4, 0, 1, 18, "READ C4 H0 HD after motor off");
      check($realtime - t0 >= SPINUP_CYC * 20.0, "motor spun up before the seek (model checks the timing)");

      // --- disk change: eject, probe (no disk), insert DD write-protected, probe (disk) ---
      model.eject();
      #10us;
      check(dskchg, "eject: sticky disk-change flag");
      check(!cache_valid, "eject: cache dropped");
      @(posedge clk); chg_clr = 1; @(posedge clk); chg_clr = 0;
      #(MOTOR_OFF * 20ns + 200us);
      check(f_motora === 1'b1, "motor off while ejected");
      steps0 = model.model_steps;
      run(CMD_PROBE, 0, 0, 0, 0, 0, 0, "PROBE (no disk)", 10.0);
      check(err == E_OK, "PROBE: err 0");
      check(model.model_steps - steps0 == 2, $sformatf("PROBE: 2 steps (%0d)", model.model_steps - steps0));
      check(f_motora === 1'b1, "PROBE: without the motor");
      check(dskchg_live, "PROBE with no disk: DISK CHANGE stays asserted");
      check(model.pos == 4, $sformatf("PROBE: head back where it was (%0d)", model.pos));
      model.insert(0, 1);                                              // DD disk, write protected
      run(CMD_PROBE, 0, 0, 0, 0, 0, 0, "PROBE (DD disk)", 10.0);
      check(!dskchg_live, "PROBE with a disk: DISK CHANGE cleared by the step");
      check(wp, "DD disk: write protected");

      // --- DETECT on the DD disk ---
      run(CMD_DETECT, 0, 0, 0, 0, 0, 0, "DETECT (DD)", 1500.0);
      check(err == E_OK, $sformatf("DETECT DD: err %0d", err));
      check(!det_hd && det_dd, $sformatf("DETECT DD: hd %0d dd %0d", det_hd, det_dd));
      check(det_max_r == 9, $sformatf("DETECT DD: max R %0d (9)", det_max_r));
      check(model.pos == 0, "DETECT DD: at track 0");
      read_track_check(0, 0, 0, 9, "READ C0 H0 DD");
      read_track_check(7, 1, 0, 9, "READ C7 H1 DD");
      check(f_density === 1'b0, "DENSITY = G_DENSITY_DD while reading at 250 kbit/s");

      // --- a sector the disk does not have (FDC told 18 SPT, disk has 9): stays invalid ---
      run(CMD_READ, 7, 1, 0, 0, 12, 18, "READ C7 H1 sector 12 of 18", 1500.0);
      check(err == E_OK && !valid[11] && !crcerr[11], "sector 12 on a 9-sector track: invalid, no CRC error");
      check(valid == expect_valid(9, 5, 7), "sector 12 request: the 9 real sectors still valid");

      // --- no disk: READ_TRACK and DETECT time out on the index ---
      model.eject();
      #10us;
      run(CMD_READ, 8, 0, 0, 0, 1, 9, "READ with no disk", 1500.0);
      check(err == E_NO_INDEX, $sformatf("READ with no disk: err %0d (1)", err));
      check(!index_seen, "READ with no disk: no index seen");
      run(CMD_DETECT, 0, 0, 0, 0, 0, 0, "DETECT with no disk", 1500.0);
      check(err == E_NO_INDEX && !det_hd && !det_dd && det_max_r == 0, $sformatf("DETECT with no disk: err %0d hd %0d dd %0d maxr %0d", err, det_hd, det_dd, det_max_r));

      // --- a clean HD disk: the whole track fills and the capture exits early ---
      model.insert(1, 0);
      model.bad_id = 0; model.bad_data = 0;
      run(CMD_PROBE, 0, 0, 0, 0, 0, 0, "PROBE (clean HD)", 10.0);
      @(posedge clk); chg_clr = 1; @(posedge clk); chg_clr = 0;
      run(CMD_DETECT, 0, 0, 0, 0, 0, 0, "DETECT (clean HD)", 1500.0);
      check(det_hd && det_max_r == 18, "clean HD detected");
      t0 = $realtime;
      read_track_check(12, 1, 1, 18, "READ C12 H1 clean HD");
      check(valid == 18'h3FFFF && crcerr == 0, "clean track: all 18 sectors valid, no CRC errors");
      t1 = $realtime - t0;
      check(t1 < 12.0 * 200.0e6 / 10.0 + 400.0e6, $sformatf("clean track read in %0.1f ms (< seek + 1.2 revolutions)", t1 / 1.0e6));
      run(CMD_MOTOROFF, 0, 0, 0, 0, 0, 0, "MOTOR_OFF", 1.0);
      check(f_motora === 1'b1, "MOTOR_OFF: motor off at once");

      // ==========================================================================================
      // phase 3: writes
      // ==========================================================================================
      for (int c = 0; c < 83; c++) for (int h = 0; h < 2; h++) for (int s = 0; s < 19; s++) pat_tbl[c][h][s] = 0;

      // --- one sector on the cached track (C12 H1, no precompensation below cylinder 20) ---
      check(!vfy_pend && !vfy_fail, "before any write: no verify pending or failed");
      write_sector(4, 12, 1, 1, 1, E_OK, "WRITE C12 H1 s4");
      check(!valid[3] && !crcerr[3], "after the write: slot 4 invalid, no CRC error");
      check(valid == (18'h3FFFF & ~18'h8), "after the write: the other 17 slots still valid");
      check(vfy_pend, "after the write: verify pending");
      check(f_wgate === 1'b1, "after the write: WRITE GATE released");
      wait_verify("WRITE C12 H1 s4", 0);
      check(valid[3] && !crcerr[3], "verify read the sector back into slot 4");
      copy_check(4, 12, 1);                                            // the read-back copy
      run(CMD_READ, 12, 1, 1, 1, 4, 18, "READ C12 H1 forced after the write", 1500.0);
      check(err == E_OK && valid == 18'h3FFFF && crcerr == 0, "forced re-read after the write: all 18 valid");
      for (int s = 1; s <= 18; s++) copy_check(s, 12, 1);              // the written one and its neighbours

      // --- write protect: refused before WRITE GATE ---
      model.disk_wp = 1;
      #10us;
      check(wp, "write protect tab: wp flag");
      write_sector(5, 12, 1, 1, 2, E_WPROT, "WRITE on a protected disk");
      check(valid[4], "refused write: slot 5 untouched");
      model.disk_wp = 0;
      #10us;

      // --- bad arguments ---
      write_sector(0, 12, 1, 1, 2, E_BAD_ARG, "WRITE sector 0");
      write_sector(19, 12, 1, 1, 2, E_BAD_ARG, "WRITE sector 19");
      run(CMD_WRITE, 83, 0, 1, 0, 1, 0, "WRITE C83", 1.0);
      check(err == E_BAD_ARG, $sformatf("WRITE cylinder 83: err %0d (5)", err));

      // --- after a seek, with precompensation (cylinder 30 >= 20) ---
      steps0 = model.model_steps;
      write_sector(1, 30, 0, 1, 3, E_OK, "WRITE C30 H0 s1");
      check(model.model_steps - steps0 == 18, $sformatf("seek 12 -> 30 before the write: %0d steps", model.model_steps - steps0));
      check(model.pos == 30, "head on cylinder 30");
      wait_verify("WRITE C30 H0 s1", 0);
      // the verify put sector 1 into the cache, so a read of sector 1 would be a hit; DOS reads on:
      // sector 2 misses and the capture fills the rest of the track
      run(CMD_READ, 30, 0, 1, 0, 2, 18, "READ C30 H0 s2 after the write", 1500.0);
      check(err == E_OK && valid == 18'h3FFFF && crcerr == 0, "read of the next sector after the write: the whole track captured, 18 valid");
      for (int s = 1; s <= 18; s++) copy_check(s, 30, 0);

      // --- three consecutive sectors back to back (a DOS multi-sector write), then a read before the verify ---
      write_sector(6, 30, 0, 1, 4, E_OK, "WRITE C30 H0 s6");
      t0 = $realtime;
      write_sector(7, 30, 0, 1, 4, E_OK, "WRITE C30 H0 s7");
      write_sector(8, 30, 0, 1, 4, E_OK, "WRITE C30 H0 s8");
      t1 = $realtime - t0;
      check(t1 < 60.0e6, $sformatf("sectors 7 and 8 written %0.1f ms after sector 6 (same revolution, < 60 ms)", t1 / 1.0e6));
      check(vfy_pend, "three verifies pending");
      run(CMD_READ, 30, 0, 1, 0, 7, 18, "READ C30 H0 s7 right after writing it", 1500.0);
      check(err == E_OK && valid[6], "read of a just-written sector: captured");
      copy_check(7, 30, 0);
      wait_verify("WRITE C30 H0 s6..8", 0);
      run(CMD_READ, 30, 0, 1, 1, 1, 18, "READ C30 H0 forced", 1500.0);
      check(err == E_OK && valid == 18'h3FFFF && crcerr == 0, "forced re-read: all 18 valid after 4 writes");
      for (int s = 1; s <= 18; s++) copy_check(s, 30, 0);

      // --- a write the drive corrupts: the background verify fails, the flag clears ---
      model.corrupt_next = 1;
      write_sector(12, 30, 0, 1, 5, E_OK, "WRITE C30 H0 s12 (corrupted by the drive)");
      wait_verify("corrupted write", 1);
      check(!valid[11], "corrupted sector: slot stays invalid");
      pat_tbl[30][0][12] = 0;
      @(posedge clk); vfy_clr = 1; @(posedge clk); vfy_clr = 0; #100;
      check(!vfy_fail, "vfy_clr clears the failure");
      write_sector(12, 30, 0, 1, 6, E_OK, "WRITE C30 H0 s12 again");
      wait_verify("rewrite of sector 12", 0);
      copy_check(12, 30, 0);

      // --- a seek waits for the pending verify ---
      write_sector(2, 30, 0, 1, 7, E_OK, "WRITE C30 H0 s2");
      check(vfy_pend, "verify pending before the seek");
      steps0 = model.model_steps;
      read_track_check(31, 0, 1, 18, "READ C31 H0 right after a write on C30");
      check(!vfy_pend && !vfy_fail, "the verify of C30 s2 completed before the head moved");
      check(model.model_steps - steps0 == 1, "one step to cylinder 31");
      run(CMD_READ, 30, 0, 1, 0, 2, 18, "READ C30 H0 s2", 1500.0);
      check(err == E_OK && valid[1], "C30 s2 reads back");
      copy_check(2, 30, 0);

      // --- a sector the track does not have, no disk ---
      run(CMD_WRITE, 30, 0, 0, 0, 3, 0, "WRITE at the DD rate on the HD disk", 1500.0);
      check(err == E_NO_IDAM, $sformatf("write at the wrong rate: err %0d (3)", err));
      model.eject();
      #10us;
      @(posedge clk); chg_clr = 1; @(posedge clk); chg_clr = 0;
      run(CMD_WRITE, 30, 0, 1, 0, 3, 0, "WRITE with no disk", 1500.0);
      check(err == E_NO_INDEX, $sformatf("write with no disk: err %0d (1)", err));

      // --- the DD disk at 250 kbit/s: one sector, a sector after a side switch, a missing sector ---
      model.insert(0, 0);
      model.bad_id = 0; model.bad_data = 0;
      run(CMD_PROBE, 0, 0, 0, 0, 0, 0, "PROBE (clean DD)", 10.0);
      @(posedge clk); chg_clr = 1; @(posedge clk); chg_clr = 0;
      run(CMD_DETECT, 0, 0, 0, 0, 0, 0, "DETECT (clean DD)", 1500.0);
      check(det_dd && !det_hd && det_max_r == 9, "clean DD detected");
      read_track_check(0, 0, 0, 9, "READ C0 H0 DD before writing");
      write_sector(3, 0, 0, 0, 8, E_OK, "WRITE C0 H0 s3 DD");
      check(f_density === 1'b0, "DENSITY = G_DENSITY_DD while writing at 250 kbit/s");
      wait_verify("WRITE C0 H0 s3 DD", 0);
      write_sector(9, 0, 1, 0, 9, E_OK, "WRITE C0 H1 s9 DD (side switch)");
      wait_verify("WRITE C0 H1 s9 DD", 0);
      run(CMD_WRITE, 0, 1, 0, 0, 12, 0, "WRITE C0 H1 s12 on a 9-sector track", 1500.0);
      check(err == E_NO_SECTOR, $sformatf("write of sector 12 of 9: err %0d (9)", err));
      run(CMD_READ, 0, 0, 0, 1, 1, 9, "READ C0 H0 DD forced", 1500.0);
      check(err == E_OK && valid == 18'h001FF, "DD C0 H0 after the write: 9 valid");
      for (int s = 1; s <= 9; s++) copy_check(s, 0, 0);
      run(CMD_READ, 0, 1, 0, 1, 1, 9, "READ C0 H1 DD forced", 1500.0);
      check(err == E_OK && valid == 18'h001FF, "DD C0 H1 after the write: 9 valid");
      for (int s = 1; s <= 9; s++) copy_check(s, 0, 1);
      check(!vfy_pend && !vfy_fail, "end of the write tests: nothing pending, nothing failed");
      $display("FLP writes: %0d recorded by the drive", model.writes);

      // ==========================================================================================
      // phase 4: FORMAT_TRACK
      // ==========================================================================================
      // --- a blank HD disk on a 3 % fast spindle: index pulses, no headers at either rate ---
      model.eject();
      #10us;
      model.speed_hd = 0.97;
      model.insert(1, 0);
      model.disk_blank = 1;
      run(CMD_PROBE, 0, 0, 0, 0, 0, 0, "PROBE (blank HD)", 10.0);
      @(posedge clk); chg_clr = 1; @(posedge clk); chg_clr = 0;
      run(CMD_DETECT, 0, 0, 0, 0, 0, 0, "DETECT (blank HD)", 1500.0);
      check(err == E_OK && !det_hd && !det_dd && det_max_r == 0 && index_seen,
            $sformatf("blank disk: err %0d hd %0d dd %0d maxr %0d index %0d (0 0 0 0 1: the firmware's blank-disk rule)", err, det_hd, det_dd, det_max_r, index_seen));
      run(CMD_READ, 0, 0, 1, 0, 1, 18, "READ C0 H0 on the blank disk", 1500.0);
      check(err == E_NO_IDAM, $sformatf("read of a blank track: err %0d (3)", err));

      // --- format C0 H0 with the defaults (18 sectors, gap 3 0x54, fill F6): everything reads back ---
      t0 = $realtime;
      format_track(0, 0, 1, 18, 8'hF6, 8'h00, E_OK, "FORMAT C0 H0 HD");
      t1 = $realtime - t0;
      check(t1 < 3.0 * 200.0e6 + SPINUP_CYC * 20.0 + 20.0e6, $sformatf("format + read-back in %0.1f ms (< spin-up + 3 revolutions)", t1 / 1.0e6));
      check(fmt_tail >= 100 && fmt_tail <= 200, $sformatf("gap 4b on a 3 %% fast spindle: %0d bytes (100..200: 146 + 18 x 658 = 11990 of 12136 bytes)", fmt_tail));
      for (int s = 1; s <= 18; s++) copy_check(s, 0, 0);
      run(CMD_READ, 0, 0, 1, 1, 1, 18, "READ C0 H0 forced after the format", 1500.0);
      check(err == E_OK && valid == 18'h3FFFF && crcerr == 0, "forced re-read of the formatted track: 18 valid, no CRC error");
      for (int s = 1; s <= 18; s++) copy_check(s, 0, 0);
      run(CMD_DETECT, 0, 0, 0, 0, 0, 0, "DETECT after the format", 1500.0);
      check(det_hd && !det_dd && det_max_r == 18, $sformatf("DETECT after the format: hd %0d dd %0d maxr %0d (1 0 18)", det_hd, det_dd, det_max_r));

      // --- the BIOS table's gap 3 (0x6C = 108) does not fit a 3 % fast revolution: overrun, err 11 ---
      format_track(0, 1, 1, 18, 8'hF6, 8'h6C, E_FMT_OVER, "FORMAT C0 H1 HD with gap 3 0x6C");
      check(!cache_valid || valid == 0, "overrun: no sector believed valid");
      // ... and the same track formatted again with the default is fine
      format_track(0, 1, 1, 18, 8'hE5, 8'h00, E_OK, "FORMAT C0 H1 HD again with the default gap 3");
      for (int s = 1; s <= 18; s++) copy_check(s, 0, 1);

      // --- after a seek (cylinder 40, precompensation on), then a sector write onto our own format ---
      steps0 = model.model_steps;
      format_track(40, 1, 1, 18, 8'h00, 8'h00, E_OK, "FORMAT C40 H1 HD (fill 00)");
      check(model.model_steps - steps0 == 40, $sformatf("seek 0 -> 40 before the format: %0d steps", model.model_steps - steps0));
      write_sector(5, 40, 1, 1, 11, E_OK, "WRITE C40 H1 s5 on the formatted track");
      wait_verify("WRITE C40 H1 s5 on the formatted track", 0);
      run(CMD_READ, 40, 1, 1, 1, 1, 18, "READ C40 H1 forced after the write", 1500.0);
      check(err == E_OK && valid == 18'h3FFFF && crcerr == 0, "formatted track + one sector write: 18 valid");
      for (int s = 1; s <= 18; s++) copy_check(s, 40, 1);

      // --- write protect: refused before WRITE GATE; the track is untouched ---
      model.disk_wp = 1;
      #10us;
      format_track(40, 0, 1, 18, 8'hF6, 8'h00, E_WPROT, "FORMAT on a protected disk");
      model.disk_wp = 0;
      #10us;

      // --- a MEGA65/1581-style DD disk (10 sectors, short gap 3) formatted as 720 KB, both sides ---
      model.eject();
      #10us;
      model.nsec_ovr = 10; model.gap3_ovr = 30;
      model.insert(0, 0);
      model.bad_id = 0; model.bad_data = 0;
      run(CMD_PROBE, 0, 0, 0, 0, 0, 0, "PROBE (1581 DD)", 10.0);
      @(posedge clk); chg_clr = 1; @(posedge clk); chg_clr = 0;
      run(CMD_DETECT, 0, 0, 0, 0, 0, 0, "DETECT (1581 DD)", 1500.0);
      check(det_dd && !det_hd && det_max_r == 10, $sformatf("1581-style disk: dd %0d hd %0d maxr %0d (1 0 10)", det_dd, det_hd, det_max_r));
      format_track(0, 0, 0, 9, 8'hF6, 8'h00, E_OK, "FORMAT C0 H0 DD");
      check(f_density === 1'b0, "DENSITY = G_DENSITY_DD while formatting at 250 kbit/s");
      check(fmt_tail >= 10 && fmt_tail <= 60, $sformatf("gap 4b at 250 kbit/s on a 3 %% fast spindle: %0d bytes (10..60: 146 + 9 x 654 = 6032 of 6068)", fmt_tail));
      for (int s = 1; s <= 9; s++) copy_check(s, 0, 0);
      run(CMD_READ, 0, 0, 0, 0, 10, 18, "READ C0 H0 DD sector 10 after the format", 1500.0);
      check(err == E_OK && valid == 18'h001FF && !valid[9], "the old sector 10 is gone: 9 valid");
      format_track(0, 1, 0, 9, 8'hF6, 8'h00, E_OK, "FORMAT C0 H1 DD (side switch)");
      for (int s = 1; s <= 9; s++) copy_check(s, 0, 1);
      run(CMD_DETECT, 0, 0, 0, 0, 0, 0, "DETECT after the DD format", 1500.0);
      check(det_dd && !det_hd && det_max_r == 9, $sformatf("DETECT after the DD format: dd %0d hd %0d maxr %0d (1 0 9)", det_dd, det_hd, det_max_r));
      model.nsec_ovr = 0; model.gap3_ovr = 0;

      // --- no disk, bad arguments ---
      model.eject();
      #10us;
      @(posedge clk); chg_clr = 1; @(posedge clk); chg_clr = 0;
      format_track(1, 0, 0, 9, 8'hF6, 8'h00, E_NO_INDEX, "FORMAT with no disk");
      format_track(83, 0, 1, 18, 8'hF6, 8'h00, E_BAD_ARG, "FORMAT cylinder 83");
      format_track(1, 0, 1, 0, 8'hF6, 8'h00, E_BAD_ARG, "FORMAT with 0 sectors");
      format_track(1, 0, 1, 19, 8'hF6, 8'h00, E_BAD_ARG, "FORMAT with 19 sectors");
      $display("FLP writes after the format tests: %0d recorded by the drive", model.writes);

      // --- disable ---
      enable = 0;
      #1us;
      check(f_selecta === 1'b1 && f_motora === 1'b1, "disabled: deselected, motor off");
      check(!cache_valid, "disabled: cache dropped");

      $display("FLP counters: index %0d idam ok %0d dam ok %0d steps %0d revolutions %0d",
               cnt_index, cnt_idam_ok, cnt_dam_ok, cnt_steps, model.revs);
      n_pass += model.n_pass; n_fail += model.n_fail;
      if (n_fail == 0) $display("FLP RESULT: PASS (%0d checks)", n_pass);
      else             $display("FLP RESULT: FAIL (%0d failed, %0d passed)", n_fail, n_pass);
      $finish;
   end

   initial begin
      #45s;
      $display("FLP RESULT: FAIL (timeout; %0d failed, %0d passed so far)", n_fail + model.n_fail, n_pass + model.n_pass);
      $finish;
   end

endmodule
