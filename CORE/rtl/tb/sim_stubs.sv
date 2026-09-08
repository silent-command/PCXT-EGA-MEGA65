// Simulation stand-ins for the VHDL entities the core instantiates from
// Verilog, so the whole wrapper builds under Verilator (no VHDL support).
//
//   dpram       rtl/common/bram.vhd (ide.v's 512-byte buffers): functional model,
//               write-first on each port, q forced to 1s while cs is low
//   uart_16750  rtl/uart/uart_16750.vhd: idle stub, never receives, always
//               ready to transmit (nothing in these benches talks to COM ports)

module dpram #(
    parameter addr_width    = 8,
    parameter data_width    = 8,
    parameter mem_init_file = " "
) (
    input  wire                   clock,
    input  wire [addr_width-1:0]  address_a,
    input  wire [data_width-1:0]  data_a,
    input  wire                   enable_a,
    input  wire                   wren_a,
    output wire [data_width-1:0]  q_a,
    input  wire                   cs_a,
    input  wire [addr_width-1:0]  address_b,
    input  wire [data_width-1:0]  data_b,
    input  wire                   enable_b,
    input  wire                   wren_b,
    output wire [data_width-1:0]  q_b,
    input  wire                   cs_b
);
    reg [data_width-1:0] mem [0:(1<<addr_width)-1];
    reg [data_width-1:0] q0 = 0, q1 = 0;
    always @(posedge clock) begin
        if (enable_a) begin
            if (wren_a & cs_a) begin mem[address_a] <= data_a; q0 <= data_a; end
            else q0 <= mem[address_a];
        end
        if (enable_b) begin
            if (wren_b & cs_b) begin mem[address_b] <= data_b; q1 <= data_b; end
            else q1 <= mem[address_b];
        end
    end
    assign q_a = cs_a ? q0 : {data_width{1'b1}};
    assign q_b = cs_b ? q1 : {data_width{1'b1}};
endmodule

module uart_16750 (
    input  wire       CLK,
    input  wire       RST,
    input  wire       BAUDCE,
    input  wire       CS,
    input  wire       WR,
    input  wire       RD,
    input  wire [2:0] A,
    input  wire [7:0] DIN,
    output wire [7:0] DOUT,
    output wire       DDIS,
    output wire       INT,
    output wire       OUT1N,
    output wire       OUT2N,
    input  wire       RCLK,
    output wire       BAUDOUTN,
    output wire       RTSN,
    output wire       DTRN,
    input  wire       CTSN,
    input  wire       DSRN,
    input  wire       DCDN,
    input  wire       RIN,
    input  wire       SIN,
    output wire       SOUT,
    output wire       LSR_DR,
    output wire       LSR_THRE
);
    assign DOUT     = 8'h00;
    assign DDIS     = 1'b0;
    assign INT      = 1'b0;
    assign OUT1N    = 1'b1;
    assign OUT2N    = 1'b1;
    assign BAUDOUTN = 1'b1;
    assign RTSN     = 1'b1;
    assign DTRN     = 1'b1;
    assign SOUT     = 1'b1;
    assign LSR_DR   = 1'b0;
    assign LSR_THRE = 1'b1;
endmodule

// saa1099 (C/MS sound): Verilator rejects the upstream array literals, and the
// chip has no part in any current bench, so it is a silent stub here.
module saa1099 (
    input        clk_sys,
    input        ce,
    input        rst_n,
    input        cs_n,
    input        a0,
    input        wr_n,
    input  [7:0] din,
    output [7:0] out_l,
    output [7:0] out_r
);
    assign out_l = 8'h00;
    assign out_r = 8'h00;
endmodule

// Xilinx glitch-free clock mux used by the wrapper: a plain mux in simulation.
module BUFGMUX_CTRL (
    input  I0,
    input  I1,
    input  S,
    output O
);
    assign O = S ? I1 : I0;
endmodule

// XT2IDE (XT-IDE bridge) and vga_dac: upstream uses constructs Verilator does
// not support (mixed blocking/non-blocking, delayed array writes in loops).
// Neither matters for the bring-up benches; both are inert stubs here.
module XT2IDE (
    input   logic           clock,
    input   logic           reset,
    input   logic           high_speed,
    input   logic           chip_select_n,
    input   logic           io_read_n,
    input   logic           io_write_n,
    input   logic   [4:0]   address,
    input   logic   [7:0]   data_bus_in,
    output  logic   [7:0]   data_bus_out,
    output  logic           ide_cs1fx,
    output  logic           ide_cs3fx,
    output  logic           ide_io_read_n,
    output  logic           ide_io_write_n,
    output  logic   [2:0]   ide_address,
    input   logic   [15:0]  ide_data_bus_in,
    output  logic   [15:0]  ide_data_bus_out
);
    assign data_bus_out     = 8'hFF;
    assign ide_cs1fx        = 1'b1;
    assign ide_cs3fx        = 1'b1;
    assign ide_io_read_n    = 1'b1;
    assign ide_io_write_n   = 1'b1;
    assign ide_address      = 3'b000;
    assign ide_data_bus_out = 16'h0000;
endmodule

module vga_dac (
    input  wire        clock,
    input  wire        reset,
    input  wire        load_defaults,
    input  wire        invalidate,
    input  wire        write_en,
    input  wire [7:0]  write_index,
    input  wire [5:0]  write_red,
    input  wire [5:0]  write_green,
    input  wire [5:0]  write_blue,
    input  wire        component_write_en,
    input  wire [7:0]  component_write_index,
    input  wire [1:0]  component_select,
    input  wire [5:0]  component_data,
    input  wire [7:0]  sample_index,
    output wire [5:0]  sample_red,
    output wire [5:0]  sample_green,
    output wire [5:0]  sample_blue,
    output wire [7:0]  sample_red_8,
    output wire [7:0]  sample_green_8,
    output wire [7:0]  sample_blue_8,
    output wire        sample_valid,
    input  wire [7:0]  port_index,
    output wire [5:0]  port_red,
    output wire [5:0]  port_green,
    output wire [5:0]  port_blue,
    output wire        port_valid
);
    assign sample_red = 6'd0; assign sample_green = 6'd0; assign sample_blue = 6'd0;
    assign sample_red_8 = 8'd0; assign sample_green_8 = 8'd0; assign sample_blue_8 = 8'd0;
    assign sample_valid = 1'b0;
    assign port_red = 6'd0; assign port_green = 6'd0; assign port_blue = 6'd0;
    assign port_valid = 1'b0;
endmodule
