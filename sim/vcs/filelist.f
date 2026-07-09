//============================================================================
// VCS file list -- in-tree RTL for the rifl_subsystem testbench.
//
//   Consumed by vlogan/vcs:   vlogan ... -f filelist.f
//   $RIFL_ROOT is exported by compile.sh (defaults to the repo root).
//
// This list covers ONLY the in-repo RTL: the rifl_subsystem local hierarchy,
// the BaseJump STL subset it pulls in, and the testbench.  The Vivado-generated
// IP simulation sources (clk_wiz_0 MMCM + RIFL_0..3 gtwizard/GTYE4) and the
// Xilinx simulation libraries are NOT here -- they are produced by
// gen_ip_and_simlib.tcl into ip_sim_vlog.f / ip_sim_vhdl.f and the compiled
// simlib, and stitched in by compile.sh.  See README.md.
//============================================================================

// ---- defines -------------------------------------------------------------
// SIMULATION drops the synthesis/hardware-only AXIS debug ILA in rifl_subsystem.
+define+SIMULATION
// SIM_SPEED_UP shrinks the RIFL rx_up debounce (rx_aligner.sv rx_up_detector)
// from 2^20 to 2^12 cycles, so a RIFL link reaches rx_up within ~tens of us of
// sim instead of ~ms of link time (hours of wall-clock).  Required for the link
// to come up in any practical simulation.
+define+SIM_SPEED_UP

// ---- include dirs --------------------------------------------------------
// bsg_defines.v (BSG macros) is `include`d by the BSG + local sources.
+incdir+$RIFL_ROOT/basejump_stl_bigblade/bsg_misc

// ---- hardened primitive overrides ----------------------------------------
// These shadow the bsg_async versions of the same modules; listing them
// explicitly makes their definitions win over the -y search below (-y only
// auto-loads modules that are still undefined).
$RIFL_ROOT/v/hard/bsg_sync_sync.v
$RIFL_ROOT/v/hard/bsg_launch_sync_sync.v
$RIFL_ROOT/v/hard/bsg_async_fifo.v

// ---- local RTL: rifl_subsystem hierarchy ---------------------------------
$RIFL_ROOT/v/bsg_reset_chain.v
$RIFL_ROOT/v/bsg_reset_module.sv
$RIFL_ROOT/v/bsg_fifo_1r1w_small_hardened.v
$RIFL_ROOT/v/event_capture_cdc.v
$RIFL_ROOT/v/axi_lite_regs.v
$RIFL_ROOT/v/tkeep_pack_fifo.v
$RIFL_ROOT/v/axi_full_to_axis_fifo.v
$RIFL_ROOT/v/axis_to_axi_full_fifo.v
$RIFL_ROOT/v/rifl_txrx_fifo.v
$RIFL_ROOT/v/rifl_prbs_bist.sv
$RIFL_ROOT/v/rifl_subsystem.v

// ---- BaseJump STL: auto-resolve referenced modules by file name ----------
// (file name == module name; only referenced modules are pulled in)
-y $RIFL_ROOT/basejump_stl_bigblade/bsg_misc
-y $RIFL_ROOT/basejump_stl_bigblade/bsg_mem
-y $RIFL_ROOT/basejump_stl_bigblade/bsg_dataflow
-y $RIFL_ROOT/basejump_stl_bigblade/bsg_async
+libext+.v+.sv

// ---- testbench -----------------------------------------------------------
$RIFL_ROOT/tb/tb_rifl_subsystem.sv
