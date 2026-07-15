//============================================================================
// VCS file list -- in-tree RTL for the rifl_subsystem testbench.
//
//   Consumed by vlogan/vcs:   vlogan ... -f filelist.f
//   $RIFL_ROOT is exported by compile.sh (defaults to the repo root).
//
// Covers the in-repo RTL: the de-IP'd RIFL fabric + GT transceivers (rtl/),
// the rifl_subsystem local hierarchy, the BaseJump STL subset, and the TB.
// clk_wiz_0 (the only remaining Vivado IP) + the Xilinx sim libraries are
// produced by gen_ip_and_simlib.tcl (ip_sim_vlog.f + the compiled simlib)
// and stitched in by compile.sh.  See README.md.
//============================================================================

// ---- defines -------------------------------------------------------------
// SIMULATION drops the synthesis/hardware-only AXIS debug ILA in rifl_subsystem.
+define+SIMULATION
// SIM_SPEED_UP shrinks the RIFL rx_up debounce (rx_aligner.sv) 2^20 -> 2^12 so a
// link reaches rx_up within ~tens of us of sim.  Required for bring-up.
+define+SIM_SPEED_UP

// ---- include dirs --------------------------------------------------------
+incdir+$RIFL_ROOT/basejump_stl_bigblade/bsg_misc

// ---- hardened primitive overrides ----------------------------------------
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

