##############################################################################
# build_rifl.tcl : build the vu47p_rifl project (top_rifl) to a bitstream.
#
# Creates the project if it does not exist yet, then runs synthesis and
# implementation through write_bitstream.  Implementation uses the
# Performance_ExplorePostRoutePhysOpt strategy: the ~390 MHz GTY user-clock
# datapath needs post-route phys-opt (together with the AXIS register slices in
# rifl_txrx_fifo) to close timing.
#
# Run from the repo root (or via `make build_rifl`):
#   vivado -mode batch -source script/build_rifl.tcl
##############################################################################

set proj_name vu47p_rifl
set proj_xpr  ${proj_name}/${proj_name}.xpr
set jobs      8

# Open the project, creating it first if needed.
if {[file exists $proj_xpr]} {
  open_project $proj_xpr
} else {
  source vu47p_rifl_project.tcl
}
# Ensure the PRBS BIST module is present.  It was added to vu47p_rifl_project.tcl
# after the .xpr was first created, so an already-existing project won't have it.
if {[llength [get_files -quiet *rifl_prbs_bist.sv]] == 0} {
  add_files -norecurse -fileset [get_filesets sources_1] [file normalize "v/rifl_prbs_bist.sv"]
  set_property file_type SystemVerilog [get_files -quiet *rifl_prbs_bist.sv]
  puts "INFO: added v/rifl_prbs_bist.sv to the existing project."
}
update_compile_order -fileset sources_1

# ---- synthesis ----
reset_run synth_1
launch_runs synth_1 -jobs $jobs
wait_on_run synth_1
if {[get_property PROGRESS [get_runs synth_1]] ne "100%"} {
  error "synth_1 failed: [get_property STATUS [get_runs synth_1]]"
}
puts "INFO: synthesis complete."

# ---- implementation -> bitstream ----
set_property strategy Performance_ExplorePostRoutePhysOpt [get_runs impl_1]
reset_run impl_1
launch_runs impl_1 -to_step write_bitstream -jobs $jobs
wait_on_run impl_1
if {[get_property PROGRESS [get_runs impl_1]] ne "100%"} {
  error "impl_1 failed: [get_property STATUS [get_runs impl_1]]"
}

set bit [glob -nocomplain ${proj_name}/${proj_name}.runs/impl_1/*.bit]
puts "INFO: build_rifl complete. Bitstream: $bit"
