# =============================================================================
# Implementation constraints for top_rifl (VU47P RIFL bring-up).
#   - external 200 MHz refclk + four 156.25 MHz GTY refclks
#   - CDC constraints between init_clk / core_clk / per-link usr clocks
#   - GTY reference-clock pin placement (quads 131/133/135/229)
#   - per-link placement pblocks (converter + FIFO + RIFL near each quad)
# =============================================================================

# led is a slow status output
set_false_path -to [get_ports {led[*]}]

# External refclk 200 MHz
create_clock -name ext_refclk -period 5.000 [get_ports ext_refclk_p]

# CDC helper: bound cross-domain datapath delay, ignore cross-domain hold
proc set_async_constraint {clk_name_1 clk_name_2} {
  set clk_1 [get_clocks $clk_name_1]
  set clk_2 [get_clocks $clk_name_2]
  set clk_period_1 [get_property PERIOD $clk_1]
  set clk_period_2 [get_property PERIOD $clk_2]
  set min_period [expr {$clk_period_1 < $clk_period_2 ? $clk_period_1 : $clk_period_2}]
  set_max_delay  -from $clk_1 -to $clk_2 $min_period -datapath_only
  set_max_delay  -from $clk_2 -to $clk_1 $min_period -datapath_only
  set_false_path -from $clk_1 -to $clk_2 -hold
  set_false_path -from $clk_2 -to $clk_1 -hold
}

# -----------------------------------------------------------------------------
# GTY reference clocks + transceiver placement
#   RIFL_0 = X0Y28 = GTY131   RIFL_1 = X0Y36 = GTY133
#   RIFL_2 = X0Y44 = GTY135   RIFL_3 = X1Y20 = GTY229
# -----------------------------------------------------------------------------
set gty_location {X0Y28 X0Y36 X0Y44 X1Y20}
for {set i 0} {$i < [llength $gty_location]} {incr i} {
  set location [lindex $gty_location $i]
  create_clock -period 6.400 [get_ports gt_ref_i_clk_p\[$i\]]
  set_property PACKAGE_PIN [get_package_pins -of_objects [get_bels [get_sites -filter {NAME =~ *COMMON*} -of_objects [get_iobanks -of_objects [get_sites GTYE4_CHANNEL_${location}]]]/REFCLK0P]] [get_ports gt_ref_i_clk_p\[$i\]]
  set_property PACKAGE_PIN [get_package_pins -of_objects [get_bels [get_sites -filter {NAME =~ *COMMON*} -of_objects [get_iobanks -of_objects [get_sites GTYE4_CHANNEL_${location}]]]/REFCLK0N]] [get_ports gt_ref_i_clk_n\[$i\]]
}

# -----------------------------------------------------------------------------
# Clock-domain crossings.  init_clk = clk_wiz clk_out1 (100 MHz),
# core_clk = clk_wiz clk_out2 (250 MHz), usr_clk[i] = GTY txoutclk.
# -----------------------------------------------------------------------------
set init_clk_name   clk_out1_clk_wiz_0
set core_clk_name   clk_out2_clk_wiz_0
set usr_clks_0_name {txoutclk_out[1]}
set usr_clks_1_name {txoutclk_out[1]_1}
set usr_clks_2_name {txoutclk_out[1]_2}
set usr_clks_3_name {txoutclk_out[1]_3}

# INIT clock <-> CORE clock
set_async_constraint $init_clk_name $core_clk_name

# INIT clock <-> USR CLKS X clock
set_async_constraint $init_clk_name $usr_clks_0_name
set_async_constraint $init_clk_name $usr_clks_1_name
set_async_constraint $init_clk_name $usr_clks_2_name
set_async_constraint $init_clk_name $usr_clks_3_name

# CORE clock <-> USR CLKS X clock
set_async_constraint $core_clk_name $usr_clks_0_name
set_async_constraint $core_clk_name $usr_clks_1_name
set_async_constraint $core_clk_name $usr_clks_2_name
set_async_constraint $core_clk_name $usr_clks_3_name

# -----------------------------------------------------------------------------
# Per-link placement: keep each link's clock converter, TX/RX FIFO, PRBS BIST and
# RIFL core in the two clock-region rows at its GTY quad -- the quad's own row plus
# the one below it (extended down; verified to stay within the quad's SLR).  The
# BIST is a pblock member so its generator/checker place next to the RIFL core they
# drive; two rows (rather than one) give the whole per-link group room to spread.
# (delete any pre-existing pblocks first so this is safe to re-apply -- the
# constraints run at both synth and impl.)
# -----------------------------------------------------------------------------
foreach pb [get_pblocks -quiet] { delete_pblock $pb }
create_pblock pblock_rifl_0
add_cells_to_pblock [get_pblocks pblock_rifl_0] [get_cells -quiet [list \
  {u_clock_converters/cc[0].u_cc} {u_rifl_subsystem/nm[0].txrx_fifo} {u_rifl_subsystem/nm[0].prbs_bist} {u_rifl_subsystem/RIFL_inst_0}]]
resize_pblock [get_pblocks pblock_rifl_0] -add {CLOCKREGION_X0Y6:CLOCKREGION_X3Y7}

create_pblock pblock_rifl_1
add_cells_to_pblock [get_pblocks pblock_rifl_1] [get_cells -quiet [list \
  {u_clock_converters/cc[1].u_cc} {u_rifl_subsystem/nm[1].txrx_fifo} {u_rifl_subsystem/nm[1].prbs_bist} {u_rifl_subsystem/RIFL_inst_1}]]
resize_pblock [get_pblocks pblock_rifl_1] -add {CLOCKREGION_X0Y8:CLOCKREGION_X3Y9}

create_pblock pblock_rifl_2
add_cells_to_pblock [get_pblocks pblock_rifl_2] [get_cells -quiet [list \
  {u_clock_converters/cc[2].u_cc} {u_rifl_subsystem/nm[2].txrx_fifo} {u_rifl_subsystem/nm[2].prbs_bist} {u_rifl_subsystem/RIFL_inst_2}]]
resize_pblock [get_pblocks pblock_rifl_2] -add {CLOCKREGION_X0Y10:CLOCKREGION_X3Y11}

create_pblock pblock_rifl_3
add_cells_to_pblock [get_pblocks pblock_rifl_3] [get_cells -quiet [list \
  {u_clock_converters/cc[3].u_cc} {u_rifl_subsystem/nm[3].txrx_fifo} {u_rifl_subsystem/nm[3].prbs_bist} {u_rifl_subsystem/RIFL_inst_3}]]
resize_pblock [get_pblocks pblock_rifl_3] -add {CLOCKREGION_X4Y4:CLOCKREGION_X7Y5}
