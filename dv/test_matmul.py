"""
test_matmul.py

cocotb testbench for matmul_top. Drives the AXI-Lite register interface,
pre-loads operand matrices, triggers the computation, and checks the
result scratchpad against a numpy reference.

Not yet functional: axi_lite_slave, matmul_fsm, and mac_unit are all
Week 1 stubs with no real logic (see the TODOs in rtl/). The helpers and
test structure below are the intended shape of verification once the
RTL is implemented, not a passing test yet.
"""

import numpy as np

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge, ClockCycles

CTRL_STATUS = 0x00
DIMS        = 0x04
BASE_ADDR_A = 0x08
BASE_ADDR_B = 0x0C
BASE_ADDR_C = 0x10

CTRL_START_BIT = 0
STATUS_BUSY_BIT = 1
STATUS_DONE_BIT = 2


async def reset_dut(dut):
    dut.rst_n.value = 0
    await ClockCycles(dut.clk, 5)
    dut.rst_n.value = 1
    await RisingEdge(dut.clk)


async def axi_lite_write(dut, addr, data):
    # TODO: real handshake once axi_lite_slave implements awready/wready.
    dut.s_axi_awaddr.value = addr
    dut.s_axi_awvalid.value = 1
    dut.s_axi_wdata.value = data
    dut.s_axi_wstrb.value = 0xF
    dut.s_axi_wvalid.value = 1
    await RisingEdge(dut.clk)
    dut.s_axi_awvalid.value = 0
    dut.s_axi_wvalid.value = 0


async def axi_lite_read(dut, addr):
    # TODO: real handshake once axi_lite_slave implements arready/rvalid.
    dut.s_axi_araddr.value = addr
    dut.s_axi_arvalid.value = 1
    await RisingEdge(dut.clk)
    dut.s_axi_arvalid.value = 0
    return dut.s_axi_rdata.value


def pack_dims(n, k, m):
    return (n & 0xFF) | ((k & 0xFF) << 8) | ((m & 0xFF) << 16)


@cocotb.test()
async def test_matmul_basic(dut):
    """Multiply two small random matrices and check against numpy.dot()."""
    cocotb.start_soon(Clock(dut.clk, 10, units="ns").start())
    await reset_dut(dut)

    n, k, m = 4, 4, 4
    rng = np.random.default_rng(seed=0)
    a = rng.integers(0, 16, size=(n, k), dtype=np.int32)
    b = rng.integers(0, 16, size=(k, m), dtype=np.int32)
    expected = np.dot(a, b)

    # TODO: pre-load `a` and `b` into the scratchpads via whatever load
    # path axi_lite_slave ends up exposing (direct hierarchical poke of
    # u_scratchpad_a/b.mem[] is a reasonable stand-in until then).

    await axi_lite_write(dut, DIMS, pack_dims(n, k, m))
    await axi_lite_write(dut, BASE_ADDR_A, 0)
    await axi_lite_write(dut, BASE_ADDR_B, 0)
    await axi_lite_write(dut, BASE_ADDR_C, 0)
    await axi_lite_write(dut, CTRL_STATUS, 1 << CTRL_START_BIT)

    # TODO: poll status_done (via CTRL_STATUS read) instead of a fixed
    # cycle count, once the FSM actually asserts it.
    await ClockCycles(dut.clk, 200)

    # TODO: read back the C scratchpad and compare against `expected`.
    assert True, "placeholder -- no real check until the datapath exists"
