// fdc_dma_wr_tb.sv
//
// The MEMORY->DEVICE companion to fdc_dma_8237_tb.sv.
//
// fdc_dma_8237_tb proved the DEVICE->MEMORY direction (8237 channel-2
// "write transfer", the direction a floppy READ uses: DMA writes bytes INTO
// memory). That direction works on hardware.
//
// This bench exercises the OTHER direction, the one a floppy WRITE uses and
// which has NEVER run on hardware or in simulation: 8237 channel-2
// "read transfer" (memory -> device). The 8237 reads a byte FROM memory and
// strobes it into the peripheral. Crucially the memory here is the real
// MEGA65 path -- RAM.sv (closed-loop READY) + KFSDRAM.sv (byte Avalon on the
// SDRAM pins) + a variable-latency Avalon backend that emulates HyperRAM --
// and the real READY block generates the DMA `ready` (dma_ready) that parks
// the 8237 in SW until the memory read data is actually back.
//
// So it keeps every real block that decides a memory-read DMA:
//   * XT_CE_Generator  (clk_select = 0, 4.77 MHz)
//   * KF8237           (the real DMA controller)
//   * Bus_Arbiter hold FSM  (verbatim, as in fdc_dma_8237_tb)
//   * READY            (the real wait-state / dma_ready generator)
//   * RAM.sv + KFSDRAM (the real MEGA65 memory front-end, overlays)
//   * a small Avalon backend with a programmable read latency (HyperRAM model)
//   * the Peripherals.sv fdd_dma_* glue (write_to_fdd latch, rw_ack, tc)
// and replaces only the floppy with a synthetic channel-2 RECEIVER whose DMA
// contract matches floppy.v's write path exactly:
//   * dma_req is a LEVEL, held high while the write FIFO has room     (floppy.v:832)
//   * one byte is consumed per dma_ack pulse, captured on the ack EDGE(floppy.v:859,872)
//   * the byte it captures is write_to_fdd = internal_data_bus latched
//     while io_write_n is low (Peripherals.sv:1639-1645, :1684)
//   * dma_tc ends the transfer                                        (floppy.v:840)
//
// It programs the 8237 for a channel-2 read transfer (mode 0x4A), preloads the
// backend with a known 512-byte pattern at the DMA address, runs the DMA, and
// checks the receiver got all N bytes in order with TC.
//
// RESULT: PASS / FAIL line at the end; the run script greps for PASS.
//
// Vivado xsim only (RAM.sv/KFSDRAM/KF8237 use SystemVerilog Icarus rejects).

