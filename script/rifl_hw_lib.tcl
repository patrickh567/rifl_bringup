##############################################################################
# rifl_hw_lib.tcl
#
# Hardware-manager helper library to exercise the top_rifl image over its
# JTAG-to-AXI master (design_1) and the domain-1 reset VIO.  Source this from
# the driver scripts (rifl_hw_connect / rifl_hw_linkup / rifl_hw_link_test).
#
# ---------------------------------------------------------------------------
# AXI memory map (design_1 address editor)
#   0x44A0_0000  AXI4-Lite register map (axi_lite_regs, M_AXI_4)
#   0x44A1_0000  link 0 TX/RX FIFO        0x44A3_0000  link 2
#   0x44A2_0000  link 1 TX/RX FIFO        0x44A4_0000  link 3
#
# Register map (32-bit regs; byte offset = reg_index*4)
#   ctrl reg0 @ 0x00 : bit0 axis_enable (TX), bit1 cc_reset, bit2 core_reset
#   status (read-only) @ 0x40 + k*4 :
#     0x40 rx_up         0x44 rx_aligned      0x48 rx_error
#     0x4C rx_pause      0x50 rx_retrans      0x54 tx_state_init ...
#     0x68 tx_state_normal   0x6C local_fc    0x70 remote_fc   0x74 compensate
#     0x1C8 + 4*L  rx_data_occupancy[L]   0x1D8 + 4*L  rx_tkeep_occupancy[L]
#     0x1E8 + 4*L  tx_desc_occupancy[L]   0x1F8 + 4*L  rx_pkt_count[L]
#   rx_up / rx_aligned / ... pack one bit per channel: bit (link*4 + channel),
#   4 channels per link -> a link is "up" when its nibble == 0xF.
#
# Per-link FIFO (base 0x44A(L+1)_0000)
#   WRITE awaddr[15]=0 (+0x0)    -> push a 256-bit TX word into the data FIFO
#   WRITE awaddr[15]=1 (+0x8000) -> COMMIT: frame the words written since the last
#                                   commit as one packet (descriptor FIFO).  Raising
#                                   ctrl0[0] drains every buffered packet, tlast at
#                                   each boundary.
#   READ araddr[15:14]: 0x (+0x0) RX data, 10 (+0x8000) RX tkeep, 11 (+0xC000) RX
#                       packet length (one beat-count per received packet).
#   The JTAG-AXI master is 32-bit, so a 256-bit word is one 8-beat INCR burst
#   (the design_1 axi_dwidth_converter packs/unpacks 8x32 <-> 1x256).
##############################################################################

# ---- address map ----
set ::RIFL_REG_BASE   0x44A00000
set ::RIFL_LINK_BASE  {0x44A10000 0x44A20000 0x44A30000 0x44A40000}

# register byte offsets
set ::RIFL_CTRL0          0x00
set ::RIFL_ST_RX_UP       0x40
set ::RIFL_ST_RX_ALIGNED  0x44
set ::RIFL_ST_RX_ERROR    0x48
set ::RIFL_ST_TX_NORMAL   0x68
set ::RIFL_ST_RXOCC_BASE  0x1C8
set ::RIFL_ST_TKOCC_BASE  0x1D8
set ::RIFL_ST_TXDESC_BASE 0x1E8
set ::RIFL_ST_RXPKT_BASE  0x1F8
set ::RIFL_ST_PRBS_ERR_BASE 0x208    ;# per-link PRBS corrupted-packet count
set ::RIFL_ST_PRBS_OCC_BASE 0x218    ;# per-link PRBS error-record FIFO occupancy (256b words)

# PRBS BIST control registers
set ::RIFL_CTRL1          0x04       ;# [3:0] per-link enable, [8] clear, [19:16] per-link seed-perturb
set ::RIFL_PRBS_MASK      0x08       ;# [15:0] length mask (2^k-1); length = min + (lfsr & mask)
set ::RIFL_PRBS_SEED      0x0C       ;# [31:0] PRBS + length seed
set ::RIFL_PRBS_MIN       0x10       ;# [17:2] min length (beats)

# ctrl reg0 bit masks
set ::RIFL_AXIS_EN        0x1
set ::RIFL_CC_RESET       0x2
set ::RIFL_CORE_RESET     0x4

# globals, set by rifl_connect
set ::rifl_dev ""
set ::rifl_axi ""

# XVC url: $::RIFL_XVC if set, else hammerblade_ip_address.txt in cwd, else default
proc rifl_xvc_url {} {
  if {[info exists ::RIFL_XVC] && $::RIFL_XVC ne ""} { return $::RIFL_XVC }
  set f [file join [pwd] hammerblade_ip_address.txt]
  if {[file exists $f]} {
    set fh [open $f r]; set url [string trim [read $fh]]; close $fh
    if {$url ne ""} { return $url }
  }
  return "128.95.196.147:2542"
}

