// scratchpad_ram.sv
// Synchronous dual-port RAM wrapper, inferred (no vendor BRAM primitive).
// One instance per matrix (A, B, C) -- port A is written by the AXI-Lite
// side to pre-load operands (and to read back the result), port B is
// read/written by the MAC datapath during computation.
//
// Port B's one-cycle synchronous read latency is accounted for downstream
// in matmul_fsm (its FETCH/ACCUM state split exists specifically for
// this).

module scratchpad_ram #(
    parameter DATA_WIDTH = 32,
    parameter DEPTH      = 256,
    parameter ADDR_WIDTH = $clog2(DEPTH)
)(
    input  logic                  clk,

    // port A
    input  logic                  a_en,
    input  logic                  a_we,
    input  logic [ADDR_WIDTH-1:0] a_addr,
    input  logic [DATA_WIDTH-1:0] a_wdata,
    output logic [DATA_WIDTH-1:0] a_rdata,

    // port B
    input  logic                  b_en,
    input  logic                  b_we,
    input  logic [ADDR_WIDTH-1:0] b_addr,
    input  logic [DATA_WIDTH-1:0] b_wdata,
    output logic [DATA_WIDTH-1:0] b_rdata
);

    logic [DATA_WIDTH-1:0] mem [DEPTH];

    always_ff @(posedge clk) begin
        if (a_en) begin
            if (a_we) mem[a_addr] <= a_wdata;
            a_rdata <= mem[a_addr];
        end
    end

    always_ff @(posedge clk) begin
        if (b_en) begin
            if (b_we) mem[b_addr] <= b_wdata;
            b_rdata <= mem[b_addr];
        end
    end

endmodule
