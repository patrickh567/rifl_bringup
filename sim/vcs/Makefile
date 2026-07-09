# =============================================================================
# VCS compile/run flow for tb_rifl_subsystem.  See README.md for details.
#
#   make ip        compile_simlib + generate IP sim sources (needs Vivado)   [once]
#   make compile   analyze + elaborate the testbench -> ./simv               (VCS)
#   make run       run ./simv and print PASS/FAIL
#   make waves     run ./simv with a full waveform dump (waves.vpd)
#   make all       compile + run
#   make clean     remove build products (keep the compiled simlib)
#   make cleanall  also remove the compiled simlib and generated IP lists
#
# Override paths on the command line, e.g.:
#   make ip SIMLIB_DIR=/tools/xilinx/vcs_simlib_2019.1
# =============================================================================

RIFL_ROOT   ?= $(abspath $(CURDIR)/../..)
SIMLIB_DIR  ?= $(CURDIR)/xil_simlib
PROJECT_XPR ?= $(RIFL_ROOT)/vu47p_rifl/vu47p_rifl.xpr
VIVADO      ?= vivado
WORKLIB     ?= xil_defaultlib

export RIFL_ROOT SIMLIB_DIR PROJECT_XPR WORKLIB

.PHONY: all ip simlib compile run waves clean cleanall help

all: compile run

## ip: compile_simlib + generate IP simulation sources + emit ip_sim_*.f
ip:
	$(VIVADO) -mode batch -notrace -source gen_ip_and_simlib.tcl
simlib: ip

## compile: analyze + elaborate -> ./simv
compile:
	./compile.sh

## run: run ./simv
run:
	./run.sh

## waves: run ./simv and dump waves.vpd
waves:
	WAVES=1 ./run.sh

clean:
	rm -rf $(WORKLIB) AN.DB csrc simv simv.daidir 64 \
	       *.log ucli.key vc_hdrs.h .dump.ucli synopsys_sim.setup waves.vpd novas.* verdiLog

cleanall: clean
	rm -rf $(SIMLIB_DIR) ip_gen ip_sim_vlog.f ip_sim_vhdl.f

help:
	@grep -E '^## ' $(MAKEFILE_LIST) | sed 's/^## /  /'
