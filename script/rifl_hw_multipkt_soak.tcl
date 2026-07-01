##############################################################################
# rifl_hw_multipkt_soak.tcl
#
# Soak of the multi-packet TX framing: connect + bring links up ONCE, then loop
# <iters> times.  Each iteration, per link: drain, load <npkt> varying-size
# packets (data tagged by iter/link/pkt/word), check tx_desc_occ, enable, find
# the arrival link, and read every packet back verifying boundary + data.
#
# npkt defaults to 60 -- just under the loaded image's 64-deep descriptor FIFO
# (max packets), with sizes cycling 1..8 (~270 beats << the 512-beat data FIFO).
#
#   vivado -mode batch -source script/rifl_hw_multipkt_soak.tcl [-tclargs <iters> <npkt> <host:port>]
##############################################################################

source [file join [file dirname [file normalize [info script]]] rifl_hw_lib.tcl]
set ITER 100
set NPKT 60
if {$argc >= 1} { set ITER [lindex $argv 0] }
if {$argc >= 2} { set NPKT [lindex $argv 1] }
if {$argc >= 3} { set ::RIFL_XVC [lindex $argv 2] }

# unique 256-bit (64-hex) word tagged with (iter,link,pkt,idx)
proc mp_word {iter link pkt idx} {
  set tag [format %02X%02X%02X%02X [expr {$iter & 0xFF}] [expr {$link & 0xFF}] \
                                   [expr {$pkt & 0xFF}]  [expr {$idx & 0xFF}]]
  return "${tag}111111112222222233333333444444445555555566666666${tag}"
}

# Robust connect: open the XVC target ONCE, then re-run chain enumeration until
# the JTAG-AXI core appears (it is transiently missed under CPU/IO contention).
proc soak_connect {} {
  set url [rifl_xvc_url]
  puts "soak_connect: $url"
  if {[catch {open_hw_manager}]} { open_hw }
  connect_hw_server
  catch { open_hw_target -quiet -xvc_url $url }
  after 1500
  catch { close_hw_target }
  after 1500
  open_hw_target -xvc_url $url
  set ::rifl_dev [lindex [get_hw_devices] 0]
  current_hw_device $::rifl_dev
  for {set i 0} {$i < 30} {incr i} {
    refresh_hw_device -quiet $::rifl_dev
    after 1000
    set axis [get_hw_axis -quiet]
    if {[llength $axis] > 0} {
      set ::rifl_axi [lindex $axis 0]
      puts "  connected: hw_axi = $::rifl_axi (enum try [expr {$i+1}])"
      return 1
    }
  }
  return 0
}
if {![soak_connect]} { error "could not reach the FPGA JTAG-AXI (enumeration kept missing it)" }
rifl_release_axi_reset
after 300
puts "=== bring links up ==="
rifl_ctrl_clr $::RIFL_AXIS_EN
rifl_ctrl_set $::RIFL_CORE_RESET; after 200; rifl_ctrl_clr $::RIFL_CORE_RESET
if {![rifl_wait_links_up 10000]} { puts ">>> WARNING: not all links up" }
rifl_status

set sizes {}
for {set i 0} {$i < $NPKT} {incr i} { lappend sizes [expr {($i % 8) + 1}] }
set exp_total [expr {4 * $NPKT}]
puts [format "=== soak: %d iterations x 4 links x %d packets (%d beats/link) ===" \
        $ITER $NPKT [expr [join $sizes +]]]

set grand_pass 0
set grand_total 0
set iters_ok 0
for {set it 0} {$it < $ITER} {incr it} {
  set it_pass 0
  set worst_desc $NPKT
  for {set L 0} {$L < 4} {incr L} {
    rifl_ctrl_clr $::RIFL_AXIS_EN
    rifl_drain_all
    # ---- load npkt packets (data burst + commit), TX disabled ----
    set sent {}
    set pi 0
    foreach N $sizes {
      set pkt ""
      for {set w 0} {$w < $N} {incr w} { append pkt [mp_word $it $L $pi $w] }
      rifl_tx_burst  $L $N $pkt
      rifl_tx_commit $L
      lappend sent $pkt
      incr pi
    }
    set dq [rifl_tx_desc_occ $L]
    if {$dq < $worst_desc} { set worst_desc $dq }
    # ---- release + find the arrival link ----
    rifl_ctrl_set $::RIFL_AXIS_EN
    set arr -1
    for {set t 0} {$t < 60 && $arr < 0} {incr t} {
      after 100
      for {set r 0} {$r < 4} {incr r} { if {[rifl_rx_pkt_occ $r] >= $NPKT} { set arr $r; break } }
    }
    if {$arr < 0} {
      set best -1; set arr 0
      for {set r 0} {$r < 4} {incr r} { set o [rifl_rx_pkt_occ $r]; if {$o > $best} { set best $o; set arr $r } }
    }
    # ---- read back packet-by-packet ----
    for {set p 0} {$p < $NPKT} {incr p} {
      incr grand_total
      if {[rifl_rx_pkt_occ $arr] < 1} { continue }
      set Lrx  [rifl_rx_pop_len $arr]
      set Lexp [lindex $sizes $p]
      for {set t 0} {$t < 30 && [rifl_rx_occ $arr] < $Lrx} {incr t} { after 50 }
      set navail [rifl_rx_occ $arr]
      set toread [expr {$navail < $Lrx ? $navail : $Lrx}]
      if {$toread < 1} { continue }
      set rd  [rifl_rx_burst $arr $toread 0]
      set exp [lindex $sent $p]
      if {$Lrx == $Lexp && $toread == $Lrx && [string equal -nocase $rd $exp]} {
        incr it_pass; incr grand_pass
      }
    }
    rifl_ctrl_clr $::RIFL_AXIS_EN
  }
  if {$it_pass == $exp_total} { incr iters_ok }
  puts [format "iter %3d: %d/%d packets  (min tx_desc_occ=%d)  %s" \
          $it $it_pass $exp_total $worst_desc [expr {$it_pass == $exp_total ? "OK" : "<-- FAIL"}]]
  flush stdout
}
puts [format "===== SOAK RESULT: %d/%d iterations fully passed; %d/%d packets verified =====" \
        $iters_ok $ITER $grand_pass $grand_total]
rifl_status
rifl_disconnect
puts "=== done ==="
