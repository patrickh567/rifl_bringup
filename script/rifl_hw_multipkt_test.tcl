##############################################################################
# rifl_hw_multipkt_test.tcl
#
# Multi-packet TX framing test (buffer-descriptor FIFO).  For each link:
#   1. disable TX; load several packets of VARYING size into the TX FIFO --
#      per packet: write its data words (awaddr[15]=0) then commit (awaddr[15]=1,
#      +0x8000), which records the packet's beat-count in the descriptor FIFO.
#   2. check tx_desc_occ == number of packets loaded (none drained yet, since
#      descriptor pops are gated by the TX enable).
#   3. enable TX once -> every buffered packet drains into the RIFL link with
#      tlast at its own descriptor boundary.
#   4. on the peer link, read back packet-by-packet: pop a length L from the RX
#      length FIFO (+0xC000), read L data words, and verify BOTH the boundary
#      (L == sent size) AND the data.
#
# Every read is sized to the live occupancy (rx_pkt_occ / rx_occ) so it never
# over-reads and stalls the bus.  Links are pair-cabled (0<->1, 2<->3); the test
# scans for the arrival link, so it is topology-agnostic.
#
#   vivado -mode batch -source script/rifl_hw_multipkt_test.tcl  [-tclargs <host:port>]
##############################################################################

source [file join [file dirname [file normalize [info script]]] rifl_hw_lib.tcl]
if {$argc >= 1} { set ::RIFL_XVC [lindex $argv 0] }

# unique 256-bit (64-hex) word tagged with (link, packet-index, word-index)
proc mp_word {link pkt idx} {
  set a [format %08X [expr {(0xC0000000 + ($link<<24) + ($pkt<<16) + $idx) & 0xFFFFFFFF}]]
  set b [format %08X [expr {(0xD0000000 + ($link<<24) + ($pkt<<16) + $idx) & 0xFFFFFFFF}]]
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

# a larger batch of varying-size packets (256-bit beats) to exercise the deeper FIFOs
set sizes {}
for {set i 0} {$i < 32} {incr i} { lappend sizes [expr {($i % 8) + 1}] }
set npkt  [llength $sizes]
set total 0
set pass  0

for {set L 0} {$L < 4} {incr L} {
  puts [format "===== TX link %d: load %d packets, %d beats total =====" $L $npkt [expr [join $sizes +]]]
  rifl_ctrl_clr $::RIFL_AXIS_EN
  rifl_drain_all

  # ---- load each packet (data burst + commit), TX disabled ----
  set sent {}
  set pi 0
  foreach N $sizes {
    set pkt ""
    for {set w 0} {$w < $N} {incr w} { append pkt [mp_word $L $pi $w] }
    rifl_tx_burst  $L $N $pkt
    rifl_tx_commit $L
    lappend sent $pkt
    incr pi
  }
  set dq [rifl_tx_desc_occ $L]
  puts [format "  loaded; tx_desc_occ = %d (expected %d)%s" $dq $npkt \
          [expr {$dq == $npkt ? "" : "  <-- MISMATCH"}]]

  # ---- release: all packets drain with their own tlast boundaries ----
  rifl_ctrl_set $::RIFL_AXIS_EN

  # ---- find the arrival link (receives all $npkt packets) ----
  set arr -1
  for {set t 0} {$t < 60 && $arr < 0} {incr t} {
    after 100
    for {set r 0} {$r < 4} {incr r} { if {[rifl_rx_pkt_occ $r] >= $npkt} { set arr $r; break } }
  }
  if {$arr < 0} {
    set best -1; set arr 0
    for {set r 0} {$r < 4} {incr r} { set o [rifl_rx_pkt_occ $r]; if {$o > $best} { set best $o; set arr $r } }
  }
  puts [format "  TX %d -> RX %d : %d packet(s) received" $L $arr [rifl_rx_pkt_occ $arr]]

  # ---- read back packet-by-packet, verify boundary + data ----
  set lpass 0
  for {set p 0} {$p < $npkt} {incr p} {
    incr total
    if {[rifl_rx_pkt_occ $arr] < 1} { puts [format "  pkt %d: MISSING (no length in RX)" $p]; continue }
    set Lrx  [rifl_rx_pop_len $arr]                       ;# received packet length (boundary)
    set Lexp [lindex $sizes $p]
    for {set t 0} {$t < 30 && [rifl_rx_occ $arr] < $Lrx} {incr t} { after 50 }
    set navail [rifl_rx_occ $arr]
    set toread [expr {$navail < $Lrx ? $navail : $Lrx}]
    if {$toread < 1} { puts [format "  pkt %d: FAIL (len=%d but no data)" $p $Lrx]; continue }
    set rd  [rifl_rx_burst $arr $toread 0]
    set exp [lindex $sent $p]
    if {$Lrx == $Lexp && $toread == $Lrx && [string equal -nocase $rd $exp]} {
      incr lpass; incr pass
    } else {
      puts [format "  pkt %d: FAIL  (rx_len=%d exp=%d, read=%d, data=%s)" \
              $p $Lrx $Lexp $toread [expr {[string equal -nocase $rd $exp] ? "match" : "MISMATCH"}]]
    }
  }
  puts [format "  verified %d/%d packets (boundary + data)" $lpass $npkt]
  rifl_ctrl_clr $::RIFL_AXIS_EN
}

puts "===== RESULT: $pass / $total packets verified ====="
rifl_status
rifl_disconnect
puts "=== done ==="
