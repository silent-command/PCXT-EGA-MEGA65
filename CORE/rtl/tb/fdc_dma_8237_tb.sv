// fdc_dma_8237_tb.sv
//
// Integration bench for the DMA channel-2 path that the chipset test suite
// deliberately skips (the KF8237 benches under KF8237/TESTBENCH no longer even
// match the port list, because they predate the cpu_ce_posedge/negedge inputs).
//
// The floppy SIDE of the transfer is already proven by mgmt_bridge_tb.sv, which
// drives the real floppy.v with hand-generated dma_ack / dma_tc. What has never
// been exercised in simulation is the OTHER side: the real KF8237 as it is
// wired in this port -- clocked by the real XT_CE_Generator at the default
// 4.77 MHz (clk_select = 0), arbitrated by the exact Bus_Arbiter hold FSM, and
// glued to the peripheral by the exact Peripherals.sv fdd_dma_* equations.
//
// So this bench keeps every one of those real blocks and replaces only the
// floppy with a synthetic channel-2 peripheral whose DMA contract matches
// floppy.v exactly:
//   * dma_req is a LEVEL, held high until the byte is consumed          (floppy.v:824)
//   * one byte moves per dma_ack pulse, popped on the ack EDGE          (floppy.v:854,866)
//   * dma_writedata carries the current FIFO byte                        (floppy.v:822)
//   * dma_tc ends the transfer                                           (floppy.v:834)
//
// It programs the 8237 for a channel-2 "write transfer" (device -> memory, the
// direction an INT 13h floppy READ uses), lets the DMA run, and checks that all
// N bytes land in the memory model in order, that the 8237 asserts terminal
// count on the last byte, and that HRQ/HLDA sequenced at all.
//
// RESULT: PASS / FAIL line at the end; the run script greps for PASS.
//
// Verified with Vivado xsim 2026.1 (Icarus 12 cannot compile the KF8237 -- see
// run_fdc_dma_8237_tb.ps1):
//   WAIT_STATES = 0  ->  RESULT: PASS  (HRQ pulses=32, bytes_written=32, tc_seen=1)
//   WAIT_STATES = 4  ->  RESULT: PASS  (8237 parks in SW for the ready wait,
//                                       still completes all 32 bytes with TC)
// i.e. the KF8237 channel-2 datapath, the HRQ/HLDA handshake, the cpu_ce
// clocking and the closed-loop ready are all functionally correct in isolation.

