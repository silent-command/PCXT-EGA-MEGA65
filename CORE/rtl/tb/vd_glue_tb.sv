// vd_glue_tb: the block buffer of CORE/vhdl/vd_glue.vhd from the core side, both directions of the
// internal floppy drive's sector engine (docs/floppy.md):
//   * the bridge writes 512 bytes (a floppy write drained from floppy.v) and the engine reads them back
//     through flp_buf_rd_i / flp_buf_addr_i / flp_buf_rdata_o with one clock of latency (WRITE_SECTOR's
//     load), while the QNICE side (vdrives) sees the same bytes through sd_buff_din_o;
//   * the engine writes 512 bytes (COPY) and the bridge reads them back through buf_addr_i / buf_rdata_o;
//   * with neither flp_buf_we_i nor flp_buf_rd_i the bridge owns the port: the engine's address is ignored;
//   * a block request crosses to the QNICE side with its LBA and the acknowledge comes back.
// The DUT is wrapped by vd_glue_wrap.vhd (the vdrives_pkg array ports flattened). Run with run_vd_glue_tb.ps1.
`timescale 1ns / 1ps

module vd_glue_tb;

    logic core_clk = 0, qnice_clk = 0;
    always #10.0  core_clk  = ~core_clk;
    always #10.07 qnice_clk = ~qnice_clk;

    logic        core_rst = 1'b1;
    logic [2:0]  blk_rd = 3'b000, blk_wr = 3'b000;
    logic [31:0] blk_lba = 32'd0;
    wire  [2:0]  blk_ack;
    logic [8:0]  buf_addr = 9'd0;
    logic [7:0]  buf_wdata = 8'd0;
    logic        buf_we = 1'b0;
    wire  [7:0]  buf_rdata;
    logic [8:0]  flp_addr = 9'd0;
    logic [7:0]  flp_data = 8'd0;
    logic        flp_we = 1'b0, flp_rd = 1'b0;
    wire  [7:0]  flp_rdata;

    wire  [95:0] sd_lba;                 // drive i: bits 32i+31..32i (vd_glue_wrap.vhd flattens the array ports)
    wire  [2:0]  sd_rd, sd_wr;
    logic [2:0]  sd_ack = 3'b000;
    logic [13:0] sd_buff_addr = 14'd0;
    logic [7:0]  sd_buff_dout = 8'd0;
    wire  [23:0] sd_buff_din;            // drive i: bits 8i+7..8i
    logic        sd_buff_wr = 1'b0;

    vd_glue_wrap dut (
        .core_clk_i(core_clk), .core_rst_i(core_rst),
        .blk_rd_i(blk_rd), .blk_wr_i(blk_wr), .blk_lba_i(blk_lba), .blk_ack_o(blk_ack),
        .buf_addr_i(buf_addr), .buf_wdata_i(buf_wdata), .buf_we_i(buf_we), .buf_rdata_o(buf_rdata),
        .flp_buf_addr_i(flp_addr), .flp_buf_data_i(flp_data), .flp_buf_we_i(flp_we),
        .flp_buf_rd_i(flp_rd), .flp_buf_rdata_o(flp_rdata),
        .qnice_clk_i(qnice_clk),
        .sd_lba_o(sd_lba), .sd_rd_o(sd_rd), .sd_wr_o(sd_wr), .sd_ack_i(sd_ack),
        .sd_buff_addr_i(sd_buff_addr), .sd_buff_dout_i(sd_buff_dout), .sd_buff_din_o(sd_buff_din),
        .sd_buff_wr_i(sd_buff_wr)
    );

    int n_pass = 0, n_fail = 0;
    task automatic check(input bit cond, input string msg);
        if (cond) n_pass++;
        else begin n_fail++; $display("VDG FAIL @%0t: %s", $time, msg); end
    endtask

    function automatic byte pat_a(input int k); return (k * 7 + 3) & 8'hFF; endfunction
    function automatic byte pat_b(input int k); return (k * 13 + 91) ^ 8'h5A; endfunction

    // the bridge writes a byte (registered address/data/we, as mgmt_bridge does)
    task automatic bridge_write(input int a, input byte d);
        @(posedge core_clk); #1;
        buf_addr = a; buf_wdata = d; buf_we = 1'b1;
        @(posedge core_clk); #1;
        buf_we = 1'b0;
    endtask
    // the bridge reads a byte: address, then the data one clock later
    task automatic bridge_read(input int a, output byte d);
        @(posedge core_clk); #1;
        buf_addr = a;
        @(posedge core_clk); #1;
        @(posedge core_clk); #1;
        d = buf_rdata;
    endtask

    int bad;
    byte d;
    byte eng [0:511];

    initial begin
        repeat (5) @(posedge core_clk);
        core_rst = 1'b0;
        repeat (5) @(posedge core_clk);

        // --- 1. the bridge fills the buffer (a drained floppy write), the engine loads it ---
        for (int k = 0; k < 512; k++) bridge_write(k, pat_a(k));
        // the engine's load: address streamed every clock with flp_rd high; the buffer samples the address
        // at the next edge and the data is out right after it (the engine registers it at the edge after)
        @(posedge core_clk); #1;
        flp_rd = 1'b1;
        for (int k = 0; k < 512; k++) begin
            flp_addr = k;
            @(posedge core_clk); #1;
            eng[k] = flp_rdata;
        end
        flp_rd = 1'b0;
        bad = 0;
        for (int k = 0; k < 512; k++) if (eng[k] !== pat_a(k)) bad++;
        check(bad == 0, $sformatf("engine load: %0d of 512 bytes differ from what the bridge wrote", bad));
        // the QNICE side sees the same block
        bad = 0;
        for (int k = 0; k < 512; k++) begin
            @(posedge qnice_clk); #1;
            sd_buff_addr = k;
            @(posedge qnice_clk); #1;
            @(posedge qnice_clk); #1;
            if (sd_buff_din[7:0] !== pat_a(k)) bad++;
        end
        check(bad == 0, $sformatf("QNICE side: %0d of 512 bytes differ", bad));

        // --- 2. the engine's COPY writes the buffer, the bridge reads it back ---
        @(posedge core_clk); #1;
        for (int k = 0; k < 512; k++) begin
            flp_addr = k; flp_data = pat_b(k); flp_we = 1'b1;
            @(posedge core_clk); #1;
        end
        flp_we = 1'b0;
        bad = 0;
        for (int k = 0; k < 512; k++) begin bridge_read(k, d); if (d !== pat_b(k)) bad++; end
        check(bad == 0, $sformatf("bridge read after COPY: %0d of 512 bytes differ", bad));

        // --- 3. the engine's address is ignored while it neither writes nor reads ---
        flp_addr = 9'd7;
        bridge_read(3, d);
        check(d === pat_b(3), "bridge owns the port when the engine is idle");
        flp_rd = 1'b1;
        @(posedge core_clk); #1; @(posedge core_clk); #1;
        check(flp_rdata === pat_b(7), "engine read while the bridge address differs: the engine's address wins");
        flp_rd = 1'b0;

        // --- 4. a block write request crosses with its LBA, the acknowledge comes back ---
        @(posedge core_clk); #1;
        blk_lba = 32'd1234; blk_wr = 3'b001;
        fork
            begin wait (sd_wr[0]); end
            begin #2us; check(0, "sd_wr never rose"); end
        join_any
        disable fork;
        check(sd_wr[0] === 1'b1 && sd_lba[31:0] == 32'd1234 && sd_rd[0] === 1'b0, "block write request on the QNICE side with LBA 1234");
        @(posedge qnice_clk); #1;
        sd_ack[0] = 1'b1;
        fork
            begin wait (blk_ack[0]); end
            begin #2us; check(0, "blk_ack never rose"); end
        join_any
        disable fork;
        check(blk_ack[0] === 1'b1, "acknowledge crossed to the core side");
        @(posedge core_clk); #1;
        blk_wr = 3'b000;
        @(posedge qnice_clk); #1;
        sd_ack[0] = 1'b0;
        fork
            begin wait (!blk_ack[0]); end
            begin #2us; check(0, "blk_ack never fell"); end
        join_any
        disable fork;
        check(blk_ack[0] === 1'b0, "acknowledge released");

        if (n_fail == 0) $display("VDG RESULT: PASS (%0d checks)", n_pass);
        else             $display("VDG RESULT: FAIL (%0d failed, %0d passed)", n_fail, n_pass);
        $finish;
    end

    initial begin
        #10ms;
        $display("VDG RESULT: FAIL (timeout)");
        $finish;
    end

endmodule
