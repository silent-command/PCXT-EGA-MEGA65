// rom_loader_tb: the QNICE side and clock crossing of rom_loader.vhd.
//
// Models the firmware's autoload loop on the QNICE bus (one byte per write,
// consecutive addresses, ce/we held while wait is high, device id set before
// the data write) and the core's ROM port (rom_wait: high for a few clocks
// after rom_download rises, high for ~172 clocks after each accepted word).
// Checks that every byte pair arrives once, in order, with the right index,
// word address and data, and that the firmware side never stalls for long.
//
// Streams: pcxt.rom segments at the start, across the 64 KB boundary and at
// the end of a 128 KB file (word addresses up to 1FFFE), then the EGA and
// XT-IDE devices, with M2M CRTROM CSR-window writes (status / file size in
// 4k window 0xFFFF) sprinkled in, which must never produce a word.
//
// MAC registers (window 0xFFFE of device 0x0110, see rom_loader.vhd): the
// three address words and the valid bit are written the way the firmware's
// ETH_SET_MAC does it, and the bench checks that no word is produced, that
// eth_mac_valid_o stays low until the valid bit, that eth_mac_o then holds
// the address and never changes while valid is high, that the registers read
// back, that the other device ids cannot write them, that a rewrite (valid
// low, new words, valid high) and a core reset both end with a fresh copy.
//
// Floppy engine registers (window 0xFFFD, see rom_loader.vhd): a stub engine on the core side goes busy
// for a while after each command pulse and then presents result words; the bench checks that a command
// write reaches the core as one pulse with the code and arguments written before it, that the busy bit is
// set by the write itself and only clears after the stub finished (no window in which a fast firmware
// could see "idle" too early), that the result words read back exactly once the busy bit is clear, that a
// command written while busy is dropped, that the enable / block-error levels and the disk-change and
// verify-fail clear pulses cross (each on its own, together, and never spuriously), that the nine live
// flags read back (seven in the status word, the two write-verify ones in register 12), that the sticky
// access flag of register 13 is set by one core-clock pulse and cleared by control bit 4 only, that a
// WRITE_SECTOR command (code 6) passes like any other, and that floppy-window writes never produce a ROM
// word.
//
// Run with run_rom_loader_tb.ps1 (xsim, mixed language).
`timescale 1ns / 1ps

module rom_loader_tb;

    // QNICE at 50 MHz, core at a slightly different 50 MHz so the phase drifts
    logic qnice_clk = 0, core_clk = 0;
    always #10.0  qnice_clk = ~qnice_clk;
    always #10.07 core_clk  = ~core_clk;

    logic        qnice_rst = 1'b1;
    logic [15:0] dev_id = 16'h0000;
    logic [27:0] dev_addr = 28'd0;
    logic [15:0] dev_data = 16'd0;
    logic        dev_ce = 1'b0, dev_we = 1'b0;
    wire         dev_wait;
    wire  [15:0] dev_data_o;

    logic        core_rst = 1'b1;
    wire         rom_download;
    wire  [7:0]  rom_index;
    wire         rom_wr;
    wire  [24:0] rom_addr;
    wire  [15:0] rom_data;
    logic        rom_wait = 1'b0;
    wire  [47:0] eth_mac;
    wire         eth_mac_valid;

    // floppy engine side (core clock)
    wire         flp_cmd, flp_enable, flp_chg_clr, flp_vfy_clr, flp_blk_err;
    wire  [3:0]  flp_cmd_code;
    wire  [15:0] flp_arg0, flp_arg1;
    logic        flp_busy = 1'b0;
    logic [95:0] flp_res = 96'h0;
    logic [8:0]  flp_live = 9'h0;
    logic        flp_access = 1'b0;     // floppy.v fdd0_access: a DOS access attempt on drive A (pulse)
    logic [95:0] flp_dbg = 96'h0;
    wire  [15:0] flp_arg2;              // FORMAT_TRACK fill / gap 3 (write 4)
    logic [15:0] flp_fmt = 16'h0;       // the format tap (read 14)
    logic [15:0] flp_fmt_tail = 16'h0;  // gap 4b count (read 15)

    rom_loader #(.G_TIMEOUT(20000), .G_WORD_TIMEOUT(5000)) dut (
        .qnice_clk_i(qnice_clk), .qnice_rst_i(qnice_rst),
        .qnice_dev_id_i(dev_id), .qnice_dev_addr_i(dev_addr), .qnice_dev_data_i(dev_data),
        .qnice_dev_ce_i(dev_ce), .qnice_dev_we_i(dev_we), .qnice_dev_wait_o(dev_wait),
        .qnice_dev_data_o(dev_data_o),
        .core_clk_i(core_clk), .core_rst_i(core_rst),
        .rom_download_o(rom_download), .rom_index_o(rom_index), .rom_wr_o(rom_wr),
        .rom_addr_o(rom_addr), .rom_data_o(rom_data), .rom_wait_i(rom_wait),
        .eth_mac_o(eth_mac), .eth_mac_valid_o(eth_mac_valid),
        .flp_cmd_o(flp_cmd), .flp_cmd_code_o(flp_cmd_code), .flp_arg0_o(flp_arg0), .flp_arg1_o(flp_arg1),
        .flp_enable_o(flp_enable), .flp_chg_clr_o(flp_chg_clr), .flp_vfy_clr_o(flp_vfy_clr), .flp_blk_err_o(flp_blk_err),
        .flp_busy_i(flp_busy), .flp_res_i(flp_res), .flp_live_i(flp_live), .flp_dbg_i(flp_dbg), .flp_access_i(flp_access),
        .flp_arg2_o(flp_arg2), .flp_fmt_i(flp_fmt), .flp_fmt_tail_i(flp_fmt_tail)
    );

    //------------------------------------------------------------------------
    // Floppy engine stub and checks
    //------------------------------------------------------------------------
    integer      flp_errors = 0;
    integer      flp_cmds = 0, flp_clrs = 0, flp_vclrs = 0;
    logic        flp_vclr_d = 1'b0;
    logic [3:0]  flp_last_code;
    logic [15:0] flp_last_a0, flp_last_a1;
    integer      flp_busy_len = 0;          // core clocks the stub stays busy after a command
    logic [95:0] flp_next_res = 96'h0;      // what it presents at the end
    logic        flp_cmd_d = 1'b0;
    integer      flp_busy_cnt = 0;
    always @(posedge core_clk) begin
        flp_cmd_d <= flp_cmd;
        if (flp_cmd && flp_cmd_d) begin flp_errors = flp_errors + 1; $display("%0t ERROR FLP: cmd pulse wider than one clock", $time); end
        if (flp_chg_clr) flp_clrs = flp_clrs + 1;
        flp_vclr_d <= flp_vfy_clr;
        if (flp_vfy_clr && flp_vclr_d) begin flp_errors = flp_errors + 1; $display("%0t ERROR FLP: verify-clear pulse wider than one clock", $time); end
        if (flp_vfy_clr) flp_vclrs = flp_vclrs + 1;
        if (flp_cmd) begin
            flp_cmds = flp_cmds + 1;
            flp_last_code = flp_cmd_code; flp_last_a0 = flp_arg0; flp_last_a1 = flp_arg1;
            if (flp_busy_len > 0) begin flp_busy <= 1'b1; flp_busy_cnt <= flp_busy_len; end
            else flp_res <= flp_next_res;
        end
        else if (flp_busy) begin
            if (flp_busy_cnt <= 1) begin flp_busy <= 1'b0; flp_res <= flp_next_res; end
            flp_busy_cnt <= flp_busy_cnt - 1;
        end
    end
    // combinational readback of window 0xFFFD register r through the QNICE bus
    task automatic flp_read(input [3:0] r, output [15:0] v);
        dev_id   = 16'h0110;
        dev_addr = {16'hFFFD, 8'h00, r};
        #1;
        v = dev_data_o;
    endtask
    task automatic flp_expect(input [3:0] r, input [15:0] exp, input string what);
        logic [15:0] v;
        flp_read(r, v);
        if (v !== exp) begin flp_errors = flp_errors + 1; $display("%0t ERROR FLP %s: reg %0d = %04h, expected %04h", $time, what, r, v, exp); end
    endtask
    task automatic flp_write(input [3:0] r, input [15:0] v);
        qnice_write(16'h0110, {16'hFFFD, 8'h00, r}, v);
    endtask
    // the firmware's command sequence: args, then the command; returns the busy bit right after the write
    task automatic flp_command(input [3:0] code, input [15:0] a0, input [15:0] a1, output logic busy_now);
        logic [15:0] v;
        flp_write(4'd1, a0);
        flp_write(4'd2, a1);
        flp_write(4'd0, {12'h0, code});
        flp_read(4'd0, v);
        busy_now = v[15];
    endtask
    task automatic flp_wait_idle(input string what);
        logic [15:0] v;
        integer n = 0;
        flp_read(4'd0, v);
        while (v[15] && n < 100000) begin @(posedge qnice_clk); #1; flp_read(4'd0, v); n = n + 1; end
        if (v[15]) begin flp_errors = flp_errors + 1; $display("%0t ERROR FLP %s: busy never cleared", $time, what); end
    endtask

    //------------------------------------------------------------------------
    // MAC register checks: valid must never be high with a MAC other than the
    // one expected at that time, and the MAC must not change while valid
    //------------------------------------------------------------------------
    integer      mac_errors = 0;
    logic [47:0] mac_expect = 48'h0;
    logic        mac_valid_d = 1'b0;
    logic [47:0] mac_d = 48'h0;
    always @(posedge core_clk) begin
        mac_valid_d <= eth_mac_valid;
        mac_d       <= eth_mac;
        if (eth_mac_valid && eth_mac !== mac_expect) begin
            mac_errors <= mac_errors + 1;
            $display("%0t ERROR MAC: valid with %012h, expected %012h", $time, eth_mac, mac_expect);
        end
        if (eth_mac_valid && mac_valid_d && eth_mac !== mac_d) begin
            mac_errors <= mac_errors + 1;
            $display("%0t ERROR MAC: changed from %012h to %012h while valid", $time, mac_d, eth_mac);
        end
    end
    task automatic mac_check(input logic exp_valid, input string what);
        if (eth_mac_valid !== exp_valid) begin
            mac_errors = mac_errors + 1;
            $display("%0t ERROR MAC: %s: valid=%0d expected %0d", $time, what, eth_mac_valid, exp_valid);
        end
        else $display("%0t MAC ok: %s (valid=%0d mac=%012h)", $time, what, eth_mac_valid, eth_mac);
    endtask
    // QNICE readback is combinational on the device id and address
    task automatic mac_readback_check(input [47:0] mac, input logic valid, input logic src);
        logic [15:0] exp [0:3];
        exp[0] = mac[47:32]; exp[1] = mac[31:16]; exp[2] = mac[15:0]; exp[3] = {14'd0, src, valid};
        for (int r = 0; r < 4; r++) begin
            dev_id   = 16'h0110;
            dev_addr = {16'hFFFE, 12'(r)};
            #1;
            if (dev_data_o !== exp[r]) begin
                mac_errors = mac_errors + 1;
                $display("%0t ERROR MAC readback reg %0d: %04h expected %04h", $time, r, dev_data_o, exp[r]);
            end
        end
        // the debug readback in window 0 is untouched: reg 1 is the delivered-words counter
        dev_addr = {16'h0000, 12'h001};
        #1;
        if (dev_data_o !== dut.c_words_ok) begin
            mac_errors = mac_errors + 1;
            $display("%0t ERROR debug readback reg 1: %04h expected %04h", $time, dev_data_o, dut.c_words_ok);
        end
    endtask
    // the firmware's ETH_SET_MAC: three words, then the control word
    task automatic mac_write(input [15:0] id, input [47:0] mac, input logic valid, input logic src);
        qnice_write(id, {16'hFFFE, 12'h000}, mac[47:32]);
        qnice_write(id, {16'hFFFE, 12'h001}, mac[31:16]);
        qnice_write(id, {16'hFFFE, 12'h002}, mac[15:0]);
        qnice_write(id, {16'hFFFE, 12'h003}, {14'd0, src, valid});
    endtask

    //------------------------------------------------------------------------
    // Expected words, in order (pushed by the stimulus when it writes the
    // odd byte of a pair)
    //------------------------------------------------------------------------
    logic [7:0]  exp_idx_q[$];
    logic [24:0] exp_addr_q[$];
    logic [15:0] exp_data_q[$];
    integer      words_sent = 0;

    //------------------------------------------------------------------------
    // Core ROM port model (from the wrapper's loader FSM behaviour)
    //------------------------------------------------------------------------
    integer busy = 0;
    logic   download_d = 0;
    integer words_rx = 0, errors = 0;

    always @(posedge core_clk) begin
        download_d <= rom_download;
        if (rom_download & ~download_d) busy <= 3;            // state 00 -> 01
        else if (rom_wr) begin
            busy <= 172;                                       // per-word write cycle
            words_rx <= words_rx + 1;
            if (exp_addr_q.size() == 0) begin
                errors <= errors + 1;
                $display("%0t ERROR word %0d: unexpected word idx=%02h addr=%0h data=%04h (nothing pending)",
                         $time, words_rx, rom_index, rom_addr, rom_data);
            end
            else if (rom_index !== exp_idx_q[0] || rom_addr !== exp_addr_q[0] || rom_data !== exp_data_q[0]) begin
                errors <= errors + 1;
                $display("%0t ERROR word %0d: got idx=%02h addr=%0h data=%04h, expected idx=%02h addr=%0h data=%04h",
                         $time, words_rx, rom_index, rom_addr, rom_data, exp_idx_q[0], exp_addr_q[0], exp_data_q[0]);
                void'(exp_idx_q.pop_front()); void'(exp_addr_q.pop_front()); void'(exp_data_q.pop_front());
            end
            else begin
                void'(exp_idx_q.pop_front()); void'(exp_addr_q.pop_front()); void'(exp_data_q.pop_front());
            end
        end
        else if (busy > 0) busy <= busy - 1;
        rom_wait <= (busy > 0) || (rom_download & ~download_d);
    end

    //------------------------------------------------------------------------
    // QNICE bus model: firmware writes one byte per MMIO write
    //------------------------------------------------------------------------
    integer max_stall = 0;

    task automatic qnice_write(input [15:0] id, input [27:0] addr, input [15:0] data);
        integer stall;
        begin
            @(negedge qnice_clk);
            dev_id   = id;
            dev_addr = addr;
            dev_data = data;
            dev_ce   = 1'b1;
            dev_we   = 1'b1;
            stall = 0;
            // the CPU repeats the bus state while wait is high
            @(posedge qnice_clk); #1;
            while (dev_wait) begin @(posedge qnice_clk); #1; stall = stall + 1; if (stall > 100000) begin $display("%0t FATAL: QNICE stalled forever", $time); $finish; end end
            if (stall > max_stall) max_stall = stall;
            @(negedge qnice_clk);
            dev_ce = 1'b0;
            dev_we = 1'b0;
            // firmware overhead between bytes: a few instructions
            repeat (6) @(posedge qnice_clk);
        end
    endtask

    // deterministic file content: word at byte offset k (even) of device id
    function automatic [15:0] pat(input [15:0] id, input [27:0] k);
        pat = 16'h0101 * k[16:1] + {id[3:0], id[3:0], 8'h00} + {4'h0, k[24:17], 4'h0};
    endfunction

    // stream file bytes [first, last] of device id (both even/odd boundaries expected)
    task automatic stream(input [15:0] id, input [7:0] idx, input [27:0] first, input [27:0] last);
        logic [15:0] w;
        for (int unsigned k = first; k <= last; k++) begin
            w = pat(id, k & ~28'd1);
            if (k & 1) begin
                exp_idx_q.push_back(idx);
                exp_addr_q.push_back(k & ~28'd1);
                exp_data_q.push_back(w);
                words_sent = words_sent + 1;
                qnice_write(id, k, {8'h00, w[15:8]});
            end
            else
                qnice_write(id, k, {8'h00, w[7:0]});
        end
    endtask

    // M2M CRTROM_CSR_W: 4k window 0xFFFF, register offset, value
    task automatic csr_write(input [15:0] id, input [11:0] reg_off, input [15:0] value);
        qnice_write(id, {16'hFFFF, reg_off}, value);
    endtask

    integer rx_before;

    initial begin
        repeat (5) @(posedge qnice_clk);
        qnice_rst = 1'b0;
        core_rst  = 1'b0;
        repeat (20) @(posedge qnice_clk);

        // MAC registers before anything else, as the firmware does it in PREP_START
        mac_check(1'b0, "before any MAC write");
        mac_expect = 48'h024D36350001;
        qnice_write(16'h0110, {16'hFFFE, 12'h000}, 16'h024D);
        qnice_write(16'h0110, {16'hFFFE, 12'h001}, 16'h3635);
        qnice_write(16'h0110, {16'hFFFE, 12'h002}, 16'h0001);
        repeat (20) @(posedge core_clk);
        mac_check(1'b0, "three words written, no valid bit yet");
        mac_readback_check(48'h024D36350001, 1'b0, 1'b0);
        qnice_write(16'h0110, {16'hFFFE, 12'h003}, 16'h0001);      // valid, source = default
        repeat (20) @(posedge core_clk);
        mac_check(1'b1, "valid bit written");
        mac_readback_check(48'h024D36350001, 1'b1, 1'b0);
        // Neither another device id nor the CSR window reaches the MAC registers.
        // (Through the EGA id, window 0xFFFE is ordinary ROM data, so only an
        // even byte is written here: it parks in the low-byte latch and the EGA
        // stream below overwrites it before any word could form.)
        qnice_write(16'h0111, {16'hFFFE, 12'h000}, 16'h00DE);
        csr_write(16'h0110, 12'h003, 16'h0000);
        repeat (20) @(posedge core_clk);
        mac_check(1'b1, "other device id / CSR window ignored");
        mac_readback_check(48'h024D36350001, 1'b1, 1'b0);

        // the manual-load protocol writes "loading" first; must not become a low byte
        csr_write(16'h0110, 12'h000, 16'h0001);

        // pcxt.rom: 512 bytes at the start, 32 bytes across the 64 KB boundary,
        // 512 bytes at the end of a 128 KB file
        stream(16'h0110, 8'h00, 28'h00000, 28'h001FF);
        stream(16'h0110, 8'h00, 28'h0FFF0, 28'h1000F);
        stream(16'h0110, 8'h00, 28'h1FE00, 28'h1FFFF);

        // file size + status OK (manual-load protocol): no words
        rx_before = words_sent;
        csr_write(16'h0110, 12'h001, 16'h0000);
        csr_write(16'h0110, 12'h002, 16'h0002);
        csr_write(16'h0110, 12'h000, 16'h0003);

        // EGA and XT-IDE devices: index 3 and 2
        stream(16'h0111, 8'h03, 28'h00000, 28'h0003F);
        stream(16'h0112, 8'h02, 28'h00000, 28'h0003F);
        csr_write(16'h0112, 12'h000, 16'h0003);

        // wait for the last word to be delivered
        repeat (1000) @(posedge core_clk);
        mac_check(1'b1, "MAC untouched by the ROM streams");

        // rewrite: valid low, new address (a MEGA65 config one), valid high
        qnice_write(16'h0110, {16'hFFFE, 12'h003}, 16'h0000);
        repeat (20) @(posedge core_clk);
        mac_check(1'b0, "valid cleared");
        mac_expect = 48'h0E3E7A5B1C2D;
        mac_write(16'h0110, 48'h0E3E7A5B1C2D, 1'b1, 1'b1);
        repeat (20) @(posedge core_clk);
        mac_check(1'b1, "rewritten address");
        mac_readback_check(48'h0E3E7A5B1C2D, 1'b1, 1'b1);

        // a core reset clears the capture; the address comes back by itself
        core_rst = 1'b1;
        repeat (5) @(posedge core_clk);
        mac_check(1'b0, "core reset");
        core_rst = 1'b0;
        repeat (20) @(posedge core_clk);
        mac_check(1'b1, "after core reset");
        if (eth_mac !== 48'h0E3E7A5B1C2D) begin mac_errors = mac_errors + 1; $display("ERROR MAC after reset: %012h", eth_mac); end

        // a QNICE reset drops the valid bit (the firmware will write again). On
        // the board it only ever comes with the clock-lock core reset (main_rst),
        // which rom_loader needs to re-sync its request toggle, so both are pulsed.
        qnice_rst = 1'b1;
        core_rst  = 1'b1;
        repeat (5) @(posedge qnice_clk);
        qnice_rst = 1'b0;
        repeat (5) @(posedge core_clk);
        core_rst  = 1'b0;
        repeat (20) @(posedge core_clk);
        mac_check(1'b0, "after QNICE reset");
        //--------------------------------------------------------------------
        // floppy engine registers
        //--------------------------------------------------------------------
        begin
            logic busy_now;
            logic [15:0] v;
            integer cmds0, clrs0, vclrs0;
            rx_before = words_sent;
            mac_check(1'b0, "before the floppy tests (valid was dropped by the QNICE reset)");
            // idle: nothing enabled, status shows no busy
            flp_expect(4'd0, 16'h0000, "idle status");
            if (flp_enable !== 1'b0 || flp_blk_err !== 1'b0) begin flp_errors = flp_errors + 1; $display("ERROR FLP: enable/blk_err not low after reset"); end
            // control levels cross, the clear bit is a pulse
            clrs0 = flp_clrs;
            flp_write(4'd3, 16'h0001);                       // enable
            repeat (10) @(posedge core_clk);
            if (flp_enable !== 1'b1) begin flp_errors = flp_errors + 1; $display("ERROR FLP: enable did not cross"); end
            flp_write(4'd3, 16'h0007);                       // enable + clear + blk_err
            repeat (10) @(posedge core_clk);
            if (flp_blk_err !== 1'b1) begin flp_errors = flp_errors + 1; $display("ERROR FLP: blk_err did not cross"); end
            if (flp_clrs != clrs0 + 1) begin flp_errors = flp_errors + 1; $display("ERROR FLP: %0d clear pulses (1)", flp_clrs - clrs0); end
            flp_write(4'd3, 16'h0001);                       // enable only
            repeat (10) @(posedge core_clk);
            if (flp_blk_err !== 1'b0 || flp_clrs != clrs0 + 1) begin flp_errors = flp_errors + 1; $display("ERROR FLP: blk_err not cleared / stray clear pulse"); end
            // the verify-fail clear (bit 3): alone, together with the disk-change clear, never spuriously
            vclrs0 = flp_vclrs;
            if (flp_vclrs != 0) begin flp_errors = flp_errors + 1; $display("ERROR FLP: %0d verify-clear pulses before any request", flp_vclrs); end
            if (flp_clrs != clrs0 + 1) begin flp_errors = flp_errors + 1; $display("ERROR FLP: %0d disk-change clear pulses before the floppy tests (1)", flp_clrs); end
            flp_write(4'd3, 16'h0009);                       // enable + verify clear
            repeat (10) @(posedge core_clk);
            if (flp_vclrs != vclrs0 + 1 || flp_clrs != clrs0 + 1) begin flp_errors = flp_errors + 1; $display("ERROR FLP: verify clear: %0d pulses (1), chg clears %0d", flp_vclrs - vclrs0, flp_clrs - clrs0); end
            flp_write(4'd3, 16'h000B);                       // enable + both clears
            repeat (10) @(posedge core_clk);
            if (flp_vclrs != vclrs0 + 2 || flp_clrs != clrs0 + 2) begin flp_errors = flp_errors + 1; $display("ERROR FLP: both clears: verify %0d (2), chg %0d (2)", flp_vclrs - vclrs0, flp_clrs - clrs0); end
            flp_write(4'd3, 16'h0001);
            repeat (10) @(posedge core_clk);
            if (flp_vclrs != vclrs0 + 2 || flp_enable !== 1'b1) begin flp_errors = flp_errors + 1; $display("ERROR FLP: stray verify-clear pulse or enable lost"); end
            // live flags: seven in the status word, the two verify flags in register 12
            flp_live = 9'b00_1010101;
            repeat (10) @(posedge qnice_clk);
            flp_expect(4'd0, {1'b0, 7'b1010101, 8'h00}, "live flags");
            flp_expect(4'd12, 16'h0000, "verify flags clear");
            flp_live = 9'b01_0101010;
            repeat (10) @(posedge qnice_clk);
            flp_expect(4'd0, {1'b0, 7'b0101010, 8'h00}, "live flags (2)");
            flp_expect(4'd12, 16'h0001, "verify pending");
            flp_live = 9'b10_0000000;
            repeat (10) @(posedge qnice_clk);
            flp_expect(4'd0, 16'h0000, "live flags (3)");
            flp_expect(4'd12, 16'h0002, "verify failed");
            flp_live = 9'b11_0000000;
            repeat (10) @(posedge qnice_clk);
            flp_expect(4'd12, 16'h0003, "verify pending and failed");
            flp_live = 9'b00_0000000;
            repeat (10) @(posedge qnice_clk);
            // the access flag (register 13, docs/floppy.md on-demand detection): sticky from one core-clock
            // pulse, cleared by control bit 4 only, never set spuriously
            flp_expect(4'd13, 16'h0000, "access flag clear at start");
            @(posedge core_clk); flp_access <= 1'b1; @(posedge core_clk); flp_access <= 1'b0;
            repeat (10) @(posedge qnice_clk);
            flp_expect(4'd13, 16'h0001, "access flag set by one pulse");
            flp_write(4'd3, 16'h0001);                       // enable only: the flag stays
            repeat (10) @(posedge qnice_clk);
            flp_expect(4'd13, 16'h0001, "access flag survives a control write without bit 4");
            flp_write(4'd3, 16'h0011);                       // enable + access clear
            repeat (10) @(posedge qnice_clk);
            flp_expect(4'd13, 16'h0000, "access flag cleared by control bit 4");
            if (flp_clrs != clrs0 + 2 || flp_vclrs != vclrs0 + 2) begin flp_errors = flp_errors + 1; $display("ERROR FLP: the access clear pulsed a disk-change or verify clear"); end
            // set again after a clear, cleared again
            flp_write(4'd3, 16'h0011);
            @(posedge core_clk); flp_access <= 1'b1; @(posedge core_clk); flp_access <= 1'b0;
            repeat (10) @(posedge qnice_clk);
            flp_expect(4'd13, 16'h0001, "access flag set again after a clear");
            flp_write(4'd3, 16'h0011);
            repeat (10) @(posedge qnice_clk);
            flp_expect(4'd13, 16'h0000, "access flag cleared again");
            flp_expect(4'd0, 16'h0000, "status word untouched by the access flag");
            // a command with a busy engine: busy set by the write, results only after the stub finished
            cmds0 = flp_cmds;
            flp_busy_len = 400;
            flp_next_res = 96'h5A5A_1234_ABCD_0003_0102_0000 | 96'h0000_0000_0000_0000_0000_0007;
            flp_command(4'd2, 16'h0345, 16'h1206, busy_now);
            if (!busy_now) begin flp_errors = flp_errors + 1; $display("ERROR FLP: busy not set by the command write"); end
            repeat (20) @(posedge core_clk);
            if (flp_cmds != cmds0 + 1 || flp_last_code !== 4'd2 || flp_last_a0 !== 16'h0345 || flp_last_a1 !== 16'h1206) begin
                flp_errors = flp_errors + 1; $display("ERROR FLP: command pulse/args: n=%0d code=%0h a0=%04h a1=%04h", flp_cmds - cmds0, flp_last_code, flp_last_a0, flp_last_a1);
            end
            flp_read(4'd0, v);
            if (!v[15]) begin flp_errors = flp_errors + 1; $display("ERROR FLP: busy cleared while the engine is busy"); end
            flp_command(4'd1, 16'h0000, 16'h0000, busy_now);  // dropped: still busy
            repeat (20) @(posedge core_clk);
            if (flp_cmds != cmds0 + 1) begin flp_errors = flp_errors + 1; $display("ERROR FLP: a command while busy was not dropped"); end
            flp_wait_idle("READ_TRACK stub");
            flp_expect(4'd0, 16'h0007, "result word 0 (err)");
            flp_expect(4'd1, 16'h0102, "result word 1");
            flp_expect(4'd2, 16'h0003, "result word 2");
            flp_expect(4'd3, 16'hABCD, "result word 3");
            flp_expect(4'd4, 16'h1234, "result word 4");
            flp_expect(4'd5, 16'h5A5A, "result word 5");
            flp_dbg = 96'h0006_0005_0004_0003_0002_0001;
            #1;
            flp_expect(4'd6, 16'h0001, "debug word 6");
            flp_expect(4'd11, 16'h0006, "debug word 11");
            // phase 4: the format tap (read 14) and the gap 4b count (read 15) read back; write 4 (fill / gap 3)
            // reaches the engine with the command like the other arguments (FORMAT_TRACK, code 7)
            flp_expect(4'd14, 16'h0000, "format tap clear at start");
            flp_expect(4'd15, 16'h0000, "gap 4b count clear at start");
            flp_fmt = 16'h92F6;                              // a fill of a FORMAT TRACK: SC 18, filler F6
            flp_fmt_tail = 16'h0092;
            repeat (10) @(posedge qnice_clk);
            flp_expect(4'd14, 16'h92F6, "format tap word");
            flp_expect(4'd15, 16'h0092, "gap 4b count");
            flp_expect(4'd0, 16'h0007, "status word untouched by the format tap (still the last result)");
            flp_fmt = 16'h0000;
            flp_fmt_tail = 16'h0000;
            repeat (10) @(posedge qnice_clk);
            flp_expect(4'd14, 16'h0000, "format tap cleared");
            cmds0 = flp_cmds;
            flp_busy_len = 200;
            flp_next_res = 96'h0000_0000_0000_0000_0000_0000;
            flp_write(4'd4, 16'h54F6);                       // gap 3 0x54, fill F6
            flp_command(4'd7, 16'h0228, 16'h1200, busy_now); // FORMAT_TRACK C40 H1 HD, 18 sectors
            if (!busy_now) begin flp_errors = flp_errors + 1; $display("ERROR FLP: busy not set by the FORMAT_TRACK write"); end
            repeat (20) @(posedge core_clk);
            if (flp_cmds != cmds0 + 1 || flp_last_code !== 4'd7 || flp_last_a0 !== 16'h0228 || flp_last_a1 !== 16'h1200 || flp_arg2 !== 16'h54F6) begin
                flp_errors = flp_errors + 1; $display("ERROR FLP: FORMAT_TRACK pulse/args: n=%0d code=%0h a0=%04h a1=%04h a2=%04h", flp_cmds - cmds0, flp_last_code, flp_last_a0, flp_last_a1, flp_arg2);
            end
            flp_wait_idle("FORMAT_TRACK stub");
            flp_expect(4'd0, 16'h0000, "FORMAT_TRACK result: err 0");
            // WRITE_SECTOR (code 6) with its arguments crosses like any other command
            cmds0 = flp_cmds;
            flp_busy_len = 200;
            flp_next_res = 96'h0000_0000_0000_0000_0000_0007;
            flp_command(4'd6, 16'h021E, 16'h1209, busy_now);
            if (!busy_now) begin flp_errors = flp_errors + 1; $display("ERROR FLP: busy not set by the WRITE_SECTOR write"); end
            repeat (20) @(posedge core_clk);
            if (flp_cmds != cmds0 + 1 || flp_last_code !== 4'd6 || flp_last_a0 !== 16'h021E || flp_last_a1 !== 16'h1209) begin
                flp_errors = flp_errors + 1; $display("ERROR FLP: WRITE_SECTOR pulse/args: n=%0d code=%0h a0=%04h a1=%04h", flp_cmds - cmds0, flp_last_code, flp_last_a0, flp_last_a1);
            end
            flp_wait_idle("WRITE_SECTOR stub");
            flp_expect(4'd0, 16'h0007, "WRITE_SECTOR result: err 7 (write protected)");
            // a command the engine never picks up (disabled engine, stub stays idle): busy clears by itself
            cmds0 = flp_cmds;
            flp_busy_len = 0;
            flp_next_res = 96'h0000_0000_0000_0000_0000_0006;
            flp_command(4'd3, 16'h0000, 16'h0001, busy_now);
            if (!busy_now) begin flp_errors = flp_errors + 1; $display("ERROR FLP: busy not set by the second command write"); end
            flp_wait_idle("COPY on an idle engine");
            flp_expect(4'd0, 16'h0006, "result after a command the engine ignored");
            if (flp_cmds != cmds0 + 1) begin flp_errors = flp_errors + 1; $display("ERROR FLP: second command pulse missing"); end
            // other device ids cannot reach the window (for them 0xFFFD is ROM data: an even address only
            // latches a low byte), and the window never makes ROM words
            qnice_write(16'h0111, {16'hFFFD, 12'h002}, 16'h0000);
            repeat (10) @(posedge core_clk);
            flp_expect(4'd0, 16'h0006, "control/result untouched by another device id");
            if (flp_enable !== 1'b1) begin flp_errors = flp_errors + 1; $display("ERROR FLP: another device id changed the control register"); end
            repeat (200) @(posedge core_clk);
            if (words_sent != rx_before) begin flp_errors = flp_errors + 1; $display("ERROR FLP: floppy-window writes produced ROM words"); end
            flp_write(4'd3, 16'h0000);
            $display("FLP register checks: errors=%0d (%0d commands, %0d clear pulses, %0d verify-clear pulses)", flp_errors, flp_cmds, flp_clrs, flp_vclrs);
        end

        $display("MAC register checks: errors=%0d", mac_errors);
        $display("words delivered=%0d (expected %0d), errors=%0d, pending=%0d, max QNICE stall=%0d cycles, dropped=%0d, download=%0d",
                 words_rx, words_sent, errors, exp_addr_q.size(), max_stall, dut.c_words_drop, rom_download);
        if (words_rx == words_sent && errors == 0 && exp_addr_q.size() == 0 && dut.c_words_drop == 0 && mac_errors == 0 && flp_errors == 0) $display("RESULT: PASS");
        else $display("RESULT: FAIL");
        $finish;
    end

endmodule
