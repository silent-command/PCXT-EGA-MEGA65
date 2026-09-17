// ramtest_sys_tb.sv
//
// The 8088 BIOS (skiselev, MACHINE_XT build = sdcard/bios/pcxt-xt.rom) POST RAM
// test on the MEGA65 memory path, with the real CPU and chipset:
//
//   * rtl/8088 i8088 (MCL86 EU + max-mode BIU)            the CPU, 100 MHz core clock
//   * XT_CE_Generator                                      4.77 / 7.16 / 9.54 / Max
//   * BUS_ARBITER (KF8288 + KF8237 overlay + page regs)    the real bus, DRAM-refresh DMA on channel 0
//   * READY                                                the real wait-state logic
//   * RAM.sv overlay + KFSDRAM overlay                     the MEGA65 memory front end (strict READY, lookahead)
//   * ramtest_mem_model.vhd = mem_backend.vhd + the framework's HyperRAM path (avm_arbit_general with
//     scaler/QNICE traffic, hyperram_errata/config/ctrl, HyperBus device model); -d USE_HR_MODEL swaps in
//     mem_backend_tb.vhd's compact random-latency hr_model instead (pessimistic: reproduces the Max fault reliably)
//   * KF8259, KF8253, KF8255, KFPS2KB (+Send_Data), keyboard_warm_reset, the MEGA65 PS/2 keyboard
//   * a verbatim copy of the Peripherals.sv / Chipset.sv / PCXT-EGA.sv glue
//
// The BIOS image is streamed into mem_backend through its ROM port exactly as
// rom_loader.vhd does (16 KB file -> FC000).  B8000 text RAM and the CRT status
// register are bench stand-ins (no EGA ROM: CGA fallback).  Memory above RAMKB
// (default 64) reads FF and drops writes, like an XT with fewer DIMMs, so that
// detect_ram sizes 64 KB and test_ram runs the 32 KB and 48 KB blocks only.
//
// Observers
//   * every OUT 80h (POST code)
//   * a shadow memory fed from the byte RAM.sv accepts; every byte the BIU
//     samples on a memory read is compared against it (only addresses that
//     have been written since reset are checked)
//   * a ring log of bus events (ALE, MEMR/MEMW strobes, RAM.sv accept /
//     complete, BIU sample, DMA acknowledge, AEN), dumped on the first
//     mismatch and on the BIOS's own verdict
//   * the verdict itself: test_ram writes memory_size (0040:0013) only on
//     .test_error; a POST code written while the 32 KB block is under test and
//     no such write happened is e_ram_complete.
//
//   xsim ramtest_sys_sim -R -testplusarg SPEED=3 [-testplusarg RAMKB=64] [-testplusarg NOPATCH] [-testplusarg RING=512]
//                       [-testplusarg TRACE] (events to trace.txt from POST 04 = first 32 KB test, and from ram_test_block on)
//
// Run with run_ramtest_sys_tb.ps1.

