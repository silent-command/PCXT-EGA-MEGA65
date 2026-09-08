// rom_load_tb: does the wrapper accept a BIOS ROM stream while the machine
// is held in soft reset, the way the M2M firmware delivers it?
//
// Drives pcxt_core the way main.vhd does: seven clocks, cold reset pulse,
// reset_osd_i held high (firmware soft reset), Avalon byte RAM on the SDRAM
// pins (the KFSDRAM overlay's bus), and the ioctl-style ROM port fed with
// 16-bit words whenever rom_wait_o is low. Prints the loader's state so a
// stall is visible: initilized_sdram, reset_sdram, bios_load_state,
// processor_ready, address_direction.
//
// Build and run with run_rom_load_tb.sh (Verilator)
`timescale 1ns / 1ps

module rom_load_tb;

    // clocks (periods rounded to 10 ps; only ratios matter here)
    logic clk_100 = 0, clk_50 = 0, clk_28 = 0, clk_57 = 0, clk_57_ps = 0, clk_25 = 0, clk_14 = 0;
    always #5.000  clk_100 = ~clk_100;
    always #10.000 clk_50  = ~clk_50;
    always #17.460 clk_28  = ~clk_28;
    always #8.730  clk_57  = ~clk_57;
    initial begin #4.365; forever #8.730 clk_57_ps = ~clk_57_ps; end
    always #19.840 clk_25  = ~clk_25;
    always #34.920 clk_14  = ~clk_14;

    logic reset_cold = 1'b1;
    logic reset_osd  = 1'b1;

    // ROM port
    logic        rom_download = 1'b0;
    logic [7:0]  rom_index = 8'h00;
    logic        rom_wr = 1'b0;
    logic [24:0] rom_addr = 25'd0;
    logic [15:0] rom_data = 16'h0000;
    wire         rom_wait;

    // SDRAM pins = Avalon byte bus
    wire [12:0] sdram_a;
    wire [1:0]  sdram_ba;
    wire        sdram_nras, sdram_nwe;
    wire [15:0] sdram_dq_out;
    logic [15:0] sdram_dq_in;

    wire bios_missing_pcxt, bios_missing_ega, splash_active;

    pcxt_core dut (
        .clk_core_i(clk_100), .clk_chipset_i(clk_50), .clk_video_base_i(clk_28),
        .clk_video_x2_i(clk_57), .clk_video_out_ps_i(clk_57_ps), .clk_video_vga_i(clk_25),
        .clk_14_318_i(clk_14), .pll_locked_i(1'b1),
        .reset_i(reset_cold), .reset_osd_i(reset_osd), .reset_button_i(1'b0),
        .video_clk_o(), .video_ce_o(), .video_red_o(), .video_green_o(), .video_blue_o(),
        .video_hs_o(), .video_vs_o(), .video_hblank_o(), .video_vblank_o(), .video_de_o(),
        .video_mode13_o(), .video_mode13_native_clk_o(), .video_mode350_o(),
        .video_active_dots_o(), .video_active_lines_o(), .video_aspect_o(), .video_scanlines_o(),
        .audio_left_o(), .audio_right_o(), .audio_mix_o(),
        .ps2_kbd_clk_i(1'b1), .ps2_kbd_data_i(1'b1), .ps2_kbd_clk_o(), .ps2_kbd_data_o(),
        .ps2_key_i(11'd0), .ps2_mouse_clk_i(1'b1), .ps2_mouse_data_i(1'b1),
        .ps2_mouse_clk_o(), .ps2_mouse_data_o(),
        .joy0_i(14'd0), .joy1_i(14'd0), .joya0_i(16'd0), .joya1_i(16'd0),
        .osm_cpu_speed_i(2'b00), .osm_cpu_8086_i(1'b0), .osm_fake286_i(1'b0), .osm_splash_off_i(1'b0),
        .osm_bios_writable_i(2'b00), .osm_audio220_i(2'b00), .osm_opl2_i(2'b00), .osm_tandy_i(1'b0),
        .osm_speaker_vol_i(2'b00), .osm_audio_boost_i(2'b00), .osm_stereo_mix_i(2'b00),
        .osm_crt_h_i(4'b0), .osm_crt_v_i(3'b0), .osm_vsync_w_i(3'b0), .osm_hsync_w_i(3'b0),
        .osm_scandoubler_fx_i(2'b00), .osm_aspect_i(2'b00), .osm_display_i(3'b000), .osm_vga13_tv_i(1'b0),
        .osm_monitor_i(2'b00), .osm_ems_disable_i(1'b1), .osm_umb_disable_i(1'b1),
        .osm_joy1_i(2'b00), .osm_joy2_i(2'b00), .osm_joy_sync_i(1'b0), .osm_joy_swap_i(1'b0),
        .osm_sb_irq7_i(1'b0), .osm_mpu401_disable_i(1'b1), .osm_floppy_wp_i(2'b00),
        .bios_missing_pcxt_o(bios_missing_pcxt), .bios_missing_ega_o(bios_missing_ega),
        .reset_pending_o(), .pause_o(), .splash_active_o(splash_active),
        .rom_download_i(rom_download), .rom_index_i(rom_index), .rom_wr_i(rom_wr),
        .rom_addr_i(rom_addr), .rom_data_i(rom_data), .rom_wait_o(rom_wait),
        .sdram_a_o(sdram_a), .sdram_ba_o(sdram_ba), .sdram_cke_o(), .sdram_ncs_o(),
        .sdram_nras_o(sdram_nras), .sdram_ncas_o(), .sdram_nwe_o(sdram_nwe),
        .sdram_dq_out_o(sdram_dq_out), .sdram_dq_io_o(), .sdram_dq_in_i(sdram_dq_in),
        .sdram_dqml_o(), .sdram_dqmh_o(), .sdram_initialized_o(),
        .mgmt_addr_i(16'd0), .mgmt_dout_i(16'd0), .mgmt_din_o(), .mgmt_wr_i(1'b0), .mgmt_rd_i(1'b0),
        .mgmt_req_o(), .fdd_present_o(), .led_disk_o()
    );

    //------------------------------------------------------------------------
    // Avalon byte RAM, 1 MB, zero wait, one-cycle read latency
    //------------------------------------------------------------------------
    logic [7:0] mem [0:1048575];
    wire [21:0] avm_address   = {sdram_dq_out[15:9], sdram_ba, sdram_a};
    wire        avm_read      = ~sdram_nras;
    wire        avm_write     = ~sdram_nwe;
    logic [7:0] rd_q = 8'h00;
    logic       rv_q = 1'b0;
    integer     avm_reads = 0, avm_writes = 0;
    always @(posedge clk_50) begin
        rv_q <= avm_read;
        if (avm_read)  begin rd_q <= mem[avm_address[19:0]]; avm_reads <= avm_reads + 1; end
        if (avm_write) begin mem[avm_address[19:0]] <= sdram_dq_out[7:0]; avm_writes <= avm_writes + 1; end
    end
    assign sdram_dq_in = {6'b0, rv_q, 1'b0, rd_q};

    //------------------------------------------------------------------------
    // ROM stream, ioctl protocol
    //------------------------------------------------------------------------
    integer words_sent = 0;
    integer stalls = 0;

    task automatic status(input string tag);
        $display("%0t %s: reset_sdram=%0d initilized_sdram=%0d reset=%0d bios_load_state=%0h rom_wait=%0d processor_ready=%0d address_direction=%0d words=%0d avm_w=%0d avm_r=%0d",
                 $time, tag, dut.reset_sdram, dut.initilized_sdram, dut.reset, dut.bios_load_state, rom_wait,
                 dut.processor_ready, dut.address_direction, words_sent, avm_writes, avm_reads);
    endtask

    task automatic send_word(input [15:0] addr, input [15:0] data);
        integer guard;
        begin
            guard = 0;
            while (rom_wait && guard < 200000) begin @(posedge clk_50); guard = guard + 1; end
            if (rom_wait) begin stalls = stalls + 1; status("STALL"); end
            @(negedge clk_50);
            rom_addr = {9'd0, addr};
            rom_data = data;
            rom_wr   = 1'b1;
            @(negedge clk_50);
            rom_wr   = 1'b0;
            words_sent = words_sent + 1;
        end
    endtask

    initial begin
        $display("rom_load_tb: start");
        repeat (20) @(posedge clk_50);
        reset_cold = 1'b0;                     // cold reset released, soft reset stays

        // wait for the SDRAM reset stretch (65535 clocks) and init
        repeat (70000) @(posedge clk_50);
        status("after reset stretch");

        // stream 256 words of the PCXT BIOS (index 0) then a few of the EGA BIOS (index 3)
        rom_index    = 8'h00;
        rom_download = 1'b1;
        @(posedge clk_50);
        status("download raised");
        for (int i = 0; i < 256; i++) send_word(i*2, 16'hA500 + i);
        status("after 256 PCXT words");
        rom_download = 1'b0;
        repeat (500) @(posedge clk_50);

        rom_index    = 8'h03;
        rom_download = 1'b1;
        for (int i = 0; i < 64; i++) send_word(i*2, 16'h3C00 + i);
        status("after 64 EGA words");
        rom_download = 1'b0;
        repeat (500) @(posedge clk_50);

        // check what landed in memory: PCXT at F0000, EGA at C0000
        $display("mem[F0000..F0003] = %02x %02x %02x %02x (expect 00 a5 01 a5)", mem[20'hF0000], mem[20'hF0001], mem[20'hF0002], mem[20'hF0003]);
        $display("mem[C0000..C0003] = %02x %02x %02x %02x (expect 00 3c 01 3c)", mem[20'hC0000], mem[20'hC0001], mem[20'hC0002], mem[20'hC0003]);
        $display("bios_missing_pcxt=%0d bios_missing_ega=%0d splash_active=%0d", bios_missing_pcxt, bios_missing_ega, splash_active);
        if (stalls == 0 && mem[20'hF0001] == 8'ha5 && mem[20'hC0001] == 8'h3c) $display("RESULT: PASS");
        else $display("RESULT: FAIL (stalls=%0d)", stalls);
        $finish;
    end

    // periodic heartbeat so a stall is visible
    always begin
        repeat (50000) @(posedge clk_50);
        status("tick");
    end

endmodule
