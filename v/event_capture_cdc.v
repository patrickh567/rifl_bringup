`timescale 1 ps / 1 ps
`default_nettype none

// -----------------------------------------------------------------------------
// event_capture_cdc
//
// Captures occurrences of a transient event in the source (event) clock domain
// and presents a {sticky, count} status word in the destination domain.
//
//   * While enable_i is high:
//       - count occurrences (rising edges of event_i), saturating at all-ones;
//       - set the sticky bit on the first occurrence.
//   * While enable_i is low: the count and sticky bit are held cleared.
//
// The count is carried to the destination domain with xpm_cdc_gray and the
// sticky bit with xpm_cdc_single.  status_o = { sticky, 0.., count }.
//
// NOTE: clearing the counter (enable 1->0) is a multi-bit jump to 0, which is
// not gray-lossless; the gray sync may show a one-cycle transient before it
// settles to 0.  This is harmless because the count is only meaningful while
// enabled -- read it during / at the end of the packet, before de-asserting the
// enable (which then clears it for the next packet).
//
// COUNT_WIDTH must be <= 31 (one bit is reserved for the sticky flag).
// -----------------------------------------------------------------------------
module event_capture_cdc #
(
    parameter integer COUNT_WIDTH = 16
)
(
    input  wire        src_clk    // event / source clock domain
  , input  wire        enable_i   // src-domain: high = capture, low = clear + hold
  , input  wire        event_i    // src-domain transient; an occurrence = a rising edge
  , input  wire        dst_clk    // destination (status) clock domain
  , output wire [31:0] status_o   // dst-domain { sticky, 0.., count }
);

  logic                   event_q;
  logic                   sticky_r;
  logic [COUNT_WIDTH-1:0] count_r;

  wire event_rise = event_i & ~event_q;       // one occurrence per rising edge
  wire saturated  = &count_r;

  always_ff @(posedge src_clk) begin
    event_q <= event_i;                       // always track, so the enable edge is clean
    if (~enable_i) begin
      sticky_r <= 1'b0;
      count_r  <= '0;
    end else if (event_rise) begin
      sticky_r <= 1'b1;
      if (~saturated)
        count_r <= count_r + 1'b1;
    end
  end

  // count -> destination domain (gray-coded)
  wire [COUNT_WIDTH-1:0] count_dst;
  xpm_cdc_gray #(
     .DEST_SYNC_FF         (4)
    ,.INIT_SYNC_FF         (0)
    ,.REG_OUTPUT           (1)
    ,.SIM_ASSERT_CHK       (0)
    ,.SIM_LOSSLESS_GRAY_CHK(0)   // counter is cleared (multi-bit jump) when disabled
    ,.WIDTH                (COUNT_WIDTH)
  ) u_count_cdc (
     .dest_out_bin(count_dst)
    ,.dest_clk    (dst_clk)
    ,.src_clk     (src_clk)
    ,.src_in_bin  (count_r)
  );

  // sticky -> destination domain (single-bit)
  wire sticky_dst;
  xpm_cdc_single #(
     .DEST_SYNC_FF  (4)
    ,.INIT_SYNC_FF  (0)
    ,.SIM_ASSERT_CHK(0)
    ,.SRC_INPUT_REG (0)
  ) u_sticky_cdc (
     .dest_out(sticky_dst)
    ,.dest_clk(dst_clk)
    ,.src_clk (1'b0)
    ,.src_in  (sticky_r)
  );

  assign status_o = { sticky_dst, {(31-COUNT_WIDTH){1'b0}}, count_dst };

endmodule

`default_nettype wire
