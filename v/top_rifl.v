`timescale 1 ps / 1 ps
`default_nettype none

// -----------------------------------------------------------------------------
// top_rifl: top level for the RIFL standalone design, refactored into three
// modules connected here:
//
//   axi_jtag_master            -- the AXI-JTAG block design (design_1): JTAG-to-AXI
//                                 master -> 4x M_AXI_0..3 (full) + M_AXI_4 (lite),
//                                 in the init_clk domain.
//   rifl_axi_clock_converters  -- the 4 per-link AXI clock converters, each crossing
//                                 one M_AXI from init_clk into rifl_usr_clk[i].
//   rifl_subsystem                  -- everything else: RIFL IPs + GTs, per-link TX/RX
//                                 FIFOs, register map, resets, event/occupancy
//                                 status, ILAs, and clock generation (firmware_bd).
//
// Data flow per link: axi_jtag_master M_AXI_i -> converters -> rifl_subsystem
//   (writes transmit, reads receive).  M_AXI_4 (lite) goes straight to rifl_subsystem's
//   register map (init_clk, no converter).  rifl_subsystem sources init_clk + the
//   converter/usr resets; the design_1 reset (domain 1) is the top-level VIO below.
//
// Per-link AXI buses crossing the module boundaries are carried as unpacked arrays.
// -----------------------------------------------------------------------------
module top_rifl
#(
    parameter gt_serial_width_p = 4
  , parameter num_gty_port_p = 4
  , parameter axis_data_width_p = 256
)
(
    input  wire       ext_refclk_n
  , input  wire       ext_refclk_p
  , output wire [1:0] led

  , input  wire [num_gty_port_p-1:0] gt_ref_i_clk_n
  , input  wire [num_gty_port_p-1:0] gt_ref_i_clk_p
  , input  wire [num_gty_port_p*gt_serial_width_p-1:0] rifl_gt_o_gt_rxn_in
  , input  wire [num_gty_port_p*gt_serial_width_p-1:0] rifl_gt_o_gt_rxp_in
  , output wire [num_gty_port_p*gt_serial_width_p-1:0] rifl_gt_o_gt_txn_out
  , output wire [num_gty_port_p*gt_serial_width_p-1:0] rifl_gt_o_gt_txp_out

  // Per-link recovered user clock + reset (debug visibility).
  , output wire [num_gty_port_p-1:0] rifl_usr_clk_o
  , output wire [num_gty_port_p-1:0] rifl_usr_rst_o
);

  // ---- shared clocks / resets (init_clk + converter/usr resets from rifl_subsystem;
  //      axi_aresetn_li from the top-level VIO below) ----
  wire                      init_clk;
  wire                      axi_aresetn_li;
  wire                      cc_s_aresetn;
  wire [num_gty_port_p-1:0] usr_clks;
  wire [num_gty_port_p-1:0] cc_m_aresetn;

  assign rifl_usr_clk_o = usr_clks;

  // ---- domain-1 reset: JTAG-driven VIO -> design_1 (and the register map) ----
  // Runs in init_clk (sourced by rifl_subsystem's firmware_bd); active-high VIO rst
  // -> active-low axi_aresetn_li, which resets design_1 (axi_jtag_master) here and
  // the register map (fed into rifl_subsystem via axi_aresetn_i).
  wire vio_axi_rst_lo;
  assign axi_aresetn_li = ~vio_axi_rst_lo;
  design_vio_rifl_rst design_vio_axi_rst_0 (
     .clk(init_clk)
    ,.rst(vio_axi_rst_lo)
  );

  // ---- axi_jtag_master M_AXI_0..3 (init_clk) -> clock converters s_axi ----
  wire [31:0]  j_awaddr   [num_gty_port_p];  wire [7:0]   j_awlen    [num_gty_port_p];
  wire [2:0]   j_awsize   [num_gty_port_p];  wire [1:0]   j_awburst  [num_gty_port_p];
  wire [0:0]   j_awlock   [num_gty_port_p];  wire [3:0]   j_awcache  [num_gty_port_p];
  wire [2:0]   j_awprot   [num_gty_port_p];  wire [3:0]   j_awqos    [num_gty_port_p];
  wire [3:0]   j_awregion [num_gty_port_p];  wire         j_awvalid  [num_gty_port_p];
  wire         j_awready  [num_gty_port_p];  wire [255:0] j_wdata    [num_gty_port_p];
  wire [31:0]  j_wstrb    [num_gty_port_p];  wire         j_wlast    [num_gty_port_p];
  wire         j_wvalid   [num_gty_port_p];  wire         j_wready   [num_gty_port_p];
  wire [1:0]   j_bresp    [num_gty_port_p];  wire         j_bvalid   [num_gty_port_p];
  wire         j_bready   [num_gty_port_p];  wire [31:0]  j_araddr   [num_gty_port_p];
  wire [7:0]   j_arlen    [num_gty_port_p];  wire [2:0]   j_arsize   [num_gty_port_p];
  wire [1:0]   j_arburst  [num_gty_port_p];  wire [0:0]   j_arlock   [num_gty_port_p];
  wire [3:0]   j_arcache  [num_gty_port_p];  wire [2:0]   j_arprot   [num_gty_port_p];
  wire [3:0]   j_arqos    [num_gty_port_p];  wire [3:0]   j_arregion [num_gty_port_p];
  wire         j_arvalid  [num_gty_port_p];  wire         j_arready  [num_gty_port_p];
  wire [255:0] j_rdata    [num_gty_port_p];  wire [1:0]   j_rresp    [num_gty_port_p];
  wire         j_rlast    [num_gty_port_p];  wire         j_rvalid   [num_gty_port_p];
  wire         j_rready   [num_gty_port_p];

  // ---- clock converters m_axi (rifl_usr_clk[i]) -> rifl_subsystem cc_* ----
  wire [31:0]  c_awaddr   [num_gty_port_p];  wire [7:0]   c_awlen    [num_gty_port_p];
  wire [2:0]   c_awsize   [num_gty_port_p];  wire [1:0]   c_awburst  [num_gty_port_p];
  wire [0:0]   c_awlock   [num_gty_port_p];  wire [3:0]   c_awcache  [num_gty_port_p];
  wire [2:0]   c_awprot   [num_gty_port_p];  wire [3:0]   c_awqos    [num_gty_port_p];
  wire [3:0]   c_awregion [num_gty_port_p];  wire         c_awvalid  [num_gty_port_p];
  wire         c_awready  [num_gty_port_p];  wire [255:0] c_wdata    [num_gty_port_p];
  wire [31:0]  c_wstrb    [num_gty_port_p];  wire         c_wlast    [num_gty_port_p];
  wire         c_wvalid   [num_gty_port_p];  wire         c_wready   [num_gty_port_p];
  wire [1:0]   c_bresp    [num_gty_port_p];  wire         c_bvalid   [num_gty_port_p];
  wire         c_bready   [num_gty_port_p];  wire [31:0]  c_araddr   [num_gty_port_p];
  wire [7:0]   c_arlen    [num_gty_port_p];  wire [2:0]   c_arsize   [num_gty_port_p];
  wire [1:0]   c_arburst  [num_gty_port_p];  wire [0:0]   c_arlock   [num_gty_port_p];
  wire [3:0]   c_arcache  [num_gty_port_p];  wire [2:0]   c_arprot   [num_gty_port_p];
  wire [3:0]   c_arqos    [num_gty_port_p];  wire [3:0]   c_arregion [num_gty_port_p];
  wire         c_arvalid  [num_gty_port_p];  wire         c_arready  [num_gty_port_p];
  wire [255:0] c_rdata    [num_gty_port_p];  wire [1:0]   c_rresp    [num_gty_port_p];
  wire         c_rlast    [num_gty_port_p];  wire         c_rvalid   [num_gty_port_p];
  wire         c_rready   [num_gty_port_p];

  // ---- axi_jtag_master M_AXI_4 (lite) -> rifl_subsystem register map ----
  wire [31:0]  l_awaddr;  wire [2:0] l_awprot;  wire l_awvalid, l_awready;
  wire [31:0]  l_wdata;   wire [3:0] l_wstrb;   wire l_wvalid,  l_wready;
  wire [1:0]   l_bresp;   wire       l_bvalid,  l_bready;
  wire [31:0]  l_araddr;  wire [2:0] l_arprot;  wire l_arvalid, l_arready;
  wire [31:0]  l_rdata;   wire [1:0] l_rresp;   wire l_rvalid,  l_rready;

  // ---------------------------------------------------------------------------
  // AXI-JTAG block design (design_1)
  // ---------------------------------------------------------------------------
  axi_jtag_master #(.num_gty_port_p(num_gty_port_p)) u_axi_jtag_master (
     .aclk_0(init_clk), .aresetn_0(axi_aresetn_li)
    ,.m_axi_awaddr(j_awaddr), .m_axi_awlen(j_awlen), .m_axi_awsize(j_awsize)
    ,.m_axi_awburst(j_awburst), .m_axi_awlock(j_awlock), .m_axi_awcache(j_awcache)
    ,.m_axi_awprot(j_awprot), .m_axi_awqos(j_awqos), .m_axi_awregion(j_awregion)
    ,.m_axi_awvalid(j_awvalid), .m_axi_awready(j_awready)
    ,.m_axi_wdata(j_wdata), .m_axi_wstrb(j_wstrb), .m_axi_wlast(j_wlast)
    ,.m_axi_wvalid(j_wvalid), .m_axi_wready(j_wready)
    ,.m_axi_bresp(j_bresp), .m_axi_bvalid(j_bvalid), .m_axi_bready(j_bready)
    ,.m_axi_araddr(j_araddr), .m_axi_arlen(j_arlen), .m_axi_arsize(j_arsize)
    ,.m_axi_arburst(j_arburst), .m_axi_arlock(j_arlock), .m_axi_arcache(j_arcache)
    ,.m_axi_arprot(j_arprot), .m_axi_arqos(j_arqos), .m_axi_arregion(j_arregion)
    ,.m_axi_arvalid(j_arvalid), .m_axi_arready(j_arready)
    ,.m_axi_rdata(j_rdata), .m_axi_rresp(j_rresp), .m_axi_rlast(j_rlast)
    ,.m_axi_rvalid(j_rvalid), .m_axi_rready(j_rready)
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

  // ---------------------------------------------------------------------------
  // Per-link AXI clock converters (init_clk -> rifl_usr_clk[i])
  // ---------------------------------------------------------------------------
  rifl_axi_clock_converters #(.num_gty_port_p(num_gty_port_p)) u_clock_converters (
     .s_axi_aclk(init_clk), .s_axi_aresetn(cc_s_aresetn)
    ,.m_axi_aclk(usr_clks), .m_axi_aresetn(cc_m_aresetn)
    // s_axi <- axi_jtag_master M_AXI_0..3
    ,.s_axi_awaddr(j_awaddr), .s_axi_awlen(j_awlen), .s_axi_awsize(j_awsize)
    ,.s_axi_awburst(j_awburst), .s_axi_awlock(j_awlock), .s_axi_awcache(j_awcache)
    ,.s_axi_awprot(j_awprot), .s_axi_awqos(j_awqos), .s_axi_awregion(j_awregion)
    ,.s_axi_awvalid(j_awvalid), .s_axi_awready(j_awready)
    ,.s_axi_wdata(j_wdata), .s_axi_wstrb(j_wstrb), .s_axi_wlast(j_wlast)
    ,.s_axi_wvalid(j_wvalid), .s_axi_wready(j_wready)
    ,.s_axi_bresp(j_bresp), .s_axi_bvalid(j_bvalid), .s_axi_bready(j_bready)
    ,.s_axi_araddr(j_araddr), .s_axi_arlen(j_arlen), .s_axi_arsize(j_arsize)
    ,.s_axi_arburst(j_arburst), .s_axi_arlock(j_arlock), .s_axi_arcache(j_arcache)
    ,.s_axi_arprot(j_arprot), .s_axi_arqos(j_arqos), .s_axi_arregion(j_arregion)
    ,.s_axi_arvalid(j_arvalid), .s_axi_arready(j_arready)
    ,.s_axi_rdata(j_rdata), .s_axi_rresp(j_rresp), .s_axi_rlast(j_rlast)
    ,.s_axi_rvalid(j_rvalid), .s_axi_rready(j_rready)
    // m_axi -> rifl_subsystem cc_*
    ,.m_axi_awaddr(c_awaddr), .m_axi_awlen(c_awlen), .m_axi_awsize(c_awsize)
    ,.m_axi_awburst(c_awburst), .m_axi_awlock(c_awlock), .m_axi_awcache(c_awcache)
    ,.m_axi_awprot(c_awprot), .m_axi_awqos(c_awqos), .m_axi_awregion(c_awregion)
    ,.m_axi_awvalid(c_awvalid), .m_axi_awready(c_awready)
    ,.m_axi_wdata(c_wdata), .m_axi_wstrb(c_wstrb), .m_axi_wlast(c_wlast)
    ,.m_axi_wvalid(c_wvalid), .m_axi_wready(c_wready)
    ,.m_axi_bresp(c_bresp), .m_axi_bvalid(c_bvalid), .m_axi_bready(c_bready)
    ,.m_axi_araddr(c_araddr), .m_axi_arlen(c_arlen), .m_axi_arsize(c_arsize)
    ,.m_axi_arburst(c_arburst), .m_axi_arlock(c_arlock), .m_axi_arcache(c_arcache)
    ,.m_axi_arprot(c_arprot), .m_axi_arqos(c_arqos), .m_axi_arregion(c_arregion)
    ,.m_axi_arvalid(c_arvalid), .m_axi_arready(c_arready)
    ,.m_axi_rdata(c_rdata), .m_axi_rresp(c_rresp), .m_axi_rlast(c_rlast)
    ,.m_axi_rvalid(c_rvalid), .m_axi_rready(c_rready)
  );

  // ---------------------------------------------------------------------------
  // RIFL core: RIFL IPs + GTs + FIFOs + register map + status + clocking
  // ---------------------------------------------------------------------------
  rifl_subsystem #(
     .gt_serial_width_p(gt_serial_width_p)
    ,.num_gty_port_p(num_gty_port_p)
    ,.axis_data_width_p(axis_data_width_p)
  ) u_rifl_subsystem (
     .ext_refclk_n(ext_refclk_n), .ext_refclk_p(ext_refclk_p), .led(led)
    ,.gt_ref_i_clk_n(gt_ref_i_clk_n), .gt_ref_i_clk_p(gt_ref_i_clk_p)
    ,.rifl_gt_o_gt_rxn_in(rifl_gt_o_gt_rxn_in), .rifl_gt_o_gt_rxp_in(rifl_gt_o_gt_rxp_in)
    ,.rifl_gt_o_gt_txn_out(rifl_gt_o_gt_txn_out), .rifl_gt_o_gt_txp_out(rifl_gt_o_gt_txp_out)
    ,.init_clk_o(init_clk), .axi_aresetn_i(axi_aresetn_li), .cc_s_aresetn_o(cc_s_aresetn)
    ,.usr_clk_o(usr_clks), .usr_rst_o(rifl_usr_rst_o), .cc_m_aresetn_o(cc_m_aresetn)
    // cc_* <- clock converters m_axi
    ,.cc_awaddr(c_awaddr), .cc_awlen(c_awlen), .cc_awsize(c_awsize)
    ,.cc_awburst(c_awburst), .cc_awlock(c_awlock), .cc_awcache(c_awcache)
    ,.cc_awprot(c_awprot), .cc_awqos(c_awqos), .cc_awregion(c_awregion)
    ,.cc_awvalid(c_awvalid), .cc_awready(c_awready)
    ,.cc_wdata(c_wdata), .cc_wstrb(c_wstrb), .cc_wlast(c_wlast)
    ,.cc_wvalid(c_wvalid), .cc_wready(c_wready)
    ,.cc_bresp(c_bresp), .cc_bvalid(c_bvalid), .cc_bready(c_bready)
    ,.cc_araddr(c_araddr), .cc_arlen(c_arlen), .cc_arsize(c_arsize)
    ,.cc_arburst(c_arburst), .cc_arlock(c_arlock), .cc_arcache(c_arcache)
    ,.cc_arprot(c_arprot), .cc_arqos(c_arqos), .cc_arregion(c_arregion)
    ,.cc_arvalid(c_arvalid), .cc_arready(c_arready)
    ,.cc_rdata(c_rdata), .cc_rresp(c_rresp), .cc_rlast(c_rlast)
    ,.cc_rvalid(c_rvalid), .cc_rready(c_rready)
    // m_axil <- axi_jtag_master M_AXI_4
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

endmodule

`default_nettype wire