`timescale 1ns/1ps

module ramtest_sys_tb;

    // ------------------------------------------------------------------ clocks / reset
    logic clk_100 = 1'b1;  always #5  clk_100 = ~clk_100;     // MCL86 CORE_CLK and the HyperRAM side (hr_clk)
    logic clk     = 1'b1;  always #10 clk     = ~clk;         // chipset clock (rising edges coincide)
    logic reset      = 1'b1;
    logic reset_cold = 1'b1;
    // MEGA65 reset button (-testplusarg BUTTON=<ns>): at the first HyperRAM read outstanding after
    // <ns> the framework's hr_rst (reset_core_n) and the CPU reset (status[0]) are asserted together,
    // exactly as on hardware; RAM.sv/KFSDRAM and the ROM presence latches are NOT reset (reset_sdram
    // follows the clock lock only). The BIOS must then POST again: on the RTL before the mem_backend
    // fix KFSDRAM waits for the readdatavalid of the read lost in the reset and the CPU hangs.
    logic hr_button  = 1'b0;

    logic [1:0] clk_select = 2'b00;
    integer     speed_arg  = 0;
    integer     ram_kb     = 64;
    integer     button_at  = 0;
    initial begin
        if ($value$plusargs("SPEED=%d", speed_arg)) clk_select = speed_arg[1:0];
        if (!$value$plusargs("RAMKB=%d", ram_kb)) ram_kb = 64;
        if (!$value$plusargs("BUTTON=%d", button_at)) button_at = 0;
    end
    wire [21:0] ram_limit = ram_kb * 1024;

    // ------------------------------------------------------------------ results
    integer errors = 0;
    task check(input logic cond, input string msg);
        if (!cond) begin errors = errors + 1; $display("  CHECK FAILED: %s   (t=%0t)", msg, $time); end
    endtask

    // ==================================================================
    //  XT_CE_Generator (PCXT-EGA.sv)
    // ==================================================================
    wire        clk_cpu, cpu_ce_posedge, cpu_ce_negedge, peripheral_ce;
    wire        cycle_accrate, shift_read_timing;
    wire [7:0]  clock_cycle_counter_division_ratio, clock_cycle_counter_decrement_value;
    wire [1:0]  ram_read_wait_cycle, ram_write_wait_cycle;

    XT_CE_Generator u_XT_CE_Generator (
        .clock(clk), .reset(reset),
        .clk_select_load(1'b1), .clk_select(clk_select),
        .cpu_clk_pin(clk_cpu), .cpu_ce_posedge(cpu_ce_posedge), .cpu_ce_negedge(cpu_ce_negedge),
        .peripheral_ce(peripheral_ce), .cycle_accrate(cycle_accrate),
        .clock_cycle_counter_division_ratio(clock_cycle_counter_division_ratio),
        .clock_cycle_counter_decrement_value(clock_cycle_counter_decrement_value),
        .shift_read_timing(shift_read_timing),
        .ram_read_wait_cycle(ram_read_wait_cycle), .ram_write_wait_cycle(ram_write_wait_cycle)
    );

    // ==================================================================
    //  CPU (PCXT-EGA.sv)
    // ==================================================================
    wire [19:0] cpu_ad_out;
    wire [7:0]  cpu_data_bus;
    wire [7:0]  data_bus;
    wire        lock_n;
    wire [2:0]  processor_status;
    wire        processor_ready;
    logic       interrupt_to_cpu;
    logic       pause_core;
    logic [19:0] cpu_address;

    i8088 B1 (
        .CORE_CLK(clk_100), .CLK(clk_cpu), .RESET(reset),
        .READY(processor_ready && ~pause_core), .NMI(1'b0), .INTR(interrupt_to_cpu),
        .ad_out(cpu_ad_out), .dout(cpu_data_bus), .din(data_bus),
        .lock_n(lock_n), .s6_3_mux(), .s2_s0_out(processor_status), .SEGMENT(),
        .biu_done(),
        .cycle_accrate(cycle_accrate),
        .clock_cycle_counter_division_ratio(clock_cycle_counter_division_ratio),
        .clock_cycle_counter_decrement_value(clock_cycle_counter_decrement_value),
        .shift_read_timing(shift_read_timing),
        .is8086(1'b0), .fake286_flags(1'b0),
        .word_read_request(), .word_write_request(), .data_bus_word_out(),
        .data_bus_word(16'h0000), .word_access_possible(1'b0)
    );

    wire address_latch_enable;
    always @(posedge clk) if (address_latch_enable) cpu_address <= cpu_ad_out;   // PCXT-EGA.sv

    // ==================================================================
    //  Bus arbiter + ready (Chipset.sv)
    // ==================================================================
    wire        dma_ready, dma_wait_n, interrupt_acknowledge_n;
    wire [19:0] address;
    logic [7:0] data_bus_ext;
    wire [7:0]  internal_data_bus;
    wire        internal_data_bus_direction;
    wire        io_read_n, io_write_n, memory_read_n, memory_write_n;
    wire        no_command_state;
    wire [3:0]  dma_acknowledge_n;
    wire        address_enable_n;
    logic       DRQ0, prev_timer_count_1;
    wire [2:0]  timer_counter_out;

    // Chipset.sv DRAM refresh request flip-flop
    always_ff @(posedge clk)
        if (reset) prev_timer_count_1 <= 1'b1; else prev_timer_count_1 <= timer_counter_out[1];
    always_ff @(posedge clk, posedge reset)
        if (reset) DRQ0 <= 1'b0;
        else if (~dma_acknowledge_n[0]) DRQ0 <= 1'b0;
        else if (~prev_timer_count_1 & timer_counter_out[1]) DRQ0 <= 1'b1;

    // Chipset.sv I/O settle guard
    logic [2:0] io_settle_count; logic prev_io_active;
    wire io_active = ~io_read_n | ~io_write_n;
    always_ff @(posedge clk, posedge reset)
        if (reset) begin prev_io_active <= 1'b0; io_settle_count <= 3'd0; end
        else begin
            prev_io_active <= io_active;
            if (io_active && ~prev_io_active) io_settle_count <= (clk_select == 2'b11) ? 3'd4 : 3'd0;
            else if (io_settle_count != 3'd0) io_settle_count <= io_settle_count - 3'd1;
        end
    wire io_settle_ready = (io_settle_count == 3'd0);

    // chip selects (Peripherals.sv)
    wire iorq = ~io_read_n | ~io_write_n;
    logic [7:0] chip_select_n;
    always_comb begin
        if (iorq & ~address_enable_n & ~address[9] & ~address[8]) begin
            casez (address[7:5])
                3'b000: chip_select_n = 8'b11111110;
                3'b001: chip_select_n = 8'b11111101;
                3'b010: chip_select_n = 8'b11111011;
                3'b011: chip_select_n = 8'b11110111;
                3'b100: chip_select_n = 8'b11101111;
                3'b101: chip_select_n = 8'b11011111;
                3'b110: chip_select_n = 8'b10111111;
                3'b111: chip_select_n = 8'b01111111;
                default: chip_select_n = 8'b11111111;
            endcase
        end
        else chip_select_n = 8'b11111111;
    end
    wire dma_chip_select_n       = chip_select_n[0];
    wire interrupt_chip_select_n = chip_select_n[1];
    wire timer_chip_select_n     = chip_select_n[2];
    wire ppi_chip_select_n       = chip_select_n[3];
    wire dma_page_chip_select_n  = chip_select_n[4];

    wire memory_access_ready;

    READY u_READY (
        .clock(clk), .cpu_ce_posedge(cpu_ce_posedge), .cpu_ce_negedge(cpu_ce_negedge), .reset(reset),
        .processor_ready(processor_ready), .dma_ready(dma_ready), .dma_wait_n(dma_wait_n),
        .io_channel_ready(io_settle_ready & memory_access_ready),
        .io_read_n(io_read_n), .io_write_n(io_write_n), .memory_read_n(memory_read_n), .memory_write_n(memory_write_n),
        .dma0_acknowledge_n(dma_acknowledge_n[0]), .address_enable_n(address_enable_n), .clk_select(clk_select)
    );

    BUS_ARBITER u_BUS_ARBITER (
        .clock(clk), .cpu_ce_posedge(cpu_ce_posedge), .cpu_ce_negedge(cpu_ce_negedge), .reset(reset),
        .cpu_address(cpu_address), .cpu_data_bus(cpu_data_bus),
        .processor_status(processor_status), .processor_lock_n(lock_n), .processor_transmit_or_receive_n(),
        .dma_ready(dma_ready), .dma_wait_n(dma_wait_n),
        .interrupt_acknowledge_n(interrupt_acknowledge_n),
        .dma_chip_select_n(dma_chip_select_n), .dma_page_chip_select_n(dma_page_chip_select_n),
        .address(address), .address_ext(20'h00000), .address_direction(),
        .data_bus_ext(data_bus_ext), .internal_data_bus(internal_data_bus), .data_bus_direction(internal_data_bus_direction),
        .address_latch_enable(address_latch_enable),
        .io_read_n(io_read_n), .io_read_n_ext(1'b1), .io_read_n_direction(),
        .io_write_n(io_write_n), .io_write_n_ext(1'b1), .io_write_n_direction(),
        .memory_read_n(memory_read_n), .memory_read_n_ext(1'b1), .memory_read_n_direction(),
        .memory_write_n(memory_write_n), .memory_write_n_ext(1'b1), .memory_write_n_direction(),
        .no_command_state(no_command_state), .ext_access_request(1'b0),
        .dma_request({3'b000, DRQ0}), .dma_acknowledge_n(dma_acknowledge_n),
        .address_enable_n(address_enable_n), .terminal_count_n()
    );
    assign data_bus = internal_data_bus;                          // Chipset.sv

    // ==================================================================
    //  Memory: RAM.sv overlay -> KFSDRAM overlay -> mem_backend + hr_model
    // ==================================================================
    wire [7:0]  ram_data_out;
    wire        ram_address_select_n, initilized_sdram;
    wire [12:0] sdram_address;
    wire        sdram_cke, sdram_cs, sdram_ras, sdram_cas, sdram_we, sdram_dq_io, sdram_ldqm, sdram_udqm;
    wire [1:0]  sdram_ba;
    wire [15:0] sdram_dq_out;
    logic [15:0] sdram_dq_in;
    logic [6:0] map_ems [0:3];
    initial begin map_ems[0] = 7'd0; map_ems[1] = 7'd0; map_ems[2] = 7'd0; map_ems[3] = 7'd0; end

    RAM u_RAM (
        .clock(clk), .reset(reset_cold), .enable_sdram(1'b1), .initilized_sdram(initilized_sdram),
        .address(address), .internal_data_bus(internal_data_bus), .data_bus_out(ram_data_out),
        .word_read_request(1'b0), .word_write_request(1'b0), .data_bus_in_word(16'h0000), .data_bus_out_word(),
        .memory_read_n(memory_read_n), .memory_write_n(memory_write_n), .no_command_state(no_command_state),
        .memory_access_ready(memory_access_ready), .ram_address_select_n(ram_address_select_n),
        .sdram_address(sdram_address), .sdram_cke(sdram_cke), .sdram_cs(sdram_cs), .sdram_ras(sdram_ras),
        .sdram_cas(sdram_cas), .sdram_we(sdram_we), .sdram_ba(sdram_ba),
        .sdram_dq_in(sdram_dq_in), .sdram_dq_out(sdram_dq_out), .sdram_dq_io(sdram_dq_io),
        .sdram_ldqm(sdram_ldqm), .sdram_udqm(sdram_udqm),
        .map_ems(map_ems), .ems_b1(1'b0), .ems_b2(1'b0), .ems_b3(1'b0), .ems_b4(1'b0),
        .umb_enabled(1'b0), .bios_protect_flag(3'b011),
        .wait_count_clk_en(cpu_ce_negedge),
        .ram_read_wait_cycle(ram_read_wait_cycle), .ram_write_wait_cycle(ram_write_wait_cycle),
        .clk_select(clk_select)
    );

    // the re-purposed SDRAM pins (main.vhd)
    wire [21:0] avm_address   = {sdram_dq_out[15:9], sdram_ba, sdram_address};
    wire [7:0]  avm_writedata = sdram_dq_out[7:0];
    wire        avm_read      = ~sdram_ras;
    wire        avm_write     = ~sdram_we;
    wire [7:0]  m_readdata;
    wire        m_readdatavalid, m_waitrequest;

    // unpopulated RAM above RAMKB: reads FF, writes dropped, zero wait
    wire        hole = (avm_address >= ram_limit) && (avm_address < 22'h0A0000);
    logic       hole_rdv = 1'b0;
    always_ff @(posedge clk) hole_rdv <= avm_read & hole;
    wire        avm_waitrequest   = hole ? 1'b0 : m_waitrequest;
    wire        avm_readdatavalid = m_readdatavalid | hole_rdv;
    wire [7:0]  avm_readdata      = m_readdatavalid ? m_readdata : 8'hFF;
    assign sdram_dq_in = {6'b000000, avm_readdatavalid, avm_waitrequest, avm_readdata};

    // reads the backend has accepted and not yet answered (its out_count, mirrored on the bench side;
    // ROM-window reads answer one clock later, HyperRAM reads take tens of clocks)
    integer hr_outstanding = 0;
    always_ff @(posedge clk) begin
        if (!reset_cold)
            hr_outstanding <= hr_outstanding + ((avm_read & ~hole & ~m_waitrequest) ? 1 : 0) - (m_readdatavalid ? 1 : 0);
    end

    logic        rom_wr = 1'b0;
    logic [7:0]  rom_index = 8'h00;
    logic [24:0] rom_addr = 25'd0;
    logic [15:0] rom_data = 16'h0000;

`ifdef USE_HR_MODEL
    localparam int G_REAL = 0;     // hr_model: compact random-latency HyperRAM model
