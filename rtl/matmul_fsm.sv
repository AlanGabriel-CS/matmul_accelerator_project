// matmul_fsm.sv
// Control FSM: on ctrl_start, walks C_ij = sum_k(A_ik * B_kj) for all
// (i, j) in the N x M output, generating read addresses into the A/B
// scratchpads and a write address into the C scratchpad, and sequencing
// mac_unit's clear/enable so each (i, j) accumulates a fresh dot product
// over K terms before writing back.
//
// Matrices are stored row-major within their own scratchpad, relative to
// their base address: A[i][k] -> base_addr_a + i*K + k, B[k][j] ->
// base_addr_b + k*M + j, C[i][j] -> base_addr_c + i*M + j.
//
// scratchpad_ram's read port has one cycle of synchronous latency (data
// for an address driven this cycle isn't valid until next cycle), so each
// k iteration spends one cycle driving the next A/B address (FETCH) and
// one cycle folding the now-valid operands into the accumulator (ACCUM)
// rather than overlapping the two -- simple, correct control over raw
// throughput, matching this project's scope.
//
// N/K/M and the base addresses are latched on START so a host write to
// DIMS/BASE_ADDR_* mid-computation can't perturb an already-running pass.

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

    typedef enum logic [2:0] {
        STATE_IDLE,
        STATE_CLEAR,
        STATE_FETCH,
        STATE_ACCUM,
        STATE_WRITEBACK,
        STATE_DONE
    } state_t;

    state_t state_q, state_d;

    // Latched operands for the in-flight pass.
    logic [7:0]                    n_r, k_r, m_r;
    logic [SCRATCH_ADDR_WIDTH-1:0] base_a_r, base_b_r, base_c_r;

    // i walks rows of A/C, j walks cols of B/C, k walks the inner
    // dot-product dimension.
    logic [7:0] i_q, i_d;
    logic [7:0] j_q, j_d;
    logic [7:0] k_q, k_d;

    logic last_k, last_j, last_i;
    assign last_k = (k_q == k_r - 8'd1);
    assign last_j = (j_q == m_r - 8'd1);
    assign last_i = (i_q == n_r - 8'd1);

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) state_q <= STATE_IDLE;
        else        state_q <= state_d;
    end

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            n_r      <= '0;
            k_r      <= '0;
            m_r      <= '0;
            base_a_r <= '0;
            base_b_r <= '0;
            base_c_r <= '0;
        end else if (ctrl_start && (state_q == STATE_IDLE)) begin
            n_r      <= dim_n;
            k_r      <= dim_k;
            m_r      <= dim_m;
            base_a_r <= base_addr_a;
            base_b_r <= base_addr_b;
            base_c_r <= base_addr_c;
        end
    end

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            i_q <= '0;
            j_q <= '0;
            k_q <= '0;
        end else begin
            i_q <= i_d;
            j_q <= j_d;
            k_q <= k_d;
        end
    end

    always_comb begin
        state_d = state_q;
        i_d     = i_q;
        j_d     = j_q;
        k_d     = k_q;

        case (state_q)
            STATE_IDLE: begin
                if (ctrl_start) begin
                    i_d     = '0;
                    j_d     = '0;
                    k_d     = '0;
                    state_d = STATE_CLEAR;
                end
            end

            // mac_clear pulses this cycle (see output assigns below);
            // the first A/B address pair is driven starting next cycle.
            STATE_CLEAR: state_d = STATE_FETCH;

            // a_addr/b_addr driven this cycle; scratchpad_ram's
            // synchronous read means the data isn't valid until next
            // cycle -- that's STATE_ACCUM.
            STATE_FETCH: state_d = STATE_ACCUM;

            // a_rdata/b_rdata valid now; mac_enable pulses this cycle to
            // fold a*b into acc.
            STATE_ACCUM: begin
                if (last_k) begin
                    state_d = STATE_WRITEBACK;
                end else begin
                    k_d     = k_q + 8'd1;
                    state_d = STATE_FETCH;
                end
            end

            // c_addr/c_en/c_we driven this cycle, writing mac_acc (valid
            // since last cycle's STATE_ACCUM).
            STATE_WRITEBACK: begin
                k_d = '0;
                if (last_j && last_i) begin
                    state_d = STATE_DONE;
                end else if (last_j) begin
                    j_d     = '0;
                    i_d     = i_q + 8'd1;
                    state_d = STATE_CLEAR;
                end else begin
                    j_d     = j_q + 8'd1;
                    state_d = STATE_CLEAR;
                end
            end

            STATE_DONE: state_d = STATE_IDLE;

            default: state_d = STATE_IDLE;
        endcase
    end

    assign status_busy = (state_q != STATE_IDLE);
    assign status_done = (state_q == STATE_DONE);

    assign a_en = (state_q == STATE_FETCH);
    assign b_en = (state_q == STATE_FETCH);

    logic [15:0] a_addr_full, b_addr_full, c_addr_full;
    assign a_addr_full = 16'(base_a_r) + (16'(i_q) * 16'(k_r)) + 16'(k_q);
    assign b_addr_full = 16'(base_b_r) + (16'(k_q) * 16'(m_r)) + 16'(j_q);
    assign c_addr_full = 16'(base_c_r) + (16'(i_q) * 16'(m_r)) + 16'(j_q);

    assign a_addr = a_addr_full[SCRATCH_ADDR_WIDTH-1:0];
    assign b_addr = b_addr_full[SCRATCH_ADDR_WIDTH-1:0];
    assign c_addr = c_addr_full[SCRATCH_ADDR_WIDTH-1:0];

    assign mac_clear  = (state_q == STATE_CLEAR);
    assign mac_enable = (state_q == STATE_ACCUM);

    assign c_en = (state_q == STATE_WRITEBACK);
    assign c_we = (state_q == STATE_WRITEBACK);

endmodule
