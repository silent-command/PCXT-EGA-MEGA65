//
// KFSDRAM (MEGA65 overlay)
//
// Drop-in replacement for rtl/KFPC-XT/HDL/KFSDRAM/HDL/KFSDRAM.sv, the SDRAM
// controller RAM.sv talks to. Same module name, parameters and ports, so
// RAM.sv, Chipset.sv and Peripherals.sv stay untouched.
//
// The MEGA65 has no SDRAM. This module keeps the command-side handshake that
// RAM.sv depends on (address / access_num / read_request / write_request in,
// write_flag / read_flag / idle / data_out back) and turns each access into
// byte transfers on a small Avalon-MM style master that is carried on the
// existing SDRAM pin ports, which CHIPSET already exports:
//
//   pin (KFSDRAM port)      meaning on MEGA65
//   ---------------------   ----------------------------------------------
//   sdram_address[12:0]     avm_address[12:0]
//   sdram_ba[1:0]           avm_address[14:13]
//   sdram_dq_out[15:9]      avm_address[21:15]      (22-bit byte address, 4 MB)
//   sdram_dq_out[7:0]       avm_writedata
//   sdram_dq_out[8]         0 (spare)
//   sdram_ras               ~avm_read               (active low, like the pin)
//   sdram_we                ~avm_write              (active low, like the pin)
//   sdram_dq_io             ~avm_write              (0 = driving, as upstream)
//   sdram_cke               1 once out of reset     (controller initialised)
//   sdram_cs                0 (asserted)            sdram_cas 1 (unused)
//   sdram_dq_in[7:0]        avm_readdata
//   sdram_dq_in[8]          avm_waitrequest
//   sdram_dq_in[9]          avm_readdatavalid
//
// Avalon rules used: read/write are held while waitrequest is 1 and accepted
// on the edge where it is 0; writes complete on acceptance; reads return
// readdata with readdatavalid any number of cycles later, in order. The
// backend may therefore be BRAM (zero wait) or HyperRAM (variable latency).
//
// RAM.sv contract reproduced from the upstream controller:
//   * idle is high only in IDLE; a request is accepted only there.
//   * A write raises write_flag for at least access_num consecutive cycles;
//     data_in[7:0] is sampled on the first access_num of them (beat k ->
//     address + k) and the flag stays up until the backend has accepted
//     every byte.
//     RAM.sv advances its own byte selector on the first write_flag edge.
//   * A read raises read_flag for exactly access_num consecutive cycles with
//     the byte for address + k on data_out[7:0] in the same cycle.
//   * Requests that disappear mid-access are still completed (RAM.sv goes to
//     WAIT and waits for idle).
//   * RAM.sv only ever stores one byte per 16-bit word; data_out[15:8] = 0.
// Refresh does not exist here: enable_refresh is ignored, refresh_mode = 0.
//
module KFSDRAM #(
    parameter sdram_col_width       = 9,
    parameter sdram_row_width       = 13,
    parameter sdram_bank_width      = 2,
    parameter sdram_data_width      = 16,
    parameter sdram_no_refresh      = 1'b0,
    parameter sdram_trc             = 16'd5-16'd1,
    parameter sdram_trp             = 16'd1-16'd1,
    parameter sdram_tmrd            = 16'd2-16'd1,
    parameter sdram_trcd            = 16'd1-16'd1,
    parameter sdram_tdpl            = 16'd2-16'd1,
    parameter cas_latency           = 3'b010,
    parameter sdram_init_wait       = 16'd10000,
    parameter sdram_refresh_cycle   = 16'd00100,
    parameter sdram_force_refresh   = 16'd00400
) (
    input   logic                               sdram_clock,
    input   logic                               sdram_reset,

    // Control
    input   logic   [sdram_col_width
                    + sdram_row_width
                    + sdram_bank_width-1:0]     address,
    input   logic   [sdram_col_width-1:0]       access_num,
    input   logic   [sdram_data_width-1:0]      data_in,
    output  reg     [sdram_data_width-1:0]      data_out,
    input   logic                               write_request,
    input   logic                               read_request,
    input   logic                               enable_refresh,
    output  logic                               write_flag,
    output  reg                                 read_flag,
    output  logic                               refresh_mode,
    output  logic                               idle,

    // SDRAM pins, re-purposed as the Avalon-style byte bus (see header)
    output  logic   [sdram_row_width-1:0]       sdram_address,
    output  logic                               sdram_cke,
    output  logic                               sdram_cs,
    output  logic                               sdram_ras,
    output  logic                               sdram_cas,
    output  logic                               sdram_we,
    output  logic   [sdram_bank_width-1:0]      sdram_ba,
    input   logic   [sdram_data_width-1:0]      sdram_dq_in,
    output  logic   [sdram_data_width-1:0]      sdram_dq_out,
    output  logic                               sdram_dq_io
);

    // RAM.sv only ever asks for 1 or 2 beats (a byte, or a byte plus its
    // lookahead / the other half of an 8086 word). Two buffers suffice.
    localparam int MAX_BEATS = 2;
    localparam int INIT_CYCLES = 16;    // let the backend leave reset first

    typedef enum logic [2:0] { INIT, IDLE, WRITE_BEATS, WRITE_ISSUE, READ_ISSUE, READ_OUT } state_t;
    state_t state;

    logic [21:0]    avm_address;
    logic [7:0]     avm_writedata;
    logic           avm_read;
    logic           avm_write;
    wire  [7:0]     avm_readdata      = sdram_dq_in[7:0];
    wire            avm_waitrequest   = sdram_dq_in[8];
    wire            avm_readdatavalid = sdram_dq_in[9];
    wire            avm_accept        = (avm_read | avm_write) & ~avm_waitrequest;

    logic [21:0]    base_address;
    logic [1:0]     beats;              // 1 or 2
    logic [1:0]     beat;               // beats sampled / commands issued
    logic [1:0]     resp;               // read responses received
    logic [7:0]     wbuf [0:MAX_BEATS-1];
    logic [7:0]     rbuf [0:MAX_BEATS-1];
    logic [1:0]     out_beat;
    logic [4:0]     init_counter;

    wire  [1:0]     req_beats = (access_num == 0) ? 2'd1
                              : (access_num > MAX_BEATS) ? MAX_BEATS[1:0]
                              : access_num[1:0];

    always_ff @(posedge sdram_clock, posedge sdram_reset) begin
        if (sdram_reset) begin
            state         <= INIT;
            init_counter  <= 0;
            base_address  <= 0;
            beats         <= 2'd1;
            beat          <= 0;
            resp          <= 0;
            out_beat      <= 0;
            avm_address   <= 0;
            avm_writedata <= 0;
            avm_read      <= 1'b0;
            avm_write     <= 1'b0;
            data_out      <= 0;
            read_flag     <= 1'b0;
            wbuf[0]       <= 8'h00;
            wbuf[1]       <= 8'h00;
            rbuf[0]       <= 8'h00;
            rbuf[1]       <= 8'h00;
        end
        else begin
            read_flag <= 1'b0;

            case (state)
                INIT: begin
                    init_counter <= init_counter + 1'b1;
                    if (init_counter == INIT_CYCLES - 1)
                        state <= IDLE;
                end

                IDLE: begin
                    beat <= 0;
                    resp <= 0;
                    out_beat <= 0;
                    if (write_request) begin
                        base_address <= address[21:0];
                        beats        <= req_beats;
                        state        <= WRITE_BEATS;
                    end
                    else if (read_request) begin
                        base_address <= address[21:0];
                        beats        <= req_beats;
                        state        <= READ_ISSUE;
                    end
                end

                // write_flag is high here. Upstream samples data_in on every
                // WRITE cycle; the first sample is beat 0.
                WRITE_BEATS: begin
                    wbuf[beat] <= data_in[7:0];
                    beat       <= beat + 1'b1;
                    if (beat == beats - 1) begin
                        // first Avalon write goes out on the next edge
                        avm_address   <= base_address;
                        avm_writedata <= wbuf[0];   // overwritten below if beat 0 is this cycle
                        if (beat == 0)
                            avm_writedata <= data_in[7:0];
                        avm_write     <= 1'b1;
                        beat          <= 0;
                        state         <= WRITE_ISSUE;
                    end
                end

                WRITE_ISSUE: begin
                    if (avm_accept) begin
                        if (beat == beats - 1) begin
                            avm_write <= 1'b0;
                            state     <= IDLE;
                        end
                        else begin
                            beat          <= beat + 1'b1;
                            avm_address   <= base_address + 22'd1;
                            avm_writedata <= wbuf[1];
                        end
                    end
                end

                // Issue `beats` reads back to back (pipelined) and collect the
                // responses in order.
                READ_ISSUE: begin
                    if (~avm_read && (beat == 0)) begin
                        avm_address <= base_address;
                        avm_read    <= 1'b1;
                    end
                    if (avm_accept) begin
                        if (beat == beats - 1)
                            avm_read <= 1'b0;
                        else
                            avm_address <= base_address + 22'd1;
                        beat <= beat + 1'b1;
                    end
                    if (avm_readdatavalid) begin
                        rbuf[resp] <= avm_readdata;
                        resp       <= resp + 1'b1;
                        if (resp == beats - 1) begin
                            // present beat 0 on the next edge
                            data_out  <= {8'h00, avm_readdata};
                            if (beats != 2'd1)
                                data_out <= {8'h00, rbuf[0]};
                            read_flag <= 1'b1;
                            out_beat  <= 2'd1;
                            state     <= READ_OUT;
                        end
                    end
                end

                READ_OUT: begin
                    if (out_beat < beats) begin
                        data_out  <= {8'h00, rbuf[out_beat]};
                        read_flag <= 1'b1;
                        out_beat  <= out_beat + 1'b1;
                    end
                    else begin
                        state <= IDLE;
                    end
                end

                default: state <= INIT;
            endcase
        end
    end

    //
    // Status, as RAM.sv expects it
    //
    assign  idle         = (state == IDLE);
    // Held until the last Avalon write is accepted, so that RAM.sv (which
    // raises READY on the falling edge) never reports a write complete before
    // the backend holds it. Upstream commits inside the WRITE state too.
    assign  write_flag   = (state == WRITE_BEATS) || (state == WRITE_ISSUE);
    assign  refresh_mode = 1'b0;

    //
    // The re-purposed pins
    //
    assign  sdram_address = avm_address[12:0];
    assign  sdram_ba      = avm_address[14:13];
    assign  sdram_dq_out  = {avm_address[21:15], 1'b0, avm_writedata};
    assign  sdram_ras     = ~avm_read;
    assign  sdram_we      = ~avm_write;
    assign  sdram_dq_io   = ~avm_write;
    assign  sdram_cas     = 1'b1;
    assign  sdram_cs      = 1'b0;
    assign  sdram_cke     = (state != INIT);

endmodule
