`timescale 1 ps / 1 ps
`default_nettype none

// -----------------------------------------------------------------------------
// axi_full_to_axis_fifo
//
// AXI4 (full) write slave  ->  data FIFO + descriptor FIFO  ->  AXI-Stream master.
//
// Packet framing is DESCRIPTOR-DRIVEN, so software can buffer several variable-size
// packets and have them drain as distinct AXIS packets ("load many, then enable"):
//   * WRITE with awaddr[COMMIT_BIT]==0  -> DATA: each W beat pushes one word into
//     the data FIFO and increments the running length wr_len.
//   * WRITE with awaddr[COMMIT_BIT]==1  -> COMMIT: on its last beat, push wr_len
//     (the just-written packet's beat-count) into the descriptor FIFO and reset
//     wr_len.  No data is pushed; a zero-length commit is dropped.
//   * The AXI-Stream side drains only while axis_enable is high.  A small FSM pops
//     a length L from the descriptor FIFO and emits exactly L beats, asserting
//     TLAST on the L-th (rem==1), then pops the next descriptor.  So each buffered
//     packet leaves with its own correct TLAST boundary.
//
// AW/W handshake: one outstanding write.  AW is accepted (awready=~aw_active) and
// its awaddr[COMMIT_BIT] latched; WREADY is held low until that AW is registered
// (removes AW/W skew) and is gated by ~fifo_full (data) or ~desc_full (commit), so
// neither FIFO overflows and the data and descriptor streams never desynchronize.
// One OKAY B response per write burst (per accepted WLAST).
//
// Single clock domain (aclk).  FWFT FIFOs (head read combinationally).
// The AXI read channel is unused; it returns arlen+1 zero beats so reads never hang.
// -----------------------------------------------------------------------------
module axi_full_to_axis_fifo #
(
    parameter integer AXI_DATA_WIDTH = 256
  , parameter integer AXI_ADDR_WIDTH = 32
  , parameter integer FIFO_DEPTH     = 512          // data FIFO, power of two, >= 2
  , parameter integer DESC_DEPTH     = 64           // descriptor FIFO (max buffered packets)
  , parameter integer COMMIT_BIT     = 15           // awaddr bit: 1 => commit a packet
  , localparam integer STRB_WIDTH    = AXI_DATA_WIDTH/8
  , localparam integer PTR_WIDTH     = $clog2(FIFO_DEPTH)
  , localparam integer CNT_WIDTH     = $clog2(FIFO_DEPTH) + 1
  , localparam integer DPTR_WIDTH    = $clog2(DESC_DEPTH)
  , localparam integer DCNT_WIDTH    = $clog2(DESC_DEPTH) + 1
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
  , input  wire                       s_axi_wlast
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

  // ---- descriptor FIFO occupancy (packets buffered, ready to drain) ----
  , output wire [DCNT_WIDTH-1:0]      desc_count_o
);

  // ---------------------------------------------------------------------------
  // Data FIFO (first-word-fall-through)
  // ---------------------------------------------------------------------------
  (* ram_style = "distributed" *)
  logic [AXI_DATA_WIDTH-1:0] mem [FIFO_DEPTH-1:0];
  logic [PTR_WIDTH-1:0]      wptr;
  logic [PTR_WIDTH-1:0]      rptr;
  logic [CNT_WIDTH-1:0]      count;

  wire fifo_full  = (count == FIFO_DEPTH);
  wire fifo_empty = (count == 0);

  // ---------------------------------------------------------------------------
  // Descriptor FIFO (per-packet beat-count, FWFT)
  // ---------------------------------------------------------------------------
  (* ram_style = "distributed" *)
  logic [CNT_WIDTH-1:0]  desc_mem [DESC_DEPTH-1:0];
  logic [DPTR_WIDTH-1:0] dwptr;
  logic [DPTR_WIDTH-1:0] drptr;
  logic [DCNT_WIDTH-1:0] dcount;

  wire desc_full  = (dcount == DESC_DEPTH);
  wire desc_empty = (dcount == 0);
  wire [CNT_WIDTH-1:0] desc_head = desc_mem[drptr];
  assign desc_count_o = dcount;

  // ---------------------------------------------------------------------------
  // AW / W : one outstanding write; decode commit-vs-data on awaddr[COMMIT_BIT]
  // ---------------------------------------------------------------------------
  logic aw_active;       // an AW is accepted; its W beats may flow
  logic is_commit_q;     // latched awaddr[COMMIT_BIT] of the current AW

  assign s_axi_awready = ~aw_active;
  wire   aw_fire = s_axi_awvalid & s_axi_awready;

  // W flows only after its AW is registered: data gated by ~fifo_full, commit by ~desc_full
  assign s_axi_wready = aw_active & (is_commit_q ? ~desc_full : ~fifo_full);
  wire   w_fire = s_axi_wvalid & s_axi_wready;
  wire   push   = w_fire & ~is_commit_q;                 // data beat -> data FIFO
  wire   commit = w_fire &  is_commit_q & s_axi_wlast;   // end of a commit transaction

  // running beat-count of the packet currently being written
  logic [CNT_WIDTH-1:0] wr_len;
  wire   desc_push = commit & (wr_len != 0);             // drop zero-length commits

  always_ff @(posedge aclk) begin
    if (~aresetn) begin
      aw_active   <= 1'b0;
      is_commit_q <= 1'b0;
    end else if (aw_fire) begin
      aw_active   <= 1'b1;
      is_commit_q <= s_axi_awaddr[COMMIT_BIT];
    end else if (w_fire & s_axi_wlast) begin
      aw_active   <= 1'b0;                               // transaction complete
    end
  end

  always_ff @(posedge aclk) begin
    if (~aresetn)    wr_len <= '0;
    else if (commit) wr_len <= '0;                       // reset after committing
    else if (push)   wr_len <= wr_len + 1'b1;
  end

  // ---------------------------------------------------------------------------
  // Drain FSM : pop a length L (only while enabled), emit L beats, TLAST on L-th.
  // ---------------------------------------------------------------------------
  logic [CNT_WIDTH-1:0] rem;                            // beats left in current packet
  wire   desc_pop = (rem == 0) & ~desc_empty & axis_enable;   // start next packet

  assign m_axis_tvalid = axis_enable & (rem != 0) & ~fifo_empty;
  assign m_axis_tdata  = mem[rptr];
  assign m_axis_tlast  = (rem == 1);
  wire   pop           = m_axis_tvalid & m_axis_tready;

  always_ff @(posedge aclk) begin
    if (~aresetn)       rem <= '0;
    else if (rem == 0) begin
      if (desc_pop)     rem <= desc_head;
    end else if (pop)   rem <= rem - 1'b1;
  end

  // ---- data FIFO pointers / count ----
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

  // ---- descriptor FIFO pointers / count ----
  always_ff @(posedge aclk) begin
    if (~aresetn) begin
      dwptr  <= '0;
      drptr  <= '0;
      dcount <= '0;
    end else begin
      if (desc_push) begin
        desc_mem[dwptr] <= wr_len;
        dwptr           <= dwptr + 1'b1;
      end
      if (desc_pop)
        drptr <= drptr + 1'b1;
      case ({desc_push, desc_pop})
        2'b10:   dcount <= dcount + 1'b1;
        2'b01:   dcount <= dcount - 1'b1;
        default: dcount <= dcount;
      endcase
    end
  end

  // ---------------------------------------------------------------------------
  // AXI write response : one OKAY B per write burst (per accepted WLAST).
  // ---------------------------------------------------------------------------
  logic [7:0] bcount;
  wire  wlast_beat = w_fire & s_axi_wlast;               // covers data AND commit
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
  assign s_axi_bresp  = 2'b00;             // OKAY

  // ---------------------------------------------------------------------------
  // AXI read channel : unused.  Accept any read and return arlen+1 zero beats.
  // ---------------------------------------------------------------------------
  logic       r_busy;
  logic [7:0] r_remaining;

  assign s_axi_arready = ~r_busy;
  assign s_axi_rdata   = '0;
  assign s_axi_rresp   = 2'b00;            // OKAY
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
