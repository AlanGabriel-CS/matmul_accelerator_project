// mac_unit.sv
// Single multiply-accumulate block: acc <= acc + (a * b) when enabled,
// or loads acc directly when clearing (start of a new dot product).
//
// a/b/acc are all `signed` -- matrix elements are two's-complement, and
// an unsigned ACC_WIDTH'(a) cast would zero-extend a negative a/b into a
// huge positive value instead of sign-extending it, corrupting any
// product involving a negative operand.
//
// Sequenced by matmul_fsm: clear pulses once per (i, j) output element,
// enable pulses once per k term of that element's dot product.

module mac_unit #(
    parameter DATA_WIDTH = 32,
    parameter ACC_WIDTH  = 64
)(
    input  logic                          clk,
    input  logic                          rst_n,

    input  logic                          clear,   // synchronous clear of acc (new dot product)
    input  logic                          enable,  // accumulate this cycle's a*b into acc
    input  logic signed [DATA_WIDTH-1:0]  a,
    input  logic signed [DATA_WIDTH-1:0]  b,

    output logic signed [ACC_WIDTH-1:0]   acc
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
