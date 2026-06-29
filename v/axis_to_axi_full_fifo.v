`timescale 1 ps / 1 ps
`default_nettype none

// -----------------------------------------------------------------------------
// axis_to_axi_full_fifo
//
// The reverse of axi_full_to_axis_fifo:
//   AXI-Stream slave (push)  ->  FIFO  ->  AXI4 (full) read slave (pop).
//
//   * Every AXI-Stream beat (TVALID & TREADY) pushes TDATA into the FIFO.
//     TLAST is accepted but ignored (no framing is stored).  TREADY = not-full.
//   * The AXI4 read channel pops the FIFO: AR is accepted (ARADDR ignored -- the
//     FIFO is address-agnostic) and ARLEN+1 words are returned, one per accepted
//     R beat (RVALID & RREADY), dequeuing each.  RVALID stalls (low) while the
//     FIFO is empty, so a read waits for data -- a read of more words than are
//     (or will become) available will block.
//   * The AXI4 write channel is unused; it accepts writes and returns one OKAY B
//     response per burst (data discarded) so a master that writes never hangs.
//
// Single clock domain (aclk).  First-word-fall-through FIFO (head read
// combinationally) so RDATA is valid the cycle RVALID asserts.
// -----------------------------------------------------------------------------
module axis_to_axi_full_fifo #
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

  // ---- AXI-Stream slave (push side) ----
  , input  wire [AXI_DATA_WIDTH-1:0]  s_axis_tdata
  , input  wire                       s_axis_tlast      // accepted but ignored
  , input  wire                       s_axis_tvalid
  , output wire                       s_axis_tready

  // ---- AXI4 (full) slave : write address channel (unused) ----
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
  // ---- write data channel (unused) ----
  , input  wire [AXI_DATA_WIDTH-1:0]  s_axi_wdata
  , input  wire [STRB_WIDTH-1:0]      s_axi_wstrb
  , input  wire                       s_axi_wlast
  , input  wire                       s_axi_wvalid
  , output wire                       s_axi_wready
  // ---- write response channel ----
  , output wire [1:0]                 s_axi_bresp
  , output wire                       s_axi_bvalid
  , input  wire                       s_axi_bready

  // ---- AXI4 (full) slave : read address channel ----
  , input  wire [AXI_ADDR_WIDTH-1:0]  s_axi_araddr      // ignored (address-agnostic)
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
  // ---- read data channel ----
  , output wire [AXI_DATA_WIDTH-1:0]  s_axi_rdata
  , output wire [1:0]                 s_axi_rresp
  , output wire                       s_axi_rlast
  , output wire                       s_axi_rvalid
  , input  wire                       s_axi_rready

  // ---- FIFO occupancy (number of words available to read), this clock domain ----
  , output wire [CNT_WIDTH-1:0]       count_o
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
  assign count_o  = count;

  // ---- AXI-Stream push -> FIFO ----
  assign s_axis_tready = ~fifo_full;
  wire   push          = s_axis_tvalid & s_axis_tready;

  // ---- AXI read pop (driven by the read FSM below) ----
  wire   pop;

  always_ff @(posedge aclk) begin
    if (~aresetn) begin
      wptr  <= '0;
      rptr  <= '0;
      count <= '0;
    end else begin
      if (push) begin
        mem[wptr] <= s_axis_tdata;
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
  // AXI read channel: accept AR (address ignored), return ARLEN+1 FIFO words,
  // one per R beat, dequeuing each.  RVALID stalls while the FIFO is empty.
  // ---------------------------------------------------------------------------
  logic       r_busy;
  logic [7:0] r_remaining;

  assign s_axi_arready = ~r_busy;
  assign s_axi_rdata   = mem[rptr];
  assign s_axi_rresp   = 2'b00;                 // OKAY
  assign s_axi_rvalid  = r_busy & ~fifo_empty;
  assign s_axi_rlast   = s_axi_rvalid & (r_remaining == 8'd0);
  assign pop           = s_axi_rvalid & s_axi_rready;

  always_ff @(posedge aclk) begin
    if (~aresetn) begin
      r_busy      <= 1'b0;
      r_remaining <= 8'd0;
    end else if (~r_busy) begin
      if (s_axi_arvalid) begin
        r_busy      <= 1'b1;
        r_remaining <= s_axi_arlen;
      end
    end else if (pop) begin
      if (r_remaining == 8'd0)
        r_busy <= 1'b0;
      else
        r_remaining <= r_remaining - 8'd1;
    end
  end

  // ---------------------------------------------------------------------------
  // AXI write channel: unused.  Accept the burst and return one OKAY B response
  // per WLAST so a master that writes never hangs (write data is discarded).
  // ---------------------------------------------------------------------------
  assign s_axi_awready = 1'b1;
  assign s_axi_wready  = 1'b1;

  logic [7:0] bcount;
  wire  wlast_beat = s_axi_wvalid & s_axi_wready & s_axi_wlast;
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
  assign s_axi_bresp  = 2'b00;                   // OKAY

endmodule

`default_nettype wire
