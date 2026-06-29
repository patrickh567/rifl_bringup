# RIFL BIST Testbench Clear
set_property OUTPUT_VALUE 1 [get_hw_probes {nm[*].design_vio_rifl_bist_0/vio_0_probe_out4} -of_objects [get_hw_vios -of_objects [get_hw_devices xcvu47p_0] -filter {CELL_NAME=~"nm[*].design_vio_rifl_bist_0/vio_0"}]]
commit_hw_vio [get_hw_probes {nm[*].design_vio_rifl_bist_0/vio_0_probe_out4} -of_objects [get_hw_vios -of_objects [get_hw_devices xcvu47p_0] -filter {CELL_NAME=~"nm[*].design_vio_rifl_bist_0/vio_0"}]]
set_property OUTPUT_VALUE 0 [get_hw_probes {nm[*].design_vio_rifl_bist_0/vio_0_probe_out4} -of_objects [get_hw_vios -of_objects [get_hw_devices xcvu47p_0] -filter {CELL_NAME=~"nm[*].design_vio_rifl_bist_0/vio_0"}]]
commit_hw_vio [get_hw_probes {nm[*].design_vio_rifl_bist_0/vio_0_probe_out4} -of_objects [get_hw_vios -of_objects [get_hw_devices xcvu47p_0] -filter {CELL_NAME=~"nm[*].design_vio_rifl_bist_0/vio_0"}]]
