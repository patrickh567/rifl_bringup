# RIFL BIST Testbench Reset
set_property OUTPUT_VALUE 1 [get_hw_probes design_vio_global_rst_0/vio_0_probe_out0 -of_objects [get_hw_vios -of_objects [get_hw_devices xcvu47p_0] -filter {CELL_NAME=~"design_vio_global_rst_0/vio_0"}]]
commit_hw_vio [get_hw_probes {design_vio_global_rst_0/vio_0_probe_out0} -of_objects [get_hw_vios -of_objects [get_hw_devices xcvu47p_0] -filter {CELL_NAME=~"design_vio_global_rst_0/vio_0"}]]
set_property OUTPUT_VALUE 0 [get_hw_probes design_vio_global_rst_0/vio_0_probe_out0 -of_objects [get_hw_vios -of_objects [get_hw_devices xcvu47p_0] -filter {CELL_NAME=~"design_vio_global_rst_0/vio_0"}]]
commit_hw_vio [get_hw_probes {design_vio_global_rst_0/vio_0_probe_out0} -of_objects [get_hw_vios -of_objects [get_hw_devices xcvu47p_0] -filter {CELL_NAME=~"design_vio_global_rst_0/vio_0"}]]
