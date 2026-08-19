// matmul_top.sv
// Top-level: AXI-Lite register interface + three scratchpad RAMs (A, B, C)
// + MAC datapath + control FSM, wired together per the register map
// documented in axi_lite_slave.sv.

module matmul_top #(
    parameter ADDR_WIDTH         = 6,   // AXI-Lite register address width
    parameter DATA_WIDTH         = 32,
    parameter SCRATCH_DEPTH      = 256,
    parameter SCRATCH_ADDR_WIDTH = $clog2(SCRATCH_DEPTH)
)(
    input  logic                    clk,
    input  logic                    rst_n,

    input  logic [ADDR_WIDTH-1:0]   s_axi_awaddr,
    input  logic                    s_axi_awvalid,
    output logic                    s_axi_awready,

    input  logic [DATA_WIDTH-1:0]   s_axi_wdata,
    input  logic [DATA_WIDTH/8-1:0] s_axi_wstrb,
    input  logic                    s_axi_wvalid,
    output logic                    s_axi_wready,

    output logic [1:0]              s_axi_bresp,
    output logic                    s_axi_bvalid,
    input  logic                    s_axi_bready,

    input  logic [ADDR_WIDTH-1:0]   s_axi_araddr,
    input  logic                    s_axi_arvalid,
    output logic                    s_axi_arready,

    output logic [DATA_WIDTH-1:0]   s_axi_rdata,
    output logic [1:0]              s_axi_rresp,
    output logic                    s_axi_rvalid,
    input  logic                    s_axi_rready
);

    logic                           ctrl_start;
    logic [7:0]                     dim_n, dim_k, dim_m;
    logic [SCRATCH_ADDR_WIDTH-1:0]  base_addr_a, base_addr_b, base_addr_c;
    logic                           status_busy, status_done;

    // scratchpad load/read-back port (host <-> port A of each scratchpad,
    // via axi_lite_slave's SCRATCH_SEL/ADDR/WDATA/RDATA registers)
    logic                           ld_a_en, ld_a_we, ld_b_en, ld_b_we, ld_c_en, ld_c_we;
    logic [SCRATCH_ADDR_WIDTH-1:0]  ld_a_addr, ld_b_addr, ld_c_addr;
    logic [DATA_WIDTH-1:0]          ld_a_wdata, ld_b_wdata, ld_c_wdata;
    logic [DATA_WIDTH-1:0]          ld_a_rdata, ld_b_rdata, ld_c_rdata;

    axi_lite_slave #(
        .ADDR_WIDTH         (ADDR_WIDTH),
        .DATA_WIDTH         (DATA_WIDTH),
        .SCRATCH_ADDR_WIDTH (SCRATCH_ADDR_WIDTH)
    ) u_axi_lite_slave (
        .clk           (clk),
        .rst_n         (rst_n),
        .s_axi_awaddr  (s_axi_awaddr),
        .s_axi_awvalid (s_axi_awvalid),
        .s_axi_awready (s_axi_awready),
        .s_axi_wdata   (s_axi_wdata),
        .s_axi_wstrb   (s_axi_wstrb),
        .s_axi_wvalid  (s_axi_wvalid),
        .s_axi_wready  (s_axi_wready),
        .s_axi_bresp   (s_axi_bresp),
        .s_axi_bvalid  (s_axi_bvalid),
        .s_axi_bready  (s_axi_bready),
        .s_axi_araddr  (s_axi_araddr),
        .s_axi_arvalid (s_axi_arvalid),
        .s_axi_arready (s_axi_arready),
        .s_axi_rdata   (s_axi_rdata),
        .s_axi_rresp   (s_axi_rresp),
        .s_axi_rvalid  (s_axi_rvalid),
        .s_axi_rready  (s_axi_rready),
        .ctrl_start    (ctrl_start),
        .dim_n         (dim_n),
        .dim_k         (dim_k),
        .dim_m         (dim_m),
        .base_addr_a   (base_addr_a),
        .base_addr_b   (base_addr_b),
        .base_addr_c   (base_addr_c),
        .status_busy   (status_busy),
        .status_done   (status_done),
        .ld_a_en       (ld_a_en),
        .ld_a_we       (ld_a_we),
        .ld_a_addr     (ld_a_addr),
        .ld_a_wdata    (ld_a_wdata),
        .ld_a_rdata    (ld_a_rdata),
        .ld_b_en       (ld_b_en),
        .ld_b_we       (ld_b_we),
        .ld_b_addr     (ld_b_addr),
        .ld_b_wdata    (ld_b_wdata),
        .ld_b_rdata    (ld_b_rdata),
        .ld_c_en       (ld_c_en),
        .ld_c_we       (ld_c_we),
        .ld_c_addr     (ld_c_addr),
        .ld_c_wdata    (ld_c_wdata),
        .ld_c_rdata    (ld_c_rdata)
    );

    logic                           a_en, b_en, c_en, c_we;
    logic [SCRATCH_ADDR_WIDTH-1:0]  a_addr, b_addr, c_addr;
    logic [DATA_WIDTH-1:0]          a_rdata, b_rdata, c_wdata, c_rdata;
    logic                           mac_clear, mac_enable;
    logic [63:0]                    mac_acc;

    matmul_fsm #(
        .SCRATCH_ADDR_WIDTH (SCRATCH_ADDR_WIDTH)
    ) u_matmul_fsm (
        .clk          (clk),
        .rst_n        (rst_n),
        .ctrl_start   (ctrl_start),
        .dim_n        (dim_n),
        .dim_k        (dim_k),
        .dim_m        (dim_m),
        .base_addr_a  (base_addr_a),
        .base_addr_b  (base_addr_b),
        .base_addr_c  (base_addr_c),
        .status_busy  (status_busy),
        .status_done  (status_done),
        .a_en         (a_en),
        .a_addr       (a_addr),
        .b_en         (b_en),
        .b_addr       (b_addr),
        .mac_clear    (mac_clear),
        .mac_enable   (mac_enable),
        .c_en         (c_en),
        .c_we         (c_we),
        .c_addr       (c_addr)
    );

    // Scratchpad port A (word width DATA_WIDTH) faces the AXI-Lite side,
    // driven by axi_lite_slave's SCRATCH_SEL/ADDR/WDATA/RDATA registers,
    // for pre-load and read-back. Port B faces the MAC datapath via
    // matmul_fsm.
    scratchpad_ram #(
        .DATA_WIDTH (DATA_WIDTH),
        .DEPTH      (SCRATCH_DEPTH)
    ) u_scratchpad_a (
        .clk     (clk),
        .a_en    (ld_a_en),
        .a_we    (ld_a_we),
        .a_addr  (ld_a_addr),
        .a_wdata (ld_a_wdata),
        .a_rdata (ld_a_rdata),
        .b_en    (a_en),
        .b_we    (1'b0),
        .b_addr  (a_addr),
        .b_wdata ('0),
        .b_rdata (a_rdata)
    );

    scratchpad_ram #(
        .DATA_WIDTH (DATA_WIDTH),
        .DEPTH      (SCRATCH_DEPTH)
    ) u_scratchpad_b (
        .clk     (clk),
        .a_en    (ld_b_en),
        .a_we    (ld_b_we),
        .a_addr  (ld_b_addr),
        .a_wdata (ld_b_wdata),
        .a_rdata (ld_b_rdata),
        .b_en    (b_en),
        .b_we    (1'b0),
        .b_addr  (b_addr),
        .b_wdata ('0),
        .b_rdata (b_rdata)
    );

    scratchpad_ram #(
        .DATA_WIDTH (DATA_WIDTH),
        .DEPTH      (SCRATCH_DEPTH)
    ) u_scratchpad_c (
        .clk     (clk),
        .a_en    (ld_c_en),
        .a_we    (ld_c_we),
        .a_addr  (ld_c_addr),
        .a_wdata (ld_c_wdata),
        .a_rdata (ld_c_rdata),
        .b_en    (c_en),
        .b_we    (c_we),
        .b_addr  (c_addr),
        .b_wdata (c_wdata),
        .b_rdata (c_rdata)
    );

    assign c_wdata = mac_acc[DATA_WIDTH-1:0];

    mac_unit #(
        .DATA_WIDTH (DATA_WIDTH),
        .ACC_WIDTH  (64)
    ) u_mac_unit (
        .clk    (clk),
        .rst_n  (rst_n),
        .clear  (mac_clear),
        .enable (mac_enable),
        .a      (a_rdata),
        .b      (b_rdata),
        .acc    (mac_acc)
    );

endmodule