`timescale 1ns/10ps

module fdc_dma_8237_tb;

    // ---- clock / reset -----------------------------------------------------
    logic clock = 1'b0;
    always #5 clock = ~clock;               // 100 MHz tb clock; the real design
                                            // runs the chipset at 50 MHz but the
                                            // ratios are all cpu_ce-relative, so
                                            // any clock works for a functional test
    logic reset = 1'b1;

    // ---- pass/fail bookkeeping --------------------------------------------
    integer errors = 0;
    task check(input cond, input string msg);
        if (!cond) begin
            errors = errors + 1;
            $display("  CHECK FAILED: %s   (t=%0t)", msg, $time);
        end
    endtask

    // ---- real CE generator (XT_CE_Generator), clk_select = 0 (4.77 MHz) ----
    logic cpu_ce_posedge, cpu_ce_negedge, peripheral_ce, cpu_clk_pin;
    logic cycle_accrate;
    logic [7:0] ccc_div, ccc_dec;
    logic shift_read_timing;
    logic [1:0] rrwc, rwwc;

    XT_CE_Generator u_ce (
        .clock              (clock),
        .reset              (reset),
        .clk_select_load    (1'b0),
        .clk_select         (2'b00),
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
    logic         dma_ready;                       // from the ready model, below
    logic         hold_acknowledge;                // from the arbiter FSM, below
    logic [3:0]   dma_request;                     // {ch3, fdd_dma_req, ch1, ch0}
    logic [7:0]   dma_reg_din = 8'h00;             // CPU write data to 8237 regs
    logic [7:0]   dma_data_out;
    logic         reg_io_read_n = 1'b1;
    logic         reg_io_write_n = 1'b1;
    logic         dma_io_read_n, dma_io_write_n;
    logic [3:0]   reg_addr = 4'h0;
    logic [15:0]  dma_address_out;
    logic         dma_hold_request;                // HRQ
    logic [3:0]   dma_acknowledge_n;               // active-low DACK, Chipset naming
    logic         dma_memory_read_n, dma_memory_write_n;
    logic         terminal_count;                  // = KF8237.end_of_process_n_out

    KF8237 u_dma (
        .clock                  (clock),
        .cpu_ce_posedge         (cpu_ce_posedge),
        .cpu_ce_negedge         (cpu_ce_negedge),
        .reset                  (reset),
        .chip_select_n          (dma_chip_select_n),
        .ready                  (dma_ready),
        .hold_acknowledge       (hold_acknowledge),     // Bus_Arbiter passes
                                                        // hold_acknowledge & ~ext_access_request;
                                                        // ext_access_request = 0 at runtime
        .dma_request            (dma_request),
        .data_bus_in            (dma_reg_din),
        .data_bus_out           (dma_data_out),
        .io_read_n_in           (reg_io_read_n),
        .io_read_n_out          (dma_io_read_n),
        .io_read_n_io           (),
        .io_write_n_in          (reg_io_write_n),
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

    // terminal_count_n as Chipset.sv:341 forms it, fed to Peripherals as
    // `terminal_count` (active high at TC).
    wire terminal_count_n = ~terminal_count;

    // =======================================================================
    //  Bus_Arbiter hold FSM  -- copied verbatim from Bus_Arbiter.sv:52-127
    //  (ext_access_request = 0, so hold_request = dma_hold_request).
    // =======================================================================
    logic hold_request_ff_1, hold_request_ff_2;
    logic address_enable_n = 1'b1;
    logic dma_wait;

    // CPU is parked passive for the whole test so the bus is always grantable:
    // processor_status = 3'b111, processor_lock_n = 1 (Bus_Arbiter.sv:64).
    wire  cpu_passive = 1'b1;

    wire hold_request = dma_hold_request;   // ext_access_request tied 0

    always_ff @(posedge clock, posedge reset) begin
        if (reset)
            hold_request_ff_1 <= 1'b0;
        else if (cpu_ce_posedge)
            hold_request_ff_1 <= (cpu_passive & hold_request) ? 1'b1 : 1'b0;
    end
    always_ff @(posedge clock, posedge reset) begin
        if (reset)
            hold_request_ff_2 <= 1'b0;
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

    // =======================================================================
    //  Peripherals.sv fdd_dma_* glue  -- copied verbatim from
    //  Peripherals.sv:1625-1730, with `clock` = chipset clock.
    // =======================================================================
    logic         fdd_dma_req;          // latched request into the arbiter
    wire          fdd_dma_req_wire;      // synthetic peripheral raw dma_req
    logic         prev_fdd_dma_ack;
    wire          fdd_dma_ack = ~dma_acknowledge_n[2];      // Chipset.sv:502
    wire          fdd_dma_rw_ack = prev_fdd_dma_ack & ~fdd_dma_ack;   // Peripherals.sv:1662
    logic         fdd_dma_tc;
    wire          periph_tc = terminal_count_n;              // Peripherals input `terminal_count`

    always_ff @(posedge clock) prev_fdd_dma_ack <= fdd_dma_ack;   // Peripherals.sv:1659

    always_ff @(posedge clock) begin                             // Peripherals.sv:1664-1673
        if (fdd_dma_ack)
            if (fdd_dma_tc == 1'b0) fdd_dma_tc <= periph_tc;
            else                    fdd_dma_tc <= fdd_dma_tc;
        else
            fdd_dma_tc <= 1'b0;
    end

    always_ff @(posedge clock) begin                             // Peripherals.sv:1714-1721
        if (fdd_dma_ack)            fdd_dma_req <= 1'b0;
        else if (cpu_ce_negedge)   fdd_dma_req <= fdd_dma_req_wire;
        else                       fdd_dma_req <= fdd_dma_req;
    end

    // dma_request vector into the 8237, as Chipset.sv:372
    assign dma_request = {1'b0, fdd_dma_req, 1'b0, 1'b0};

    // =======================================================================
    //  Synthetic channel-2 peripheral -- matches floppy.v's DMA contract.
    // =======================================================================
    localparam int N = 32;                  // bytes to move (a floppy sector is
                                            // 512; 32 keeps the run short and
                                            // exercises the same loop + TC)
    logic [7:0] src [0:N-1];
    integer     src_idx;
    logic       run;                        // asserted by the test to start
    logic       tc_seen;

    integer i;
    initial for (i = 0; i < N; i = i + 1) src[i] = (i * 8'h13) ^ 8'h5A;

    // dma_req: level, high while bytes remain and TC not yet seen (floppy.v:824
    // holds dma_req until the FIFO drains / dma_has_terminated).
    assign fdd_dma_req_wire = run & (src_idx < N) & ~tc_seen;

    wire [7:0] dma_writedata = (src_idx < N) ? src[src_idx] : 8'h00;   // floppy.v:822

    always_ff @(posedge clock, posedge reset) begin
        if (reset) begin
            src_idx <= 0;
            tc_seen <= 1'b0;
        end
        else begin
            // pop one byte per ack edge (floppy.v pops the FIFO on
            // fifo_pc_rd = (~execute_ndma && dma_ack), i.e. the rw_ack edge)
            if (fdd_dma_rw_ack && src_idx < N)
                src_idx <= src_idx + 1;
            if (fdd_dma_tc)
                tc_seen <= 1'b1;
        end
    end

    // =======================================================================
    //  Memory model + ready.  Captures the DMA memory-write bytes.
    //  address = {page(=0), dma_address_out}; write when the 8237 pulses
    //  memory_write_n low with DACK2 active (Bus_Arbiter.sv address mux +
    //  RAM.sv write_command = ~memory_write_n).
    // =======================================================================
    logic [7:0] mem [0:65535];
    integer     bytes_written;

    // dma_ready model: WAIT_STATES chipset clocks of "not ready" per memory
    // cycle, then ready.  WAIT_STATES = 0 emulates zero-wait RAM; a nonzero
    // value emulates a slower HyperRAM answer to prove the 8237 parks in SW and
    // still completes (the closed-loop READY the port added).
    localparam int WAIT_STATES = 0;
    integer ready_cnt;
    always_ff @(posedge clock, posedge reset) begin
        if (reset)                       ready_cnt <= 0;
        else if (~dma_memory_write_n)    ready_cnt <= ready_cnt + 1;
        else                             ready_cnt <= 0;
    end
    assign dma_ready = (WAIT_STATES == 0) ? 1'b1 : (ready_cnt >= WAIT_STATES);

    logic prev_mem_wr_n;
    always_ff @(posedge clock, posedge reset) begin
        if (reset) begin
            prev_mem_wr_n <= 1'b1;
            bytes_written <= 0;
        end
        else begin
            prev_mem_wr_n <= dma_memory_write_n;
            // capture on the rising edge of memory_write_n (end of the write
            // strobe) while DACK2 is active -- the address and data are stable
            // through the strobe.
            if (prev_mem_wr_n == 1'b0 && dma_memory_write_n == 1'b1 && ~dma_acknowledge_n[2]) begin
                mem[dma_address_out] <= dma_writedata;
                bytes_written <= bytes_written + 1;
            end
        end
    end

    // ---- 8237 register-write helper (system-clock write pulse) -------------
    task dma_wr(input [3:0] a, input [7:0] d);
    begin
        @(posedge clock);
        dma_chip_select_n <= 1'b0;
        reg_addr          <= a;
        dma_reg_din       <= d;
        reg_io_write_n    <= 1'b0;
        @(posedge clock);
        @(posedge clock);
        reg_io_write_n    <= 1'b1;      // rising edge -> write_flag (Bus_Control_Logic)
        @(posedge clock);
        dma_chip_select_n <= 1'b1;
        @(posedge clock);
    end
    endtask

    // ---- program the 8237 for a channel-2 device->memory transfer ----------
    task program_ch2(input [15:0] addr, input [15:0] count);
    begin
        dma_wr(4'h8, 8'h00);            // command register: default
        dma_wr(4'hB, 8'h46);            // mode: single(01) incr(0) noauto(0)
                                        //       write-transfer(01) channel(10) = 0x46
        dma_wr(4'hC, 8'h00);            // clear byte pointer flip/flop
        dma_wr(4'h4, addr[7:0]);        // ch2 base/current address low
        dma_wr(4'h4, addr[15:8]);       //                        high
        dma_wr(4'h5, count[7:0]);       // ch2 base/current word count low
        dma_wr(4'h5, count[15:8]);      //                          high
        dma_wr(4'hA, 8'h02);            // set/reset mask: channel(10) clear-mask(0) -> unmask ch2
    end
    endtask

    // ---- timeout guard -----------------------------------------------------
    initial begin
        #4000000;
        $display("  TIMEOUT: DMA did not complete");
        errors = errors + 1;
        $display("RESULT: FAIL");
        $finish;
    end

    integer k;
    integer hrq_pulses;
    // count HRQ assertions to prove the handshake actually ran
    logic prev_hrq;
    always_ff @(posedge clock, posedge reset)
        if (reset) begin prev_hrq <= 1'b0; hrq_pulses <= 0; end
        else begin
            prev_hrq <= dma_hold_request;
            if (dma_hold_request && ~prev_hrq) hrq_pulses <= hrq_pulses + 1;
        end

    initial begin
        run = 1'b0;
        // release reset after a few CE cycles
        repeat (40) @(posedge clock);
        reset = 1'b0;
        repeat (40) @(posedge clock);

        $display("Programming KF8237 channel 2: addr=0x1000, count=%0d (N-1)", N-1);
        program_ch2(16'h1000, N-1);

        // let the mode/mask registers settle into the cpu_ce-clocked logic
        repeat (20) @(posedge clock);

        $display("Starting synthetic channel-2 DMA request...");
        run = 1'b1;

        // wait for the transfer to finish (all bytes popped and TC seen)
        k = 0;
        while (!(tc_seen && src_idx == N) && k < 200000) begin
            @(posedge clock);
            k = k + 1;
        end

        repeat (50) @(posedge clock);

        // ---- checks --------------------------------------------------------
        check(hrq_pulses > 0, "8237 asserted HRQ at least once");
        check(src_idx == N, "all N bytes were requested/acked by the peripheral");
        check(tc_seen, "terminal count reached the peripheral (dma_tc)");
        check(bytes_written == N, "exactly N bytes written to memory");

        for (k = 0; k < N; k = k + 1)
            check(mem[16'h1000 + k] === src[k], $sformatf("mem[0x%0h] == src[%0d]", 16'h1000 + k, k));

        $display("  HRQ pulses=%0d  bytes_written=%0d  src_idx=%0d  tc_seen=%0d  final_dma_addr=0x%0h",
                 hrq_pulses, bytes_written, src_idx, tc_seen, dma_address_out);

        if (errors == 0) $display("RESULT: PASS");
        else             $display("RESULT: FAIL (%0d errors)", errors);
        $finish;
    end

endmodule
