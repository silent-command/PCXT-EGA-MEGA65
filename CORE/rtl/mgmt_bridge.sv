// mgmt_bridge.sv - MEGA65 replacement for the MiSTer ARM (HPS) side of the
// PCXT-EGA storage path: serves rtl/common/ide.v and rtl/common/floppy.v over
// the 16-bit "mgmt" register bus, using the framework's virtual drives.
//
// References (repo docs, section numbers quoted as MGMT x.y / ARM x.y):
//   docs/mgmt-bus-and-storage-regs.md      MGMT: bus and register-level rules
//   docs/arm-side-ide-floppy-behaviour.md  ARM: what Main_MiSTer does, 4 = contract
//
// Bus timing (MGMT 1.5 / 5.1, verified against ide.v and floppy.v; the MEGA65
// wrapper pcxt_core.sv passes the bus straight through as wires):
//   * mgmt_wr / mgmt_rd are one-clock pulses. mgmt_addr / mgmt_dout are
//     registered at least one clock before the pulse and held through it.
//   * Read: address driven at edge E, mgmt_rd high during [E+3, E+4),
//     mgmt_din sampled at edge E+4 (the clock after the pulse). That is the
//     value for the address *before* any side effect: ide.v registers
//     mgmt_readdata from mgmt_address/mgmt_cnt every clock and only bumps
//     mgmt_cnt on the trailing edge of mgmt_read, i.e. at E+5 (ide.v:196-206,
//     267-279); floppy.v returns reg 0 combinationally from registered state
//     and the FIFO byte through fifo_readdata, registered from the FIFO head
//     (floppy.v:79, 845-849); the FIFO pops at E+4 so the head moves after
//     E+4 and fifo_readdata after E+5 (simple_fifo.v:53-59).
//   * Back-to-back IDE buffer reads need >= 4 clocks from one pulse to the
//     next sample (pointer -> dpram q -> registered readdata); the loops
//     below space pulses by >= 8 clocks. Writes need >= 2 (trailing-edge
//     pointer bump before the next pulse is seen); the loops use >= 3.
//
// One flat state machine: an IDE group (MGMT 5.2 / ARM 4.1-4.3), a floppy
// group (MGMT 5.3 / ARM 3, 4.4-4.6) and small helpers (bus cycle, register
// block, buffer streams, block transfer, divider) reached through two
// return registers (bus_ret for the bus cycle, seq_ret for everything else).
// Priority when several things are pending (S_IDLE): IDE mount, IDE request,
// floppy mounts, floppy request.  Only one floppy request can exist at a
// time (one floppy.v serves both drives), so A/B priority never arises.
//
// Floppy read errors (docs/floppy.md, the internal drive): floppy.v has no
// way to report a read error - the ARM sends 512 bytes no matter what and
// its SD state machine leaves S_SD_READ_WAIT_FOR_DATA only on fifo_full or
// the chip reset (not on the DOR software reset). When the firmware
// acknowledges a floppy block with blk_err high, the block is NOT streamed:
// floppy.v keeps waiting, the BIOS's INT 13h times out (error 80h), DOS
// prints "Not ready reading drive A" and drive A stays dead until the next
// core reset - but no garbage reaches DOS and the machine does not hang.
// The still-pending request is parked (fd_hold) so that the hard disk keeps
// being served; the hold clears when the request finally drops (core reset).
// Floppy write errors (the internal drive's write path): floppy.v completes
// a WRITE DATA sector as soon as its FIFO has been drained, long before the
// firmware has written the disk, so a failed physical write (or a failed
// read-back verify of an earlier one) can only be reported on the request
// that follows. When the firmware acknowledges a floppy write block with
// blk_err high, the bridge sets fd_dead: every later floppy request is
// ignored until the chip reset, so the next DOS access (the next sector of
// the same multi-sector write, the FAT update, or a read) times out in the
// BIOS and DOS reports an error instead of believing the write succeeded.
// The hold cannot be tied to the request dropping (as fd_hold is) because
// for the last sector of a write the request has already dropped.
// Since the on-demand detection of docs/floppy.md the overlay floppy.v drops a
// parked request on the FDC software reset the BIOS issues on its error path,
// so fd_hold clears there too and the retry raises a fresh request. A read
// block that arrives after its request was abandoned that way is checked
// against floppy.v's current request word (S_FDD_RD_CHK): the same drive and
// LBA still pending (the retry of the same sector) takes it, anything else
// drops it and the live request is dispatched afresh - a stale block never
// lands in another sector's FIFO.
//
// Hard-disk geometry (replaces ARM 2.2's 128-entry size table): at mount the
// bridge reads block 0 of the image through the block interface (the same
// blk_rd/blk_ack/buffer path an IDE read uses, so it waits on the SD card
// like one) and parses the MBR partition table at 0x1BE. The first entry
// with a non-zero type byte gives heads = end_head + 1 and spt = end_sector
// & 0x3F. The result is used only if bytes 510/511 are 0x55 0xAA, 1 <= heads
// <= 16 and 1 <= spt <= 63; otherwise, and for an image shorter than one
// block, the ARM's fallback of 16 x 63 applies. cylinders = sectors /
// (heads * spt), truncated, capped at 65535 (the sequential divider). The
// detected pair is frozen into IDENTIFY words 1/3/4/6 and 54-56 and starts
// the CHS translation; INITIALIZE DEVICE PARAMETERS (91h) later replaces the
// translation pair only, like the ARM. Every mount strobe (unmount, remount)
// redoes the detection, and ide.v is told "present" (reg 6) only after it
// has finished, so a CHS command can never run on a half-configured drive.

