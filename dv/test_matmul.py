"""
test_matmul.py

cocotb testbench for matmul_top. Drives the AXI-Lite register interface,
pre-loads operand matrices through the SCRATCH_SEL/ADDR/WDATA load path,
triggers the computation, polls for completion, reads the result
scratchpad back through SCRATCH_RDATA, and checks it against numpy.dot().

s_axi_bready and s_axi_rready are tied high for the whole test -- this
DUT is a single-outstanding-transaction slave (see axi_lite_slave.sv), so
every helper below only ever starts a new transaction once the previous
one's response has fully cleared, which keeps the handshake trivial: no
retry loop needed, awready/wready/arready are guaranteed asserted the
cycle each helper asserts *valid.
"""

import numpy as np

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge, ClockCycles

CTRL_STATUS   = 0x00
DIMS          = 0x04
BASE_ADDR_A   = 0x08
BASE_ADDR_B   = 0x0C
BASE_ADDR_C   = 0x10
SCRATCH_SEL   = 0x14
SCRATCH_ADDR  = 0x18
SCRATCH_WDATA = 0x1C
SCRATCH_RDATA = 0x20

CTRL_START_BIT  = 0
STATUS_BUSY_BIT = 1
STATUS_DONE_BIT = 2

SCRATCH_A, SCRATCH_B, SCRATCH_C = 0, 1, 2


def to_signed32(value):
    """SCRATCH_RDATA/registers come back as raw unsigned 32-bit words;
    matrix elements are two's-complement and can be negative."""
    value &= 0xFFFFFFFF
    return value - 0x1_0000_0000 if value & 0x8000_0000 else value


async def reset_dut(dut):
    dut.s_axi_awvalid.value = 0
    dut.s_axi_wvalid.value  = 0
    dut.s_axi_arvalid.value = 0
    dut.s_axi_bready.value  = 1  # tied high -- see module docstring
    dut.s_axi_rready.value  = 1
    dut.rst_n.value = 0
    await ClockCycles(dut.clk, 5)
    dut.rst_n.value = 1
    await RisingEdge(dut.clk)


async def axi_lite_write(dut, addr, data, strb=0xF):
    """Single-cycle AW/W pulse. Relies on the caller never overlapping
    this with another outstanding write (awready is guaranteed high,
    since bvalid is guaranteed low -- see module docstring)."""
    dut.s_axi_awaddr.value = addr
    dut.s_axi_awvalid.value = 1
    dut.s_axi_wdata.value = data & 0xFFFFFFFF
    dut.s_axi_wstrb.value = strb
    dut.s_axi_wvalid.value = 1
    await RisingEdge(dut.clk)  # write accepted (awready/wready high)
    dut.s_axi_awvalid.value = 0
    dut.s_axi_wvalid.value = 0
    await RisingEdge(dut.clk)  # bvalid asserts, then clears (bready tied high)


async def axi_lite_read(dut, addr):
    dut.s_axi_araddr.value = addr
    dut.s_axi_arvalid.value = 1
    await RisingEdge(dut.clk)  # read address accepted (arready high)
    dut.s_axi_arvalid.value = 0
    # Normal registers return data next cycle; SCRATCH_RDATA takes one
    # extra cycle (goes through the scratchpad's own synchronous read).
    while not dut.s_axi_rvalid.value:
        await RisingEdge(dut.clk)
    data = int(dut.s_axi_rdata.value)
    await RisingEdge(dut.clk)  # rvalid clears (rready tied high)
    return data


def pack_dims(n, k, m):
    return (n & 0xFF) | ((k & 0xFF) << 8) | ((m & 0xFF) << 16)


async def load_matrix(dut, sel, base, matrix):
    """Stream a row-major-flattened matrix into scratchpad `sel`, starting
    at word address `base`, via SCRATCH_SEL + SCRATCH_ADDR + SCRATCH_WDATA
    (SCRATCH_ADDR auto-increments after each SCRATCH_WDATA write)."""
    await axi_lite_write(dut, SCRATCH_SEL, sel)
    await axi_lite_write(dut, SCRATCH_ADDR, base)
    for value in matrix.flatten():
        await axi_lite_write(dut, SCRATCH_WDATA, int(value))


