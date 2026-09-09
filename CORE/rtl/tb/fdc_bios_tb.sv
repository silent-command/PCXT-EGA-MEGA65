// fdc_bios_tb.sv
//
// End-to-end simulation of the CPU-visible FDC behaviour during a DOS floppy
// READ, to find why the READ never starts on hardware (floppy.v
// cmd_read_write_start never pulses, DACK2 never fires, DOS says "drive not
// ready").
//
// It instantiates the REAL blocks that decide this:
//   * rtl/common/floppy.v          (+ simple_fifo.v)   -- the NEC765 model
//   * KFPC-XT/HDL/KF8259/*         -- the real PIC (edge/level as programmed)
// plus a VERBATIM copy of the Peripherals.sv fdd I/O-edge-latch glue and the
// IR6 = fdd_interrupt wiring, so the CPU-visible port timing matches the core.
// The DMA channel-2 datapath and the mgmt storage feed are modelled
// behaviourally against floppy.v's exact contracts (both already proven by
// fdc_dma_8237_tb.sv and mgmt_bridge_tb.sv), so this bench can concentrate on
// the command / interrupt handshake that those two benches never exercise.
//
// The behavioural CPU runs the "Super PC/Turbo XT BIOS v3.1" NEC 765 driver
// port sequence exactly:
//   program the 8259 (ICW1=0x13 EDGE-triggered, ICW2=8, ICW4=9, unmask IRQ6)
//   mount a 360K/DS image over mgmt page F2 (present,cyl=40,spt=9,total=720,heads=2)
//   RESET (DOR) -> wait IRQ6 -> SENSE INT
//   SPECIFY -> motor on (DOR) -> RECALIBRATE -> wait IRQ6 (NO sense int) ->
//   SEEK -> wait IRQ6 -> SENSE INT -> READ DATA (0xE6 + 8) with DMA -> wait IRQ6
// Every command byte is gated by the real MSR handshake (RQM=1, DIO=0); every
// wait-for-IRQ6 is serviced through the real 8259 (INTA x2 + non-specific EOI),
// exactly as the BIOS's int_E does.
//
//   powershell -File run_fdc_bios_tb.ps1            # upstream floppy.v (repro)
//   powershell -File run_fdc_bios_tb.ps1 -Fix       # overlay floppy.v (fix)
//
// Needs Vivado xsim (KF8259 is SystemVerilog Icarus rejects).

