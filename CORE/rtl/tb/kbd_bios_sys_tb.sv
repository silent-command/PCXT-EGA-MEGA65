// kbd_bios_sys_tb.sv
//
// The 8088 BIOS keyboard question, one level up from kbd_bios_tb: instead of a
// behavioural CPU replaying the BIOS's port sequence, the REAL CPU runs the REAL
// BIOS binary.
//
//   * rtl/8088 i8088 (MCL86 EU + max-mode BIU)           the CPU, at 100 MHz core clock
//   * XT_CE_Generator                                     4.77 MHz CPU clock, peripheral_ce
//   * BUS_ARBITER (KF8288 + KF8237 + page registers)     the real bus, with DRAM-refresh DMA
//   * READY                                               the real wait-state logic
//   * KF8259, KF8253, KF8255, KFPS2KB (+Send_Data), keyboard_warm_reset
//   * CORE/vhdl/keyboard.vhd + ps2_tx.vhd                 the MEGA65 PS/2 keyboard device
//   * a verbatim copy of the Peripherals.sv / Chipset.sv / PCXT-EGA.sv glue
//     between them (I/O decode, DRQ0 refresh flip-flop, io_settle, data bus
//     return mux, PS/2 input flip-flops, address latch)
//   * 640 KB of zero-wait RAM, B8000 text RAM, and the BIOS image at FC000
//     (SW/8088_bios/binaries/bios-xt.bin, the MACHINE_XT build).  No option
//     ROMs: the machine POSTs, finds nothing to boot and parks in int_18 (HLT
//     with interrupts enabled), where the keyboard is exactly as live as at a
//     DOS prompt.
//
// A 1 kHz MEGA65 key scan presses A, then Ctrl+Alt+Del, 60 ms after the BIOS
// unmasks the PIC (OCW1 = BCh, bios.asm:1097).  INT 9 is observed through the
// port 60h reads only it performs; Ctrl+Alt+Del through the 1234h warm-boot
// marker the BIOS writes to 0040:0072 before restarting (keyboard.inc:329-331).
//
// Sim-only ROM tweak (off with -testplusarg NOPATCH): the beepinit note delay
// (sound.inc:55, mov cx,1500h) is shortened so the POST reaches the keyboard
// test in a few hundred milliseconds of simulated time.  Nothing else is
// changed; the patched loop is a pure delay.
//
//   xsim kbd_bios_sys_sim -R                       4.77 MHz
//   xsim kbd_bios_sys_sim -R -testplusarg MAXSPEED  "Max" CPU speed setting
//
// Run with run_kbd_bios_sys_tb.ps1 (Vivado xsim, mixed language).

