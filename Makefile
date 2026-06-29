# =============================================================================
# Self-contained VU47P RIFL bring-up image (top_rifl).
#
#   make create_rifl_project        create the vu47p_rifl Vivado project
#   make open_rifl_project          open it in the Vivado GUI
#   make generate_bitstream         run synth -> impl -> bitstream
#   make program_fpga XVC_URL=...   program the FPGA over XVC
#   make clean_rifl_project         remove the generated project
#   make clean_xci                  remove generated IP output products (keep .xci)
#
# Vivado 2019.1.3 (AR72746).  The RIFL ip_repo and the basejump_stl subset used
# here are committed in-tree -- there are no external repo or IP dependencies.
# =============================================================================

THIS_DIR   := $(realpath $(shell dirname $(realpath $(lastword $(MAKEFILE_LIST)))))
vivado_bin := $(XILINX_VIVADO)/bin/vivado
script_dir := $(THIS_DIR)/script

rifl_project_dir := $(THIS_DIR)/vu47p_rifl
rifl_project_xpr := $(rifl_project_dir)/vu47p_rifl.xpr
rifl_project_tcl := $(THIS_DIR)/vu47p_rifl_project.tcl

.PHONY: all create_rifl_project open_rifl_project generate_bitstream \
        program_fpga update_tcl clean_rifl_project clean_xci are_you_sure

all: create_rifl_project

create_rifl_project: $(rifl_project_dir)
$(rifl_project_dir): $(rifl_project_tcl)
	$(vivado_bin) -mode batch -source $(rifl_project_tcl)

open_rifl_project:
	$(vivado_bin) $(rifl_project_xpr) &

generate_bitstream:
	$(vivado_bin) -mode batch -source $(script_dir)/generate_bitstream.tcl

program_fpga:
	$(vivado_bin) -mode batch -source $(script_dir)/program_fpga.tcl -tclargs $(XVC_URL)

update_tcl:
	$(vivado_bin) -mode batch -source $(script_dir)/update_tcl.tcl

clean_rifl_project: are_you_sure
	rm -rf $(rifl_project_dir)

clean_xci:
	find xci/ -mindepth 3 -delete
	find xci/ -mindepth 2 ! -name "*.xci" -delete

DISABLE_SAFETY_PROMPT ?= false
are_you_sure:
	@$(DISABLE_SAFETY_PROMPT) || (echo -n "Are you sure [Y/n]? " && read ans && ([ "$$ans" == "Y" ] || [ "$$ans" == "y" ]))
