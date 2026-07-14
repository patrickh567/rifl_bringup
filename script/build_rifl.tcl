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

# ---- top synthesis ----
# RIFL is de-IP'd as in-context RTL (fabric + GT + the 4 RIFL_N wrappers live in
# sources_1), so synth_1 builds it together with the top -- no separate OOC runs.
# Lever 1 (timing): enable global retiming to rebalance the 5-7 level ~390 MHz
# datapath and recover part of the source-vs-prebuilt-dcp gap.  Keep the default
# 'rebuilt' flatten so the scoped RIFL / gt_core_<QUAD> constraints still resolve
# (a full-flatten directive like PerformanceOptimized would dissolve the gt_core ref).
set_property STEPS.SYNTH_DESIGN.ARGS.RETIMING true [get_runs synth_1]
reset_run synth_1
launch_runs synth_1 -jobs $jobs
wait_on_run synth_1
if {[get_property PROGRESS [get_runs synth_1]] ne "100%"} {
  error "synth_1 failed: [get_property STATUS [get_runs synth_1]]"
}
puts "INFO: synthesis complete."

# ---- implementation -> bitstream ----
# Performance_ExplorePostRoutePhysOpt (explore place/route + post-route phys-opt).
# NOTE: AggressiveExplore/ExtraTimingOpt as the whole place+route STRATEGY was tried
# and made the ~390 MHz usr clock worse (-0.369 vs -0.215).  Instead keep the base
# Explore place/route and only strengthen the POST-ROUTE phys-opt STEP (lever 3):
# phys-opt is greedy-improving, so replication+placement here pulls the
# route-dominated ~390 MHz nets together without disturbing the good place/route.
set_property strategy Performance_ExplorePostRoutePhysOpt [get_runs impl_1]
set_property STEPS.POST_ROUTE_PHYS_OPT_DESIGN.IS_ENABLED true [get_runs impl_1]
set_property STEPS.POST_ROUTE_PHYS_OPT_DESIGN.ARGS.DIRECTIVE AggressiveExplore [get_runs impl_1]
reset_run impl_1
launch_runs impl_1 -to_step write_bitstream -jobs $jobs
wait_on_run impl_1
if {[get_property PROGRESS [get_runs impl_1]] ne "100%"} {
  error "impl_1 failed: [get_property STATUS [get_runs impl_1]]"
}

set bit [glob -nocomplain ${proj_name}/${proj_name}.runs/impl_1/*.bit]
puts "INFO: build_rifl complete. Bitstream: $bit"