# open hw manager, connect to the XVC target, latch the device + JTAG-AXI master
proc rifl_connect {} {
  set url [rifl_xvc_url]
  puts "rifl_connect: opening XVC target $url"
  if {[catch {open_hw_manager}]} { open_hw }   ;# open_hw on 2019.1, open_hw_manager on 2019.2+
  connect_hw_server
  catch { open_hw_target -quiet -xvc_url $url }
  after 1000
  catch { close_hw_target }
  after 1000
  open_hw_target -xvc_url $url
  set ::rifl_dev [lindex [get_hw_devices] 0]
  current_hw_device $::rifl_dev
  refresh_hw_device -quiet $::rifl_dev
  set axis [get_hw_axis -quiet]
  if {[llength $axis] == 0} {
    error "No JTAG-AXI master (hw_axi) found -- is the FPGA programmed with the top_rifl image?"
  }
  set ::rifl_axi [lindex $axis 0]
  puts "rifl_connect: device=$::rifl_dev  hw_axi=$::rifl_axi"
}

proc rifl_disconnect {} {
  catch { close_hw_target }
  catch { disconnect_hw_server }
}

# Release the design_1 (JTAG-AXI + register-map) reset held by the top-level VIO.
# Sets every VIO output probe to 0 (the active-high reset), so axi_aresetn -> 1.
proc rifl_release_axi_reset {} {
  set vios [get_hw_vios -quiet -of_objects $::rifl_dev]
  if {[llength $vios] == 0} {
    puts "  rifl_release_axi_reset: no hw_vio (design_1 reset assumed released by VIO init)"
    return
  }
  foreach v $vios {
    foreach p [get_hw_probes -quiet -of_objects $v -filter {NAME =~ *probe_out*}] {
      set_property OUTPUT_VALUE 0 $p
      commit_hw_vio $p
      puts "  rifl_release_axi_reset: $p <- 0"
    }
  }
}

# ---- 32-bit register access (M_AXI_4, AXI4-Lite) ----
proc rifl_reg_rd {off} {
  set addr [format 0x%08X [expr {$::RIFL_REG_BASE + $off}]]
  catch { delete_hw_axi_txn [get_hw_axi_txns -quiet rifl_r] }
  create_hw_axi_txn rifl_r $::rifl_axi -address $addr -len 1 -type read
  run_hw_axi -quiet [get_hw_axi_txns rifl_r]
  set d [get_property DATA [get_hw_axi_txns rifl_r]]
  delete_hw_axi_txn [get_hw_axi_txns rifl_r]
  return $d
}
proc rifl_reg_wr {off val} {
  set addr [format 0x%08X [expr {$::RIFL_REG_BASE + $off}]]
  set data [format %08X [expr {$val & 0xFFFFFFFF}]]
  catch { delete_hw_axi_txn [get_hw_axi_txns -quiet rifl_w] }
  create_hw_axi_txn rifl_w $::rifl_axi -address $addr -data $data -len 1 -type write
  run_hw_axi -quiet [get_hw_axi_txns rifl_w]
  delete_hw_axi_txn [get_hw_axi_txns rifl_w]
}
proc rifl_rd {off}  { return [expr {"0x[rifl_reg_rd $off]"}] }            ;# integer
proc rifl_ctrl_set {mask} { rifl_reg_wr $::RIFL_CTRL0 [expr {[rifl_rd $::RIFL_CTRL0] |  $mask}] }
proc rifl_ctrl_clr {mask} { rifl_reg_wr $::RIFL_CTRL0 [expr {[rifl_rd $::RIFL_CTRL0] & ~$mask}] }

# ---- 256-bit per-link FIFO access (8-beat 32-bit JTAG-AXI burst) ----
proc rifl_link_base {link} { return [lindex $::RIFL_LINK_BASE $link] }

# push one 256-bit TX word (data256 = 64-hex string) into link L's TX FIFO
proc rifl_tx_word {link data256} {
  catch { delete_hw_axi_txn [get_hw_axi_txns -quiet rifl_tx] }
  create_hw_axi_txn rifl_tx $::rifl_axi -address [rifl_link_base $link] \
                    -data $data256 -len 8 -type write
  run_hw_axi -quiet [get_hw_axi_txns rifl_tx]
  delete_hw_axi_txn [get_hw_axi_txns rifl_tx]
}
# pop one 256-bit RX word from link L (tkeep=0 data, 1 tkeep); returns 64-hex
proc rifl_rx_word {link {tkeep 0}} {
  set addr [format 0x%08X [expr {[rifl_link_base $link] + ($tkeep ? 0x8000 : 0)}]]
  catch { delete_hw_axi_txn [get_hw_axi_txns -quiet rifl_rx] }
  create_hw_axi_txn rifl_rx $::rifl_axi -address $addr -len 8 -type read
  run_hw_axi -quiet [get_hw_axi_txns rifl_rx]
  set d [get_property DATA [get_hw_axi_txns rifl_rx]]
  delete_hw_axi_txn [get_hw_axi_txns rifl_rx]
  return $d
}

