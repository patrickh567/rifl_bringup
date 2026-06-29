
# False paths
set_false_path -from [get_ports rstn]
set_false_path -to [get_ports led[*]]

# External refclk 200 MHZ
create_clock -name ext_refclk -period 5 [get_ports ext_refclk_p]



# define async constraints
proc set_async_constraint {clk_name_1 clk_name_2} {
  set clk_1 [get_clocks $clk_name_1]
  set clk_2 [get_clocks $clk_name_2]
  set clk_period_1 [get_property PERIOD $clk_1]
  set clk_period_2 [get_property PERIOD $clk_2]
  set min_period [expr $clk_period_1 < $clk_period_2 ? $clk_period_1 : $clk_period_2]
  set_max_delay  -from $clk_1 -to $clk_2 $min_period -datapath_only
  set_max_delay  -from $clk_2 -to $clk_1 $min_period -datapath_only
  set_false_path -from $clk_1 -to $clk_2 -hold
  set_false_path -from $clk_2 -to $clk_1 -hold
}


# RIFL_0 = X0Y28 = GTY131
# RIFL_1 = X0Y36 = GTY133
# RIFL_2 = X0Y44 = GTY135
# RIFL_3 = X1Y20 = GTY229
set gty_location {X0Y28 X0Y36 X0Y44 X1Y20}
set num_gty [llength $gty_location]
for {set i 0} {$i < $num_gty} {incr i} {
  set location [lindex $gty_location $i]
  create_clock -period 6.400 [get_ports gt_ref_i_clk_p[$i]]
  set_property PACKAGE_PIN [get_package_pins -of_objects [get_bels [get_sites -filter {NAME =~ *COMMON*} -of_objects [get_iobanks -of_objects [get_sites GTYE4_CHANNEL_${location}]]]/REFCLK0P]] [get_ports gt_ref_i_clk_p[$i]]
  set_property PACKAGE_PIN [get_package_pins -of_objects [get_bels [get_sites -filter {NAME =~ *COMMON*} -of_objects [get_iobanks -of_objects [get_sites GTYE4_CHANNEL_${location}]]]/REFCLK0N]] [get_ports gt_ref_i_clk_n[$i]]
}



set init_clk_name     clk_out1_firmware_bd_clk_wiz_0_0
set core_clk_name     clk_out2_firmware_bd_clk_wiz_0_0
set usr_clks_0_name   txoutclk_out[1]
set usr_clks_1_name   txoutclk_out[1]_1
set usr_clks_2_name   txoutclk_out[1]_2
set usr_clks_3_name   txoutclk_out[1]_3

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



# RIFL_0
create_pblock                    pblock_rifl_0
add_cells_to_pblock [get_pblocks pblock_rifl_0] [get_cells -quiet [list \
  nm[0].converter \
  nm[0].rifl_axis_bist_inst \
  RIFL_inst_0 ]]
resize_pblock       [get_pblocks pblock_rifl_0] -add {CLOCKREGION_X0Y7:CLOCKREGION_X3Y7}

# RIFL_1
create_pblock                    pblock_rifl_1
add_cells_to_pblock [get_pblocks pblock_rifl_1] [get_cells -quiet [list \
  nm[1].converter \
  nm[1].rifl_axis_bist_inst \
  RIFL_inst_1 ]]
resize_pblock       [get_pblocks pblock_rifl_1] -add {CLOCKREGION_X0Y9:CLOCKREGION_X3Y9}

# RIFL_2
create_pblock                    pblock_rifl_2
add_cells_to_pblock [get_pblocks pblock_rifl_2] [get_cells -quiet [list \
  nm[2].converter \
  nm[2].rifl_axis_bist_inst \
  RIFL_inst_2 ]]
resize_pblock       [get_pblocks pblock_rifl_2] -add {CLOCKREGION_X0Y11:CLOCKREGION_X3Y11}

# RIFL_3
create_pblock                    pblock_rifl_3
add_cells_to_pblock [get_pblocks pblock_rifl_3] [get_cells -quiet [list \
  nm[3].converter \
  nm[3].rifl_axis_bist_inst \
  RIFL_inst_3 ]]
resize_pblock       [get_pblocks pblock_rifl_3] -add {CLOCKREGION_X4Y5:CLOCKREGION_X7Y5}