`timescale 1ns/10ps

module fdc_dma_wr_tb;

    // ---- knobs -------------------------------------------------------------
    localparam int N          = 512;    // a full floppy sector
    localparam int BASE       = 16'h1000;
    localparam int READ_LAT   = 30;     // Avalon read latency (HyperRAM-ish)
    localparam int WAITREQ    = 3;      // Avalon waitrequest cycles per access

    // ---- clock / reset -----------------------------------------------------
    logic clock = 1'b0;
    always #10 clock = ~clock;              // 50 MHz chipset clock
    logic reset = 1'b1;

    // ---- pass/fail bookkeeping --------------------------------------------
    integer errors = 0;
    task check(input cond, input string msg);
        if (!cond) begin
            errors = errors + 1;
            $display("  CHECK FAILED: %s   (t=%0t)", msg, $time);
        end
    endtask

    // ---- real CE generator, clk_select = 0 (4.77 MHz) ----------------------
    logic cpu_ce_posedge, cpu_ce_negedge, peripheral_ce, cpu_clk_pin;
    logic cycle_accrate;
    logic [7:0] ccc_div, ccc_dec;
    logic shift_read_timing;
    logic [1:0] rrwc, rwwc;
    localparam logic [1:0] CLK_SELECT = 2'b00;

    XT_CE_Generator u_ce (
        .clock              (clock),
        .reset              (reset),
        .clk_select_load    (1'b0),
        .clk_select         (CLK_SELECT),
        .cpu_clk_pin        (cpu_clk_pin),
        .cpu_ce_posedge     (cpu_ce_posedge),
        .cpu_ce_negedge     (cpu_ce_negedge),
        .peripheral_ce      (peripheral_ce),
        .cycle_accrate      (cycle_accrate),
        .clock_cycle_counter_division_ratio (ccc_div),
        .clock_cycle_counter_decrement_value(ccc_dec),
        .shift_read_timing  (shift_read_timing),
        .ram_read_wait_cycle (rrwc),
        .ram_write_wait_cycle(rwwc)
    );

    // ---- the real KF8237 ---------------------------------------------------
    logic         dma_chip_select_n = 1'b1;
    logic         dma_ready;                       // from READY
    logic         hold_acknowledge;
    logic [3:0]   dma_request;
    logic [7:0]   dma_reg_din = 8'h00;             // CPU write data to 8237 regs
    logic [7:0]   dma_data_out;
    logic         reg_io_read_n = 1'b1;
    logic         reg_io_write_n = 1'b1;
    logic         dma_io_read_n, dma_io_write_n;
    logic [3:0]   reg_addr = 4'h0;
    logic [15:0]  dma_address_out;
    logic         dma_hold_request;
    logic [3:0]   dma_acknowledge_n;
    logic         dma_memory_read_n, dma_memory_write_n;
    logic         terminal_count;

    // internal_data_bus mux (see below) feeds the 8237 register data path
    logic [7:0]   internal_data_bus;

    // command signals, as Bus_Arbiter forms them (CPU passive). Declared here
    // because the KF8237 instantiation below reads io_read_n/io_write_n.
    logic programming = 1'b0;
    wire io_write_n     = programming ? reg_io_write_n : dma_io_write_n;
    wire io_read_n      = programming ? reg_io_read_n  : dma_io_read_n;
    wire memory_read_n  = dma_memory_read_n;
    wire memory_write_n = dma_memory_write_n;

    KF8237 u_dma (
        .clock                  (clock),
        .cpu_ce_posedge         (cpu_ce_posedge),
        .cpu_ce_negedge         (cpu_ce_negedge),
        .reset                  (reset),
        .chip_select_n          (dma_chip_select_n),
        .ready                  (dma_ready),
        .hold_acknowledge       (hold_acknowledge),
        .dma_request            (dma_request),
        .data_bus_in            (internal_data_bus),
        .data_bus_out           (dma_data_out),
        .io_read_n_in           (io_read_n),
        .io_read_n_out          (dma_io_read_n),
        .io_read_n_io           (),
        .io_write_n_in          (io_write_n),
        .io_write_n_out         (dma_io_write_n),
        .io_write_n_io          (),
        .end_of_process_n_in    (1'b1),
        .end_of_process_n_out   (terminal_count),
        .address_in             (reg_addr),
        .address_out            (dma_address_out),
        .output_highst_address  (),
        .hold_request           (dma_hold_request),
        .dma_acknowledge        (dma_acknowledge_n),
        .address_enable         (),
        .address_strobe         (),
        .memory_read_n          (dma_memory_read_n),
        .memory_write_n         (dma_memory_write_n)
    );

    wire terminal_count_n = ~terminal_count;

    // =======================================================================
    //  Bus_Arbiter hold FSM  -- verbatim from Bus_Arbiter.sv:52-127
    // =======================================================================
    logic hold_request_ff_1, hold_request_ff_2;
    logic address_enable_n = 1'b1;
    logic dma_wait;
    wire  cpu_passive = 1'b1;
    wire  hold_request = dma_hold_request;

    always_ff @(posedge clock, posedge reset) begin
        if (reset)               hold_request_ff_1 <= 1'b0;
        else if (cpu_ce_posedge) hold_request_ff_1 <= (cpu_passive & hold_request) ? 1'b1 : 1'b0;
    end
    always_ff @(posedge clock, posedge reset) begin
        if (reset)                    hold_request_ff_2 <= 1'b0;
        else if (cpu_ce_negedge)
            if (~hold_request)          hold_request_ff_2 <= 1'b0;
            else if (hold_request_ff_2) hold_request_ff_2 <= 1'b1;
            else                        hold_request_ff_2 <= hold_request_ff_1;
    end
    assign hold_acknowledge = (hold_request) ? (hold_request_ff_1 | hold_request_ff_2) : 1'b0;

    always_ff @(posedge clock, posedge reset) begin
        if (reset)                address_enable_n <= 1'b1;
        else if (cpu_ce_posedge)  address_enable_n <= hold_acknowledge;
    end
    always_ff @(posedge clock, posedge reset) begin
        if (reset)                dma_wait <= 1'b0;
        else if (cpu_ce_posedge)  dma_wait <= address_enable_n;
    end
    wire dma_enable_n = ~(dma_wait & address_enable_n);
    wire dma_wait_n   = ~dma_wait;

    // dma_request vector into the 8237, as Chipset.sv (ch2 = fdd)
    logic       fdd_dma_req;
    wire        fdd_dma_req_wire;
    assign dma_request = {1'b0, fdd_dma_req, 1'b0, 1'b0};

    // =======================================================================
    //  DMA address onto the memory bus (Bus_Arbiter address mux, page 0)
    // =======================================================================
    wire [19:0] mem_address = {4'h0, dma_address_out};

    // =======================================================================
    //  REAL READY  (generates dma_ready that parks the 8237 in SW)
    // =======================================================================
    logic memory_access_ready;
    logic processor_ready;
    wire  io_channel_ready = memory_access_ready;   // the other AND terms are 1

    READY u_READY (
        .clock              (clock),
        .cpu_ce_posedge     (cpu_ce_posedge),
        .cpu_ce_negedge     (cpu_ce_negedge),
        .reset              (reset),
        .processor_ready    (processor_ready),
        .dma_ready          (dma_ready),
        .dma_wait_n         (dma_wait_n),
        .io_channel_ready   (io_channel_ready),
        .io_read_n          (io_read_n),
        .io_write_n         (io_write_n),
        .memory_read_n      (memory_read_n),
        .memory_write_n     (memory_write_n),
        .dma0_acknowledge_n (dma_acknowledge_n[0]),
        .address_enable_n   (address_enable_n),
        .clk_select         (CLK_SELECT)
    );

    // =======================================================================
    //  REAL RAM.sv + KFSDRAM + Avalon backend (HyperRAM model)
    // =======================================================================
    logic [7:0]  internal_data_bus_ram;
    logic        ram_address_select_n;

    // SDRAM pins re-purposed as the byte Avalon bus by KFSDRAM
    wire  [12:0] sdram_address;
    wire         sdram_cke, sdram_cs, sdram_ras, sdram_cas, sdram_we;
    wire  [1:0]  sdram_ba;
    wire  [15:0] sdram_dq_out;
    logic [15:0] sdram_dq_in;
    wire         sdram_dq_io, sdram_ldqm, sdram_udqm;

    logic [6:0]  map_ems [0:3];
    initial for (int i=0;i<4;i++) map_ems[i]=7'd0;

    RAM u_RAM (
        .clock              (clock),
        .reset              (reset),
        .enable_sdram       (1'b1),
        .initilized_sdram   (),
        .address            (mem_address),
        .internal_data_bus  (internal_data_bus),
        .data_bus_out       (internal_data_bus_ram),
        .word_read_request  (1'b0),
        .word_write_request (1'b0),
        .data_bus_in_word   (16'h0000),
        .data_bus_out_word  (),
        .memory_read_n      (memory_read_n),
        .memory_write_n     (memory_write_n),
        .no_command_state   (memory_read_n & memory_write_n),
        .memory_access_ready(memory_access_ready),
        .ram_address_select_n(ram_address_select_n),
        .sdram_address      (sdram_address),
        .sdram_cke          (sdram_cke),
        .sdram_cs           (sdram_cs),
        .sdram_ras          (sdram_ras),
        .sdram_cas          (sdram_cas),
        .sdram_we           (sdram_we),
        .sdram_ba           (sdram_ba),
        .sdram_dq_in        (sdram_dq_in),
        .sdram_dq_out       (sdram_dq_out),
        .sdram_dq_io        (sdram_dq_io),
        .sdram_ldqm         (sdram_ldqm),
        .sdram_udqm         (sdram_udqm),
        .map_ems            (map_ems),
        .ems_b1             (1'b0),
        .ems_b2             (1'b0),
        .ems_b3             (1'b0),
        .ems_b4             (1'b0),
        .umb_enabled        (1'b0),
        .bios_protect_flag  (3'b000),
        .wait_count_clk_en  (cpu_ce_posedge),
        .ram_read_wait_cycle (2'b00),
        .ram_write_wait_cycle(2'b00),
        .clk_select         (CLK_SELECT)
    );

    // ---- Avalon-MM backend on the KFSDRAM byte bus -------------------------
    //   avm_address = {sdram_dq_out[15:9], sdram_ba, sdram_address}
    //   avm_write   = ~sdram_we ; avm_read = ~sdram_ras
    //   avm_writedata = sdram_dq_out[7:0]
    //   sdram_dq_in[7:0]=readdata [8]=waitrequest [9]=readdatavalid
    wire [21:0] avm_address   = {sdram_dq_out[15:9], sdram_ba, sdram_address};
    wire        avm_write     = ~sdram_we;
    wire        avm_read      = ~sdram_ras;
    wire [7:0]  avm_writedata = sdram_dq_out[7:0];

    logic [7:0] bmem [0:65535];
    logic       waitrequest;
    logic       readdatavalid;
    logic [7:0] readdata;

    // waitrequest: hold for WAITREQ cycles at the start of each fresh access
    integer wr_cnt;
    logic   prev_access;
    wire    access = avm_read | avm_write;
    always_ff @(posedge clock, posedge reset) begin
        if (reset) begin wr_cnt <= WAITREQ; prev_access <= 1'b0; end
        else begin
            prev_access <= access;
            if (~access)                 wr_cnt <= WAITREQ;
            else if (wr_cnt != 0)        wr_cnt <= wr_cnt - 1;
        end
    end
    assign waitrequest = access & (wr_cnt != 0);
    wire   avm_accept  = access & ~waitrequest;

    // reads: after acceptance, schedule readdatavalid READ_LAT cycles later
    // (a tiny pipeline of pending responses; RAM.sv asks for at most 2 beats)
    logic [7:0]  rd_pipe_data  [0:63];
    logic        rd_pipe_valid [0:63];
    integer      k2;
    always_ff @(posedge clock, posedge reset) begin
        if (reset) begin
            readdatavalid <= 1'b0; readdata <= 8'h00;
            for (k2=0;k2<64;k2++) begin rd_pipe_valid[k2] <= 1'b0; rd_pipe_data[k2] <= 8'h00; end
        end else begin
            // shift the delay pipe
            readdatavalid <= rd_pipe_valid[0];
            readdata      <= rd_pipe_data[0];
            for (k2=0;k2<63;k2++) begin
                rd_pipe_valid[k2] <= rd_pipe_valid[k2+1];
                rd_pipe_data[k2]  <= rd_pipe_data[k2+1];
            end
            rd_pipe_valid[63] <= 1'b0;
            rd_pipe_data[63]  <= 8'h00;
            // accept a read -> insert its response at slot READ_LAT-1
            if (avm_read & ~waitrequest) begin
                rd_pipe_valid[READ_LAT-1] <= 1'b1;
                rd_pipe_data[READ_LAT-1]  <= bmem[avm_address[15:0]];
            end
            // writes commit immediately on acceptance
            if (avm_write & ~waitrequest)
                bmem[avm_address[15:0]] <= avm_writedata;
        end
    end

    assign sdram_dq_in = {6'h00, readdatavalid, waitrequest, readdata};

    // =======================================================================
    //  internal_data_bus mux (Bus_Arbiter + Chipset, the DMA-read subset)
    // =======================================================================
    //   * programming: CPU register data to the 8237
    //   * DMA memory read: the RAM byte (Chipset.sv:601-604 -> Bus_Arbiter else)
    always_comb begin
        if (programming)
            internal_data_bus = dma_reg_din;
        else if ((~ram_address_select_n) && (~memory_read_n))
            internal_data_bus = internal_data_bus_ram;
        else
            internal_data_bus = 8'h00;
    end

    // =======================================================================
    //  Peripherals.sv fdd_dma_* glue (verbatim subset) + write_to_fdd latch
    // =======================================================================
    logic [7:0] write_to_fdd;
    always_ff @(posedge clock) begin
        if (~io_write_n) write_to_fdd <= internal_data_bus;   // Peripherals.sv:1641
        else             write_to_fdd <= write_to_fdd;
    end

    logic       prev_fdd_dma_ack;
    wire        fdd_dma_ack    = ~dma_acknowledge_n[2];
    wire        fdd_dma_rw_ack = prev_fdd_dma_ack & ~fdd_dma_ack;
    logic       fdd_dma_tc;
    wire        periph_tc      = terminal_count_n;

    always_ff @(posedge clock) prev_fdd_dma_ack <= fdd_dma_ack;

    always_ff @(posedge clock) begin
        if (fdd_dma_ack)
            if (fdd_dma_tc == 1'b0) fdd_dma_tc <= periph_tc;
            else                    fdd_dma_tc <= fdd_dma_tc;
        else
            fdd_dma_tc <= 1'b0;
    end

    always_ff @(posedge clock) begin
        if (fdd_dma_ack)          fdd_dma_req <= 1'b0;
        else if (cpu_ce_negedge)  fdd_dma_req <= fdd_dma_req_wire;
        else                      fdd_dma_req <= fdd_dma_req;
    end

    // =======================================================================
    //  Synthetic channel-2 RECEIVER -- floppy.v write-path contract
    // =======================================================================
    logic [7:0] recv [0:N-1];
    integer     recv_idx;
    logic       run;
    logic       tc_seen;

    // dma_req: level, high while room remains and TC not yet seen (floppy.v:832
    // holds it while fifo not full in S_WAIT_FOR_FULL_WRITE_FIFO).
    assign fdd_dma_req_wire = run & (recv_idx < N) & ~tc_seen;

    always_ff @(posedge clock, posedge reset) begin
        if (reset) begin
            recv_idx <= 0;
            tc_seen  <= 1'b0;
        end else begin
            // capture one byte per ack edge -- floppy pushes write_to_fdd into
            // the fifo on dma_ack (fifo_pc_wr, floppy.v:859,872).
            if (fdd_dma_rw_ack && recv_idx < N) begin
                recv[recv_idx] <= write_to_fdd;
                recv_idx <= recv_idx + 1;
            end
            if (fdd_dma_tc) tc_seen <= 1'b1;
        end
    end

    // ---- 8237 register-write helper ----------------------------------------
    task dma_wr(input [3:0] a, input [7:0] d);
    begin
        @(posedge clock);
        programming       <= 1'b1;
        dma_chip_select_n <= 1'b0;
        reg_addr          <= a;
        dma_reg_din       <= d;
        reg_io_write_n    <= 1'b0;
        @(posedge clock);
        @(posedge clock);
        reg_io_write_n    <= 1'b1;
        @(posedge clock);
        dma_chip_select_n <= 1'b1;
        @(posedge clock);
        programming       <= 1'b0;
        @(posedge clock);
    end
    endtask

    // ---- program the 8237 for a channel-2 memory->device read transfer -----
    task program_ch2(input [15:0] addr, input [15:0] count);
    begin
        dma_wr(4'h8, 8'h00);            // command register: default
        dma_wr(4'hB, 8'h4A);            // mode: single(01) incr(0) noauto(0)
                                        //       read-transfer(10) channel(10) = 0x4A
        dma_wr(4'hC, 8'h00);            // clear byte pointer flip/flop
        dma_wr(4'h4, addr[7:0]);        // ch2 base/current address low
        dma_wr(4'h4, addr[15:8]);       //                        high
        dma_wr(4'h5, count[7:0]);       // ch2 base/current word count low
        dma_wr(4'h5, count[15:8]);      //                          high
        dma_wr(4'hA, 8'h02);            // unmask ch2
    end
    endtask

    // ---- pattern -----------------------------------------------------------
    function [7:0] pat(input integer i);
        pat = (( (i*7) + 8'h11 ) & 8'hFF) ^ 8'h3C;
    endfunction

    // ---- timeout guard -----------------------------------------------------
    initial begin
        #40000000;
        $display("  TIMEOUT: DMA did not complete (recv_idx=%0d tc_seen=%0d)", recv_idx, tc_seen);
        errors = errors + 1;
        $display("RESULT: FAIL");
        $finish;
    end

    integer hrq_pulses;
    logic prev_hrq;
    always_ff @(posedge clock, posedge reset)
        if (reset) begin prev_hrq <= 1'b0; hrq_pulses <= 0; end
        else begin
            prev_hrq <= dma_hold_request;
            if (dma_hold_request && ~prev_hrq) hrq_pulses <= hrq_pulses + 1;
        end

    integer k, bad;
    initial begin
        run = 1'b0;
        // preload the backend
        for (k = 0; k < N; k = k + 1) bmem[BASE + k] = pat(k);

        repeat (40) @(posedge clock);
        reset = 1'b0;
        repeat (80) @(posedge clock);       // let KFSDRAM leave INIT -> IDLE

        $display("Programming KF8237 channel 2 (mode 0x4A read-transfer): addr=0x%0h count=%0d", BASE, N-1);
        program_ch2(BASE[15:0], N-1);
        repeat (20) @(posedge clock);

        $display("Starting channel-2 memory->device DMA (READ_LAT=%0d WAITREQ=%0d)...", READ_LAT, WAITREQ);
        run = 1'b1;

        k = 0;
        while (!(tc_seen && recv_idx == N) && k < 2000000) begin
            @(posedge clock);
            k = k + 1;
        end
        repeat (50) @(posedge clock);

        check(hrq_pulses > 0,        "8237 asserted HRQ at least once");
        check(recv_idx == N,         "all N bytes were acked by the receiver");
        check(tc_seen,               "terminal count reached the receiver (dma_tc)");

        bad = 0;
        for (k = 0; k < N && k < recv_idx; k = k + 1)
            if (recv[k] !== pat(k)) begin
                bad = bad + 1;
                if (bad <= 8) $display("  byte[%0d] got 0x%02h expected 0x%02h", k, recv[k], pat(k));
            end
        check(bad == 0, "every received byte matches memory");

        $display("  HRQ pulses=%0d  recv_idx=%0d  tc_seen=%0d  mismatches=%0d  final_addr=0x%0h",
                 hrq_pulses, recv_idx, tc_seen, bad, dma_address_out);

        if (errors == 0) $display("RESULT: PASS");
        else             $display("RESULT: FAIL (%0d errors)", errors);
        $finish;
    end

endmodule
