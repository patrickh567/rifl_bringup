`timescale 1 ps / 1 ps
`default_nettype none

// -----------------------------------------------------------------------------
// axi_full_to_axis_fifo
//
// AXI4 (full) write slave  ->  FIFO  ->  AXI-Stream master.
//
//   * Every AXI write data beat (WVALID & WREADY) is pushed into the FIFO.
//     WLAST is IGNORED for framing -- it is used only to return the AXI write
//     response (one B per write burst).
//   * The AXI-Stream side drains the FIFO only while axis_enable is high.
//     One word is dequeued per accepted beat (TVALID & TREADY).
//   * TLAST is asserted on the beat that empties the FIFO -- i.e. when the word
//     being dequeued is the last one currently in the FIFO (occupancy == 1).
//
// Single clock domain (aclk).  The FIFO is first-word-fall-through (the head is
// presented combinationally) so the occupancy->TLAST decision is exact.
//
// The AXI read channel is unused; it safely returns arlen+1 zero beats so a
// master that issues reads never hangs.
//
// Note: with concurrent writes during a drain, "occupancy == 1" can recur, so
// TLAST is only a clean single packet boundary in the intended fill-then-drain
// use (stop writing, then raise axis_enable to release the buffered packet).
// -----------------------------------------------------------------------------
module axi_full_to_axis_fifo #
(
    parameter integer AXI_DATA_WIDTH = 256
  , parameter integer AXI_ADDR_WIDTH = 32
  , parameter integer FIFO_DEPTH     = 512          // power of two, >= 2
  , localparam integer STRB_WIDTH    = AXI_DATA_WIDTH/8
  , localparam integer PTR_WIDTH     = $clog2(FIFO_DEPTH)
  , localparam integer CNT_WIDTH     = $clog2(FIFO_DEPTH) + 1
)
(
    input  wire                       aclk
  , input  wire                       aresetn          // active-low

  // ---- AXI4 (full) slave : write address channel ----
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
  // ---- write data channel ----
  , input  wire [AXI_DATA_WIDTH-1:0]  s_axi_wdata
  , input  wire [STRB_WIDTH-1:0]      s_axi_wstrb       // ignored
  , input  wire                       s_axi_wlast       // ignored for framing
  , input  wire                       s_axi_wvalid
  , output wire                       s_axi_wready
  // ---- write response channel ----
  , output wire [1:0]                 s_axi_bresp
  , output wire                       s_axi_bvalid
  , input  wire                       s_axi_bready

  // ---- AXI4 (full) slave : read channel (unused, returns zeros) ----
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

  // ---- AXI-Stream master (FIFO read side) ----
  , input  wire                       axis_enable       // gate the stream side
  , output wire [AXI_DATA_WIDTH-1:0]  m_axis_tdata
  , output wire                       m_axis_tlast
  , output wire                       m_axis_tvalid
  , input  wire                       m_axis_tready
);

  // ---------------------------------------------------------------------------
  // FIFO storage (first-word-fall-through: head read combinationally)
  // ---------------------------------------------------------------------------
  (* ram_style = "distributed" *)
  logic [AXI_DATA_WIDTH-1:0] mem [FIFO_DEPTH-1:0];
  logic [PTR_WIDTH-1:0]      wptr;
  logic [PTR_WIDTH-1:0]      rptr;
  logic [CNT_WIDTH-1:0]      count;

  wire fifo_full  = (count == FIFO_DEPTH);
  wire fifo_empty = (count == 0);

  // ---- write data -> FIFO ----
  assign s_axi_wready = ~fifo_full;
  wire   push         = s_axi_wvalid & s_axi_wready;

  // ---- AXI-Stream drain ----
  assign m_axis_tvalid = axis_enable & ~fifo_empty;
  assign m_axis_tdata  = mem[rptr];
  assign m_axis_tlast  = m_axis_tvalid & (count == 1);
  wire   pop           = m_axis_tvalid & m_axis_tready;

  always_ff @(posedge aclk) begin
    if (~aresetn) begin
      wptr  <= '0;
      rptr  <= '0;
      count <= '0;
    end else begin
      if (push) begin
        mem[wptr] <= s_axi_wdata;
        wptr      <= wptr + 1'b1;
      end
      if (pop)
        rptr <= rptr + 1'b1;
      case ({push, pop})
        2'b10:   count <= count + 1'b1;
        2'b01:   count <= count - 1'b1;
        default: count <= count;
      endcase
    end
  end

  // ---------------------------------------------------------------------------
  // AXI write address + response.  AW is accepted and its address ignored
  // (the FIFO is address-agnostic).  One B response is returned per write burst
  // (per accepted WLAST).  Assumes a bounded number of outstanding writes.
  // ---------------------------------------------------------------------------
  assign s_axi_awready = 1'b1;

  logic [7:0] bcount;                       // outstanding B responses to send
  wire  wlast_beat = push & s_axi_wlast;
  wire  b_fire     = s_axi_bvalid & s_axi_bready;

  always_ff @(posedge aclk) begin
    if (~aresetn)
      bcount <= 8'd0;
    else
      case ({wlast_beat, b_fire})
        2'b10:   bcount <= bcount + 8'd1;
        2'b01:   bcount <= bcount - 8'd1;
        default: bcount <= bcount;
      endcase
  end

  assign s_axi_bvalid = (bcount != 8'd0);
  assign s_axi_bresp  = 2'b00;              // OKAY

  // ---------------------------------------------------------------------------
  // AXI read channel : unused.  Accept any read and return arlen+1 zero beats.
  // ---------------------------------------------------------------------------
  logic       r_busy;
  logic [7:0] r_remaining;

  assign s_axi_arready = ~r_busy;
  assign s_axi_rdata   = '0;
  assign s_axi_rresp   = 2'b00;             // OKAY
  assign s_axi_rvalid  = r_busy;
  assign s_axi_rlast   = r_busy & (r_remaining == 8'd0);

  always_ff @(posedge aclk) begin
    if (~aresetn) begin
      r_busy      <= 1'b0;
      r_remaining <= 8'd0;
    end else if (~r_busy) begin
      if (s_axi_arvalid) begin
        r_busy      <= 1'b1;
        r_remaining <= s_axi_arlen;
      end
    end else if (s_axi_rvalid & s_axi_rready) begin
      if (r_remaining == 8'd0)
        r_busy <= 1'b0;
      else
        r_remaining <= r_remaining - 8'd1;
    end
  end

endmodule

`default_nettype wire
