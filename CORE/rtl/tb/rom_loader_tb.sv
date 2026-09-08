// rom_loader_tb: the QNICE side and clock crossing of rom_loader.vhd.
//
// Models the firmware's autoload loop on the QNICE bus (one byte per write,
// consecutive addresses, ce/we held while wait is high, device id set before
// the data write) and the core's ROM port (rom_wait: high for a few clocks
// after rom_download rises, high for ~172 clocks after each accepted word).
// Checks that every byte pair arrives once, in order, at the right word
// address, and that the firmware side never stalls for long.
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

    rom_loader #(.G_TIMEOUT(20000), .G_WORD_TIMEOUT(5000)) dut (
        .qnice_clk_i(qnice_clk), .qnice_rst_i(qnice_rst),
        .qnice_dev_id_i(dev_id), .qnice_dev_addr_i(dev_addr), .qnice_dev_data_i(dev_data),
        .qnice_dev_ce_i(dev_ce), .qnice_dev_we_i(dev_we), .qnice_dev_wait_o(dev_wait),
        .qnice_dev_data_o(dev_data_o),
        .core_clk_i(core_clk), .core_rst_i(core_rst),
        .rom_download_o(rom_download), .rom_index_o(rom_index), .rom_wr_o(rom_wr),
        .rom_addr_o(rom_addr), .rom_data_o(rom_data), .rom_wait_i(rom_wait)
    );

    //------------------------------------------------------------------------
    // Core ROM port model (from the wrapper's loader FSM behaviour)
    //------------------------------------------------------------------------
    integer busy = 0;
    logic   download_d = 0;
    integer words_rx = 0, errors = 0;
    logic [15:0] expect_word = 16'h0000;
    logic [24:0] expect_addr = 25'd0;

    always @(posedge core_clk) begin
        download_d <= rom_download;
        if (rom_download & ~download_d) busy <= 3;            // state 00 -> 01
        else if (rom_wr) begin
            busy <= 172;                                       // per-word write cycle
            words_rx <= words_rx + 1;
            if (rom_addr !== expect_addr || rom_data !== expect_word) begin
                errors <= errors + 1;
                $display("%0t ERROR word %0d: got addr=%0h data=%04h, expected addr=%0h data=%04h",
                         $time, words_rx, rom_addr, rom_data, expect_addr, expect_word);
            end
            expect_addr  <= expect_addr + 2;
            expect_word  <= expect_word + 16'h0101;
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

    initial begin
        repeat (5) @(posedge qnice_clk);
        qnice_rst = 1'b0;
        core_rst  = 1'b0;
        repeat (20) @(posedge qnice_clk);

        // 512 bytes of "ROM": byte k = low/high of word (k/2)*0x0101
        for (int k = 0; k < 512; k++) begin
            logic [15:0] w = 16'h0101 * (k / 2);
            qnice_write(16'h0110, k, (k & 1) ? {8'h00, w[15:8]} : {8'h00, w[7:0]});
        end

        // wait for the last word to be delivered
        repeat (1000) @(posedge core_clk);
        $display("words delivered=%0d (expected 256), errors=%0d, max QNICE stall=%0d cycles, dropped=%0d, download=%0d",
                 words_rx, errors, max_stall, dut.c_words_drop, rom_download);
        if (words_rx == 256 && errors == 0 && dut.c_words_drop == 0) $display("RESULT: PASS");
        else $display("RESULT: FAIL");
        $finish;
    end

endmodule
