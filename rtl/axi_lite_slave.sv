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
//   0x14  SCRATCH_SEL    [1:0] selects which scratchpad the load/read-back
//                        window below targets: 0=A, 1=B, 2=C.
//   0x18  SCRATCH_ADDR   word address within the selected scratchpad.
//                        Auto-increments after every SCRATCH_WDATA write or
//                        SCRATCH_RDATA read, so a host streams a whole
//                        matrix by setting SEL+ADDR once and then hitting
//                        WDATA/RDATA back-to-back.
//   0x1C  SCRATCH_WDATA  W-only. Writing stores the word into
//                        scratch[SEL][ADDR], then ADDR++. Reads as 0.
//   0x20  SCRATCH_RDATA  R-only. Reading returns scratch[SEL][ADDR], then
//                        ADDR++. Costs one extra read-latency cycle versus
//                        the plain registers above, since it goes through
//                        the scratchpad RAM's synchronous read port.
//
// Single-outstanding-transaction slave: awready/wready are asserted
// whenever no write response is pending, arready whenever no read data (or
// a pending scratchpad read) is outstanding. Matches the cocotb
// testbench's one-transaction-at-a-time usage.

module axi_lite_slave #(
    parameter ADDR_WIDTH        = 6,   // AXI-Lite register address width (9 registers)
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
    input  logic                    status_done,

    // scratchpad load/read-back port A, one set per matrix -- driven here,
    // wired straight through to each scratchpad_ram's port A in
    // matmul_top. Only the RAM selected by SCRATCH_SEL is ever enabled.
    output logic                          ld_a_en,
    output logic                          ld_a_we,
    output logic [SCRATCH_ADDR_WIDTH-1:0] ld_a_addr,
    output logic [DATA_WIDTH-1:0]         ld_a_wdata,
    input  logic [DATA_WIDTH-1:0]         ld_a_rdata,

    output logic                          ld_b_en,
    output logic                          ld_b_we,
    output logic [SCRATCH_ADDR_WIDTH-1:0] ld_b_addr,
    output logic [DATA_WIDTH-1:0]         ld_b_wdata,
    input  logic [DATA_WIDTH-1:0]         ld_b_rdata,

    output logic                          ld_c_en,
    output logic                          ld_c_we,
    output logic [SCRATCH_ADDR_WIDTH-1:0] ld_c_addr,
    output logic [DATA_WIDTH-1:0]         ld_c_wdata,
    input  logic [DATA_WIDTH-1:0]         ld_c_rdata
);

    localparam int REG_CTRL_STATUS  = 0;
    localparam int REG_DIMS         = 1;
    localparam int REG_BASE_A       = 2;
    localparam int REG_BASE_B       = 3;
    localparam int REG_BASE_C       = 4;
    localparam int REG_SCRATCH_SEL  = 5;
    localparam int REG_SCRATCH_ADDR = 6;
    localparam int REG_SCRATCH_WDATA = 7;
    localparam int REG_SCRATCH_RDATA = 8;

    // word-select: registers are 4-byte aligned, so drop the byte offset.
    logic [ADDR_WIDTH-3:0] waddr_sel;
    logic [ADDR_WIDTH-3:0] raddr_sel;

    // ---------------------------------------------------------------
    // Write channel: accept a transfer whenever no response is pending.
    // ---------------------------------------------------------------
    logic write_en;

    assign s_axi_awready = !s_axi_bvalid;
    assign s_axi_wready  = !s_axi_bvalid;
    assign write_en      = s_axi_awvalid && s_axi_wvalid && !s_axi_bvalid;
    assign waddr_sel      = s_axi_awaddr[ADDR_WIDTH-1:2];

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            s_axi_bvalid <= 1'b0;
            s_axi_bresp  <= 2'b00;
        end else if (write_en) begin
            s_axi_bvalid <= 1'b1;
            s_axi_bresp  <= 2'b00; // OKAY
        end else if (s_axi_bvalid && s_axi_bready) begin
            s_axi_bvalid <= 1'b0;
        end
    end

    // ---------------------------------------------------------------
    // Read channel: accept a request whenever no read data (or a pending
    // scratchpad read) is outstanding. SCRATCH_RDATA needs one extra
    // cycle beyond the normal 1-cycle read latency, since its data comes
    // from the scratchpad RAM's own synchronous read port rather than a
    // plain register.
    // ---------------------------------------------------------------
    logic [ADDR_WIDTH-3:0] read_sel_q;
    logic                  scratch_rd_pending;
    logic                  scratch_rd_issue;

    assign s_axi_arready = !(s_axi_rvalid || scratch_rd_pending);
    assign raddr_sel      = s_axi_araddr[ADDR_WIDTH-1:2];
    assign scratch_rd_issue = s_axi_arvalid && s_axi_arready &&
                               (raddr_sel == REG_SCRATCH_RDATA[ADDR_WIDTH-3:0]);

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            s_axi_rvalid       <= 1'b0;
            s_axi_rresp        <= 2'b00;
            read_sel_q         <= '0;
            scratch_rd_pending <= 1'b0;
        end else if (s_axi_arvalid && s_axi_arready) begin
            s_axi_rresp <= 2'b00; // OKAY
            read_sel_q  <= raddr_sel;
            if (raddr_sel == REG_SCRATCH_RDATA[ADDR_WIDTH-3:0]) begin
                scratch_rd_pending <= 1'b1;
                s_axi_rvalid       <= 1'b0;
            end else begin
                s_axi_rvalid <= 1'b1;
            end
        end else if (scratch_rd_pending) begin
            s_axi_rvalid       <= 1'b1;
            scratch_rd_pending <= 1'b0;
        end else if (s_axi_rvalid && s_axi_rready) begin
            s_axi_rvalid <= 1'b0;
        end
    end

    // ---------------------------------------------------------------
    // Register file
    // ---------------------------------------------------------------
    logic done_reg;
    logic ctrl_start_pulse;

    logic [7:0] dim_n_reg, dim_k_reg, dim_m_reg;
    logic [SCRATCH_ADDR_WIDTH-1:0] base_addr_a_reg, base_addr_b_reg, base_addr_c_reg;

    logic [1:0]                    scratch_sel_reg;   // 0=A, 1=B, 2=C
    logic [SCRATCH_ADDR_WIDTH-1:0] scratch_addr_reg;
    logic                          scratch_wr_issue;

    assign scratch_wr_issue = write_en && (waddr_sel == REG_SCRATCH_WDATA[ADDR_WIDTH-3:0]);

    // START is a one-cycle pulse coincident with the write transfer that
    // sets it; it never lives in a readable bit.
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            ctrl_start_pulse <= 1'b0;
        end else begin
            ctrl_start_pulse <= write_en && (waddr_sel == REG_CTRL_STATUS[ADDR_WIDTH-3:0]) &&
                                 s_axi_wstrb[0] && s_axi_wdata[0];
        end
    end
    assign ctrl_start = ctrl_start_pulse;

    // DONE: set by the FSM's status_done, cleared by a new START or a W1C
    // write to bit 2. New-START clear takes priority over a stale done bit.
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            done_reg <= 1'b0;
        end else if (ctrl_start_pulse) begin
            done_reg <= 1'b0;
        end else if (status_done) begin
            done_reg <= 1'b1;
        end else if (write_en && (waddr_sel == REG_CTRL_STATUS[ADDR_WIDTH-3:0]) &&
                     s_axi_wstrb[0] && s_axi_wdata[2]) begin
            done_reg <= 1'b0;
        end
    end

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            dim_n_reg       <= '0;
            dim_k_reg       <= '0;
            dim_m_reg       <= '0;
            base_addr_a_reg <= '0;
            base_addr_b_reg <= '0;
            base_addr_c_reg <= '0;
            scratch_sel_reg <= '0;
        end else if (write_en) begin
            case (waddr_sel)
                REG_DIMS[ADDR_WIDTH-3:0]: begin
                    if (s_axi_wstrb[0]) dim_n_reg <= s_axi_wdata[7:0];
                    if (s_axi_wstrb[1]) dim_k_reg <= s_axi_wdata[15:8];
                    if (s_axi_wstrb[2]) dim_m_reg <= s_axi_wdata[23:16];
                end
                REG_BASE_A[ADDR_WIDTH-3:0]:      base_addr_a_reg <= s_axi_wdata[SCRATCH_ADDR_WIDTH-1:0];
                REG_BASE_B[ADDR_WIDTH-3:0]:      base_addr_b_reg <= s_axi_wdata[SCRATCH_ADDR_WIDTH-1:0];
                REG_BASE_C[ADDR_WIDTH-3:0]:      base_addr_c_reg <= s_axi_wdata[SCRATCH_ADDR_WIDTH-1:0];
                REG_SCRATCH_SEL[ADDR_WIDTH-3:0]: scratch_sel_reg <= s_axi_wdata[1:0];
                default: ; // CTRL_STATUS / SCRATCH_ADDR / SCRATCH_WDATA handled elsewhere
            endcase
        end
    end

    // SCRATCH_ADDR: an explicit host write sets it directly; otherwise it
    // auto-increments once after a load write or a read-back read.
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            scratch_addr_reg <= '0;
        end else if (write_en && (waddr_sel == REG_SCRATCH_ADDR[ADDR_WIDTH-3:0])) begin
            scratch_addr_reg <= s_axi_wdata[SCRATCH_ADDR_WIDTH-1:0];
        end else if (scratch_wr_issue || scratch_rd_issue) begin
            scratch_addr_reg <= scratch_addr_reg + 1'b1;
        end
    end

    assign dim_n       = dim_n_reg;
    assign dim_k       = dim_k_reg;
    assign dim_m       = dim_m_reg;
    assign base_addr_a = base_addr_a_reg;
    assign base_addr_b = base_addr_b_reg;
    assign base_addr_c = base_addr_c_reg;

    // ---------------------------------------------------------------
    // Scratchpad load/read-back port: only the RAM selected by
    // scratch_sel_reg is ever enabled, for both the write path (host
    // storing into SCRATCH_WDATA) and the read path (scratch_rd_issue).
    // ---------------------------------------------------------------
    assign ld_a_en    = (scratch_wr_issue || scratch_rd_issue) && (scratch_sel_reg == 2'd0);
    assign ld_a_we    = scratch_wr_issue && (scratch_sel_reg == 2'd0);
    assign ld_a_addr  = scratch_addr_reg;
    assign ld_a_wdata = s_axi_wdata;

    assign ld_b_en    = (scratch_wr_issue || scratch_rd_issue) && (scratch_sel_reg == 2'd1);
    assign ld_b_we    = scratch_wr_issue && (scratch_sel_reg == 2'd1);
    assign ld_b_addr  = scratch_addr_reg;
    assign ld_b_wdata = s_axi_wdata;

    assign ld_c_en    = (scratch_wr_issue || scratch_rd_issue) && (scratch_sel_reg == 2'd2);
    assign ld_c_we    = scratch_wr_issue && (scratch_sel_reg == 2'd2);
    assign ld_c_addr  = scratch_addr_reg;
    assign ld_c_wdata = s_axi_wdata;

    // ---------------------------------------------------------------
    // Read-data mux
    // ---------------------------------------------------------------
    always_comb begin
        case (read_sel_q)
            REG_CTRL_STATUS[ADDR_WIDTH-3:0]:
                s_axi_rdata = {{(DATA_WIDTH-3){1'b0}}, done_reg, status_busy, 1'b0};
            REG_DIMS[ADDR_WIDTH-3:0]:
                s_axi_rdata = {{(DATA_WIDTH-24){1'b0}}, dim_m_reg, dim_k_reg, dim_n_reg};
            REG_BASE_A[ADDR_WIDTH-3:0]:
                s_axi_rdata = {{(DATA_WIDTH-SCRATCH_ADDR_WIDTH){1'b0}}, base_addr_a_reg};
            REG_BASE_B[ADDR_WIDTH-3:0]:
                s_axi_rdata = {{(DATA_WIDTH-SCRATCH_ADDR_WIDTH){1'b0}}, base_addr_b_reg};
            REG_BASE_C[ADDR_WIDTH-3:0]:
                s_axi_rdata = {{(DATA_WIDTH-SCRATCH_ADDR_WIDTH){1'b0}}, base_addr_c_reg};
            REG_SCRATCH_SEL[ADDR_WIDTH-3:0]:
                s_axi_rdata = {{(DATA_WIDTH-2){1'b0}}, scratch_sel_reg};
            REG_SCRATCH_ADDR[ADDR_WIDTH-3:0]:
                s_axi_rdata = {{(DATA_WIDTH-SCRATCH_ADDR_WIDTH){1'b0}}, scratch_addr_reg};
            REG_SCRATCH_RDATA[ADDR_WIDTH-3:0]:
                case (scratch_sel_reg)
                    2'd0:    s_axi_rdata = ld_a_rdata;
                    2'd1:    s_axi_rdata = ld_b_rdata;
                    2'd2:    s_axi_rdata = ld_c_rdata;
                    default: s_axi_rdata = '0;
                endcase
            default:
                s_axi_rdata = '0;
        endcase
    end

endmodule
