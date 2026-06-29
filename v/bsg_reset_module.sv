`include "bsg_defines.v"

module bsg_reset_module #(
    parameter `BSG_INV_PARAM(num_gty_port_p)
   ,parameter `BSG_INV_PARAM(num_stages_p)
)
(
    input                             init_clk_i
  , input                             core_clk_i
  , input [num_gty_port_p-1:0]        usr_clks_i
  , input                             async_rstn_i

  , output logic [num_gty_port_p-1:0] usr_rsts_o  // usr_clk
  , output logic                      core_rst_o   // core_clk
  , output logic [num_gty_port_p-1:0] rsts_o       // init_clk, per GTY
  , output logic [num_gty_port_p-1:0] gt_rsts_o    // init_clk, per GTY
);
  wire async_reset_li = ~async_rstn_i;
  logic init_clk_rst;
  logic core_clk_rst;

  bsg_sync_sync #(
     .width_p(1)
  ) init_clk_rst_bss (
     .oclk_i(init_clk_i)
    ,.iclk_data_i(async_reset_li)
    ,.oclk_data_o(init_clk_rst)
  );

  logic [3:0] count_r_lo;
  wire delayed_init_clk_rst = (count_r_lo != '0);
  bsg_counter_set_down #(
     .width_p(4)
    ,.init_val_p(4'b1111)
    ,.set_and_down_exclusive_p(1)
  ) delay (
     .clk_i(init_clk_i)
    ,.reset_i(init_clk_rst)
    ,.set_i(1'b0)
    ,.val_i(4'b1111)
    ,.down_i(delayed_init_clk_rst)
    ,.count_r_o(count_r_lo)
  );

  bsg_sync_sync #(
     .width_p(1)
  ) core_clk_rst_bss (
     .oclk_i(core_clk_i)
    ,.iclk_data_i(init_clk_rst | delayed_init_clk_rst)
    ,.oclk_data_o(core_clk_rst)
  );

  logic [num_gty_port_p-1:0][num_stages_p:0] init_rst_chain_lo;
  logic [num_gty_port_p-1:0][num_stages_p:0] init_delayed_rst_chain_lo;

  for(genvar idx = 0; idx < num_gty_port_p; idx++) begin: gty
    bsg_reset_chain #(
       .num_stages_p(num_stages_p)
    ) init_rst_chain (
       .clk_i(init_clk_i)
      ,.pipelined_reset_i(init_clk_rst)
      ,.pipelined_resets_o(init_rst_chain_lo[idx])
    );

    bsg_reset_chain #(
       .num_stages_p(num_stages_p)
    ) init_delayed_rst_chain (
       .clk_i(init_clk_i)
      ,.pipelined_reset_i(init_clk_rst | delayed_init_clk_rst)
      ,.pipelined_resets_o(init_delayed_rst_chain_lo[idx])
    );

    assign rsts_o[idx]    = init_rst_chain_lo[idx][num_stages_p];
    assign gt_rsts_o[idx] = init_rst_chain_lo[idx][num_stages_p];

    bsg_sync_sync #(
       .width_p(1)
    ) usr_rsts_bss (
       .oclk_i(usr_clks_i[idx])
      ,.iclk_data_i(init_delayed_rst_chain_lo[idx][num_stages_p])
      ,.oclk_data_o(usr_rsts_o[idx])
    );
  end

  assign core_rst_o = core_clk_rst;

endmodule