# multi-word burst access (nwords <= 32: one JTAG burst is 8*nwords <= 256 beats).
# push nwords 256-bit words (data = nwords*64-hex) into link L's TX FIFO
proc rifl_tx_burst {link nwords data} {
  catch { delete_hw_axi_txn [get_hw_axi_txns -quiet rifl_txb] }
  create_hw_axi_txn rifl_txb $::rifl_axi -address [rifl_link_base $link] \
                    -data $data -len [expr {8*$nwords}] -type write
  run_hw_axi -quiet [get_hw_axi_txns rifl_txb]
  delete_hw_axi_txn [get_hw_axi_txns rifl_txb]
}
# pop nwords 256-bit words from link L (tkeep=0 data, 1 tkeep); returns nwords*64-hex.
# CAUTION: reading more words than present blocks (RVALID stalls) -- size to rx_occ.
proc rifl_rx_burst {link nwords {tkeep 0}} {
  set addr [format 0x%08X [expr {[rifl_link_base $link] + ($tkeep ? 0x8000 : 0)}]]
  catch { delete_hw_axi_txn [get_hw_axi_txns -quiet rifl_rxb] }
  create_hw_axi_txn rifl_rxb $::rifl_axi -address $addr -len [expr {8*$nwords}] -type read
  run_hw_axi -quiet [get_hw_axi_txns rifl_rxb]
  set d [get_property DATA [get_hw_axi_txns rifl_rxb]]
  delete_hw_axi_txn [get_hw_axi_txns rifl_rxb]
  return $d
}

# ---- packet framing: commit (TX) + length readback (RX) ----
# Commit the TX words written since the last commit as one packet (push their
# beat-count into the descriptor FIFO).  One write to link_base+0x8000
# (awaddr[15]=1); data is don't-care -- the hardware counts the beats.
proc rifl_tx_commit {link} {
  set addr [format 0x%08X [expr {[rifl_link_base $link] + 0x8000}]]
  catch { delete_hw_axi_txn [get_hw_axi_txns -quiet rifl_cm] }
  create_hw_axi_txn rifl_cm $::rifl_axi -address $addr -data [string repeat 0 64] -len 8 -type write
  run_hw_axi -quiet [get_hw_axi_txns rifl_cm]
  delete_hw_axi_txn [get_hw_axi_txns rifl_cm]
}
# Read nwords packet lengths from link L's RX length FIFO (+0xC000); raw nwords*64-hex.
# CAUTION: reading more lengths than present blocks -- size to rifl_rx_pkt_occ.
proc rifl_rx_len {link nwords} {
  set addr [format 0x%08X [expr {[rifl_link_base $link] + 0xC000}]]
  catch { delete_hw_axi_txn [get_hw_axi_txns -quiet rifl_ln] }
  create_hw_axi_txn rifl_ln $::rifl_axi -address $addr -len [expr {8*$nwords}] -type read
  run_hw_axi -quiet [get_hw_axi_txns rifl_ln]
  set d [get_property DATA [get_hw_axi_txns rifl_ln]]
  delete_hw_axi_txn [get_hw_axi_txns rifl_ln]
  return $d
}
# pop ONE packet length (integer # of 256-bit beats) from link L's RX length FIFO.
# The length is the low 32 bits (last 8 hex) of its returned 256-bit word.
proc rifl_rx_pop_len {link} {
  return [expr {"0x[string range [rifl_rx_len $link 1] end-7 end]"}]
}
proc rifl_tx_desc_occ {link} { return [rifl_rd [expr {$::RIFL_ST_TXDESC_BASE + 4*$link}]] }
proc rifl_rx_pkt_occ  {link} { return [rifl_rd [expr {$::RIFL_ST_RXPKT_BASE  + 4*$link}]] }

