##############################################################################
# rifl_hw_prbs_test.tcl
#
# PRBS self-test (built-in generator/checker) exercise over the JTAG-AXI master.
#   1. connect, release design_1 reset, bring the links up.
#   2. healthy soak: enable the PRBS generator + checker on all links with a
#      shared seed.  Each link's checker regenerates its peer's sequence, so a
#      healthy link should report ZERO errors.  Read each link's error count and
#      error-record FIFO fill.
#   3. forced error: perturb link 0's checker seed so it expects a different
#      sequence than its peer actually sends -> link 0's error count must climb
#      and its error FIFO must capture records.  Read back one record.
#
# The point of step 3 is to prove the checker + error buffer actually work
# (RIFL's own error-injection is compiled out of this image).
#
#   vivado -mode batch -source script/rifl_hw_prbs_test.tcl  [-tclargs <host:port>]
##############################################################################

source [file join [file dirname [file normalize [info script]]] rifl_hw_lib.tcl]
if {$argc >= 1} { set ::RIFL_XVC [lindex $argv 0] }

set SEED   0xDEADBEEF
set MAXLEN 16

rifl_connect
rifl_release_axi_reset
after 300

puts "=== bring links up ==="
rifl_ctrl_clr $::RIFL_AXIS_EN
rifl_prbs_enable 0x0
rifl_ctrl_set $::RIFL_CORE_RESET; after 200; rifl_ctrl_clr $::RIFL_CORE_RESET
if {![rifl_wait_links_up 10000]} { puts ">>> WARNING: not all links up" }
rifl_status

# ---- healthy soak: PRBS on all links, shared seed, expect 0 errors ----
puts [format "=== healthy soak: seed=0x%X, random length 1..%d beats, ~3 s ===" $SEED $MAXLEN]
rifl_prbs_config $SEED $MAXLEN 2 1
rifl_prbs_enable 0xF
after 3000
set toterr 0
for {set L 0} {$L < 4} {incr L} {
  set e [rifl_prbs_err_cnt $L]; set o [rifl_prbs_occ $L]
  incr toterr $e
  puts [format "  link %d : prbs_err=%d  errfifo_occ=%d  %s" $L $e $o \
          [expr {$e == 0 ? "OK" : "<-- ERRORS"}]]
}
rifl_prbs_enable 0x0

# ---- forced error: perturb link 0's checker; expect its count to climb ----
puts "=== forced error: perturb link 0's checker (expect link 0 err > 0) ==="
rifl_prbs_enable 0xF 0x1
after 1000
set e0 [rifl_prbs_err_cnt 0]; set o0 [rifl_prbs_occ 0]
puts [format "  link 0 : prbs_err=%d  errfifo_occ=%d" $e0 $o0]
if {$o0 >= 3} {
  set rec [rifl_prbs_err_rec 0]
  puts "  first error record (3 x 256-bit words, raw hex):"
  puts "    A = [string range $rec 0 63]"
  puts "    B = [string range $rec 64 127]"
  puts "    C = [string range $rec 128 191]"
  puts "    (two of A/B/C are the expected vs received 256-bit data; the third"
  puts "     packs pkt/flit index, expected/received tkeep, and mismatch flags.)"
}
rifl_prbs_enable 0x0

puts [format "=== RESULT: healthy total err=%d (want 0);  link0 forced err=%d (want >0) ===" $toterr $e0]
rifl_status
rifl_disconnect
puts "=== done ==="
