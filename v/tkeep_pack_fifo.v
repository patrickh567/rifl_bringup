`timescale 1 ps / 1 ps
`default_nettype none

// -----------------------------------------------------------------------------
// tkeep_pack_fifo
//
// Packs a per-beat tkeep stream into AXI_DATA_WIDTH-bit words and stores them in
// a FIFO read out over an AXI4 (full) read channel.  The storage + AXI read is
// the reverse FIFO (axis_to_axi_full_fifo); this module just adds the packing
// accumulator at its input.
//
//   * Input: one TKEEP_W-bit tkeep chunk per accepted beat (s_axis_tkeep), with
//     s_axis_tlast marking the end of a packet.  An accumulator register gathers
//     CHUNKS chunks (= AXI_DATA_WIDTH / TKEEP_W) into one word, chunk 0 in the
//     low bits.
//   * The accumulated word is pushed into the FIFO when it FILLS (CHUNKS chunks)
//     OR when TLAST is seen (a partial final word is flushed; unused chunks = 0).
//   * Output: AXI4 reads pop packed words; count_o = occupancy in packed words.
//     The AXI write channel is unused (stubbed by the inner FIFO).
//
// TKEEP_W defaults to AXI_DATA_WIDTH/8 (one tkeep bit per data byte), so
// CHUNKS = 8 (eight 32-bit tkeep chunks -> one 256-bit word).
// -----------------------------------------------------------------------------
module tkeep_pack_fifo #
(
    parameter integer AXI_DATA_WIDTH = 256
  , parameter integer AXI_ADDR_WIDTH = 32
  , parameter integer FIFO_DEPTH     = 512
  , localparam integer TKEEP_W       = AXI_DATA_WIDTH/8
  , localparam integer CHUNKS        = AXI_DATA_WIDTH/TKEEP_W
  , localparam integer CHUNK_CNT_W   = $clog2(CHUNKS)
  , localparam integer CNT_WIDTH     = $clog2(FIFO_DEPTH) + 1
  , localparam integer STRB_WIDTH    = AXI_DATA_WIDTH/8
)
(
    input  wire                       aclk
  , input  wire                       aresetn

  // ---- input: per-beat tkeep stream (one chunk per accepted beat) ----
  , input  wire [TKEEP_W-1:0]         s_axis_tkeep
  , input  wire                       s_axis_tlast
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
  , input  wire [AXI_DATA_WIDTH-1:0]  s_axi_wdata
  , input  wire [STRB_WIDTH-1:0]      s_axi_wstrb
  , input  wire                       s_axi_wlast
  , input  wire                       s_axi_wvalid
  , output wire                       s_axi_wready
  , output wire [1:0]                 s_axi_bresp
  , output wire                       s_axi_bvalid
  , input  wire                       s_axi_bready
  // ---- AXI4 (full) slave : read channel (packed tkeep words) ----
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

  // ---- packed-word occupancy (words available to read) ----
  , output wire [CNT_WIDTH-1:0]       count_o
);

  // ---------------------------------------------------------------------------
  // Packing accumulator: gather CHUNKS tkeep chunks into one word; push on
  // FILL (chunk_cnt == CHUNKS-1) or TLAST.  chunk_cnt is the next slot to fill.
  // ---------------------------------------------------------------------------
  logic [AXI_DATA_WIDTH-1:0] acc_reg;
  logic [CHUNK_CNT_W-1:0]    chunk_cnt;

  wire fifo_in_ready;
  wire is_push   = s_axis_tvalid & (s_axis_tlast | (chunk_cnt == CHUNKS-1));
  assign s_axis_tready = is_push ? fifo_in_ready : 1'b1;  // only need FIFO room on a push beat
  wire in_beat   = s_axis_tvalid & s_axis_tready;
  wire fifo_push = is_push & s_axis_tvalid;               // inner-FIFO tvalid (accepts when fifo_in_ready)

  // word presented to the FIFO: accumulator with the current chunk inserted
  logic [AXI_DATA_WIDTH-1:0] push_word;
  always_comb begin
    push_word = acc_reg;
    push_word[chunk_cnt*TKEEP_W +: TKEEP_W] = s_axis_tkeep;
  end

  always_ff @(posedge aclk) begin
    if (~aresetn) begin
      acc_reg   <= '0;
      chunk_cnt <= '0;
    end else if (in_beat) begin
      if (is_push) begin
        acc_reg   <= '0;
        chunk_cnt <= '0;
      end else begin
        acc_reg[chunk_cnt*TKEEP_W +: TKEEP_W] <= s_axis_tkeep;
        chunk_cnt <= chunk_cnt + 1'b1;
      end
    end
  end

  // ---------------------------------------------------------------------------
  // Storage + AXI read-out (reuse the reverse FIFO for packed words)
  // ---------------------------------------------------------------------------
  axis_to_axi_full_fifo #(
     .AXI_DATA_WIDTH(AXI_DATA_WIDTH)
    ,.AXI_ADDR_WIDTH(AXI_ADDR_WIDTH)
    ,.FIFO_DEPTH    (FIFO_DEPTH)
  ) fifo (
     .aclk          (aclk)
    ,.aresetn       (aresetn)
    ,.s_axis_tdata  (push_word)
    ,.s_axis_tlast  (1'b0)
    ,.s_axis_tvalid (fifo_push)
    ,.s_axis_tready (fifo_in_ready)
    ,.s_axi_awaddr  (s_axi_awaddr )
    ,.s_axi_awlen   (s_axi_awlen  )
    ,.s_axi_awsize  (s_axi_awsize )
    ,.s_axi_awburst (s_axi_awburst)
    ,.s_axi_awlock  (s_axi_awlock )
    ,.s_axi_awcache (s_axi_awcache)
    ,.s_axi_awprot  (s_axi_awprot )
    ,.s_axi_awqos   (s_axi_awqos  )
    ,.s_axi_awregion(s_axi_awregion)
    ,.s_axi_awvalid (s_axi_awvalid)
    ,.s_axi_awready (s_axi_awready)
    ,.s_axi_wdata   (s_axi_wdata  )
    ,.s_axi_wstrb   (s_axi_wstrb  )
    ,.s_axi_wlast   (s_axi_wlast  )
    ,.s_axi_wvalid  (s_axi_wvalid )
    ,.s_axi_wready  (s_axi_wready )
    ,.s_axi_bresp   (s_axi_bresp  )
    ,.s_axi_bvalid  (s_axi_bvalid )
    ,.s_axi_bready  (s_axi_bready )
    ,.s_axi_araddr  (s_axi_araddr )
    ,.s_axi_arlen   (s_axi_arlen  )
    ,.s_axi_arsize  (s_axi_arsize )
    ,.s_axi_arburst (s_axi_arburst)
    ,.s_axi_arlock  (s_axi_arlock )
    ,.s_axi_arcache (s_axi_arcache)
    ,.s_axi_arprot  (s_axi_arprot )
    ,.s_axi_arqos   (s_axi_arqos  )
    ,.s_axi_arregion(s_axi_arregion)
    ,.s_axi_arvalid (s_axi_arvalid)
    ,.s_axi_arready (s_axi_arready)
    ,.s_axi_rdata   (s_axi_rdata  )
    ,.s_axi_rresp   (s_axi_rresp  )
    ,.s_axi_rlast   (s_axi_rlast  )
    ,.s_axi_rvalid  (s_axi_rvalid )
    ,.s_axi_rready  (s_axi_rready )
    ,.count_o       (count_o      )
  );

endmodule

`default_nettype wire
