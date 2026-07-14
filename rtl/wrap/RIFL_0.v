`timescale 1 ps / 1 ps
// de-IP source wrapper: RIFL_0 = RIFL with the per-quad gt_core baked in (GT_QUAD=0).
module RIFL_0 (
  gt_ref_clk_p,
  gt_ref_clk_n,
  init_clk,
  rst,
  gt_rst,
  usr_clk,
  gt_loopback_in,
  gt_rxp_in,
  gt_rxn_in,
  gt_txp_out,
  gt_txn_out,
  s_axis_tdata,
  s_axis_tkeep,
  s_axis_tlast,
  s_axis_tvalid,
  s_axis_tready,
  m_axis_tdata,
  m_axis_tkeep,
  m_axis_tlast,
  m_axis_tvalid,
  m_axis_tready,
  tx_state_init,
  tx_state_send_pause,
  tx_state_pause,
  tx_state_send_retrans,
  tx_state_retrans,
  tx_state_normal,
  rx_up,
  rx_aligned,
  rx_error,
  rx_pause_request,
  rx_retrans_request,
  local_fc,
  remote_fc,
  compensate,
  comp_locked,
  comp_type,
  rx_fifo_overflow
);

(* X_INTERFACE_INFO = "xilinx.com:interface:diff_clock:1.0 gt_ref CLK_P" *)
input wire gt_ref_clk_p;
(* X_INTERFACE_PARAMETER = "XIL_INTERFACENAME gt_ref, CAN_DEBUG false, FREQ_HZ 100000000" *)
(* X_INTERFACE_INFO = "xilinx.com:interface:diff_clock:1.0 gt_ref CLK_N" *)
input wire gt_ref_clk_n;
(* X_INTERFACE_PARAMETER = "XIL_INTERFACENAME init_clk, FREQ_HZ 100000000, PHASE 0.000, INSERT_VIP 0" *)
(* X_INTERFACE_INFO = "xilinx.com:signal:clock:1.0 init_clk CLK" *)
input wire init_clk;
(* X_INTERFACE_PARAMETER = "XIL_INTERFACENAME rst, POLARITY ACTIVE_LOW, INSERT_VIP 0" *)
(* X_INTERFACE_INFO = "xilinx.com:signal:reset:1.0 rst RST" *)
input wire rst;
(* X_INTERFACE_PARAMETER = "XIL_INTERFACENAME gt_rst, POLARITY ACTIVE_LOW, INSERT_VIP 0" *)
(* X_INTERFACE_INFO = "xilinx.com:signal:reset:1.0 gt_rst RST" *)
input wire gt_rst;
(* X_INTERFACE_PARAMETER = "XIL_INTERFACENAME usr_clk, ASSOCIATED_BUSIF m_axis:s_axis:rifl_stat, FREQ_HZ 100000000, PHASE 0.000, INSERT_VIP 0" *)
(* X_INTERFACE_INFO = "xilinx.com:signal:clock:1.0 usr_clk CLK" *)
output wire usr_clk;
input wire [11 : 0] gt_loopback_in;
(* X_INTERFACE_INFO = "clarkshen.com:user:rifl_gt:1.0 rifl_gt gt_rxp_in" *)
input wire [3 : 0] gt_rxp_in;
(* X_INTERFACE_INFO = "clarkshen.com:user:rifl_gt:1.0 rifl_gt gt_rxn_in" *)
input wire [3 : 0] gt_rxn_in;
(* X_INTERFACE_INFO = "clarkshen.com:user:rifl_gt:1.0 rifl_gt gt_txp_out" *)
output wire [3 : 0] gt_txp_out;
(* X_INTERFACE_INFO = "clarkshen.com:user:rifl_gt:1.0 rifl_gt gt_txn_out" *)
output wire [3 : 0] gt_txn_out;
(* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 s_axis TDATA" *)
input wire [255 : 0] s_axis_tdata;
(* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 s_axis TKEEP" *)
input wire [31 : 0] s_axis_tkeep;
(* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 s_axis TLAST" *)
input wire s_axis_tlast;
(* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 s_axis TVALID" *)
input wire s_axis_tvalid;
(* X_INTERFACE_PARAMETER = "XIL_INTERFACENAME s_axis, TDATA_NUM_BYTES 32, TDEST_WIDTH 0, TID_WIDTH 0, TUSER_WIDTH 0, HAS_TREADY 1, HAS_TSTRB 0, HAS_TKEEP 1, HAS_TLAST 1, FREQ_HZ 100000000, PHASE 0.000, LAYERED_METADATA undef, INSERT_VIP 0" *)
(* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 s_axis TREADY" *)
output wire s_axis_tready;
(* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 m_axis TDATA" *)
output wire [255 : 0] m_axis_tdata;
(* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 m_axis TKEEP" *)
output wire [31 : 0] m_axis_tkeep;
(* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 m_axis TLAST" *)
output wire m_axis_tlast;
(* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 m_axis TVALID" *)
output wire m_axis_tvalid;
(* X_INTERFACE_PARAMETER = "XIL_INTERFACENAME m_axis, TDATA_NUM_BYTES 32, TDEST_WIDTH 0, TID_WIDTH 0, TUSER_WIDTH 0, HAS_TREADY 1, HAS_TSTRB 0, HAS_TKEEP 1, HAS_TLAST 1, FREQ_HZ 100000000, PHASE 0.000, LAYERED_METADATA undef, INSERT_VIP 0" *)
(* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 m_axis TREADY" *)
input wire m_axis_tready;
(* X_INTERFACE_INFO = "clarkshen.com:user:rifl_stat:1.0 rifl_stat tx_state_init" *)
output wire [3 : 0] tx_state_init;
(* X_INTERFACE_INFO = "clarkshen.com:user:rifl_stat:1.0 rifl_stat tx_state_send_pause" *)
output wire [3 : 0] tx_state_send_pause;
(* X_INTERFACE_INFO = "clarkshen.com:user:rifl_stat:1.0 rifl_stat tx_state_pause" *)
output wire [3 : 0] tx_state_pause;
(* X_INTERFACE_INFO = "clarkshen.com:user:rifl_stat:1.0 rifl_stat tx_state_send_retrans" *)
output wire [3 : 0] tx_state_send_retrans;
(* X_INTERFACE_INFO = "clarkshen.com:user:rifl_stat:1.0 rifl_stat tx_state_retrans" *)
output wire [3 : 0] tx_state_retrans;
(* X_INTERFACE_INFO = "clarkshen.com:user:rifl_stat:1.0 rifl_stat tx_state_normal" *)
output wire [3 : 0] tx_state_normal;
(* X_INTERFACE_INFO = "clarkshen.com:user:rifl_stat:1.0 rifl_stat rx_up" *)
output wire [3 : 0] rx_up;
(* X_INTERFACE_INFO = "clarkshen.com:user:rifl_stat:1.0 rifl_stat rx_aligned" *)
output wire [3 : 0] rx_aligned;
(* X_INTERFACE_INFO = "clarkshen.com:user:rifl_stat:1.0 rifl_stat rx_error" *)
output wire [3 : 0] rx_error;
(* X_INTERFACE_INFO = "clarkshen.com:user:rifl_stat:1.0 rifl_stat rx_pause_request" *)
output wire [3 : 0] rx_pause_request;
(* X_INTERFACE_INFO = "clarkshen.com:user:rifl_stat:1.0 rifl_stat rx_retrans_request" *)
output wire [3 : 0] rx_retrans_request;
(* X_INTERFACE_INFO = "clarkshen.com:user:rifl_stat:1.0 rifl_stat local_fc" *)
output wire [3 : 0] local_fc;
(* X_INTERFACE_INFO = "clarkshen.com:user:rifl_stat:1.0 rifl_stat remote_fc" *)
output wire [3 : 0] remote_fc;
(* X_INTERFACE_INFO = "clarkshen.com:user:rifl_stat:1.0 rifl_stat compensate" *)
output wire compensate;
  output wire comp_locked;
  output wire [1:0] comp_type;
  output wire [3:0] rx_fifo_overflow;

  RIFL #(
    .N_CHANNEL(4),
    .GT_WIDTH(64),
    .GT_INT_WIDTH(64),
    .LANE_LINE_RATE(25),
    .ERROR_INJ(0),
    .ERROR_SEED(0),
    .CABLE_LENGTH(20),
    .USER_WIDTH(256),
    .FRAME_WIDTH(256),
    .GT_QUAD(0)
  ) inst (
    .gt_ref_clk_p(gt_ref_clk_p),
    .gt_ref_clk_n(gt_ref_clk_n),
    .init_clk(init_clk),
    .rst(rst),
    .gt_rst(gt_rst),
    .usr_clk(usr_clk),
    .gt_loopback_in(gt_loopback_in),
    .gt_rxp_in(gt_rxp_in),
    .gt_rxn_in(gt_rxn_in),
    .gt_txp_out(gt_txp_out),
    .gt_txn_out(gt_txn_out),
    .s_axis_tdata(s_axis_tdata),
    .s_axis_tkeep(s_axis_tkeep),
    .s_axis_tlast(s_axis_tlast),
    .s_axis_tvalid(s_axis_tvalid),
    .s_axis_tready(s_axis_tready),
    .m_axis_tdata(m_axis_tdata),
    .m_axis_tkeep(m_axis_tkeep),
    .m_axis_tlast(m_axis_tlast),
    .m_axis_tvalid(m_axis_tvalid),
    .m_axis_tready(m_axis_tready),
    .ber_code(64'B0),
    .tx_state_init(tx_state_init),
    .tx_state_send_pause(tx_state_send_pause),
    .tx_state_pause(tx_state_pause),
    .tx_state_send_retrans(tx_state_send_retrans),
    .tx_state_retrans(tx_state_retrans),
    .tx_state_normal(tx_state_normal),
    .rx_up(rx_up),
    .rx_aligned(rx_aligned),
    .rx_error(rx_error),
    .rx_pause_request(rx_pause_request),
    .rx_retrans_request(rx_retrans_request),
    .local_fc(local_fc),
    .remote_fc(remote_fc),
    .compensate(compensate),
    .comp_locked(comp_locked),
    .comp_type(comp_type),
    .rx_fifo_overflow(rx_fifo_overflow)
  );
endmodule
