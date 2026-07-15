`timescale 1 ps / 1 ps
`default_nettype none

// -----------------------------------------------------------------------------
// tb_rifl_subsystem: testbench for rifl_subsystem.
//
// Test: buffer M packets on each RIFL link (packet p has PKT_WORDS+p 256-bit words,
// so they are different sizes), drain them, and check each is received correctly and
// boundary-framed on its peer.  Run-time plusargs: +PKT_WORDS=N (base size, default 1,
// max 256), +NUM_PKTS=M (packets buffered before draining, default 1, max 16).
//
// The testbench drives rifl_subsystem's converter-side AXI ports (cc_*, one full AXI4
// per link, in that link's rifl_usr_clk domain) and the lite register-map port
// (m_axil, in init_clk).  The 4 RIFL links are connected in pairs over the GT
// serial (link 0<->1, 2<->3): each link's TX feeds its PEER's RX (peer = link ^ 1),
// so a packet transmitted on one link is received by its peer (no self-loopback).
//
// Sequence: reset RIFL -> wait for all links up -> reset converters/FIFOs -> per link,
// with the stream disabled, write+COMMIT M packets (awaddr[15]=1 commits each packet's
// length as a descriptor) -> enable the stream so the descriptor FIFO drains each as
// its own TLAST packet to the peer -> per link, wait for M packets (rx_pkt_count), read
// each packet's length from the RX length FIFO (0xC000) and its words, and check all.
//
// NOTE: running this requires the real RIFL / GTY / firmware_bd (MMCM) / debug-core
// simulation models and the Xilinx unisim/secureip libraries; GT bring-up takes a
// long simulation time.  The paired links form proper RIFL peers (0<->1, 2<->3).
// -----------------------------------------------------------------------------
module tb_rifl_subsystem;

  localparam int unsigned num_gty_port_p    = 4;
  localparam int unsigned gt_serial_width_p = 4;
  localparam int unsigned axis_data_width_p = 256;
  localparam int unsigned gt_w_lp           = num_gty_port_p*gt_serial_width_p;

  // register map (M_AXI_4) byte offsets
  localparam logic [31:0] REG_CTRL0   = 32'h0000_0000;          // bit0 enable, bit1 cc_reset, bit2 core_reset
  localparam logic [31:0] STAT_RX_UP  = 32'h0000_0040;          // status reg 0
  localparam logic [31:0] STAT_RXOCC0 = 32'h0000_0040 + 32'd98*4; // status reg 98 (rx data occupancy, link 0)
  localparam logic [31:0] RX_DATA_ADDR = 32'h0000_0000;         // cc read,  araddr[15:14]=0x -> RX data FIFO
  localparam logic [31:0] RX_LEN_ADDR  = 32'h0000_C000;         // cc read,  araddr[15:14]=11 -> RX length FIFO (beat-count/packet)
  localparam logic [31:0] TX_COMMIT_ADDR = 32'h0000_8000;       // cc write, awaddr[15]=1     -> commit a TX packet descriptor
  localparam logic [31:0] STAT_RXPKT0 = 32'h0000_0040 + 32'd110*4; // status reg 110 (rx packet count, link 0)
  // PRBS BIST control (reg 1..4) + status (reg 114 err, reg 118 occ), per rifl_hw_lib.tcl
  localparam logic [31:0] REG_CTRL1     = 32'h0000_0004;        // [3:0] per-link enable, [8] clear, [19:16] perturb
  localparam logic [31:0] PRBS_MASK     = 32'h0000_0008;        // [15:0] length mask (2^k-1); len = min + (lfsr & mask)
  localparam logic [31:0] PRBS_SEED     = 32'h0000_000C;        // [31:0] PRBS + length seed
  localparam logic [31:0] PRBS_MIN      = 32'h0000_0010;        // [17:2] min length (beats)
  localparam logic [31:0] STAT_PRBSERR0 = 32'h0000_0040 + 32'd114*4; // reg 114 per-link corrupted-packet count
  localparam logic [31:0] STAT_PRBSOCC0 = 32'h0000_0040 + 32'd118*4; // reg 118 per-link error-record FIFO occupancy
  // ---- part (b): new clock-comp / RX-overflow status regs (commit 77e63a4) ----
  localparam logic [31:0] STAT_COMP_LOCK0 = 32'h0000_0040 + 32'd122*4; // reg 122+i comp_locked (telemetry)
  localparam logic [31:0] STAT_COMP_TYPE0 = 32'h0000_0040 + 32'd126*4; // reg 126+i comp_type  (ppm sign, telemetry)
  localparam logic [31:0] STAT_RXOVF0     = 32'h0000_0040 + 32'd130*4; // reg 130+i rx async-FIFO overflow (sticky)

  // ---- input clocks ----
  logic ext_refclk_p = 1'b0;        // 200 MHz LVDS -> firmware_bd MMCM
  logic gt_ref_clk_p = 1'b0;        // 156.25 MHz GT refclk (shared to all links here)
  always #2500 ext_refclk_p = ~ext_refclk_p;   // 200 MHz (5000 ps period)
  always #3200 gt_ref_clk_p = ~gt_ref_clk_p;   // 156.25 MHz (6400 ps period)
  wire ext_refclk_n = ~ext_refclk_p;
  wire [num_gty_port_p-1:0] gt_ref_i_clk_p = {num_gty_port_p{gt_ref_clk_p}};
  wire [num_gty_port_p-1:0] gt_ref_i_clk_n = ~gt_ref_i_clk_p;

  // ---- DUT I/O ----
  wire [1:0]      led;
  wire [gt_w_lp-1:0] gt_txn, gt_txp;
  wire [gt_w_lp-1:0] gt_rxn, gt_rxp;
  // Connect the 4 RIFL links in pairs (0<->1, 2<->3): each link's RX serial is
  // driven by its PEER's TX serial (peer = link ^ 1).  No self-loopback.
  for (genvar g = 0; g < num_gty_port_p; g++) begin: pair_lb
    localparam int peer = g ^ 1;
    assign gt_rxp[g*gt_serial_width_p +: gt_serial_width_p] = gt_txp[peer*gt_serial_width_p +: gt_serial_width_p];
    assign gt_rxn[g*gt_serial_width_p +: gt_serial_width_p] = gt_txn[peer*gt_serial_width_p +: gt_serial_width_p];
  end

  // ---- part (b) item 1: idle-insertion cadence probe on link 0's clock_compensate.
  // The fixed-rate comp asserts `compensate` 1 cycle per 2^10=1024 tx_frame_clk cycles
  // (COMP_PERIOD_LOG2=10).  Count assertions vs cycles over a window while cad_run is set.
  // Hierarchy: dut -> RIFL_inst_0 (`RIFL_MACRO(0)) -> inst (RIFL) -> u_clock_compensate.
  logic   cad_run = 1'b0;
  longint cad_cyc = 0, cad_hi = 0;
  int     ovf_ns  = 0;    // +OVF_NS>0 activates the item-4 overflow-escalation injection (bind, end of file)
  always @(posedge dut.RIFL_inst_0.inst.u_clock_compensate.tx_frame_clk) if (cad_run) begin
    cad_cyc = cad_cyc + 1;
    if (dut.RIFL_inst_0.inst.u_clock_compensate.compensate) cad_hi = cad_hi + 1;
  end

  wire                      init_clk;
  logic                     axi_aresetn = 1'b0;  // domain-1 reset; TB-driven (stands in for top VIO)
  wire                      cc_s_aresetn;
  wire [num_gty_port_p-1:0] usr_clk;
  wire [num_gty_port_p-1:0] usr_rst;
  wire [num_gty_port_p-1:0] cc_m_aresetn;

  // ---- cc_* : full AXI4 per link (testbench is master) ----
  logic [31:0]  cc_awaddr   [num_gty_port_p];
  logic [7:0]   cc_awlen    [num_gty_port_p];
  logic [2:0]   cc_awsize   [num_gty_port_p];
  logic [1:0]   cc_awburst  [num_gty_port_p];
  logic [0:0]   cc_awlock   [num_gty_port_p];
  logic [3:0]   cc_awcache  [num_gty_port_p];
  logic [2:0]   cc_awprot   [num_gty_port_p];
  logic [3:0]   cc_awqos    [num_gty_port_p];
  logic [3:0]   cc_awregion [num_gty_port_p];
  logic         cc_awvalid  [num_gty_port_p];
  wire          cc_awready  [num_gty_port_p];
  logic [255:0] cc_wdata    [num_gty_port_p];
  logic [31:0]  cc_wstrb    [num_gty_port_p];
  logic         cc_wlast    [num_gty_port_p];
  logic         cc_wvalid   [num_gty_port_p];
  wire          cc_wready   [num_gty_port_p];
  wire  [1:0]   cc_bresp    [num_gty_port_p];
  wire          cc_bvalid   [num_gty_port_p];
  logic         cc_bready   [num_gty_port_p];
  logic [31:0]  cc_araddr   [num_gty_port_p];
  logic [7:0]   cc_arlen    [num_gty_port_p];
  logic [2:0]   cc_arsize   [num_gty_port_p];
  logic [1:0]   cc_arburst  [num_gty_port_p];
  logic [0:0]   cc_arlock   [num_gty_port_p];
  logic [3:0]   cc_arcache  [num_gty_port_p];
  logic [2:0]   cc_arprot   [num_gty_port_p];
  logic [3:0]   cc_arqos    [num_gty_port_p];
  logic [3:0]   cc_arregion [num_gty_port_p];
  logic         cc_arvalid  [num_gty_port_p];
  wire          cc_arready  [num_gty_port_p];
  wire  [255:0] cc_rdata    [num_gty_port_p];
  wire  [1:0]   cc_rresp    [num_gty_port_p];
  wire          cc_rlast    [num_gty_port_p];
  wire          cc_rvalid   [num_gty_port_p];
  logic         cc_rready   [num_gty_port_p];

  // ---- m_axil : AXI4-Lite (testbench is master) ----
  logic [31:0]  l_awaddr;  logic [2:0] l_awprot;  logic l_awvalid;  wire l_awready;
  logic [31:0]  l_wdata;   logic [3:0] l_wstrb;   logic l_wvalid;   wire l_wready;
  wire  [1:0]   l_bresp;   wire        l_bvalid;  logic l_bready;
  logic [31:0]  l_araddr;  logic [2:0] l_arprot;  logic l_arvalid;  wire l_arready;
  wire  [31:0]  l_rdata;   wire  [1:0] l_rresp;   wire  l_rvalid;   logic l_rready;

  // ---- DUT ----
  rifl_subsystem #(
     .gt_serial_width_p(gt_serial_width_p)
    ,.num_gty_port_p(num_gty_port_p)
    ,.axis_data_width_p(axis_data_width_p)
  ) dut (
     .ext_refclk_n(ext_refclk_n), .ext_refclk_p(ext_refclk_p), .led(led)
    ,.gt_ref_i_clk_n(gt_ref_i_clk_n), .gt_ref_i_clk_p(gt_ref_i_clk_p)
    ,.rifl_gt_o_gt_rxn_in(gt_rxn), .rifl_gt_o_gt_rxp_in(gt_rxp)
    ,.rifl_gt_o_gt_txn_out(gt_txn), .rifl_gt_o_gt_txp_out(gt_txp)
    ,.init_clk_o(init_clk), .axi_aresetn_i(axi_aresetn), .cc_s_aresetn_o(cc_s_aresetn)
    ,.usr_clk_o(usr_clk), .usr_rst_o(usr_rst), .cc_m_aresetn_o(cc_m_aresetn)
    ,.cc_awaddr(cc_awaddr), .cc_awlen(cc_awlen), .cc_awsize(cc_awsize)
    ,.cc_awburst(cc_awburst), .cc_awlock(cc_awlock), .cc_awcache(cc_awcache)
    ,.cc_awprot(cc_awprot), .cc_awqos(cc_awqos), .cc_awregion(cc_awregion)
    ,.cc_awvalid(cc_awvalid), .cc_awready(cc_awready)
    ,.cc_wdata(cc_wdata), .cc_wstrb(cc_wstrb), .cc_wlast(cc_wlast)
    ,.cc_wvalid(cc_wvalid), .cc_wready(cc_wready)
    ,.cc_bresp(cc_bresp), .cc_bvalid(cc_bvalid), .cc_bready(cc_bready)
    ,.cc_araddr(cc_araddr), .cc_arlen(cc_arlen), .cc_arsize(cc_arsize)
    ,.cc_arburst(cc_arburst), .cc_arlock(cc_arlock), .cc_arcache(cc_arcache)
    ,.cc_arprot(cc_arprot), .cc_arqos(cc_arqos), .cc_arregion(cc_arregion)
    ,.cc_arvalid(cc_arvalid), .cc_arready(cc_arready)
    ,.cc_rdata(cc_rdata), .cc_rresp(cc_rresp), .cc_rlast(cc_rlast)
    ,.cc_rvalid(cc_rvalid), .cc_rready(cc_rready)
    ,.m_axil_awaddr(l_awaddr), .m_axil_awprot(l_awprot)
    ,.m_axil_awvalid(l_awvalid), .m_axil_awready(l_awready)
    ,.m_axil_wdata(l_wdata), .m_axil_wstrb(l_wstrb)
    ,.m_axil_wvalid(l_wvalid), .m_axil_wready(l_wready)
    ,.m_axil_bresp(l_bresp), .m_axil_bvalid(l_bvalid), .m_axil_bready(l_bready)
    ,.m_axil_araddr(l_araddr), .m_axil_arprot(l_arprot)
    ,.m_axil_arvalid(l_arvalid), .m_axil_arready(l_arready)
    ,.m_axil_rdata(l_rdata), .m_axil_rresp(l_rresp)
    ,.m_axil_rvalid(l_rvalid), .m_axil_rready(l_rready)
  );

  // ---- idle / init all driven signals ----
  task automatic init_axi;
    integer k;
    begin
      axi_aresetn=1'b0;   // assert domain-1 reset (design_1 + register map)
      l_awvalid=0; l_wvalid=0; l_bready=0; l_arvalid=0; l_rready=0;
      l_awaddr=0; l_awprot=0; l_wdata=0; l_wstrb=0; l_araddr=0; l_arprot=0;
      for (k=0;k<num_gty_port_p;k++) begin
        cc_awvalid[k]=0; cc_wvalid[k]=0; cc_bready[k]=0; cc_arvalid[k]=0; cc_rready[k]=0;
        cc_awaddr[k]=0; cc_awlen[k]=0; cc_awsize[k]=3'd5; cc_awburst[k]=2'b01;
        cc_awlock[k]=0; cc_awcache[k]=0; cc_awprot[k]=0; cc_awqos[k]=0; cc_awregion[k]=0;
        cc_wdata[k]=0; cc_wstrb[k]='1; cc_wlast[k]=0;
        cc_araddr[k]=0; cc_arlen[k]=0; cc_arsize[k]=3'd5; cc_arburst[k]=2'b01;
        cc_arlock[k]=0; cc_arcache[k]=0; cc_arprot[k]=0; cc_arqos[k]=0; cc_arregion[k]=0;
      end
    end
  endtask

  // ---- AXI4-Lite write (register map) ----
  task automatic lite_wr(input logic [31:0] addr, input logic [31:0] data);
    begin
      @(posedge init_clk);
      l_awaddr<=addr; l_awvalid<=1'b1; l_wdata<=data; l_wstrb<=4'hF; l_wvalid<=1'b1; l_bready<=1'b1;
      @(posedge init_clk);
      while (!l_awready) @(posedge init_clk); l_awvalid<=1'b0;
      while (!l_wready)  @(posedge init_clk); l_wvalid<=1'b0;
      while (!l_bvalid)  @(posedge init_clk); l_bready<=1'b0;
      @(posedge init_clk);
    end
  endtask

  // ---- AXI4-Lite read (register map) ----
  task automatic lite_rd(input logic [31:0] addr, output logic [31:0] data);
    begin
      @(posedge init_clk);
      l_araddr<=addr; l_arvalid<=1'b1; l_rready<=1'b1;
      @(posedge init_clk);
      while (!l_arready) @(posedge init_clk); l_arvalid<=1'b0;
      while (!l_rvalid)  @(posedge init_clk);
      data = l_rdata; l_rready<=1'b0;
      @(posedge init_clk);
    end
  endtask

  // ---- full-AXI single-word write on link `lk` (transmit) ----
  task automatic axi_wr(input int lk, input logic [31:0] addr, input logic [255:0] data);
    bit aw_done, w_done;
    begin
      @(posedge usr_clk[lk]);
      cc_awaddr[lk]<=addr; cc_awlen[lk]<=8'd0; cc_awvalid[lk]<=1'b1;
      cc_wdata[lk]<=data; cc_wstrb[lk]<='1; cc_wlast[lk]<=1'b1; cc_wvalid[lk]<=1'b1;
      cc_bready[lk]<=1'b1;
      aw_done=0; w_done=0;
      @(posedge usr_clk[lk]);
      while (!(aw_done && w_done)) begin
        if (!aw_done && cc_awready[lk]) begin cc_awvalid[lk]<=1'b0; aw_done=1; end
        if (!w_done  && cc_wready[lk] ) begin cc_wvalid[lk] <=1'b0; w_done=1; end
        if (!(aw_done && w_done)) @(posedge usr_clk[lk]);
      end
      while (!cc_bvalid[lk]) @(posedge usr_clk[lk]);
      cc_bready[lk]<=1'b0;
      @(posedge usr_clk[lk]);
    end
  endtask

  // ---- full-AXI single-word read on link `lk` (receive) ----
  task automatic axi_rd(input int lk, input logic [31:0] addr, output logic [255:0] data);
    begin
      @(posedge usr_clk[lk]);
      cc_araddr[lk]<=addr; cc_arlen[lk]<=8'd0; cc_arvalid[lk]<=1'b1; cc_rready[lk]<=1'b1;
      @(posedge usr_clk[lk]);
      while (!cc_arready[lk]) @(posedge usr_clk[lk]); cc_arvalid[lk]<=1'b0;
      while (!cc_rvalid[lk])  @(posedge usr_clk[lk]);
      data = cc_rdata[lk]; cc_rready[lk]<=1'b0;
      @(posedge usr_clk[lk]);
    end
  endtask

  // ---- test ----
  localparam int MAX_PKT_WORDS = 256;            // largest single packet (got_arr); data FIFO is 512 deep
  localparam int MAX_PKTS      = 16;             // most packets buffered per link before draining
  localparam int FIFO_BUDGET   = 500;            // keep total buffered words under the 512-deep data FIFO
  integer errors = 0;
  integer poll;
  integer i, j, p, psz, total, rxlen, rd_n;
  int     pkt_words;                             // base packet length in 256-bit words (+PKT_WORDS=N)
  int     num_pkts;                              // packets buffered per link before drain (+NUM_PKTS=M)
  logic         link_ok;
  logic [31:0]  rdw;
  logic [255:0] word    [num_gty_port_p][MAX_PKTS][MAX_PKT_WORDS];
  logic [255:0] got_arr [MAX_PKT_WORDS];
  logic [255:0] len_word;                        // RX length-FIFO entry (received packet's beat-count)
  int          prbs_us;                          // PRBS BIST soak duration in us (+PRBS_US=N; 0 => packet mode)
  int          prbs_maxlen;                       // PRBS max packet length in beats (+PRBS_MAXLEN)
  logic [31:0] prbs_seed, prbs_mask, occ_rdw;    // PRBS seed, derived length mask, occupancy read
  integer      span;

  initial begin
    init_axi();

    // Run-time selectable: +PKT_WORDS=N (base packet size, words) and +NUM_PKTS=M
    // (packets buffered per link before draining).  Packet p has size N+p, so M>1
    // pushes several DIFFERENT-size packets through the descriptor FIFO at once.
    if (!$value$plusargs("PKT_WORDS=%d", pkt_words)) pkt_words = 1;
    if (!$value$plusargs("NUM_PKTS=%d",  num_pkts )) num_pkts  = 1;
    if (pkt_words < 1) pkt_words = 1;
    if (num_pkts  < 1) num_pkts  = 1;
    if (num_pkts  > MAX_PKTS)      num_pkts  = MAX_PKTS;
    if (pkt_words > MAX_PKT_WORDS) pkt_words = MAX_PKT_WORDS;
    // largest single packet (N+M-1) must fit got_arr; total buffered words must fit the FIFO
    while (num_pkts > 1 && (pkt_words + num_pkts - 1) > MAX_PKT_WORDS) num_pkts--;
    while (num_pkts > 1 && (num_pkts*pkt_words + (num_pkts*(num_pkts-1))/2) > FIFO_BUDGET) num_pkts--;
    total = num_pkts*pkt_words + (num_pkts*(num_pkts-1))/2;
    $display("[%0t] tb_rifl_subsystem: PKT_WORDS=%0d NUM_PKTS=%0d (sizes %0d..%0d, %0d words/link total)",
             $time, pkt_words, num_pkts, pkt_words, pkt_words+num_pkts-1, total);

    // +PRBS_US=N (>0) selects PRBS BIST soak mode (built-in generator/checker) instead
    // of the packet test; +PRBS_MAXLEN sets the max random packet length, +PRBS_SEED the seed.
    if (!$value$plusargs("PRBS_US=%d",     prbs_us))     prbs_us     = 0;
    if (!$value$plusargs("PRBS_MAXLEN=%d", prbs_maxlen)) prbs_maxlen = 64;
    if (!$value$plusargs("PRBS_SEED=%h",   prbs_seed))   prbs_seed   = 32'hDEAD_BEEF;
    if (!$value$plusargs("OVF_NS=%d",      ovf_ns))      ovf_ns      = 0;   // item-4 overflow demo (link 0)
    if (prbs_maxlen < 1) prbs_maxlen = 1;

    // wait for init_clk (firmware_bd MMCM) to start toggling
    repeat (50) @(posedge init_clk);

    // release the domain-1 reset (design_1 + register map); on hardware this is the
    // JTAG VIO in top_rifl -- here the TB drives axi_aresetn directly.
    axi_aresetn <= 1'b1;
    repeat (10) @(posedge init_clk);

    // 1) everything-else reset (core_reset, control reg 0 bit 2)
    lite_wr(REG_CTRL0, 32'h0000_0004);
    repeat (100) @(posedge init_clk);
    lite_wr(REG_CTRL0, 32'h0000_0000);

    // 2) wait for all links/channels up (status reg 0 = rx_up, bit 4*link+channel)
    poll = 0;
    do begin
      lite_rd(STAT_RX_UP, rdw);
      poll++;
      if (poll % 1000 == 0) $display("[%0t] waiting for rx_up: 0x%08x", $time, rdw);
    // case-inequality (!==): rx_up lives in the GT recovered-clock domain and
    // reads X until that clock starts, so a plain `!=` ((X != 1)->X->false) would
    // treat an all-X status as "links up" and march on over a dead link.  `!==`
    // keeps polling until the bits are genuinely all 1.
    end while ((rdw[gt_w_lp-1:0] !== {gt_w_lp{1'b1}}) && (poll < 200000));
    if (rdw[gt_w_lp-1:0] !== {gt_w_lp{1'b1}}) begin
      $error("[%0t] timeout waiting for RIFL links up (rx_up=0x%08x)", $time, rdw);
      errors++;
    end else begin
      $display("[%0t] all RIFL links up (rx_up=0x%08x)", $time, rdw);
    end

    // 3) reset the converters + FIFOs now that all clocks are up (reg 0 bit 1)
    lite_wr(REG_CTRL0, 32'h0000_0002);
    repeat (50) @(posedge init_clk);
    lite_wr(REG_CTRL0, 32'h0000_0000);
    repeat (50) @(posedge init_clk);

    // ===== PRBS BIST soak mode (+PRBS_US>0): drive the built-in per-link PRBS
    //       generator/checker for a long random sequence, confirm ZERO errors on
    //       every link, then perturb link 0's checker to prove it actually detects
    //       mismatches.  (Falls through to the packet test when +PRBS_US=0.) =====
    if (prbs_us > 0) begin
      // random packet length = 1 + (lfsr & mask); grow mask to a 2^k-1 span >= maxlen-1
      span = prbs_maxlen - 1; if (span < 0) span = 0;
      prbs_mask = 32'h0; while (prbs_mask < span) prbs_mask = (prbs_mask << 1) | 32'h1;
      lite_wr(PRBS_SEED, prbs_seed);
      lite_wr(PRBS_MASK, prbs_mask & 32'h0000_FFFF);
      lite_wr(PRBS_MIN,  (32'd1 & 32'h0000_FFFF) << 2);         // min length 1 beat
      // enable PRBS on all 4 links (perturb=0); the enable rising edge zeroes counters
      lite_wr(REG_CTRL1, 32'h0000_0000);
      repeat (20) @(posedge init_clk);
      lite_wr(REG_CTRL1, 32'h0000_000F);
      $display("[%0t] PRBS enabled on all 4 links (seed=0x%08x, lengths 1..%0d beats); soaking %0d us ...",
               $time, prbs_seed, prbs_maxlen, prbs_us);
      cad_run = 1'b1;                                            // (b) item 1: measure comp cadence during soak
      #(prbs_us * 1_000_000);                                    // <-- the long PRBS sequence
      cad_run = 1'b0;
      lite_wr(REG_CTRL1, 32'h0000_0000);                         // graceful disable
      repeat (500) @(posedge init_clk);
      // healthy result: every link's corrupted-packet count must be 0
      for (i = 0; i < num_gty_port_p; i++) begin
        lite_rd(STAT_PRBSERR0 + i*4, rdw);
        lite_rd(STAT_PRBSOCC0 + i*4, occ_rdw);
        $display("[%0t] link %0d: prbs_err=%0d errfifo_occ=%0d  %s", $time, i, rdw, occ_rdw,
                 (rdw==0)?"OK":((ovf_ns>0 && i==0)?"(expected: item-4 overflow injection)":"<-- ERRORS"));
        if (rdw !== 32'd0 && !(ovf_ns > 0 && i == 0)) errors++;   // link 0 errors are the injected item-4 fault
      end
      // ===== part (b): clock-comp + RX-overflow verification (commit 77e63a4) =====
      // item 2 (transparency): the soak ran with fixed-rate idle insertion ACTIVE
      //   (compensate ~1/1024 frames) yet every link is 0 errors -> insertions do not
      //   corrupt the stream; confirm the elastic buffer never overflowed.
      // item 5 (telemetry): read per-link comp_locked / comp_type / overflow CSRs.  The
      //   comp measurement needs ~84 ms to resolve (bench-only), so comp_type stays
      //   UNKNOWN(0) / comp_locked=0 in a short sim -- the datapath does not depend on it.
      $display("[%0t] (b) clock-comp + overflow telemetry (post-soak):", $time);
      for (i = 0; i < num_gty_port_p; i++) begin
        logic [31:0] cl, ct, ov;
        lite_rd(STAT_COMP_LOCK0 + i*4, cl);
        lite_rd(STAT_COMP_TYPE0 + i*4, ct);
        lite_rd(STAT_RXOVF0     + i*4, ov);
        $display("[%0t]   link %0d: comp_locked=%0d comp_type=%0d rx_async_fifo_overflow=0x%02x %s",
                 $time, i, cl[0], ct[1:0], ov[7:0], (ov===32'd0)?"(no overflow)":"<-- OVERFLOW");
        if (ov !== 32'd0) begin
          if (ovf_ns > 0 && i == 0)
            $display("[%0t]   -> (b) item4: link 0 overflow ESCALATION CONFIRMED (sticky 0x%02x) -- the forced write-while-full drop, previously silent, is now flagged and escalated to rx_error/retransmit", $time, ov[7:0]);
          else begin errors++; $error("[%0t] link %0d RX elastic-buffer OVERFLOW on a clean link", $time, i); end
        end
      end
      // item 4 recovery: after the forced overflow the link must survive via retransmit --
      // confirm all links still up, then a cleared re-soak has 0 new errors (checker re-locked).
      if (ovf_ns > 0) begin
        lite_rd(STAT_RX_UP, rdw);
        $display("[%0t] (b) item4 recovery: rx_up=0x%04x after overflow %s", $time, rdw[15:0], (rdw[15:0]==16'hffff)?"(all links still up)":"<-- A LINK DROPPED");
        if (rdw[15:0] !== 16'hffff) begin errors++; $error("[%0t] a link dropped after overflow -- no recovery", $time); end
        lite_wr(REG_CTRL1, 32'h0000_0100);                       // clear counts + error FIFO
        lite_wr(REG_CTRL1, 32'h0000_000F);                       // re-enable, counters cleared
        #(20 * 1_000_000);                                       // clean re-soak
        lite_wr(REG_CTRL1, 32'h0000_0000);
        repeat (500) @(posedge init_clk);
        lite_rd(STAT_PRBSERR0, rdw);                             // link 0's checker (it took the drop)
        $display("[%0t] (b) item4 recovery re-soak: link 0 err=%0d (expect 0 = checker re-locked after retransmit)", $time, rdw);
        if (rdw !== 32'd0) begin errors++; $error("[%0t] checker did not re-lock after overflow recovery", $time); end
      end
      // item 1 (cadence): compensate should have asserted ~cad_cyc/1024 times.
      if (cad_hi == 0)
        $display("[%0t] (b) item1 cadence: soak too short to observe an insertion (need >~10.5us of soak); cad_cyc=%0d", $time, cad_cyc);
      else begin
        $display("[%0t] (b) item1 cadence: compensate fired %0d times / %0d tx_frame_clk cycles = 1 per %0d (expect ~1024)",
                 $time, cad_hi, cad_cyc, cad_cyc/cad_hi);
        if ((cad_cyc/cad_hi) < 900 || (cad_cyc/cad_hi) > 1200) begin errors++; $error("[%0t] comp cadence off -- expect ~1 insertion per 1024 frames", $time); end
      end
      // liveness sanity: inject bit errors into link 0's TX (reg1[16]=force_error).  The
      // self-synchronizing BIST corrupts the TRANSMITTED stream, so the errors surface at
      // the PEER link's checker (link 0 -> link 1 = link 0^1), not at link 0 itself.
      lite_wr(REG_CTRL1, 32'h0001_0000);                         // force-error link 0, enable low
      repeat (20) @(posedge init_clk);
      lite_wr(REG_CTRL1, 32'h0001_000F);                         // enable all + force-error link 0
      #(20 * 1_000_000);
      lite_wr(REG_CTRL1, 32'h0000_0000);
      repeat (500) @(posedge init_clk);
      lite_rd(STAT_PRBSERR0 + 32'd1*4, rdw);                     // PEER = link 1 sees link 0's corruption
      lite_rd(STAT_PRBSOCC0 + 32'd1*4, occ_rdw);
      $display("[%0t] forced-error link 0 -> peer link 1: prbs_err=%0d errfifo_occ=%0d (expect > 0)", $time, rdw, occ_rdw);
      if (rdw === 32'd0) begin errors++; $error("[%0t] forced error NOT detected at peer link 1 -- checker inactive", $time); end
      if (errors == 0) $display("==== TB PASSED: PRBS soak %0d us, 0 errors on all 4 links; forced error caught ====", prbs_us);
      else             $display("==== TB FAILED: %0d error(s) in PRBS test ====", errors);
      $finish;
    end

    // 4) FILL each link with NUM_PKTS packets (packet p has pkt_words+p words) and COMMIT
    //    each, all with the AXI-Stream drain DISABLED.  TX framing is descriptor-driven:
    //    writes to awaddr[15]==0 push data words (accumulating the running length); a
    //    write to awaddr[15]==1 (TX_COMMIT_ADDR) records that length as one descriptor and
    //    begins the next packet.  Several different-size packets thus sit buffered;
    //    enabling the drain releases each as its own TLAST-bounded packet.  Each word is
    //    unique per (link,packet,beat) -> ordering + framing + peer-pairing all checked.
    for (i = 0; i < num_gty_port_p; i++)
      for (p = 0; p < num_pkts; p++)
        for (j = 0; j < pkt_words + p; j++)
          word[i][p][j] = 256'hC0DE_C0DE_C0DE_C0DE_C0DE_C0DE_C0DE_C0DE + i*65536 + p*256 + j;

    for (i = 0; i < num_gty_port_p; i++) begin
      for (p = 0; p < num_pkts; p++) begin
        for (j = 0; j < pkt_words + p; j++) axi_wr(i, 32'h0, word[i][p][j]); // DATA   (awaddr[15]=0)
        axi_wr(i, TX_COMMIT_ADDR, 256'h0);                                   // COMMIT (awaddr[15]=1)
      end
      $display("[%0t] link %0d: filled+committed %0d packet(s), sizes %0d..%0d words", $time, i, num_pkts, pkt_words, pkt_words+num_pkts-1);
    end

    // 5) enable the AXI-Stream drain on all FIFOs (reg 0 bit 0): each TX FIFO now
    //    releases its buffered packet to its peer over the RIFL link.
    lite_wr(REG_CTRL0, 32'h0000_0001);

    // 6) on each link, wait for all NUM_PKTS packets from its peer (rx_pkt_count, reg
    //    110+i), then read them back boundary-aware: per packet, read its framed length
    //    from the RX length FIFO (0xC000), confirm it equals pkt_words+p, then read that
    //    many data words and check each against what the peer sent (in order).
    for (i = 0; i < num_gty_port_p; i++) begin
      poll = 0;
      do begin
        lite_rd(STAT_RXPKT0 + i*4, rdw);
        poll++;
      end while ((rdw[15:0] < num_pkts) && (poll < 400000));
      if (rdw[15:0] < num_pkts) begin
        $error("[%0t] link %0d: timeout waiting for %0d packets from peer %0d (rx_pkt_count=%0d)", $time, i, num_pkts, i^1, rdw[15:0]);
        errors++;
      end else begin
        link_ok = 1'b1;
        for (p = 0; p < num_pkts; p++) begin
          psz = pkt_words + p;                          // expected size of peer's packet p
          // packet-boundary check: the length-FIFO entry is this packet's beat-count
          axi_rd(i, RX_LEN_ADDR, len_word);
          rxlen = len_word[15:0];
          if (rxlen !== psz[15:0]) begin
            link_ok = 1'b0; errors++;
            $error("[%0t] link %0d pkt %0d: received length %0d, expected %0d (peer %0d)",
                   $time, i, p, rxlen, psz, i^1);
          end
          // read the words this packet actually carried (keeps FIFOs in sync), check each
          rd_n = (rxlen > MAX_PKT_WORDS) ? MAX_PKT_WORDS : rxlen;
          for (j = 0; j < rd_n; j++) begin
            axi_rd(i, RX_DATA_ADDR, got_arr[j]);
            if (j < psz && got_arr[j] !== word[i ^ 1][p][j]) begin
              link_ok = 1'b0; errors++;
              $error("[%0t] link %0d pkt %0d word %0d: received 0x%064x expected 0x%064x (peer %0d)",
                     $time, i, p, j, got_arr[j], word[i^1][p][j], i^1);
            end
          end
        end
        if (link_ok)
          $display("[%0t] link %0d: received %0d packet(s) (sizes %0d..%0d, lengths ok) from peer %0d, all words match  PASS",
                   $time, i, num_pkts, pkt_words, pkt_words+num_pkts-1, i^1);
      end
    end

    if (errors == 0) $display("==== TB PASSED: %0d packet(s)/link (sizes %0d..%0d words) on all %0d links ====", num_pkts, pkt_words, pkt_words+num_pkts-1, num_gty_port_p);
    else             $display("==== TB FAILED: %0d error(s) (PKT_WORDS=%0d NUM_PKTS=%0d) ====", errors, pkt_words, num_pkts);
    $finish;
  end

  // ---- global watchdog ----
  // Scales with packet size: link bring-up is ~36 us, the single-word test passes
  // ~38 us, and larger packets add ~1 us/word.  (timescale is 1ps, so the original
  // `#50_000_000_000 // 50 us` was actually 50 ms.)
  initial begin
    int wpw, wnp, wtot, wprbs;
    if (!$value$plusargs("PKT_WORDS=%d", wpw))   wpw   = 1;
    if (!$value$plusargs("NUM_PKTS=%d",  wnp))   wnp   = 1;
    if (!$value$plusargs("PRBS_US=%d",   wprbs)) wprbs = 0;
    if (wpw < 1) wpw = 1;  if (wpw > 256) wpw = 256;
    if (wnp < 1) wnp = 1;  if (wnp > 16)  wnp = 16;
    wtot = wnp*wpw + (wnp*(wnp-1))/2;   // total buffered words/link
    if (wprbs > 0) #((wprbs + 120) * 1_000_000);   // bring-up + PRBS soak + forced-error + margin
    else           #((80 + wtot) * 1_000_000);     // ~80us bring-up + ~1us/word, generous
    $error("[%0t] global timeout (PKT_WORDS=%0d NUM_PKTS=%0d PRBS_US=%0d)", $time, wpw, wnp, wprbs);
    $finish;
  end

endmodule

`default_nettype wire

// ---- part (b) item 4: overflow-escalation fault injector (bind into every rifl_rx) ----
// With +OVF_NS=N (>0), force link 0's RX elastic-buffer write-side ready (afifo_tready)
// low for N ns during the soak -- exactly the write-while-full fault the commit's item-4
// verification calls for.  The bound module UPWARD-references the parent rifl_rx's
// afifo_tready (no fragile hierarchical path needed) and self-gates to link 0 via its own
// %m.  Expect: sticky rx_async_fifo_overflow latches (CSR 0x248), rx_error escalates to a
// retransmit, and the link recovers -- the drop is no longer silent.  +OVF_AT_NS sets when.
module ovf_inject(ref logic tready);   // tready is bound to the parent rifl_rx.afifo_tready (a var)
  int ovf_ns = 0, ovf_at_ns = 50000;
  function automatic bit has_sub(input string s, input string sub);
    has_sub = 1'b0;
    if (sub.len() == 0 || sub.len() > s.len()) return;
    for (int k = 0; k + sub.len() <= s.len(); k++)
      if (s.substr(k, k+sub.len()-1) == sub) begin has_sub = 1'b1; return; end
  endfunction
  initial begin
    if (!$value$plusargs("OVF_NS=%d",    ovf_ns))    ovf_ns    = 0;
    if (!$value$plusargs("OVF_AT_NS=%d", ovf_at_ns)) ovf_at_ns = 50000;
    if (has_sub($sformatf("%m"), "RIFL_inst_0.")) $display("OVFPATH %m");   // path hedge
    if (ovf_ns > 0 && has_sub($sformatf("%m"), "RIFL_inst_0.")) begin
      #(ovf_at_ns * 1ns);
      $display("[%0t] OVF_INJECT %m: forcing afifo_tready=0 for %0d ns (write-while-full)", $time, ovf_ns);
      force tready = 1'b0;
      #(ovf_ns * 1ns);
      release tready;
      $display("[%0t] OVF_INJECT %m: released afifo_tready", $time);
    end
  end
endmodule

bind rifl_rx ovf_inject u_ovf_inject(.tready(afifo_tready));