// ---- de-IP'd RIFL fabric + GT transceivers (rtl/) ------------------------
// The 4 RIFL cores + gtwizard/GTYE4 transceivers, formerly Vivado-generated
// IP (RIFL_0..3.xci), are now in-context RTL under rtl/ (commit 1292f74).
// Listed explicitly (NOT -y): several files have module name != file name --
// the gtwizard primitives carry a per-core hash (bit_sync.v defines module
// gtwizard_ultrascale_v1_7_72746_bit_synchronizer), and sync_single_bit.sv
// defines module sync_signle_bit (sic) -- neither resolvable by -y.  No
// packages/includes in rtl/, so file order is free; GTYE4 primitives still
// come from the compiled Xilinx unisim/secureip simlib.
+libext+.v+.sv
$RIFL_ROOT/rtl/cdc/sync_multi_bit.sv
$RIFL_ROOT/rtl/cdc/sync_reset.sv
$RIFL_ROOT/rtl/cdc/sync_single_bit.sv
$RIFL_ROOT/rtl/easy_fifo/async_fifo/async_fifo.sv
$RIFL_ROOT/rtl/easy_fifo/async_fifo/async_rd_ctrl.sv
$RIFL_ROOT/rtl/easy_fifo/async_fifo/async_wr_ctrl.sv
$RIFL_ROOT/rtl/easy_fifo/async_fifo/graycode_util.sv
$RIFL_ROOT/rtl/easy_fifo/async_fifo/simple_dp_ram.sv
$RIFL_ROOT/rtl/easy_fifo/sync_fifo/rifl_sync_fifo.sv
$RIFL_ROOT/rtl/easy_fifo/top/rifl_axis_async_fifo.sv
$RIFL_ROOT/rtl/easy_fifo/top/rifl_axis_sync_fifo.sv
$RIFL_ROOT/rtl/easy_fifo/top/rst_cntrl.sv
$RIFL_ROOT/rtl/gt/gt_core_X0Y28_gtwizard_gtye4.v
$RIFL_ROOT/rtl/gt/gt_core_X0Y28_gtwizard_top.v
$RIFL_ROOT/rtl/gt/gt_core_X0Y28_gtye4_channel_wrapper.v
$RIFL_ROOT/rtl/gt/gt_core_X0Y28_gtye4_common_wrapper.v
$RIFL_ROOT/rtl/gt/gt_core_X0Y28.v
$RIFL_ROOT/rtl/gt/gt_core_X0Y36_gtwizard_gtye4.v
$RIFL_ROOT/rtl/gt/gt_core_X0Y36_gtwizard_top.v
$RIFL_ROOT/rtl/gt/gt_core_X0Y36_gtye4_channel_wrapper.v
$RIFL_ROOT/rtl/gt/gt_core_X0Y36_gtye4_common_wrapper.v
$RIFL_ROOT/rtl/gt/gt_core_X0Y36.v
$RIFL_ROOT/rtl/gt/gt_core_X0Y44_gtwizard_gtye4.v
$RIFL_ROOT/rtl/gt/gt_core_X0Y44_gtwizard_top.v
$RIFL_ROOT/rtl/gt/gt_core_X0Y44_gtye4_channel_wrapper.v
$RIFL_ROOT/rtl/gt/gt_core_X0Y44_gtye4_common_wrapper.v
$RIFL_ROOT/rtl/gt/gt_core_X0Y44.v
$RIFL_ROOT/rtl/gt/gt_core_X1Y20_gtwizard_gtye4.v
$RIFL_ROOT/rtl/gt/gt_core_X1Y20_gtwizard_top.v
$RIFL_ROOT/rtl/gt/gt_core_X1Y20_gtye4_channel_wrapper.v
$RIFL_ROOT/rtl/gt/gt_core_X1Y20_gtye4_common_wrapper.v
$RIFL_ROOT/rtl/gt/gt_core_X1Y20.v
$RIFL_ROOT/rtl/gt/gtwizard_ultrascale_v1_7_bit_sync.v
$RIFL_ROOT/rtl/gt/gtwizard_ultrascale_v1_7_gte4_drp_arb.v
$RIFL_ROOT/rtl/gt/gtwizard_ultrascale_v1_7_gthe3_cal_freqcnt.v
$RIFL_ROOT/rtl/gt/gtwizard_ultrascale_v1_7_gthe3_cpll_cal.v
$RIFL_ROOT/rtl/gt/gtwizard_ultrascale_v1_7_gthe4_cal_freqcnt.v
$RIFL_ROOT/rtl/gt/gtwizard_ultrascale_v1_7_gthe4_cpll_cal_rx.v
$RIFL_ROOT/rtl/gt/gtwizard_ultrascale_v1_7_gthe4_cpll_cal_tx.v
$RIFL_ROOT/rtl/gt/gtwizard_ultrascale_v1_7_gthe4_cpll_cal.v
$RIFL_ROOT/rtl/gt/gtwizard_ultrascale_v1_7_gthe4_delay_powergood.v
$RIFL_ROOT/rtl/gt/gtwizard_ultrascale_v1_7_gtwiz_buffbypass_rx.v
$RIFL_ROOT/rtl/gt/gtwizard_ultrascale_v1_7_gtwiz_buffbypass_tx.v
$RIFL_ROOT/rtl/gt/gtwizard_ultrascale_v1_7_gtwiz_reset.v
$RIFL_ROOT/rtl/gt/gtwizard_ultrascale_v1_7_gtwiz_userclk_rx.v
$RIFL_ROOT/rtl/gt/gtwizard_ultrascale_v1_7_gtwiz_userclk_tx.v
$RIFL_ROOT/rtl/gt/gtwizard_ultrascale_v1_7_gtwiz_userdata_rx.v
$RIFL_ROOT/rtl/gt/gtwizard_ultrascale_v1_7_gtwiz_userdata_tx.v
$RIFL_ROOT/rtl/gt/gtwizard_ultrascale_v1_7_gtye4_cal_freqcnt.v
$RIFL_ROOT/rtl/gt/gtwizard_ultrascale_v1_7_gtye4_channel.v
$RIFL_ROOT/rtl/gt/gtwizard_ultrascale_v1_7_gtye4_common.v
$RIFL_ROOT/rtl/gt/gtwizard_ultrascale_v1_7_gtye4_cpll_cal_rx.v
$RIFL_ROOT/rtl/gt/gtwizard_ultrascale_v1_7_gtye4_cpll_cal_tx.v
$RIFL_ROOT/rtl/gt/gtwizard_ultrascale_v1_7_gtye4_cpll_cal.v
$RIFL_ROOT/rtl/gt/gtwizard_ultrascale_v1_7_gtye4_delay_powergood.v
$RIFL_ROOT/rtl/gt/gtwizard_ultrascale_v1_7_reset_inv_sync.v
$RIFL_ROOT/rtl/gt/gtwizard_ultrascale_v1_7_reset_sync.v
$RIFL_ROOT/rtl/rifl/channel_bounding/spatial/rx_spatial_cb.sv
$RIFL_ROOT/rtl/rifl/channel_bounding/spatial/tx_spatial_cb.sv
$RIFL_ROOT/rtl/rifl/channel_bounding/temporal/fast2slow_buffer.sv
$RIFL_ROOT/rtl/rifl/channel_bounding/temporal/rx_temporal_cb.sv
$RIFL_ROOT/rtl/rifl/channel_bounding/temporal/slow2fast_buffer.sv
$RIFL_ROOT/rtl/rifl/channel_bounding/temporal/tx_temporal_cb.sv
$RIFL_ROOT/rtl/rifl/common/rifl_scramble_cntrl.sv
$RIFL_ROOT/rtl/rifl/common/scrambler.sv
$RIFL_ROOT/rtl/rifl/error_injection/rifl_err_inj.sv
$RIFL_ROOT/rtl/rifl/error_injection/rifl_xoshiro128ss.sv
$RIFL_ROOT/rtl/rifl/gt_wrapper/datapath_reset.sv
$RIFL_ROOT/rtl/rifl/gt_wrapper/gt_cdc.sv
$RIFL_ROOT/rtl/rifl/gt_wrapper/rifl_gt_wrapper.sv
$RIFL_ROOT/rtl/rifl/rx/remote_fc_detector.sv
$RIFL_ROOT/rtl/rifl/rx/rifl_rx.sv
$RIFL_ROOT/rtl/rifl/rx/rx_aligner.sv
$RIFL_ROOT/rtl/rifl/rx/rx_cdc.sv
$RIFL_ROOT/rtl/rifl/rx/rx_controller.sv
$RIFL_ROOT/rtl/rifl/rx/rx_dwidth_conv.sv
$RIFL_ROOT/rtl/rifl/rx/vcode_val.sv
$RIFL_ROOT/rtl/rifl/top/compensate_cntrl.sv
$RIFL_ROOT/rtl/rifl/top/rifl_core.sv
$RIFL_ROOT/rtl/rifl/top/rifl_rst_gen.sv
$RIFL_ROOT/rtl/rifl/top/RIFL.sv
$RIFL_ROOT/rtl/rifl/tx/rifl_encode.sv
$RIFL_ROOT/rtl/rifl/tx/rifl_tx.sv
$RIFL_ROOT/rtl/rifl/tx/tx_controller.sv
$RIFL_ROOT/rtl/rifl/tx/tx_dwidth_conv.sv
$RIFL_ROOT/rtl/rifl/tx/vcode_gen.sv
$RIFL_ROOT/rtl/utils/clock_buffer.sv
$RIFL_ROOT/rtl/utils/clock_counter.sv
$RIFL_ROOT/rtl/utils/rx_axis_conv.sv
$RIFL_ROOT/rtl/utils/tx_axis_conv.sv
$RIFL_ROOT/rtl/wrap/RIFL_0.v
$RIFL_ROOT/rtl/wrap/RIFL_1.v
$RIFL_ROOT/rtl/wrap/RIFL_2.v
$RIFL_ROOT/rtl/wrap/RIFL_3.v

// ---- BaseJump STL: auto-resolve referenced modules by file name ----------
// (file name == module name; only referenced modules are pulled in)
-y $RIFL_ROOT/basejump_stl_bigblade/bsg_misc
-y $RIFL_ROOT/basejump_stl_bigblade/bsg_mem
-y $RIFL_ROOT/basejump_stl_bigblade/bsg_dataflow
-y $RIFL_ROOT/basejump_stl_bigblade/bsg_async
+libext+.v+.sv

// ---- testbench -----------------------------------------------------------
$RIFL_ROOT/tb/tb_rifl_subsystem.sv
