`timescale 1 ps / 1 ps
`default_nettype none

// -----------------------------------------------------------------------------
// rifl_txrx_fifo
//
// Combined per-link TX + RX FIFOs sharing ONE AXI4 (full) slave port.
//
//   TX (writes):  awaddr[15]==0       -> push a data word into the TX data FIFO;
//                 awaddr[15]==1 (+0x8000) -> COMMIT: record the just-written
//                 packet's beat-count in the TX descriptor FIFO.  Raising
//                 tx_axis_enable drains every buffered packet to the RIFL s_axis
//                 with TLAST at each descriptor boundary (axi_full_to_axis_fifo).
//
//   RX (reads), demuxed by araddr[15:14]:
//                 0x (0x0)    -> RX data  FIFO  (axis_to_axi_full_fifo)
//                 10 (0x8000) -> RX tkeep FIFO  (tkeep_pack_fifo, 8 chunks/word)
//                 11 (0xC000) -> RX length FIFO (axis_to_axi_full_fifo): one entry
//                                per received packet = its beat-count, so software
//                                can read packets back boundary-aware.
//
// Each RIFL RX beat is forked into the data + tkeep FIFOs (and, on its TLAST beat,
// the length FIFO) and is accepted only when every target it feeds has room.
// Reads are serialized (one burst at a time).  Single clock domain (rifl_usr_clk).
// -----------------------------------------------------------------------------
module rifl_txrx_fifo #
(
    parameter integer AXI_DATA_WIDTH = 256
  , parameter integer AXI_ADDR_WIDTH = 32
  , parameter integer TX_FIFO_DEPTH  = 512
  , parameter integer RX_FIFO_DEPTH  = 512
  , parameter integer TK_FIFO_DEPTH  = 512
  , parameter integer TX_DESC_DEPTH  = 64        // TX descriptor FIFO (max buffered TX packets)
  , parameter integer RX_PKT_DEPTH   = 64        // RX length FIFO (max buffered RX packet lengths)
  , parameter integer DECODE_BIT     = 15        // read sel = araddr[15:14]: 0x=data,10=tkeep,11=len
  , localparam integer STRB_WIDTH    = AXI_DATA_WIDTH/8
  , localparam integer TKEEP_W       = AXI_DATA_WIDTH/8
  , localparam integer RX_CNT_WIDTH  = $clog2(RX_FIFO_DEPTH) + 1
  , localparam integer TK_CNT_WIDTH  = $clog2(TK_FIFO_DEPTH) + 1
  , localparam integer TX_DESC_CNT_W = $clog2(TX_DESC_DEPTH) + 1
  , localparam integer RX_PKT_CNT_W  = $clog2(RX_PKT_DEPTH) + 1
)
(
    input  wire                       aclk
  , input  wire                       aresetn

  // ---- shared AXI4 (full) slave: writes -> TX, reads -> RX data/tkeep/length ----
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

  // ---- occupancies ----
  , output wire [RX_CNT_WIDTH-1:0]    rx_count_o       // RX data FIFO (words)
  , output wire [TK_CNT_WIDTH-1:0]    tkeep_count_o    // RX tkeep FIFO (packed words)
  , output wire [TX_DESC_CNT_W-1:0]   tx_desc_count_o  // TX descriptor FIFO (packets buffered)
  , output wire [RX_PKT_CNT_W-1:0]    rx_pkt_count_o   // RX length FIFO (packets received)
);

  // ---------------------------------------------------------------------------
  // RX register slice: break the long RIFL m_axis -> RX FIFO route so the usr
  // clock (~390 MHz) closes timing.  The skid carries {tlast, tkeep, tdata}.
  // ---------------------------------------------------------------------------
  wire [AXI_DATA_WIDTH-1:0] r_tdata;
  wire [TKEEP_W-1:0]        r_tkeep;
  wire                      r_tlast, r_tvalid, r_tready;
  axis_skid_buffer #(.W(1 + TKEEP_W + AXI_DATA_WIDTH)) rx_skid (
     .clk(aclk), .rstn(aresetn)
    ,.s_data ({s_axis_tlast, s_axis_tkeep, s_axis_tdata})
    ,.s_valid(s_axis_tvalid), .s_ready(s_axis_tready)
    ,.m_data ({r_tlast, r_tkeep, r_tdata})
    ,.m_valid(r_tvalid), .m_ready(r_tready)
  );

  // ---------------------------------------------------------------------------
  // RX beat fork: each accepted RIFL RX beat feeds the data + tkeep FIFOs, and on
  // its TLAST beat also pushes the packet length into the RX length FIFO.  The
  // beat is accepted only when every target it feeds has room (length only needed
  // on a TLAST beat) so the three streams stay in lockstep.
  // ---------------------------------------------------------------------------
  wire rxd_tready, tk_tready, len_in_ready;
  wire len_ok = ~(r_tvalid & r_tlast) | len_in_ready;     // length-FIFO room on TLAST beats only
  assign r_tready = rxd_tready & tk_tready & len_ok;
  wire rxd_tvalid = r_tvalid & tk_tready & len_ok;         // data push when tkeep (+len) ready
  wire tk_tvalid  = r_tvalid & rxd_tready & len_ok;        // tkeep push when data (+len) ready
  wire len_push   = r_tvalid & r_tlast & rxd_tready & tk_tready;  // FIFO tready gates the push

  // packet-length counter (value, up to RX_FIFO_DEPTH beats) for the RX length FIFO
  wire fork_fire = r_tvalid & r_tready;
  logic [RX_CNT_WIDTH-1:0] rx_len;                         // prior beats in the current RX packet
  always_ff @(posedge aclk) begin
    if (~aresetn)       rx_len <= '0;
    else if (fork_fire) rx_len <= r_tlast ? '0 : (rx_len + 1'b1);
  end
  wire [AXI_DATA_WIDTH-1:0] len_din = AXI_DATA_WIDTH'(rx_len + 1'b1);  // include the TLAST beat

  // ---------------------------------------------------------------------------
  // AXI read demux: route AR/R to data / tkeep / length FIFO by araddr[15:14].
  // Backward compatible: data at 0x0, tkeep at 0x8000, length at 0xC000.
  // Serialized: accept a new AR only when no read burst is in flight.
  // ---------------------------------------------------------------------------
  wire [1:0] ar_sel  = s_axi_araddr[DECODE_BIT -: 2];      // [15:14]
  wire ar_is_data = ~ar_sel[1];                            // 0x0000-0x7FFF
  wire ar_is_tk   = (ar_sel == 2'b10);                     // 0x8000-0xBFFF
  wire ar_is_len  = (ar_sel == 2'b11);                     // 0xC000-0xFFFF

  logic       rd_active;
  logic [1:0] r_sel;
  wire  ar_fire    = s_axi_arvalid & s_axi_arready;
  wire  rlast_fire = s_axi_rvalid  & s_axi_rready & s_axi_rlast;

  always_ff @(posedge aclk) begin
    if (~aresetn) begin
      rd_active <= 1'b0;
      r_sel     <= 2'b00;
    end else if (ar_fire) begin
      rd_active <= 1'b1;
      r_sel     <= ar_sel;
    end else if (rlast_fire) begin
      rd_active <= 1'b0;
    end
  end

  // per-FIFO read-channel handshake signals
  wire                      rxd_arready, tk_arready, len_arready;
  wire [AXI_DATA_WIDTH-1:0] rxd_rdata,   tk_rdata,   len_rdata;
  wire [1:0]                rxd_rresp,   tk_rresp,   len_rresp;
  wire                      rxd_rlast,   tk_rlast,   len_rlast;
  wire                      rxd_rvalid,  tk_rvalid,  len_rvalid;

  wire rxd_arvalid = s_axi_arvalid & ~rd_active & ar_is_data;
  wire tk_arvalid  = s_axi_arvalid & ~rd_active & ar_is_tk;
  wire len_arvalid = s_axi_arvalid & ~rd_active & ar_is_len;
  assign s_axi_arready = ~rd_active &
       (ar_is_data ? rxd_arready : ar_is_tk ? tk_arready : len_arready);

  wire rs_data = ~r_sel[1];
  wire rs_tk   = (r_sel == 2'b10);
  wire rs_len  = (r_sel == 2'b11);
  assign s_axi_rvalid = rd_active & (rs_tk ? tk_rvalid : rs_len ? len_rvalid : rxd_rvalid);
  assign s_axi_rdata  =             rs_tk ? tk_rdata   : rs_len ? len_rdata   : rxd_rdata;
  assign s_axi_rresp  =             rs_tk ? tk_rresp   : rs_len ? len_rresp   : rxd_rresp;
  assign s_axi_rlast  =             rs_tk ? tk_rlast   : rs_len ? len_rlast   : rxd_rlast;
  wire rxd_rready = rd_active & rs_data & s_axi_rready;
  wire tk_rready  = rd_active & rs_tk   & s_axi_rready;
  wire len_rready = rd_active & rs_len  & s_axi_rready;

  // ---------------------------------------------------------------------------
  // TX: shared AXI write channel -> data+descriptor FIFO -> register slice -> m_axis
  // (read channel tied off).  awaddr[15] selects data write vs packet commit.
  // ---------------------------------------------------------------------------
  wire [AXI_DATA_WIDTH-1:0] tx_m_tdata;
  wire                      tx_m_tlast, tx_m_tvalid, tx_m_tready;
  axi_full_to_axis_fifo #(
     .AXI_DATA_WIDTH(AXI_DATA_WIDTH)
    ,.AXI_ADDR_WIDTH(AXI_ADDR_WIDTH)
    ,.FIFO_DEPTH    (TX_FIFO_DEPTH)
    ,.DESC_DEPTH    (TX_DESC_DEPTH)
    ,.COMMIT_BIT    (DECODE_BIT)
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
    ,.m_axis_tdata(tx_m_tdata), .m_axis_tlast(tx_m_tlast)
    ,.m_axis_tvalid(tx_m_tvalid), .m_axis_tready(tx_m_tready)
    ,.desc_count_o(tx_desc_count_o)
  );

  // TX register slice: break the long TX FIFO -> RIFL s_axis route.
  axis_skid_buffer #(.W(1 + AXI_DATA_WIDTH)) tx_skid (
     .clk(aclk), .rstn(aresetn)
    ,.s_data ({tx_m_tlast, tx_m_tdata})
    ,.s_valid(tx_m_tvalid), .s_ready(tx_m_tready)
    ,.m_data ({m_axis_tlast, m_axis_tdata})
    ,.m_valid(m_axis_tvalid), .m_ready(m_axis_tready)
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
    ,.s_axis_tdata(r_tdata), .s_axis_tlast(r_tlast)
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
    ,.s_axis_tkeep(r_tkeep), .s_axis_tlast(r_tlast)
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

  // ---------------------------------------------------------------------------
  // RX length: one word per received packet (its beat-count) -> read demux
  // (length side, +0xC000).  Pushed on the packet's TLAST beat; AXIS push unused
  // otherwise.  Reuses axis_to_axi_full_fifo (length carried in the low bits).
  // ---------------------------------------------------------------------------
  axis_to_axi_full_fifo #(
     .AXI_DATA_WIDTH(AXI_DATA_WIDTH)
    ,.AXI_ADDR_WIDTH(AXI_ADDR_WIDTH)
    ,.FIFO_DEPTH    (RX_PKT_DEPTH)
  ) len_fifo (
     .aclk(aclk), .aresetn(aresetn)
    ,.s_axis_tdata(len_din), .s_axis_tlast(1'b0)
    ,.s_axis_tvalid(len_push), .s_axis_tready(len_in_ready)
    ,.s_axi_awaddr('0), .s_axi_awlen('0), .s_axi_awsize('0), .s_axi_awburst('0)
    ,.s_axi_awlock('0), .s_axi_awcache('0), .s_axi_awprot('0), .s_axi_awqos('0)
    ,.s_axi_awregion('0), .s_axi_awvalid(1'b0), .s_axi_awready()
    ,.s_axi_wdata('0), .s_axi_wstrb('0), .s_axi_wlast(1'b0), .s_axi_wvalid(1'b0), .s_axi_wready()
    ,.s_axi_bresp(), .s_axi_bvalid(), .s_axi_bready(1'b0)
    ,.s_axi_araddr(s_axi_araddr), .s_axi_arlen(s_axi_arlen), .s_axi_arsize(s_axi_arsize)
    ,.s_axi_arburst(s_axi_arburst), .s_axi_arlock(s_axi_arlock), .s_axi_arcache(s_axi_arcache)
    ,.s_axi_arprot(s_axi_arprot), .s_axi_arqos(s_axi_arqos), .s_axi_arregion(s_axi_arregion)
    ,.s_axi_arvalid(len_arvalid), .s_axi_arready(len_arready)
    ,.s_axi_rdata(len_rdata), .s_axi_rresp(len_rresp), .s_axi_rlast(len_rlast)
    ,.s_axi_rvalid(len_rvalid), .s_axi_rready(len_rready)
    ,.count_o(rx_pkt_count_o)
  );

endmodule


// -----------------------------------------------------------------------------
// axis_skid_buffer: 2-deep AXI-Stream register slice (pipeline register + skid).
// Registers the forward data/valid path so it can be placed midway on a long
// route; full throughput in steady state.  Payload is opaque (W bits).
// -----------------------------------------------------------------------------
module axis_skid_buffer #(parameter integer W = 257)
(
    input  wire         clk
  , input  wire         rstn
  , input  wire [W-1:0] s_data
  , input  wire         s_valid
  , output wire         s_ready
  , output wire [W-1:0] m_data
  , output wire         m_valid
  , input  wire         m_ready
);
  reg          full;        // skid register occupied
  reg [W-1:0]  skid_data;
  reg          out_valid;
  reg [W-1:0]  out_data;

  assign s_ready = ~full;
  assign m_valid = out_valid;
  assign m_data  = out_data;

  wire s_fire = s_valid & ~full;

  always @(posedge clk) begin
    if (~rstn) begin
      full      <= 1'b0;
      out_valid <= 1'b0;
    end else if (~out_valid | m_ready) begin
      // output register free to (re)load: drain skid if present, else take input
      if (full) begin
        out_data  <= skid_data;
        out_valid <= 1'b1;
        full      <= 1'b0;
      end else begin
        out_data  <= s_data;
        out_valid <= s_fire;
      end
    end else if (s_fire) begin
      // output stalled (out_valid & ~m_ready): capture one word into the skid
      skid_data <= s_data;
      full      <= 1'b1;
    end
  end
endmodule

`default_nettype wire
