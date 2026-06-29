
`include "bsg_defines.v"

(* KEEP_HIERARCHY = "TRUE" *)
module bsg_reset_chain #(
    // Can be zero
    parameter `BSG_INV_PARAM(num_stages_p)
)
(
    input clk_i
  , input pipelined_reset_i
  // [0] is pipelined_reset_i
  , output logic [num_stages_p+1-1:0] pipelined_resets_o
);

  logic [num_stages_p+1-1:0] data_li;
  (* srl_style = "register" *)
  logic [num_stages_p-1:0] data_r;

  assign data_li[0] = pipelined_reset_i;
  assign pipelined_resets_o = data_li;

  for(genvar i = 1;i <= num_stages_p;i++) begin
    always_ff @(posedge clk_i)
      data_r[i-1] <= data_li[i-1];

    assign data_li[i] = data_r[i-1];
  end

endmodule
