// mem_reset_stress_tb: the MEGA65 reset button against the PC's memory path, many times.
//
// Why: an R3 owner reported "faulty memory detected" from the BIOS RAM test after a soft reset
// (2026-10-04). ramtest_sys_tb's button scenario runs the real CPU and BIOS, which is slow: one
// press per run. This bench has no CPU. A master that behaves like the chipset's KFSDRAM overlay
// (one request at a time, held until accepted; at most two reads outstanding; NOT reset by the
// button, so it goes on waiting for every read it had accepted) drives random byte writes and
// reads into the same memory path the system bench uses (ramtest_mem_model with G_REAL = 1:
// mem_backend -> avm_fifo -> arbiter with scaler and QNICE traffic -> hyperram_errata / _config /
// _ctrl -> HyperBus device model), and the framework's hr_rst is pulsed at random moments with
// random lengths, asynchronously to both clocks: with reads in flight, with a write on its way,
// with a request waiting, while the controller is still in its 150 us start-up after the
// previous reset.
//
// What must hold after every reset:
//   * every read that was accepted gets exactly one answer (the backend drains the ones the
//     reset killed with a dummy beat) - none missing (the hang of docs/reset-button.md), none
//     extra (an extra beat would shift every later answer by one read);
//   * once the master is going again, every read of a byte written after the reset returns
//     that byte. Writes from before the reset are forgotten: the reset may have thrown them
//     away, and after a real reset the BIOS writes before it reads.
//
//   xsim mem_reset_stress_sim -R -testplusarg RESETS=300 -testplusarg SEED=1
//
// Prints "RESULT: PASS" or "RESULT: FAIL" and the counts.
`timescale 1ns / 1ps

module mem_reset_stress_tb #(parameter int BIST = 0);   // BIST = 1: mem_backend's self test after every reset, as on the core

    logic clk_100 = 1'b1;  always #5  clk_100 = ~clk_100;     // HyperRAM side
    logic clk     = 1'b1;  always #10 clk     = ~clk;         // chipset side

    logic rst    = 1'b1;       // clock-lock reset: once
    logic hr_rst = 1'b1;       // the framework's hr_rst: the reset button

    logic [21:0] a  = 22'd0;
    logic [7:0]  wd = 8'd0;
    logic        wr = 1'b0, rd = 1'b0;
    wire  [7:0]  rdat;
    wire         rvalid, waitreq;

    ramtest_mem_model #(.G_SEED(1), .G_REAL(1), .G_BIST(BIST)) u_mem (
        .clk_i(clk), .rst_i(rst), .hr_clk_i(clk_100), .hr_rst_i(hr_rst),
        .avm_address_i(a), .avm_writedata_i(wd), .avm_write_i(wr), .avm_read_i(rd),
        .avm_readdata_o(rdat), .avm_readdatavalid_o(rvalid), .avm_waitrequest_o(waitreq),
        .rom_wr_i(1'b0), .rom_index_i(8'h00), .rom_addr_i(25'd0), .rom_data_i(16'h0000)
    );

    // ------------------------------------------------------------------ scoreboard
    logic [7:0] exp_mem [0:1048575];
    logic       known   [0:1048575];
    integer errors = 0, reads_ok = 0, reads_unknown = 0, writes = 0, resets_done = 0;
    integer extra_beats = 0, dummy_beats = 0;
    integer seed = 1, n_resets = 100;
    logic   debug = 1'b0;
    initial debug = $test$plusargs("DEBUG");

    // reads accepted and not yet answered, in order
    logic [19:0] q_addr [0:7];
    logic        q_dead [0:7];        // accepted before a reset: the answer is a dummy
    integer      q_head = 0, q_tail = 0, q_n = 0;

    time  t_last_reset = 0;
    logic master_run = 1'b0;          // the "CPU" is out of reset
    logic in_reset   = 1'b0;          // from the press until the master runs again

    // addresses: a few small windows, so that a byte is read soon after it was written and both
    // bytes of a 16-bit HyperRAM word are in play; one of them at 592 KB, where the report was
    function automatic logic [19:0] pick_addr();
        integer w;
        w = $urandom_range(0, 3);
        case (w)
            0: return 20'h08000 + $urandom_range(0, 63);
            1: return 20'h94000 + $urandom_range(0, 63);
            2: return 20'h00400 + $urandom_range(0, 31);
            default: return $urandom_range(0, 20'h9FFFF);
        endcase
    endfunction

    // answers
    always @(posedge clk) begin
        if (rvalid) begin
            if (q_n == 0) begin
                extra_beats++;
                errors++;
                if (extra_beats <= 5) $display("  *** EXTRA BEAT at %0t: readdatavalid with no read outstanding (data %02x)", $time, rdat);
                if (debug && extra_beats <= 5)
                    $display("      backend: out_count=%0d rst_all=%0d flush_valid=%0d s_readdatavalid=%0d rom_valid_q=%0d none_q=%0d hr_rst=%0d in_reset=%0d",
                             u_mem.i_backend.out_count, u_mem.i_backend.rst_all, u_mem.i_backend.flush_valid, u_mem.i_backend.s_readdatavalid,
                             u_mem.i_backend.rom_valid_q, u_mem.i_backend.none_q, hr_rst, in_reset);
                if (debug && extra_beats == 40) begin $display("  (debug: stopping after 40 extra beats)"); $finish; end
            end
            else begin
                if (q_dead[q_head]) dummy_beats++;
                else if (known[q_addr[q_head]]) begin
                    if (rdat !== exp_mem[q_addr[q_head]]) begin
                        errors++;
                        if (errors <= 10)
                            $display("  *** READ MISMATCH at %0t: %05x returned %02x, expected %02x (reset #%0d was %0t ago)",
                                     $time, q_addr[q_head], rdat, exp_mem[q_addr[q_head]], resets_done, $time - t_last_reset);
                    end
                    else reads_ok++;
                end
                else reads_unknown++;
                q_head = (q_head + 1) % 8;
                q_n    = q_n - 1;
            end
        end
    end

    // ------------------------------------------------------------------ the master
    task automatic do_write(input logic [19:0] ad, input logic [7:0] d);
        a <= {2'b00, ad}; wd <= d; wr <= 1'b1;
        do @(posedge clk); while (waitreq);
        wr <= 1'b0;
        // accepted: this is what the memory must hold from now on - unless a reset is under
        // way, in which case the byte may or may not arrive and nobody may rely on it
        if (in_reset) known[ad] = 1'b0;
        else begin exp_mem[ad] = d; known[ad] = 1'b1; end
        writes++;
    endtask

    task automatic issue_read(input logic [19:0] ad);
        a <= {2'b00, ad}; rd <= 1'b1;
        do @(posedge clk); while (waitreq);
        rd <= 1'b0;
        q_addr[q_tail] = ad;
        q_dead[q_tail] = in_reset;
        q_tail = (q_tail + 1) % 8;
        q_n    = q_n + 1;
    endtask

    task automatic wait_answers(input string what);
        integer guard;
        guard = 0;
        while (q_n > 0) begin
            @(posedge clk);
            guard++;
            if (guard > 2500000) begin         // 50 ms
                errors++;
                $display("  *** HANG at %0t: %0d read(s) never answered (%s)", $time, q_n, what);
                q_n = 0; q_head = q_tail;
            end
        end
    endtask

    initial begin : master
        integer k, gap;
        logic [19:0] ad;
        if (!$value$plusargs("SEED=%d", seed)) seed = 1;
        process::self().srandom(seed * 2 + 1);       // every thread has its own generator
        forever begin
            @(posedge clk);
            if (!master_run) continue;
            k = $urandom_range(0, 99);
            ad = pick_addr();
            if (k < 45) do_write(ad, $urandom_range(0, 255));
            else if (k < 80) begin
                issue_read(ad);
                wait_answers("single read");
            end
            else begin
                // KFSDRAM's look-ahead: two reads back to back, answers in order
                issue_read(ad);
                issue_read(ad ^ 20'h00001);
                wait_answers("read pair");
            end
            gap = $urandom_range(0, 9);
            if (gap > 6) repeat ($urandom_range(1, 40)) @(posedge clk);
        end
    end

    // ------------------------------------------------------------------ the button
    initial begin : button
        integer i, dly, len, kind;
        if (!$value$plusargs("RESETS=%d", n_resets)) n_resets = 100;
        if (!$value$plusargs("SEED=%d", seed)) seed = 1;
        process::self().srandom(seed * 2);
        for (i = 0; i < 1048576; i++) begin exp_mem[i] = 8'h00; known[i] = 1'b0; end
        $display("=== mem_reset_stress_tb: %0d resets, seed %0d, real HyperRAM path, self test %0s ===", n_resets, seed, BIST ? "on (as on the core)" : "off");
        #201; rst = 1'b0; hr_rst = 1'b0;
        #400us;                                   // the controller's 150 us start-up and CR0 write
        if (BIST) #4ms;                           // and the self test
        master_run = 1'b1;

        for (i = 1; i <= n_resets; i++) begin
            // how long the machine runs before the press: mostly long enough to do real work,
            // sometimes so short that the press lands in the start-up of the controller
            kind = $urandom_range(0, 9);
            if (kind == 0)      dly = $urandom_range(1000, 140000);        // inside the 150 us start-up
            else if (kind < 3)  dly = $urandom_range(160000, 400000);
            else                dly = $urandom_range(400000, 2500000);
            #(dly * 1ns);
            #($urandom_range(0, 19) * 1ns);       // any phase against both clocks

            in_reset   = 1'b1;
            master_run = 1'b0;                    // the CPU is reset together with the memory side
            for (int j = 0; j < 8; j++) q_dead[j] = 1'b1;     // whatever is outstanding now is answered with a dummy
            hr_rst     = 1'b1;
            t_last_reset = $time;
            len = (kind == 9) ? $urandom_range(2000, 6000) : $urandom_range(6000, 200000);   // 2 us .. 200 us (the board: milliseconds)
            if (debug) $display("  [%0t] press #%0d: after %0d ns, %0d ns long (kind %0d); q_n=%0d wr=%0d rd=%0d out_count=%0d",
                                $time, i, dly, len, kind, q_n, wr, rd, u_mem.i_backend.out_count);
            #(len * 1ns);
            #($urandom_range(0, 19) * 1ns);
            hr_rst = 1'b0;
            if (debug) $display("  [%0t] release #%0d: q_n=%0d wr=%0d rd=%0d out_count=%0d rst_all=%0d",
                                $time, i, q_n, wr, rd, u_mem.i_backend.out_count, u_mem.i_backend.rst_all);

            // the CPU comes back later than the memory side; by then every read the master
            // still had outstanding must have been answered
            #($urandom_range(10000, 60000) * 1ns);
            begin
                integer guard;
                guard = 0;
                while ((q_n > 0 || wr || rd) && guard < 2500000) begin @(posedge clk); guard++; end
                if (q_n > 0 || wr || rd) begin
                    errors++;
                    $display("  *** HANG at %0t after reset #%0d: %0d read(s) outstanding, write pending %0d, read pending %0d",
                             $time, i, q_n, wr, rd);
                end
            end
            // from here on only what is written after the reset counts
            for (int j = 0; j < 1048576; j++) known[j] = 1'b0;
            @(posedge clk);
            in_reset    = 1'b0;
            master_run  = 1'b1;
            resets_done = i;
            if (i % 25 == 0)
                $display("  [%0t] %0d resets: %0d writes, %0d reads checked, %0d unknown, %0d dummy beats, %0d errors",
                         $time, i, writes, reads_ok, reads_unknown, dummy_beats, errors);
        end

        #2ms;
        master_run = 1'b0;
        #1ms;
        $display("--- %0d resets, %0d writes, %0d reads checked against the scoreboard, %0d reads of bytes not written since the reset, %0d dummy beats, %0d extra beats",
                 resets_done, writes, reads_ok, reads_unknown, dummy_beats, extra_beats);
        if (errors == 0 && reads_ok > 1000) $display("RESULT: PASS");
        else                                $display("RESULT: FAIL (%0d errors, %0d reads checked)", errors, reads_ok);
        $finish;
    end

endmodule
