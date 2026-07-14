`timescale 1ns / 1ps
module rifl_gt_wrapper # (
    parameter int N_CHANNEL = 1,
    parameter int FRAME_WIDTH = 256,
    parameter int GT_WIDTH = 64,
    parameter int GT_QUAD = 0            // 0->X0Y28 1->X0Y36 2->X0Y44 3->X1Y20 (de-IP: selects the per-quad gt_core)
)
(
//clk and rst
    input logic gt_ref_clk,
    input logic init_clk,
    input logic rst,
    input logic gt_init_rst,
//align status
    input logic rx_aligned,
//gt input pins
    input logic [N_CHANNEL-1:0] gt_rxp_in,
    input logic [N_CHANNEL-1:0] gt_rxn_in,
//gt loopback port
    input logic [3*N_CHANNEL-1:0] gt_loopback_in,
//tx data interface
    input logic [GT_WIDTH-1:0] gt_tx_data[N_CHANNEL-1:0],
//rx data interface
    output logic [GT_WIDTH-1:0] gt_rx_data[N_CHANNEL-1:0],
//gt output pins
    output logic [N_CHANNEL-1:0] gt_txp_out,
    output logic [N_CHANNEL-1:0] gt_txn_out,
//clock signals
    //clk
    output logic tx_gt_src_clk,
    output logic rx_gt_src_clk,
    input logic txusrclk,
    input logic rxusrclk,
    input logic txusrclk2,
    input logic rxusrclk2,
    //clk_cntrl
    input logic tx_usr_clk_active,
    input logic rx_usr_clk_active,
    output logic tx_gt_clk_rst,
    output logic rx_gt_clk_rst
);
//clks
    localparam int MASTER_CHAN_IDX = N_CHANNEL == 1 ? 0 : N_CHANNEL/2-1;
    logic [N_CHANNEL-1:0] tx_gt_src_clk_int;
    logic [N_CHANNEL-1:0] rx_gt_src_clk_int;
    logic [N_CHANNEL-1:0] txusrclk_int;
    logic [N_CHANNEL-1:0] rxusrclk_int;
    logic [N_CHANNEL-1:0] txusrclk2_int;
    logic [N_CHANNEL-1:0] rxusrclk2_int;

//rsts
    logic bypass_tx_reset_gt;
    logic bypass_rx_reset_gt;
    logic rst_all_gt;
    logic rst_rx_datapath_gt;
    logic rst_tx_done_gt;
    logic rst_rx_done_gt;
    logic bypass_tx_done_gt;
    logic bypass_rx_done_gt;
    logic [N_CHANNEL-1:0] txpmaresetdone_out;
    logic [N_CHANNEL-1:0] txprgdivresetdone_out;
    logic [N_CHANNEL-1:0] rxpmaresetdone_out;

//data
    logic [GT_WIDTH*N_CHANNEL-1:0] gt_tx_data_int, gt_rx_data_int;

//control and status
    logic tx_good_tx_synced;
    logic rx_good_rx_synced;
    logic tx_good_init_synced;
    logic rx_good_init_synced;

//synchronizer
    gt_cdc gt_cdc_inst (
        .init_clk(init_clk),
        .txusrclk2(txusrclk2),
        .rxusrclk2(rxusrclk2),
        .rst(rst),
        .tx_good_tx_synced(tx_good_tx_synced),
        .rx_good_rx_synced(rx_good_rx_synced),
        .tx_good_init_synced(tx_good_init_synced),
        .rx_good_init_synced(rx_good_init_synced)
    );

//datapath resets
    datapath_reset # (
        .COUNTER_WIDTH(20)
    ) gt_all_reset_inst (
        .clk(init_clk),
        .rst(gt_init_rst),
        .channel_good(tx_good_init_synced),
        .rst_out(rst_all_gt)
    );

    datapath_reset # (
        .COUNTER_WIDTH(23)
    ) rx_datapath_reset_inst (
        .clk(init_clk),
        .rst(gt_init_rst),
        .channel_good(rx_good_init_synced),
        .rst_out(rst_rx_datapath_gt)
    );

//gt_core
`define RIFL_GT_CORE_PORTS rifl_gt_core_inst ( \
        .gtyrxn_in                               (gt_rxn_in), \
        .gtyrxp_in                               (gt_rxp_in), \
        .gtytxn_out                              (gt_txn_out), \
        .gtytxp_out                              (gt_txp_out), \
        .gtwiz_buffbypass_tx_reset_in            (bypass_tx_reset_gt), \
        .gtwiz_buffbypass_tx_start_user_in       (1'b0), \
        .gtwiz_buffbypass_tx_done_out            (bypass_tx_done_gt), \
        .gtwiz_buffbypass_tx_error_out           (), \
        .gtwiz_buffbypass_rx_reset_in            (bypass_rx_reset_gt), \
        .gtwiz_buffbypass_rx_start_user_in       (1'b0), \
        .gtwiz_buffbypass_rx_done_out            (bypass_rx_done_gt), \
        .gtwiz_buffbypass_rx_error_out           (), \
        .gtwiz_reset_clk_freerun_in              (init_clk), \
        .gtwiz_reset_all_in                      (gt_init_rst | rst_all_gt), \
        .gtwiz_reset_tx_pll_and_datapath_in      (1'b0), \
        .gtwiz_reset_tx_datapath_in              (1'b0), \
        .gtwiz_reset_rx_pll_and_datapath_in      (1'b0), \
        .gtwiz_reset_rx_datapath_in              (rst_rx_datapath_gt), \
        .gtwiz_reset_rx_cdr_stable_out           (), \
        .gtwiz_reset_tx_done_out                 (rst_tx_done_gt), \
        .gtwiz_reset_rx_done_out                 (rst_rx_done_gt), \
        .gtwiz_userclk_tx_active_in              (tx_usr_clk_active), \
        .txusrclk_in                             (txusrclk_int), \
        .txusrclk2_in                            (txusrclk2_int), \
        .txoutclk_out                            (tx_gt_src_clk_int), \
        .gtwiz_userclk_rx_active_in              (rx_usr_clk_active), \
        .rxusrclk_in                             (rxusrclk_int), \
        .rxusrclk2_in                            (rxusrclk2_int), \
        .rxoutclk_out                            (rx_gt_src_clk_int), \
        .gtwiz_userdata_tx_in                    (gt_tx_data_int), \
        .gtwiz_userdata_rx_out                   (gt_rx_data_int), \
        .gtrefclk00_in                           (gt_ref_clk), \
        .qpll0outclk_out                         (), \
        .qpll0outrefclk_out                      (), \
        .loopback_in                             (gt_loopback_in), \
        .gtpowergood_out                         (), \
        .rxpmaresetdone_out                      (rxpmaresetdone_out), \
        .txpmaresetdone_out                      (txpmaresetdone_out), \
        .txprgdivresetdone_out                   (txprgdivresetdone_out) \
    )
    // de-IP: only the gt_core MODULE NAME differs per quad; the port map is
    // identical, so factor it into a macro and pick the core with GT_QUAD.
    // Only the selected generate-case branch is elaborated into hardware.
    generate
        case (GT_QUAD)
            0:       gt_core_X0Y28 `RIFL_GT_CORE_PORTS;
            1:       gt_core_X0Y36 `RIFL_GT_CORE_PORTS;
            2:       gt_core_X0Y44 `RIFL_GT_CORE_PORTS;
            default: gt_core_X1Y20 `RIFL_GT_CORE_PORTS;
        endcase
    endgenerate
    `undef RIFL_GT_CORE_PORTS
//clks
    assign tx_gt_src_clk = tx_gt_src_clk_int[MASTER_CHAN_IDX];
    assign rx_gt_src_clk = rx_gt_src_clk_int[MASTER_CHAN_IDX];
    assign txusrclk_int = {N_CHANNEL{txusrclk}};
    assign rxusrclk_int = {N_CHANNEL{rxusrclk}};
    assign txusrclk2_int = {N_CHANNEL{txusrclk2}};
    assign rxusrclk2_int = {N_CHANNEL{rxusrclk2}};

//data
    genvar i;
    for (i = 0; i < N_CHANNEL; i++) begin
        assign gt_tx_data_int[(i+1)*GT_WIDTH-1-:GT_WIDTH] = gt_tx_data[i];
        assign gt_rx_data[i] = gt_rx_data_int[(i+1)*GT_WIDTH-1-:GT_WIDTH];
    end

//control
    assign bypass_tx_reset_gt = ~tx_usr_clk_active;
    assign bypass_rx_reset_gt = ~(&rx_usr_clk_active) | ~bypass_tx_done_gt;
    assign tx_gt_clk_rst = ~(&txpmaresetdone_out && &txprgdivresetdone_out);
    assign rx_gt_clk_rst = ~(&rxpmaresetdone_out);
    assign tx_good_tx_synced = rst_tx_done_gt & bypass_tx_done_gt;
    assign rx_good_rx_synced = rst_rx_done_gt & bypass_rx_done_gt & rx_aligned;

endmodule
