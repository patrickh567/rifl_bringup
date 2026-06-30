##############################################################################
# rifl_hw_packet_test.tcl
#
# Exercise each RIFL link with packets of several sizes.  A packet is N 256-bit
# beats framed by tlast; the TX FIFO frames per descriptor (commit), so for each
# (link, size):
#   1. disable TX (csr[0][0]=0)
#   2. write N unique 256-bit words into the link's TX FIFO, then commit them as
#      one packet
#   3. enable TX -> the FIFO drains the N-beat packet with tlast on the last beat
#   4. poll the peer link's rx occupancy until N words have arrived
#   5. burst-read exactly that many words and compare against what was sent
#
# Sizes: 1,2,4,8,16,32 words (32B .. 1KB).  32 words = one 256-beat JTAG burst,
# the AXI4 max -- larger packets would need multiple bursts.
#
#   vivado -mode batch -source script/rifl_hw_packet_test.tcl   [-tclargs <host:port>]
##############################################################################

source [file join [file dirname [file normalize [info script]]] rifl_hw_lib.tcl]
if {$argc >= 1} { set ::RIFL_XVC [lindex $argv 0] }

# unique 256-bit (64-hex) word tagged with (link,size,word-index)
proc rifl_mkword {link size idx} {
  set a [format %08X [expr {(0xA0000000 + ($link<<20) + ($size<<12) + $idx) & 0xFFFFFFFF}]]
  set b [format %08X [expr {(0xB0000000 + ($link<<20) + ($size<<12) + $idx) & 0xFFFFFFFF}]]
  return "${a}111111112222222233333333444444445555555566666666${b}"
}
rifl_connect
rifl_release_axi_reset
after 300

puts "=== bring links up ==="
rifl_ctrl_clr $::RIFL_AXIS_EN
rifl_ctrl_set $::RIFL_CORE_RESET; after 200; rifl_ctrl_clr $::RIFL_CORE_RESET
if {![rifl_wait_links_up 10000]} { puts ">>> WARNING: not all links up" }
rifl_status

set sizes {1 2 4 8 16 32}
set pass 0
set total 0
foreach N $sizes {
  puts "===== packet size = $N word(s) = [expr {$N*32}] bytes ====="
  for {set L 0} {$L < 4} {incr L} {
    incr total
    rifl_ctrl_clr $::RIFL_AXIS_EN
    rifl_drain_all

    # build + buffer the N-word packet, then release it as one packet
    set pkt ""
    for {set w 0} {$w < $N} {incr w} { append pkt [rifl_mkword $L $N $w] }
    rifl_tx_burst $L $N $pkt
    rifl_tx_commit $L
    rifl_ctrl_set $::RIFL_AXIS_EN

    # wait for N words to land on some link
    set arr -1
    for {set t 0} {$t < 50 && $arr < 0} {incr t} {
      after 100
      for {set r 0} {$r < 4} {incr r} { if {[rifl_rx_occ $r] >= $N} { set arr $r; break } }
    }
    if {$arr < 0} {
      set best -1; set arr 0
      for {set r 0} {$r < 4} {incr r} { set o [rifl_rx_occ $r]; if {$o > $best} { set best $o; set arr $r } }
    }
    set navail [rifl_rx_occ $arr]
    if {$navail < 1} { puts [format "  link %d  N=%-2d : NO RX (no arrival)" $L $N]; continue }
    if {$navail > $N} { set navail $N }
    set rd [rifl_rx_burst $arr $navail 0]
    if {$navail == $N && [string equal -nocase $rd $pkt]} {
      puts [format "  link %d -> RX %d   N=%-2d : PASS (%d bytes round-tripped)" $L $arr $N [expr {$N*32}]]
      incr pass
    } else {
      puts [format "  link %d -> RX %d   N=%-2d : FAIL (got %d/%d words%s)" \
              $L $arr $N $navail $N [expr {[string equal -nocase $rd [string range $pkt 0 [expr {$navail*64-1}]]] ? "" : ", data mismatch"}]]
    }
  }
}

rifl_ctrl_clr $::RIFL_AXIS_EN
puts "===== RESULT: $pass / $total packet tests passed ====="
rifl_status
rifl_disconnect
puts "=== done ==="