async def read_matrix(dut, sel, base, rows, cols):
    """Inverse of load_matrix, via SCRATCH_RDATA. Values are interpreted
    as signed two's-complement (see to_signed32)."""
    await axi_lite_write(dut, SCRATCH_SEL, sel)
    await axi_lite_write(dut, SCRATCH_ADDR, base)
    values = [to_signed32(await axi_lite_read(dut, SCRATCH_RDATA)) for _ in range(rows * cols)]
    return np.array(values, dtype=np.int64).reshape(rows, cols)


async def wait_done(dut, max_polls=2000):
    for _ in range(max_polls):
        status = await axi_lite_read(dut, CTRL_STATUS)
        if status & (1 << STATUS_DONE_BIT):
            return
    raise TimeoutError(f"matmul_fsm never asserted DONE within {max_polls} polls")


async def run_matmul_case(dut, n, k, m, low, high, seed):
    """Load two random n*k / k*m matrices (values in [low, high)), run the
    accelerator, and assert the C readback matches numpy.dot() exactly."""
    cocotb.start_soon(Clock(dut.clk, 10, unit="ns").start())
    await reset_dut(dut)

    rng = np.random.default_rng(seed=seed)
    a = rng.integers(low, high, size=(n, k), dtype=np.int64)
    b = rng.integers(low, high, size=(k, m), dtype=np.int64)
    expected = np.dot(a, b)

    base_a, base_b, base_c = 0, n * k, n * k + k * m

    await load_matrix(dut, SCRATCH_A, base_a, a)
    await load_matrix(dut, SCRATCH_B, base_b, b)

    await axi_lite_write(dut, DIMS, pack_dims(n, k, m))
    await axi_lite_write(dut, BASE_ADDR_A, base_a)
    await axi_lite_write(dut, BASE_ADDR_B, base_b)
    await axi_lite_write(dut, BASE_ADDR_C, base_c)
    await axi_lite_write(dut, CTRL_STATUS, 1 << CTRL_START_BIT)

    await wait_done(dut)

    result = await read_matrix(dut, SCRATCH_C, base_c, n, m)

    assert (result == expected).all(), (
        f"matmul result mismatch (n={n} k={k} m={m}):\n"
        f"RTL:\n{result}\nexpected (numpy):\n{expected}"
    )


@cocotb.test()
async def test_matmul_basic(dut):
    """4x4x4, small non-negative values -- the baseline happy path."""
    await run_matmul_case(dut, n=4, k=4, m=4, low=0, high=16, seed=0)


@cocotb.test()
async def test_matmul_non_square(dut):
    """N != K != M (3x5x2), to exercise row/col address generation beyond
    the trivial symmetric case."""
    await run_matmul_case(dut, n=3, k=5, m=2, low=0, high=16, seed=1)


@cocotb.test()
async def test_matmul_negative_values(dut):
    """Negative operands -- mac_unit must sign-extend a/b into the 64-bit
    accumulator, not zero-extend, or this silently corrupts every product
    with a negative operand."""
    await run_matmul_case(dut, n=4, k=4, m=4, low=-8, high=8, seed=2)


@cocotb.test()
async def test_matmul_k_equals_one(dut):
    """K=1: the inner dot-product loop's FETCH/ACCUM pair must run exactly
    once and fall straight through to WRITEBACK, not loop or skip."""
    await run_matmul_case(dut, n=3, k=1, m=3, low=-8, high=8, seed=3)


@cocotb.test()
async def test_matmul_near_scratchpad_depth(dut):
    """9x9x9 uses 243 of the scratchpad's 256 words (81 + 81 + 81, C's
    base at 162) -- close to SCRATCH_ADDR_WIDTH's depth limit without
    overflowing it, to catch any off-by-one in the address math that only
    shows up once addresses actually get large."""
    await run_matmul_case(dut, n=9, k=9, m=9, low=0, high=8, seed=4)
