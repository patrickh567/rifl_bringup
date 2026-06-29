
`timescale 1 ps / 1 ps

`include "bsg_defines.v"

`default_nettype none

// Default: use the patched align-to-15 converter.
// Define USE_NOPATCH_CONVERTER to instantiate dma_width_converter_nopatch instead.

//`define USE_NOPATCH_CONVERTER

`ifdef USE_NOPATCH_CONVERTER
  `define DMA_WIDTH_CONVERTER_MODULE dma_width_converter_nopatch
`else
  `define DMA_WIDTH_CONVERTER_MODULE dma_width_converter
`endif

module top
#(
  // Optical inter-node DMA / RIFL-GTY parameters
    parameter gt_serial_width_p = 4
  , parameter num_gty_port_p = 4
  , parameter rifl_axis_bist_p = 1
  , parameter axis_data_width_p = 256
  , localparam axis_keep_width_lp = axis_data_width_p / 8
  , localparam dma_data_width_lp = axis_data_width_p * 2
)
(
    input  wire       ext_refclk_n
  , input  wire       ext_refclk_p
  , input  wire       rstn
  , output wire [1:0] led

  // Optical inter-node DMA / RIFL-GTY ports merged from design_1_wrapper.v
  , input  wire [num_gty_port_p-1:0] gt_ref_i_clk_n
  , input  wire [num_gty_port_p-1:0] gt_ref_i_clk_p
  , input  wire [num_gty_port_p*gt_serial_width_p-1:0] rifl_gt_o_gt_rxn_in
  , input  wire [num_gty_port_p*gt_serial_width_p-1:0] rifl_gt_o_gt_rxp_in
  , output wire [num_gty_port_p*gt_serial_width_p-1:0] rifl_gt_o_gt_txn_out
  , output wire [num_gty_port_p*gt_serial_width_p-1:0] rifl_gt_o_gt_txp_out
);

  wire init_clk;
  wire core_clk;

  // LED breathing
  logic led_breath = 1'b0;
  logic [31:0] led_counter_r = '0;
  
  always_ff @(posedge init_clk)
  begin
    led_counter_r <= (led_counter_r == 32'd50000000)? '0 : led_counter_r + 1;
    led_breath <= (led_counter_r == 32'd50000000)? ~led_breath : led_breath;
  end

  // LEDs
  assign led[0] = led_breath;
  assign led[1] = ~led_breath;



  logic vio_global_rst_lo;
  design_vio_global_rst design_vio_global_rst_0 (
     .clk(init_clk)
    ,.rst(vio_global_rst_lo)
  );

  wire [num_gty_port_p-1:0] rifl_rsts;
  wire [num_gty_port_p-1:0] rifl_gt_rsts;
  wire                      core_reset;
  wire [num_gty_port_p-1:0] rifl_usr_rsts;
  wire [num_gty_port_p-1:0] rifl_usr_clks;

  bsg_reset_module #(
     .num_gty_port_p(num_gty_port_p)
    ,.num_stages_p(3)
  ) optical_reset_module (
     .init_clk_i(init_clk)
    ,.core_clk_i(core_clk)

    ,.async_rstn_i(~vio_global_rst_lo)
    ,.usr_clks_i(rifl_usr_clks)

    ,.usr_rsts_o(rifl_usr_rsts) // rifl_usr_clks
    ,.core_rst_o(core_reset) // core_clk
    ,.rsts_o()           // init_clk
    ,.gt_rsts_o()     // init_clk
  );

  // From GTY/RIFL into DMA
  logic [num_gty_port_p-1:0][axis_data_width_p-1:0]  m_axis_tdata_gty_o;
  logic [num_gty_port_p-1:0][axis_keep_width_lp-1:0] m_axis_tkeep_gty_o; // UNUSED
  logic [num_gty_port_p-1:0]                         m_axis_tlast_gty_o;
  logic [num_gty_port_p-1:0]                         m_axis_tready_gty_i;
  logic [num_gty_port_p-1:0]                         m_axis_tvalid_gty_o;

  // From DMA into GTY/RIFL
  logic [num_gty_port_p-1:0][axis_data_width_p-1:0]  s_axis_tdata_gty_i;
  logic [num_gty_port_p-1:0][axis_keep_width_lp-1:0] s_axis_tkeep_gty_i;
  logic [num_gty_port_p-1:0]                         s_axis_tlast_gty_i;
  logic [num_gty_port_p-1:0]                         s_axis_tready_gty_o;
  logic [num_gty_port_p-1:0]                         s_axis_tvalid_gty_i;

  logic [num_gty_port_p-1:0][gt_serial_width_p-1:0] rifl_tx_state_init_o        ;
  logic [num_gty_port_p-1:0][gt_serial_width_p-1:0] rifl_tx_state_send_pause_o  ;
  logic [num_gty_port_p-1:0][gt_serial_width_p-1:0] rifl_tx_state_pause_o       ;
  logic [num_gty_port_p-1:0][gt_serial_width_p-1:0] rifl_tx_state_send_retrans_o;
  logic [num_gty_port_p-1:0][gt_serial_width_p-1:0] rifl_tx_state_retrans_o     ;
  logic [num_gty_port_p-1:0][gt_serial_width_p-1:0] rifl_tx_state_normal_o      ;
  logic [num_gty_port_p-1:0][gt_serial_width_p-1:0] rifl_rx_up_o                ;
  logic [num_gty_port_p-1:0][gt_serial_width_p-1:0] rifl_rx_aligned_o           ;
  logic [num_gty_port_p-1:0][gt_serial_width_p-1:0] rifl_rx_error_o             ;
  logic [num_gty_port_p-1:0][gt_serial_width_p-1:0] rifl_rx_pause_request_o     ;
  logic [num_gty_port_p-1:0][gt_serial_width_p-1:0] rifl_rx_retrans_request_o   ;
  logic [num_gty_port_p-1:0][gt_serial_width_p-1:0] rifl_local_fc_o             ;
  logic [num_gty_port_p-1:0][gt_serial_width_p-1:0] rifl_remote_fc_o            ;
  logic [num_gty_port_p-1:0]                        rifl_compensate_o           ;

  // Note from design_1_wrapper.v:
  //   000: Normal operation
  //   001, 010, 100, 110: Loopback modes
  wire [num_gty_port_p-1:0][11:0] gt_loopback_in = {num_gty_port_p{12'b000000000000}};

  // RIFL/GTY wrappers.
  `define RIFL_MACRO(idx)                                                                           \
  (* KEEP_HIERARCHY = "TRUE" *)                                                                     \
  RIFL_``idx`` RIFL_inst_``idx`` (                                                                  \
     .gt_ref_clk_p(gt_ref_i_clk_p[``idx``])                                                         \
    ,.gt_ref_clk_n(gt_ref_i_clk_n[``idx``])                                                         \
    ,.init_clk(init_clk)                                                                            \
    ,.rst(rifl_rsts[``idx``])                                                                                 \
    ,.gt_rst(rifl_gt_rsts[``idx``])                                                                           \
    ,.usr_clk(rifl_usr_clks[``idx``])                                                               \
    ,.gt_loopback_in(gt_loopback_in[``idx``])                                                       \
    ,.gt_rxp_in (rifl_gt_o_gt_rxp_in[(``idx``+1)*gt_serial_width_p-1:(``idx``)*gt_serial_width_p])  \
    ,.gt_rxn_in (rifl_gt_o_gt_rxn_in[(``idx``+1)*gt_serial_width_p-1:(``idx``)*gt_serial_width_p])  \
    ,.gt_txp_out(rifl_gt_o_gt_txp_out[(``idx``+1)*gt_serial_width_p-1:(``idx``)*gt_serial_width_p]) \
    ,.gt_txn_out(rifl_gt_o_gt_txn_out[(``idx``+1)*gt_serial_width_p-1:(``idx``)*gt_serial_width_p]) \
    ,.s_axis_tdata (s_axis_tdata_gty_i[``idx``] )                                                   \
    ,.s_axis_tkeep (s_axis_tkeep_gty_i[``idx``] )                                                   \
    ,.s_axis_tlast (s_axis_tlast_gty_i[``idx``] )                                                   \
    ,.s_axis_tvalid(s_axis_tvalid_gty_i[``idx``])                                                   \
    ,.s_axis_tready(s_axis_tready_gty_o[``idx``])                                                   \
    ,.m_axis_tdata (m_axis_tdata_gty_o[``idx``] )                                                   \
    ,.m_axis_tkeep (m_axis_tkeep_gty_o[``idx``] )                                                   \
    ,.m_axis_tlast (m_axis_tlast_gty_o[``idx``] )                                                   \
    ,.m_axis_tvalid(m_axis_tvalid_gty_o[``idx``])                                                   \
    ,.m_axis_tready(m_axis_tready_gty_i[``idx``])                                                   \
    ,.tx_state_init        (rifl_tx_state_init_o        [``idx``])                                  \
    ,.tx_state_send_pause  (rifl_tx_state_send_pause_o  [``idx``])                                  \
    ,.tx_state_pause       (rifl_tx_state_pause_o       [``idx``])                                  \
    ,.tx_state_send_retrans(rifl_tx_state_send_retrans_o[``idx``])                                  \
    ,.tx_state_retrans     (rifl_tx_state_retrans_o     [``idx``])                                  \
    ,.tx_state_normal      (rifl_tx_state_normal_o      [``idx``])                                  \
    ,.rx_up                (rifl_rx_up_o                [``idx``])                                  \
    ,.rx_aligned           (rifl_rx_aligned_o           [``idx``])                                  \
    ,.rx_error             (rifl_rx_error_o             [``idx``])                                  \
    ,.rx_pause_request     (rifl_rx_pause_request_o     [``idx``])                                  \
    ,.rx_retrans_request   (rifl_rx_retrans_request_o   [``idx``])                                  \
    ,.local_fc             (rifl_local_fc_o             [``idx``])                                  \
    ,.remote_fc            (rifl_remote_fc_o            [``idx``])                                  \
    ,.compensate           (rifl_compensate_o           [``idx``])                                  \
  );

  `RIFL_MACRO(0)
  `RIFL_MACRO(1)
  `RIFL_MACRO(2)
  `RIFL_MACRO(3)
  `undef RIFL_MACRO

  for(genvar i = 0;i < num_gty_port_p;i++) begin: nm

    localparam core_reset_stage_lp = (i == 0) ? 4
                                   : (i == 1) ? 6
                                   : (i == 2) ? 6
                                   : (i == 3) ? 6
                                   : 6;
    logic [core_reset_stage_lp:0] core_reset_delayed_array;
    wire core_reset_pipelined = core_reset_delayed_array[core_reset_stage_lp];
    bsg_reset_chain #(
       .num_stages_p(core_reset_stage_lp)
    ) core_reset_chain (
       .clk_i(core_clk)
      ,.pipelined_reset_i(core_reset)
      ,.pipelined_resets_o(core_reset_delayed_array)
    );

    logic [dma_data_width_lp-1:0] converter_dma_tdata_li;
    logic                         converter_dma_tlast_li;
    logic                         converter_dma_tready_lo;
    logic                         converter_dma_tvalid_li;

    logic [dma_data_width_lp-1:0] converter_dma_tdata_lo;
    logic                         converter_dma_tlast_lo;
    logic                         converter_dma_tready_li;
    logic                         converter_dma_tvalid_lo;

      logic bist_tx_start_vio, bist_tx_stop_vio;
      logic bist_rx_start_vio, bist_rx_stop_vio;
      logic bist_clear_vio;
      logic [1:0]  bist_cfg_len_mode_vio;
      logic [15:0] bist_cfg_pkt_len_vio;
      logic [15:0] bist_cfg_pkt_len_min_vio;
      logic [15:0] bist_cfg_pkt_len_max_vio;
      logic [15:0] bist_cfg_gap_vio;
      logic [63:0] bist_cfg_packet_count_vio;
      logic [31:0] bist_cfg_seed_vio;

      logic bist_tx_busy_lo, bist_tx_done_lo;
      logic bist_rx_active_lo, bist_rx_done_lo;
      logic bist_error_lo;
      logic [3:0] bist_error_kind_lo;
      logic [63:0] bist_sent_flit_count_lo;
      logic [63:0] bist_sent_packet_count_lo;
      logic [63:0] bist_recv_flit_count_lo;
      logic [63:0] bist_recv_packet_count_lo;
      logic [63:0] bist_err_pkt_idx_lo;
      logic [31:0] bist_err_flit_idx_lo;
      logic [63:0] bist_err_expected_lo;
      logic [63:0] bist_err_actual_lo;
      logic        bist_err_expected_last_lo;
      logic        bist_err_actual_last_lo;

      axis_traffic_gen_checker #(
         .data_width_p(dma_data_width_lp)
        ,.counter_width_p(64)
        ,.packet_len_width_p(16)
        ,.gap_width_p(16)
      ) rifl_axis_bist_inst (
         .clk_i(core_clk)
        ,.reset_i(core_reset_pipelined)

        ,.tx_start_i(bist_tx_start_vio)
        ,.tx_stop_i (bist_tx_stop_vio )
        ,.rx_start_i(bist_rx_start_vio)
        ,.rx_stop_i (bist_rx_stop_vio )
        ,.clear_i   (bist_clear_vio   )

        ,.cfg_len_mode_i    (bist_cfg_len_mode_vio    )
        ,.cfg_pkt_len_i     (bist_cfg_pkt_len_vio     )
        ,.cfg_pkt_len_min_i (bist_cfg_pkt_len_min_vio )
        ,.cfg_pkt_len_max_i (bist_cfg_pkt_len_max_vio )
        ,.cfg_gap_i         (bist_cfg_gap_vio         )
        ,.cfg_packet_count_i(bist_cfg_packet_count_vio)
        ,.cfg_seed_i        (bist_cfg_seed_vio        )

        ,.tx_tdata_o (converter_dma_tdata_li )
        ,.tx_tlast_o (converter_dma_tlast_li )
        ,.tx_tready_i(converter_dma_tready_lo)
        ,.tx_tvalid_o(converter_dma_tvalid_li)

        ,.rx_tdata_i (converter_dma_tdata_lo )
        ,.rx_tlast_i (converter_dma_tlast_lo )
        ,.rx_tready_o(converter_dma_tready_li)
        ,.rx_tvalid_i(converter_dma_tvalid_lo)

        ,.tx_busy_o          (bist_tx_busy_lo          )
        ,.tx_done_o          (bist_tx_done_lo          )
        ,.rx_active_o        (bist_rx_active_lo        )
        ,.rx_done_o          (bist_rx_done_lo          )
        ,.error_o            (bist_error_lo            )
        ,.error_kind_o       (bist_error_kind_lo       )
        ,.sent_flit_count_o  (bist_sent_flit_count_lo  )
        ,.sent_packet_count_o(bist_sent_packet_count_lo)
        ,.recv_flit_count_o  (bist_recv_flit_count_lo  )
        ,.recv_packet_count_o(bist_recv_packet_count_lo)
        ,.err_pkt_idx_o      (bist_err_pkt_idx_lo      )
        ,.err_flit_idx_o     (bist_err_flit_idx_lo     )
        ,.err_expected_lo_o  (bist_err_expected_lo     )
        ,.err_actual_lo_o    (bist_err_actual_lo       )
        ,.err_expected_last_o(bist_err_expected_last_lo)
        ,.err_actual_last_o  (bist_err_actual_last_lo  )
      );

      // Per-link VIO.  Create a Vivado VIO IP with these probe widths.
      design_vio_rifl_bist design_vio_rifl_bist_0 (
         .clk(core_clk)
        ,.probe_out0(bist_tx_start_vio)
        ,.probe_out1(bist_tx_stop_vio)
        ,.probe_out2(bist_rx_start_vio)
        ,.probe_out3(bist_rx_stop_vio)
        ,.probe_out4(bist_clear_vio)
        ,.probe_out5(bist_cfg_len_mode_vio)
        ,.probe_out6(bist_cfg_pkt_len_vio)
        ,.probe_out7(bist_cfg_pkt_len_min_vio)
        ,.probe_out8(bist_cfg_pkt_len_max_vio)
        ,.probe_out9(bist_cfg_gap_vio)
        ,.probe_out10(bist_cfg_packet_count_vio)
        ,.probe_out11(bist_cfg_seed_vio)
        ,.probe_in0 (bist_tx_busy_lo)
        ,.probe_in1 (bist_tx_done_lo)
        ,.probe_in2 (bist_rx_active_lo)
        ,.probe_in3 (bist_rx_done_lo)
        ,.probe_in4 (bist_error_lo)
        ,.probe_in5 (bist_error_kind_lo)
        ,.probe_in6 (bist_sent_flit_count_lo)
        ,.probe_in7 (bist_sent_packet_count_lo)
        ,.probe_in8 (bist_recv_flit_count_lo)
        ,.probe_in9 (bist_recv_packet_count_lo)
        ,.probe_in10(bist_err_pkt_idx_lo)
        ,.probe_in11(bist_err_flit_idx_lo)
        ,.probe_in12(bist_err_expected_lo)
        ,.probe_in13(bist_err_actual_lo)
        ,.probe_in14(bist_err_expected_last_lo)
        ,.probe_in15(bist_err_actual_last_lo)
      );

      logic vio_rifl_rst_lo;
      assign rifl_rsts[i] = vio_rifl_rst_lo;
      assign rifl_gt_rsts[i] = vio_rifl_rst_lo;
      design_vio_rifl_rst design_vio_rifl_rst_0 (
         .clk(init_clk)
        ,.rst(vio_rifl_rst_lo)
      );

    `DMA_WIDTH_CONVERTER_MODULE #(
       .dma_data_width_p(dma_data_width_lp)
      ,.gty_data_width_p(axis_data_width_p)
    ) converter (
       .dma_clk_i(core_clk)
      ,.dma_reset_i(core_reset_pipelined)

      ,.gty_clk_i(rifl_usr_clks[i])
      ,.gty_reset_i(rifl_usr_rsts[i])

      ,.dma_tdata_o (converter_dma_tdata_lo )
      ,.dma_tlast_o (converter_dma_tlast_lo )
      ,.dma_tready_i(converter_dma_tready_li)
      ,.dma_tvalid_o(converter_dma_tvalid_lo)

      ,.dma_tdata_i (converter_dma_tdata_li )
      ,.dma_tlast_i (converter_dma_tlast_li )
      ,.dma_tready_o(converter_dma_tready_lo)
      ,.dma_tvalid_i(converter_dma_tvalid_li)

      ,.gty_tdata_o (s_axis_tdata_gty_i[i] )
      ,.gty_tlast_o (s_axis_tlast_gty_i[i] )
      ,.gty_tready_i(s_axis_tready_gty_o[i])
      ,.gty_tvalid_o(s_axis_tvalid_gty_i[i])

      ,.gty_tdata_i (m_axis_tdata_gty_o[i] )
      ,.gty_tlast_i (m_axis_tlast_gty_o[i] )
      ,.gty_tready_o(m_axis_tready_gty_i[i])
      ,.gty_tvalid_i(m_axis_tvalid_gty_o[i])
    );
    // We assume tkeep is all '1
    assign s_axis_tkeep_gty_i[i] = '1;

    // RIFL AXIS debug ILA
    logic [15:0] m_axis_counter_r, s_axis_counter_r;
    logic [15:0] m_axis_counter_last_r, s_axis_counter_last_r;
    logic [15:0] m_axis_counter_tkeep_r, s_axis_counter_tkeep_r;
    always_ff @(posedge rifl_usr_clks[i])
      begin
        if (rifl_usr_rsts[i])
          begin
            m_axis_counter_r       <= '0;
            s_axis_counter_r       <= '0;
            m_axis_counter_last_r  <= '0;
            s_axis_counter_last_r  <= '0;
            m_axis_counter_tkeep_r <= '0;
            s_axis_counter_tkeep_r <= '0;
          end
        else
          begin
            m_axis_counter_r       <= m_axis_counter_r       + (m_axis_tvalid_gty_o[i] & m_axis_tready_gty_i[i]                                );
            s_axis_counter_r       <= s_axis_counter_r       + (s_axis_tvalid_gty_i[i] & s_axis_tready_gty_o[i]                                );
            m_axis_counter_last_r  <= m_axis_counter_last_r  + (m_axis_tvalid_gty_o[i] & m_axis_tready_gty_i[i] &  m_axis_tlast_gty_o[i]       );
            s_axis_counter_last_r  <= s_axis_counter_last_r  + (s_axis_tvalid_gty_i[i] & s_axis_tready_gty_o[i] &  s_axis_tlast_gty_i[i]       );
            m_axis_counter_tkeep_r <= m_axis_counter_tkeep_r + (m_axis_tvalid_gty_o[i] & m_axis_tready_gty_i[i] & (m_axis_tkeep_gty_o[i] != '1));
            s_axis_counter_tkeep_r <= s_axis_counter_tkeep_r + (s_axis_tvalid_gty_i[i] & s_axis_tready_gty_o[i] & (s_axis_tkeep_gty_i[i] != '1));
          end
      end

    design_ila_axis_debug design_ila_axis_debug_0
    (.clk                  (rifl_usr_clks               [i])
    ,.m_axis_counter       (m_axis_counter_r               )
    ,.s_axis_counter       (s_axis_counter_r               )
    ,.m_axis_counter_last  (m_axis_counter_last_r          )
    ,.s_axis_counter_last  (s_axis_counter_last_r          )
    ,.m_axis_counter_tkeep (m_axis_counter_tkeep_r         )
    ,.s_axis_counter_tkeep (s_axis_counter_tkeep_r         )
    ,.tx_state_init        (rifl_tx_state_init_o        [i])
    ,.tx_state_send_pause  (rifl_tx_state_send_pause_o  [i])
    ,.tx_state_pause       (rifl_tx_state_pause_o       [i])
    ,.tx_state_send_retrans(rifl_tx_state_send_retrans_o[i])
    ,.tx_state_retrans     (rifl_tx_state_retrans_o     [i])
    ,.tx_state_normal      (rifl_tx_state_normal_o      [i])
    ,.rx_up                (rifl_rx_up_o                [i])
    ,.rx_aligned           (rifl_rx_aligned_o           [i])
    ,.rx_error             (rifl_rx_error_o             [i])
    ,.rx_pause_request     (rifl_rx_pause_request_o     [i])
    ,.rx_retrans_request   (rifl_rx_retrans_request_o   [i])
    ,.local_fc             (rifl_local_fc_o             [i])
    ,.remote_fc            (rifl_remote_fc_o            [i])
    ,.compensate           (rifl_compensate_o           [i])
    );

  end

  firmware_bd firmware_bd
       (.ext_refclk_clk_n(ext_refclk_n),
        .ext_refclk_clk_p(ext_refclk_p),
        .init_clk(init_clk),
        .core_clk(core_clk)
        );

endmodule

`undef DMA_WIDTH_CONVERTER_MODULE

`default_nettype wire
