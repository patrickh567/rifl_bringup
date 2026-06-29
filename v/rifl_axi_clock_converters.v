`timescale 1 ps / 1 ps
`default_nettype none

// -----------------------------------------------------------------------------
// rifl_axi_clock_converters
//
// The per-link AXI clock converters, wrapped in one module.  Each instance of
// axi_clock_converter_0 crosses one M_AXI from the s_axi (init_clk, design_1)
// domain into the m_axi (per-link rifl_usr_clk[i]) domain.
//
// The AXI buses are per-link unpacked arrays:
//   s_axi_* : AXI4 SLAVE side  (init_clk), connects to design_1 M_AXI_0..3
//   m_axi_* : AXI4 MASTER side (rifl_usr_clk[i]), connects to rifl_subsystem
// -----------------------------------------------------------------------------
module rifl_axi_clock_converters #
(
    parameter integer num_gty_port_p = 4
)
(
    input  wire                       s_axi_aclk
  , input  wire                       s_axi_aresetn
  , input  wire [num_gty_port_p-1:0]  m_axi_aclk
  , input  wire [num_gty_port_p-1:0]  m_axi_aresetn

  // ---- s_axi (slave, init_clk) <- design_1 M_AXI_0..3 ----
  , input  wire [31:0]  s_axi_awaddr   [num_gty_port_p]
  , input  wire [7:0]   s_axi_awlen    [num_gty_port_p]
  , input  wire [2:0]   s_axi_awsize   [num_gty_port_p]
  , input  wire [1:0]   s_axi_awburst  [num_gty_port_p]
  , input  wire [0:0]   s_axi_awlock   [num_gty_port_p]
  , input  wire [3:0]   s_axi_awcache  [num_gty_port_p]
  , input  wire [2:0]   s_axi_awprot   [num_gty_port_p]
  , input  wire [3:0]   s_axi_awqos    [num_gty_port_p]
  , input  wire [3:0]   s_axi_awregion [num_gty_port_p]
  , input  wire         s_axi_awvalid  [num_gty_port_p]
  , output wire         s_axi_awready  [num_gty_port_p]
  , input  wire [255:0] s_axi_wdata    [num_gty_port_p]
  , input  wire [31:0]  s_axi_wstrb    [num_gty_port_p]
  , input  wire         s_axi_wlast    [num_gty_port_p]
  , input  wire         s_axi_wvalid   [num_gty_port_p]
  , output wire         s_axi_wready   [num_gty_port_p]
  , output wire [1:0]   s_axi_bresp    [num_gty_port_p]
  , output wire         s_axi_bvalid   [num_gty_port_p]
  , input  wire         s_axi_bready   [num_gty_port_p]
  , input  wire [31:0]  s_axi_araddr   [num_gty_port_p]
  , input  wire [7:0]   s_axi_arlen    [num_gty_port_p]
  , input  wire [2:0]   s_axi_arsize   [num_gty_port_p]
  , input  wire [1:0]   s_axi_arburst  [num_gty_port_p]
  , input  wire [0:0]   s_axi_arlock   [num_gty_port_p]
  , input  wire [3:0]   s_axi_arcache  [num_gty_port_p]
  , input  wire [2:0]   s_axi_arprot   [num_gty_port_p]
  , input  wire [3:0]   s_axi_arqos    [num_gty_port_p]
  , input  wire [3:0]   s_axi_arregion [num_gty_port_p]
  , input  wire         s_axi_arvalid  [num_gty_port_p]
  , output wire         s_axi_arready  [num_gty_port_p]
  , output wire [255:0] s_axi_rdata    [num_gty_port_p]
  , output wire [1:0]   s_axi_rresp    [num_gty_port_p]
  , output wire         s_axi_rlast    [num_gty_port_p]
  , output wire         s_axi_rvalid   [num_gty_port_p]
  , input  wire         s_axi_rready   [num_gty_port_p]

  // ---- m_axi (master, rifl_usr_clk[i]) -> rifl_subsystem ----
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
);

  for (genvar i = 0; i < num_gty_port_p; i++) begin: cc
    axi_clock_converter_0 u_cc (
       .s_axi_aclk    (s_axi_aclk)
      ,.s_axi_aresetn (s_axi_aresetn)
      ,.s_axi_awaddr  (s_axi_awaddr[i] )
      ,.s_axi_awlen   (s_axi_awlen[i]  )
      ,.s_axi_awsize  (s_axi_awsize[i] )
      ,.s_axi_awburst (s_axi_awburst[i])
      ,.s_axi_awlock  (s_axi_awlock[i] )
      ,.s_axi_awcache (s_axi_awcache[i])
      ,.s_axi_awprot  (s_axi_awprot[i] )
      ,.s_axi_awregion(s_axi_awregion[i])
      ,.s_axi_awqos   (s_axi_awqos[i]  )
      ,.s_axi_awvalid (s_axi_awvalid[i])
      ,.s_axi_awready (s_axi_awready[i])
      ,.s_axi_wdata   (s_axi_wdata[i]  )
      ,.s_axi_wstrb   (s_axi_wstrb[i]  )
      ,.s_axi_wlast   (s_axi_wlast[i]  )
      ,.s_axi_wvalid  (s_axi_wvalid[i] )
      ,.s_axi_wready  (s_axi_wready[i] )
      ,.s_axi_bresp   (s_axi_bresp[i]  )
      ,.s_axi_bvalid  (s_axi_bvalid[i] )
      ,.s_axi_bready  (s_axi_bready[i] )
      ,.s_axi_araddr  (s_axi_araddr[i] )
      ,.s_axi_arlen   (s_axi_arlen[i]  )
      ,.s_axi_arsize  (s_axi_arsize[i] )
      ,.s_axi_arburst (s_axi_arburst[i])
      ,.s_axi_arlock  (s_axi_arlock[i] )
      ,.s_axi_arcache (s_axi_arcache[i])
      ,.s_axi_arprot  (s_axi_arprot[i] )
      ,.s_axi_arregion(s_axi_arregion[i])
      ,.s_axi_arqos   (s_axi_arqos[i]  )
      ,.s_axi_arvalid (s_axi_arvalid[i])
      ,.s_axi_arready (s_axi_arready[i])
      ,.s_axi_rdata   (s_axi_rdata[i]  )
      ,.s_axi_rresp   (s_axi_rresp[i]  )
      ,.s_axi_rlast   (s_axi_rlast[i]  )
      ,.s_axi_rvalid  (s_axi_rvalid[i] )
      ,.s_axi_rready  (s_axi_rready[i] )
      ,.m_axi_aclk    (m_axi_aclk[i])
      ,.m_axi_aresetn (m_axi_aresetn[i])
      ,.m_axi_awaddr  (m_axi_awaddr[i] )
      ,.m_axi_awlen   (m_axi_awlen[i]  )
      ,.m_axi_awsize  (m_axi_awsize[i] )
      ,.m_axi_awburst (m_axi_awburst[i])
      ,.m_axi_awlock  (m_axi_awlock[i] )
      ,.m_axi_awcache (m_axi_awcache[i])
      ,.m_axi_awprot  (m_axi_awprot[i] )
      ,.m_axi_awregion(m_axi_awregion[i])
      ,.m_axi_awqos   (m_axi_awqos[i]  )
      ,.m_axi_awvalid (m_axi_awvalid[i])
      ,.m_axi_awready (m_axi_awready[i])
      ,.m_axi_wdata   (m_axi_wdata[i]  )
      ,.m_axi_wstrb   (m_axi_wstrb[i]  )
      ,.m_axi_wlast   (m_axi_wlast[i]  )
      ,.m_axi_wvalid  (m_axi_wvalid[i] )
      ,.m_axi_wready  (m_axi_wready[i] )
      ,.m_axi_bresp   (m_axi_bresp[i]  )
      ,.m_axi_bvalid  (m_axi_bvalid[i] )
      ,.m_axi_bready  (m_axi_bready[i] )
      ,.m_axi_araddr  (m_axi_araddr[i] )
      ,.m_axi_arlen   (m_axi_arlen[i]  )
      ,.m_axi_arsize  (m_axi_arsize[i] )
      ,.m_axi_arburst (m_axi_arburst[i])
      ,.m_axi_arlock  (m_axi_arlock[i] )
      ,.m_axi_arcache (m_axi_arcache[i])
      ,.m_axi_arprot  (m_axi_arprot[i] )
      ,.m_axi_arregion(m_axi_arregion[i])
      ,.m_axi_arqos   (m_axi_arqos[i]  )
      ,.m_axi_arvalid (m_axi_arvalid[i])
      ,.m_axi_arready (m_axi_arready[i])
      ,.m_axi_rdata   (m_axi_rdata[i]  )
      ,.m_axi_rresp   (m_axi_rresp[i]  )
      ,.m_axi_rlast   (m_axi_rlast[i]  )
      ,.m_axi_rvalid  (m_axi_rvalid[i] )
      ,.m_axi_rready  (m_axi_rready[i] )
    );
  end

endmodule

`default_nettype wire
