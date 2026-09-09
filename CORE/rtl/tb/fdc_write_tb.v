// fdc_write_tb.v
//
// Focused unit test of the REAL overlay floppy.v WRITE path -- the direction a
// DOS floppy WRITE uses and that fails on hardware ("drive not ready").
//
// It drives the real floppy.v at its CPU I/O ports directly (polling the Main
// Status Register exactly as the BIOS's nec_chip does: wait RQM=1, DIO=0 before
// each command byte), watching floppy.irq for command completion instead of
// wiring a real 8259 -- so the whole bench compiles under Icarus, which the
// KF8259-based xsim benches cannot. The interrupt/edge behaviour is already
// covered by fdc_bios_tb; this bench isolates the WRITE state machine, the DMA
// fill of the write FIFO, and the mgmt request[1] (mgmt_req[7], "FDD write")
// that the storage bridge drains.
//
// The DMA channel-2 side is behavioural (memory -> device): on floppy.dma_req
// it presents the next byte of a known 512-byte source pattern on dma_readdata
// and pulses dma_ack (one byte per pulse), TC on the last byte. That contract
// is exactly what fdc_dma_wr_tb.sv proves the REAL KF8237 + REAL RAM.sv + REAL
// READY honour end to end, so a behavioural stand-in here is faithful.
//
// For a WRITE the ORDER is: the DMA must FILL the FIFO from memory FIRST, and
// only then does request[1] rise so the bridge can drain it to SD. If the DMA
// never fills the FIFO, request[1] never rises and the controller times out --
// the reported failure. This bench checks: WRITE started, 512 bytes DMA'd in,
// request[1] rose, 512 drained bytes match the source, and the command
// completed (result phase reached).
//
//   wsl -d Ubuntu -- bash ./run_fdc_write_tb.sh

