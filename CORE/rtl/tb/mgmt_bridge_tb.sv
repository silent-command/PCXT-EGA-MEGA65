`timescale 1ns / 1ps
// mgmt_bridge_tb.sv - self-checking bench for CORE/rtl/mgmt_bridge.sv against
// the real rtl/common/ide.v and rtl/common/floppy.v (plus simple_fifo.v).
//
// The bench plays three roles:
//   * the chipset glue of Peripherals.sv:1527/1631/1738 (page decode F0/F2,
//     read mux, request packing into mgmt_req),
//   * the 8088 side: XT-IDE style register accesses on ide.v (io_address 0..7,
//     14; 16-bit data register) and 8272 command/DMA traffic on floppy.v,
//   * the MEGA65 framework: mount strobes, a 1 MB HDD image (mounted with
//     its real size, or with the FreeDOS test image's 87,227-sector size and
//     an MBR in block 0 for the geometry tests; blocks past 1 MB read as
//     zeros), a 360 KB floppy A image, the 512-byte shared buffer and
//     blk_rd/blk_wr/blk_ack with a random acknowledge latency.
//
// Prints RESULT: PASS or RESULT: FAIL.  Build/run: run_mgmt_bridge_tb.sh.

// bram.vhd's dpram as ide.v sees it: enable_*/cs_* default to '1' in the
// VHDL entity and are left unconnected by ide.v, so an undriven (z) input
// counts as asserted here.  Write-first on each port, q forced to all-ones
// while cs is low.
module dpram #(
    parameter addr_width    = 8,
    parameter data_width    = 8,
    parameter mem_init_file = " "
) (
    input  wire                  clock,
    input  wire [addr_width-1:0] address_a,
    input  wire [data_width-1:0] data_a,
    input  wire                  enable_a,
    input  wire                  wren_a,
    output wire [data_width-1:0] q_a,
    input  wire                  cs_a,
    input  wire [addr_width-1:0] address_b,
    input  wire [data_width-1:0] data_b,
    input  wire                  enable_b,
    input  wire                  wren_b,
    output wire [data_width-1:0] q_b,
    input  wire                  cs_b
);
    wire en_a = (enable_a !== 1'b0);
    wire en_b = (enable_b !== 1'b0);
    wire csa  = (cs_a !== 1'b0);
    wire csb  = (cs_b !== 1'b0);
    reg [data_width-1:0] mem [0:(1<<addr_width)-1];
    reg [data_width-1:0] q0 = 0, q1 = 0;
    always @(posedge clock) begin
        if (en_a) begin
            if (wren_a === 1'b1 && csa) begin mem[address_a] <= data_a; q0 <= data_a; end
            else q0 <= mem[address_a];
        end
        if (en_b) begin
            if (wren_b === 1'b1 && csb) begin mem[address_b] <= data_b; q1 <= data_b; end
            else q1 <= mem[address_b];
        end
    end
    assign q_a = csa ? q0 : {data_width{1'b1}};
    assign q_b = csb ? q1 : {data_width{1'b1}};
endmodule


module mgmt_bridge_tb;

    // ------------------------------------------------------------------ clock / reset
    reg clk = 1'b0;
    always #10 clk = ~clk;                       // 50 MHz
    reg reset = 1'b1;

    integer errors = 0;
    integer checks = 0;

    task check(input cond, input string msg);
    begin
        checks = checks + 1;
        if (!cond) begin
            errors = errors + 1;
            $display("FAIL @%0t: %s", $time, msg);
        end
    end
    endtask

    // ------------------------------------------------------------------ mgmt bus and consumers
    wire [15:0] mgmt_addr, mgmt_dout;
    wire        mgmt_wr, mgmt_rd;
    wire [15:0] mgmt_din;
    wire [7:0]  mgmt_req;

    wire        ide_cs = (mgmt_addr[15:8] == 8'hF0);   // Peripherals.sv:1527
    wire        fdd_cs = (mgmt_addr[15:8] == 8'hF2);   // Peripherals.sv:1631
    wire [15:0] ide_mgmt_rdata, fdd_mgmt_rdata;
    wire [2:0]  ide_req;
    wire [1:0]  fdd_req;
    assign mgmt_din = ide_cs ? ide_mgmt_rdata : fdd_mgmt_rdata;   // Peripherals.sv:1738
    assign mgmt_req = {fdd_req, 3'b000, ide_req};                 // PCXT-EGA.sv:1320-1321

    // ide.v CPU side
    reg  [3:0]  io_address = 4'd0;
    reg         io_read = 1'b0, io_write = 1'b0;
    reg  [31:0] io_writedata = 32'd0;
    wire [31:0] io_readdata;

    ide u_ide (
        .clk            (clk),
        .rst_n          (~reset),
        .irq            (),
        .drq            (),
        .use_fast       (1'b0),
        .no_data        (),
        .drive_en       (),
        .io_address     (io_address),
        .io_read        (io_read),
        .io_readdata    (io_readdata),
        .io_write       (io_write),
        .io_writedata   (io_writedata),
        .io_32          (1'b0),
        .io_wait        (),
        .request        (ide_req),
        .mgmt_address   (mgmt_addr[3:0]),
        .mgmt_write     (mgmt_wr & ide_cs),
        .mgmt_writedata (mgmt_dout),
        .mgmt_read      (mgmt_rd & ide_cs),
        .mgmt_readdata  (ide_mgmt_rdata),
        .primary_only   (1'b0),
        .secondary_only (1'b0),
        .ignore_access  ()
    );

    // floppy.v CPU / DMA side
    reg         fdd_dma_ack = 1'b0, fdd_dma_tc = 1'b0;
    reg  [7:0]  fdd_dma_rd = 8'd0;
    wire [7:0]  fdd_dma_wr;
    wire        fdd_dma_req, fdd_irq;
    reg  [2:0]  f_addr = 3'd0;
    reg         f_rd = 1'b0, f_wr = 1'b0;
    reg  [7:0]  f_wdata = 8'd0;
    wire [7:0]  f_rdata;

    floppy u_fdd (
        .clk            (clk),
        .rst_n          (~reset),
        .dma_req        (fdd_dma_req),
        .dma_ack        (fdd_dma_ack),
        .dma_tc         (fdd_dma_tc),
        .dma_readdata   (fdd_dma_rd),
        .dma_writedata  (fdd_dma_wr),
        .irq            (fdd_irq),
        .io_address     (f_addr),
        .io_read        (f_rd),
        .io_readdata    (f_rdata),
        .io_write       (f_wr),
        .io_writedata   (f_wdata),
        .fdd0_inserted  (),
        .mgmt_address   (mgmt_addr[3:0]),
        .mgmt_fddn      (mgmt_addr[7]),
        .mgmt_write     (mgmt_wr & fdd_cs),
        .mgmt_writedata (mgmt_dout),
        .mgmt_read      (mgmt_rd & fdd_cs),
        .mgmt_readdata  (fdd_mgmt_rdata),
        .wp             (2'b00),
        .clock_rate     (28'd50000000),
        .request        (fdd_req)
    );

    // ------------------------------------------------------------------ framework model
    reg  [2:0]  img_mounted = 3'b000;
    reg  [31:0] img_size = 32'd0;
    reg         img_readonly = 1'b0;
    reg  [2:0]  drive_mounted = 3'b000;
    wire [2:0]  blk_rd, blk_wr;
    wire [31:0] blk_lba;
    reg  [2:0]  blk_ack = 3'b000;
    wire [8:0]  buf_addr;
    wire [7:0]  buf_wdata;
    wire        buf_we;
    reg  [7:0]  buf_rdata = 8'd0;

    mgmt_bridge #(.FDD_EJECT_CYCLES(200)) u_dut (
        .clk           (clk),
        .reset         (reset),
        .mgmt_addr     (mgmt_addr),
        .mgmt_dout     (mgmt_dout),
        .mgmt_din      (mgmt_din),
        .mgmt_wr       (mgmt_wr),
        .mgmt_rd       (mgmt_rd),
        .mgmt_req      (mgmt_req),
        .img_mounted   (img_mounted),
        .img_size      (img_size),
        .img_readonly  (img_readonly),
        .drive_mounted (drive_mounted),
        .blk_rd        (blk_rd),
        .blk_wr        (blk_wr),
        .blk_lba       (blk_lba),
        .blk_ack       (blk_ack),
        .buf_addr      (buf_addr),
        .buf_wdata     (buf_wdata),
        .buf_we        (buf_we),
        .buf_rdata     (buf_rdata)
    );

    // shared 512-byte buffer, 1-clock read latency on the bridge port
    reg [7:0] sbuf [0:511];
    always @(posedge clk) begin
        if (buf_we) sbuf[buf_addr] <= buf_wdata;
        buf_rdata <= sbuf[buf_addr];
    end

    localparam integer HD_BYTES = 1048576;       // 2048 sectors
    localparam integer FA_BYTES = 368640;        // 720 sectors = 360 KB
    reg [7:0] hd_img [0:HD_BYTES-1];
    reg [7:0] fa_img [0:FA_BYTES-1];

    function [7:0] hdpat(input integer i);
        hdpat = ((i & 255) + 13 * (i >> 9)) & 255;
    endfunction
    function [7:0] fapat(input integer i);
        fapat = ((i * 3) + 7 * (i >> 9)) & 255;
    endfunction
    function [7:0] wpat(input integer i);
        wpat = ((i * 5 + 17) & 255) ^ 8'hA5;
    endfunction

    // block server: random latency, ack high for the 512-clock transfer
    integer     blk_count = 0;
    reg  [31:0] last_blk_lba = 32'hFFFFFFFF;
    integer     last_blk_drv = -1;
    reg         last_blk_wr = 1'b0;

    initial begin : blk_server
        integer d, i, lat;
        reg is_wr;
        reg [31:0] lba;
        forever begin
            @(posedge clk);
            if ((blk_rd | blk_wr) != 3'b000) begin
                d = (blk_rd[2] | blk_wr[2]) ? 2 : (blk_rd[1] | blk_wr[1]) ? 1 : 0;
                is_wr = blk_wr[d];
                lba = blk_lba;
                check((blk_rd | blk_wr) == (3'b001 << d), "only one block transfer in flight");
                check(!(blk_rd[d] & blk_wr[d]), "blk_rd and blk_wr not both set");
                lat = $urandom_range(1, 24);
                repeat (lat) @(posedge clk);
                check(blk_rd[d] | blk_wr[d], "blk request held until ack rises");
                blk_ack[d] <= 1'b1;
                for (i = 0; i < 512; i = i + 1) begin
                    @(posedge clk);
                    if (d == 2) begin
                        // the array holds the first 1 MB; larger mounted sizes read as zeros
                        if (lba * 512 + i >= HD_BYTES) begin
                            if (is_wr) check(0, "HDD block write past the modelled image");
                            else       sbuf[i] <= 8'h00;
                        end else if (is_wr) hd_img[lba * 512 + i] <= sbuf[i];
                        else                sbuf[i] <= hd_img[lba * 512 + i];
                    end else if (d == 0) begin
                        if (is_wr) fa_img[lba * 512 + i] <= sbuf[i];
                        else       sbuf[i] <= fa_img[lba * 512 + i];
                    end else begin
                        check(0, "block transfer for drive B (no image modelled)");
                    end
                end
                @(posedge clk);
                blk_ack[d] <= 1'b0;
                blk_count = blk_count + 1;
                last_blk_lba = lba;
                last_blk_drv = d;
                last_blk_wr = is_wr;
                repeat (2) @(posedge clk);
            end
        end
    end

    // bus protocol monitors: single-cycle strobes only (MGMT 1.5)
    reg prev_wr = 1'b0, prev_rd = 1'b0;
    always @(posedge clk) begin
        prev_wr <= mgmt_wr;
        prev_rd <= mgmt_rd;
        if (mgmt_wr && prev_wr) check(0, "mgmt_wr wider than one clock");
        if (mgmt_rd && prev_rd) check(0, "mgmt_rd wider than one clock");
        if (mgmt_wr && mgmt_rd) check(0, "mgmt_wr and mgmt_rd together");
    end

    // ------------------------------------------------------------------ helpers
    task mount(input integer drv, input [31:0] size, input ro);
    begin
        @(posedge clk);
        img_size <= size;
        img_readonly <= ro;
        img_mounted <= (3'b001 << drv);
        drive_mounted[drv] <= (size != 0);
        @(posedge clk);
        img_mounted <= 3'b000;
        @(posedge clk);
    end
    endtask

    // wait until the bridge has nothing left to do (mounts included)
    task wait_bridge_idle;
        integer n;
    begin
        n = 0;
        @(posedge clk);
        while (!(u_dut.state == 0 && !u_dut.hd_mount_pend && u_dut.fd_pend == 2'b00 &&
                 u_dut.fd_wait == 2'b00 && mgmt_req == 8'h00) && n < 400000) begin
            @(posedge clk);
            n = n + 1;
        end
        check(n < 400000, "bridge idle timeout");
        repeat (4) @(posedge clk);
    end
    endtask

    task ide_wr8(input [3:0] a, input [7:0] v);
    begin
        @(posedge clk);
        io_address <= a;
        io_writedata <= {24'd0, v};
        io_write <= 1'b1;
        @(posedge clk);
        io_write <= 1'b0;
        repeat (3) @(posedge clk);
    end
    endtask

    task ide_wr16(input [15:0] v);
    begin
        @(posedge clk);
        io_address <= 4'd0;
        io_writedata <= {16'd0, v};
        io_write <= 1'b1;
        @(posedge clk);
        io_write <= 1'b0;
        repeat (3) @(posedge clk);
    end
    endtask

    task ide_rd(input [3:0] a, output [31:0] v);
    begin
        @(posedge clk);
        io_address <= a;
        io_read <= 1'b1;
        @(posedge clk);
        io_read <= 1'b0;
        @(posedge clk);
        v = io_readdata;                         // registered on the edge that saw io_read
        repeat (2) @(posedge clk);
    end
    endtask

    task ide_wait_ready(output [7:0] st);
        integer n;
        reg [31:0] v;
    begin
        n = 0;
        ide_rd(4'd7, v);
        st = v[7:0];
        while (st[7] && n < 200000) begin
            ide_rd(4'd7, v);
            st = v[7:0];
            n = n + 1;
        end
        check(n < 200000, "IDE status poll timeout (BSY stuck)");
    end
    endtask

    task ide_wait_req_clear;
        integer n;
    begin
        n = 0;
        while (ide_req != 3'b000 && n < 200000) begin
            @(posedge clk);
            n = n + 1;
        end
        check(n < 200000, "IDE request never cleared");
        repeat (8) @(posedge clk);
    end
    endtask

    // set up an LBA28 command block (XT-IDE order: count, sector, cyl lo, cyl hi, drive/head, command)
    task ide_cmd_lba(input [27:0] lba, input [7:0] cnt, input [7:0] cmd);
    begin
        ide_wr8(4'd2, cnt);
        ide_wr8(4'd3, lba[7:0]);
        ide_wr8(4'd4, lba[15:8]);
        ide_wr8(4'd5, lba[23:16]);
        ide_wr8(4'd6, 8'hE0 | {4'd0, lba[27:24]});
        ide_wr8(4'd7, cmd);
    end
    endtask

    task ide_cmd_chs(input [15:0] c, input [3:0] h, input [7:0] s, input [7:0] cnt, input [8:0] cmd);
    begin
        ide_wr8(4'd2, cnt);
        ide_wr8(4'd3, s);
        ide_wr8(4'd4, c[7:0]);
        ide_wr8(4'd5, c[15:8]);
        ide_wr8(4'd6, 8'hA0 | {4'd0, h});
        ide_wr8(4'd7, cmd[7:0]);
    end
    endtask

    // read one 256-word block from the data register and compare with a
    // sector of the HDD image (or with zeros when zero = 1)
    task ide_read_block_check(input [31:0] lba, input zero, input string what);
        integer k, bad;
        reg [31:0] v;
        reg [7:0] e0, e1;
    begin
        bad = 0;
        for (k = 0; k < 256; k = k + 1) begin
            ide_rd(4'd0, v);
            e0 = zero ? 8'h00 : hd_img[lba * 512 + 2 * k];
            e1 = zero ? 8'h00 : hd_img[lba * 512 + 2 * k + 1];
            if (v[15:0] !== {e1, e0}) begin
                if (bad < 4) $display("  %s: word %0d = %04x, expected %02x%02x", what, k, v[15:0], e1, e0);
                bad = bad + 1;
            end
        end
        check(bad == 0, {what, ": sector data"});
    end
    endtask

    task fdc_wr(input [2:0] a, input [7:0] v);
    begin
        @(posedge clk);
        f_addr <= a;
        f_wdata <= v;
        f_wr <= 1'b1;
        @(posedge clk);
        f_wr <= 1'b0;
        repeat (3) @(posedge clk);
    end
    endtask

    task fdc_rd(input [2:0] a, output [7:0] v);
    begin
        @(posedge clk);
        f_addr <= a;
        f_rd <= 1'b1;
        @(posedge clk);
        f_rd <= 1'b0;
        @(posedge clk);
        v = f_rdata;
        repeat (2) @(posedge clk);
    end
    endtask

    // 8272 READ DATA / WRITE DATA: 9 command bytes (MF=1, drive 0)
    task fdc_cmd_rw(input is_write, input [7:0] c, input h, input [7:0] r, input [7:0] eot);
    begin
        fdc_wr(3'd5, is_write ? 8'h45 : 8'h46);
        fdc_wr(3'd5, {5'd0, h, 2'b00});          // HDS, DS = 0
        fdc_wr(3'd5, c);
        fdc_wr(3'd5, {7'd0, h});
        fdc_wr(3'd5, r);
        fdc_wr(3'd5, 8'h02);                     // N = 512 bytes
        fdc_wr(3'd5, eot);
        fdc_wr(3'd5, 8'h1B);                     // GPL
        fdc_wr(3'd5, 8'hFF);                     // DTL
    end
    endtask

    task fdc_wait_dma_req;
        integer n;
    begin
        n = 0;
        @(negedge clk);
        while (!fdd_dma_req && n < 400000) begin
            @(negedge clk);
            n = n + 1;
        end
        check(n < 400000, "floppy DMA request timeout");
    end
    endtask

    task fdc_wait_irq;
        integer n;
    begin
        n = 0;
        @(negedge clk);
        while (!fdd_irq && n < 400000) begin
            @(negedge clk);
            n = n + 1;
        end
        check(n < 400000, "floppy IRQ timeout");
    end
    endtask

    // result phase: 7 bytes from the data register
    task fdc_result(output [7:0] st0);
        integer k;
        reg [7:0] b;
    begin
        st0 = 8'hFF;
        for (k = 0; k < 7; k = k + 1) begin
            fdc_rd(3'd5, b);
            if (k == 0) st0 = b;
        end
    end
    endtask

    // MBR helpers for the geometry tests: entry e (0-3) of the partition table
    // at 0x1BE, classic layout {boot, start CHS, type, end CHS, start LBA, length}
    task set_mbr_entry(input integer e, input [7:0] typ,
                       input [7:0] sh, input [7:0] ss, input [15:0] sc,
                       input [7:0] eh, input [7:0] es, input [15:0] ec,
                       input [31:0] lba0, input [31:0] len);
        integer o;
    begin
        o = 'h1BE + 16 * e;
        hd_img[o + 0]  = (typ != 0) ? 8'h80 : 8'h00;
        hd_img[o + 1]  = sh;
        hd_img[o + 2]  = {sc[9:8], ss[5:0]};
        hd_img[o + 3]  = sc[7:0];
        hd_img[o + 4]  = typ;
        hd_img[o + 5]  = eh;
        hd_img[o + 6]  = {ec[9:8], es[5:0]};
        hd_img[o + 7]  = ec[7:0];
        hd_img[o + 8]  = lba0[7:0];   hd_img[o + 9]  = lba0[15:8];  hd_img[o + 10] = lba0[23:16]; hd_img[o + 11] = lba0[31:24];
        hd_img[o + 12] = len[7:0];    hd_img[o + 13] = len[15:8];   hd_img[o + 14] = len[23:16];  hd_img[o + 15] = len[31:24];
    end
    endtask

    // block 0 <- zeros, signature (or a broken one), no partition entries
    task clear_mbr(input sig_ok);
        integer i;
    begin
        for (i = 0; i < 512; i = i + 1) hd_img[i] = 8'h00;
        hd_img[510] = sig_ok ? 8'h55 : 8'h00;
        hd_img[511] = sig_ok ? 8'hAA : 8'h00;
    end
    endtask

    // IDENTIFY through the CPU side into idw[]
    task ide_identify;
        integer k;
        reg [31:0] v;
        reg [7:0]  st;
    begin
        ide_wr8(4'd6, 8'hA0);
        ide_wr8(4'd7, 8'hEC);
        ide_wait_ready(st);
        check(st == 8'h58, "IDENTIFY: DRQ");
        for (k = 0; k < 256; k = k + 1) begin
            ide_rd(4'd0, v);
            idw[k] = v[15:0];
        end
        ide_wait_ready(st);
        check(st == 8'h40, "IDENTIFY: 0x40 after the last word");
    end
    endtask

    // ------------------------------------------------------------------ main
    reg [319:0] model_str = "MEGA65 PCXT HD                          ";
    reg [15:0]  idw [0:255];
    reg [7:0]   dma_buf [0:511];

    initial begin : main
        integer i, k, bad, n0;
        reg [31:0] v;
        reg [7:0]  st, b;

`ifdef DUMP
        $dumpfile("mgmt_bridge_tb.vcd");
        $dumpvars(0, mgmt_bridge_tb);
