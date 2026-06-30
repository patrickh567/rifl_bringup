##############################################################################
# rifl_hw_linkup.tcl
#
# Bring the four RIFL links up: connect, release the design_1 reset, pulse the
# core_reset (csr[0][2]) to restart RIFL/GT training, then poll rx_up until all
# links report all four channels up (or time out).  Reports per-link status.
#
#   vivado -mode batch -source script/rifl_hw_linkup.tcl
#   # optional:  -tclargs <host:port>
##############################################################################

source [file join [file dirname [file normalize [info script]]] rifl_hw_lib.tcl]
if {$argc >= 1} { set ::RIFL_XVC [lindex $argv 0] }

rifl_connect
rifl_release_axi_reset
after 300

puts "=== pulsing core_reset to (re)start RIFL training ==="
rifl_ctrl_set $::RIFL_CORE_RESET
after 200
rifl_ctrl_clr $::RIFL_CORE_RESET

puts "=== waiting for links up (timeout 10 s) ==="
if {[rifl_wait_links_up 10000]} {
  puts ">>> ALL 4 LINKS UP"
} else {
  puts ">>> TIMEOUT: not all links up (see per-link rx_up nibble below)"
  for {set l 0} {$l < 4} {incr l} {
    puts [format "    link %d rx_up nibble = 0x%X (0xF = all 4 channels up)" $l [rifl_link_nibble $l]]
  }
}

puts "=== status ==="
rifl_status

rifl_disconnect
puts "=== done ==="
