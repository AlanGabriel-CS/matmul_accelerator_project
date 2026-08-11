// matmul_fsm.sv
// Control FSM: on ctrl_start, walks C_ij = sum_k(A_ik * B_kj) for all
// (i, j) in the N x M output, generating read addresses into the A/B
// scratchpads and a write address into the C scratchpad, and sequencing
// mac_unit's clear/enable so each (i, j) accumulates a fresh dot product
// over K terms before writing back.
//
// Not yet implemented: state transitions and address generation. This is
// a Week 1 scaffold, not a functional controller.

module matmul_fsm #(
    parameter SCRATCH_ADDR_WIDTH = 8
)(
    input  logic                            clk,
    input  logic                            rst_n,

    // from axi_lite_slave
    input  logic                            ctrl_start,
    input  logic [7:0]                      dim_n,
    input  logic [7:0]                      dim_k,
    input  logic [7:0]                      dim_m,
    input  logic [SCRATCH_ADDR_WIDTH-1:0]   base_addr_a,
    input  logic [SCRATCH_ADDR_WIDTH-1:0]   base_addr_b,
    input  logic [SCRATCH_ADDR_WIDTH-1:0]   base_addr_c,

    // to axi_lite_slave
    output logic                            status_busy,
    output logic                            status_done,

    // to scratchpad_ram (A read port)
    output logic                            a_en,
    output logic [SCRATCH_ADDR_WIDTH-1:0]   a_addr,

    // to scratchpad_ram (B read port)
    output logic                            b_en,
    output logic [SCRATCH_ADDR_WIDTH-1:0]   b_addr,

    // to mac_unit
    output logic                            mac_clear,
    output logic                            mac_enable,

    // to scratchpad_ram (C write port)
    output logic                            c_en,
    output logic                            c_we,
    output logic [SCRATCH_ADDR_WIDTH-1:0]   c_addr
);

    typedef enum logic [1:0] {
        STATE_IDLE,
        STATE_RUN,
        STATE_WRITEBACK,
        STATE_DONE
    } state_t;

    state_t state_q, state_d;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) state_q <= STATE_IDLE;
        else        state_q <= state_d;
    end

    always_comb begin
        state_d = state_q;
        case (state_q)
            STATE_IDLE:      if (ctrl_start) state_d = STATE_RUN;
            STATE_RUN:       state_d = STATE_RUN;       // TODO: row/col/k loop
            STATE_WRITEBACK: state_d = STATE_DONE;       // TODO: write C_ij, loop or finish
            STATE_DONE:      state_d = STATE_IDLE;
            default:         state_d = STATE_IDLE;
        endcase
    end

    assign status_busy = (state_q != STATE_IDLE);
    assign status_done = (state_q == STATE_DONE);

    assign a_en        = 1'b0;
    assign a_addr      = '0;
    assign b_en        = 1'b0;
    assign b_addr      = '0;
    assign mac_clear   = 1'b0;
    assign mac_enable  = 1'b0;
    assign c_en        = 1'b0;
    assign c_we        = 1'b0;
    assign c_addr      = '0;

endmodule
