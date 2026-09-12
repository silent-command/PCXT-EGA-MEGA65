// kbd_bios_tb.sv
//
// Why is the keyboard dead under Sergey Kiselev's 8088 BIOS (MACHINE_XT /
// MACHINE_FE2010A builds) while the Super PC/Turbo XT BIOS v3.1 types fine on
// the same core?  This bench runs the complete keyboard path of the core with
// the REAL blocks:
//
//   * CORE/vhdl/keyboard.vhd + ps2_tx.vhd   the MEGA65 PS/2 keyboard device
//   * KFPS2KB (+ Shift_Register, Send_Data) the XT keyboard controller
//   * KF8255                                 the PPI (port A/B/C)
//   * KF8259                                 the PIC
//   * KF8253                                 the PIT (IRQ0 nesting inside INT 9)
//   * keyboard_warm_reset
//
// plus a VERBATIM copy of the Peripherals.sv / PCXT-EGA.sv glue between them
// (I/O decode, clock inhibit, keycode mux, port A pipeline, IRQ synchronisers,
// the registered read mux, port B / port C wiring, PS/2 input flip-flops).
//
// A behavioural 8088 runs, port access by port access and with 4.77 MHz bus
// timing, either BIOS's real POST sequence for the PPI / PIC / keyboard and the
// real INT 8 / INT 9 / default-IRQ handlers of that BIOS (line numbers in the
// comments refer to the two sources).  A 1 kHz MEGA65 key scan then presses A
// and Ctrl+Alt+Del.  The bench passes when INT 9 saw make 1E, break 9E and the
// Ctrl+Alt+Del chord 1D 38 E0 53 within the XT 8255/8259 contract.
//
//   xsim -testplusarg BIOS=8088     Sergey Kiselev 8088 BIOS, MACHINE_XT build
//   xsim -testplusarg BIOS=TURBO    Super PC/Turbo XT BIOS v3.1
//
// Run with run_kbd_bios_tb.ps1 (Vivado xsim, mixed language).