`timescale 1ns/1ps

module kbd_bios_sys_tb;

    // ------------------------------------------------------------------ clocks / reset
    logic clk_100 = 1'b1;  always #5  clk_100 = ~clk_100;     // MCL86 CORE_CLK
    logic clk     = 1'b1;  always #10 clk     = ~clk;         // chipset clock (rising edges coincide)
    logic reset      = 1'b1;
    logic reset_cold = 1'b1;

    logic [1:0] clk_select = 2'b00;
    initial if ($test$plusargs("MAXSPEED")) clk_select = 2'b11;

    // ------------------------------------------------------------------ results
    integer errors = 0;
    task check(input logic cond, input string msg);
        if (!cond) begin errors = errors + 1; $display("  CHECK FAILED: %s   (t=%0t)", msg, $time); end
    endtask

    // ==================================================================
    //  XT_CE_Generator (PCXT-EGA.sv:572-590)
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
    //  CPU (PCXT-EGA.sv:1361-1397)
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
    always @(posedge clk) if (address_latch_enable) cpu_address <= cpu_ad_out;   // PCXT-EGA.sv:1172-1178

    // ==================================================================
    //  Bus arbiter + ready (Chipset.sv:312-376)
    // ==================================================================
    wire        dma_ready, dma_wait_n, interrupt_acknowledge_n;
    wire [19:0] address;
    logic [7:0] data_bus_ext;
    wire [7:0]  internal_data_bus;
    wire        internal_data_bus_direction;
    wire        io_read_n, io_write_n, memory_read_n, memory_write_n;
    wire [3:0]  dma_acknowledge_n;
    wire        address_enable_n;
    logic       DRQ0, prev_timer_count_1;
    wire [2:0]  timer_counter_out;

    // Chipset.sv:296-311 DRAM refresh request flip-flop
    always_ff @(posedge clk)
        if (reset) prev_timer_count_1 <= 1'b1; else prev_timer_count_1 <= timer_counter_out[1];
    always_ff @(posedge clk, posedge reset)
        if (reset) DRQ0 <= 1'b0;
        else if (~dma_acknowledge_n[0]) DRQ0 <= 1'b0;
        else if (~prev_timer_count_1 & timer_counter_out[1]) DRQ0 <= 1'b1;

    // Chipset.sv:262-294 I/O settle guard
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

    // chip selects (Peripherals.sv:262-303)
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

    READY u_READY (
        .clock(clk), .cpu_ce_posedge(cpu_ce_posedge), .cpu_ce_negedge(cpu_ce_negedge), .reset(reset),
        .processor_ready(processor_ready), .dma_ready(dma_ready), .dma_wait_n(dma_wait_n),
        .io_channel_ready(io_settle_ready),
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
        .no_command_state(), .ext_access_request(1'b0),
        .dma_request({3'b000, DRQ0}), .dma_acknowledge_n(dma_acknowledge_n),
        .address_enable_n(address_enable_n), .terminal_count_n()
    );
    assign data_bus = internal_data_bus;                          // Chipset.sv:578

    // ==================================================================
    //  Memory: 640 KB RAM, B8000 text RAM, BIOS at FC000, FF elsewhere
    // ==================================================================
    logic [7:0] mem [0:1048575];
    wire ram_select = (address < 20'hA0000) || (address >= 20'hB8000 && address < 20'hC0000);
    always_ff @(posedge clk)
        if (~memory_write_n && ram_select) mem[address] <= internal_data_bus;
    wire [7:0] mem_rdata = mem[address];

    // Chipset.sv:596-616 data bus return mux
    logic [7:0] data_bus_out;                                     // peripheral read data (registered)
    logic       data_bus_out_from_chipset;
    always_comb begin
        if (data_bus_out_from_chipset)      data_bus_ext = data_bus_out;
        else if (~memory_read_n)            data_bus_ext = mem_rdata;
        else                                data_bus_ext = 8'h00;
    end

    // ==================================================================
    //  8259 / 8253 / 8255 / KFPS2KB / keyboard (as in kbd_bios_tb.sv)
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

    // Peripherals.sv:1823-1945 registered read mux
    always_ff @(posedge clk) begin
        if (~interrupt_acknowledge_n)                          begin data_bus_out_from_chipset <= 1'b1; data_bus_out <= interrupt_data_bus_out; end
        else if ((~interrupt_chip_select_n) && (~io_read_n))  begin data_bus_out_from_chipset <= 1'b1; data_bus_out <= interrupt_data_bus_out; end
        else if ((~timer_chip_select_n) && (~io_read_n))      begin data_bus_out_from_chipset <= 1'b1; data_bus_out <= timer_data_bus_out; end
        else if ((~ppi_chip_select_n) && (~io_read_n))        begin data_bus_out_from_chipset <= 1'b1; data_bus_out <= ppi_data_bus_out; end
        else                                                  begin data_bus_out_from_chipset <= 1'b0; data_bus_out <= 8'h00; end
    end

    // the MEGA65 keyboard
    integer      key_num = 0;
    logic        key_pressed_n = 1'b1;
    logic [79:0] pressed = '0;
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
        forever for (int k = 0; k < 80; k++) begin key_num = k; key_pressed_n = ~pressed[k]; #12500; end
    end
    logic device_clock_ff, device_data_ff;
    always_ff @(negedge clk, posedge reset)
        if (reset) begin device_clock_ff <= 1'b0; ps2_clock <= 1'b0; device_data_ff <= 1'b0; ps2_data <= 1'b0; end
        else begin device_clock_ff <= dev_clk; ps2_clock <= device_clock_ff; device_data_ff <= dev_data; ps2_data <= device_data_ff; end

    // ==================================================================
    //  Observers
    // ==================================================================
    wire [7:0] pic_imr = u_KF8259.interrupt_mask;
    wire [7:0] pic_isr = u_KF8259.in_service_register;
    wire [7:0] pic_irr = u_KF8259.interrupt_request_register;

    logic [7:0] prev_imr = 8'hFF;
    logic       imr_unmasked = 1'b0;
    logic [7:0] p60_codes [0:255];
    integer     p60_count = 0, p61_writes = 0, inta_count = 0, halts = 0;
    logic       warm_marker_lo = 1'b0, warm_boot_seen = 1'b0;
    logic       prev_io_read_n = 1'b1, prev_io_write_n = 1'b1, prev_inta_n = 1'b1, prev_mem_write_n = 1'b1;
    logic       prev_irq = 1'b0;
    logic [2:0] prev_status = 3'b111;

    always @(negedge clk) begin
        prev_io_read_n   <= io_read_n;
        prev_io_write_n  <= io_write_n;
        prev_inta_n      <= interrupt_acknowledge_n;
        prev_mem_write_n <= memory_write_n;
        prev_status      <= processor_status;
        if (pic_imr != prev_imr) begin
            $display("  [%0t] PIC IMR %02x -> %02x", $time, prev_imr, pic_imr);
            prev_imr = pic_imr;
            if (pic_imr == 8'hBC) imr_unmasked = 1'b1;
        end
        // port reads / writes (end of strobe)
        if (~prev_io_read_n & io_read_n & ~address_enable_n) begin
            if (address[15:0] == 16'h0060) begin
                $display("  [%0t] IN 60h -> %02x   (port B %02x, IMR %02x, ISR %02x)", $time, data_bus, port_b_out, pic_imr, pic_isr);
                if (p60_count < 256) begin p60_codes[p60_count] = data_bus; p60_count++; end
            end
        end
        if (~prev_io_write_n & io_write_n & ~address_enable_n) begin
            if (address[15:0] == 16'h0061) begin
                p61_writes++;
                if (p61_writes <= 40) $display("  [%0t] OUT 61h <- %02x", $time, internal_data_bus);
            end
            if (address[15:0] == 16'h0020 && (internal_data_bus == 8'h20)) ;   // EOI, silent
        end
        // INTA cycles
        if (prev_inta_n & ~interrupt_acknowledge_n) inta_count++;
        // warm boot marker (Chipset.sv warm_boot_marker_detector semantics)
        if (~prev_mem_write_n & memory_write_n & ~address_enable_n) begin
            if (address == 20'h00472 && internal_data_bus == 8'h34) warm_marker_lo <= 1'b1;
            else if (address == 20'h00473 && internal_data_bus == 8'h12 && warm_marker_lo) begin
                warm_boot_seen <= 1'b1; warm_marker_lo <= 1'b0;
                $display("  [%0t] *** warm-boot marker 1234h written to 0040:0072 (Ctrl+Alt+Del taken)", $time);
            end
            else warm_marker_lo <= 1'b0;
        end
        if (processor_status == 3'b011 && prev_status != 3'b011) begin
            halts++;
            if (halts <= 3) $display("  [%0t] CPU HLT (IMR %02x)", $time, pic_imr);
        end
        if (keybord_irq != prev_irq) begin
            prev_irq = keybord_irq;
            if (keybord_irq) $display("  [%0t] KFPS2KB irq=1 keycode=%02x (port B=%02x)", $time, keycode_buf, port_b_out);
        end
    end

    function automatic int find_code(input [7:0] code, input int from);
        for (int i = from; i < p60_count; i++) if (p60_codes[i] == code) return i;
        return -1;
    endfunction

    // ==================================================================
    //  ROM image
    // ==================================================================
    localparam string BIOS_FILE = "bios-xt.bin";
    integer fd, n, patched;
    logic [7:0] rom [0:16383];

    task automatic patch3(input [7:0] b0, b1, b2, input [7:0] n1, n2, input string what);
        int hits = 0, at = -1;
        for (int i = 0; i < 16382; i++)
            if (rom[i] == b0 && rom[i+1] == b1 && rom[i+2] == b2) begin hits++; at = i; end
        if (hits == 1) begin rom[at+1] = n1; rom[at+2] = n2; $display("  sim-only ROM patch: %s at F000:%04X", what, at + 16'hC000); end
        else $display("  sim-only ROM patch: %s NOT applied (%0d matches)", what, hits);
    endtask

    // ==================================================================
    //  Test
    // ==================================================================
    localparam M65_A = 10, M65_CTRL = 58, M65_MEGA = 61, M65_INS_DEL = 0;
    integer i_make, i_break, i_ctrl, i_alt, i_e0, i_del, base;
    real t_unmask;

    initial begin
        $display("=== kbd_bios_sys_tb: real MCL86 running %s, CPU speed select %0d ===", BIOS_FILE, clk_select);
        for (int i = 0; i < 1048576; i++) mem[i] = 8'hFF;
        fd = $fopen(BIOS_FILE, "rb");
        if (fd == 0) begin $display("RESULT: FAIL (cannot open %s)", BIOS_FILE); $finish; end
        n = $fread(rom, fd); $fclose(fd);
        $display("  loaded %0d bytes of BIOS", n);
        check(n == 16384, "BIOS image is 16 KB");
        if (!$test$plusargs("NOPATCH")) begin
            patch3(8'hB9, 8'h00, 8'h15, 8'h10, 8'h00, "beepinit note delay cx=1500h -> 0010h (sound.inc:55)");
            patch3(8'hB9, 8'h00, 8'h30, 8'h10, 8'h00, "oplsound note delay cx=3000h -> 0010h (sound.inc:68)");
        end
        for (int i = 0; i < 16384; i++) mem[20'hFC000 + i] = rom[i];
        check(mem[20'hFFFF0] == 8'hEA, "reset vector is a far jump");

        #201;  reset_cold = 1'b0;
        #3000; reset = 1'b0;
        $display("  [%0t] reset released", $time);

        // wait for the BIOS to unmask the PIC (bios.asm:1097), then give it a moment
        wait (imr_unmasked);
        t_unmask = $realtime;
        $display("  [%0t] PIC unmasked; port B = %02x", $time, port_b_out);
        #60ms;
        base = p60_count;

        $display("--- press A");
        pressed[M65_A] = 1'b1;  #40ms;
        $display("--- release A");
        pressed[M65_A] = 1'b0;  #40ms;
        i_make  = find_code(8'h1E, base);
        i_break = find_code(8'h9E, base);
        check(i_make  >= 0, "INT 9 read make code 1E for A from port 60h");
        check(i_break >= 0 && i_break > i_make, "INT 9 read break code 9E for A after the make");

        $display("--- Ctrl+Alt+Del");
        base = p60_count;
        pressed[M65_CTRL] = 1'b1;    #20ms;
        pressed[M65_MEGA] = 1'b1;    #20ms;
        pressed[M65_INS_DEL] = 1'b1; #60ms;
        i_ctrl = find_code(8'h1D, base);
        i_alt  = find_code(8'h38, base);
        i_e0   = find_code(8'hE0, base);
        i_del  = find_code(8'h53, base);
        check(i_ctrl >= 0, "INT 9 read Ctrl make 1D");
        check(i_alt  >= 0 && i_alt > i_ctrl, "INT 9 read Alt make 38");
        check(i_e0   >= 0 && i_e0 > i_alt,  "INT 9 read E0 prefix of Del");
        check(i_del  >= 0 && i_del == i_e0 + 1, "INT 9 read Del make 53 right after E0");
        check(warm_boot_seen, "BIOS wrote the 1234h warm-boot marker (Ctrl+Alt+Del reboot taken)");

        $display("--- observations: port 60h reads=%0d port 61h writes=%0d INTA cycles=%0d HLTs=%0d",
                 p60_count, p61_writes, inta_count, halts);
        $write("    port 60h values:");
        for (int i = 0; i < p60_count; i++) $write(" %02x", p60_codes[i]);
        $display("");
        $display("    final: port B=%02x IMR=%02x ISR=%02x IRR=%02x KFPS2KB irq=%0d keycode=%02x sending=%0d ps2_clock_out=%0d",
                 port_b_out, pic_imr, pic_isr, pic_irr, keybord_irq, keycode_buf, lock_recv_clock, ps2_clock_out);
        if (errors == 0) $display("RESULT: PASS (real MCL86 + 8088 BIOS, speed %0d)", clk_select);
        else             $display("RESULT: FAIL (real MCL86 + 8088 BIOS, speed %0d, %0d checks failed)", clk_select, errors);
        $finish;
    end

    // progress / safety net
    initial begin
        forever begin
            #100ms;
            $display("  [%0t] ... running (IMR %02x, port B %02x, port 60h reads %0d, INTA %0d, HLTs %0d)",
                     $time, pic_imr, port_b_out, p60_count, inta_count, halts);
        end
    end
    initial begin
        #4000ms;
        $display("RESULT: FAIL (timeout: PIC never unmasked or keys never processed)");
        $finish;
    end

endmodule
