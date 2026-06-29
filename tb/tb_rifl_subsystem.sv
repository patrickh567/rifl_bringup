`timescale 1 ps / 1 ps
`default_nettype none

// -----------------------------------------------------------------------------
// tb_rifl_subsystem: testbench for rifl_subsystem.
//
// First (and only) test: send and receive a single-word packet on each RIFL link.
//
// The testbench drives rifl_subsystem's converter-side AXI ports (cc_*, one full AXI4
// per link, in that link's rifl_usr_clk domain) and the lite register-map port
// (m_axil, in init_clk).  The 4 RIFL links are connected in pairs over the GT
// serial (link 0<->1, 2<->3): each link's TX feeds its PEER's RX (peer = link ^ 1),
// so a packet transmitted on one link is received by its peer (no self-loopback).
//
// Sequence: reset RIFL -> wait for all links up -> reset converters/FIFOs ->
// enable streaming -> per link: AXI-write one word (transmit), poll RX occupancy,
// AXI-read one word (receive), check it matches.
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
  localparam logic [31:0] RX_DATA_ADDR = 32'h0000_0000;         // cc read, araddr[15]=0 -> RX data FIFO

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
  integer errors = 0;
  integer poll;
  logic [31:0] rdw;
  logic [255:0] word [num_gty_port_p];
  logic [255:0] got, expw;
  integer i;

  initial begin
    init_axi();

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
    end while ((rdw[gt_w_lp-1:0] != {gt_w_lp{1'b1}}) && (poll < 200000));
    if (rdw[gt_w_lp-1:0] != {gt_w_lp{1'b1}}) begin
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

    // 4) enable the AXI-Stream (TX drain) on all FIFOs (reg 0 bit 0)
    lite_wr(REG_CTRL0, 32'h0000_0001);

    // 5) transmit one word on each link, then receive it on the paired peer.
    //    A word sent on link i arrives at link (i^1)'s RX (the peer it is wired to).
    for (i = 0; i < num_gty_port_p; i++)
      word[i] = 256'hC0DE_C0DE_C0DE_C0DE_C0DE_C0DE_C0DE_C0DE + i;

    for (i = 0; i < num_gty_port_p; i++) begin
      axi_wr(i, 32'h0, word[i]);
      $display("[%0t] link %0d: transmitted 0x%064x", $time, i, word[i]);
    end

    for (i = 0; i < num_gty_port_p; i++) begin
      // link i receives the word transmitted by its peer (i^1)
      poll = 0;
      do begin
        lite_rd(STAT_RXOCC0 + i*4, rdw);
        poll++;
      end while ((rdw[15:0] == 16'd0) && (poll < 200000));
      if (rdw[15:0] == 16'd0) begin
        $error("[%0t] link %0d: timeout waiting for RX data from peer %0d", $time, i, i^1);
        errors++;
      end else begin
        axi_rd(i, RX_DATA_ADDR, got);
        expw = word[i ^ 1];
        if (got === expw)
          $display("[%0t] link %0d: received 0x%064x from peer %0d  PASS", $time, i, got, i^1);
        else begin
          $error("[%0t] link %0d: received 0x%064x expected 0x%064x (peer %0d)", $time, i, got, expw, i^1);
          errors++;
        end
      end
    end

    if (errors == 0) $display("==== TB PASSED: single-word packet on all %0d links ====", num_gty_port_p);
    else             $display("==== TB FAILED: %0d error(s) ====", errors);
    $finish;
  end

  // ---- global watchdog ----
  initial begin
    #50_000_000_000;   // 50 us
    $error("[%0t] global timeout", $time);
    $finish;
  end

endmodule

`default_nettype wire