module mgmt_bridge #(
    // Gap between the "media absent" write and the re-insert writes of a
    // floppy mount. ARM 4.4 sleeps 100 ms; only the 0 -> 1 ordering matters
    // (MGMT 3.6). 500_000 clocks = 10 ms at 50 MHz. Max 2^24-1.
    parameter int FDD_EJECT_CYCLES = 500_000
) (
    input  wire        clk,            // 50 MHz chipset clock, same as the core's mgmt bus
    input  wire        reset,          // active high, synchronous
    // mgmt bus to pcxt_core
    output reg  [15:0] mgmt_addr,
    output reg  [15:0] mgmt_dout,
    input  wire [15:0] mgmt_din,
    output reg         mgmt_wr,        // single-cycle pulse
    output reg         mgmt_rd,        // single-cycle pulse; mgmt_din sampled on the clock after it
    /* verilator lint_off UNUSEDSIGNAL */
    input  wire [7:0]  mgmt_req,       // level: [2:0] IDE (110 reset, 100 command, 101 data), [6] FDD read, [7] FDD write/format; [5:3] = 0 (no IDE1)
    /* verilator lint_on UNUSEDSIGNAL */
    // virtual drives (framework): 0 = floppy A, 1 = floppy B, 2 = hard disk (ATA unit 0)
    input  wire [2:0]  img_mounted,    // strobe of any width (M2M vdrives: tens of clocks); the rising edge counts, img_size / img_readonly valid then
    input  wire [31:0] img_size,       // bytes; 0 = unmount
    input  wire        img_readonly,
    input  wire [2:0]  drive_mounted,  // level
    // 512-byte block transfers to/from the framework
    output reg  [2:0]  blk_rd,         // level, cleared when blk_ack rises; one drive at a time
    output reg  [2:0]  blk_wr,
    output reg  [31:0] blk_lba,        // block number
    input  wire [2:0]  blk_ack,        // level: high while the block moves; complete when it falls
    input  wire        blk_err,        // level, sampled when a floppy block's ack falls: read: the block carries no data; write: the write failed, park the drive (see header)
    // the format tap (docs/floppy.md phase 4): floppy.v's management register 1, sampled when a floppy
    // request is dispatched and held until the next one: [15] this block is the fill of a FORMAT TRACK
    // sector, [14:8] the command's sector count, [7:0] its filler byte. The firmware reads it (rom_loader
    // register 14) while it serves the block; a level tap would be gone for the last sector of a track.
    output reg  [15:0] fd_fmt,
    // 512-byte sector buffer shared with the framework
    output reg  [8:0]  buf_addr,
    output reg  [7:0]  buf_wdata,
    output reg         buf_we,
    input  wire [7:0]  buf_rdata       // valid one clock after buf_addr
);

    // ------------------------------------------------------------------ constants
    localparam [15:0] IDE_BASE = 16'hF000;   // MGMT 1.4: page F0, reg = addr[3:0]
    localparam [15:0] IDE_BUF  = 16'hF00F;   // MGMT 2.4: 16 KB word buffer (any addr[3:0]==F)
    localparam [15:0] FDD_BASE = 16'hF200;   // MGMT 1.4: page F2, drive = addr[7], reg = addr[3:0]
    localparam [15:0] FDD_BUF  = 16'hF2FF;   // MGMT 3.2: byte FIFO, shared by both drives

    // ARM 2.2 "16x63 rule": the geometry when the MBR yields nothing usable
    localparam [4:0]  HD_HEADS_FB = 5'd16;
    localparam [8:0]  HD_SPT_FB   = 9'd63;
    localparam [8:0]  MBR_PT_OFF  = 9'h1BE;      // partition table: 4 x 16 bytes, then 55 AA at 510/511

    // word-5 status bytes exactly as ARM 4.3 lists them (DSC already folded in)
    localparam [7:0] ST_BSY       = 8'h80;   // reset step 2
    localparam [7:0] ST_READY     = 8'h50;   // reset step 3 / after mount
    localparam [7:0] ST_OK        = 8'h54;   // no-data command done, write done
    localparam [7:0] ST_ABORT     = 8'h45;   // RDY|IRQ|ERR
    localparam [7:0] ST_DRQ_FIRST = 8'h58;   // first write block
    localparam [7:0] ST_DRQ       = 8'h5C;   // read block / later write blocks
    localparam [7:0] ST_DRQ_LAST  = 8'h5E;   // last read block / IDENTIFY (END -> last_read)
    localparam [7:0] ERR_NONE     = 8'h00;
    localparam [7:0] ERR_DIAG     = 8'h01;   // EXECUTE DIAGNOSTICS result
    localparam [7:0] ERR_ABRT     = 8'h04;

    // stream modes for the TX/RX helpers
    localparam [2:0] XM_IDE_SECT = 3'd0;   // 256 words from the sector buffer, {byte[2k+1], byte[2k]}
    localparam [2:0] XM_IDE_ID   = 3'd1;   // 256 IDENTIFY words
    localparam [2:0] XM_IDE_ZERO = 3'd2;   // 256 zero words (read beyond the image, ARM 2.5)
    localparam [2:0] XM_FDD_SECT = 3'd3;   // 512 bytes from the sector buffer, one per word
    localparam [2:0] XM_FDD_ZERO = 3'd4;   // 512 zero bytes (no media, ARM 3.3)

    // IDENTIFY strings, ATA byte order (first character in bits [15:8]).
    // ARM 2.4 puts the image file name in words 27-46; a fixed name here.
    localparam [319:0] ID_MODEL  = "MEGA65 PCXT HD                          "; // 40 chars
    localparam [159:0] ID_SERIAL = "AOHD00000           ";                     // 20 chars

    // ------------------------------------------------------------------ IDENTIFY (ARM 2.4)
    // Words 1/3/4/6 and 54-56 are the geometry detected at mount (MBR or the
    // 16 x 63 fallback, see the header); 91h changes the CHS translation but
    // not this table, like the ARM.
    // Deviations from ARM 2.4: word 47 = 0x8001 and word 59 = 0x0101 because
    // this bridge moves one sector per DRQ (READ/WRITE MULTIPLE block = 1).
    function automatic logic [15:0] id_word(input logic [7:0] w, input logic [15:0] cyl,
                                            input logic [4:0] heads, input logic [8:0] spt,
                                            input logic [22:0] total);
        logic [15:0] r;
        r = 16'h0000;
        if (w >= 8'd10 && w <= 8'd19)
            r = ID_SERIAL[(159 - 16 * (w - 8'd10)) -: 16];
        else if (w >= 8'd27 && w <= 8'd46)
            r = ID_MODEL[(319 - 16 * (w - 8'd27)) -: 16];
        else begin
            case (w)
                8'd0:   r = 16'h0040;
                8'd1:   r = cyl;
                8'd3:   r = {11'd0, heads};
                8'd4:   r = {spt[6:0], 9'd0};         // (512*spt) & 0xFFFF
                8'd5:   r = 16'd512;
                8'd6:   r = {7'd0, spt};
                8'd20:  r = 16'd3;
                8'd21:  r = 16'd512;
                8'd22:  r = 16'd4;
                8'd47:  r = 16'h8001;                 // max 1 sector per READ/WRITE MULTIPLE
                8'd48:  r = 16'd1;
                8'd49:  r = 16'h0200;                 // LBA supported
                8'd50:  r = 16'h4001;
                8'd51:  r = 16'h0200;
                8'd52:  r = 16'h0200;
                8'd53:  r = 16'h0007;
                8'd54:  r = cyl;
                8'd55:  r = {11'd0, heads};
                8'd56:  r = {7'd0, spt};
                8'd57:  r = total[15:0];
                8'd58:  r = {9'd0, total[22:16]};
                8'd59:  r = 16'h0101;                 // multiple valid, 1 sector current
                8'd60:  r = total[15:0];
                8'd61:  r = {9'd0, total[22:16]};
                8'd65, 8'd66, 8'd67, 8'd68: r = 16'd120;
                8'd80:  r = 16'h007E;
                8'd82:  r = 16'h4200;
                8'd83:  r = 16'h7000;
                8'd84:  r = 16'h4000;
                8'd85:  r = 16'h4200;
                8'd86:  r = 16'h7000;
                8'd87:  r = 16'h4000;
                8'd93:  r = 16'h630B;
                8'd100: r = total[15:0];
                8'd101: r = {9'd0, total[22:16]};
                default: r = 16'h0000;
            endcase
        end
        return r;
    endfunction

    // ------------------------------------------------------------------ floppy type table (ARM 3.1)
    // {present, cylinders[7:0], heads[1:0], spt[7:0], total_sectors[15:0]}
    // from the image size in 512-byte blocks; first matching row wins.
    // 0 blocks = no image, >= 8000 = rejected: both program the 1.44M
    // geometry with present = 0 like the ARM's "no file" row.
    function automatic logic [34:0] fdd_geo(input logic [22:0] blocks);
        if (blocks == 23'd0)        return {1'b0, 8'd80, 2'd2, 8'd18, 16'd2880};
        else if (blocks >= 23'd8000) return {1'b0, 8'd80, 2'd2, 8'd18, 16'd2880};
        else if (blocks >= 23'd5760) return {1'b1, 8'd80, 2'd2, 8'd36, 16'd5760};
        else if (blocks >= 23'd3360) return {1'b1, 8'd80, 2'd2, 8'd21, 16'd3360};
        else if (blocks >= 23'd2880) return {1'b1, 8'd80, 2'd2, 8'd18, 16'd2880};
        else if (blocks >= 23'd2400) return {1'b1, 8'd80, 2'd2, 8'd15, 16'd2400};
        else if (blocks >= 23'd1440) return {1'b1, 8'd80, 2'd2, 8'd9,  16'd1440};
        else if (blocks >= 23'd720)  return {1'b1, 8'd40, 2'd2, 8'd9,  16'd720};
        else if (blocks >= 23'd640)  return {1'b1, 8'd40, 2'd2, 8'd8,  16'd640};
        else if (blocks >= 23'd360)  return {1'b1, 8'd40, 2'd1, 8'd9,  16'd360};
        else                         return {1'b1, 8'd40, 2'd1, 8'd8,  16'd320};
    endfunction

    // ------------------------------------------------------------------ states
    typedef enum logic [6:0] {
        S_IDLE,
        // bus-cycle helper (MGMT 5.1 rules 2/3)
        S_BUS_WR, S_BUS_WGAP,
        S_BUS_RD1, S_BUS_RD2, S_BUS_RD3, S_BUS_RD4,
        // register block helpers: 6 words at wregs_base+0..5 / IDE regs 0..5
        S_WREGS, S_WREGS_NEXT, S_RREGS, S_RREGS_NEXT,
        // buffer -> mgmt stream and mgmt -> buffer stream
        S_TX_A, S_TX_B, S_TX_C, S_TX_D, S_TX_NEXT,
        S_RX_RD, S_RX_W0, S_RX_W1, S_RX_NEXT,
        // framework block transfer, sequential divider
        S_BLK_ACK_HI, S_BLK_ACK_LO,
        S_DIV_RUN, S_DIV_DONE,
        // IDE (MGMT 5.2, ARM 4.1-4.3)
        S_IDE_MOUNT, S_IDE_MBR_A, S_IDE_MBR_B, S_IDE_MBR_C, S_IDE_MOUNT_GEO, S_IDE_CYL_DIV,
        S_IDE_MOUNT_W6A, S_IDE_MOUNT_W6B, S_IDE_MOUNT_REGS,
        S_IDE_RST_W1, S_IDE_RST_W2,
        S_IDE_DECODE, S_IDE_DISPATCH,
        S_IDE_ID_REGS,
        S_IDE_LBA1, S_IDE_LBA2,
        S_IDE_RD_FETCH, S_IDE_RD_TX, S_IDE_RD_REGS,
        S_IDE_WR_REGS, S_IDE_WR_RX, S_IDE_WR_STORE, S_IDE_WR_NEXT,
        S_IDE_STEP,
        S_IDE_91_DONE,
        S_IDE_OK_REGS, S_IDE_ABORT_REGS,
        // floppy (MGMT 5.3, ARM 4.4-4.6)
        S_FDD_EJECT, S_FDD_INSERT,
        S_FDD_REQ, S_FDD_DISPATCH, S_FDD_TAP, S_FDD_DISPATCH2, S_FDD_RD_CHK, S_FDD_RD_CHK2, S_FDD_RD_TX, S_FDD_WR_STORE, S_FDD_WAIT, S_FDD_ERR
    } state_t;

    state_t state, bus_ret, seq_ret;

    // ------------------------------------------------------------------ registers
    // bus helper
    logic [15:0] bus_rdata;
    // register block helpers
    logic [15:0] wregs [0:5];
    logic [15:0] rregs [0:5];
    logic [15:0] wregs_base;
    logic [2:0]  ridx;
    // streams
    logic [2:0]  xmode;
    logic [9:0]  xcnt;
    logic [7:0]  xlo;
    // block transfer
    logic [1:0]  blk_drv;
    // divider: div_q = div_n / div_d, 24 by 13 bits, restoring (remainder < 2^13)
    logic [23:0] div_n, div_q, div_rem;
    logic [12:0] div_d;
    logic [4:0]  div_i;
    logic [15:0] div_res;

    // hard disk (unit 0 of the ARM-served IDE; unit 1 is never present)
    logic        hd_mount_pend, hd_ro_lat, hd_present, hd_ro;
    logic [31:0] hd_size_lat;
    logic [22:0] hd_total;           // sectors = size / 512
    logic [4:0]  hd_heads;           // current translation (91h changes it)
    logic [8:0]  hd_spt;
    /* verilator lint_off UNUSEDSIGNAL */
    logic [15:0] hd_cyl;             // current translation (ARM keeps it too; nothing reads it back, kept for observability)
    /* verilator lint_on UNUSEDSIGNAL */
    logic [15:0] hd_cyl_id;          // frozen at mount for IDENTIFY
    logic [4:0]  hd_heads_id;
    logic [8:0]  hd_spt_id;
    // MBR scan at mount: byte MBR_PT_OFF + mbr_n, n = 0..65
    logic [6:0]  mbr_n;
    logic        mbr_take;           // inside the first entry with a non-zero type
    logic        mbr_found;          // that entry's end head / sector are latched
    logic        mbr_sig55, mbr_sig_ok;
    logic [7:0]  mbr_head;           // end head (heads - 1)
    logic [5:0]  mbr_sec;            // end sector (spt)
    // command snapshot (ARM 4.3: R 0xF000 -> 6 words)
    logic [7:0]  ide_cmd, ide_drv, ide_count, ide_sector, ide_err;
    logic [15:0] ide_cyl;
    logic        ide_rd_act, ide_wr_act, ide_first;
    logic [8:0]  ide_rem;            // sectors still to move (count 0 = 256)
    // next sector to transfer (cur) and last transferred / reported (rep)
    logic [31:0] cur_lba;
    logic [27:0] rep_lba;
    logic [15:0] cur_c, rep_c;
    logic [3:0]  cur_h, rep_h;
    logic [7:0]  cur_s, rep_s;
    logic [31:0] mul_t;

    // floppies
    logic [1:0]  fd_pend, fd_wait, fd_mounted, fd_ro;
    logic        fd_ro_lat0, fd_ro_lat1;
    logic [22:0] fd_size0, fd_size1;  // blocks, latched at the strobe
    logic [15:0] fd_total [0:1];
    logic [23:0] fd_timer0, fd_timer1;
    logic        fd_idx;              // drive being (un)mounted
    logic        fd_is_wr, fd_drv;
    logic [14:0] fd_lba;
    logic        fd_hold;             // a floppy read failed: ignore its request until it drops
    logic        fd_dead;             // a floppy write failed: ignore every floppy request until the reset
    logic        fd_blk_wr;           // the block transfer in flight is a floppy write
    // mount strobes: the framework holds img_mounted for as long as the QNICE
    // firmware takes between its set and clear register writes, so only the
    // rising edge is a mount; a level would otherwise re-arm the mount on
    // every clock (a second eject/insert per mount, or with a stuck strobe an
    // endless eject/insert loop that leaves media_present at 0 almost always)
    logic [2:0]  img_mounted_q;

    // ------------------------------------------------------------------ combinational
    wire  [2:0] img_mount_edge = img_mounted & ~img_mounted_q;
    wire        ide_lba   = ide_drv[6];
    wire [7:0]  rp_sector = ide_lba ? rep_lba[7:0]   : rep_s;
    wire [15:0] rp_cyl    = ide_lba ? rep_lba[23:8]  : rep_c;
    wire [3:0]  rp_head   = ide_lba ? rep_lba[27:24] : rep_h;
    wire [7:0]  dh_rep    = {1'b1, ide_lba, 1'b1, ide_drv[4], rp_head};   // ARM 4: DH'
    wire [7:0]  dh_cmd    = ide_drv | 8'hA0;                             // ARM 4: DH
    wire        hd_in_range = hd_present && drive_mounted[2] && (cur_lba < {9'd0, hd_total});
    wire        mbr_geo_ok  = mbr_sig_ok && mbr_found && (mbr_head <= 8'd15) && (mbr_sec != 6'd0);   // 1..16 heads, 1..63 spt
    wire [31:0] cur_lba_chs = mul_t * {23'd0, hd_spt} + {24'd0, cur_s} - 32'd1;   // ARM 2.5 get_lba, CHS form

    wire        xfdd  = (xmode == XM_FDD_SECT) || (xmode == XM_FDD_ZERO);
    wire [9:0]  xlast = xfdd ? 10'd511 : 10'd255;
    wire [15:0] xbuf_addr = xfdd ? FDD_BUF : IDE_BUF;

    wire [23:0] div_t  = (div_rem << 1) | {23'd0, div_n[23]};   // remainder < 2^13, the shifted-out bit is always 0
    wire        div_ge = (div_t >= {11'd0, div_d});

    wire [34:0] fd_geo   = fdd_geo(fd_idx ? fd_size1 : fd_size0);
    wire        fd_ok    = fd_mounted[fd_drv] && drive_mounted[{1'b0, fd_drv}] && ({1'b0, fd_lba} < fd_total[fd_drv]);
    wire [15:0] fd_base  = FDD_BASE | {8'd0, fd_idx, 7'd0};

    // ------------------------------------------------------------------ main machine
    always_ff @(posedge clk) begin
        if (reset) begin
            state     <= S_IDLE;
            bus_ret   <= S_IDLE;
            seq_ret   <= S_IDLE;
            mgmt_addr <= 16'h0000;
            mgmt_dout <= 16'h0000;
            mgmt_wr   <= 1'b0;
            mgmt_rd   <= 1'b0;
            blk_rd    <= 3'b000;
            blk_wr    <= 3'b000;
            blk_lba   <= 32'd0;
            buf_addr  <= 9'd0;
            buf_wdata <= 8'd0;
            buf_we    <= 1'b0;
            bus_rdata <= 16'h0000;
            wregs_base <= IDE_BASE;
            ridx      <= 3'd0;
            xmode     <= XM_IDE_SECT;
            xcnt      <= 10'd0;
            xlo       <= 8'd0;
            blk_drv   <= 2'd0;
            div_n     <= 24'd0;
            div_q     <= 24'd0;
            div_rem   <= 24'd0;
            div_d     <= 13'd1;
            div_i     <= 5'd0;
            div_res   <= 16'd0;
            hd_mount_pend <= 1'b0;
            hd_ro_lat <= 1'b0;
            hd_size_lat <= 32'd0;
            hd_present <= 1'b0;
            hd_ro     <= 1'b0;
            hd_total  <= 23'd0;
            hd_heads  <= HD_HEADS_FB;
            hd_spt    <= HD_SPT_FB;
            hd_cyl    <= 16'd0;
            hd_cyl_id <= 16'd0;
            hd_heads_id <= HD_HEADS_FB;
            hd_spt_id <= HD_SPT_FB;
            mbr_n     <= 7'd0;
            mbr_take  <= 1'b0;
            mbr_found <= 1'b0;
            mbr_sig55 <= 1'b0;
            mbr_sig_ok <= 1'b0;
            mbr_head  <= 8'd0;
            mbr_sec   <= 6'd0;
            ide_cmd   <= 8'd0;
            ide_drv   <= 8'd0;
            ide_count <= 8'd0;
            ide_sector <= 8'd0;
            ide_err   <= 8'd0;
            ide_cyl   <= 16'd0;
            ide_rd_act <= 1'b0;
            ide_wr_act <= 1'b0;
            ide_first <= 1'b0;
            ide_rem   <= 9'd0;
            cur_lba   <= 32'd0;
            rep_lba   <= 28'd0;
            cur_c     <= 16'd0;
            rep_c     <= 16'd0;
            cur_h     <= 4'd0;
            rep_h     <= 4'd0;
            cur_s     <= 8'd0;
            rep_s     <= 8'd0;
            mul_t     <= 32'd0;
            fd_pend   <= 2'b00;
            fd_wait   <= 2'b00;
            fd_mounted <= 2'b00;
            fd_ro     <= 2'b00;
            fd_ro_lat0 <= 1'b0;
            fd_ro_lat1 <= 1'b0;
            fd_size0  <= 23'd0;
            fd_size1  <= 23'd0;
            fd_total[0] <= 16'd0;
            fd_total[1] <= 16'd0;
            fd_timer0 <= 24'd0;
            fd_timer1 <= 24'd0;
            fd_idx    <= 1'b0;
            fd_is_wr  <= 1'b0;
            fd_drv    <= 1'b0;
            fd_lba    <= 15'd0;
            fd_hold   <= 1'b0;
            fd_dead   <= 1'b0;
            fd_blk_wr <= 1'b0;
            fd_fmt    <= 16'd0;
            img_mounted_q <= 3'b000;
        end else begin
            // defaults: strobes are one clock wide
            mgmt_wr <= 1'b0;
            mgmt_rd <= 1'b0;
            buf_we  <= 1'b0;
            img_mounted_q <= img_mounted;
            if (fd_timer0 != 24'd0) fd_timer0 <= fd_timer0 - 24'd1;
            if (fd_timer1 != 24'd0) fd_timer1 <= fd_timer1 - 24'd1;
            if (mgmt_req[7:6] == 2'b00) fd_hold <= 1'b0;

            case (state)
            // ---------------------------------------------------------- dispatcher
            S_IDLE: begin
                if (hd_mount_pend) begin
                    hd_mount_pend <= 1'b0;
                    state <= S_IDE_MOUNT;
                end else if (mgmt_req[2:0] == 3'b110) begin      // ARM 4.2 reset
                    seq_ret <= S_IDE_RST_W1;
                    state   <= S_RREGS;
                end else if (mgmt_req[2:0] == 3'b100) begin      // ARM 4.3 new command
                    seq_ret <= S_IDE_DECODE;
                    state   <= S_RREGS;
                end else if (mgmt_req[2:0] == 3'b101) begin      // data phase done
                    if (ide_rd_act) begin
                        // the reg-5 write that ended the previous block already
                        // rewound mgmt_cnt (MGMT 2.4); CPU data reads do not touch it
                        state <= S_IDE_RD_FETCH;
                    end else if (ide_wr_act) begin
                        // MGMT 5.2 step 5: R(5) to rewind, then drain the buffer
                        mgmt_addr <= IDE_BASE | 16'h0005;
                        bus_ret   <= S_IDE_WR_RX;
                        state     <= S_BUS_RD1;
                    end else begin
                        state <= S_IDE_ABORT_REGS;               // ARM 2.3 stray 101
                    end
                end else if (fd_pend[0] && !fd_wait[0]) begin
                    fd_idx <= 1'b0;
                    state  <= S_FDD_EJECT;
                end else if (fd_pend[1] && !fd_wait[1]) begin
                    fd_idx <= 1'b1;
                    state  <= S_FDD_EJECT;
                end else if (fd_wait[0] && fd_timer0 == 24'd0) begin
                    fd_idx <= 1'b0;
                    state  <= S_FDD_INSERT;
                end else if (fd_wait[1] && fd_timer1 == 24'd0) begin
                    fd_idx <= 1'b1;
                    state  <= S_FDD_INSERT;
                end else if (mgmt_req[7:6] != 2'b00 && !fd_hold && !fd_dead) begin
                    state <= S_FDD_REQ;
                end
            end

            // ---------------------------------------------------------- bus cycle helper
            // Write: caller sets mgmt_addr / mgmt_dout / bus_ret, enters S_BUS_WR.
            S_BUS_WR: begin
                mgmt_wr <= 1'b1;
                state   <= S_BUS_WGAP;
            end
            S_BUS_WGAP: state <= bus_ret;          // mgmt_wr back low this clock
            // Read: caller sets mgmt_addr / bus_ret, enters S_BUS_RD1; result in bus_rdata.
            S_BUS_RD1: state <= S_BUS_RD2;         // address settles, ide.v registers readdata
            S_BUS_RD2: state <= S_BUS_RD3;
            S_BUS_RD3: begin
                mgmt_rd <= 1'b1;
                state   <= S_BUS_RD4;
            end
            S_BUS_RD4: begin
                bus_rdata <= mgmt_din;             // clock after the pulse: pre-pop / pre-increment value
                state     <= bus_ret;
            end

            // ---------------------------------------------------------- register blocks
            // ridx is 0 whenever these helpers are not running.
            S_WREGS: begin
                mgmt_addr <= wregs_base + {13'd0, ridx};
                mgmt_dout <= wregs[ridx];
                bus_ret   <= S_WREGS_NEXT;
                state     <= S_BUS_WR;
            end
            S_WREGS_NEXT: begin
                if (ridx == 3'd5) begin
                    ridx  <= 3'd0;
                    state <= seq_ret;
                end else begin
                    ridx  <= ridx + 3'd1;
                    state <= S_WREGS;
                end
            end
            S_RREGS: begin
                mgmt_addr <= IDE_BASE + {13'd0, ridx};
                bus_ret   <= S_RREGS_NEXT;
                state     <= S_BUS_RD1;
            end
            S_RREGS_NEXT: begin
                rregs[ridx] <= bus_rdata;
                if (ridx == 3'd5) begin
                    ridx  <= 3'd0;
                    state <= seq_ret;
                end else begin
                    ridx  <= ridx + 3'd1;
                    state <= S_RREGS;
                end
            end

            // ---------------------------------------------------------- TX: buffer -> mgmt
            // IDE: word k = {byte[2k+1], byte[2k]} (ARM 1.2, little-endian, like ide.cpp).
            // FDD: one byte per word in [7:0] (ARM 3.3).
            S_TX_A: begin
                buf_addr <= xfdd ? xcnt[8:0] : {xcnt[7:0], 1'b0};
                state    <= S_TX_B;
            end
            S_TX_B: begin
                buf_addr <= xfdd ? xcnt[8:0] : {xcnt[7:0], 1'b1};
                state    <= S_TX_C;
            end
            S_TX_C: begin
                xlo   <= buf_rdata;                // byte 2k (IDE) / byte k (FDD)
                state <= S_TX_D;
            end
            S_TX_D: begin
                mgmt_addr <= xbuf_addr;
                case (xmode)
                    XM_IDE_SECT: mgmt_dout <= {buf_rdata, xlo};
                    XM_IDE_ID:   mgmt_dout <= id_word(xcnt[7:0], hd_cyl_id, hd_heads_id, hd_spt_id, hd_total);
                    XM_FDD_SECT: mgmt_dout <= {8'h00, xlo};
                    default:     mgmt_dout <= 16'h0000;
                endcase
                bus_ret <= S_TX_NEXT;
                state   <= S_BUS_WR;
            end
            S_TX_NEXT: begin
                if (xcnt == xlast) state <= seq_ret;
                else begin
                    xcnt  <= xcnt + 10'd1;
                    state <= S_TX_A;
                end
            end

            // ---------------------------------------------------------- RX: mgmt -> buffer
            S_RX_RD: begin
                mgmt_addr <= xbuf_addr;
                bus_ret   <= S_RX_W0;
                state     <= S_BUS_RD1;
            end
            S_RX_W0: begin
                buf_we    <= 1'b1;
                buf_addr  <= xfdd ? xcnt[8:0] : {xcnt[7:0], 1'b0};
                buf_wdata <= bus_rdata[7:0];
                state     <= xfdd ? S_RX_NEXT : S_RX_W1;
            end
            S_RX_W1: begin
                buf_we    <= 1'b1;
                buf_addr  <= {xcnt[7:0], 1'b1};
                buf_wdata <= bus_rdata[15:8];
                state     <= S_RX_NEXT;
            end
            S_RX_NEXT: begin
                if (xcnt == xlast) state <= seq_ret;
                else begin
                    xcnt  <= xcnt + 10'd1;
                    state <= S_RX_RD;
                end
            end

            // ---------------------------------------------------------- block transfer
            // caller sets blk_lba, blk_drv and one bit of blk_rd / blk_wr
            S_BLK_ACK_HI: begin
                if (blk_ack[blk_drv]) begin
                    blk_rd <= 3'b000;
                    blk_wr <= 3'b000;
                    state  <= S_BLK_ACK_LO;
                end
            end
            S_BLK_ACK_LO: begin
                if (!blk_ack[blk_drv]) begin
                    // a floppy read the firmware could not serve: no data for floppy.v (header);
                    // a floppy write it could not do: the drive is dead until the reset
                    // a served read: first make sure the request is still the one it was fetched for
                    if (seq_ret == S_FDD_RD_TX) state <= blk_err ? S_FDD_ERR : S_FDD_RD_CHK;
                    else                        state <= seq_ret;
                    if (blk_err && fd_blk_wr) fd_dead <= 1'b1;
                    fd_blk_wr <= 1'b0;
                end
            end

            // ---------------------------------------------------------- divider
            // caller loads div_n / div_d, clears div_rem / div_q, sets div_i = 23
            S_DIV_RUN: begin
                div_rem <= div_ge ? (div_t - {11'd0, div_d}) : div_t;
                div_q   <= {div_q[22:0], div_ge};
                div_n   <= {div_n[22:0], 1'b0};
                div_i   <= div_i - 5'd1;
                if (div_i == 5'd0) state <= S_DIV_DONE;
            end
            S_DIV_DONE: begin
                div_res <= (div_q > 24'd65535) ? 16'hFFFF : div_q[15:0];   // ARM 2.2 cap
                state   <= seq_ret;
            end

            // ---------------------------------------------------------- IDE: mount (ARM 4.1)
            // Geometry first (header): fetch block 0, scan the partition
            // table, pick heads/spt, divide for the cylinders; only then the
            // reg-6 writes that make ide.v report the drive present.
            S_IDE_MOUNT: begin
                hd_present <= (hd_size_lat != 32'd0);
                hd_ro      <= hd_ro_lat;
                hd_total   <= hd_size_lat[31:9];
                ide_rd_act <= 1'b0;
                ide_wr_act <= 1'b0;
                mbr_n      <= 7'd0;
                mbr_take   <= 1'b0;
                mbr_found  <= 1'b0;
                mbr_sig55  <= 1'b0;
                mbr_sig_ok <= 1'b0;
                if (hd_size_lat[31:9] != 23'd0) begin
                    blk_lba <= 32'd0;
                    blk_drv <= 2'd2;
                    blk_rd  <= 3'b100;
                    seq_ret <= S_IDE_MBR_A;
                    state   <= S_BLK_ACK_HI;
                end else begin
                    state   <= S_IDE_MOUNT_GEO;    // unmount / image shorter than a block
                end
            end
            // block 0 is in the buffer: walk bytes 0x1BE..0x1FF, one per three clocks
            S_IDE_MBR_A: begin
                buf_addr <= MBR_PT_OFF + {2'd0, mbr_n};
                state    <= S_IDE_MBR_B;
            end
            S_IDE_MBR_B: state <= S_IDE_MBR_C;     // buf_rdata valid next clock
            S_IDE_MBR_C: begin
                if (!mbr_n[6]) begin               // partition entries: n[5:4] = entry, n[3:0] = byte
                    case (mbr_n[3:0])
                        4'd4: if (buf_rdata != 8'h00 && !mbr_found) mbr_take <= 1'b1;   // type
                        4'd5: if (mbr_take) mbr_head <= buf_rdata;                       // end head
                        4'd6: if (mbr_take) begin                                        // end sector (low 6 bits; cyl high bits above)
                            mbr_sec   <= buf_rdata[5:0];
                            mbr_found <= 1'b1;
                            mbr_take  <= 1'b0;
                        end
                        default: ;
                    endcase
                end else if (mbr_n == 7'd64) begin
                    mbr_sig55 <= (buf_rdata == 8'h55);
                end else begin                     // n = 65: byte 511
                    mbr_sig_ok <= mbr_sig55 && (buf_rdata == 8'hAA);
                end
                if (mbr_n == 7'd65) state <= S_IDE_MOUNT_GEO;
                else begin
                    mbr_n <= mbr_n + 7'd1;
                    state <= S_IDE_MBR_A;
                end
            end
            S_IDE_MOUNT_GEO: begin
                hd_heads    <= mbr_geo_ok ? ({1'b0, mbr_head[3:0]} + 5'd1) : HD_HEADS_FB;
                hd_spt      <= mbr_geo_ok ? {3'd0, mbr_sec} : HD_SPT_FB;
                hd_heads_id <= mbr_geo_ok ? ({1'b0, mbr_head[3:0]} + 5'd1) : HD_HEADS_FB;
                hd_spt_id   <= mbr_geo_ok ? {3'd0, mbr_sec} : HD_SPT_FB;
                seq_ret     <= S_IDE_MOUNT_W6A;
                state       <= S_IDE_CYL_DIV;
            end
            // cylinders = total / (heads * spt), capped (ARM 2.2 ide_set_geometry);
            // shared by the mount and 91h, the caller sets seq_ret. div_d is 13
            // bits: at most 16 x 63 from the MBR, 16 x 256 from 91h.
            S_IDE_CYL_DIV: begin
                div_d   <= hd_heads * hd_spt;
                div_n   <= {1'b0, hd_total};
                div_rem <= 24'd0;
                div_q   <= 24'd0;
                div_i   <= 5'd23;
                state   <= S_DIV_RUN;
            end
            S_IDE_MOUNT_W6A: begin                 // step 1: latch present, hob_ena = 0
                hd_cyl    <= div_res;
                hd_cyl_id <= div_res;
                mgmt_addr <= IDE_BASE | 16'h0006;
                mgmt_dout <= hd_present ? 16'h0009 : 16'h0008;
                bus_ret   <= S_IDE_MOUNT_W6B;
                state     <= S_BUS_WR;
            end
            S_IDE_MOUNT_W6B: begin                 // step 2: use_wait = 0
                mgmt_addr <= IDE_BASE | 16'h0006;
                mgmt_dout <= 16'h0200;
                bus_ret   <= S_IDE_MOUNT_REGS;
                state     <= S_BUS_WR;
            end
            S_IDE_MOUNT_REGS: begin                // step 4: the ARM's next poll with req 000
                if (hd_present && mgmt_req[2:0] == 3'b000) begin
                    wregs[0] <= 16'h0000;
                    wregs[1] <= 16'h0000;
                    wregs[2] <= 16'h0000;
                    wregs[3] <= 16'h0000;
                    wregs[4] <= 16'h0000;
                    wregs[5] <= {ST_READY, 8'hA0};
                    wregs_base <= IDE_BASE;
                    seq_ret <= S_IDLE;
                    state   <= S_WREGS;
                end else begin
                    state <= S_IDLE;
                end
            end

            // ---------------------------------------------------------- IDE: reset (ARM 4.2)
            // regs were read into rregs; only rregs[5][4] (drv) is used
            S_IDE_RST_W1: begin
                ide_drv    <= rregs[5][7:0];
                ide_rd_act <= 1'b0;
                ide_wr_act <= 1'b0;
                wregs[0] <= {ERR_NONE, 8'h00};
                wregs[1] <= 16'h0101;                                   // sector = 1, count = 1
                wregs[2] <= hd_present ? 16'h0000 : 16'hFFFF;
                wregs[3] <= 16'h0000;
                wregs[4] <= 16'h0000;
                wregs[5] <= {ST_BSY, 4'hA, rregs[5][4], 3'b000};
                wregs_base <= IDE_BASE;
                seq_ret <= S_IDE_RST_W2;
                state   <= S_WREGS;
            end
            S_IDE_RST_W2: begin                    // step 3, same block with status 0x50
                wregs[5] <= {ST_READY, 4'hA, ide_drv[4], 3'b000};
                seq_ret  <= S_IDLE;
                state    <= S_WREGS;
            end

            // ---------------------------------------------------------- IDE: new command (ARM 4.3)
            S_IDE_DECODE: begin
                ide_err    <= ERR_NONE;
                ide_count  <= rregs[1][7:0];
                ide_sector <= rregs[1][15:8];
                ide_cyl    <= rregs[2];
                ide_drv    <= rregs[5][7:0];
                ide_cmd    <= rregs[5][15:8];
                state      <= S_IDE_DISPATCH;
            end
            S_IDE_DISPATCH: begin
                ide_rd_act <= 1'b0;
                ide_wr_act <= 1'b0;
                // common set-up for data commands: next = command address
                ide_rem <= (ide_count == 8'd0) ? 9'd256 : {1'b0, ide_count};
                cur_c   <= ide_cyl;    rep_c   <= ide_cyl;
                cur_h   <= ide_drv[3:0]; rep_h <= ide_drv[3:0];
                cur_s   <= ide_sector; rep_s   <= ide_sector;
                cur_lba <= {4'd0, ide_drv[3:0], ide_cyl, ide_sector};
                rep_lba <= {ide_drv[3:0], ide_cyl, ide_sector};
                xcnt    <= 10'd0;
                if (ide_drv[4]) begin
                    state <= S_IDE_ABORT_REGS;             // unit 1 is never present (ARM 2.6)
                end else if ((ide_cmd & 8'hF0) == 8'h10) begin
                    ide_cyl <= 16'h0000;                   // RECALIBRATE: cylinder = 0
                    state   <= S_IDE_OK_REGS;
                end else begin
                    case (ide_cmd)
                        8'hEC: begin                       // IDENTIFY DEVICE: data first, then regs
                            xmode   <= XM_IDE_ID;
                            seq_ret <= S_IDE_ID_REGS;
                            state   <= S_TX_A;
                        end
                        8'h20, 8'h21, 8'hC4: begin         // READ SECTORS / READ MULTIPLE (1 sector per DRQ)
                            ide_rd_act <= 1'b1;
                            state <= ide_lba ? S_IDE_RD_FETCH : S_IDE_LBA1;
                        end
                        8'h30, 8'h31, 8'hC5: begin         // WRITE SECTORS / WRITE MULTIPLE
                            ide_wr_act <= 1'b1;
                            ide_first  <= 1'b1;
                            state <= ide_lba ? S_IDE_WR_REGS : S_IDE_LBA1;
                        end
                        8'hC6: begin                       // SET MULTIPLE: only block size 1 (or 0) accepted
                            state <= (ide_count > 8'd1) ? S_IDE_ABORT_REGS : S_IDE_OK_REGS;
                        end
                        8'h40, 8'h41,                      // READ VERIFY (41 aborts on the ARM; accepted here)
                        8'h70,                             // SEEK
                        8'hE3: state <= S_IDE_OK_REGS;     // IDLE
                        8'h90: begin                       // EXECUTE DIAGNOSTICS
                            ide_err <= ERR_DIAG;
                            state   <= S_IDE_OK_REGS;
                        end
                        8'h91: begin                       // INITIALIZE DEVICE PARAMETERS
                            hd_heads <= {1'b0, ide_drv[3:0]} + 5'd1;
                            hd_spt   <= (ide_count == 8'd0) ? 9'd256 : {1'b0, ide_count};
                            seq_ret  <= S_IDE_91_DONE;
                            state    <= S_IDE_CYL_DIV;
                        end
                        default: state <= S_IDE_ABORT_REGS; // 08, E7, EF, FA, ATAPI, ...
                    endcase
                end
            end

            // IDENTIFY: 256 words are in the buffer, now the regs (ARM 4.3 step 2)
            S_IDE_ID_REGS: begin
                wregs[0] <= 16'h0001;
                wregs[1] <= 16'h0000;
                wregs[2] <= 16'h0000;
                wregs[3] <= 16'h0000;
                wregs[4] <= 16'h0000;
                wregs[5] <= {ST_DRQ_LAST, 4'hA, ide_drv[4], 3'b000};
                wregs_base <= IDE_BASE;
                seq_ret <= S_IDLE;
                state   <= S_WREGS;
            end

            // CHS -> LBA (ARM 2.5 get_lba): ((cyl*heads)+head)*spt + sector - 1
            S_IDE_LBA1: begin
                mul_t <= {16'd0, cur_c} * {27'd0, hd_heads} + {28'd0, cur_h};
                state <= S_IDE_LBA2;
            end
            S_IDE_LBA2: begin
                cur_lba <= cur_lba_chs;
                rep_lba <= cur_lba_chs[27:0];
                state   <= ide_wr_act ? S_IDE_WR_REGS : S_IDE_RD_FETCH;
            end

            // read: fetch one sector (zeros beyond the image), stream it, step, regs
            S_IDE_RD_FETCH: begin
                blk_lba <= cur_lba;
                blk_drv <= 2'd2;
                seq_ret <= S_IDE_RD_TX;
                if (hd_in_range) begin
                    xmode  <= XM_IDE_SECT;
                    blk_rd <= 3'b100;
                    state  <= S_BLK_ACK_HI;
                end else begin
                    xmode  <= XM_IDE_ZERO;
                    state  <= S_IDE_RD_TX;
                end
            end
            S_IDE_RD_TX: begin
                xcnt    <= 10'd0;
                seq_ret <= S_IDE_STEP;
                state   <= S_TX_A;
            end
            S_IDE_RD_REGS: begin                   // ARM 4.3 read step 4
                wregs[0] <= 16'h0001;
                wregs[1] <= {rp_sector, ide_rem[7:0]};
                wregs[2] <= rp_cyl;
                wregs[3] <= 16'h0000;
                wregs[4] <= 16'h0000;
                wregs[5] <= {(ide_rem == 9'd0) ? ST_DRQ_LAST : ST_DRQ, dh_rep};
                if (ide_rem == 9'd0) ide_rd_act <= 1'b0;
                wregs_base <= IDE_BASE;
                seq_ret <= S_IDLE;
                state   <= S_WREGS;
            end

            // write: announce DRQ, wait for 101 (S_IDLE), drain, store, step
            S_IDE_WR_REGS: begin                   // ARM 4.3 write step 2
                wregs[0] <= 16'h0001;
                wregs[1] <= {rp_sector, ide_rem[7:0]};
                wregs[2] <= rp_cyl;
                wregs[3] <= 16'h0000;
                wregs[4] <= 16'h0000;
                wregs[5] <= {ide_first ? ST_DRQ_FIRST : ST_DRQ, dh_rep};
                ide_first <= 1'b0;
                wregs_base <= IDE_BASE;
                seq_ret <= S_IDLE;
                state   <= S_WREGS;
            end
            S_IDE_WR_RX: begin                     // step 4: R 0xF00F x 256
                xmode   <= XM_IDE_SECT;
                xcnt    <= 10'd0;
                seq_ret <= S_IDE_WR_STORE;
                state   <= S_RX_RD;
            end
            S_IDE_WR_STORE: begin
                blk_lba <= cur_lba;
                blk_drv <= 2'd2;
                seq_ret <= S_IDE_STEP;
                if (hd_in_range && !hd_ro) begin
                    blk_wr <= 3'b100;
                    state  <= S_BLK_ACK_HI;
                end else begin
                    state  <= S_IDE_STEP;          // read-only or beyond the image: dropped
                end
            end
            S_IDE_WR_NEXT: begin                   // step 6
                if (ide_rem == 9'd0) begin
                    wregs[0] <= 16'h0001;
                    wregs[1] <= {rp_sector, 8'h00};
                    wregs[2] <= rp_cyl;
                    wregs[3] <= 16'h0000;
                    wregs[4] <= 16'h0000;
                    wregs[5] <= {ST_OK, dh_rep};
                    ide_wr_act <= 1'b0;
                    wregs_base <= IDE_BASE;
                    seq_ret <= S_IDLE;
                    state   <= S_WREGS;
                end else begin
                    state <= S_IDE_WR_REGS;
                end
            end

            // after one sector: rep = the sector just moved (put_lba(lba+1) - 1),
            // cur = next sector, in both LBA and CHS form
            S_IDE_STEP: begin
                rep_lba <= cur_lba[27:0];
                rep_c   <= cur_c;
                rep_h   <= cur_h;
                rep_s   <= cur_s;
                cur_lba <= cur_lba + 32'd1;
                if ({1'b0, cur_s} < hd_spt) begin
                    cur_s <= cur_s + 8'd1;
                end else begin
                    cur_s <= 8'd1;
                    if ({1'b0, cur_h} + 5'd1 < hd_heads) begin
                        cur_h <= cur_h + 4'd1;
                    end else begin
                        cur_h <= 4'd0;
                        cur_c <= cur_c + 16'd1;
                    end
                end
                ide_rem <= ide_rem - 9'd1;
                state   <= ide_wr_act ? S_IDE_WR_NEXT : S_IDE_RD_REGS;
            end

            // 91h: after S_IDE_CYL_DIV with the new translation pair
            S_IDE_91_DONE: begin
                hd_cyl <= div_res;
                state  <= S_IDE_OK_REGS;
            end

            // no-data OK (ARM 4.3): {err, 0}, {sector, count}, cyl, 0, 0, {0x54, DH}
            S_IDE_OK_REGS: begin
                wregs[0] <= {ide_err, 8'h00};
                wregs[1] <= {ide_sector, ide_count};
                wregs[2] <= ide_cyl;
                wregs[3] <= 16'h0000;
                wregs[4] <= 16'h0000;
                wregs[5] <= {ST_OK, dh_cmd};
                wregs_base <= IDE_BASE;
                seq_ret <= S_IDLE;
                state   <= S_WREGS;
            end
            // unsupported / not present / stray 101: {0x04, 0}, ..., {0x45, DH}
            S_IDE_ABORT_REGS: begin
                ide_rd_act <= 1'b0;
                ide_wr_act <= 1'b0;
                wregs[0] <= {ERR_ABRT, 8'h00};
                wregs[1] <= {ide_sector, ide_count};
                wregs[2] <= ide_cyl;
                wregs[3] <= 16'h0000;
                wregs[4] <= 16'h0000;
                wregs[5] <= {ST_ABORT, dh_cmd};
                wregs_base <= IDE_BASE;
                seq_ret <= S_IDLE;
                state   <= S_WREGS;
            end

            // ---------------------------------------------------------- floppy: mount (ARM 4.4)
            // W B+0 <- 0, then after FDD_EJECT_CYCLES (non-blocking, the timer
            // runs while S_IDLE serves other things) W B+0..5 <- present, wp,
            // cyl, spt, total, heads.
            S_FDD_EJECT: begin
                mgmt_addr <= fd_base;
                mgmt_dout <= 16'h0000;
                fd_pend[fd_idx] <= 1'b0;
                fd_wait[fd_idx] <= 1'b1;
                if (fd_idx) fd_timer1 <= FDD_EJECT_CYCLES[23:0];
                else        fd_timer0 <= FDD_EJECT_CYCLES[23:0];
                bus_ret <= S_IDLE;
                state   <= S_BUS_WR;
            end
            S_FDD_INSERT: begin
                wregs[0] <= {15'd0, fd_geo[34]};                                       // media present
                wregs[1] <= {15'd0, ~fd_geo[34] | (fd_idx ? fd_ro_lat1 : fd_ro_lat0)}; // write protect
                wregs[2] <= {8'd0, fd_geo[33:26]};                                      // cylinders
                wregs[3] <= {8'd0, fd_geo[23:16]};                                      // sectors per track
                wregs[4] <= fd_geo[15:0];                                               // total sectors
                wregs[5] <= {14'd0, fd_geo[25:24]};                                     // heads
                fd_mounted[fd_idx] <= fd_geo[34];
                fd_ro[fd_idx]      <= fd_idx ? fd_ro_lat1 : fd_ro_lat0;
                fd_total[fd_idx]   <= fd_geo[15:0];
                fd_wait[fd_idx]    <= 1'b0;
                wregs_base <= fd_base;
                seq_ret <= S_IDLE;
                state   <= S_WREGS;
            end

            // ---------------------------------------------------------- floppy: service (ARM 4.5 / 4.6)
            S_FDD_REQ: begin
                fd_is_wr  <= mgmt_req[7];
                mgmt_addr <= FDD_BASE;             // R 0xF200 -> {drive, lba[14:0]}
                bus_ret   <= S_FDD_DISPATCH;
                state     <= S_BUS_RD1;
            end
            S_FDD_DISPATCH: begin
                fd_drv    <= bus_rdata[15];
                fd_lba    <= bus_rdata[14:0];
                mgmt_addr <= FDD_BASE | 16'h0001; // R 0xF201 -> the format tap (header), a constant 1 in the upstream floppy.v
                bus_ret   <= S_FDD_TAP;
                state     <= S_BUS_RD1;
            end
            S_FDD_TAP: begin
                fd_fmt <= bus_rdata;
                state  <= S_FDD_DISPATCH2;
            end
            S_FDD_DISPATCH2: begin
                blk_lba <= {17'd0, fd_lba};
                blk_drv <= {1'b0, fd_drv};
                xcnt    <= 10'd0;
                if (!fd_is_wr) begin
                    if (fd_ok) begin
                        xmode   <= XM_FDD_SECT;
                        blk_rd  <= fd_drv ? 3'b010 : 3'b001;
                        seq_ret <= S_FDD_RD_TX;
                        state   <= S_BLK_ACK_HI;
                    end else begin
                        xmode   <= XM_FDD_ZERO;    // no image / out of range: 512 zero bytes
                        state   <= S_FDD_RD_TX;
                    end
                end else begin
                    xmode   <= XM_FDD_SECT;        // write or format: pop 512 bytes first
                    seq_ret <= S_FDD_WR_STORE;
                    state   <= S_RX_RD;
                end
            end
            S_FDD_RD_CHK: begin                    // the request may have been abandoned (FDC software reset,
                mgmt_addr <= FDD_BASE;             // header) while the firmware fetched the block: re-read it
                bus_ret   <= S_FDD_RD_CHK2;
                state     <= S_BUS_RD1;
            end
            S_FDD_RD_CHK2: begin
                if (mgmt_req[6] && bus_rdata[15] == fd_drv && bus_rdata[14:0] == fd_lba) state <= S_FDD_RD_TX;
                else state <= S_IDLE;              // gone or another sector: drop this block, dispatch the live request afresh
            end
            S_FDD_RD_TX: begin
                xcnt    <= 10'd0;
                seq_ret <= S_FDD_WAIT;
                state   <= S_TX_A;
            end
            S_FDD_WR_STORE: begin
                // mgmt_req[7] for THIS sector already fell while S_RX drained
                // floppy.v's 512-byte FIFO (that is what floppy.v waits on to
                // leave S_SD_WRITE_WAIT_FOR_EMPTY_FIFO), hundreds of clocks
                // before this block write even starts. For a multi-sector
                // WRITE DATA, floppy.v then DMA-refills its FIFO and re-raises
                // mgmt_req[7] for the NEXT sector - and because the framework's
                // SD-card block write is far slower than that refill, the next
                // request is already high again by the time this block write
                // finishes. So the write path must NOT return through
                // S_FDD_WAIT (which waits for mgmt_req to reach 0): it would
                // never see 0 and would park forever, dropping every sector
                // after the first (on hardware: 2 sectors written, then DOS
                // "drive not ready"). Return straight to S_IDLE instead, where
                // the next sector's request is dispatched cleanly. The just-
                // serviced request cannot be re-dispatched: floppy.v released
                // it long before this block write completed, and only ever
                // re-raises it after advancing sd_sector to the next LBA.
                if (fd_ok && !fd_ro[fd_drv]) begin
                    blk_wr    <= fd_drv ? 3'b010 : 3'b001;
                    fd_blk_wr <= 1'b1;
                    seq_ret   <= S_IDLE;
                    state     <= S_BLK_ACK_HI;
                end else begin
                    seq_ret <= S_FDD_WAIT;
                    state   <= S_FDD_WAIT;          // read-only / no media: nothing stored (no slow block follows)
                end
            end
            S_FDD_WAIT: begin                      // read path (and the discarded-write path): the request
                if (mgmt_req[7:6] == 2'b00) state <= S_IDLE;   // bit fell on the 512th transfer just performed (MGMT 5.3 step 6)
            end
            S_FDD_ERR: begin                       // park the request, keep serving everything else
                fd_hold <= 1'b1;
                state   <= S_IDLE;
            end

            default: state <= S_IDLE;
            endcase

            // Mount strobes (rising edge only), after the case so an edge landing
            // on the clock a pending flag is consumed still registers.
            if (img_mount_edge[2]) begin
                hd_mount_pend <= 1'b1;
                hd_size_lat   <= img_size;
                hd_ro_lat     <= img_readonly;
            end
            if (img_mount_edge[0]) begin
                fd_pend[0] <= 1'b1;
                fd_size0   <= img_size[31:9];
                fd_ro_lat0 <= img_readonly;
            end
            if (img_mount_edge[1]) begin
                fd_pend[1] <= 1'b1;
                fd_size1   <= img_size[31:9];
                fd_ro_lat1 <= img_readonly;
            end
        end
    end

endmodule
