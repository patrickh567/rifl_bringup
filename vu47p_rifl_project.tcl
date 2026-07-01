##############################################################################
# Create-only Vivado project for the top_rifl top level.
#
# Reuses vu47p_project.tcl as-is (the exact same RTL / IP / block-design /
# constraint source set as the top.v design), but:
#   * names the project vu47p_rifl (so it coexists with vu47p_test), and
#   * adds v/top_rifl.v and makes top_rifl the top module.
#
# This CREATES THE PROJECT ONLY. It does not launch synthesis or
# implementation (vu47p_project.tcl contains no launch_runs).
#
# Run from the repo root:
#   vivado -mode batch -source vu47p_rifl_project.tcl
##############################################################################

# vu47p_project.tcl honors ::user_project_name for the project name.
set ::user_project_name "vu47p_rifl"

# Create the project with all the same sources, IP, block designs and
# constraints as the top.v design (leaves the project open).
source vu47p_project.tcl

# top_rifl uses an XPM CDC macro (xpm_cdc_array_single) to synchronize the RIFL
# link status into the register-map (init_clk) domain; declare the XPM library.
set_property XPM_LIBRARIES {XPM_CDC} [current_project]

# Recreate the AXI-JTAG block design (design_1) and generate + add its HDL
# wrapper (design_1_wrapper), so top_rifl's instantiation resolves and the
# project is reproducible from scripts alone.
source ${origin_dir}/script/design_1_bd.tcl
generate_target all [get_files design_1.bd]
make_wrapper -files [get_files design_1.bd] -top -import

# Recreate the AXI clock converter IP (axi_clock_converter_0).  top_rifl
# instantiates one per link to cross that link's M_AXI from the init_clk domain
# (design_1) into the link's rifl_usr_clk domain (the TX FIFO + RIFL s_axis).
source ${origin_dir}/script/axi_clock_converter_0.tcl
generate_target all [get_ips axi_clock_converter_0]

# rifl_subsystem generates its clocks with a directly-instantiated clk_wiz_0 MMCM
# (raw IBUFDS + BUFG) instead of the firmware_bd block design.  Drop the now-unused
# firmware_bd BD and the legacy top.v that referenced it, then create clk_wiz_0.
catch { remove_files [get_files -quiet -filter {NAME =~ *firmware_bd.bd}] }
catch { remove_files [get_files -quiet -filter {NAME =~ *v/top.v}] }
source ${origin_dir}/script/clk_wiz_0.tcl
generate_target all [get_ips clk_wiz_0]

# Add the new top level and its supporting modules (the JTAG-AXI TX FIFOs and the
# AXI-Lite register map).  These use SystemVerilog constructs, so set their file
# type explicitly.
add_files -norecurse -fileset [get_filesets sources_1] [list \
  [file normalize "${origin_dir}/v/axi_full_to_axis_fifo.v"] \
  [file normalize "${origin_dir}/v/axis_to_axi_full_fifo.v"] \
  [file normalize "${origin_dir}/v/tkeep_pack_fifo.v"] \
  [file normalize "${origin_dir}/v/rifl_txrx_fifo.v"] \
  [file normalize "${origin_dir}/v/axi_lite_regs.v"] \
  [file normalize "${origin_dir}/v/event_capture_cdc.v"] \
  [file normalize "${origin_dir}/v/axi_jtag_master.v"] \
  [file normalize "${origin_dir}/v/rifl_axi_clock_converters.v"] \
  [file normalize "${origin_dir}/v/rifl_prbs_bist.sv"] \
  [file normalize "${origin_dir}/v/rifl_subsystem.v"] \
  [file normalize "${origin_dir}/v/top_rifl.v"] ]
set_property -name "file_type" -value "SystemVerilog" -objects \
  [get_files -of_objects [get_filesets sources_1] [list \
     "*v/axi_full_to_axis_fifo.v" "*v/axis_to_axi_full_fifo.v" "*v/tkeep_pack_fifo.v" "*v/rifl_txrx_fifo.v" \
     "*v/axi_lite_regs.v" "*v/event_capture_cdc.v" "*v/axi_jtag_master.v" \
     "*v/rifl_axi_clock_converters.v" "*v/rifl_prbs_bist.sv" "*v/rifl_subsystem.v" "*v/top_rifl.v"]]

set_property top top_rifl [get_filesets sources_1]
set_property top top_rifl [get_filesets sim_1]

puts "INFO: Project 'vu47p_rifl' created with top = top_rifl (not built)."
