# AXI-Lite Matrix Multiplier Accelerator

Third project in my hardware portfolio, after the RISC-V core and the [NoC router](https://github.com/AlanGabriel-CS/noc_router_project). I scaled this one down from a systolic array to a single-core MAC-based design on purpose — the goal here is clean AXI-Lite register-interface integration, memory addressing, and control FSM design, not spatial routing across a grid. It's scoped to a solid third-year computer engineering course level and built to run entirely in simulation (Icarus/Verilator + cocotb) — no FPGA board or synthesis step.

**Status: Week 1, scaffold stage.** The register map, module boundaries, and interfaces below are settled; the actual logic inside `axi_lite_slave`, `matmul_fsm`, and the scratchpad-loading path is still TODO. See Roadmap at the bottom for where things stand day to day.

## Overview

A host writes matrix dimensions and scratchpad base addresses through an AXI-Lite register interface, sets a start bit, and the accelerator computes `C = A x B` using a single shared multiply-accumulate unit, sequenced by a control FSM that walks the row/column/inner-product loops. A done flag signals completion back through the same register interface.

## Architecture

```
        AXI-Lite (host / testbench)
               |
       axi_lite_slave
   (register map, decode, r/w channels)
               |
       +-------+-------+
       |               |
   matmul_fsm      scratchpad_ram x3
 (address gen,      (A, B, C -- dual
  row/col/k loop)    port, inferred)
       |               |
       +-------+-------+
               |
           mac_unit
   (acc <= acc + a*b, one MAC/cycle)
```

**Register map** (word-addressed, 32-bit registers):

| Offset | Name         | Fields                                                     |
|--------|--------------|-------------------------------------------------------------|
| 0x00   | CTRL_STATUS  | bit 0 START (W1P), bit 1 BUSY (RO), bit 2 DONE (RO/W1C)     |
| 0x04   | DIMS         | [7:0] N, [15:8] K, [23:16] M                                |
| 0x08   | BASE_ADDR_A  | scratchpad word offset for matrix A                          |
| 0x0C   | BASE_ADDR_B  | scratchpad word offset for matrix B                          |
| 0x10   | BASE_ADDR_C  | scratchpad word offset for matrix C                          |

`BASE_ADDR_C` extends the register map by one word beyond the original 4-register plan: two base addresses alone can't independently locate three separate scratchpads, so C gets its own rather than sharing A's or B's address space. Worth revisiting once the load path is actually built, in case a different addressing scheme (e.g. a single unified scratchpad with all three matrices packed in) turns out cleaner.

**Datapath.** `C_ij = sum_k(A_ik * B_kj)`, computed one MAC per cycle over a shared `mac_unit` rather than an array of multipliers — that's the whole point of scoping this down from a systolic array. `matmul_fsm` is responsible for clearing the accumulator at the start of each `(i, j)` pair, feeding `k` operand pairs from the A/B scratchpads in sequence, and writing the accumulated result to C once the inner loop finishes.

## Repository Structure

```
rtl/
  axi_lite_slave.sv    AXI-Lite register interface (map above)
  scratchpad_ram.sv    dual-port RAM wrapper, one instance per matrix
  mac_unit.sv           single multiply-accumulate block
  matmul_fsm.sv          control FSM: address generation + MAC sequencing
  matmul_top.sv          top-level integration

dv/
  Makefile              cocotb sim Makefile (defaults to Icarus)
  test_matmul.py         cocotb testbench, numpy.dot() as the reference model
```

## Build & Run

Requires a Verilog simulator (Icarus Verilog or Verilator) and cocotb.

```bash
pip install cocotb
cd dv
make
```

## Roadmap

- [x] Module boundaries and port lists for all five RTL blocks
- [x] Register map drafted
- [x] cocotb testbench structure (clock/reset, AXI-Lite write/read helpers, numpy reference)
- [ ] AXI-Lite slave: address decode, register file, read-data mux
- [ ] Scratchpad pre-load path (host -> AXI-Lite -> scratchpad, or a separate load mechanism)
- [ ] `matmul_fsm`: row/column/k-loop address generation, MAC sequencing, write-back
- [ ] Replace testbench placeholder assertion with a real result comparison
- [ ] Waveform debugging pass once the above is wired up end to end