`timescale 1ns/10ps

module fdc_write_tb;

    reg clk = 1'b0;
    always #5 clk = ~clk;
    reg rst_n = 1'b0;

    integer errors = 0;
    task check(input cond, input [8*48:1] msg);
        if (!cond) begin errors = errors + 1; $display("  CHECK FAILED: %0s   (t=%0t)", msg, $time); end
    endtask

    // ---- floppy I/O port drivers ------------------------------------------
    reg  [2:0] io_address = 3'd0;
    reg        io_read    = 1'b0;
    reg        io_write   = 1'b0;
    reg  [7:0] io_writedata = 8'h00;
    wire [7:0] io_readdata;

    // ---- dma (behavioural memory->device) ---------------------------------
    wire       dma_req;
    reg        dma_ack = 1'b0;
    reg        dma_tc  = 1'b0;
    reg  [7:0] dma_readdata = 8'h00;
    wire [7:0] dma_writedata;

    // ---- mgmt --------------------------------------------------------------
    reg  [3:0] mgmt_address = 4'd0;
    reg        mgmt_fddn = 1'b0;
    reg        mgmt_write = 1'b0;
    reg [15:0] mgmt_writedata = 16'd0;
    reg        mgmt_read = 1'b0;
    wire [15:0] mgmt_readdata;

    wire       irq;
    wire [1:0] request;

    floppy u_fdd (
        .clk           (clk),
        .rst_n         (rst_n),
        .dma_req       (dma_req),
        .dma_ack       (dma_ack),
        .dma_tc        (dma_tc & dma_ack),
        .dma_readdata  (dma_readdata),
        .dma_writedata (dma_writedata),
        .irq           (irq),
        .io_address    (io_address),
        .io_read       (io_read),
        .io_readdata   (io_readdata),
        .io_write      (io_write),
        .io_writedata  (io_writedata),
        .fdd0_inserted (),
        .mgmt_address  (mgmt_address),
        .mgmt_fddn     (mgmt_fddn),
        .mgmt_write    (mgmt_write),
        .mgmt_writedata(mgmt_writedata),
        .mgmt_read     (mgmt_read),
        .mgmt_readdata (mgmt_readdata),
        .wp            (2'b00),
        .clock_rate    (28'd8000),
        .request       (request)
    );

    // ---- source pattern (the sector being written) ------------------------
    function [7:0] spat(input integer i);
        spat = (( (i*7) + 8'h11 ) & 8'hFF) ^ 8'h3C;
    endfunction
    reg [7:0] src [0:511];
    integer ii;
    initial for (ii = 0; ii < 512; ii = ii + 1) src[ii] = spat(ii);

    // ---- probes / counters -------------------------------------------------
    integer rws_count = 0;      // cmd_read_write_start pulses
    integer dack_pulses = 0;
    integer dma_bytes = 0;
    integer wr_req_rises = 0;   // request[1] rising edges (mgmt_req[7])
    integer max_fifo = 0;
    integer seen_check_tc = 0;
    reg req1_q = 1'b0;
    always @(posedge clk) begin
        if (u_fdd.cmd_read_write_start) rws_count <= rws_count + 1;
        if (u_fdd.fifo_count > max_fifo) max_fifo <= u_fdd.fifo_count;
        if (u_fdd.state == 4'd8) seen_check_tc <= 1;   // S_CHECK_TC
        req1_q <= request[1];
        if (request[1] && !req1_q) wr_req_rises <= wr_req_rises + 1;
    end

    // ---- behavioural DMA ch2: memory -> device ----------------------------
    reg        dma_enabled = 1'b0;
    integer    dma_issued = 0;
    integer    dma_st = 0;
    integer    dma_lat = 0;
    localparam integer DMA_COUNT = 512;
    // Per-byte memory-read latency, emulating the 8237 parking in SW while a
    // HyperRAM read completes (fdc_dma_wr_tb proves the real 8237+READY+RAM.sv
    // do exactly this). 0 = instantaneous; a nonzero value stresses the real
    // floppy.v write FSM against a slow DMA fill.
    localparam integer DMA_MEM_LAT = 40;
    always @(posedge clk) begin
        if (!rst_n) begin
            dma_ack <= 1'b0; dma_tc <= 1'b0; dma_st <= 0; dma_issued <= 0; dma_bytes <= 0;
            dma_readdata <= 8'h00; dma_lat <= 0;
        end else begin
            case (dma_st)
                0: begin
                    dma_ack <= 1'b0; dma_tc <= 1'b0;
                    if (dma_enabled && dma_req && dma_issued < DMA_COUNT) begin
                        dma_lat <= DMA_MEM_LAT;
                        dma_st  <= 3;              // wait for the "memory read"
                    end
                end
                3: begin                          // emulate memory-read latency
                    if (dma_lat != 0) dma_lat <= dma_lat - 1;
                    else begin
                        dma_readdata <= src[dma_issued];
                        dma_ack      <= 1'b1;
                        dma_tc       <= (dma_issued == DMA_COUNT-1);
                        dack_pulses  <= dack_pulses + 1;
                        dma_bytes    <= dma_bytes + 1;
                        dma_issued   <= dma_issued + 1;
                        dma_st       <= 1;
                    end
                end
                1: begin
                    dma_ack <= 1'b0; dma_tc <= 1'b0;   // 1-clk gap, let dma_req re-eval
                    dma_st  <= 0;
                end
            endcase
        end
    end

    // ---- behavioural mgmt DRAIN of the write FIFO on request[1] -----------
    reg [7:0] drained [0:511];
    integer   drained_count = 0;
    integer   drain_sectors = 0;
    integer   di;
    initial begin : drainer
        forever begin
            @(posedge clk);
            if (request[1]) begin
                for (di = 0; di < 512; di = di + 1) begin
                    @(posedge clk);
                    mgmt_address <= 4'hF;
                    mgmt_read    <= 1'b1;
                    @(posedge clk);
                    drained[di] = mgmt_readdata[7:0];
                    if (drained_count < 512) drained_count = drained_count + 1;
                    mgmt_read    <= 1'b0;
                end
                drain_sectors = drain_sectors + 1;
                while (request[1]) @(posedge clk);
            end
        end
    end

    // ---- I/O helpers -------------------------------------------------------
    task io_wr(input [2:0] a, input [7:0] d);
    begin
        @(posedge clk);
        io_address   <= a;
        io_writedata <= d;
        io_write     <= 1'b1;      // 1-clk pulse (Peripherals gives a 1-clk edge)
        @(posedge clk);
        io_write     <= 1'b0;
        @(posedge clk);
        @(posedge clk);
    end
    endtask

    task io_rd(input [2:0] a, output [7:0] d);
    begin
        @(posedge clk);
        io_address <= a;
        io_read    <= 1'b1;
        @(posedge clk);
        @(posedge clk);            // io_readdata is registered from io_readdata_prepare
        d = io_readdata;
        io_read    <= 1'b0;
        @(posedge clk);
    end
    endtask

    // send an FDC command/param byte, gated by MSR (RQM=1, DIO=0)
    integer nwait;
    reg [7:0] msr;
    task nec_chip(input [7:0] d);
    begin
        nwait = 0;
        msr = 8'h00;
        while (!(msr[7] && !msr[6]) && nwait < 100000) begin
            io_rd(3'd4, msr);
            nwait = nwait + 1;
        end
        if (nwait >= 100000) $display("  nec_chip TIMEOUT waiting RQM for 0x%02h (msr=0x%02h)", d, msr);
        io_wr(3'd5, d);
    end
    endtask

    // read one result byte, gated by MSR (RQM=1, DIO=1)
    task nec_result(output [7:0] d);
    begin
        nwait = 0;
        msr = 8'h00;
        while (!(msr[7] && msr[6]) && nwait < 100000) begin
            io_rd(3'd4, msr);
            nwait = nwait + 1;
        end
        io_rd(3'd5, d);
    end
    endtask

    task mgmt_wr(input [3:0] a, input [15:0] d);
    begin
        @(posedge clk);
        mgmt_address <= a; mgmt_writedata <= d; mgmt_fddn <= 1'b0; mgmt_write <= 1'b1;
        @(posedge clk);
        mgmt_write <= 1'b0;
        @(posedge clk);
    end
    endtask

    // wait for irq to rise (command completion / seek done), then clear it by
    // reading the status the way the BIOS would (SENSE INTERRUPT or result).
    task wait_irq(input integer maxc, output integer ok);
        integer c;
    begin
        ok = 0; c = 0;
        while (!irq && c < maxc) begin @(posedge clk); c = c + 1; end
        ok = irq;
    end
    endtask

    // ---- MAIN --------------------------------------------------------------
    integer ok, k, bad;
    reg [7:0] rb;
    initial begin
        rst_n = 1'b0;
        repeat (20) @(posedge clk);
        rst_n = 1'b1;
        repeat (20) @(posedge clk);

        // mount a 360K DS image, NOT write-protected
        mgmt_wr(4'd0, 16'h0001);   // present
        mgmt_wr(4'd1, 16'h0000);   // not write protected
        mgmt_wr(4'd2, 16'd40);     // cylinders
        mgmt_wr(4'd3, 16'd9);      // sectors/track
        mgmt_wr(4'd4, 16'd720);    // total sectors
        mgmt_wr(4'd5, 16'd2);      // heads
        repeat (10) @(posedge clk);

        // RESET via DOR: assert then release with enable, wait the reset irq
        io_wr(3'd2, 8'h08);        // enable=0 (reset asserted), int enable
        io_wr(3'd2, 8'h0C);        // enable=1 -> reset interrupt
        wait_irq(200000, ok);
        $display("[phase] RESET  irq=%0d", ok);
        nec_chip(8'h08);           // SENSE INTERRUPT
        nec_result(rb); nec_result(rb);

        // SPECIFY (DMA mode: ND bit = 0)
        $display("[phase] SPECIFY");
        nec_chip(8'h03);
        nec_chip(8'hCF);
        nec_chip(8'h02);

        // motor on + DMA + enable + drive0
        io_wr(3'd2, 8'h1C);
        repeat (10) @(posedge clk);
        dma_enabled = 1'b1;

        // RECALIBRATE
        $display("[phase] RECALIBRATE");
        nec_chip(8'h07);
        nec_chip(8'h00);
        wait_irq(400000, ok);
        $display("           recal irq=%0d", ok);

        // SEEK to cyl 0
        $display("[phase] SEEK");
        nec_chip(8'h0F);
        nec_chip(8'h00);
        nec_chip(8'h00);
        wait_irq(400000, ok);
        $display("           seek irq=%0d", ok);
        nec_chip(8'h08);           // SENSE INTERRUPT
        nec_result(rb); nec_result(rb);

        // WRITE DATA (func 0xC5), 8 params
        $display("[phase] WRITE DATA");
        nec_chip(8'hC5);           // MT|MFM|WRITE
        nec_chip(8'h00);           // HDS head0 drive0
        nec_chip(8'h00);           // C
        nec_chip(8'h00);           // H
        nec_chip(8'h01);           // R
        nec_chip(8'h02);           // N=2 (512)
        nec_chip(8'h01);           // EOT
        nec_chip(8'h2A);           // GPL
        nec_chip(8'hFF);           // DTL  <- 9th byte triggers cmd_read_write_start

        // wait for the write to fill the FIFO, drain, and complete
        wait_irq(2000000, ok);
        $display("[phase] WRITE complete irq=%0d", ok);
        // read the 7 result bytes
        for (k = 0; k < 7; k = k + 1) nec_result(rb);

        repeat (200) @(posedge clk);

        // ---- report --------------------------------------------------------
        $display("");
        $display("---- observations ----");
        $display("  cmd_read_write_start (WRITE started) : %0d", rws_count);
        $display("  DACK pulses / DMA bytes delivered    : %0d / %0d", dack_pulses, dma_bytes);
        $display("  max write FIFO count                 : %0d", max_fifo);
        $display("  request[1] rises (mgmt_req[7])        : %0d", wr_req_rises);
        $display("  bytes drained to bridge              : %0d (sectors=%0d)", drained_count, drain_sectors);
        $display("  reached S_CHECK_TC                   : %0d", seen_check_tc);
        $display("  final state=%0d  dma_has_terminated=%0b", u_fdd.state, u_fdd.dma_has_terminated);

        bad = 0;
        if (drained_count == 512)
            for (k = 0; k < 512; k = k + 1) if (drained[k] !== src[k]) bad = bad + 1;

        $display("");
        if (rws_count > 0 && dma_bytes == 512 && wr_req_rises > 0 &&
            drained_count == 512 && bad == 0 && seen_check_tc && errors == 0)
            $display("RESULT: PASS (WRITE started; 512 bytes DMA'd to FIFO; request[1] rose; 512 drained intact; completed)");
        else if (rws_count == 0)
            $display("RESULT: FAIL - WRITE never started (cmd_read_write_start=0)");
        else if (wr_req_rises == 0)
            $display("RESULT: FAIL - FIFO never filled -> request[1]/mgmt_req[7] never rose (dma_bytes=%0d fifo_max=%0d)", dma_bytes, max_fifo);
        else
            $display("RESULT: FAIL - write datapath incomplete (rws=%0d dma=%0d req1=%0d drained=%0d mism=%0d tc=%0d errors=%0d)",
                     rws_count, dma_bytes, wr_req_rises, drained_count, bad, seen_check_tc, errors);
        $finish;
    end

    initial begin
        #500_000_000;
        $display("RESULT: FAIL - global timeout (rws=%0d dma=%0d req1=%0d)", rws_count, dma_bytes, wr_req_rises);
        $finish;
    end

endmodule
