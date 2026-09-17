// floppy_drive_model: a 3.5" PC floppy drive on the Shugart pins, for the benches of
// CORE/vhdl/floppy_phy_spike.vhd and CORE/vhdl/floppy_sector_engine.vhd (docs/floppy.md).
//
//   * outputs (TRACK0, WPT, DSKCHG, INDEX, RDATA) are only driven while DRIVE SELECT is low, as a real
//     drive's open-collector outputs are; DISK CHANGE latches on eject/insert and clears on a STEP pulse
//     with a disk in;
//   * STEP acts on the rising (trailing) edge when selected, DIR high = out (towards track 0); the model
//     checks pulse width, step-to-step interval, DIR set-up/hold around the pulse, that the motor was on
//     for the spin-up time before the first pulse (only when MOTOR_BEFORE_STEP is set: a seek without the
//     motor is legal, the spike just never does one), and that WRITE GATE / WRITE DATA never fall;
//   * rotation: one revolution per pass over a synthetic IBM System 34 track (gap 4a, IAM, 18 or 9
//     sectors of 512 bytes with IDAM / DAM / CRCs, gap 3, gap 4b) built for the current head position and
//     the SIDE1 level, MFM-encoded with real 0x4489 / 0x5224 marks, played as 300 ns low pulses on RDATA
//     at the HD (1 us half cell) or DD (2 us) rate with +3 % / -3 % spindle speed error and +-12 %
//     half-cell jitter on every transition; INDEX low for 2 ms at the start of each revolution.
//     Sector BAD_ID_SECTOR has a corrupt ID CRC, sector BAD_DATA_SECTOR a corrupt data CRC (0 = none);
//     both can be changed at run time (bad_id / bad_data). Data byte k of sector s on cylinder c, head h
//     is data_byte(s, k, c, h).
// The bench drives eject() / insert() and reads pos / dskchg / model_steps / revs hierarchically; the
// model's own checks count into n_pass / n_fail, which the bench adds to its totals.
`timescale 1ns/1ps

module floppy_drive_model #(
   parameter int SPINUP_CYC        = 50_000,   // cycles of 20 ns the motor must have run before a step
   parameter int STEP_RATE         = 15_000,   // minimum step interval in cycles
   parameter int STEP_PULSE        = 600,      // the DUT's STEP low time in cycles (for the interval check)
   parameter bit MOTOR_BEFORE_STEP = 1,        // check that the motor was on for SPINUP_CYC before a step
   parameter int BAD_ID_SECTOR     = 5,
   parameter int BAD_DATA_SECTOR   = 7
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
   int  pos          = 5;          // head position at power-up
   bit  dskchg       = 1;          // latched until a step with a disk in
   int  bad_id       = BAD_ID_SECTOR;
   int  bad_data     = BAD_DATA_SECTOR;
   bit  sel;
   int  head;
   assign sel  = (f_selecta === 1'b0);
   assign head = (f_side1 === 1'b0) ? 1 : 0;

   always_comb begin
      f_track0 = (sel && pos == 0)                ? 1'b0 : 1'b1;
      f_wp     = (sel && disk_present && disk_wp) ? 1'b0 : 1'b1;
      f_dskchg = (sel && dskchg)                  ? 1'b0 : 1'b1;
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

   // never write
   always @(negedge f_wgate) if (!rst) check(0, "WRITE GATE asserted");
   always @(negedge f_wdata) if (!rst) check(0, "WRITE DATA asserted");

   // ------------------------------------------------------------------------------------------
   // track image: IBM System 34, 512-byte sectors, N = 2
   // ------------------------------------------------------------------------------------------
   byte trk[];          // bytes
   bit  mrk[];          // 1 = A1/C2 mark with the missing clock
   int  trk_len;

   task automatic put(input byte b, input bit m, ref int i);
      trk[i] = b; mrk[i] = m; i++;
   endtask

   task automatic build_track(input bit hd, input int cyl, input int hd_side);
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
         hdr[4] = cyl; hdr[5] = hd_side; hdr[6] = s; hdr[7] = 2;
         c = crc16(hdr, 8);
         if (s == bad_id) c ^= 16'h0001;                               // corrupt ID CRC
         put(8'hFE, 0, i); put(hdr[4], 0, i); put(hdr[5], 0, i); put(hdr[6], 0, i); put(hdr[7], 0, i);
         put(c[15:8], 0, i); put(c[7:0], 0, i);
         for (int k = 0; k < 22; k++) put(8'h4E, 0, i);               // gap 2
         for (int k = 0; k < 12; k++) put(8'h00, 0, i);
         for (int k = 0; k < 3;  k++) put(8'hA1, 1, i);
         dat[0] = 8'hA1; dat[1] = 8'hA1; dat[2] = 8'hA1; dat[3] = 8'hFB;
         for (int k = 0; k < 512; k++) dat[4 + k] = data_byte(s, k, cyl, hd_side);
         c = crc16(dat, 516);
         if (s == bad_data) c ^= 16'h0100;                             // corrupt data CRC
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
   int  play_pos, play_head;

   task automatic play_track();
      bit  prev_d = 0;
      bit  stop = 0;
      real t_ideal = $realtime;
      real t_pulse;
      logic [15:0] raw;
      for (int i = 0; i < trk_len && !stop; i++) begin
         // the head moved or the side changed: the same angular position, the other track's data
         if (pos != play_pos || head != play_head) begin
            play_pos  = pos;
            play_head = head;
            build_track(disk_hd, pos, head);
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
            t_ideal += hc_eff;
            if (raw[b]) begin
               t_pulse = t_ideal + jit * (real'($urandom_range(0, 2000)) / 1000.0 - 1.0);
               if (t_pulse > $realtime) #(t_pulse - $realtime);
               if (sel) begin
                  f_rdata = 0;
                  f_rdata <= #300 1'b1;
               end
            end else begin
               if (t_ideal > $realtime) #(t_ideal - $realtime);
            end
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
         hc_eff = disk_hd ? 1000.0 * 1.03 : 2000.0 * 0.97;              // +3 % / -3 % speed
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
