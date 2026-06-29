`default_nettype none
`include "bsg_defines.v"

module dma_width_converter #(
    parameter `BSG_INV_PARAM(dma_data_width_p)
  , parameter `BSG_INV_PARAM(gty_data_width_p)

  // Optional packet store-and-forward buffering on the TX/RIFL side.
  // Counts are in RIFL/GTY-side flits, after PISO serialization.
  , parameter integer store_forward_en_p  = 1
  , parameter integer store_forward_els_p = 66
  , parameter integer max_packet_flits_p  = 66

  // RIFL-side deterministic throttling.
  , parameter integer modulo_flits_p      = 5
  , parameter integer modulo_bubbles_p    = 1
  , parameter integer packet_end_bubbles_p = 2

  , localparam ratio_lp = dma_data_width_p / gty_data_width_p
  , localparam counter_width_lp = `BSG_SAFE_CLOG2(ratio_lp)
  , localparam sf_packet_count_width_lp = `BSG_SAFE_CLOG2(max_packet_flits_p+1)
  , localparam modulo_count_width_lp = `BSG_SAFE_CLOG2(modulo_flits_p)
  , localparam max_bubbles_lp = (packet_end_bubbles_p > modulo_bubbles_p)
                              ? packet_end_bubbles_p
                              : modulo_bubbles_p
  , localparam bubble_count_width_lp = `BSG_SAFE_CLOG2(max_bubbles_lp+1)
)
(
    input wire                           dma_clk_i
  , input wire                           dma_reset_i

  , input wire                           gty_clk_i
  , input wire                           gty_reset_i

  , output logic [dma_data_width_p-1:0]  dma_tdata_o
  , output logic                         dma_tlast_o
  , input wire                           dma_tready_i
  , output logic                         dma_tvalid_o

  , input wire [dma_data_width_p-1:0]    dma_tdata_i
  , input wire                           dma_tlast_i
  , output logic                         dma_tready_o // ready_and
  , input wire                           dma_tvalid_i

  , output logic [gty_data_width_p-1:0]  gty_tdata_o
  , output logic                         gty_tlast_o
  , input wire                           gty_tready_i
  , output logic                         gty_tvalid_o

  , input wire [gty_data_width_p-1:0]    gty_tdata_i
  , input wire                           gty_tlast_i
  , output logic                         gty_tready_o // ready_and
  , input wire                           gty_tvalid_i
);
  if((dma_data_width_p < gty_data_width_p)
    || (dma_data_width_p % gty_data_width_p)) begin
    $error("%m bad data-width parameter");
  end
  if (store_forward_en_p
      && ((store_forward_els_p < 1)
          || (max_packet_flits_p < 1)
          || (max_packet_flits_p > store_forward_els_p))) begin
    $error("%m requires 1 <= max_packet_flits_p <= store_forward_els_p when store_forward_en_p is set");
  end
  if ((modulo_flits_p < 1) || (modulo_bubbles_p < 0) || (packet_end_bubbles_p < 0)) begin
    $error("%m bad throttling parameter");
  end

  begin: to_gty

    logic [ratio_lp-1:0][gty_data_width_p-1:0]  dma_tdata_i_sync;
    logic                                       dma_tlast_i_sync;
    logic                                       dma_tready_o_sync; // ready_and
    logic                                       dma_tvalid_i_sync;

    logic w_full_lo;
    assign dma_tready_o = ~w_full_lo;

    bsg_async_fifo #(
       .lg_size_p(3)
      ,.width_p(dma_data_width_p + 1)
    ) async_fifo (
       .w_clk_i(dma_clk_i)
      ,.w_reset_i(dma_reset_i)

      ,.w_enq_i(dma_tvalid_i & dma_tready_o)
      ,.w_data_i({dma_tdata_i, dma_tlast_i})
      ,.w_full_o(w_full_lo)

      ,.r_clk_i(gty_clk_i)
      ,.r_reset_i(gty_reset_i)
      ,.r_deq_i(dma_tvalid_i_sync & dma_tready_o_sync)
      ,.r_data_o({dma_tdata_i_sync, dma_tlast_i_sync})
      ,.r_valid_o(dma_tvalid_i_sync)
    );

    logic [ratio_lp-1:0][gty_data_width_p+1-1:0] piso_data_li;
    for(genvar i = 0; i < ratio_lp; i++) begin: r
      assign piso_data_li[i] = {dma_tlast_i_sync, dma_tdata_i_sync[i]};
    end

    logic gty_tyumi_i;
    logic gty_tlast_piso_lo;
    logic gty_tvalid_piso_lo;
    logic [gty_data_width_p-1:0] gty_tdata_piso_lo;
    logic [counter_width_lp-1:0] piso_idx;

    localparam [counter_width_lp-1:0] piso_last_idx_lp = ratio_lp-1;
    localparam [sf_packet_count_width_lp-1:0] max_packet_flits_lp
      = max_packet_flits_p;
    localparam [modulo_count_width_lp-1:0] modulo_last_count_lp
      = modulo_flits_p-1;
    localparam [bubble_count_width_lp-1:0] modulo_bubbles_lp
      = modulo_bubbles_p;
    localparam [bubble_count_width_lp-1:0] packet_end_bubbles_lp
      = packet_end_bubbles_p;

    bsg_parallel_in_serial_out #(
       .width_p(gty_data_width_p+1)
      ,.els_p(ratio_lp)
      ,.hi_to_lo_p(0)
    ) piso (
       .clk_i(gty_clk_i)
      ,.reset_i(gty_reset_i)

      ,.valid_i(dma_tvalid_i_sync)
      ,.data_i(piso_data_li)
      ,.ready_and_o(dma_tready_o_sync)

      ,.valid_o(gty_tvalid_piso_lo)
      ,.data_o({gty_tlast_piso_lo, gty_tdata_piso_lo})
      ,.yumi_i(gty_tyumi_i)
    );

    // The DMA-side TLAST is replicated onto every PISO slice.  Only the
    // final RIFL-side slice is the actual packet boundary.
    wire gty_tlast_piso_final_lo
      = gty_tlast_piso_lo & (piso_idx == piso_last_idx_lp);

    // Shared source into the RIFL-side isolation FIFO.  This source is
    // either the store-forward FIFO output or the direct PISO output.
    logic tx_src_ready_li;
    logic tx_src_v_lo;
    logic tx_src_tlast_lo;
    logic [gty_data_width_p-1:0] tx_src_tdata_lo;
    (* mark_debug = "true" *) logic sf_packet_too_long_dbg_r;

    if (store_forward_en_p) begin: store_forward_enabled
      // ---------------------------------------------------------------
      // Packet store-and-forward buffer.
      //
      // Data flits are buffered in one FIFO.  A second FIFO receives one
      // token only after the corresponding packet TLAST has been accepted.
      // The output side is enabled only while a packet token is available,
      // so no packet begins transmission until its complete contents have
      // reached the data FIFO.  Later packets may be buffered at the tail
      // while older complete packets drain.  The token is popped with that
      // packet's TLAST.
      // ---------------------------------------------------------------
      logic sf_data_fifo_ready_lo;
      logic sf_data_fifo_v_li;
      logic sf_data_fifo_v_lo;
      logic sf_data_fifo_yumi_li;
      logic sf_data_tlast_lo;
      logic [gty_data_width_p-1:0] sf_data_lo;

      logic sf_ctrl_fifo_ready_lo;
      logic sf_ctrl_fifo_v_lo;
      logic sf_ctrl_fifo_yumi_li;

      logic [sf_packet_count_width_lp-1:0] sf_packet_flit_count_r;

      // Packet-pipelined admission: accept the next packet whenever the
      // physical data FIFO has space.  The completion-token FIFO prevents
      // any incomplete packet from reaching the output.
      wire sf_current_packet_has_room_lo
        = (sf_packet_flit_count_r < max_packet_flits_lp);
      wire sf_ingress_enable_lo = sf_current_packet_has_room_lo;

      // On TLAST, data and its completion token must be accepted atomically.
      assign sf_data_fifo_v_li
        = gty_tvalid_piso_lo
          & sf_ingress_enable_lo
          & (~gty_tlast_piso_final_lo | sf_ctrl_fifo_ready_lo);
      assign gty_tyumi_i = sf_data_fifo_v_li & sf_data_fifo_ready_lo;

      bsg_fifo_1r1w_small #(
         .width_p(gty_data_width_p+1)
        ,.els_p(store_forward_els_p)
        ,.harden_p(1)
      ) store_forward_data_fifo (
         .clk_i   (gty_clk_i)
        ,.reset_i (gty_reset_i)

        ,.v_i     (sf_data_fifo_v_li)
        ,.data_i  ({gty_tlast_piso_final_lo, gty_tdata_piso_lo})
        ,.ready_o (sf_data_fifo_ready_lo)

        ,.v_o     (sf_data_fifo_v_lo)
        ,.data_o  ({sf_data_tlast_lo, sf_data_lo})
        ,.yumi_i  (sf_data_fifo_yumi_li)
      );

      bsg_fifo_1r1w_small #(
         .width_p(1)
        ,.els_p(store_forward_els_p)
      ) store_forward_control_fifo (
         .clk_i   (gty_clk_i)
        ,.reset_i (gty_reset_i)

        ,.v_i     (gty_tyumi_i & gty_tlast_piso_final_lo)
        ,.data_i  (1'b0)
        ,.ready_o (sf_ctrl_fifo_ready_lo)

        ,.v_o     (sf_ctrl_fifo_v_lo)
        ,.data_o  ()
        ,.yumi_i  (sf_ctrl_fifo_yumi_li)
      );

      wire sf_complete_packet_v_lo = sf_data_fifo_v_lo & sf_ctrl_fifo_v_lo;
      assign sf_data_fifo_yumi_li = sf_complete_packet_v_lo
                                    & tx_src_ready_li;
      assign sf_ctrl_fifo_yumi_li = sf_data_fifo_yumi_li
                                    & sf_data_tlast_lo;

      assign tx_src_v_lo     = sf_complete_packet_v_lo;
      assign tx_src_tlast_lo = sf_data_tlast_lo;
      assign tx_src_tdata_lo = sf_data_lo;

      // Enforce the configured maximum packet size.  Since an incomplete
      // packet is bounded to fit in the full FIFO, completed packets ahead
      // of it may drain concurrently and create the space needed for TLAST.
      always_ff @(posedge gty_clk_i) begin
        if (gty_reset_i) begin
          sf_packet_flit_count_r   <= '0;
          sf_packet_too_long_dbg_r <= 1'b0;
        end else if (gty_tyumi_i) begin
          if (gty_tlast_piso_final_lo) begin
            sf_packet_flit_count_r <= '0;
          end else begin
            if (sf_packet_flit_count_r == (max_packet_flits_lp-1'b1))
              sf_packet_too_long_dbg_r <= 1'b1;
            sf_packet_flit_count_r <= sf_packet_flit_count_r + 1'b1;
          end
        end
      end
    end else begin: store_forward_bypassed
      assign tx_src_v_lo     = gty_tvalid_piso_lo;
      assign tx_src_tlast_lo = gty_tlast_piso_final_lo;
      assign tx_src_tdata_lo = gty_tdata_piso_lo;
      assign gty_tyumi_i     = tx_src_v_lo & tx_src_ready_li;
      assign sf_packet_too_long_dbg_r = 1'b0;
    end

    // Two-entry RIFL-side isolation FIFO.  It breaks the ready path from
    // RIFL back into the store-forward/PISO logic.
    logic gty_fifo_ready_lo;
    logic gty_fifo_v_lo;
    logic gty_fifo_yumi_li;
    logic gty_tlast_fifo_lo;
    logic [gty_data_width_p-1:0] gty_tdata_fifo_lo;

    assign tx_src_ready_li = gty_fifo_ready_lo;

    bsg_two_fifo #(
       .width_p(gty_data_width_p+1)
    ) gty_output_fifo (
       .clk_i   (gty_clk_i)
      ,.reset_i (gty_reset_i)

      ,.ready_o (gty_fifo_ready_lo)
      ,.data_i  ({tx_src_tlast_lo, tx_src_tdata_lo})
      ,.v_i     (tx_src_v_lo)

      ,.v_o     (gty_fifo_v_lo)
      ,.data_o  ({gty_tlast_fifo_lo, gty_tdata_fifo_lo})
      ,.yumi_i  (gty_fifo_yumi_li)
    );

    // ---------------------------------------------------------------
    // RIFL-side deterministic throughput limiter.
    //
    // Count accepted output flits, independent of natural stalls.  After
    // every modulo_flits_p accepted non-TLAST flits, insert
    // modulo_bubbles_p visible bubble cycles.  After each accepted TLAST,
    // insert packet_end_bubbles_p visible bubble cycles and restart the
    // modulo counter for the next packet.
    //
    // A bubble is counted only while RIFL is ready.  If tready is low, the
    // required visible bubble is held and retried on a later cycle.
    // ---------------------------------------------------------------
    logic [modulo_count_width_lp-1:0] gty_flit_count_r;
    logic [bubble_count_width_lp-1:0] gty_bubble_count_r;
    wire gty_in_bubble = (gty_bubble_count_r != '0);

    assign gty_tdata_o      = gty_tdata_fifo_lo;
    assign gty_tvalid_o     = gty_fifo_v_lo & ~gty_in_bubble;
    assign gty_tlast_o      = gty_tlast_fifo_lo;
    assign gty_fifo_yumi_li = gty_tvalid_o & gty_tready_i;

    always_ff @(posedge gty_clk_i) begin
      if (gty_reset_i) begin
        gty_flit_count_r   <= '0;
        gty_bubble_count_r <= '0;
      end else if (gty_in_bubble) begin
        if (gty_tready_i) begin
          gty_bubble_count_r <= gty_bubble_count_r - 1'b1;
          if (gty_bubble_count_r == 1)
            gty_flit_count_r <= '0;
        end
      end else if (gty_fifo_yumi_li) begin
        if (gty_tlast_o) begin
          gty_bubble_count_r <= packet_end_bubbles_lp;
          gty_flit_count_r   <= '0;
        end else if (gty_flit_count_r == modulo_last_count_lp) begin
          gty_bubble_count_r <= modulo_bubbles_lp;
          gty_flit_count_r   <= '0;
        end else begin
          gty_bubble_count_r <= '0;
          gty_flit_count_r   <= gty_flit_count_r + 1'b1;
        end
      end
    end

    bsg_counter_clear_up #(
       .max_val_p(ratio_lp-1)
      ,.init_val_p(0)
      ,.disable_overflow_warning_p(1)
    ) piso_idx_counter (
       .clk_i(gty_clk_i)
      ,.reset_i(gty_reset_i)

      ,.clear_i('0)
      ,.up_i(gty_tyumi_i)
      ,.count_o(piso_idx)
    );

  end

  begin: from_gty

    logic [ratio_lp-1:0][gty_data_width_p-1:0]  gty_tdata_i_ext;
    logic [ratio_lp-1:0]                        gty_tlast_i_ext;
    logic                                       gty_tready_o_ext;
    logic                                       gty_tvalid_i_ext;
    logic [ratio_lp-1:0][gty_data_width_p+1-1:0] sipo_data_lo;

    bsg_serial_in_parallel_out_full #(
       .width_p(gty_data_width_p+1)
      ,.els_p(ratio_lp)
    ) sipo (
       .clk_i(gty_clk_i)
      ,.reset_i(gty_reset_i)

      ,.v_i(gty_tvalid_i)
      ,.data_i({gty_tdata_i, gty_tlast_i})
      ,.ready_o(gty_tready_o)

      ,.v_o(gty_tvalid_i_ext)
      ,.data_o(sipo_data_lo)
      ,.yumi_i(gty_tvalid_i_ext & gty_tready_o_ext)
    );
    for(genvar i = 0; i < ratio_lp; i++) begin: r
      assign {gty_tdata_i_ext[i], gty_tlast_i_ext[i]} = sipo_data_lo[i];
    end

    logic w_full_lo;
    assign gty_tready_o_ext = ~w_full_lo;
    bsg_async_fifo #(
       .lg_size_p(3)
      ,.width_p(dma_data_width_p+1)
    ) async_fifo (
       .w_clk_i(gty_clk_i)
      ,.w_reset_i(gty_reset_i)

      ,.w_enq_i(gty_tvalid_i_ext & gty_tready_o_ext)

      ,.w_data_i({gty_tdata_i_ext, gty_tlast_i_ext[ratio_lp-1]})
      ,.w_full_o(w_full_lo)

      ,.r_clk_i(dma_clk_i)
      ,.r_reset_i(dma_reset_i)
      ,.r_deq_i(dma_tvalid_o & dma_tready_i)
      ,.r_data_o({dma_tdata_o, dma_tlast_o})
      ,.r_valid_o(dma_tvalid_o)
    );
  end
endmodule

`default_nettype wire
