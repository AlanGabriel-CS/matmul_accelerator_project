// axi_lite_slave.sv
// AXI-Lite register interface for the matrix multiplier accelerator.
//
// Register map (word-addressed, 32-bit registers):
//   0x00  CTRL_STATUS
//           bit 0  START  (W1P from host, self-clears; read as 0)
//           bit 1  BUSY   (RO, set while matmul_fsm is running)
//           bit 2  DONE   (RO/W1C, set on completion, cleared by writing 1 or by next START)
//   0x04  DIMS
//           [7:0]   N  (rows of A, rows of C)
//           [15:8]  K  (cols of A, rows of B)
//           [23:16] M  (cols of B, cols of C)
//   0x08  BASE_ADDR_A  (scratchpad word offset for matrix A)
//   0x0C  BASE_ADDR_B  (scratchpad word offset for matrix B)
//   0x10  BASE_ADDR_C  (scratchpad word offset for matrix C)
//           -- extends the originally specified 0x00/0x04/0x08/0x0C map by one
//              register: two base addresses alone can't independently locate
//              three scratchpads (A, B, C), so C gets its own base register
//              rather than sharing A's or B's address space.
//
// Not yet implemented: read/write channel logic (currently drives safe
// defaults only). This is a Week 1 scaffold, not a functional interface.

module axi_lite_slave #(
    parameter ADDR_WIDTH        = 5,   // AXI-Lite register address width (5 registers)
    parameter DATA_WIDTH        = 32,
    parameter SCRATCH_ADDR_WIDTH = 8   // scratchpad memory address width (independent of ADDR_WIDTH)
)(
    input  logic                    clk,
    input  logic                    rst_n,

    // AXI-Lite write address channel
    input  logic [ADDR_WIDTH-1:0]   s_axi_awaddr,
    input  logic                    s_axi_awvalid,
    output logic                    s_axi_awready,

    // AXI-Lite write data channel
    input  logic [DATA_WIDTH-1:0]   s_axi_wdata,
    input  logic [DATA_WIDTH/8-1:0] s_axi_wstrb,
    input  logic                    s_axi_wvalid,
    output logic                    s_axi_wready,

    // AXI-Lite write response channel
    output logic [1:0]              s_axi_bresp,
    output logic                    s_axi_bvalid,
    input  logic                    s_axi_bready,

    // AXI-Lite read address channel
    input  logic [ADDR_WIDTH-1:0]   s_axi_araddr,
    input  logic                    s_axi_arvalid,
    output logic                    s_axi_arready,

    // AXI-Lite read data channel
    output logic [DATA_WIDTH-1:0]   s_axi_rdata,
    output logic [1:0]              s_axi_rresp,
    output logic                    s_axi_rvalid,
    input  logic                    s_axi_rready,

    // decoded register outputs -- consumed by matmul_fsm / scratchpads
    output logic                          ctrl_start,
    output logic [7:0]                    dim_n,
    output logic [7:0]                    dim_k,
    output logic [7:0]                    dim_m,
    output logic [SCRATCH_ADDR_WIDTH-1:0] base_addr_a,
    output logic [SCRATCH_ADDR_WIDTH-1:0] base_addr_b,
    output logic [SCRATCH_ADDR_WIDTH-1:0] base_addr_c,

    // status inputs -- driven back by matmul_fsm
    input  logic                    status_busy,
    input  logic                    status_done
);

    // TODO: address decode, write-enable generation, and register file.
    // TODO: read-data mux back to s_axi_rdata.

    assign s_axi_awready = 1'b0;
    assign s_axi_wready  = 1'b0;
    assign s_axi_bresp   = 2'b00;
    assign s_axi_bvalid  = 1'b0;
    assign s_axi_arready = 1'b0;
    assign s_axi_rdata   = '0;
    assign s_axi_rresp   = 2'b00;
    assign s_axi_rvalid  = 1'b0;

    assign ctrl_start  = 1'b0;
    assign dim_n        = '0;
    assign dim_k        = '0;
    assign dim_m        = '0;
    assign base_addr_a  = '0;
    assign base_addr_b  = '0;
    assign base_addr_c  = '0;

endmodule
