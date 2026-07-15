set init_clk_src [get_ports init_clk]
set tx_frame_clk_src [get_pins -hier -filter {NAME =~ */u_tx_clock_buffer/bufg_inst3/O}]
set tx_frame_clk [get_clocks -quiet -of $tx_frame_clk_src]
set tx_gt_clk_src [get_pins -hier -filter {NAME =~ */u_tx_clock_buffer/bufg_inst2/O}]
set tx_gt_clk [get_clocks -quiet -of $tx_gt_clk_src]
set rx_gt_clk_src [get_pins -hier -filter {NAME =~ */u_rx_clock_buffer/bufg_inst2/O}]
set rx_gt_clk [get_clocks -quiet -of $rx_gt_clk_src]

set usr_clk_src [get_pins -hier -filter {NAME =~ *usr_clk_bufg/O}]
set usr_clk [get_clocks -quiet -of $usr_clk_src]

set frame_period [get_property -quiet -min PERIOD $tx_frame_clk]
set gt_period [get_property -quiet -min PERIOD $tx_gt_clk]
set_false_path -through [get_ports rst] -quiet
set_false_path -through [get_ports gt_rst] -quiet
set_false_path -to [get_cells -hier d_meta_reg[0][*]] -quiet
set_false_path -to [get_cells -hier rst_meta_reg[*]] -quiet
set_false_path -from [get_pins -hier -filter {NAME =~ *u_sync_tx_frame/rst_meta_reg[3]/C}] -quiet
set_false_path -from [get_pins -hier -filter {NAME =~ *u_sync_rx_frame/rst_meta_reg[3]/C}] -quiet
set_false_path -from [get_pins -hier -filter {NAME =~ *u_tx_clock_buffer/usrclk_active_sync_reg/C}] -quiet
set_false_path -from [get_pins -hier -filter {NAME =~ *u_rx_clock_buffer/usrclk_active_sync_reg/C}] -quiet
set_false_path -from [get_pins -hier tx_poweron_rst_reg/C] -quiet

set_max_delay -from [filter [all_fanout -from $rx_gt_clk_src -flat -endpoints_only] {IS_LEAF}] -through [get_pins -of_obj [get_cells -hier * -filter {NAME=~*u_simple_dp_ram/mem_int_reg*}] -filter {DIRECTION==OUT}] $gt_period -datapath_only

set_multicycle_path -quiet -setup -start 4 -from $tx_gt_clk -to $tx_frame_clk
set_multicycle_path -quiet -hold -start 3 -from $tx_gt_clk -to $tx_frame_clk
set_multicycle_path -quiet -setup -end 4 -from $tx_frame_clk -to $tx_gt_clk
set_multicycle_path -quiet -hold -end 3 -from $tx_frame_clk -to $tx_gt_clk
#vcode_gen
set_multicycle_path -quiet -setup 4 -from [get_pins -hier -filter {NAME =~ *u_vcode_gen/crc_previous_reg[*]/C}] -to [get_pins -hier -filter {NAME =~ *u_vcode_gen/data_out_reg[*]/D}]
set_multicycle_path -quiet -hold 3 -from [get_pins -hier -filter {NAME =~ *u_vcode_gen/crc_previous_reg[*]/C}] -to [get_pins -hier -filter {NAME =~ *u_vcode_gen/data_out_reg[*]/D}]
set_multicycle_path -quiet -setup 4 -from [get_pins -hier -filter {NAME =~ *frame_id_reg[*]/C}]
set_multicycle_path -quiet -hold 3 -from [get_pins -hier -filter {NAME =~ *frame_id_reg[*]/C}]
#vcode_val
set_multicycle_path -quiet -setup 4 -from [get_pins -hier -filter {NAME =~ *frame_id_threshold_reg[*]/C}]
set_multicycle_path -quiet -hold 3  -from [get_pins -hier -filter {NAME =~ *frame_id_threshold_reg[*]/C}]
set_multicycle_path -quiet -setup 4 -to [get_pins -hier -filter {NAME =~ *rx_error_reg/D}]
set_multicycle_path -quiet -hold 3  -to [get_pins -hier -filter {NAME =~ *rx_error_reg/D}]

set_multicycle_path -quiet -setup -start 4 -from $usr_clk -to $tx_frame_clk
set_multicycle_path -quiet -hold -start 3 -from $usr_clk -to $tx_frame_clk
set_multicycle_path -quiet -setup -end 4 -from $tx_frame_clk -to $usr_clk
set_multicycle_path -quiet -hold -end 3 -from $tx_frame_clk -to $usr_clk

#gray-coded CDC buses: bound the inter-bit arrival skew to < one source clock period so
#at most one bit is in transition at any destination sampling edge (the gray-coherency
#requirement).  The blanket false_path on the synchronizer first stages above
#intentionally leaves per-bit latency unconstrained; bus-skew is an independent check
#that the false_path does not override.
#  - clock-compensation telemetry counters (tx/rx frame clk -> init_clk)
set_bus_skew -quiet -from [get_pins -hier -filter {NAME =~ *tx_cntr/gray_reg[*]/C}] -to [get_pins -hier -filter {NAME =~ *sync_tx_cntr/d_meta_reg[0][*]/D}] $frame_period
set_bus_skew -quiet -from [get_pins -hier -filter {NAME =~ *rx_cntr/gray_reg[*]/C}] -to [get_pins -hier -filter {NAME =~ *sync_rx_cntr/d_meta_reg[0][*]/D}] $frame_period
#  - async-FIFO gray read/write pointers (both directions, ~390MHz GT clocks)
set_bus_skew -quiet -from [get_pins -hier -filter {NAME =~ *u_async_wr_ctrl/u_graycntr/gray_reg[*]/C}] -to [get_pins -hier -filter {NAME =~ *u_sync_signle_bit1/d_meta_reg[0][*]/D}] $gt_period
set_bus_skew -quiet -from [get_pins -hier -filter {NAME =~ *u_async_rd_ctrl/u_graycntr/gray_reg[*]/C}] -to [get_pins -hier -filter {NAME =~ *u_sync_signle_bit2/d_meta_reg[0][*]/D}] $gt_period
