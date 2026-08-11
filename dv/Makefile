# cocotb simulation Makefile. Requires: pip install cocotb, plus a
# Verilog simulator on PATH (icarus by default; verilator also works).

SIM ?= icarus
TOPLEVEL_LANG ?= verilog
TOPLEVEL = matmul_top
MODULE = test_matmul

VERILOG_SOURCES += $(shell pwd)/../rtl/scratchpad_ram.sv
VERILOG_SOURCES += $(shell pwd)/../rtl/mac_unit.sv
VERILOG_SOURCES += $(shell pwd)/../rtl/axi_lite_slave.sv
VERILOG_SOURCES += $(shell pwd)/../rtl/matmul_fsm.sv
VERILOG_SOURCES += $(shell pwd)/../rtl/matmul_top.sv

include $(shell cocotb-config --makefiles)/Makefile.sim
