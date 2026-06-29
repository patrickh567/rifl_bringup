`timescale 1 ps / 1 ps
`default_nettype none

// -----------------------------------------------------------------------------
// axi_jtag_master
//
// The AXI-JTAG block design (design_1) as a standalone module: JTAG-to-AXI master
// -> AXI switch -> 4x M_AXI (256-bit AXI4-full) + M_AXI_4 (AXI4-Lite).  This thin
// wrapper bundles design_1's scalar M_AXI_0..3 ports into per-link arrays (m_axi_*)
// so the top level connects them cleanly; M_AXI_4 stays scalar (m_axil_*).
// Everything is in the aclk_0 (init_clk) domain.
// -----------------------------------------------------------------------------
module axi_jtag_master #
(
    parameter integer num_gty_port_p = 4
)
(
    input  wire        aclk_0
  , input  wire        aresetn_0

  // ---- M_AXI_0..3 (AXI4-full MASTER) as per-link arrays ----
  , output wire [31:0]  m_axi_awaddr   [num_gty_port_p]
  , output wire [7:0]   m_axi_awlen    [num_gty_port_p]
  , output wire [2:0]   m_axi_awsize   [num_gty_port_p]
  , output wire [1:0]   m_axi_awburst  [num_gty_port_p]
  , output wire [0:0]   m_axi_awlock   [num_gty_port_p]
  , output wire [3:0]   m_axi_awcache  [num_gty_port_p]
  , output wire [2:0]   m_axi_awprot   [num_gty_port_p]
  , output wire [3:0]   m_axi_awqos    [num_gty_port_p]
  , output wire [3:0]   m_axi_awregion [num_gty_port_p]
  , output wire         m_axi_awvalid  [num_gty_port_p]
  , input  wire         m_axi_awready  [num_gty_port_p]
  , output wire [255:0] m_axi_wdata    [num_gty_port_p]
  , output wire [31:0]  m_axi_wstrb    [num_gty_port_p]
  , output wire         m_axi_wlast    [num_gty_port_p]
  , output wire         m_axi_wvalid   [num_gty_port_p]
  , input  wire         m_axi_wready   [num_gty_port_p]
  , input  wire [1:0]   m_axi_bresp    [num_gty_port_p]
  , input  wire         m_axi_bvalid   [num_gty_port_p]
  , output wire         m_axi_bready   [num_gty_port_p]
  , output wire [31:0]  m_axi_araddr   [num_gty_port_p]
  , output wire [7:0]   m_axi_arlen    [num_gty_port_p]
  , output wire [2:0]   m_axi_arsize   [num_gty_port_p]
  , output wire [1:0]   m_axi_arburst  [num_gty_port_p]
  , output wire [0:0]   m_axi_arlock   [num_gty_port_p]
  , output wire [3:0]   m_axi_arcache  [num_gty_port_p]
  , output wire [2:0]   m_axi_arprot   [num_gty_port_p]
  , output wire [3:0]   m_axi_arqos    [num_gty_port_p]
  , output wire [3:0]   m_axi_arregion [num_gty_port_p]
  , output wire         m_axi_arvalid  [num_gty_port_p]
  , input  wire         m_axi_arready  [num_gty_port_p]
  , input  wire [255:0] m_axi_rdata    [num_gty_port_p]
  , input  wire [1:0]   m_axi_rresp    [num_gty_port_p]
  , input  wire         m_axi_rlast    [num_gty_port_p]
  , input  wire         m_axi_rvalid   [num_gty_port_p]
  , output wire         m_axi_rready   [num_gty_port_p]

  // ---- M_AXI_4 (AXI4-Lite MASTER) ----
  , output wire [31:0]  m_axil_awaddr
  , output wire [2:0]   m_axil_awprot
  , output wire         m_axil_awvalid
  , input  wire         m_axil_awready
  , output wire [31:0]  m_axil_wdata
  , output wire [3:0]   m_axil_wstrb
  , output wire         m_axil_wvalid
  , input  wire         m_axil_wready
  , input  wire [1:0]   m_axil_bresp
  , input  wire         m_axil_bvalid
  , output wire         m_axil_bready
  , output wire [31:0]  m_axil_araddr
  , output wire [2:0]   m_axil_arprot
  , output wire         m_axil_arvalid
  , input  wire         m_axil_arready
  , input  wire [31:0]  m_axil_rdata
  , input  wire [1:0]   m_axil_rresp
  , input  wire         m_axil_rvalid
  , output wire         m_axil_rready
);

  design_1_wrapper design_1_wrapper_i (
      .aclk_0   (aclk_0)
    , .aresetn_0(aresetn_0)
    // ---- M_AXI_0 ----
    , .M_AXI_0_awaddr (m_axi_awaddr[0] ), .M_AXI_0_awlen   (m_axi_awlen[0]  )
    , .M_AXI_0_awsize (m_axi_awsize[0] ), .M_AXI_0_awburst (m_axi_awburst[0])
    , .M_AXI_0_awlock (m_axi_awlock[0] ), .M_AXI_0_awcache (m_axi_awcache[0])
    , .M_AXI_0_awprot (m_axi_awprot[0] ), .M_AXI_0_awqos   (m_axi_awqos[0]  )
    , .M_AXI_0_awregion(m_axi_awregion[0]), .M_AXI_0_awvalid(m_axi_awvalid[0])
    , .M_AXI_0_awready(m_axi_awready[0] )
    , .M_AXI_0_wdata  (m_axi_wdata[0]  ), .M_AXI_0_wstrb   (m_axi_wstrb[0]  )
    , .M_AXI_0_wlast  (m_axi_wlast[0]  ), .M_AXI_0_wvalid  (m_axi_wvalid[0] )
    , .M_AXI_0_wready (m_axi_wready[0] )
    , .M_AXI_0_bresp  (m_axi_bresp[0]  ), .M_AXI_0_bvalid  (m_axi_bvalid[0] )
    , .M_AXI_0_bready (m_axi_bready[0] )
    , .M_AXI_0_araddr (m_axi_araddr[0] ), .M_AXI_0_arlen   (m_axi_arlen[0]  )
    , .M_AXI_0_arsize (m_axi_arsize[0] ), .M_AXI_0_arburst (m_axi_arburst[0])
    , .M_AXI_0_arlock (m_axi_arlock[0] ), .M_AXI_0_arcache (m_axi_arcache[0])
    , .M_AXI_0_arprot (m_axi_arprot[0] ), .M_AXI_0_arqos   (m_axi_arqos[0]  )
    , .M_AXI_0_arregion(m_axi_arregion[0]), .M_AXI_0_arvalid(m_axi_arvalid[0])
    , .M_AXI_0_arready(m_axi_arready[0] )
    , .M_AXI_0_rdata  (m_axi_rdata[0]  ), .M_AXI_0_rresp   (m_axi_rresp[0]  )
    , .M_AXI_0_rlast  (m_axi_rlast[0]  ), .M_AXI_0_rvalid  (m_axi_rvalid[0] )
    , .M_AXI_0_rready (m_axi_rready[0] )
    // ---- M_AXI_1 ----
    , .M_AXI_1_awaddr (m_axi_awaddr[1] ), .M_AXI_1_awlen   (m_axi_awlen[1]  )
    , .M_AXI_1_awsize (m_axi_awsize[1] ), .M_AXI_1_awburst (m_axi_awburst[1])
    , .M_AXI_1_awlock (m_axi_awlock[1] ), .M_AXI_1_awcache (m_axi_awcache[1])
    , .M_AXI_1_awprot (m_axi_awprot[1] ), .M_AXI_1_awqos   (m_axi_awqos[1]  )
    , .M_AXI_1_awregion(m_axi_awregion[1]), .M_AXI_1_awvalid(m_axi_awvalid[1])
    , .M_AXI_1_awready(m_axi_awready[1] )
    , .M_AXI_1_wdata  (m_axi_wdata[1]  ), .M_AXI_1_wstrb   (m_axi_wstrb[1]  )
    , .M_AXI_1_wlast  (m_axi_wlast[1]  ), .M_AXI_1_wvalid  (m_axi_wvalid[1] )
    , .M_AXI_1_wready (m_axi_wready[1] )
    , .M_AXI_1_bresp  (m_axi_bresp[1]  ), .M_AXI_1_bvalid  (m_axi_bvalid[1] )
    , .M_AXI_1_bready (m_axi_bready[1] )
    , .M_AXI_1_araddr (m_axi_araddr[1] ), .M_AXI_1_arlen   (m_axi_arlen[1]  )
    , .M_AXI_1_arsize (m_axi_arsize[1] ), .M_AXI_1_arburst (m_axi_arburst[1])
    , .M_AXI_1_arlock (m_axi_arlock[1] ), .M_AXI_1_arcache (m_axi_arcache[1])
    , .M_AXI_1_arprot (m_axi_arprot[1] ), .M_AXI_1_arqos   (m_axi_arqos[1]  )
    , .M_AXI_1_arregion(m_axi_arregion[1]), .M_AXI_1_arvalid(m_axi_arvalid[1])
    , .M_AXI_1_arready(m_axi_arready[1] )
    , .M_AXI_1_rdata  (m_axi_rdata[1]  ), .M_AXI_1_rresp   (m_axi_rresp[1]  )
    , .M_AXI_1_rlast  (m_axi_rlast[1]  ), .M_AXI_1_rvalid  (m_axi_rvalid[1] )
    , .M_AXI_1_rready (m_axi_rready[1] )
    // ---- M_AXI_2 ----
    , .M_AXI_2_awaddr (m_axi_awaddr[2] ), .M_AXI_2_awlen   (m_axi_awlen[2]  )
    , .M_AXI_2_awsize (m_axi_awsize[2] ), .M_AXI_2_awburst (m_axi_awburst[2])
    , .M_AXI_2_awlock (m_axi_awlock[2] ), .M_AXI_2_awcache (m_axi_awcache[2])
    , .M_AXI_2_awprot (m_axi_awprot[2] ), .M_AXI_2_awqos   (m_axi_awqos[2]  )
    , .M_AXI_2_awregion(m_axi_awregion[2]), .M_AXI_2_awvalid(m_axi_awvalid[2])
    , .M_AXI_2_awready(m_axi_awready[2] )
    , .M_AXI_2_wdata  (m_axi_wdata[2]  ), .M_AXI_2_wstrb   (m_axi_wstrb[2]  )
    , .M_AXI_2_wlast  (m_axi_wlast[2]  ), .M_AXI_2_wvalid  (m_axi_wvalid[2] )
    , .M_AXI_2_wready (m_axi_wready[2] )
    , .M_AXI_2_bresp  (m_axi_bresp[2]  ), .M_AXI_2_bvalid  (m_axi_bvalid[2] )
    , .M_AXI_2_bready (m_axi_bready[2] )
    , .M_AXI_2_araddr (m_axi_araddr[2] ), .M_AXI_2_arlen   (m_axi_arlen[2]  )
    , .M_AXI_2_arsize (m_axi_arsize[2] ), .M_AXI_2_arburst (m_axi_arburst[2])
    , .M_AXI_2_arlock (m_axi_arlock[2] ), .M_AXI_2_arcache (m_axi_arcache[2])
    , .M_AXI_2_arprot (m_axi_arprot[2] ), .M_AXI_2_arqos   (m_axi_arqos[2]  )
    , .M_AXI_2_arregion(m_axi_arregion[2]), .M_AXI_2_arvalid(m_axi_arvalid[2])
    , .M_AXI_2_arready(m_axi_arready[2] )
    , .M_AXI_2_rdata  (m_axi_rdata[2]  ), .M_AXI_2_rresp   (m_axi_rresp[2]  )
    , .M_AXI_2_rlast  (m_axi_rlast[2]  ), .M_AXI_2_rvalid  (m_axi_rvalid[2] )
    , .M_AXI_2_rready (m_axi_rready[2] )
    // ---- M_AXI_3 ----
    , .M_AXI_3_awaddr (m_axi_awaddr[3] ), .M_AXI_3_awlen   (m_axi_awlen[3]  )
    , .M_AXI_3_awsize (m_axi_awsize[3] ), .M_AXI_3_awburst (m_axi_awburst[3])
    , .M_AXI_3_awlock (m_axi_awlock[3] ), .M_AXI_3_awcache (m_axi_awcache[3])
    , .M_AXI_3_awprot (m_axi_awprot[3] ), .M_AXI_3_awqos   (m_axi_awqos[3]  )
    , .M_AXI_3_awregion(m_axi_awregion[3]), .M_AXI_3_awvalid(m_axi_awvalid[3])
    , .M_AXI_3_awready(m_axi_awready[3] )
    , .M_AXI_3_wdata  (m_axi_wdata[3]  ), .M_AXI_3_wstrb   (m_axi_wstrb[3]  )
    , .M_AXI_3_wlast  (m_axi_wlast[3]  ), .M_AXI_3_wvalid  (m_axi_wvalid[3] )
    , .M_AXI_3_wready (m_axi_wready[3] )
    , .M_AXI_3_bresp  (m_axi_bresp[3]  ), .M_AXI_3_bvalid  (m_axi_bvalid[3] )
    , .M_AXI_3_bready (m_axi_bready[3] )
    , .M_AXI_3_araddr (m_axi_araddr[3] ), .M_AXI_3_arlen   (m_axi_arlen[3]  )
    , .M_AXI_3_arsize (m_axi_arsize[3] ), .M_AXI_3_arburst (m_axi_arburst[3])
    , .M_AXI_3_arlock (m_axi_arlock[3] ), .M_AXI_3_arcache (m_axi_arcache[3])
    , .M_AXI_3_arprot (m_axi_arprot[3] ), .M_AXI_3_arqos   (m_axi_arqos[3]  )
    , .M_AXI_3_arregion(m_axi_arregion[3]), .M_AXI_3_arvalid(m_axi_arvalid[3])
    , .M_AXI_3_arready(m_axi_arready[3] )
    , .M_AXI_3_rdata  (m_axi_rdata[3]  ), .M_AXI_3_rresp   (m_axi_rresp[3]  )
    , .M_AXI_3_rlast  (m_axi_rlast[3]  ), .M_AXI_3_rvalid  (m_axi_rvalid[3] )
    , .M_AXI_3_rready (m_axi_rready[3] )
    // ---- M_AXI_4 (AXI4-Lite) ----
    , .M_AXI_4_awaddr (m_axil_awaddr ), .M_AXI_4_awprot (m_axil_awprot )
    , .M_AXI_4_awvalid(m_axil_awvalid), .M_AXI_4_awready(m_axil_awready)
    , .M_AXI_4_wdata  (m_axil_wdata  ), .M_AXI_4_wstrb  (m_axil_wstrb  )
    , .M_AXI_4_wvalid (m_axil_wvalid ), .M_AXI_4_wready (m_axil_wready )
    , .M_AXI_4_bresp  (m_axil_bresp  ), .M_AXI_4_bvalid (m_axil_bvalid )
    , .M_AXI_4_bready (m_axil_bready )
    , .M_AXI_4_araddr (m_axil_araddr ), .M_AXI_4_arprot (m_axil_arprot )
    , .M_AXI_4_arvalid(m_axil_arvalid), .M_AXI_4_arready(m_axil_arready)
    , .M_AXI_4_rdata  (m_axil_rdata  ), .M_AXI_4_rresp  (m_axil_rresp  )
    , .M_AXI_4_rvalid (m_axil_rvalid ), .M_AXI_4_rready (m_axil_rready )
  );

endmodule

`default_nettype wire