`timescale 1ns/10ps

module fdc_bios_tb;

    // ------------------------------------------------------------------ clock/reset
    logic clk = 1'b0;
    always #10 clk = ~clk;                 // 50 MHz chipset clock (matches pcxt_core)
    logic reset = 1'b1;

    // ------------------------------------------------------------------ results
    integer errors = 0;
    task check(input logic cond, input string msg);
        if (!cond) begin errors = errors + 1; $display("  CHECK FAILED: %s   (t=%0t)", msg, $time); end
    endtask

    // ==================================================================
    //  CPU bus (what the 8088 + Bus_Arbiter would present to Peripherals)
    // ==================================================================
    logic [19:0] address           = 20'h0;
    logic [7:0]  internal_data_bus = 8'h0;
    logic        io_read_n         = 1'b1;
    logic        io_write_n        = 1'b1;
    logic        address_enable_n  = 1'b0;   // I/O cycle (not a DMA-owned bus)
    logic        interrupt_acknowledge_n = 1'b1;

    // ------------------------------------------------------------------ chip-select decode (from Peripherals.sv)
    wire iorq = ~io_read_n | ~io_write_n;
    wire floppy0_chip_select_n = ~(~address_enable_n &&
                                   ((({address[15:2],2'd0} == 16'h03F0)) ||
                                    (({address[15:1],1'd0} == 16'h03F4)) ||
                                    ((address[15:0]        == 16'h03F7))));
    // 8259 lives at 0x20..0x3F (chip_select_n[1] in Peripherals' 0x00.. decode)
    wire interrupt_chip_select_n = ~(iorq && ~address_enable_n && ({address[15:5],5'd0} == 16'h0020));

    // ------------------------------------------------------------------ Peripherals fdd I/O glue (verbatim)
    logic       prev_io_read_n, prev_io_write_n;
    always_ff @(posedge clk) begin
        prev_io_read_n  <= io_read_n;
        prev_io_write_n <= io_write_n;
    end

    logic [7:0] write_to_fdd;
    always_ff @(posedge clk) begin
        if (~io_write_n) write_to_fdd <= internal_data_bus;
        else             write_to_fdd <= write_to_fdd;
    end

    logic [2:0] fdd_io_address;
    logic       fdd_io_read, fdd_io_read_1, fdd_io_write;
    always_ff @(posedge clk) begin
        fdd_io_address <= address[2:0];
        fdd_io_read    <= ~io_read_n & prev_io_read_n   & ~floppy0_chip_select_n;
        fdd_io_read_1  <= fdd_io_read;
        fdd_io_write   <= io_write_n & ~prev_io_write_n & ~floppy0_chip_select_n;
    end

    // DMA glue (Peripherals.sv fdd_dma_* equations)
    logic       fdd_dma_ack   = 1'b0;      // driven by behavioural 8237 model below
    logic       terminal_count= 1'b0;
    logic       prev_fdd_dma_ack;
    always_ff @(posedge clk) prev_fdd_dma_ack <= fdd_dma_ack;
    wire        fdd_dma_rw_ack = prev_fdd_dma_ack & ~fdd_dma_ack;
    wire        fdd_dma_read   = fdd_dma_ack & ~io_read_n;

    logic       fdd_dma_tc;
    always_ff @(posedge clk) begin
        if (fdd_dma_ack) fdd_dma_tc <= (fdd_dma_tc == 1'b0) ? terminal_count : fdd_dma_tc;
        else             fdd_dma_tc <= 1'b0;
    end

    // ------------------------------------------------------------------ mgmt bus (storage bridge side)
    logic [3:0]  mgmt_address = 4'd0;
    logic        mgmt_fddn    = 1'b0;
    logic        mgmt_write   = 1'b0;
    logic [15:0] mgmt_writedata = 16'd0;
    logic        mgmt_read    = 1'b0;
    wire  [15:0] mgmt_readdata;

    // ==================================================================
    //  REAL floppy.v
    // ==================================================================
    wire        fdd_dma_req_wire;
    wire [7:0]  fdd_dma_readdata;          // floppy.dma_writedata (device->mem byte)
    wire        fdd_interrupt;
    wire [7:0]  fdd_readdata_wire;
    wire [1:0]  fdd_request;

    floppy u_fdd (
        .clk           (clk),
        .rst_n         (~reset),
        .dma_req       (fdd_dma_req_wire),
        .dma_ack       (fdd_dma_rw_ack),
        .dma_tc        (fdd_dma_tc & fdd_dma_rw_ack),
        .dma_readdata  (write_to_fdd),
        .dma_writedata (fdd_dma_readdata),
        .irq           (fdd_interrupt),
        .io_address    (fdd_io_address),
        .io_read       (fdd_io_read),
        .io_readdata   (fdd_readdata_wire),
        .io_write      (fdd_io_write),
        .io_writedata  (write_to_fdd),
        .fdd0_inserted (),
        .mgmt_address  (mgmt_address),
        .mgmt_fddn     (mgmt_fddn),
        .mgmt_write    (mgmt_write),
        .mgmt_writedata(mgmt_writedata),
        .mgmt_read     (mgmt_read),
        .mgmt_readdata (mgmt_readdata),
        .wp            (2'b00),
        .clock_rate    (28'd20000),        // small so recal/seek step delays are short in sim
        .request       (fdd_request)
    );

    // fdd_readdata capture (Peripherals.sv)
    logic [7:0] fdd_readdata;
    always_ff @(posedge clk) begin
        if (fdd_io_read_1 && ~address_enable_n) fdd_readdata <= fdd_readdata_wire;
        else if (fdd_dma_read)                  fdd_readdata <= fdd_dma_readdata;
        else                                    fdd_readdata <= fdd_readdata;
    end

    // ==================================================================
    //  REAL KF8259  (IR6 = fdd_interrupt, exactly as Peripherals wires it)
    // ==================================================================
    wire [7:0] interrupt_data_bus_out;
    wire       interrupt_to_cpu;
    KF8259 u_KF8259 (
        .clock                   (clk),
        .reset                   (reset),
        .chip_select_n           (interrupt_chip_select_n),
        .read_enable_n           (io_read_n),
        .write_enable_n          (io_write_n),
        .address                 (address[0]),
        .data_bus_in             (internal_data_bus),
        .data_bus_out            (interrupt_data_bus_out),
        .data_bus_io             (),
        .cascade_in              (3'b000),
        .cascade_out             (),
        .cascade_io              (),
        .slave_program_n         (1'b1),
        .buffer_enable           (),
        .slave_program_or_enable_buffer (),
        .interrupt_acknowledge_n (interrupt_acknowledge_n),
        .interrupt_to_cpu        (interrupt_to_cpu),
        .interrupt_request       ({1'b0, fdd_interrupt, 6'b000000})   // {7, IR6=fdd, 5..0}
    );

    // ==================================================================
    //  CPU read-data mux (which device answers a read)
    // ==================================================================
    function [7:0] cpu_read_bus();
        if (~interrupt_chip_select_n) cpu_read_bus = interrupt_data_bus_out;
        else                          cpu_read_bus = fdd_readdata;   // floppy (0x3F0..0x3F7)
    endfunction

    // ==================================================================
    //  Probes into the real floppy
    // ==================================================================
    wire        p_cmd_read_write_start = u_fdd.cmd_read_write_start;
    wire        p_cmd_rw_ok_at_start   = u_fdd.cmd_read_write_ok_at_start;
    wire        p_cmd_rw_finish        = u_fdd.cmd_read_write_finish;
    wire [3:0]  p_state                = u_fdd.state;
    wire [9:0]  p_fifo_count           = u_fdd.fifo_count;
    wire        p_fifo_empty           = u_fdd.fifo_empty;
    wire        p_dma_has_terminated   = u_fdd.dma_has_terminated;
    integer fifo_wr_count = 0;
    integer seen_update = 0, seen_checktc = 0;
    always_ff @(posedge clk) begin
        if (mgmt_write && mgmt_address == 4'hF) fifo_wr_count <= fifo_wr_count + 1;
        if (p_state == 4'd7) seen_update  <= 1;
        if (p_state == 4'd8) seen_checktc <= 1;
    end

    integer rws_count = 0;                 // cmd_read_write_start pulses
    integer okstart_count = 0;
    integer mgmt_req_rises = 0;            // floppy read mgmt request rising edges
    integer dack_pulses = 0;               // DACK2 (fdd_dma_rw_ack) pulses
    integer int_to_cpu_rises = 0;
    integer fdd_irq_rises = 0;
    integer rw_finish_count = 0;
    reg     req0_q = 1'b0, i2c_q = 1'b0, firq_q = 1'b0;
    always_ff @(posedge clk) begin
        if (p_cmd_read_write_start) rws_count    <= rws_count + 1;
        if (p_cmd_rw_ok_at_start)   okstart_count<= okstart_count + 1;
        if (p_cmd_rw_finish)        rw_finish_count <= rw_finish_count + 1;
        req0_q <= fdd_request[0];
        if (fdd_request[0] && !req0_q) mgmt_req_rises <= mgmt_req_rises + 1;
        if (fdd_dma_rw_ack)            dack_pulses    <= dack_pulses + 1;
        i2c_q <= interrupt_to_cpu;
        if (interrupt_to_cpu && !i2c_q) int_to_cpu_rises <= int_to_cpu_rises + 1;
        firq_q <= fdd_interrupt;
        if (fdd_interrupt && !firq_q) fdd_irq_rises <= fdd_irq_rises + 1;
    end

    // ==================================================================
    //  Behavioural mgmt storage feeder (fills the read FIFO like mgmt_bridge)
    //  On floppy.request[0] (S_SD_READ_WAIT_FOR_DATA) push 512 bytes to mgmt 0xF.
    // ==================================================================
    function [7:0] fapat(input integer i);
        fapat = (( (i*5) + 8'h17 ) & 8'hFF) ^ 8'hA5;
    endfunction

    reg [7:0] fed [0:511];
    integer feeder_sectors = 0;
    initial begin : feeder
        integer i;
        forever begin
            @(posedge clk);
            if (fdd_request[0]) begin
                for (i = 0; i < 512; i = i + 1) begin
                    @(posedge clk);
                    mgmt_address   <= 4'hF;
                    mgmt_writedata <= {8'h00, fapat(i)};
                    mgmt_write     <= 1'b1;
                    fed[i] = fapat(i);
                    @(posedge clk);
                    mgmt_write     <= 1'b0;
                end
                feeder_sectors = feeder_sectors + 1;
                // one 512-byte sector per request; the floppy drops request[0] a
                // couple of clocks after the FIFO fills, so wait it out before
                // considering another sector (else we'd double-fill).
                while (fdd_request[0]) @(posedge clk);
            end
        end
    end

    // ==================================================================
    //  Behavioural DMA ch2 (device->memory), floppy.v contract
    //  (dma_req level; one byte per ack pulse popped on the ack edge; TC ends it)
    // ==================================================================
    logic       dma_enabled = 1'b0;
    reg [7:0]   dma_mem [0:511];
    integer     dma_bytes = 0;
    localparam integer DMA_COUNT = 512;    // BIOS programs 512-byte word count
    // capture the byte floppy presents on the ack pulse
    always_ff @(posedge clk) begin
        if (fdd_dma_rw_ack && dma_bytes < 512) begin
            dma_mem[dma_bytes] <= fdd_dma_readdata;
            dma_bytes <= dma_bytes + 1;
        end
    end
    // ack generator: assert fdd_dma_ack (level) then drop -> rw_ack pulse
    integer dma_st = 0, dma_hold = 0, dma_issued = 0;
    always_ff @(posedge clk) begin
        if (reset) begin
            fdd_dma_ack <= 1'b0; terminal_count <= 1'b0; dma_st <= 0; dma_hold <= 0; dma_issued <= 0;
        end else begin
            case (dma_st)
                0: begin
                    fdd_dma_ack <= 1'b0; terminal_count <= 1'b0;
                    if (dma_enabled && fdd_dma_req_wire && dma_issued < DMA_COUNT) begin
                        fdd_dma_ack    <= 1'b1;
                        terminal_count <= (dma_issued == DMA_COUNT-1);
                        dma_hold       <= 3;
                        dma_st         <= 1;
                    end
                end
                1: begin
                    if (dma_hold != 0) dma_hold <= dma_hold - 1;
                    else begin
                        fdd_dma_ack <= 1'b0;   // falling edge -> fdd_dma_rw_ack pulse next clk
                        dma_issued  <= dma_issued + 1;
                        dma_st      <= 2;
                    end
                end
                2: begin
                    terminal_count <= 1'b0;
                    dma_st <= 0;               // back to idle, wait next dma_req
                end
            endcase
        end
    end

    // ==================================================================
    //  CPU-side bus tasks (generous strobe widths cover the glue pipeline)
    // ==================================================================
    localparam integer STROBE = 8;         // clocks the strobe is held

    task automatic io_write(input [15:0] port, input [7:0] data);
        begin
            @(posedge clk);
            address           <= {4'h0, port};
            internal_data_bus <= data;
            io_write_n        <= 1'b0;
            repeat (STROBE) @(posedge clk);
            io_write_n        <= 1'b1;
            repeat (4) @(posedge clk);       // let the trailing-edge strobe propagate
        end
    endtask

    task automatic io_read(input [15:0] port, output [7:0] data);
        begin
            @(posedge clk);
            address    <= {4'h0, port};
            io_read_n  <= 1'b0;
            repeat (STROBE) @(posedge clk);
            data       = cpu_read_bus();     // sample after the pipeline has settled
            io_read_n  <= 1'b1;
            repeat (4) @(posedge clk);
        end
    endtask

    // ------------------------------------------------------------------ 8259 interrupt service (int_E equivalent)
    reg attention = 1'b0;                    // BIOS ds:3Eh bit7
    reg cpu_iena  = 1'b0;

    task automatic do_inta_and_isr();
        reg [7:0] junk;
        begin
            // Two INTA pulses (8086 mode). The 8259 latches ISR on the 1st and
            // ends the sequence on the 2nd.
            @(posedge clk); interrupt_acknowledge_n <= 1'b0;
            repeat (4) @(posedge clk); interrupt_acknowledge_n <= 1'b1;
            repeat (3) @(posedge clk); interrupt_acknowledge_n <= 1'b0;
            repeat (4) @(posedge clk); interrupt_acknowledge_n <= 1'b1;
            repeat (3) @(posedge clk);
            // int_E: raise attention flag, then non-specific EOI to the 8259.
            attention <= 1'b1;
            io_write(16'h0020, 8'h20);       // OCW2 non-specific EOI
        end
    endtask

    // service any pending interrupt (called from the nec_busy poll)
    task automatic service_if_pending();
        begin
            if (cpu_iena && interrupt_to_cpu) do_inta_and_isr();
        end
    endtask

    // ------------------------------------------------------------------ MSR handshake (nec_chip)
    // returns 0 = ok, 1 = timeout(RQM), 2 = DIO wrong
    task automatic nec_chip(input [7:0] data, output integer rc);
        reg [7:0] msr; integer n;
        begin
            rc = 0; n = 0;
            forever begin
                io_read(16'h03F4, msr);
                service_if_pending();
                if (msr[7]) break;           // RQM=1
                n = n + 1;
                if (n > 20000) begin rc = 1; return; end
            end
            if (msr[6]) begin rc = 2; return; end   // DIO must be 0 to write
            io_write(16'h03F5, data);
        end
    endtask

    // ------------------------------------------------------------------ result read (nec_status)
    task automatic nec_status(input integer nbytes, output integer got, ref [7:0] res [0:15]);
        reg [7:0] msr; integer n, i; logic done;
        begin
            got = 0; done = 0;
            for (i = 0; i < nbytes && !done; i = i + 1) begin
                n = 0;
                forever begin
                    io_read(16'h03F4, msr);
                    service_if_pending();
                    if (msr[7]) break;
                    n = n + 1;
                    if (n > 20000) begin done = 1; break; end
                end
                if (done) break;
                if (!msr[6]) begin done = 1; break; end   // DIO must be 1 to read
                io_read(16'h03F5, res[got]);
                got = got + 1;
                repeat (2) @(posedge clk);
                io_read(16'h03F4, msr);                   // re-check busy (bit4)
                if (!msr[4]) done = 1;                    // controller no longer busy -> result done
            end
        end
    endtask

    // ------------------------------------------------------------------ wait for interrupt (nec_busy)
    // returns 1 if the interrupt arrived, 0 on timeout
    task automatic nec_busy(output integer ok);
        integer n; reg [7:0] junk;
        begin
            ok = 0; n = 0;
            attention = 1'b0;
            forever begin
                service_if_pending();
                @(posedge clk);
                if (attention) begin ok = 1; break; end
                n = n + 1;
                if (n > 400000) begin ok = 0; break; end
            end
            attention = 1'b0;
        end
    endtask

    // ------------------------------------------------------------------ mgmt geometry mount
    task automatic mgmt_wr(input [3:0] a, input [15:0] d);
        begin
            @(posedge clk);
            mgmt_address <= a; mgmt_writedata <= d; mgmt_fddn <= 1'b0; mgmt_write <= 1'b1;
            @(posedge clk);
            mgmt_write <= 1'b0;
            @(posedge clk);
        end
    endtask

    // ==================================================================
    //  MAIN
    // ==================================================================
    integer rc, gotb, ok, i, bad;
    reg [7:0] res [0:15];
    integer seek_irq_ok = 0, recal_irq_ok = 0, reset_irq_ok = 0, read_irq_ok = 0;
    integer read_started = 0;
    integer aborted = 0;                 // BIOS nec_busy timeout does a non-local
                                         // return (pop ax) that aborts the request
    string  fail_phase = "";

    initial begin
        reset = 1'b1;
        repeat (20) @(posedge clk);
        reset = 1'b0;
        repeat (20) @(posedge clk);

        // --- program the 8259 exactly like the BIOS ---
        io_write(16'h0020, 8'h13);   // ICW1: edge, single, ICW4 needed
        io_write(16'h0021, 8'h08);   // ICW2: vector base 8
        io_write(16'h0021, 8'h09);   // ICW4: 8086 mode, normal EOI
        io_write(16'h0021, 8'hBC);   // OCW1 mask: enable IRQ0/1/6
        cpu_iena = 1'b1;

        // --- mount a 360K DS image (720 blocks): present,cyl40,spt9,total720,heads2 ---
        mgmt_wr(4'd0, 16'h0001);     // media present
        mgmt_wr(4'd1, 16'h0000);     // not write protected
        mgmt_wr(4'd2, 16'd40);       // cylinders
        mgmt_wr(4'd3, 16'd9);        // sectors/track
        mgmt_wr(4'd4, 16'd720);      // total sectors
        mgmt_wr(4'd5, 16'd2);        // heads
        repeat (10) @(posedge clk);

        // ================= BIOS @@reset =================
        $display("[phase] RESET");
        io_write(16'h03F2, 8'h08);   // DOR: int on, RESET asserted (enable=0)
        io_write(16'h03F2, 8'h0C);   // DOR: enable=1  -> reset interrupt
        nec_busy(ok); reset_irq_ok = ok;
        if (!ok) begin fail_phase = "reset-wait-irq"; aborted = 1; end
        // sense interrupt (reset_sensei)
        if (!aborted) begin
            nec_chip(8'h08, rc);
            nec_status(2, gotb, res);
        end

        // SPECIFY 0x03, SRT/HUT=0xCF, HLT/ND=0x02 (DMA mode)
        if (!aborted) begin
            $display("[phase] SPECIFY");
            nec_chip(8'h03, rc);
            nec_chip(8'hCF, rc);
            nec_chip(8'h02, rc);

            // ================= BIOS @@service =================
            // motor on + drive0 + DMA + enable
            io_write(16'h03F2, 8'h1C);   // DOR: motor0, dma, enable, drive0
            repeat (10) @(posedge clk);
            dma_enabled = 1'b1;

            // RECALIBRATE 0x07, drive0  (NO sense interrupt afterwards!)
            $display("[phase] RECALIBRATE");
            nec_chip(8'h07, rc);
            nec_chip(8'h00, rc);
            nec_busy(ok); recal_irq_ok = ok;
            if (!ok) begin fail_phase = "recal-wait-irq"; aborted = 1; end
        end

        // SEEK 0x0F, drive0, cyl0
        if (!aborted) begin
            $display("[phase] SEEK");
            nec_chip(8'h0F, rc);
            nec_chip(8'h00, rc);
            nec_chip(8'h00, rc);
            nec_busy(ok); seek_irq_ok = ok;
            // BIOS: a nec_busy timeout aborts the whole INT 13h request (pop ax),
            // so READ DATA is never issued -- exactly what "drive not ready" is.
            if (!ok) begin fail_phase = "seek-wait-irq"; aborted = 1; end
            else begin
                nec_chip(8'h08, rc);          // sense interrupt after seek
                nec_status(2, gotb, res);
            end
        end

        // ================= READ DATA =================
        // Only reachable if the seek interrupt arrived. 0xE6 + C,H,R,N,EOT,GPL,DTL
        if (!aborted) begin
            $display("[phase] READ DATA");
            nec_chip(8'hE6, rc);              // MT|MFM|SK|READ
            nec_chip(8'h00, rc);              // HDS: head0 drive0
            nec_chip(8'h00, rc);              // C = 0
            nec_chip(8'h00, rc);              // H = 0
            nec_chip(8'h01, rc);              // R = 1
            nec_chip(8'h02, rc);              // N = 2 (512)
            nec_chip(8'h01, rc);              // EOT = 1
            nec_chip(8'h2A, rc);              // GPL
            nec_chip(8'hFF, rc);              // DTL  <- 9th byte -> cmd_read_write_start
            // wait for the read-completion interrupt + read result phase
            nec_busy(ok); read_irq_ok = ok;
            if (ok) nec_status(7, gotb, res);
        end
        read_started = (rws_count > 0);

        repeat (200) @(posedge clk);

        // ------------------------------------------------------------------ RESULT
        $display("");
        $display("---- observations ----");
        $display("  reset  IRQ6 reached CPU : %0d", reset_irq_ok);
        $display("  recal  IRQ6 reached CPU : %0d", recal_irq_ok);
        $display("  seek   IRQ6 reached CPU : %0d", seek_irq_ok);
        $display("  read   IRQ6 reached CPU : %0d", read_irq_ok);
        $display("  interrupt_to_cpu rises  : %0d", int_to_cpu_rises);
        $display("  fdd_interrupt rises     : %0d", fdd_irq_rises);
        $display("  cmd_read_write_finish   : %0d", rw_finish_count);
        $display("  final fdd_interrupt=%0b  interrupt_to_cpu=%0b  state=%0d", fdd_interrupt, interrupt_to_cpu, p_state);
        $display("  fifo writes=%0d  final fifo_count=%0d empty=%0b  dma_has_terminated=%0b", fifo_wr_count, p_fifo_count, p_fifo_empty, p_dma_has_terminated);
        $display("  reached S_UPDATE_SECTOR=%0d  S_CHECK_TC=%0d", seen_update, seen_checktc);
        $display("  cmd_read_write_ok_start : %0d", okstart_count);
        $display("  cmd_read_write_start    : %0d   <-- READ actually started", rws_count);
        $display("  mgmt read-request rises : %0d", mgmt_req_rises);
        $display("  DACK2 pulses            : %0d", dack_pulses);
        $display("  DMA bytes moved         : %0d", dma_bytes);
        if (!seek_irq_ok)
            $display("  DIVERGENCE: floppy MSR at seek-wait = 0x%02h (RQM=%0b DIO=%0b), fdd_interrupt held=%0b",
                     {u_fdd.datareg_ready,u_fdd.transfer_to_cpu,u_fdd.execute_ndma,u_fdd.busy,u_fdd.in_seek_mode},
                     u_fdd.datareg_ready, u_fdd.transfer_to_cpu, fdd_interrupt);

        // check the DMA data if a read completed
        bad = 0;
        if (dma_bytes == 512)
            for (i = 0; i < 512; i = i + 1) if (dma_mem[i] !== fed[i]) bad = bad + 1;

        $display("");
        if (rws_count > 0 && dack_pulses >= 512 && dma_bytes == 512 && bad == 0 && errors == 0)
            $display("RESULT: PASS (READ started; %0d DACK2 pulses; 512 bytes moved intact)", dack_pulses);
        else if (rws_count == 0)
            $display("RESULT: FAIL - READ never started (cmd_read_write_start=0); diverged at phase '%s'", fail_phase);
        else
            $display("RESULT: FAIL - READ started but datapath incomplete (rws=%0d dack=%0d bytes=%0d mismatches=%0d errors=%0d)",
                     rws_count, dack_pulses, dma_bytes, bad, errors);
        $finish;
    end

    // global watchdog
    initial begin
        #500_000_000;
        $display("RESULT: FAIL - global timeout");
        $finish;
    end

endmodule