# ---- PRBS BIST (built-in self-test generator/checker) ----
proc rifl_prbs_err_cnt {link} { return [rifl_rd [expr {$::RIFL_ST_PRBS_ERR_BASE + 4*$link}]] }
proc rifl_prbs_occ     {link} { return [rifl_rd [expr {$::RIFL_ST_PRBS_OCC_BASE + 4*$link}]] }
# Configure the generators/checkers (write BEFORE enabling): seed, max length,
# min length.  Length = min + (lfsr & mask); the mask is the smallest 2^k-1 that
# covers (max-min), so a non-power-of-two max is rounded UP to a power-of-two
# range.  Same seed on all links so each link's checker matches its peer's gen.
proc rifl_prbs_config {seed maxlen {minlen 1}} {
  set span [expr {$maxlen - $minlen}]
  if {$span < 0} { set span 0 }
  set mask 0
  while {$mask < $span} { set mask [expr {($mask << 1) | 1}] }
  rifl_reg_wr $::RIFL_PRBS_SEED $seed
  rifl_reg_wr $::RIFL_PRBS_MASK [expr {$mask & 0xFFFF}]
  rifl_reg_wr $::RIFL_PRBS_MIN  [expr {($minlen & 0xFFFF) << 2}]
}
# Enable a per-link mask (bit L).  Optional perturb mask (bit L) makes link L's
# checker expect a different sequence than its peer sends -> guaranteed errors.
# The perturb is written first (enable low), then the enable rises, so the
# quasi-static config is stable before the per-link start edge (also forces a
# clean rising edge each call = a fresh run with zeroed counters).
proc rifl_prbs_enable {enmask {perturb 0}} {
  set pbits [expr {($perturb & 0xF) << 16}]
  rifl_reg_wr $::RIFL_CTRL1 $pbits
  after 20
  rifl_reg_wr $::RIFL_CTRL1 [expr {($enmask & 0xF) | $pbits}]
}
# Read ONE error record (3 x 256-bit beats = 24 JTAG beats) from link L at +0x4000.
# Returns the raw 192-hex string.  Two of the three words are the expected vs
# received 256-bit data; the third packs pkt/flit index, exp/rcv tkeep, and the
# mismatch-kind flags.  (Confirm the word/field order once on hardware.)
proc rifl_prbs_err_rec {link} {
  set addr [format 0x%08X [expr {[rifl_link_base $link] + 0x4000}]]
  catch { delete_hw_axi_txn [get_hw_axi_txns -quiet rifl_er] }
  create_hw_axi_txn rifl_er $::rifl_axi -address $addr -len 24 -type read
  run_hw_axi -quiet [get_hw_axi_txns rifl_er]
  set d [get_property DATA [get_hw_axi_txns rifl_er]]
  delete_hw_axi_txn [get_hw_axi_txns rifl_er]
  return $d
}

# ---- link status helpers ----
proc rifl_link_nibble {link} { return [expr {([rifl_rd $::RIFL_ST_RX_UP] >> ($link*4)) & 0xF}] }
proc rifl_link_is_up  {link} { return [expr {[rifl_link_nibble $link] == 0xF}] }
proc rifl_rx_occ      {link} { return [rifl_rd [expr {$::RIFL_ST_RXOCC_BASE + 4*$link}]] }
proc rifl_tkeep_occ   {link} { return [rifl_rd [expr {$::RIFL_ST_TKOCC_BASE + 4*$link}]] }

# read out and discard any residual RX data / tkeep / length so a test starts clean.
# Reads are chunked to <= 32 words (256 beats), the AXI4 max burst.
proc rifl_drain_all {} {
  for {set r 0} {$r < 4} {incr r} {
    set g 0; while {[set o [rifl_rx_occ $r]]     > 0 && $g < 128} { rifl_rx_burst $r [expr {$o>32?32:$o}] 0; incr g }
    set g 0; while {[set k [rifl_tkeep_occ $r]]  > 0 && $g < 128} { rifl_rx_burst $r [expr {$k>32?32:$k}] 1; incr g }
    set g 0; while {[set p [rifl_rx_pkt_occ $r]] > 0 && $g < 128} { rifl_rx_len   $r [expr {$p>32?32:$p}];   incr g }
  }
}

proc rifl_wait_links_up {{timeout_ms 8000}} {
  set t 0
  while {$t < $timeout_ms} {
    set all 1
    for {set l 0} {$l < 4} {incr l} { if {![rifl_link_is_up $l]} { set all 0; break } }
    if {$all} { return 1 }
    after 200; incr t 200
  }
  return 0
}

proc rifl_status {} {
  puts "  ctrl0      = 0x[rifl_reg_rd $::RIFL_CTRL0]  (bit0 axis_en, bit1 cc_rst, bit2 core_rst)"
  puts "  rx_up      = 0x[rifl_reg_rd $::RIFL_ST_RX_UP]   rx_aligned = 0x[rifl_reg_rd $::RIFL_ST_RX_ALIGNED]"
  puts "  rx_error   = 0x[rifl_reg_rd $::RIFL_ST_RX_ERROR]   tx_normal  = 0x[rifl_reg_rd $::RIFL_ST_TX_NORMAL]"
  for {set l 0} {$l < 4} {incr l} {
    puts [format "  link %d: up=%d  rx_occ=%d  tkeep_occ=%d" \
            $l [rifl_link_is_up $l] [rifl_rx_occ $l] [rifl_tkeep_occ $l]]
  }
}
