##############################################################################
# rifl_hw_link_test.tcl
#
# End-to-end single-word loopback test over the JTAG-AXI master:
#   1. connect, release design_1 reset, pulse core_reset, wait for links up
#   2. enable the TX AXIS path (csr[0][0])
#   3. for each link L: push a unique 256-bit word into link L's TX FIFO, then
#      scan all links' RX-data occupancy to see where it arrives, pop the RX
#      word (+ tkeep) and compare against what was sent.
#
# The arrival link depends on the physical fibre topology (self-loopback ->
# same link; pair-cabled -> the peer).  The test reports TX link -> RX link and
# PASS/FAIL on the data compare, so it works for either wiring.
#
#   vivado -mode batch -source script/rifl_hw_link_test.tcl
#   # optional:  -tclargs <host:port>
##############################################################################

source [file join [file dirname [file normalize [info script]]] rifl_hw_lib.tcl]
if {$argc >= 1} { set ::RIFL_XVC [lindex $argv 0] }

rifl_connect
rifl_release_axi_reset
after 300

puts "=== bring links up ==="
rifl_ctrl_set $::RIFL_CORE_RESET; after 200; rifl_ctrl_clr $::RIFL_CORE_RESET
if {![rifl_wait_links_up 10000]} {
  puts ">>> WARNING: not all links up; continuing anyway"
}
rifl_status

puts "=== enable TX AXIS ==="
rifl_ctrl_set $::RIFL_AXIS_EN
after 200

set pass 0
set fail 0
for {set l 0} {$l < 4} {incr l} {
  # unique 256-bit pattern for this link (beat0 .. beat7)
  set w [format "DEAD%04X%08X%08X%08X%08X%08X%08X CAFE%04X" \
           $l 0x11111111 0x22222222 0x33333333 0x44444444 0x55555555 0x66666666 $l]
  set w [string map {" " ""} $w]
  puts "--- link $l: TX word $w ---"
  rifl_tx_word $l $w
  rifl_tx_commit $l

  # wait for the word to appear in some link's RX-data FIFO
  set got -1
  for {set tries 0} {$tries < 25 && $got < 0} {incr tries} {
    after 200
    for {set r 0} {$r < 4} {incr r} {
      if {[rifl_rx_occ $r] > 0} { set got $r; break }
    }
  }
  if {$got < 0} {
    puts "    no RX data arrived within timeout (no loopback/peer on link $l?)"
    incr fail
    continue
  }
  set rd [rifl_rx_word $got 0]
  set tk [rifl_rx_word $got 1]
  puts "    RX on link $got: data=$rd  tkeep=$tk"
  if {[string equal -nocase $rd $w]} {
    puts "    PASS  (TX link $l -> RX link $got, data matched)"
    incr pass
  } else {
    puts "    FAIL  (TX link $l -> RX link $got, data MISMATCH)"
    puts "          sent $w"
    incr fail
  }
}

puts "=== RESULT: $pass passed, $fail failed (of 4 links) ==="
rifl_status
rifl_disconnect
puts "=== done ==="
