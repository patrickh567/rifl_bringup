`timescale 1 ps / 1 ps
`default_nettype none

// -----------------------------------------------------------------------------
// rifl_txrx_fifo
//
// Combined per-link TX + RX FIFOs sharing ONE AXI4 (full) slave port:
//   * AXI WRITE channel (AW/W/B) -> TX FIFO (axi_full_to_axis_fifo) -> RIFL s_axis.
//   * AXI READ channel (AR/R)  -> address-decoded between two RX FIFOs:
//       s_axi_araddr[DECODE_BIT] == 0 -> RX data FIFO  (axis_to_axi_full_fifo),
//                                        holds RIFL m_axis tdata (one word/beat);
//       s_axi_araddr[DECODE_BIT] == 1 -> RX tkeep FIFO (tkeep_pack_fifo), holds
//                                        packed m_axis tkeep (8 chunks/word).
//
// Each RIFL RX beat is forked into BOTH RX FIFOs (data word + tkeep chunk) and is
// accepted only when both have room.  Reads are serialized (one burst at a time)
// through the read demux -- fine for the JTAG-AXI master.
//
// Single clock domain (aclk = the link's rifl_usr_clk).
// -----------------------------------------------------------------------------
module rifl_txrx_fifo #
(
    parameter integer AXI_DATA_WIDTH = 256
  , parameter integer AXI_ADDR_WIDTH = 32
  , parameter integer TX_FIFO_DEPTH  = 512
  , parameter integer RX_FIFO_DEPTH  = 512
  , parameter integer TK_FIFO_DEPTH  = 512
  , parameter integer DECODE_BIT     = 15        // araddr bit: 0 = RX data, 1 = RX tkeep
  , localparam integer STRB_WIDTH    = AXI_DATA_WIDTH/8
  , localparam integer TKEEP_W       = AXI_DATA_WIDTH/8
  , localparam integer RX_CNT_WIDTH  = $clog2(RX_FIFO_DEPTH) + 1
  , localparam integer TK_CNT_WIDTH  = $clog2(TK_FIFO_DEPTH) + 1
)
(
    input  wire                       aclk
  , input  wire                       aresetn

  // ---- shared AXI4 (full) slave: writes -> TX, reads -> RX data/tkeep ----
  , input  wire [AXI_ADDR_WIDTH-1:0]  s_axi_awaddr
  , input  wire [7:0]                 s_axi_awlen
  , input  wire [2:0]                 s_axi_awsize
  , input  wire [1:0]                 s_axi_awburst
  , input  wire                       s_axi_awlock
  , input  wire [3:0]                 s_axi_awcache
  , input  wire [2:0]                 s_axi_awprot
  , input  wire [3:0]                 s_axi_awqos
  , input  wire [3:0]                 s_axi_awregion
  , input  wire                       s_axi_awvalid
  , output wire                       s_axi_awready
  , input  wire [AXI_DATA_WIDTH-1:0]  s_axi_wdata
  , input  wire [STRB_WIDTH-1:0]      s_axi_wstrb
  , input  wire                       s_axi_wlast
  , input  wire                       s_axi_wvalid
  , output wire                       s_axi_wready
  , output wire [1:0]                 s_axi_bresp
  , output wire                       s_axi_bvalid
  , input  wire                       s_axi_bready
  , input  wire [AXI_ADDR_WIDTH-1:0]  s_axi_araddr
  , input  wire [7:0]                 s_axi_arlen
  , input  wire [2:0]                 s_axi_arsize
  , input  wire [1:0]                 s_axi_arburst
  , input  wire                       s_axi_arlock
  , input  wire [3:0]                 s_axi_arcache
  , input  wire [2:0]                 s_axi_arprot
  , input  wire [3:0]                 s_axi_arqos
  , input  wire [3:0]                 s_axi_arregion
  , input  wire                       s_axi_arvalid
  , output wire                       s_axi_arready
  , output wire [AXI_DATA_WIDTH-1:0]  s_axi_rdata
  , output wire [1:0]                 s_axi_rresp
  , output wire                       s_axi_rlast
  , output wire                       s_axi_rvalid
  , input  wire                       s_axi_rready

  // ---- TX AXI-Stream master -> RIFL link s_axis ----
  , input  wire                       tx_axis_enable
  , output wire [AXI_DATA_WIDTH-1:0]  m_axis_tdata
  , output wire                       m_axis_tlast
  , output wire                       m_axis_tvalid
  , input  wire                       m_axis_tready

  // ---- RX AXI-Stream slave <- RIFL link m_axis (tdata + tkeep) ----
  , input  wire [AXI_DATA_WIDTH-1:0]  s_axis_tdata
  , input  wire [TKEEP_W-1:0]         s_axis_tkeep
  , input  wire                       s_axis_tlast
  , input  wire                       s_axis_tvalid
  , output wire                       s_axis_tready

  // ---- occupancies (words available to read) ----
  , output wire [RX_CNT_WIDTH-1:0]    rx_count_o      // RX data FIFO
  , output wire [TK_CNT_WIDTH-1:0]    tkeep_count_o   // RX tkeep FIFO (packed words)
);

  // ---------------------------------------------------------------------------
  // RX beat fork: each accepted RIFL RX beat feeds both RX FIFOs (data + tkeep).
  // ---------------------------------------------------------------------------
  wire rxd_tready, tk_tready;
  assign s_axis_tready = rxd_tready & tk_tready;
  wire rxd_tvalid = s_axis_tvalid & tk_tready;   // present to data FIFO only if tkeep also ready
  wire tk_tvalid  = s_axis_tvalid & rxd_tready;

  // ---------------------------------------------------------------------------
  // AXI read demux: route AR/R to the data or tkeep FIFO by araddr[DECODE_BIT].
  // Serialized: accept a new AR only when no read burst is in flight.
  // ---------------------------------------------------------------------------
  wire ar_sel = s_axi_araddr[DECODE_BIT];        // 0 = data, 1 = tkeep
  logic rd_active, r_sel;
  wire  ar_fire     = s_axi_arvalid & s_axi_arready;
  wire  rlast_fire  = s_axi_rvalid  & s_axi_rready & s_axi_rlast;

  always_ff @(posedge aclk) begin
    if (~aresetn) begin
      rd_active <= 1'b0;
      r_sel     <= 1'b0;
    end else if (ar_fire) begin
      rd_active <= 1'b1;
      r_sel     <= ar_sel;
    end else if (rlast_fire) begin
      rd_active <= 1'b0;
    end
  end

  // per-FIFO read-channel handshake signals
  wire                      rxd_arready, tk_arready;
  wire [AXI_DATA_WIDTH-1:0] rxd_rdata,   tk_rdata;
  wire [1:0]                rxd_rresp,   tk_rresp;
  wire                      rxd_rlast,   tk_rlast;
  wire                      rxd_rvalid,  tk_rvalid;

  wire rxd_arvalid = s_axi_arvalid & ~rd_active & ~ar_sel;
  wire tk_arvalid  = s_axi_arvalid & ~rd_active &  ar_sel;
  assign s_axi_arready = ~rd_active & (ar_sel ? tk_arready : rxd_arready);

  assign s_axi_rvalid = rd_active & (r_sel ? tk_rvalid : rxd_rvalid);
  assign s_axi_rdata  = r_sel ? tk_rdata : rxd_rdata;
  assign s_axi_rresp  = r_sel ? tk_rresp : rxd_rresp;
  assign s_axi_rlast  = r_sel ? tk_rlast : rxd_rlast;
  wire rxd_rready = rd_active & ~r_sel & s_axi_rready;
  wire tk_rready  = rd_active &  r_sel & s_axi_rready;

  // ---------------------------------------------------------------------------
  // TX: shared AXI write channel -> FIFO -> m_axis (read channel tied off)
  // ---------------------------------------------------------------------------
  axi_full_to_axis_fifo #(
     .AXI_DATA_WIDTH(AXI_DATA_WIDTH)
    ,.AXI_ADDR_WIDTH(AXI_ADDR_WIDTH)
    ,.FIFO_DEPTH    (TX_FIFO_DEPTH)
  ) tx_fifo (
     .aclk(aclk), .aresetn(aresetn)
    ,.s_axi_awaddr(s_axi_awaddr), .s_axi_awlen(s_axi_awlen), .s_axi_awsize(s_axi_awsize)
    ,.s_axi_awburst(s_axi_awburst), .s_axi_awlock(s_axi_awlock), .s_axi_awcache(s_axi_awcache)
    ,.s_axi_awprot(s_axi_awprot), .s_axi_awqos(s_axi_awqos), .s_axi_awregion(s_axi_awregion)
    ,.s_axi_awvalid(s_axi_awvalid), .s_axi_awready(s_axi_awready)
    ,.s_axi_wdata(s_axi_wdata), .s_axi_wstrb(s_axi_wstrb), .s_axi_wlast(s_axi_wlast)
    ,.s_axi_wvalid(s_axi_wvalid), .s_axi_wready(s_axi_wready)
    ,.s_axi_bresp(s_axi_bresp), .s_axi_bvalid(s_axi_bvalid), .s_axi_bready(s_axi_bready)
    ,.s_axi_araddr('0), .s_axi_arlen('0), .s_axi_arsize('0), .s_axi_arburst('0)
    ,.s_axi_arlock('0), .s_axi_arcache('0), .s_axi_arprot('0), .s_axi_arqos('0)
    ,.s_axi_arregion('0), .s_axi_arvalid(1'b0), .s_axi_arready()
    ,.s_axi_rdata(), .s_axi_rresp(), .s_axi_rlast(), .s_axi_rvalid(), .s_axi_rready(1'b0)
    ,.axis_enable(tx_axis_enable)
    ,.m_axis_tdata(m_axis_tdata), .m_axis_tlast(m_axis_tlast)
    ,.m_axis_tvalid(m_axis_tvalid), .m_axis_tready(m_axis_tready)
  );

  // ---------------------------------------------------------------------------
  // RX data: forked m_axis tdata -> FIFO -> read demux (data side); write unused
  // ---------------------------------------------------------------------------
  axis_to_axi_full_fifo #(
     .AXI_DATA_WIDTH(AXI_DATA_WIDTH)
    ,.AXI_ADDR_WIDTH(AXI_ADDR_WIDTH)
    ,.FIFO_DEPTH    (RX_FIFO_DEPTH)
  ) rxd_fifo (
     .aclk(aclk), .aresetn(aresetn)
    ,.s_axis_tdata(s_axis_tdata), .s_axis_tlast(s_axis_tlast)
    ,.s_axis_tvalid(rxd_tvalid), .s_axis_tready(rxd_tready)
    ,.s_axi_awaddr('0), .s_axi_awlen('0), .s_axi_awsize('0), .s_axi_awburst('0)
    ,.s_axi_awlock('0), .s_axi_awcache('0), .s_axi_awprot('0), .s_axi_awqos('0)
    ,.s_axi_awregion('0), .s_axi_awvalid(1'b0), .s_axi_awready()
    ,.s_axi_wdata('0), .s_axi_wstrb('0), .s_axi_wlast(1'b0), .s_axi_wvalid(1'b0), .s_axi_wready()
    ,.s_axi_bresp(), .s_axi_bvalid(), .s_axi_bready(1'b0)
    ,.s_axi_araddr(s_axi_araddr), .s_axi_arlen(s_axi_arlen), .s_axi_arsize(s_axi_arsize)
    ,.s_axi_arburst(s_axi_arburst), .s_axi_arlock(s_axi_arlock), .s_axi_arcache(s_axi_arcache)
    ,.s_axi_arprot(s_axi_arprot), .s_axi_arqos(s_axi_arqos), .s_axi_arregion(s_axi_arregion)
    ,.s_axi_arvalid(rxd_arvalid), .s_axi_arready(rxd_arready)
    ,.s_axi_rdata(rxd_rdata), .s_axi_rresp(rxd_rresp), .s_axi_rlast(rxd_rlast)
    ,.s_axi_rvalid(rxd_rvalid), .s_axi_rready(rxd_rready)
    ,.count_o(rx_count_o)
  );

  // ---------------------------------------------------------------------------
  // RX tkeep: forked m_axis tkeep -> pack FIFO -> read demux (tkeep side); wr unused
  // ---------------------------------------------------------------------------
  tkeep_pack_fifo #(
     .AXI_DATA_WIDTH(AXI_DATA_WIDTH)
    ,.AXI_ADDR_WIDTH(AXI_ADDR_WIDTH)
    ,.FIFO_DEPTH    (TK_FIFO_DEPTH)
  ) tk_fifo (
     .aclk(aclk), .aresetn(aresetn)
    ,.s_axis_tkeep(s_axis_tkeep), .s_axis_tlast(s_axis_tlast)
    ,.s_axis_tvalid(tk_tvalid), .s_axis_tready(tk_tready)
    ,.s_axi_awaddr('0), .s_axi_awlen('0), .s_axi_awsize('0), .s_axi_awburst('0)
    ,.s_axi_awlock('0), .s_axi_awcache('0), .s_axi_awprot('0), .s_axi_awqos('0)
    ,.s_axi_awregion('0), .s_axi_awvalid(1'b0), .s_axi_awready()
    ,.s_axi_wdata('0), .s_axi_wstrb('0), .s_axi_wlast(1'b0), .s_axi_wvalid(1'b0), .s_axi_wready()
    ,.s_axi_bresp(), .s_axi_bvalid(), .s_axi_bready(1'b0)
    ,.s_axi_araddr(s_axi_araddr), .s_axi_arlen(s_axi_arlen), .s_axi_arsize(s_axi_arsize)
    ,.s_axi_arburst(s_axi_arburst), .s_axi_arlock(s_axi_arlock), .s_axi_arcache(s_axi_arcache)
    ,.s_axi_arprot(s_axi_arprot), .s_axi_arqos(s_axi_arqos), .s_axi_arregion(s_axi_arregion)
    ,.s_axi_arvalid(tk_arvalid), .s_axi_arready(tk_arready)
    ,.s_axi_rdata(tk_rdata), .s_axi_rresp(tk_rresp), .s_axi_rlast(tk_rlast)
    ,.s_axi_rvalid(tk_rvalid), .s_axi_rready(tk_rready)
    ,.count_o(tkeep_count_o)
  );

endmodule

`default_nettype wire