`endif
        for (i = 0; i < HD_BYTES; i = i + 1) hd_img[i] = hdpat(i);
        for (i = 0; i < FA_BYTES; i = i + 1) fa_img[i] = fapat(i);
        for (i = 0; i < 512; i = i + 1) sbuf[i] = 8'h00;

        repeat (5) @(posedge clk);
        reset <= 1'b0;

        // ============================================================ 1. power-on reset, nothing mounted
        $display("[1] power-on reset request with no drive mounted");
        ide_wait_req_clear();
        wait_bridge_idle();
        check(u_ide.status == 8'h50, "reset: status 0x50 after the second block");
        check(u_ide.cylinder[15:0] == 16'hFFFF, "reset: cylinder 0xFFFF when not present");
        check(u_ide.sector_count[7:0] == 8'd1 && u_ide.sector[7:0] == 8'd1, "reset: sector/count = 1");
        check(u_ide.present == 2'b00, "no drive present yet");
        ide_rd(4'd7, v);
        check(v[7:0] == 8'hFF, "no drive: CPU reads 0xFF");
        // a command write is ignored by ide.v with nothing present: no request may appear
        ide_wr8(4'd7, 8'hEC);
        repeat (50) @(posedge clk);
        check(ide_req == 3'b000, "no drive: command write raises no request");

        // ============================================================ 2. mount the HDD
        $display("[2] mount 1 MB HDD");
        mount(2, HD_BYTES, 1'b0);
        wait_bridge_idle();
        check(u_ide.present == 2'b01, "mount: unit 0 present, unit 1 absent");
        check(u_ide.hob_ena == 2'b00, "mount: hob_ena 0");
        check(u_ide.use_wait == 1'b0, "mount: use_wait 0");
        check(u_ide.status == 8'h50, "mount: status 0x50");
        check(u_ide.cylinder[15:0] == 16'h0000, "mount: cylinder 0");
        check(u_dut.hd_cyl == 16'd2 && u_dut.hd_heads == 5'd16 && u_dut.hd_spt == 9'd63, "mount: geometry 2/16/63");
        check(u_dut.hd_total == 23'd2048, "mount: 2048 sectors");

        // ============================================================ 3. SRST
        $display("[3] software reset");
        ide_wr8(4'd14, 8'h04);
        repeat (40) @(posedge clk);
        check(ide_req == 3'b110, "SRST: request 110 while asserted");
        ide_wr8(4'd14, 8'h00);
        ide_wait_req_clear();
        ide_wait_ready(st);
        check(st == 8'h50, "SRST: status 0x50");
        ide_rd(4'd2, v); check(v[7:0] == 8'h01, "SRST: count 1");
        ide_rd(4'd3, v); check(v[7:0] == 8'h01, "SRST: sector 1");
        ide_rd(4'd4, v); check(v[7:0] == 8'h00, "SRST: cyl lo 0");
        ide_rd(4'd5, v); check(v[7:0] == 8'h00, "SRST: cyl hi 0");
        ide_rd(4'd1, v); check(v[7:0] == 8'h00, "SRST: error 0");
        ide_rd(4'd6, v); check(v[7:0] == 8'hA0, "SRST: drive/head 0xA0");

        // ============================================================ 4. IDENTIFY
        $display("[4] IDENTIFY DEVICE");
        ide_wr8(4'd6, 8'hA0);
        ide_wr8(4'd7, 8'hEC);
        ide_wait_ready(st);
        check(st == 8'h58, "IDENTIFY: DRQ");
        for (k = 0; k < 256; k = k + 1) begin
            ide_rd(4'd0, v);
            idw[k] = v[15:0];
        end
        ide_wait_ready(st);
        check(st == 8'h40, "IDENTIFY: 0x40 after the last word");
        check(idw[0] == 16'h0040, "IDENTIFY word 0");
        check(idw[1] == 16'd2, "IDENTIFY word 1 (cylinders = 2)");
        check(idw[3] == 16'd16, "IDENTIFY word 3 (heads)");
        check(idw[4] == 16'h7E00, "IDENTIFY word 4");
        check(idw[6] == 16'd63, "IDENTIFY word 6 (spt)");
        check(idw[10] == 16'h414F && idw[11] == 16'h4844 && idw[12] == 16'h3030 &&
              idw[13] == 16'h3030 && idw[14] == 16'h3020 && idw[15] == 16'h2020 && idw[19] == 16'h2020,
              "IDENTIFY serial AOHD00000");
        bad = 0;
        for (k = 0; k < 20; k = k + 1)
            if (idw[27 + k] !== model_str[319 - 16 * k -: 16]) bad = bad + 1;
        check(bad == 0, "IDENTIFY model string, ATA byte order");
        check(idw[47] == 16'h8001, "IDENTIFY word 47 = 0x8001");
        check(idw[49] == 16'h0200, "IDENTIFY word 49 (LBA)");
        check(idw[54] == 16'd2 && idw[55] == 16'd16 && idw[56] == 16'd63, "IDENTIFY words 54-56");
        check(idw[57] == 16'd2048 && idw[58] == 16'd0, "IDENTIFY words 57/58");
        check(idw[59] == 16'h0101, "IDENTIFY word 59");
        check(idw[60] == 16'd2048 && idw[61] == 16'd0, "IDENTIFY words 60/61 = 2048");
        check(idw[100] == 16'd2048 && idw[101] == 16'd0, "IDENTIFY words 100/101");
        check(idw[2] == 0 && idw[7] == 0 && idw[23] == 0 && idw[255] == 0, "IDENTIFY unused words 0");
        ide_rd(4'd6, v); check(v[7:0] == 8'hA0, "IDENTIFY: drive/head 0xA0 after");
        ide_rd(4'd2, v); check(v[7:0] == 8'h00, "IDENTIFY: count 0 after");

        // ============================================================ 5. READ SECTORS, LBA
        $display("[5] READ SECTORS at LBA 1234");
        n0 = blk_count;
        ide_cmd_lba(28'd1234, 8'd1, 8'h20);
        ide_wait_ready(st);
        check(st == 8'h58, "READ: DRQ");
        ide_read_block_check(32'd1234, 1'b0, "READ 1234");
        ide_wait_ready(st);
        check(st == 8'h40, "READ: 0x40 after the block");
        check(blk_count == n0 + 1 && last_blk_lba == 32'd1234 && last_blk_drv == 2 && !last_blk_wr, "READ: one block read of LBA 1234");
        ide_rd(4'd3, v); check(v[7:0] == 8'hD2, "READ: sector reg = LBA[7:0]");
        ide_rd(4'd4, v); check(v[7:0] == 8'h04, "READ: cyl lo = LBA[15:8]");
        ide_rd(4'd5, v); check(v[7:0] == 8'h00, "READ: cyl hi");
        ide_rd(4'd6, v); check(v[7:0] == 8'hE0, "READ: drive/head = 0xE0");
        ide_rd(4'd2, v); check(v[7:0] == 8'h00, "READ: count 0");
        ide_rd(4'd1, v); check(v[7:0] == 8'h00, "READ: error 0");

        // ============================================================ 6. WRITE SECTORS, CHS
        $display("[6] WRITE SECTORS at CHS 1/3/5 (LBA 1201)");
        n0 = blk_count;
        ide_cmd_chs(16'd1, 4'd3, 8'd5, 8'd1, 9'h030);
        ide_wait_ready(st);
        check(st == 8'h58, "WRITE: DRQ");
        for (k = 0; k < 256; k = k + 1) ide_wr16({wpat(2 * k + 1), wpat(2 * k)});
        ide_wait_ready(st);
        check(st == 8'h50, "WRITE: 0x50 when done");
        check(blk_count == n0 + 1 && last_blk_lba == 32'd1201 && last_blk_drv == 2 && last_blk_wr, "WRITE: one block write of LBA 1201");
        bad = 0;
        for (i = 0; i < 512; i = i + 1) if (hd_img[1201 * 512 + i] !== wpat(i)) bad = bad + 1;
        check(bad == 0, "WRITE: image sector 1201 holds the written data");
        ide_rd(4'd3, v); check(v[7:0] == 8'd5, "WRITE: sector reg 5");
        ide_rd(4'd4, v); check(v[7:0] == 8'd1, "WRITE: cyl lo 1");
        ide_rd(4'd6, v); check(v[7:0] == 8'hA3, "WRITE: drive/head 0xA3");
        ide_rd(4'd2, v); check(v[7:0] == 8'h00, "WRITE: count 0");
        // read it back through the IDE path as well
        ide_cmd_chs(16'd1, 4'd3, 8'd5, 8'd1, 9'h020);
        ide_wait_ready(st);
        check(st == 8'h58, "READ-back: DRQ");
        ide_read_block_check(32'd1201, 1'b0, "READ-back 1201");
        ide_wait_ready(st);
        check(st == 8'h40, "READ-back: 0x40");

        // ============================================================ 7. two-sector read (data-phase chain, req 101)
        $display("[7] READ SECTORS count=2 at LBA 500");
        n0 = blk_count;
        ide_cmd_lba(28'd500, 8'd2, 8'h20);
        ide_wait_ready(st);
        check(st == 8'h58, "READ x2: DRQ block 1");
        ide_read_block_check(32'd500, 1'b0, "READ x2 block 1");
        ide_wait_ready(st);
        check(st == 8'h58, "READ x2: DRQ block 2 (after request 101)");
        // ARM 4.3 read steps 2-4: the registers are updated *before* each block
        // is handed over, so with block 2 in the buffer they already show
        // LBA 501 and count 0 (the write path, checked in [7b], is the other way round)
        ide_rd(4'd2, v); check(v[7:0] == 8'd0, "READ x2: count 0 once block 2 is offered");
        ide_rd(4'd3, v); check(v[7:0] == 8'hF5, "READ x2: sector 0xF5 once block 2 is offered");
        ide_read_block_check(32'd501, 1'b0, "READ x2 block 2");
        ide_wait_ready(st);
        check(st == 8'h40, "READ x2: 0x40 at the end");
        check(blk_count == n0 + 2 && last_blk_lba == 32'd501, "READ x2: two blocks fetched, last = 501");
        ide_rd(4'd2, v); check(v[7:0] == 8'd0, "READ x2: count 0 at the end");
        ide_rd(4'd3, v); check(v[7:0] == 8'hF5, "READ x2: sector 0xF5 at the end");
        ide_rd(4'd4, v); check(v[7:0] == 8'h01, "READ x2: cyl lo 1 at the end");

        // READ MULTIPLE (C4) behaves the same: 1 sector per DRQ
        $display("[7b] READ MULTIPLE count=2 at LBA 600, WRITE MULTIPLE count=2 at LBA 700");
        ide_cmd_lba(28'd600, 8'd2, 8'hC4);
        ide_wait_ready(st);
        check(st == 8'h58, "C4: DRQ block 1");
        ide_read_block_check(32'd600, 1'b0, "C4 block 1");
        ide_wait_ready(st);
        check(st == 8'h58, "C4: DRQ block 2");
        ide_read_block_check(32'd601, 1'b0, "C4 block 2");
        ide_wait_ready(st);
        check(st == 8'h40, "C4: done");
        // two-sector write
        n0 = blk_count;
        ide_cmd_lba(28'd700, 8'd2, 8'h30);
        ide_wait_ready(st);
        check(st == 8'h58, "WRITE x2: DRQ block 1");
        for (k = 0; k < 256; k = k + 1) ide_wr16({wpat(2 * k + 1), wpat(2 * k)});
        ide_wait_ready(st);
        check(st == 8'h58, "WRITE x2: DRQ block 2");
        ide_rd(4'd2, v); check(v[7:0] == 8'd1, "WRITE x2: count 1 between blocks");
        ide_rd(4'd3, v); check(v[7:0] == 8'hBC, "WRITE x2: sector 0xBC (700) between blocks");
        for (k = 0; k < 256; k = k + 1) ide_wr16({wpat(2 * k + 1 + 512), wpat(2 * k + 512)});
        ide_wait_ready(st);
        check(st == 8'h50, "WRITE x2: done");
        check(blk_count == n0 + 2 && last_blk_lba == 32'd701 && last_blk_wr, "WRITE x2: two blocks stored, last = 701");
        bad = 0;
        for (i = 0; i < 1024; i = i + 1) if (hd_img[700 * 512 + i] !== wpat(i)) bad = bad + 1;
        check(bad == 0, "WRITE x2: image sectors 700/701");
        ide_rd(4'd3, v); check(v[7:0] == 8'hBD, "WRITE x2: sector 0xBD at the end");
        ide_rd(4'd2, v); check(v[7:0] == 8'd0, "WRITE x2: count 0 at the end");

        // ============================================================ 8. unsupported / not present / no-data commands
        $display("[8] unsupported and no-data commands");
        ide_wr8(4'd6, 8'hA0);
        ide_wr8(4'd7, 8'hEF);                    // SET FEATURES -> abort
        ide_wait_ready(st);
        check(st == 8'h41, "EF: status 0x41");
        ide_rd(4'd1, v); check(v[7:0] == 8'h04, "EF: error ABRT");
        ide_wr8(4'd7, 8'hE7);                    // FLUSH CACHE -> abort
        ide_wait_ready(st);
        check(st == 8'h41, "E7: status 0x41");
        ide_wr8(4'd6, 8'hB0);                    // unit 1: never present
        ide_wr8(4'd7, 8'hEC);
        ide_wait_ready(st);
        check(st == 8'h41, "unit 1: abort");
        ide_rd(4'd1, v); check(v[7:0] == 8'h04, "unit 1: error ABRT");
        ide_rd(4'd6, v); check(v[7:0] == 8'hB0, "unit 1: drive/head echoed");
        ide_wr8(4'd6, 8'hA0);
        ide_wr8(4'd2, 8'd1); ide_wr8(4'd7, 8'hC6);   // SET MULTIPLE 1 -> ok
        ide_wait_ready(st);
        check(st == 8'h50, "C6 count 1: ok");
        ide_wr8(4'd2, 8'd4); ide_wr8(4'd7, 8'hC6);   // SET MULTIPLE 4 -> abort
        ide_wait_ready(st);
        check(st == 8'h41, "C6 count 4: abort");
        ide_wr8(4'd4, 8'h55); ide_wr8(4'd5, 8'h01);
        ide_wr8(4'd7, 8'h10);                    // RECALIBRATE
        ide_wait_ready(st);
        check(st == 8'h50, "10: ok");
        ide_rd(4'd4, v); check(v[7:0] == 8'h00, "10: cyl lo 0");
        ide_rd(4'd5, v); check(v[7:0] == 8'h00, "10: cyl hi 0");
        ide_rd(4'd1, v); check(v[7:0] == 8'h00, "10: error 0");
        ide_wr8(4'd7, 8'h70);                    // SEEK
        ide_wait_ready(st); check(st == 8'h50, "70: ok");
        ide_wr8(4'd7, 8'h40);                    // READ VERIFY
        ide_wait_ready(st); check(st == 8'h50, "40: ok");
        ide_wr8(4'd7, 8'h41);
        ide_wait_ready(st); check(st == 8'h50, "41: ok");
        ide_wr8(4'd7, 8'hE3);                    // IDLE
        ide_wait_ready(st); check(st == 8'h50, "E3: ok");
        ide_wr8(4'd7, 8'h90);                    // EXECUTE DIAGNOSTICS
        ide_wait_ready(st); check(st == 8'h50, "90: status 0x50");
        ide_rd(4'd1, v); check(v[7:0] == 8'h01, "90: error 0x01");
        ide_wr8(4'd7, 8'h08);                    // DEVICE RESET -> abort
        ide_wait_ready(st); check(st == 8'h41, "08: abort");
        ide_wr8(4'd7, 8'hA1);                    // ATAPI IDENTIFY -> abort
        ide_wait_ready(st); check(st == 8'h41, "A1: abort");

        // ============================================================ 9. INITIALIZE DEVICE PARAMETERS
        $display("[9] 91h geometry");
        ide_wr8(4'd6, 8'hA3);                    // heads = 4
        ide_wr8(4'd2, 8'd17);                    // spt = 17
        ide_wr8(4'd7, 8'h91);
        ide_wait_ready(st);
        check(st == 8'h50, "91: ok");
        check(u_dut.hd_heads == 5'd4 && u_dut.hd_spt == 9'd17 && u_dut.hd_cyl == 16'd30, "91: 4 heads, 17 spt, 2048/68 = 30 cylinders");
        n0 = blk_count;
        ide_cmd_chs(16'd1, 4'd1, 8'd1, 8'd1, 9'h020);   // (1*4+1)*17 + 0 = 85
        ide_wait_ready(st);
        check(st == 8'h58, "91 read: DRQ");
        ide_read_block_check(32'd85, 1'b0, "91 read 85");
        ide_wait_ready(st);
        check(st == 8'h40, "91 read: done");
        check(blk_count == n0 + 1 && last_blk_lba == 32'd85, "91: CHS 1/1/1 -> LBA 85 with the new translation");
        ide_wr8(4'd6, 8'hA0);
        ide_wr8(4'd7, 8'hEC);                    // IDENTIFY unchanged by 91h
        ide_wait_ready(st);
        for (k = 0; k < 256; k = k + 1) begin
            ide_rd(4'd0, v);
            idw[k] = v[15:0];
        end
        ide_wait_ready(st);
        check(idw[1] == 16'd2 && idw[3] == 16'd16 && idw[6] == 16'd63, "91: IDENTIFY words 1/3/6 frozen at mount");
        ide_wr8(4'd6, 8'hAF);                    // back to 16 x 63
        ide_wr8(4'd2, 8'd63);
        ide_wr8(4'd7, 8'h91);
        ide_wait_ready(st);
        check(st == 8'h50 && u_dut.hd_cyl == 16'd2, "91: restored 16/63 -> 2 cylinders");
        ide_wr8(4'd6, 8'hA0);
        ide_wr8(4'd2, 8'd0);
        ide_wr8(4'd7, 8'h91);                    // spt 0 -> 256, heads 1
        ide_wait_ready(st);
        check(st == 8'h50 && u_dut.hd_spt == 9'd256 && u_dut.hd_heads == 5'd1 && u_dut.hd_cyl == 16'd8, "91: count 0 -> spt 256");
        ide_wr8(4'd6, 8'hAF);
        ide_wr8(4'd2, 8'd63);
        ide_wr8(4'd7, 8'h91);
        ide_wait_ready(st);

        // ============================================================ 10. read beyond the image, read-only image
        $display("[10] read beyond EOF, write to a read-only image");
        n0 = blk_count;
        ide_cmd_lba(28'd3000, 8'd1, 8'h20);
        ide_wait_ready(st);
        check(st == 8'h58, "EOF read: DRQ");
        ide_read_block_check(32'd0, 1'b1, "EOF read (zeros)");
        ide_wait_ready(st);
        check(st == 8'h40 && blk_count == n0, "EOF read: no block transfer, no error");
        mount(2, HD_BYTES, 1'b1);                // same image, read-only
        wait_bridge_idle();
        n0 = blk_count;
        ide_cmd_lba(28'd1234, 8'd1, 8'h30);
        ide_wait_ready(st);
        check(st == 8'h58, "RO write: DRQ");
        for (k = 0; k < 256; k = k + 1) ide_wr16(16'hDEAD);
        ide_wait_ready(st);
        check(st == 8'h50 && blk_count == n0, "RO write: accepted, nothing stored");
        bad = 0;
        for (i = 0; i < 512; i = i + 1) if (hd_img[1234 * 512 + i] !== hdpat(1234 * 512 + i)) bad = bad + 1;
        check(bad == 0, "RO write: image untouched");
        mount(2, HD_BYTES, 1'b0);
        wait_bridge_idle();

        // ============================================================ 10b. geometry from the MBR
        // The FreeDOS test image: 44,660,224 bytes = 87,227 sectors = 733 x 7 x 17,
        // one type-06 partition starting at CHS 0/1/1 (LBA 17) and ending at
        // CHS 732/6/17. Only block 0 differs from the pattern image.
        $display("[10b] MBR geometry: 87,227-sector image, partition end CHS 732/6/17 -> 7 x 17");
        mount(2, 32'd0, 1'b0);                   // unmount first so "present" is observable
        wait_bridge_idle();
        check(u_ide.present == 2'b00, "MBR: unmounted before the geometry mount");
        clear_mbr(1'b1);
        set_mbr_entry(0, 8'h06, 8'd1, 8'd1, 16'd0, 8'd6, 8'd17, 16'd732, 32'd17, 32'd87210);
        n0 = blk_count;
        mount(2, 32'd44660224, 1'b0);
        // the mount fetches block 0 first; the drive is not present until that is parsed
        k = 0;
        while (blk_count == n0 && k < 100000) begin @(posedge clk); k = k + 1; end
        check(blk_count == n0 + 1 && last_blk_lba == 32'd0 && last_blk_drv == 2 && !last_blk_wr, "MBR: mount reads block 0 of the HDD");
        check(u_ide.present == 2'b00, "MBR: not present until the geometry is parsed");
        wait_bridge_idle();
        check(blk_count == n0 + 1, "MBR: exactly one block read at mount");
        check(u_ide.present == 2'b01 && u_ide.status == 8'h50, "MBR mount: present, status 0x50");
        check(u_dut.hd_total == 23'd87227, "MBR: 87227 sectors");
        check(u_dut.hd_heads == 5'd7 && u_dut.hd_spt == 9'd17 && u_dut.hd_cyl == 16'd733, "MBR: geometry 733/7/17");
        ide_identify();
        check(idw[1] == 16'd733, "MBR IDENTIFY word 1 (cylinders = 733)");
        check(idw[3] == 16'd7, "MBR IDENTIFY word 3 (heads = 7)");
        check(idw[4] == 16'h2200, "MBR IDENTIFY word 4 (512 * 17)");
        check(idw[6] == 16'd17, "MBR IDENTIFY word 6 (spt = 17)");
        check(idw[54] == 16'd733 && idw[55] == 16'd7 && idw[56] == 16'd17, "MBR IDENTIFY words 54-56");
        check(idw[57] == 16'h54BB && idw[58] == 16'd1, "MBR IDENTIFY words 57/58 = 87227");
        check(idw[60] == 16'h54BB && idw[61] == 16'd1, "MBR IDENTIFY words 60/61 = 87227");
        // the MBR's own CHS read of the boot sector: C=0 H=1 S=1 -> LBA 17
        n0 = blk_count;
        ide_cmd_chs(16'd0, 4'd1, 8'd1, 8'd1, 9'h020);
        ide_wait_ready(st);
        check(st == 8'h58, "MBR CHS read: DRQ");
        ide_read_block_check(32'd17, 1'b0, "MBR CHS 0/1/1");
        ide_wait_ready(st);
        check(st == 8'h40, "MBR CHS read: done");
        check(blk_count == n0 + 1 && last_blk_lba == 32'd17, "MBR: CHS 0/1/1 -> LBA 17 with 7 x 17");
        ide_rd(4'd3, v); check(v[7:0] == 8'd1, "MBR CHS read: sector 1 reported");
        ide_rd(4'd6, v); check(v[7:0] == 8'hA1, "MBR CHS read: head 1 reported");
        // last sector of cylinder 1: C=1 H=6 S=17 -> (1*7+6)*17 + 16 = 237
        n0 = blk_count;
        ide_cmd_chs(16'd1, 4'd6, 8'd17, 8'd2, 9'h020);
        ide_wait_ready(st);
        check(st == 8'h58, "MBR CHS 1/6/17: DRQ");
        ide_read_block_check(32'd237, 1'b0, "MBR CHS 1/6/17");
        ide_wait_ready(st);
        check(st == 8'h58, "MBR CHS 1/6/17: DRQ block 2");
        ide_rd(4'd3, v); check(v[7:0] == 8'd1, "MBR CHS step: sector wraps to 1");
        ide_rd(4'd4, v); check(v[7:0] == 8'd2, "MBR CHS step: cylinder 2");
        ide_rd(4'd6, v); check(v[7:0] == 8'hA0, "MBR CHS step: head 0");
        ide_read_block_check(32'd238, 1'b0, "MBR CHS 2/0/1");
        ide_wait_ready(st);
        check(st == 8'h40 && last_blk_lba == 32'd238, "MBR CHS: stepped into cylinder 2 = LBA 238");
        // the second entry is used when the first is empty (type 0)
        $display("[10c] MBR: empty first entry, out-of-range entries, missing signature -> fallbacks");
        clear_mbr(1'b1);
        set_mbr_entry(0, 8'h00, 8'd0, 8'd0, 16'd0, 8'd15, 8'd63, 16'd0, 32'd0, 32'd0);
        set_mbr_entry(1, 8'h01, 8'd1, 8'd1, 16'd0, 8'd3, 8'd17, 16'd29, 32'd17, 32'd2023);
        mount(2, HD_BYTES, 1'b0);
        wait_bridge_idle();
        check(u_dut.hd_heads == 5'd4 && u_dut.hd_spt == 9'd17 && u_dut.hd_cyl == 16'd30, "MBR: first non-zero type wins -> 30/4/17");
        ide_identify();
        check(idw[1] == 16'd30 && idw[3] == 16'd4 && idw[6] == 16'd17 && idw[4] == 16'h2200, "MBR IDENTIFY 30/4/17");
        n0 = blk_count;
        ide_cmd_chs(16'd1, 4'd1, 8'd1, 8'd1, 9'h020);   // (1*4+1)*17 = 85
        ide_wait_ready(st);
        ide_read_block_check(32'd85, 1'b0, "MBR 4x17 CHS 1/1/1");
        ide_wait_ready(st);
        check(st == 8'h40 && blk_count == n0 + 1 && last_blk_lba == 32'd85, "MBR 4x17: CHS 1/1/1 -> LBA 85");
        // heads 17 (end head 16): out of range -> 16 x 63
        clear_mbr(1'b1);
        set_mbr_entry(0, 8'h06, 8'd1, 8'd1, 16'd0, 8'd16, 8'd17, 16'd10, 32'd17, 32'd1000);
        mount(2, HD_BYTES, 1'b0);
        wait_bridge_idle();
        check(u_dut.hd_heads == 5'd16 && u_dut.hd_spt == 9'd63 && u_dut.hd_cyl == 16'd2, "MBR: 17 heads rejected -> 16 x 63");
        // sector 0: out of range -> 16 x 63
        clear_mbr(1'b1);
        set_mbr_entry(0, 8'h06, 8'd1, 8'd1, 16'd0, 8'd6, 8'd0, 16'd10, 32'd17, 32'd1000);
        mount(2, HD_BYTES, 1'b0);
        wait_bridge_idle();
        check(u_dut.hd_heads == 5'd16 && u_dut.hd_spt == 9'd63, "MBR: spt 0 rejected -> 16 x 63");
        // all four entries empty with a valid signature -> 16 x 63
        clear_mbr(1'b1);
        mount(2, HD_BYTES, 1'b0);
        wait_bridge_idle();
        check(u_dut.hd_heads == 5'd16 && u_dut.hd_spt == 9'd63, "MBR: no partitions -> 16 x 63");
        // a good 7 x 17 entry without the 55 AA signature -> 16 x 63, 87227/1008 = 86 cylinders
        clear_mbr(1'b0);
        set_mbr_entry(0, 8'h06, 8'd1, 8'd1, 16'd0, 8'd6, 8'd17, 16'd732, 32'd17, 32'd87210);
        mount(2, 32'd44660224, 1'b0);
        wait_bridge_idle();
        check(u_dut.hd_heads == 5'd16 && u_dut.hd_spt == 9'd63 && u_dut.hd_cyl == 16'd86, "MBR: no signature -> 86/16/63");
        ide_identify();
        check(idw[1] == 16'd86 && idw[3] == 16'd16 && idw[6] == 16'd63 && idw[4] == 16'h7E00, "no-signature IDENTIFY 86/16/63");
        check(idw[57] == 16'h54BB && idw[58] == 16'd1, "no-signature IDENTIFY words 57/58 = 87227");
        n0 = blk_count;
        ide_cmd_chs(16'd0, 4'd1, 8'd1, 8'd1, 9'h020);   // 16 x 63: 0/1/1 -> LBA 63
        ide_wait_ready(st);
        ide_read_block_check(32'd63, 1'b0, "no-signature CHS 0/1/1");
        ide_wait_ready(st);
        check(blk_count == n0 + 1 && last_blk_lba == 32'd63, "no-signature: CHS 0/1/1 -> LBA 63");
        // half a signature (55 only) -> fallback too
        hd_img[510] = 8'h55;
        mount(2, HD_BYTES, 1'b0);
        wait_bridge_idle();
        check(u_dut.hd_heads == 5'd16 && u_dut.hd_spt == 9'd63, "MBR: 55 without AA -> 16 x 63");
        // back to the plain pattern image for the remaining tests
        for (i = 0; i < 512; i = i + 1) hd_img[i] = hdpat(i);
        mount(2, HD_BYTES, 1'b0);
        wait_bridge_idle();
        check(u_dut.hd_cyl == 16'd2 && u_dut.hd_heads == 5'd16 && u_dut.hd_spt == 9'd63, "pattern image again: 2/16/63");
        check(u_ide.present == 2'b01 && u_ide.status == 8'h50, "pattern image again: present");

        // ============================================================ 11. floppy A mount
        $display("[11] floppy A mount (360 KB)");
        mount(0, FA_BYTES, 1'b0);
        // eject first: media_present must go 0 before the geometry is written
        n0 = 0;
        while (u_dut.fd_wait[0] == 1'b0 && n0 < 10000) begin @(posedge clk); n0 = n0 + 1; end
        repeat (3) @(posedge clk);
        check(u_fdd.media_present[0] == 1'b0, "fdd mount: media_present written 0 first");
        wait_bridge_idle();
        check(u_fdd.media_present[0] == 1'b1, "fdd mount: media_present 1");
        check(u_fdd.wp_sys[0] == 1'b0, "fdd mount: write enabled");
        check(u_fdd.media_cylinders[0] == 8'd40, "fdd mount: 40 cylinders");
        check(u_fdd.media_sectors_per_track[0] == 8'd9, "fdd mount: 9 spt");
        check(u_fdd.media_sector_count[0] == 16'd720, "fdd mount: 720 sectors");
        check(u_fdd.media_heads[0] == 2'd2, "fdd mount: 2 heads");
        check(u_fdd.media_present[1] == 1'b0, "fdd mount: drive B untouched");

        // ============================================================ 12. floppy read through floppy.v (DMA)
        $display("[12] 8272 READ DATA C=3 H=1 R=4 (LBA 66) via DMA");
        n0 = blk_count;
        fdc_wr(3'd2, 8'h1C);                     // DOR: motor A, DMA/IRQ enable, not reset, drive 0
        fdc_cmd_rw(1'b0, 8'd3, 1'b1, 8'd4, 8'd9);
        for (i = 0; i < 512; i = i + 1) begin
            fdc_wait_dma_req();
            @(posedge clk);
            fdd_dma_ack <= 1'b1;
            fdd_dma_tc  <= (i == 511);
            @(negedge clk);
            dma_buf[i] = fdd_dma_wr;
            @(posedge clk);
            fdd_dma_ack <= 1'b0;
            fdd_dma_tc  <= 1'b0;
        end
        bad = 0;
        for (i = 0; i < 512; i = i + 1) if (dma_buf[i] !== fa_img[66 * 512 + i]) bad = bad + 1;
        check(bad == 0, "fdd read: 512 DMA bytes match image sector 66");
        check(blk_count == n0 + 1 && last_blk_lba == 32'd66 && last_blk_drv == 0 && !last_blk_wr, "fdd read: one block read of LBA 66 from drive A");
        fdc_wait_irq();
        fdc_rd(3'd4, b);
        check(b[7:6] == 2'b11, "fdd read: MSR ready for the result phase");
        fdc_result(st);
        check(st[7:6] == 2'b00, "fdd read: ST0 normal termination");
        wait_bridge_idle();

        // ============================================================ 13. floppy write through floppy.v (DMA)
        $display("[13] 8272 WRITE DATA C=0 H=0 R=1 (LBA 0) via DMA");
        n0 = blk_count;
        fdc_cmd_rw(1'b1, 8'd0, 1'b0, 8'd1, 8'd9);
        for (i = 0; i < 512; i = i + 1) begin
            fdc_wait_dma_req();
            @(posedge clk);
            fdd_dma_rd  <= wpat(i);
            fdd_dma_ack <= 1'b1;
            fdd_dma_tc  <= (i == 511);
            @(posedge clk);
            fdd_dma_ack <= 1'b0;
            fdd_dma_tc  <= 1'b0;
        end
        fdc_wait_irq();
        fdc_result(st);
        check(st[7:6] == 2'b00, "fdd write: ST0 normal termination");
        wait_bridge_idle();
        check(blk_count == n0 + 1 && last_blk_lba == 32'd0 && last_blk_drv == 0 && last_blk_wr, "fdd write: one block write of LBA 0 to drive A");
        bad = 0;
        for (i = 0; i < 512; i = i + 1) if (fa_img[i] !== wpat(i)) bad = bad + 1;
        check(bad == 0, "fdd write: image sector 0 holds the DMA data");

        // ============================================================ 14. floppy B mount, read-only remount, unmount
        $display("[14] floppy B mount (1.44 MB), A read-only, A unmount");
        mount(1, 32'd1474560, 1'b1);
        wait_bridge_idle();
        check(u_fdd.media_present[1] == 1'b1, "fdd B: present");
        check(u_fdd.wp_sys[1] == 1'b1, "fdd B: write protected (read-only image)");
        check(u_fdd.media_cylinders[1] == 8'd80 && u_fdd.media_sectors_per_track[1] == 8'd18 &&
              u_fdd.media_heads[1] == 2'd2 && u_fdd.media_sector_count[1] == 16'd2880, "fdd B: 80/18/2/2880");
        check(u_fdd.media_present[0] == 1'b1 && u_fdd.media_cylinders[0] == 8'd40, "fdd B mount left A alone");
        mount(0, 32'd737280, 1'b1);              // 720 KB, read-only
        wait_bridge_idle();
        check(u_fdd.wp_sys[0] == 1'b1 && u_fdd.media_cylinders[0] == 8'd80 && u_fdd.media_sectors_per_track[0] == 8'd9 &&
              u_fdd.media_sector_count[0] == 16'd1440, "fdd A remount 720 KB read-only");
        mount(0, 32'd0, 1'b0);
        wait_bridge_idle();
        check(u_fdd.media_present[0] == 1'b0, "fdd A unmount: media_present 0");
        check(u_fdd.wp_sys[0] == 1'b1, "fdd A unmount: write protected");
        mount(1, 32'd5000000, 1'b0);             // > 8000 blocks: rejected like the ARM
        wait_bridge_idle();
        check(u_fdd.media_present[1] == 1'b0, "fdd B: oversize image rejected");

        // ============================================================ 15. HDD unmount
        $display("[15] HDD unmount");
        mount(2, 32'd0, 1'b0);
        wait_bridge_idle();
        check(u_ide.present == 2'b00, "unmount: unit 0 absent");
        ide_wr8(4'd7, 8'hEC);
        repeat (50) @(posedge clk);
        check(ide_req == 3'b000, "unmount: command ignored, no request");
        ide_rd(4'd7, v);
        check(v[7:0] == 8'hFF, "unmount: CPU reads 0xFF");

        $display("%0d checks, %0d failures", checks, errors);
        if (errors == 0) $display("RESULT: PASS");
        else             $display("RESULT: FAIL");
        $finish;
    end

    // watchdog
    initial begin
        #100_000_000;                            // 100 ms
        $display("TIMEOUT");
        $display("RESULT: FAIL");
        $finish;
    end

endmodule
