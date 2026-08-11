// mac_unit.sv
// Single multiply-accumulate block: acc <= acc + (a * b) when enabled,
// or loads acc directly when clearing (start of a new dot product).
//
// Not yet implemented: the FSM side that sequences operand feeds and
// clears acc at the start of each C_ij accumulation. This is a Week 1
// scaffold, not a functional datapath.

module mac_unit #(
    parameter DATA_WIDTH = 32,
    parameter ACC_WIDTH  = 64
)(
    input  logic                   clk,
    input  logic                   rst_n,

    input  logic                   clear,   // synchronous clear of acc (new dot product)
    input  logic                   enable,  // accumulate this cycle's a*b into acc
    input  logic [DATA_WIDTH-1:0]  a,
    input  logic [DATA_WIDTH-1:0]  b,

    output logic [ACC_WIDTH-1:0]   acc
);

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            acc <= '0;
        end else if (clear) begin
            acc <= '0;
        end else if (enable) begin
            acc <= acc + (ACC_WIDTH'(a) * ACC_WIDTH'(b));
        end
    end

endmodule
