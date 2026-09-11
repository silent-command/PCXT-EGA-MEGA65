//
// KF8237
// PROGRAMMABLE DMA CONTROLLER
//
// Written by Kitune-san
//
// MEGA65 overlay (timing only, no behavioural change; ports unchanged).
//
// The CPU-side register read used to run
//   address_enable_n -> 8288 command_enable -> io_read_n -> dma_chip_select_n
//   -> read_flag -> read_current_* (one-hot) -> read_address_or_count mux
//   -> data_bus_out priority mux -> Bus_Arbiter internal_data_bus -> BIU
// i.e. the late command/enable signals crossed the whole 8:1 x 2-byte
// register tree before reaching the data bus (12 LUT levels, -0.99 ns
// against the 10 ns clk_50 -> clk_100 requirement).  Here the register read
// data is selected from address_in alone (early, address-only inputs) and
// the io_read_n / chip_select_n / lock qualification is applied once, in the
// last mux.  See the "Data Bus Buffer & Read/Write Control Logic (2)" block
// and the overlaid KF8237_Address_And_Count_Registers.sv (which gains an
// address_in input; it is instantiated only from this file).
//

module KF8237 (
    input   logic           clock,
    input   logic           cpu_ce_posedge,
    input   logic           cpu_ce_negedge,
    input   logic           reset,
    input   logic           chip_select_n,
    input   logic           ready,
    input   logic           hold_acknowledge,
    input   logic   [3:0]   dma_request,
    input   logic   [7:0]   data_bus_in,
    output  logic   [7:0]   data_bus_out,
    input   logic           io_read_n_in,
    output  logic           io_read_n_out,
    output  logic           io_read_n_io,
    input   logic           io_write_n_in,
    output  logic           io_write_n_out,
    output  logic           io_write_n_io,
    input   logic           end_of_process_n_in,
    output  logic           end_of_process_n_out,
    input   logic   [3:0]   address_in,
    output  logic   [15:0]  address_out,
    output  logic           output_highst_address,
    output  logic           hold_request,
    output  logic   [3:0]   dma_acknowledge,
    output  logic           address_enable,
    output  logic           address_strobe,
    output  logic           memory_read_n,
    output  logic           memory_write_n
);


    //
    // Data Bus Buffer & Read/Write Control Logic (1)
    //
    logic           lock_bus_control;
    logic   [7:0]   internal_data_bus;
    logic           write_command_register;
    logic           write_mode_register;
    logic           write_request_register;
    logic           set_or_reset_mask_register;
    logic           write_mask_register;
    logic   [3:0]   write_base_and_current_address;
    logic   [3:0]   write_base_and_current_word_count;
    logic           clear_byte_pointer;
    logic           set_byte_pointer;
    logic           master_clear;
    logic           clear_mask_register;
    logic           read_temporary_register;
    logic           read_status_register;
    logic   [3:0]   read_current_address;
    logic   [3:0]   read_current_word_count;

    KF8237_Bus_Control_Logic u_Bus_Control_Logic (
        // Bus
        .clock                              (clock),
        .reset                              (reset),

        .chip_select_n                      (chip_select_n),
        .io_read_n_in                       (io_read_n_in),
        .io_write_n_in                      (io_write_n_in),
        .address_in                         (address_in),
        .data_bus_in                        (data_bus_in),

        .lock_bus_control                   (lock_bus_control),

        // Internal Bus
        .internal_data_bus                  (internal_data_bus),
        // -- write
        .write_command_register             (write_command_register),
        .write_mode_register                (write_mode_register),
        .write_request_register             (write_request_register),
        .set_or_reset_mask_register         (set_or_reset_mask_register),
        .write_mask_register                (write_mask_register),
        .write_base_and_current_address     (write_base_and_current_address),
        .write_base_and_current_word_count  (write_base_and_current_word_count),
        // -- software command
        .clear_byte_pointer                 (clear_byte_pointer),
        .set_byte_pointer                   (set_byte_pointer),
        .master_clear                       (master_clear),
        .clear_mask_register                (clear_mask_register),
        // -- read
        .read_temporary_register            (read_temporary_register),
        .read_status_register               (read_status_register),
        .read_current_address               (read_current_address),
        .read_current_word_count            (read_current_word_count)
    );


    //
    // Priority Encoder And Rotating Priority Logic
    //
    logic   [1:0]   dma_rotate;
    logic   [3:0]   edge_request;
    logic   [3:0]   dma_request_state;
    logic   [3:0]   encoded_dma;
    logic           end_of_process_internal;
    logic   [3:0]   dma_acknowledge_internal;

    KF8237_Priority_Encoder u_Priority_Encoder (
        .clock                              (clock),
        .cpu_clock_posedge                  (cpu_ce_posedge),
        .cpu_clock_negedge                  (cpu_ce_negedge),
        .reset                              (reset),

        // Internal Bus
        .internal_data_bus                  (internal_data_bus),
        // -- write
        .write_command_register             (write_command_register),
        .write_request_register             (write_request_register),
        .set_or_reset_mask_register         (set_or_reset_mask_register),
        .write_mask_register                (write_mask_register),
        // -- software command
        .master_clear                       (master_clear),
        .clear_mask_register                (clear_mask_register),

        // Internal signals
        .dma_rotate                         (dma_rotate),
        .edge_request                       (edge_request),
        .dma_request_state                  (dma_request_state),
        .encoded_dma                        (encoded_dma),
        .end_of_process_internal            (end_of_process_internal),
        .dma_acknowledge_internal           (dma_acknowledge_internal),

        // External signals
        .dma_request                        (dma_request)
    );


    //
    // Address And Count Registers
    //
    logic   [7:0]   read_address_or_count;
    logic   [3:0]   transfer_register_select;
    logic           initialize_current_register;
    logic           address_hold_config;
    logic           decrement_address_config;
    logic           next_word;
    logic           update_high_address;
    logic           underflow;

    KF8237_Address_And_Count_Registers u_Address_And_Count_Registers (
        .clock                              (clock),
        .cpu_clock_posedge                  (cpu_ce_posedge),
        .cpu_clock_negedge                  (cpu_ce_negedge),
        .reset                              (reset),

        // Internal Bus
        .internal_data_bus                  (internal_data_bus),
        .address_in                         (address_in),               // MEGA65 overlay: early read select
        .read_address_or_count              (read_address_or_count),
        // -- write
        .write_base_and_current_address     (write_base_and_current_address),
        .write_base_and_current_word_count  (write_base_and_current_word_count),
        // -- software command
        .clear_byte_pointer                 (clear_byte_pointer),
        .set_byte_pointer                   (set_byte_pointer),
        .master_clear                       (master_clear),
        // -- read
        .read_current_address               (read_current_address),
        .read_current_word_count            (read_current_word_count),

        // Internal signals
        .transfer_register_select           (transfer_register_select),
        .initialize_current_register        (initialize_current_register),
        .address_hold_config                (address_hold_config),
        .decrement_address_config           (decrement_address_config),
        .next_word                          (next_word),
        .update_high_address                (update_high_address),
        .underflow                          (underflow),
        .transfer_address                   (address_out)
    );


    //
    // Timing And Control Logic
    //
    logic           output_temporary_data;
    logic   [7:0]   temporary_register;
    logic   [3:0]   terminal_count_state;

    KF8237_Timing_And_Control u_Timing_And_Control (
        .clock                              (clock),
        .cpu_clock_posedge                  (cpu_ce_posedge),
        .cpu_clock_negedge                  (cpu_ce_negedge),
        .reset                              (reset),

        // Internal Bus
        .internal_data_bus                  (internal_data_bus),
        // -- write
        .write_command_register             (write_command_register),
        .write_mode_register                (write_mode_register),
        // -- read
        .read_status_register               (read_status_register),
        // -- software command
        .master_clear                       (master_clear),

        // Internal signals
        .dma_rotate                         (dma_rotate),
        .edge_request                       (edge_request),
        .dma_request_state                  (dma_request_state),
        .encoded_dma                        (encoded_dma),
        .dma_acknowledge_internal           (dma_acknowledge_internal),
        .transfer_register_select           (transfer_register_select),
        .initialize_current_register        (initialize_current_register),
        .address_hold_config                (address_hold_config),
        .decrement_address_config           (decrement_address_config),
        .next_word                          (next_word),
        .update_high_address                (update_high_address),
        .underflow                          (underflow),
        .end_of_process_internal            (end_of_process_internal),
        .lock_bus_control                   (lock_bus_control),
        .output_temporary_data              (output_temporary_data),
        .temporary_register                 (temporary_register),
        .terminal_count_state               (terminal_count_state),

        // External signals
        .hold_request                       (hold_request),
        .hold_acknowledge                   (hold_acknowledge),
        .dma_acknowledge                    (dma_acknowledge),
        .address_enable                     (address_enable),
        .address_strobe                     (address_strobe),
        .output_highst_address              (output_highst_address),
        .memory_read_n                      (memory_read_n),
        .memory_write_n                     (memory_write_n),
        .io_read_n_out                      (io_read_n_out),
        .io_read_n_io                       (io_read_n_io),
        .io_write_n_out                     (io_write_n_out),
        .io_write_n_io                      (io_write_n_io),
        .ready                              (ready),
        .end_of_process_n_in                (end_of_process_n_in),
        .end_of_process_n_out               (end_of_process_n_out)
    );


    //
    // Data Bus Buffer & Read/Write Control Logic (2)
    //
    // MEGA65 overlay: same function as upstream, restructured so that the
    // read qualification is the last select.  Upstream was
    //
    //   ohs                     -> address_out[15:8]
    //   read_temp | otd         -> temporary_register     read_temp   = rf & (a == 1101)
    //   read_status             -> {req_state, tc_state}  read_status = rf & (a == 1000)
    //   |read_current_*         -> read_address_or_count  |read_cur_* = rf & ~a[3]
    //   else                    -> 0
    //
    // with rf = read_flag = ~io_read_n_in & ~chip_select_n & ~lock_bus_control
    // (KF8237_Bus_Control_Logic.sv) and a = address_in.  Case split on rf:
    //   rf = 0: upstream gives ohs ? addr : otd ? temp : 0        == below
    //   rf = 1: upstream gives ohs ? addr : otd ? temp :
    //           a==1101 ? temp : a==1000 ? status :
    //           ~a[3] ? read_address_or_count : 0                  == below,
    //           because the overlaid read_address_or_count is the register
    //           addressed by a for ~a[3] and 0 for a[3] whenever rf = 1
    //           (its one-hot inputs are exactly rf & decode(a)).
    // The a==1101 -> temp branch never needs read_temp's priority over
    // read_status: the two decodes are disjoint.
    //
    wire            read_flag = ~io_read_n_in & ~chip_select_n & ~lock_bus_control;
    logic   [7:0]   read_data_by_address;

    always_comb begin
        if (address_in == 4'b1101)
            read_data_by_address = temporary_register;
        else if (address_in == 4'b1000)
            read_data_by_address = {dma_request_state, terminal_count_state};
        else
            read_data_by_address = read_address_or_count;   // 8'h00 when address_in[3]
    end

    always_comb begin
        if (output_highst_address)
            data_bus_out = address_out[15:8];
        else if (output_temporary_data)
            data_bus_out = temporary_register;
        else if (read_flag)
            data_bus_out = read_data_by_address;
        else
            data_bus_out = 8'h00;
    end

endmodule