`timescale 1ns/10ps

module kbd_bios_tb;

    // ------------------------------------------------------------------ clock / reset
    logic clk = 1'b0;
    always #10 clk = ~clk;                          // 50 MHz chipset clock
    logic reset      = 1'b1;                        // chipset reset (Peripherals' reset)
    logic reset_cold = 1'b1;                        // keyboard.vhd rst_i (main.vhd: reset_cold)

    // XT_CE_Generator peripheral_ce: 21/440 of 50 MHz = 2.386 MHz
    logic        peripheral_ce = 1'b0;
    logic [8:0]  pce_acc = 9'd0;
    always_ff @(posedge clk) begin
        peripheral_ce <= 1'b0;
        if (pce_acc + 9'd21 >= 9'd440) begin pce_acc <= pce_acc + 9'd21 - 9'd440; peripheral_ce <= 1'b1; end
        else                            pce_acc <= pce_acc + 9'd21;
    end
    // cpu_ce_negedge at 4.77 MHz (only latches interrupt_to_cpu, as in Peripherals.sv)
    logic       cpu_ce_negedge = 1'b0;
    logic [3:0] cce = 4'd0;
    always_ff @(posedge clk) begin
        cpu_ce_negedge <= (cce == 4'd9);
        cce <= (cce == 4'd9) ? 4'd0 : cce + 4'd1;
    end

    // ------------------------------------------------------------------ results
    integer errors = 0;
    task check(input logic cond, input string msg);
        if (!cond) begin errors = errors + 1; $display("  CHECK FAILED: %s   (t=%0t)", msg, $time); end
    endtask

    // xsim.bat splits its arguments on '=', so the selection is a bare flag:
    //   -testplusarg TURBO   -> Super PC/Turbo XT BIOS v3.1,  otherwise the 8088 BIOS
    string bios = "8088";
    initial if ($test$plusargs("TURBO")) bios = "TURBO"; else bios = "8088";

    // ==================================================================
    //  CPU bus (what the 8088 + Bus_Arbiter present to Peripherals)
    // ==================================================================
    logic [19:0] address           = 20'h0;
    logic [7:0]  internal_data_bus = 8'h0;
    logic        io_read_n         = 1'b1;
    logic        io_write_n        = 1'b1;
    logic        address_enable_n  = 1'b0;
    logic        interrupt_acknowledge_n = 1'b1;

    // ------------------------------------------------------------------ Peripherals.sv:262-303 chip-select decode (verbatim)
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
    wire interrupt_chip_select_n = chip_select_n[1];   // 0x20 .. 0x3F
    wire timer_chip_select_n     = chip_select_n[2];   // 0x40 .. 0x5F
    wire ppi_chip_select_n       = chip_select_n[3];   // 0x60 .. 0x7F

    // ------------------------------------------------------------------ 8259 (Peripherals.sv:408-456)
    logic        timer_interrupt;
    logic        keybord_interrupt;
    logic [7:0]  interrupt_data_bus_out;
    logic        interrupt_to_cpu_buf;
    logic        interrupt_to_cpu;

    KF8259 u_KF8259 (
        .clock(clk), .reset(reset),
        .chip_select_n(interrupt_chip_select_n),
        .read_enable_n(io_read_n), .write_enable_n(io_write_n),
        .address(address[0]), .data_bus_in(internal_data_bus),
        .data_bus_out(interrupt_data_bus_out),
        .cascade_in(3'b000),
        .slave_program_n(1'b1),
        .interrupt_acknowledge_n(interrupt_acknowledge_n),
        .interrupt_to_cpu(interrupt_to_cpu_buf),
        .interrupt_request({6'b000000, keybord_interrupt, timer_interrupt})
    );
    always_ff @(posedge clk, posedge reset)
        if (reset) interrupt_to_cpu <= 1'b0;
        else if (cpu_ce_negedge) interrupt_to_cpu <= interrupt_to_cpu_buf;

    // ------------------------------------------------------------------ 8253 (Peripherals.sv:462-501)
    logic timer_clock = 1'b0;
    always_ff @(posedge clk, posedge reset)
        if (reset) timer_clock <= 1'b0;
        else if (peripheral_ce) timer_clock <= ~timer_clock;
    logic [7:0] timer_data_bus_out;
    logic [2:0] timer_counter_out;
    logic [7:0] port_b_out;
    logic       port_b_io;
    wire tim2gatespk = port_b_out[0] & ~port_b_io;
    KF8253 u_KF8253 (
        .clock(clk), .reset(reset),
        .chip_select_n(timer_chip_select_n),
        .read_enable_n(io_read_n), .write_enable_n(io_write_n),
        .address(address[1:0]), .data_bus_in(internal_data_bus),
        .data_bus_out(timer_data_bus_out),
        .counter_0_clock(timer_clock), .counter_0_gate(1'b1), .counter_0_out(timer_counter_out[0]),
        .counter_1_clock(timer_clock), .counter_1_gate(1'b1), .counter_1_out(timer_counter_out[1]),
        .counter_2_clock(timer_clock), .counter_2_gate(tim2gatespk), .counter_2_out(timer_counter_out[2])
    );
    assign timer_interrupt = timer_counter_out[0];

    // ------------------------------------------------------------------ 8255 (Peripherals.sv:506-533, PCXT-EGA.sv:1149-1164,1249-1251)
    logic [7:0] ppi_data_bus_out;
    logic [7:0] port_a_in;
    logic [7:0] port_a_out, port_c_out;
    logic       port_a_io;
    logic [7:0] port_c_io;
    logic [7:0] port_c_in;
    wire  [7:0] sw = {2'b01, 2'b00, 4'b1101};       // one floppy, EGA (video switches 00), sw_base
    assign port_c_in[3:0] = port_b_out[3] ? sw[7:4] : sw[3:0];
    assign port_c_in[7:4] = 4'b0000;                // undriven in PCXT-EGA.sv (Vivado ties to 0)

    KF8255 u_KF8255 (
        .clock(clk), .reset(reset),
        .chip_select_n(ppi_chip_select_n),
        .read_enable_n(io_read_n), .write_enable_n(io_write_n),
        .address(address[1:0]), .data_bus_in(internal_data_bus),
        .data_bus_out(ppi_data_bus_out),
        .port_a_in(port_a_in), .port_a_out(port_a_out), .port_a_io(port_a_io),
        .port_b_in(port_b_out), .port_b_out(port_b_out), .port_b_io(port_b_io),
        .port_c_in(port_c_in), .port_c_out(port_c_out), .port_c_io(port_c_io)
    );

    // ------------------------------------------------------------------ KFPS2KB + reset sender (Peripherals.sv:536-617)
    logic       ps2_clock, ps2_data;                // from the device, after the PCXT-EGA.sv input FFs
    logic       ps2_clock_out, ps2_data_out;        // to the device
    logic       ps2_send_clock;
    logic       keybord_irq;
    logic [7:0] keycode_buf, keycode;
    logic       prev_ps2_reset_n;
    logic       lock_recv_clock;
    logic       pause_core;
    localparam [15:0] KEYBOARD_WARM_RESET_HOLD = 16'd5000;
    wire        keyboard_warm_reset_active;

    wire clear_keycode = port_b_out[7];
    wire ps2_reset_n   = port_b_out[6];

    always_ff @(posedge clk, posedge reset)
        if (reset) prev_ps2_reset_n <= 1'b0;
        else       prev_ps2_reset_n <= ps2_reset_n;

    KFPS2KB #(.over_time(16'd1000)) u_KFPS2KB (
        .clock(clk), .peripheral_ce(peripheral_ce), .reset(reset),
        .device_clock(ps2_clock | lock_recv_clock), .device_data(ps2_data),
        .irq(keybord_irq), .keycode(keycode_buf), .clear_keycode(clear_keycode),
        .pause_core(pause_core)
    );
    assign keycode = ps2_reset_n ? keycode_buf : 8'h80;

    keyboard_warm_reset #(.HOLD_CYCLES(KEYBOARD_WARM_RESET_HOLD)) keyboard_warm_reset_detect (
        .clock(clk), .reset(reset), .keycode_irq(keybord_irq), .keycode(keycode),
        .warm_reset_active(keyboard_warm_reset_active)
    );

    KFPS2KB_Send_Data u_KFPS2KB_Send_Data (
        .clock(clk), .peripheral_ce(peripheral_ce), .reset(reset),
        .device_clock(ps2_clock),
        .device_clock_out(ps2_send_clock), .device_data_out(ps2_data_out),
        .sending_data_flag(lock_recv_clock),
        .send_request(~prev_ps2_reset_n & ps2_reset_n), .send_data(8'hFF)
    );

    always_ff @(posedge clk, posedge reset)
        if (reset) ps2_clock_out = 1'b1;
        else       ps2_clock_out = ~(keybord_irq | ~ps2_send_clock | ~ps2_reset_n);

    // Peripherals.sv:844-899: IRQ synchroniser and port A pipeline
    logic keybord_interrupt_ff;
    always_ff @(posedge clk, posedge reset)
        if (reset) begin keybord_interrupt_ff <= 1'b0; keybord_interrupt <= 1'b0; end
        else begin keybord_interrupt_ff <= keybord_irq; keybord_interrupt <= keybord_interrupt_ff; end

    logic [7:0] keycode_ff;
    always_ff @(posedge clk, posedge reset)
        if (reset) begin keycode_ff <= 8'h00; port_a_in <= 8'h00; end
        else begin keycode_ff <= keycode; port_a_in <= keycode_ff; end

    // Peripherals.sv:1823-1843: registered read mux (the entries that matter here)
    logic [7:0] data_bus_out;
    always_ff @(posedge clk) begin
        if (~interrupt_acknowledge_n)                          data_bus_out <= interrupt_data_bus_out;
        else if ((~interrupt_chip_select_n) && (~io_read_n))  data_bus_out <= interrupt_data_bus_out;
        else if ((~timer_chip_select_n) && (~io_read_n))      data_bus_out <= timer_data_bus_out;
        else if ((~ppi_chip_select_n) && (~io_read_n))        data_bus_out <= ppi_data_bus_out;
    end

    // ==================================================================
    //  The MEGA65 keyboard: keyboard.vhd (+ ps2_tx.vhd), the real device
    // ==================================================================
    integer     key_num = 0;
    logic       key_pressed_n = 1'b1;
    logic [79:0] pressed = '0;
    wire        dev_clk, dev_data;
    wire [10:0] ps2_key;

    keyboard u_keyboard (
        .clk_main_i(clk), .rst_i(reset_cold),
        .key_num_i(key_num), .key_pressed_n_i(key_pressed_n),
        .ps2_host_clk_i(ps2_clock_out), .ps2_host_data_i(ps2_data_out),
        .ps2_clk_o(dev_clk), .ps2_data_o(dev_data), .ps2_key_o(ps2_key)
    );

    // framework scanner: 1 kHz sweep over the 80 keys (12.5 us per key)
    initial begin
        #3;                                          // off the clock edges
        forever begin
            for (int k = 0; k < 80; k++) begin
                key_num = k; key_pressed_n = ~pressed[k];
                #12500;
            end
        end
    end

    // PCXT-EGA.sv:1089-1127 input flip-flops (negedge clk_chipset)
    logic device_clock_ff, device_data_ff;
    always_ff @(negedge clk, posedge reset)
        if (reset) begin device_clock_ff <= 1'b0; ps2_clock <= 1'b0; device_data_ff <= 1'b0; ps2_data <= 1'b0; end
        else begin device_clock_ff <= dev_clk; ps2_clock <= device_clock_ff; device_data_ff <= dev_data; ps2_data <= device_data_ff; end

    // ==================================================================
    //  Observers
    // ==================================================================
    logic prev_irq = 0, prev_clkout = 1;
    always @(posedge clk) begin
        if (keybord_irq != prev_irq) begin
            $display("  [%0t] KFPS2KB irq=%0d keycode=%02x (port B=%02x, sending=%0d)", $time, keybord_irq, keycode_buf, port_b_out, lock_recv_clock);
            prev_irq = keybord_irq;
        end
        prev_clkout = ps2_clock_out;
    end
    // KF8259 IMR / ISR visibility
    wire [7:0] pic_imr = u_KF8259.interrupt_mask;
    wire [7:0] pic_isr = u_KF8259.in_service_register;
    wire [7:0] pic_irr = u_KF8259.interrupt_request_register;
    logic [7:0] prev_imr = 8'hFF;
    always @(posedge clk) if (pic_imr != prev_imr) begin $display("  [%0t] PIC IMR %02x -> %02x", $time, prev_imr, pic_imr); prev_imr = pic_imr; end
    // what the KF8259 bus logic decodes from each write (sampled mid-cycle)
    always @(negedge clk) begin
        if (u_KF8259.write_initial_command_word_1)   $display("  [%0t] PIC ICW1 %02x", $time, u_KF8259.internal_data_bus);
        if (u_KF8259.write_initial_command_word_2_4) $display("  [%0t] PIC ICW2-4/OCW1 write %02x (cmd state %0d)", $time, u_KF8259.internal_data_bus, u_KF8259.u_Control_Logic.command_state);
        if (u_KF8259.write_operation_control_word_2) $display("  [%0t] PIC OCW2 %02x (ISR %02x)", $time, u_KF8259.internal_data_bus, pic_isr);
        if (u_KF8259.write_operation_control_word_3) $display("  [%0t] PIC OCW3 %02x", $time, u_KF8259.internal_data_bus);
    end
    always @(u_KF8259.u_Control_Logic.command_state)
        $display("  [%0t] PIC command_state -> %0d (icw1=%0d icw2_4=%0d cs_n=%0d wr_n=%0d addr=%0d)", $time, u_KF8259.u_Control_Logic.command_state,
                 u_KF8259.write_initial_command_word_1, u_KF8259.write_initial_command_word_2_4, interrupt_chip_select_n, io_write_n, address[0]);

    // ==================================================================
    //  Behavioural 8088 (4.77 MHz: T = 210 ns; an I/O bus cycle is 4 T)
    // ==================================================================
    localparam real T = 210.0;
    logic cpu_if = 1'b0;                     // IF
    integer int_depth = 0;
    logic [7:0] rd;

    // scancodes INT 9 read from port 60h, in order
    logic [7:0] int9_codes [0:255];
    integer     int9_count = 0;
    integer     int8_count = 0;
    integer     spurious_count = 0;
    integer     masked_by_default_handler = 0;

    task automatic io_write(input [15:0] port, input [7:0] val);
        service_interrupts();                 // a real CPU takes INTR at the instruction boundary
        #(T*2);
        address = port; internal_data_bus = val;
        #(T);  io_write_n = 1'b0;
        #(T*2); io_write_n = 1'b1;
        #(T);  address = 20'h0; internal_data_bus = 8'h0;
        #(T*4);                               // remainder of the instruction
    endtask

    task automatic io_read(input [15:0] port, output [7:0] val);
        service_interrupts();
        #(T*2);
        address = port;
        #(T);  io_read_n = 1'b0;
        #(T*2); val = data_bus_out;
        io_read_n = 1'b1;
        #(T);  address = 20'h0;
        #(T*4);
    endtask

    // executes "instructions" for `us` microseconds, taking interrupts as a CPU would
    task automatic run_us(input real us);
        real t0; t0 = $realtime;
        while ($realtime - t0 < us*1000.0) begin
            service_interrupts();
            #(T*8);                           // one average instruction
        end
    endtask

    task automatic sti(); cpu_if = 1'b1; endtask
    task automatic cli(); cpu_if = 1'b0; endtask

    // INTA sequence exactly as the 8088 + KF8259 do it: two INTA pulses, vector on the 2nd
    task automatic inta_cycle(output [7:0] vector);
        #(T*2); interrupt_acknowledge_n = 1'b0;
        #(T*2); interrupt_acknowledge_n = 1'b1;
        #(T*2); interrupt_acknowledge_n = 1'b0;
        #(T*2); vector = data_bus_out;
        interrupt_acknowledge_n = 1'b1;
        #(T*2);
    endtask

    task automatic service_interrupts();
        logic [7:0] vec;
        logic saved_if;
        if (cpu_if && interrupt_to_cpu) begin
            inta_cycle(vec);
            saved_if = cpu_if; cpu_if = 1'b0; int_depth++;
            case (vec)
                8'h08: int_08();
                8'h09: int_09();
                default: begin spurious_count++; $display("  [%0t] *** default IRQ handler entered, vector %02x (ISR=%02x)", $time, vec, pic_isr); int_default(); end
            endcase
            int_depth--; cpu_if = saved_if;   // IRET
        end
    endtask

    // ------------------------------------------------------------------ handlers
    task automatic int_08();
        int8_count++;
        run_us(20.0);                          // tick bookkeeping (time2.inc:69-106 / Turbo XT int_8)
        io_write(16'h0020, 8'h20);             // non-specific EOI
    endtask

    task automatic int_09();
        logic [7:0] sc, pb;
        // both BIOSes: keyboard.inc:269-277 / pcxtbios.asm:2049-2056
        io_read (16'h0060, sc);
        io_read (16'h0061, pb);
        io_write(16'h0061, pb | 8'h80);
        io_write(16'h0061, pb & 8'h7F);        // Turbo XT: `pop ax; out 61h,al` = original value
        int9_codes[int9_count] = sc; int9_count++;
        $display("  [%0t] INT 9: scancode %02x (port B %02x, IMR %02x, ISR %02x)", $time, sc, pb, pic_imr, pic_isr);
        if (bios == "8088") sti();             // keyboard.inc:279 - interrupts on before the EOI
        run_us(60.0);                          // flag / translate / buffer work
        io_write(16'h0020, 8'h20);             // keyboard.inc:545-546 / pcxtbios.asm:2073-2074
    endtask

    task automatic int_default();
        logic [7:0] isr, imr;
        if (bios == "8088") begin
            // bios.asm:1842-1860 int_ignore: OCW3=0Bh, read ISR, mask the in-service IRQ, EOI
            io_write(16'h0020, 8'h0B);
            io_read (16'h0020, isr);
            if (isr != 8'h00) begin
                io_read (16'h0021, imr);
                io_write(16'h0021, imr | isr);
                masked_by_default_handler++;
                $display("  [%0t] *** int_ignore masked IRQs %02x (IMR now %02x)", $time, isr, imr | isr);
                io_write(16'h0020, 8'h20);
            end
        end
        else begin
            io_write(16'h0020, 8'h20);         // Turbo XT: plain EOI
        end
    endtask

    // ==================================================================
    //  POST sequences
    // ==================================================================
    logic [7:0] v;

    task automatic post_8088_xt();
        $display("--- 8088 BIOS (MACHINE_XT) POST ---");
        // bios.asm:838-842  PPI mode 99h, port B = 10100101b
        io_write(16'h0063, 8'h99);
        io_write(16'h0061, 8'hA5);
        run_us(2000.0);                                        // DMA init, low RAM test ... (IF=0)
        // bios.asm:1003-1010  PIT
        io_write(16'h0043, 8'h36); io_write(16'h0040, 8'h00); io_write(16'h0040, 8'h00);
        io_write(16'h0043, 8'h54); io_write(16'h0041, 8'h12);
        run_us(500.0);
        // bios.asm:1039-1044  PIC: ICW1 13h, ICW2 08h, ICW4 09h (no OCW1 yet)
        io_write(16'h0020, 8'h13); io_write(16'h0021, 8'h08); io_write(16'h0021, 8'h09);
        // bios.asm:1056-1065  keyboard reset pulse via port B bits 6/7
        io_read (16'h0061, v);
        io_write(16'h0061, v & 8'h3F);                         // clock low
        run_us(20000.0);                                       // mov cx,10582 / loop  = 20 ms
        io_write(16'h0061, v | 8'hC0);                         // clear + clock enable (FF goes out)
        io_write(16'h0061, (v | 8'hC0) & 8'h7F);               // clear off
        // bios.asm:1066-1075  1000 x INT 16h/01 (int_16_exitf ends with sti/retf 2 -> IF=1 from the 1st call)
        sti();
        run_us(30000.0);
        // bios.asm:1079-1100  kbd_buffer_init; OCW1 = BCh; sti
        io_write(16'h0021, 8'hBC);
        sti();
        io_write(16'h00A0, 8'h80);                             // NMI enable (undecoded here)
        // bios.asm:1107-1115  read the video switches: port B bit 3 set, read port C
        io_read (16'h0061, v);
        io_write(16'h0061, v | 8'h08);
        io_read (16'h0062, v);
        run_us(40000.0);                                       // opl_init, oplsound, video BIOS, beep, messages ...
        // bios.asm:1405-1457  detect_rom_ext: save IMR, run option ROMs (XTIDE), restore IMR
        io_read (16'h0021, v);
        run_us(20000.0);
        io_write(16'h0021, v);
        $display("--- 8088 BIOS: boot; port B = %02x IMR = %02x IF = %0d", port_b_out, pic_imr, cpu_if);
    endtask

    task automatic post_turbo_xt();
        $display("--- Super PC/Turbo XT BIOS v3.1 POST ---");
        // pcxtbios.asm:487-491  PPI mode 99h, port B = 10100101b (TURBO_ENABLED)
        io_write(16'h0063, 8'h99);
        io_write(16'h0061, 8'hA5);
        // pcxtbios.asm:492-525  PIT / DMA init
        io_write(16'h0043, 8'h54); io_write(16'h0041, 8'h12);
        io_write(16'h0043, 8'h36); io_write(16'h0040, 8'h00); io_write(16'h0040, 8'h00);
        run_us(2000.0);
        // pcxtbios.asm:600-608  PIC: ICW1 13h, ICW2 08h, ICW4 09h, OCW1 = FFh
        io_write(16'h0020, 8'h13); io_write(16'h0021, 8'h08); io_write(16'h0021, 8'h09); io_write(16'h0021, 8'hFF);
        // pcxtbios.asm:667-673  port B parity bits, NMI on
        io_read (16'h0061, v);
        io_write(16'h0061, v | 8'h30);
        io_write(16'h0061, v & 8'hCF);
        io_write(16'h00A0, 8'h80);
        // pcxtbios.asm:687-692  switches through port C
        io_read (16'h0062, v);
        io_write(16'h0061, 8'hAD);
        io_read (16'h0062, v);
        // pcxtbios.asm:711-720  keyboard: clock low, ~37 ms, C8h then 48h
        io_write(16'h0061, 8'h08);
        run_us(37000.0);
        io_write(16'h0061, 8'hC8);
        io_write(16'h0061, 8'h48);
        run_us(60000.0);                                       // memory test, ROM scan ... (IF=0, IRQs masked)
        // pcxtbios.asm:886-888  unmask IRQ0/1/6, then interrupts on
        io_read (16'h0021, v);
        io_write(16'h0021, v & 8'hBC);
        sti();
        run_us(5000.0);
        $display("--- Turbo XT BIOS: boot; port B = %02x IMR = %02x IF = %0d", port_b_out, pic_imr, cpu_if);
    endtask

    // ==================================================================
    //  Test
    // ==================================================================
    localparam M65_A = 10, M65_CTRL = 58, M65_MEGA = 61, M65_INS_DEL = 0;

    function automatic int find_code(input [7:0] code, input int from);
        for (int i = from; i < int9_count; i++) if (int9_codes[i] == code) return i;
        return -1;
    endfunction

    integer i_make, i_break, i_ctrl, i_alt, i_e0, i_del, base;

    initial begin
        $display("=== kbd_bios_tb: BIOS=%s ===", bios);
        // T = 210 ns is 10.5 clocks: every CPU-model event is skewed 1 ns past
        // the clock edges so the DUT never samples a bus change on its edge.
        #201; reset_cold = 1'b0;
        #2000; reset = 1'b0;
        #1000;

        if (bios == "8088") post_8088_xt(); else post_turbo_xt();

        // DOS prompt: idle with interrupts enabled
        run_us(20000.0);
        base = int9_count;

        $display("--- press A");
        pressed[M65_A] = 1'b1;  run_us(40000.0);
        $display("--- release A");
        pressed[M65_A] = 1'b0;  run_us(40000.0);

        i_make  = find_code(8'h1E, base);
        i_break = find_code(8'h9E, base);
        check(i_make  >= 0, "INT 9 saw make code 1E for A");
        check(i_break >= 0 && i_break > i_make, "INT 9 saw break code 9E for A after the make");

        $display("--- Ctrl+Alt+Del");
        base = int9_count;
        pressed[M65_CTRL] = 1'b1;    run_us(20000.0);
        pressed[M65_MEGA] = 1'b1;    run_us(20000.0);
        pressed[M65_INS_DEL] = 1'b1; run_us(40000.0);
        i_ctrl = find_code(8'h1D, base);
        i_alt  = find_code(8'h38, base);
        i_e0   = find_code(8'hE0, base);
        i_del  = find_code(8'h53, base);
        check(i_ctrl >= 0, "INT 9 saw Ctrl make 1D");
        check(i_alt  >= 0 && i_alt > i_ctrl, "INT 9 saw Alt make 38");
        check(i_e0   >= 0 && i_e0 > i_alt,  "INT 9 saw E0 prefix of Del");
        check(i_del  >= 0 && i_del == i_e0 + 1, "INT 9 saw Del make 53 right after E0 (Ctrl+Alt+Del recognised)");
        pressed[M65_INS_DEL] = 1'b0; pressed[M65_MEGA] = 1'b0; pressed[M65_CTRL] = 1'b0;
        run_us(40000.0);

        $display("--- observations: INT 9 entries=%0d INT 8 entries=%0d default-handler entries=%0d IRQs masked by int_ignore=%0d",
                 int9_count, int8_count, spurious_count, masked_by_default_handler);
        $write("    INT 9 scancodes:");
        for (int i = 0; i < int9_count; i++) $write(" %02x", int9_codes[i]);
        $display("");
        $display("    final: port B=%02x IMR=%02x ISR=%02x IRR=%02x KFPS2KB irq=%0d keycode=%02x sending=%0d ps2_clock_out=%0d IF=%0d",
                 port_b_out, pic_imr, pic_isr, pic_irr, keybord_irq, keycode_buf, lock_recv_clock, ps2_clock_out, cpu_if);
        check(pic_imr[1] == 1'b0, "IRQ1 still unmasked at the end");
        check(lock_recv_clock == 1'b0, "KFPS2KB_Send_Data not stuck sending");

        if (errors == 0) $display("RESULT: PASS (BIOS=%s)", bios);
        else             $display("RESULT: FAIL (BIOS=%s, %0d checks failed)", bios, errors);
        $finish;
    end

    // safety net
    initial begin
        #600ms;
        $display("RESULT: FAIL (timeout)");
        $finish;
    end

endmodule
