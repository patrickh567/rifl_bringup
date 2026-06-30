##############################################################################
# rifl_hw_connect.tcl
#
# Connect to the remote FPGA over XVC, enumerate the design_1 debug cores
# (JTAG-AXI master + reset VIO), release the design_1 reset, and dump the
# register-map / link status.  Read-mostly: the only write is releasing the
# design_1 reset VIO (so the JTAG-AXI master and register map respond).
#
#   vivado -mode batch -source script/rifl_hw_connect.tcl
#   # override the XVC url:  -tclargs <host:port>   (or edit hammerblade_ip_address.txt)
##############################################################################

source [file join [file dirname [file normalize [info script]]] rifl_hw_lib.tcl]
if {$argc >= 1} { set ::RIFL_XVC [lindex $argv 0] }

rifl_connect

puts "=== debug cores on $::rifl_dev ==="
puts "  hw_axis : [get_hw_axis -quiet]"
puts "  hw_vios : [get_hw_vios -quiet -of_objects $::rifl_dev]"
puts "  hw_ilas : [get_hw_ilas -quiet -of_objects $::rifl_dev]"

puts "=== releasing design_1 reset ==="
rifl_release_axi_reset
after 300

puts "=== register / link status ==="
rifl_status

rifl_disconnect
puts "=== done ==="