`else
    localparam int G_REAL = 1;     // framework arbiter + scaler/QNICE traffic + hyperram_ctrl + HyperBus device
`endif
    ramtest_mem_model #(.G_SEED(1), .G_REAL(G_REAL)) u_mem (
        .clk_i(clk), .rst_i(reset_cold), .hr_clk_i(clk_100), .hr_rst_i(reset_cold | hr_button),
        .avm_address_i(avm_address), .avm_writedata_i(avm_writedata),
        .avm_write_i(avm_write & ~hole), .avm_read_i(avm_read & ~hole),
        .avm_readdata_o(m_readdata), .avm_readdatavalid_o(m_readdatavalid), .avm_waitrequest_o(m_waitrequest),
        .rom_wr_i(rom_wr), .rom_index_i(rom_index), .rom_addr_i(rom_addr), .rom_data_i(rom_data)
    );


    // B8000 text RAM (bench stand-in for the video card)
    logic [7:0] text [0:32767];
    wire text_select = (address[19:15] == 5'b10111);          // B8000-BFFFF
    always_ff @(posedge clk)
        if (~memory_write_n && text_select) text[address[14:0]] <= internal_data_bus;

    // Chipset.sv data bus return mux
    logic [7:0] data_bus_out;                                     // peripheral read data (registered)
    logic       data_bus_out_from_chipset;
    always_comb begin
        if (data_bus_out_from_chipset)                     data_bus_ext = data_bus_out;
        else if (~ram_address_select_n && ~memory_read_n)  data_bus_ext = ram_data_out;
        else if (~memory_read_n && text_select)            data_bus_ext = text[address[14:0]];
        else                                               data_bus_ext = 8'h00;
    end

    // ==================================================================
    //  8259 / 8253 / 8255 / KFPS2KB / keyboard (as in kbd_bios_sys_tb.sv)
    // ==================================================================
    logic       timer_interrupt, keybord_interrupt;
    logic [7:0] interrupt_data_bus_out;
    logic       interrupt_to_cpu_buf;

    KF8259 u_KF8259 (
        .clock(clk), .reset(reset),
        .chip_select_n(interrupt_chip_select_n), .read_enable_n(io_read_n), .write_enable_n(io_write_n),
        .address(address[0]), .data_bus_in(internal_data_bus), .data_bus_out(interrupt_data_bus_out),
        .cascade_in(3'b000), .slave_program_n(1'b1),
        .interrupt_acknowledge_n(interrupt_acknowledge_n), .interrupt_to_cpu(interrupt_to_cpu_buf),
        .interrupt_request({6'b000000, keybord_interrupt, timer_interrupt})
    );
    always_ff @(posedge clk, posedge reset)
        if (reset) interrupt_to_cpu <= 1'b0;
        else if (cpu_ce_negedge) interrupt_to_cpu <= interrupt_to_cpu_buf;

    logic timer_clock = 1'b0;
    always_ff @(posedge clk, posedge reset)
        if (reset) timer_clock <= 1'b0; else if (peripheral_ce) timer_clock <= ~timer_clock;
    logic [7:0] timer_data_bus_out;
    logic [7:0] port_b_out; logic port_b_io;
    wire tim2gatespk = port_b_out[0] & ~port_b_io;
    KF8253 u_KF8253 (
        .clock(clk), .reset(reset),
        .chip_select_n(timer_chip_select_n), .read_enable_n(io_read_n), .write_enable_n(io_write_n),
        .address(address[1:0]), .data_bus_in(internal_data_bus), .data_bus_out(timer_data_bus_out),
        .counter_0_clock(timer_clock), .counter_0_gate(1'b1), .counter_0_out(timer_counter_out[0]),
        .counter_1_clock(timer_clock), .counter_1_gate(1'b1), .counter_1_out(timer_counter_out[1]),
        .counter_2_clock(timer_clock), .counter_2_gate(tim2gatespk), .counter_2_out(timer_counter_out[2])
    );
    assign timer_interrupt = timer_counter_out[0];

    logic [7:0] ppi_data_bus_out, port_a_in, port_a_out, port_c_out, port_c_io, port_c_in;
    logic       port_a_io;
    wire  [7:0] sw = {2'b01, 2'b00, 4'b1101};
    assign port_c_in[3:0] = port_b_out[3] ? sw[7:4] : sw[3:0];
    assign port_c_in[7:4] = 4'b0000;
    KF8255 u_KF8255 (
        .clock(clk), .reset(reset),
        .chip_select_n(ppi_chip_select_n), .read_enable_n(io_read_n), .write_enable_n(io_write_n),
        .address(address[1:0]), .data_bus_in(internal_data_bus), .data_bus_out(ppi_data_bus_out),
        .port_a_in(port_a_in), .port_a_out(port_a_out), .port_a_io(port_a_io),
        .port_b_in(port_b_out), .port_b_out(port_b_out), .port_b_io(port_b_io),
        .port_c_in(port_c_in), .port_c_out(port_c_out), .port_c_io(port_c_io)
    );

    logic ps2_clock, ps2_data, ps2_clock_out, ps2_data_out, ps2_send_clock, keybord_irq;
    logic [7:0] keycode_buf, keycode;
    logic prev_ps2_reset_n, lock_recv_clock;
    wire  keyboard_warm_reset_active;
    wire  clear_keycode = port_b_out[7];
    wire  ps2_reset_n   = port_b_out[6];
    always_ff @(posedge clk, posedge reset)
        if (reset) prev_ps2_reset_n <= 1'b0; else prev_ps2_reset_n <= ps2_reset_n;
    KFPS2KB #(.over_time(16'd1000)) u_KFPS2KB (
        .clock(clk), .peripheral_ce(peripheral_ce), .reset(reset),
        .device_clock(ps2_clock | lock_recv_clock), .device_data(ps2_data),
        .irq(keybord_irq), .keycode(keycode_buf), .clear_keycode(clear_keycode), .pause_core(pause_core)
    );
    assign keycode = ps2_reset_n ? keycode_buf : 8'h80;
    keyboard_warm_reset #(.HOLD_CYCLES(16'd5000)) keyboard_warm_reset_detect (
        .clock(clk), .reset(reset), .keycode_irq(keybord_irq), .keycode(keycode), .warm_reset_active(keyboard_warm_reset_active)
    );
    KFPS2KB_Send_Data u_KFPS2KB_Send_Data (
        .clock(clk), .peripheral_ce(peripheral_ce), .reset(reset),
        .device_clock(ps2_clock), .device_clock_out(ps2_send_clock), .device_data_out(ps2_data_out),
        .sending_data_flag(lock_recv_clock),
        .send_request(~prev_ps2_reset_n & ps2_reset_n), .send_data(8'hFF)
    );
    always_ff @(posedge clk, posedge reset)
        if (reset) ps2_clock_out = 1'b1; else ps2_clock_out = ~(keybord_irq | ~ps2_send_clock | ~ps2_reset_n);

    logic keybord_interrupt_ff;
    always_ff @(posedge clk, posedge reset)
        if (reset) begin keybord_interrupt_ff <= 1'b0; keybord_interrupt <= 1'b0; end
        else begin keybord_interrupt_ff <= keybord_irq; keybord_interrupt <= keybord_interrupt_ff; end
    logic [7:0] keycode_ff;
    always_ff @(posedge clk, posedge reset)
        if (reset) begin keycode_ff <= 8'h00; port_a_in <= 8'h00; end
        else begin keycode_ff <= keycode; port_a_in <= keycode_ff; end

    // free-running CRT status register (3DAh / 3BAh) so the CGA/MDA fallback never spins
    logic [19:0] crt_cnt = 20'd0;
    always_ff @(posedge clk) crt_cnt <= crt_cnt + 20'd1;
    wire [7:0] crt_status = {4'b0000, crt_cnt[18], 2'b00, crt_cnt[7]};
    wire crt_status_select = ~address_enable_n && ((address[15:0] == 16'h03DA) || (address[15:0] == 16'h03BA));

    // Peripherals.sv registered read mux
    always_ff @(posedge clk) begin
        if (~interrupt_acknowledge_n)                          begin data_bus_out_from_chipset <= 1'b1; data_bus_out <= interrupt_data_bus_out; end
        else if ((~interrupt_chip_select_n) && (~io_read_n))  begin data_bus_out_from_chipset <= 1'b1; data_bus_out <= interrupt_data_bus_out; end
        else if ((~timer_chip_select_n) && (~io_read_n))      begin data_bus_out_from_chipset <= 1'b1; data_bus_out <= timer_data_bus_out; end
        else if ((~ppi_chip_select_n) && (~io_read_n))        begin data_bus_out_from_chipset <= 1'b1; data_bus_out <= ppi_data_bus_out; end
        else if (crt_status_select && (~io_read_n))           begin data_bus_out_from_chipset <= 1'b1; data_bus_out <= crt_status; end
        else                                                  begin data_bus_out_from_chipset <= 1'b0; data_bus_out <= 8'h00; end
    end

    // the MEGA65 keyboard (no key is ever pressed; the device answers the BIOS's reset)
    integer      key_num = 0;
    logic        key_pressed_n = 1'b1;
    wire         dev_clk, dev_data;
    wire [10:0]  ps2_key;
    keyboard u_keyboard (
        .clk_main_i(clk), .rst_i(reset_cold),
        .key_num_i(key_num), .key_pressed_n_i(key_pressed_n),
        .ps2_host_clk_i(ps2_clock_out), .ps2_host_data_i(ps2_data_out),
        .ps2_clk_o(dev_clk), .ps2_data_o(dev_data), .ps2_key_o(ps2_key)
    );
    initial begin
        #3;
        forever for (int k = 0; k < 80; k++) begin key_num = k; #12500; end
    end
    logic device_clock_ff, device_data_ff;
    always_ff @(negedge clk, posedge reset)
        if (reset) begin device_clock_ff <= 1'b0; ps2_clock <= 1'b0; device_data_ff <= 1'b0; ps2_data <= 1'b0; end
        else begin device_clock_ff <= dev_clk; ps2_clock <= device_clock_ff; device_data_ff <= dev_data; ps2_data <= device_data_ff; end

    // ==================================================================
    //  Observers
    // ==================================================================
    wire [7:0] pic_imr = u_KF8259.interrupt_mask;

    // RAM.sv state (enum: IDLE=0 RAM_WRITE_1 RAM_WRITE_2 RAM_READ_1 RAM_READ_2 COMPLETE_RAM_RW=5 WAIT=6)
    wire [2:0] ram_state   = u_RAM.state;
    wire       ram_idle    = (ram_state == 3'd0);
    wire       ram_complete= (ram_state == 3'd5);
    wire       ram_wcmd    = u_RAM.write_command;
    wire       ram_rcmd    = u_RAM.read_command;
    wire       ram_hit     = u_RAM.lookahead_hit;
    wire [21:0] ram_laddr  = u_RAM.latch_address;
    wire [7:0] ram_dreg    = u_RAM.data_bus_out_reg;
    wire [7:0] biu_state   = B1.u_biu_core.biu_state;
    wire [2:0] biu_sbits   = B1.u_biu_core.s_bits;
    wire [7:0] biu_latched = B1.u_biu_core.latched_data_in;
    wire [7:0] biu_ad_in   = B1.u_biu_core.ad_in_int;

    // shadow memory: what RAM.sv accepted
    logic [7:0] shadow  [0:1048575];
    logic       written [0:1048575];

    // ring log
    integer ring_n = 512;
    initial if (!$value$plusargs("RING=%d", ring_n)) ring_n = 512;
    localparam RING_MAX = 4096;
    real     r_time [0:RING_MAX-1];
    byte     r_kind [0:RING_MAX-1];
    logic [21:0] r_addr [0:RING_MAX-1];
    logic [7:0]  r_data [0:RING_MAX-1];
    logic [31:0] r_info [0:RING_MAX-1];
    integer  r_wp = 0, r_cnt = 0;

    // optional full trace of the same events to trace.txt (-testplusarg TRACE), from POST code 54 on
    integer  trace_fd = 0, trace_events = 0;
    logic    trace_on = 1'b0;
    initial begin
        if ($test$plusargs("TRACE")) trace_fd = $fopen("trace.txt", "w");
        if ($test$plusargs("TRACEALL")) trace_on = 1'b1;
    end

    task automatic ring_put(input byte kind, input logic [21:0] a, input logic [7:0] d, input logic [31:0] info);
        r_time[r_wp] = $realtime; r_kind[r_wp] = kind; r_addr[r_wp] = a; r_data[r_wp] = d; r_info[r_wp] = info;
        r_wp = (r_wp + 1) % ring_n;
        if (r_cnt < ring_n) r_cnt++;
        if (trace_fd != 0 && trace_on && trace_events < 600000) begin
            trace_events++;
            $fwrite(trace_fd, "%12.1f %s a=%05x d=%02x x=%02x st=%03b aen=%0d dack0=%0d rdy=%0d mar=%0d ram=%0d hit=%0d dmaw_n=%0d hak=%0d drq0=%0d memr_n=%0d memw_n=%0d biu=%02x\n",
                    $realtime, string'(kind), a, d, info[18:11], info[2:0], info[3], info[4], info[5], info[6], info[9:7], info[10], info[19], info[20], info[21], info[22], info[23], info[31:24]);
        end
    endtask

    // info word layout: [2:0] processor_status, [3] AEN (address_enable_n), [4] dack0 active, [5] processor_ready,
    //                   [6] memory_access_ready, [9:7] ram_state, [10] lookahead hit, [18:11] expected/extra byte,
    //                   [19] dma_wait_n, [20] hold_ack, [21] DRQ0, [22] mem_read_n, [23] mem_write_n, [31:24] biu_state
    function automatic logic [31:0] snap(input logic [7:0] extra);
        snap = {biu_state, memory_write_n, memory_read_n, DRQ0, u_BUS_ARBITER.hold_acknowledge, dma_wait_n,
                extra, ram_hit, ram_state, memory_access_ready, processor_ready, ~dma_acknowledge_n[0], address_enable_n, processor_status};
    endfunction

    task automatic ring_dump(input string why);
        integer i, k;
        logic [31:0] f;
        $display("  ---- bus ring (%0d events, oldest first): %s", r_cnt, why);
        $display("       kind: A=ALE(cpu addr,status) M=MEMW strobe m=MEMR strobe W=RAM.sv write accepted R=RAM.sv read accepted");
        $display("             c=RAM.sv read complete S=BIU sampled byte (data=got, x=expected) D/d=DACK0 on/off E/e=AEN on/off I=INTA Y=ready");
        k = (r_cnt < ring_n) ? 0 : r_wp;
        for (i = 0; i < r_cnt; i++) begin
            f = r_info[k];
            $display("    %12.1f %s a=%05x d=%02x x=%02x st=%03b aen=%0d dack0=%0d rdy=%0d mar=%0d ram=%0d hit=%0d dmaw_n=%0d hak=%0d drq0=%0d memr_n=%0d memw_n=%0d biu=%02x",
                     r_time[k], string'(r_kind[k]), r_addr[k], r_data[k], f[18:11], f[2:0], f[3], f[4], f[5], f[6], f[9:7], f[10], f[19], f[20], f[21], f[22], f[23], f[31:24]);
            k = (k + 1) % ring_n;
        end
        $display("  ---- end of ring");
    endtask

    integer mismatches = 0, mismatch_dumps = 0;
    integer post_codes = 0;
    integer dma_cycles = 0, dma_cycles_in_test = 0;
    integer ram_writes = 0, ram_reads = 0, memw_strobes = 0, memr_strobes = 0;
    logic   in_test = 1'b0;          // the 32 KB block is being written by ram_test_block
    logic   verdict_fail = 1'b0, verdict_pass = 1'b0, verdict_lowfail = 1'b0;
    logic   strobe_accepted = 1'b0;
    integer dropped_writes = 0;
    logic [7:0] memsize_lo = 8'h00;
    integer memsize_writes = 0;
    logic   prev_ale = 1'b0, prev_memw = 1'b1, prev_memr = 1'b1, prev_dack0 = 1'b1, prev_aen = 1'b0, prev_iow = 1'b1, prev_inta = 1'b1, prev_pready = 1'b0;
    logic [7:0] prev_biu_state = 8'h00;
    logic [7:0] last_post = 8'h00;
    logic [2:0] prev_ram_state = 3'd0;

    // chipset-clock observers
    always @(posedge clk) begin
        prev_ale   <= address_latch_enable;
        prev_memw  <= memory_write_n;
        prev_memr  <= memory_read_n;
        prev_dack0 <= dma_acknowledge_n[0];
        prev_aen   <= address_enable_n;
        prev_iow   <= io_write_n;
        prev_inta  <= interrupt_acknowledge_n;
        prev_pready<= processor_ready;

        if (address_latch_enable & ~prev_ale) ring_put("A", {2'b00, cpu_ad_out}, cpu_data_bus, snap(8'h00));
        if (~memory_write_n & prev_memw) begin memw_strobes++; strobe_accepted <= 1'b0; ring_put("M", {2'b00, address}, internal_data_bus, snap(8'h00)); end
        if (memory_write_n & ~prev_memw & ~address_enable_n & ~ram_address_select_n & ~strobe_accepted & (address < ram_limit)) begin
            dropped_writes++;
            if (dropped_writes <= 5) begin
                $display("  *** WRITE DROPPED #%0d at %0t: MEMW strobe to %05x (data %02x) ended without RAM.sv accepting it (ram_state=%0d)", dropped_writes, $time, address, internal_data_bus, ram_state);
                ring_dump("events before the dropped write");
            end
        end
        if (~memory_read_n  & prev_memr) begin memr_strobes++; ring_put("m", {2'b00, address}, 8'h00, snap(8'h00)); end
        if (~dma_acknowledge_n[0] & prev_dack0) begin dma_cycles++; if (in_test) dma_cycles_in_test++; ring_put("D", {2'b00, address}, 8'h00, snap(8'h00)); end
        if (dma_acknowledge_n[0] & ~prev_dack0) ring_put("d", {2'b00, address}, 8'h00, snap(8'h00));
        if (address_enable_n & ~prev_aen) ring_put("E", {2'b00, address}, 8'h00, snap(8'h00));
        if (~address_enable_n & prev_aen) ring_put("e", {2'b00, address}, 8'h00, snap(8'h00));
        if (~interrupt_acknowledge_n & prev_inta) ring_put("I", {2'b00, address}, 8'h00, snap(8'h00));
        if (processor_ready & ~prev_pready) ring_put("Y", {2'b00, address}, data_bus, snap(8'h00));

        // RAM.sv acceptance (the byte/address it will commit) and completion
        if (ram_idle && ram_wcmd) begin
            shadow[address]  <= internal_data_bus;
            written[address] <= 1'b1;
            ram_writes++;
            strobe_accepted <= 1'b1;
            ring_put("W", {2'b00, address}, internal_data_bus, snap(8'h00));
            if (address == 20'h08000 && internal_data_bus == 8'hAA && !in_test) begin
                in_test = 1'b1;
                trace_on = 1'b1;
                $display("  [%0t] ram_test_block(32 KB) started: first write AA -> 08000 (DMA refresh cycles so far %0d)", $time, dma_cycles);
            end
            if (address == 20'h00413) begin memsize_lo <= internal_data_bus; end
            if (address == 20'h00414) begin
                memsize_writes++;
                $display("  [%0t] memory_size (0040:0013) <- %0d KB  (write #%0d)", $time, {internal_data_bus, memsize_lo}, memsize_writes);
                if (in_test && !verdict_fail) begin
                    verdict_fail = 1'b1;
                    $display("  *** BIOS VERDICT: test_ram .test_error, faulty memory reported at %0d KB", {internal_data_bus, memsize_lo});
                end
            end
        end
        if (ram_idle && ram_rcmd) begin
            ram_reads++;
            ring_put("R", {2'b00, address}, 8'h00, snap({7'b0, ram_hit}));
        end
        if (ram_complete && (prev_ram_state != 3'd5))
            ring_put("c", ram_laddr, ram_dreg, snap(8'h00));
        prev_ram_state <= ram_state;

        // the low_ram_fail beep loop: an OUT 61h while the last POST code is still 54 (low RAM test)
        if (~io_write_n & prev_iow & ~address_enable_n && address[15:0] == 16'h0061 && last_post == 8'h54 && !verdict_lowfail) begin
            verdict_lowfail = 1'b1;
            $display("  *** BIOS VERDICT: low_ram_fail (first 32 KB test, no DMA/IRQ yet) - OUT 61h <- %02x", internal_data_bus);
        end
        // POST codes
        if (~io_write_n & prev_iow & ~address_enable_n && address[15:0] == 16'h0080) begin
            post_codes++;
            last_post = internal_data_bus;
            if (internal_data_bus == 8'h04 || internal_data_bus == 8'h54) trace_on = 1'b1;   // 04 = e_low_ram_test region: trace the first 32 KB RAM test
            $display("  [%0t] OUT 80h <- %02x   (DMA refresh cycles %0d, RAM writes %0d reads %0d, IMR %02x)", $time, internal_data_bus, dma_cycles, ram_writes, ram_reads, pic_imr);
            if (in_test && !verdict_fail && !verdict_pass) begin
                verdict_pass = 1'b1;
                $display("  *** BIOS VERDICT: POST code %02x after the RAM test without a memory_size write = e_ram_complete (test passed)", internal_data_bus);
            end
        end
    end

    // cycle-by-cycle dump of the READY path inside a window (-testplusarg CYCFROM=<ns> -testplusarg CYCTO=<ns>)
    integer cyc_from = 0, cyc_to = 0;
    initial begin
        if (!$value$plusargs("CYCFROM=%d", cyc_from)) cyc_from = 0;
        if (!$value$plusargs("CYCTO=%d", cyc_to)) cyc_to = 0;
    end
    always @(posedge clk) begin
        if ($time >= cyc_from && $time < cyc_to) begin
            $display("  CYC %10t clk=%0d ceP=%0d ceN=%0d st=%03b ale=%0d memr_n=%0d memw_n=%0d mc=%03b per=%0d | ram=%0d acc=%0d mar=%0d | rnw=%0d prev_rnw=%0d Qn=%0d ff1=%0d ff2=%0d dmaw_n=%0d aen=%0d dack0=%0d | biu=%02x ad=%05x bus=%05x d=%02x",
                     $time, clk_cpu, cpu_ce_posedge, cpu_ce_negedge, processor_status, address_latch_enable, memory_read_n, memory_write_n,
                     u_BUS_ARBITER.u_KF8288.machine_cycle, u_BUS_ARBITER.u_KF8288.machine_cycle_period,
                     ram_state, u_RAM.access_ready, memory_access_ready,
                     u_READY.ready_n_or_wait, u_READY.prev_ready_n_or_wait, u_READY.ready_n_or_wait_Qn, u_READY.processor_ready_ff_1, u_READY.processor_ready_ff_2,
                     dma_wait_n, address_enable_n, ~dma_acknowledge_n[0], biu_state, cpu_ad_out, address, internal_data_bus);
        end
    end

    // BIU sample point: biu_state 0x06 -> 0x07 right after latched_data_in was captured
    always @(posedge clk_100) begin
        prev_biu_state <= biu_state;
        if (biu_state == 8'h07 && prev_biu_state == 8'h06) begin
            if ((biu_sbits == 3'b100 || biu_sbits == 3'b101) && cpu_address < ram_limit && written[cpu_address]) begin
                ring_put("S", {2'b00, cpu_address}, biu_latched, snap(shadow[cpu_address]));
                if (biu_latched !== shadow[cpu_address]) begin
                    mismatches++;
                    if (mismatch_dumps < 3) begin
                        mismatch_dumps++;
                        $display("  *** READ MISMATCH #%0d at %0t: CPU %s at %05x sampled %02x, RAM.sv holds %02x (last accepted write); AEN=%0d dack0=%0d ram_state=%0d bus addr=%05x memr_n=%0d",
                                 mismatches, $time, (biu_sbits == 3'b100) ? "code fetch" : "data read", cpu_address, biu_latched, shadow[cpu_address],
                                 address_enable_n, ~dma_acknowledge_n[0], ram_state, address, memory_read_n);
                        ring_dump("first events before/at the mismatch");
                    end
                end
            end
            else if ((biu_sbits == 3'b100 || biu_sbits == 3'b101))
                ring_put("S", {2'b00, cpu_address}, biu_latched, snap(8'hFF));
        end
    end

    task automatic dump_text();
        integer row, col; logic [7:0] ch; string line; logic nonblank;
        $display("  ---- B8000 text screen (rows with content)");
        for (row = 0; row < 25; row++) begin
            line = ""; nonblank = 1'b0;
            for (col = 0; col < 80; col++) begin
                ch = text[(row * 80 + col) * 2];
                if (ch < 8'h20 || ch > 8'h7E) ch = 8'h20;
                if (ch != 8'h20) nonblank = 1'b1;
                line = {line, string'(ch)};
            end
            if (nonblank) $display("    %2d: %s", row, line);
        end
    endtask

    // ==================================================================
    //  ROM image
    // ==================================================================
    localparam string BIOS_FILE = "bios-xt.bin";
    integer fd, n;
    logic [7:0] rom [0:16383];

    task automatic patch3(input [7:0] b0, b1, b2, input [7:0] n1, n2, input string what);
        int hits = 0, at = -1;
        for (int i = 0; i < 16382; i++)
            if (rom[i] == b0 && rom[i+1] == b1 && rom[i+2] == b2) begin hits++; at = i; end
        if (hits == 1) begin rom[at+1] = n1; rom[at+2] = n2; $display("  sim-only ROM patch: %s at F000:%04X", what, at + 16'hC000); end
        else $display("  sim-only ROM patch: %s NOT applied (%0d matches)", what, hits);
    endtask
    task automatic patch3_all(input [7:0] b0, b1, b2, input [7:0] n1, n2, input string what);
        int hits = 0;
        for (int i = 0; i < 16382; i++)
            if (rom[i] == b0 && rom[i+1] == b1 && rom[i+2] == b2) begin rom[i+1] = n1; rom[i+2] = n2; hits++; end
        $display("  sim-only ROM patch: %s applied %0d times", what, hits);
    endtask

    // stream the image into mem_backend through its ROM port (rom_loader.vhd protocol: one word, then two idle clocks)
    task automatic load_rom();
        for (int i = 0; i < 8192; i++) begin
            @(posedge clk); #1;
            rom_wr = 1'b1; rom_index = 8'h00; rom_addr = i * 2; rom_data = {rom[2*i+1], rom[2*i]};
            @(posedge clk); #1;
            rom_wr = 1'b0;
            @(posedge clk); @(posedge clk);
        end
        // and zeros into the 16 KB EGA window (C0000-C3FFF, ROM index 3): its block RAM is
        // uninitialised in simulation, and the option ROM scan reads it for the 55AA signature
        for (int i = 0; i < 8192; i++) begin
            @(posedge clk); #1;
            rom_wr = 1'b1; rom_index = 8'h03; rom_addr = i * 2; rom_data = 16'h0000;
            @(posedge clk); #1;
            rom_wr = 1'b0;
            @(posedge clk); @(posedge clk);
        end
        repeat (8) @(posedge clk);
    endtask

    // ==================================================================
    //  Test
    // ==================================================================
    initial begin
        $display("=== ramtest_sys_tb: real MCL86 + 8088 BIOS XT + RAM.sv/KFSDRAM overlays + mem_backend/hr_model, CPU speed select %0d, RAM %0d KB ===", clk_select, ram_kb);
        for (int i = 0; i < 1048576; i++) begin shadow[i] = 8'h00; written[i] = 1'b0; end
        for (int i = 0; i < 32768; i++) text[i] = 8'h20;
        fd = $fopen(BIOS_FILE, "rb");
        if (fd == 0) begin $display("RESULT: FAIL (cannot open %s)", BIOS_FILE); $finish; end
        n = $fread(rom, fd); $fclose(fd);
        $display("  loaded %0d bytes of BIOS", n);
        check(n == 16384, "BIOS image is 16 KB");
        if (!$test$plusargs("NOPATCH")) begin
            patch3(8'hB9, 8'h00, 8'h15, 8'h10, 8'h00, "beepinit note delay cx=1500h -> 0010h (sound.inc:55)");
            patch3(8'hB9, 8'h00, 8'h30, 8'h10, 8'h00, "oplsound note delay cx=3000h -> 0010h (sound.inc:68)");
            patch3(8'hB9, 8'h56, 8'h29, 8'h40, 8'h01, "keyboard clock-low hold cx=10582 -> 320 (bios.asm:1059)");
            patch3(8'hB9, 8'hE8, 8'h03, 8'h0A, 8'h00, "kbd_flush 1000 -> 10 INT 16h calls (bios.asm:1067)");
            patch3(8'hB9, 8'h0A, 8'h1A, 8'h0A, 8'h00, "beep 0.1 s -> 150 us (sound.inc:123)");
            if (!$test$plusargs("FULLLOWTEST"))
                patch3_all(8'hB9, 8'h00, 8'h40, 8'h00, 8'h01, "mov cx,4000h -> 0100h (low RAM test word counts, bios.asm:889-909)");
        end
        check(rom[16'h3FF0] == 8'hEA, "reset vector is a far jump");

        #201;  reset_cold = 1'b0;
        #2000;
        load_rom();
        $display("  [%0t] BIOS streamed into mem_backend (ROM port), bios_base=%05x", $time, u_mem.i_backend.bios_base);
        #3000; reset = 1'b0;
        $display("  [%0t] reset released", $time);

        fork
            wait (verdict_fail || verdict_pass || verdict_lowfail);
            #3000ms;
        join_any
        disable fork;
        if (!(verdict_fail || verdict_pass)) $display("  *** no RAM test verdict within 3 s of simulated time");
        #200us;

        dump_text();
        $display("--- observations: speed=%0d DMA refresh cycles=%0d (in test %0d) RAM.sv writes=%0d reads=%0d MEMW strobes=%0d MEMR strobes=%0d read mismatches=%0d dropped writes=%0d memory_size writes=%0d POST codes=%0d last=%02x",
                 clk_select, dma_cycles, dma_cycles_in_test, ram_writes, ram_reads, memw_strobes, memr_strobes, mismatches, dropped_writes, memsize_writes, post_codes, last_post);
        if (verdict_fail || verdict_lowfail) ring_dump("state at the BIOS verdict");
        check(!verdict_lowfail, "BIOS low RAM test (first 32 KB, before DMA refresh) passed");
        check(dropped_writes == 0, "no MEMW strobe to RAM ended without RAM.sv accepting it");
        check(in_test, "ram_test_block reached the 32 KB block");
        check(!verdict_fail, "BIOS test_ram did not report faulty memory");
        check(mismatches == 0, "no CPU read returned something other than the last byte RAM.sv accepted");
        if (errors == 0) $display("RESULT: PASS (RAM test, speed %0d)", clk_select);
        else             $display("RESULT: FAIL (RAM test, speed %0d, %0d checks failed)", clk_select, errors);
        $finish;
    end

    // ------------------------------------------------------------------ reset button scenario
    // Hardware timing (M2M reset_manager -> clk_m2m/framework -> main.vhd): reset_core_n falls,
    // hr_rst (xpm_cdc_async_rst on hr_clk) and main_reset_core -> reset_soft_i -> status[0] ->
    // pcxt_core `reset` arrive within ~100 ns of each other; both stay for the press + 50 ms, the
    // CPU comes back 1.31 ms (the `reset` stretch) after the backend. Here: 100 us / 10 us.
    integer post_before = 0;
    initial begin
        if (button_at > 0) begin
            #(button_at * 1ns);
            // press at a moment with a HyperRAM read accepted and not yet answered (ROM reads answer
            // in one clock, so "outstanding for 4 clocks" means a HyperRAM read is in flight)
            forever begin
                @(posedge clk);
                if (hr_outstanding > 0) begin
                    repeat (3) @(posedge clk);
                    if (hr_outstanding > 0) break;
                end
            end
            $display("  [%0t] RESET BUTTON pressed: hr_rst_i + CPU reset (KFSDRAM state %0d, reads outstanding %0d, POST codes so far %0d, last %02x)",
                     $time, u_RAM.u_KFSDRAM.state, hr_outstanding, post_codes, last_post);
            hr_button = 1'b1;
            reset     = 1'b1;
            #100us;
            hr_button = 1'b0;
            $display("  [%0t] RESET BUTTON released: hr_rst_i low (KFSDRAM state %0d, reads outstanding %0d)",
                     $time, u_RAM.u_KFSDRAM.state, hr_outstanding);
            #10us;
            reset = 1'b0;
            post_before = post_codes;
            $display("  [%0t] CPU reset released after the button", $time);
            fork
                wait (post_codes >= post_before + 2);
                #5ms;
            join_any
            disable fork;
            $display("  [%0t] after the button: KFSDRAM state %0d (1=IDLE 4=READ_ISSUE), RAM.sv state %0d, reads outstanding %0d, POST codes since %0d (last %02x)",
                     $time, u_RAM.u_KFSDRAM.state, u_RAM.state, hr_outstanding, post_codes - post_before, last_post);
            if (post_codes >= post_before + 2)
                $display("BUTTON RESULT: PASS (the BIOS POSTs again after the reset button)");
            else
                $display("BUTTON RESULT: FAIL (no POST after the reset button: the CPU is hung on its first RAM access)");
            $finish;
        end
    end

    // progress
    initial begin
        forever begin
            #20ms;
            $display("  [%0t] ... running (IMR %02x, port B %02x, DMA cycles %0d, RAM writes %0d reads %0d, MEMW strobes %0d, mismatches %0d, dropped %0d, in_test %0d)",
                     $time, pic_imr, port_b_out, dma_cycles, ram_writes, ram_reads, memw_strobes, mismatches, dropped_writes, in_test);
        end
    end

endmodule
