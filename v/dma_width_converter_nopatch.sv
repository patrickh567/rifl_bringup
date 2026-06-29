
`default_nettype none
`include "bsg_defines.v"

module dma_width_converter_nopatch #(
    parameter `BSG_INV_PARAM(dma_data_width_p)
  , parameter `BSG_INV_PARAM(gty_data_width_p)
  , localparam ratio_lp = dma_data_width_p / gty_data_width_p
  , localparam counter_width_lp = `BSG_SAFE_CLOG2(ratio_lp)
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
    $error("%m bad param");
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
    for(genvar i = 0;i < ratio_lp;i++) begin: r
      assign piso_data_li[i] = {dma_tlast_i_sync, dma_tdata_i_sync[i]};
    end

    logic gty_tyumi_i;
    logic gty_tlast;
    logic [counter_width_lp-1:0] piso_idx;

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

      ,.valid_o(gty_tvalid_o)
      ,.data_o({gty_tlast, gty_tdata_o})
      ,.yumi_i(gty_tyumi_i)
    );
    assign gty_tyumi_i = gty_tvalid_o & gty_tready_i;
    assign gty_tlast_o = gty_tlast & (piso_idx == '1);

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
    for(genvar i = 0;i < ratio_lp;i++) begin: r
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