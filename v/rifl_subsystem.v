
`timescale 1 ps / 1 ps

`include "bsg_defines.v"

`default_nettype none

// -----------------------------------------------------------------------------
// rifl_subsystem: the RIFL optical links plus all supporting logic ("everything else"
// after the AXI-JTAG block design and the AXI clock converters are factored out).
//
// Contains: clk_wiz_0 MMCM clocking (raw IBUFDS+BUFG), the control register plane, bsg_reset_module,
// the 4 RIFL IP instances + GTs, the per-link rifl_txrx_fifo (TX/RX data + tkeep),
// the axi_lite_regs register map, per-link event counters, RX occupancy, the debug
// ILAs, and the status read-back.
//
// External AXI:
//   * cc_*   : AXI4 SLAVE per-link arrays (rifl_usr_clk[i]) from the clock
//              converters' m_axi side -> the per-link rifl_txrx_fifo.
//   * m_axil : AXI4-Lite SLAVE from design_1 M_AXI_4 -> axi_lite_regs.
// Clock/reset I/O: init_clk_o sources design_1 + the converters; axi_aresetn_i is
// the domain-1 reset (from the top-level VIO) for the AXI-Lite register map;
// cc_s_aresetn_o + cc_m_aresetn_o[i] reset the converters; usr_clk_o[i] is the
// per-link usr clock.
// -----------------------------------------------------------------------------
module rifl_subsystem
#(
    parameter gt_serial_width_p = 4
  , parameter num_gty_port_p = 4
  , parameter axis_data_width_p = 256
  , localparam axis_keep_width_lp = axis_data_width_p / 8
)
(
  // ---- top-level I/O (passed through from top_rifl) ----
    input  wire       ext_refclk_n
  , input  wire       ext_refclk_p
  , output wire [1:0] led
  , input  wire [num_gty_port_p-1:0] gt_ref_i_clk_n
  , input  wire [num_gty_port_p-1:0] gt_ref_i_clk_p
  , input  wire [num_gty_port_p*gt_serial_width_p-1:0] rifl_gt_o_gt_rxn_in
  , input  wire [num_gty_port_p*gt_serial_width_p-1:0] rifl_gt_o_gt_rxp_in
  , output wire [num_gty_port_p*gt_serial_width_p-1:0] rifl_gt_o_gt_txn_out
  , output wire [num_gty_port_p*gt_serial_width_p-1:0] rifl_gt_o_gt_txp_out

  // ---- clocks / resets shared with design_1 and the clock converters ----
  , output wire                      init_clk_o      // -> design_1 aclk_0, converter s_axi_aclk
  , input  wire                      axi_aresetn_i   // <- top-level VIO (domain-1 reset: register map)
  , output wire                      cc_s_aresetn_o  // -> converter s_axi_aresetn
  , output wire [num_gty_port_p-1:0] usr_clk_o       // -> converter m_axi_aclk (and debug)
  , output wire [num_gty_port_p-1:0] usr_rst_o       // recovered per-link user reset (debug)
  , output wire [num_gty_port_p-1:0] cc_m_aresetn_o  // -> converter m_axi_aresetn (= FIFO reset)

  // ---- cc_* : AXI4 SLAVE per-link (rifl_usr_clk[i]) <- converters m_axi ----
  , input  wire [31:0]  cc_awaddr   [num_gty_port_p]
  , input  wire [7:0]   cc_awlen    [num_gty_port_p]
  , input  wire [2:0]   cc_awsize   [num_gty_port_p]
  , input  wire [1:0]   cc_awburst  [num_gty_port_p]
  , input  wire [0:0]   cc_awlock   [num_gty_port_p]
  , input  wire [3:0]   cc_awcache  [num_gty_port_p]
  , input  wire [2:0]   cc_awprot   [num_gty_port_p]
  , input  wire [3:0]   cc_awqos    [num_gty_port_p]
  , input  wire [3:0]   cc_awregion [num_gty_port_p]
  , input  wire         cc_awvalid  [num_gty_port_p]
  , output wire         cc_awready  [num_gty_port_p]
  , input  wire [255:0] cc_wdata    [num_gty_port_p]
  , input  wire [31:0]  cc_wstrb    [num_gty_port_p]
  , input  wire         cc_wlast    [num_gty_port_p]
  , input  wire         cc_wvalid   [num_gty_port_p]
  , output wire         cc_wready   [num_gty_port_p]
  , output wire [1:0]   cc_bresp    [num_gty_port_p]
  , output wire         cc_bvalid   [num_gty_port_p]
  , input  wire         cc_bready   [num_gty_port_p]
  , input  wire [31:0]  cc_araddr   [num_gty_port_p]
  , input  wire [7:0]   cc_arlen    [num_gty_port_p]
  , input  wire [2:0]   cc_arsize   [num_gty_port_p]
  , input  wire [1:0]   cc_arburst  [num_gty_port_p]
  , input  wire [0:0]   cc_arlock   [num_gty_port_p]
  , input  wire [3:0]   cc_arcache  [num_gty_port_p]
  , input  wire [2:0]   cc_arprot   [num_gty_port_p]
  , input  wire [3:0]   cc_arqos    [num_gty_port_p]
  , input  wire [3:0]   cc_arregion [num_gty_port_p]
  , input  wire         cc_arvalid  [num_gty_port_p]
  , output wire         cc_arready  [num_gty_port_p]
  , output wire [255:0] cc_rdata    [num_gty_port_p]
  , output wire [1:0]   cc_rresp    [num_gty_port_p]
  , output wire         cc_rlast    [num_gty_port_p]
  , output wire         cc_rvalid   [num_gty_port_p]
  , input  wire         cc_rready   [num_gty_port_p]

  // ---- m_axil : AXI4-Lite SLAVE <- design_1 M_AXI_4 ----
  , input  wire [31:0]  m_axil_awaddr
  , input  wire [2:0]   m_axil_awprot
  , input  wire         m_axil_awvalid
  , output wire         m_axil_awready
  , input  wire [31:0]  m_axil_wdata
  , input  wire [3:0]   m_axil_wstrb
  , input  wire         m_axil_wvalid
  , output wire         m_axil_wready
  , output wire [1:0]   m_axil_bresp
  , output wire         m_axil_bvalid
  , input  wire         m_axil_bready
  , input  wire [31:0]  m_axil_araddr
  , input  wire [2:0]   m_axil_arprot
  , input  wire         m_axil_arvalid
  , output wire         m_axil_arready
  , output wire [31:0]  m_axil_rdata
  , output wire [1:0]   m_axil_rresp
  , output wire         m_axil_rvalid
  , input  wire         m_axil_rready
);

  wire init_clk;
  wire core_clk;
  assign init_clk_o = init_clk;

  // LED breathing
  logic led_breath = 1'b0;
  logic [31:0] led_counter_r = '0;
  always_ff @(posedge init_clk) begin
    led_counter_r <= (led_counter_r == 32'd50000000)? '0 : led_counter_r + 1;
    led_breath <= (led_counter_r == 32'd50000000)? ~led_breath : led_breath;
  end
  assign led[0] = led_breath;
  assign led[1] = ~led_breath;

  // ---------------------------------------------------------------------------
  // Software control/reset plane (init_clk domain).  csr is driven by the
  // axi_lite_regs instance near the end of the file.
  // ---------------------------------------------------------------------------
  // Domain-1 reset (design_1 + register map) comes from the top-level VIO via
  // axi_aresetn_i (init_clk domain).  Used here only for the AXI-Lite register map.
  wire axi_aresetn_li = axi_aresetn_i;

  // Register-map control outputs (csr) and the decoded control bits.
  localparam int CSR_NUM_REGS = 16;
  wire [CSR_NUM_REGS-1:0][31:0] csr;

  // reg 0 bit 0: global enable for every FIFO's AXI-Stream (TX) interface.
  wire axis_enable_all = csr[0][0];

  // reg 0 bit 1: software reset for the AXI clock converters ONLY (reset domain 2).
  // Pulse it only after all clocks are up.  Resets the init-clk (s_axi) side here;
  // the rifl_usr_clk (m_axi) side via the per-link cc_reset_sync below.
  wire cc_reset     = csr[0][1];
  wire cc_s_aresetn = ~cc_reset;
  assign cc_s_aresetn_o = cc_s_aresetn;

  // reg 0 bit 2: software "everything else" reset (active-high) -- reset domain 3.
  // Resets the RIFL cores + transceivers, and (via the user reset tree below) the
  // per-link FIFOs and usr-domain logic.  Independent of design_1/regmap (VIO) and
  // of the clock converters (cc_reset).
  wire core_reset = csr[0][2];

  wire [num_gty_port_p-1:0] rifl_rsts;
  wire [num_gty_port_p-1:0] rifl_gt_rsts;
  wire [num_gty_port_p-1:0] rifl_usr_rsts;
  wire [num_gty_port_p-1:0] rifl_usr_clks;

  assign rifl_rsts    = {num_gty_port_p{core_reset}};
  assign rifl_gt_rsts = {num_gty_port_p{core_reset}};

  // User-domain reset tree (reset domain 3): synchronizes core_reset into each
  // rifl_usr_clk domain to reset the per-link FIFOs and usr-domain logic -- the
  // usr-clock image of the everything-else reset.  Independent of the converters
  // (cc_reset) and the VIO (design_1/regmap).
  bsg_reset_module #(
     .num_gty_port_p(num_gty_port_p)
    ,.num_stages_p(3)
  ) optical_reset_module (
     .init_clk_i(init_clk)
    ,.core_clk_i(core_clk)
    ,.async_rstn_i(~core_reset)
    ,.usr_clks_i(rifl_usr_clks)
    ,.usr_rsts_o(rifl_usr_rsts)
    ,.core_rst_o()
    ,.rsts_o()
    ,.gt_rsts_o()
  );

  // Expose the per-link user clock and its synchronized reset.
  assign usr_clk_o = rifl_usr_clks;
  assign usr_rst_o = rifl_usr_rsts;

  // From GTY/RIFL into fabric (RX)
  logic [num_gty_port_p-1:0][axis_data_width_p-1:0]  m_axis_tdata_gty_o;
  logic [num_gty_port_p-1:0][axis_keep_width_lp-1:0] m_axis_tkeep_gty_o;
  logic [num_gty_port_p-1:0]                         m_axis_tlast_gty_o;
  logic [num_gty_port_p-1:0]                         m_axis_tready_gty_i;
  logic [num_gty_port_p-1:0]                         m_axis_tvalid_gty_o;

  // From fabric into GTY/RIFL (TX)
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

  wire [num_gty_port_p-1:0][11:0] gt_loopback_in = {num_gty_port_p{12'b000000000000}};

  // ---- per-event {sticky, count} status words (init_clk) ----
  wire [31:0] evt_rx_error_st   [num_gty_port_p][gt_serial_width_p];
  wire [31:0] evt_rx_pause_st   [num_gty_port_p][gt_serial_width_p];
  wire [31:0] evt_rx_retr_st    [num_gty_port_p][gt_serial_width_p];
  wire [31:0] evt_tx_spause_st  [num_gty_port_p][gt_serial_width_p];
  wire [31:0] evt_tx_sretr_st   [num_gty_port_p][gt_serial_width_p];
  wire [31:0] evt_compensate_st [num_gty_port_p];

  // ---- RX FIFO occupancy status (init_clk) ----
  localparam int RX_FIFO_DEPTH_LP = 512;
  localparam int RX_OCC_W         = $clog2(RX_FIFO_DEPTH_LP) + 1;
  wire [31:0] rx_occ_st    [num_gty_port_p];
  wire [31:0] tkeep_occ_st [num_gty_port_p];

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

    // Reset domain 3 (everything else): user-domain image of core_reset for this
    // link's FIFOs and usr-clock logic (from bsg_reset_module above).
    wire usr_aresetn = ~rifl_usr_rsts[i];

    // Reset domain 2 (clock converters): cc_reset synchronized into this rifl_usr_clk
    // for the converter's m_axi side -- kept separate from the FIFOs (domain 3).
    wire cc_reset_sync;
    xpm_cdc_single #(
       .DEST_SYNC_FF  (4)
      ,.INIT_SYNC_FF  (0)
      ,.SIM_ASSERT_CHK(0)
      ,.SRC_INPUT_REG (0)
    ) cc_rst_cdc (
       .dest_out(cc_reset_sync)
      ,.dest_clk(rifl_usr_clks[i])
      ,.src_clk (1'b0)
      ,.src_in  (cc_reset)
    );
    assign cc_m_aresetn_o[i] = ~cc_reset_sync;

    // Synchronize the global AXIS enable (init_clk) into this link's rifl_usr_clk.
    wire axis_enable_sync;
    xpm_cdc_single #(
       .DEST_SYNC_FF  (4)
      ,.INIT_SYNC_FF  (0)
      ,.SIM_ASSERT_CHK(0)
      ,.SRC_INPUT_REG (0)
    ) axis_en_cdc (
       .dest_out(axis_enable_sync)
      ,.dest_clk(rifl_usr_clks[i])
      ,.src_clk (1'b0)
      ,.src_in  (axis_enable_all)
    );

    // Combined per-link TX+RX FIFO on the clock-converter's m_axi (cc_*) port:
    //   WRITE -> TX FIFO -> RIFL s_axis;  RIFL m_axis -> RX data + tkeep FIFOs
    //   -> READ channel (araddr-decoded).
    wire [RX_OCC_W-1:0] rx_occ_usr;
    wire [RX_OCC_W-1:0] tkeep_occ_usr;
    rifl_txrx_fifo #(
       .AXI_DATA_WIDTH(axis_data_width_p)
      ,.AXI_ADDR_WIDTH(32)
      ,.RX_FIFO_DEPTH (RX_FIFO_DEPTH_LP)
      ,.TK_FIFO_DEPTH (RX_FIFO_DEPTH_LP)
    ) txrx_fifo (
       .aclk          (rifl_usr_clks[i])
      ,.aresetn       (usr_aresetn)
      ,.s_axi_awaddr  (cc_awaddr[i] )
      ,.s_axi_awlen   (cc_awlen[i]  )
      ,.s_axi_awsize  (cc_awsize[i] )
      ,.s_axi_awburst (cc_awburst[i])
      ,.s_axi_awlock  (cc_awlock[i] )
      ,.s_axi_awcache (cc_awcache[i])
      ,.s_axi_awprot  (cc_awprot[i] )
      ,.s_axi_awqos   (cc_awqos[i]  )
      ,.s_axi_awregion(cc_awregion[i])
      ,.s_axi_awvalid (cc_awvalid[i])
      ,.s_axi_awready (cc_awready[i])
      ,.s_axi_wdata   (cc_wdata[i]  )
      ,.s_axi_wstrb   (cc_wstrb[i]  )
      ,.s_axi_wlast   (cc_wlast[i]  )
      ,.s_axi_wvalid  (cc_wvalid[i] )
      ,.s_axi_wready  (cc_wready[i] )
      ,.s_axi_bresp   (cc_bresp[i]  )
      ,.s_axi_bvalid  (cc_bvalid[i] )
      ,.s_axi_bready  (cc_bready[i] )
      ,.s_axi_araddr  (cc_araddr[i] )
      ,.s_axi_arlen   (cc_arlen[i]  )
      ,.s_axi_arsize  (cc_arsize[i] )
      ,.s_axi_arburst (cc_arburst[i])
      ,.s_axi_arlock  (cc_arlock[i] )
      ,.s_axi_arcache (cc_arcache[i])
      ,.s_axi_arprot  (cc_arprot[i] )
      ,.s_axi_arqos   (cc_arqos[i]  )
      ,.s_axi_arregion(cc_arregion[i])
      ,.s_axi_arvalid (cc_arvalid[i])
      ,.s_axi_arready (cc_arready[i])
      ,.s_axi_rdata   (cc_rdata[i]  )
      ,.s_axi_rresp   (cc_rresp[i]  )
      ,.s_axi_rlast   (cc_rlast[i]  )
      ,.s_axi_rvalid  (cc_rvalid[i] )
      ,.s_axi_rready  (cc_rready[i] )
      // TX: drained stream -> RIFL link s_axis
      ,.tx_axis_enable(axis_enable_sync)
      ,.m_axis_tdata  (s_axis_tdata_gty_i[i] )
      ,.m_axis_tlast  (s_axis_tlast_gty_i[i] )
      ,.m_axis_tvalid (s_axis_tvalid_gty_i[i])
      ,.m_axis_tready (s_axis_tready_gty_o[i])
      // RX: RIFL m_axis -> RX data + packed-tkeep FIFOs
      ,.s_axis_tdata  (m_axis_tdata_gty_o[i] )
      ,.s_axis_tkeep  (m_axis_tkeep_gty_o[i] )
      ,.s_axis_tlast  (m_axis_tlast_gty_o[i] )
      ,.s_axis_tvalid (m_axis_tvalid_gty_o[i])
      ,.s_axis_tready (m_axis_tready_gty_i[i])
      ,.rx_count_o    (rx_occ_usr)
      ,.tkeep_count_o (tkeep_occ_usr)
    );
    // RIFL TX expects all bytes valid: TX tkeep forced high (whole 256-bit words).
    assign s_axis_tkeep_gty_i[i] = '1;

    // RX data + packed-tkeep occupancies (rifl_usr_clk[i]) -> init_clk.
    wire [RX_OCC_W-1:0] rx_occ_sync, tkeep_occ_sync;
    xpm_cdc_gray #(
       .DEST_SYNC_FF(4), .INIT_SYNC_FF(0), .REG_OUTPUT(1)
      ,.SIM_ASSERT_CHK(0), .SIM_LOSSLESS_GRAY_CHK(0), .WIDTH(RX_OCC_W)
    ) rx_occ_cdc (
       .dest_out_bin(rx_occ_sync), .dest_clk(init_clk)
      ,.src_clk(rifl_usr_clks[i]), .src_in_bin(rx_occ_usr)
    );
    xpm_cdc_gray #(
       .DEST_SYNC_FF(4), .INIT_SYNC_FF(0), .REG_OUTPUT(1)
      ,.SIM_ASSERT_CHK(0), .SIM_LOSSLESS_GRAY_CHK(0), .WIDTH(RX_OCC_W)
    ) tkeep_occ_cdc (
       .dest_out_bin(tkeep_occ_sync), .dest_clk(init_clk)
      ,.src_clk(rifl_usr_clks[i]), .src_in_bin(tkeep_occ_usr)
    );
    assign rx_occ_st[i]    = 32'(rx_occ_sync);
    assign tkeep_occ_st[i] = 32'(tkeep_occ_sync);

    // RIFL AXIS debug ILA -- synthesis/hardware only; define SIMULATION to drop it.
`ifndef SIMULATION
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
`endif // !SIMULATION

    // ---- transient-event capture (per channel): sticky + saturating counter,
    //      gated/cleared by the AXIS enable, gray-synced to init_clk. ----
    for (genvar j = 0; j < gt_serial_width_p; j++) begin: ev
      event_capture_cdc #(.COUNT_WIDTH(16)) cap_rx_error (
         .src_clk(rifl_usr_clks[i]), .enable_i(axis_enable_sync)
        ,.event_i(rifl_rx_error_o[i][j]),            .dst_clk(init_clk), .status_o(evt_rx_error_st[i][j]));
      event_capture_cdc #(.COUNT_WIDTH(16)) cap_rx_pause (
         .src_clk(rifl_usr_clks[i]), .enable_i(axis_enable_sync)
        ,.event_i(rifl_rx_pause_request_o[i][j]),    .dst_clk(init_clk), .status_o(evt_rx_pause_st[i][j]));
      event_capture_cdc #(.COUNT_WIDTH(16)) cap_rx_retr (
         .src_clk(rifl_usr_clks[i]), .enable_i(axis_enable_sync)
        ,.event_i(rifl_rx_retrans_request_o[i][j]),  .dst_clk(init_clk), .status_o(evt_rx_retr_st[i][j]));
      event_capture_cdc #(.COUNT_WIDTH(16)) cap_tx_spause (
         .src_clk(rifl_usr_clks[i]), .enable_i(axis_enable_sync)
        ,.event_i(rifl_tx_state_send_pause_o[i][j]), .dst_clk(init_clk), .status_o(evt_tx_spause_st[i][j]));
      event_capture_cdc #(.COUNT_WIDTH(16)) cap_tx_sretr (
         .src_clk(rifl_usr_clks[i]), .enable_i(axis_enable_sync)
        ,.event_i(rifl_tx_state_send_retrans_o[i][j]),.dst_clk(init_clk), .status_o(evt_tx_sretr_st[i][j]));
    end
    event_capture_cdc #(.COUNT_WIDTH(16)) cap_compensate (
       .src_clk(rifl_usr_clks[i]), .enable_i(axis_enable_sync)
      ,.event_i(rifl_compensate_o[i]),               .dst_clk(init_clk), .status_o(evt_compensate_st[i]));

  end

  // Clock generation: external 200 MHz LVDS refclk -> MMCM -> init_clk (100 MHz) +
  // core_clk (250 MHz).  Raw IBUFDS (differential input buffer) + BUFG (global
  // buffer) feed the clk_wiz_0 MMCM directly (replaces the firmware_bd block design).
  wire ext_refclk_ibuf;
  wire ext_refclk_gbuf;
  IBUFDS ext_refclk_ibufds (
     .I (ext_refclk_p)
    ,.IB(ext_refclk_n)
    ,.O (ext_refclk_ibuf)
  );
  BUFG ext_refclk_bufg (
     .I(ext_refclk_ibuf)
    ,.O(ext_refclk_gbuf)
  );
  clk_wiz_0 clk_wiz_0 (
     .clk_in1 (ext_refclk_gbuf)
    ,.clk_out1(init_clk)
    ,.clk_out2(core_clk)
  );

  // ---------------------------------------------------------------------------
  // RIFL link status -> register-map status registers (read-only).
  //   [0] rx_up  [1] rx_aligned  [2] rx_error  [3] rx_pause_request
  //   [4] rx_retrans_request  [5..10] tx_state_*  [11] local_fc  [12] remote_fc
  //   [13] compensate.  Each [3:0]=per-channel within [3:0]=per-link.
  // ---------------------------------------------------------------------------
  localparam int CSR_LVL_STATUS = 14;
  wire [CSR_LVL_STATUS-1:0][31:0] rifl_status_raw;
  assign rifl_status_raw[0]  = 32'(rifl_rx_up_o);
  assign rifl_status_raw[1]  = 32'(rifl_rx_aligned_o);
  assign rifl_status_raw[2]  = 32'(rifl_rx_error_o);
  assign rifl_status_raw[3]  = 32'(rifl_rx_pause_request_o);
  assign rifl_status_raw[4]  = 32'(rifl_rx_retrans_request_o);
  assign rifl_status_raw[5]  = 32'(rifl_tx_state_init_o);
  assign rifl_status_raw[6]  = 32'(rifl_tx_state_send_pause_o);
  assign rifl_status_raw[7]  = 32'(rifl_tx_state_pause_o);
  assign rifl_status_raw[8]  = 32'(rifl_tx_state_send_retrans_o);
  assign rifl_status_raw[9]  = 32'(rifl_tx_state_retrans_o);
  assign rifl_status_raw[10] = 32'(rifl_tx_state_normal_o);
  assign rifl_status_raw[11] = 32'(rifl_local_fc_o);
  assign rifl_status_raw[12] = 32'(rifl_remote_fc_o);
  assign rifl_status_raw[13] = 32'(rifl_compensate_o);

  wire [CSR_LVL_STATUS-1:0][31:0] rifl_status_sync;
  xpm_cdc_array_single #(
     .DEST_SYNC_FF  (4)
    ,.INIT_SYNC_FF  (0)
    ,.SIM_ASSERT_CHK(0)
    ,.SRC_INPUT_REG (0)
    ,.WIDTH         (CSR_LVL_STATUS*32)
  ) status_cdc (
     .dest_out(rifl_status_sync)
    ,.dest_clk(init_clk)
    ,.src_clk (1'b0)
    ,.src_in  (rifl_status_raw)
  );

  // Full status bus = level status + per-event {sticky,count} + RX occupancies.
  //   [14..93] per-channel event counters (rx_error, rx_pause, rx_retrans,
  //            tx_send_pause, tx_send_retrans; index = base + link*4 + channel)
  //   [94..97] compensate   [98..101] rx_data_occupancy   [102..105] rx_tkeep_occupancy
  localparam int EVT_PER_SIG    = num_gty_port_p*gt_serial_width_p;
  localparam int CSR_NUM_STATUS = CSR_LVL_STATUS + 5*EVT_PER_SIG + 3*num_gty_port_p; // 106

  wire [CSR_NUM_STATUS-1:0][31:0] status_all;
  assign status_all[CSR_LVL_STATUS-1:0] = rifl_status_sync;
  for (genvar i = 0; i < num_gty_port_p; i++) begin: stpack
    for (genvar j = 0; j < gt_serial_width_p; j++) begin
      assign status_all[CSR_LVL_STATUS + 0*EVT_PER_SIG + i*gt_serial_width_p + j] = evt_rx_error_st  [i][j];
      assign status_all[CSR_LVL_STATUS + 1*EVT_PER_SIG + i*gt_serial_width_p + j] = evt_rx_pause_st  [i][j];
      assign status_all[CSR_LVL_STATUS + 2*EVT_PER_SIG + i*gt_serial_width_p + j] = evt_rx_retr_st   [i][j];
      assign status_all[CSR_LVL_STATUS + 3*EVT_PER_SIG + i*gt_serial_width_p + j] = evt_tx_spause_st [i][j];
      assign status_all[CSR_LVL_STATUS + 4*EVT_PER_SIG + i*gt_serial_width_p + j] = evt_tx_sretr_st  [i][j];
    end
    assign status_all[CSR_LVL_STATUS + 5*EVT_PER_SIG + i]                    = evt_compensate_st[i];
    assign status_all[CSR_LVL_STATUS + 5*EVT_PER_SIG + 1*num_gty_port_p + i] = rx_occ_st[i];
    assign status_all[CSR_LVL_STATUS + 5*EVT_PER_SIG + 2*num_gty_port_p + i] = tkeep_occ_st[i];
  end

  // ---------------------------------------------------------------------------
  // Register map on the AXI4-Lite port (M_AXI_4): control bits out, status in.
  // ---------------------------------------------------------------------------
  axi_lite_regs #(
     .NUM_REGS      (CSR_NUM_REGS)
    ,.NUM_STATUS    (CSR_NUM_STATUS)
    ,.AXI_ADDR_WIDTH(32)
  ) u_axi_lite_regs (
     .aclk         (init_clk)
    ,.aresetn      (axi_aresetn_li)
    ,.s_axi_awaddr (m_axil_awaddr )
    ,.s_axi_awprot (m_axil_awprot )
    ,.s_axi_awvalid(m_axil_awvalid)
    ,.s_axi_awready(m_axil_awready)
    ,.s_axi_wdata  (m_axil_wdata  )
    ,.s_axi_wstrb  (m_axil_wstrb  )
    ,.s_axi_wvalid (m_axil_wvalid )
    ,.s_axi_wready (m_axil_wready )
    ,.s_axi_bresp  (m_axil_bresp  )
    ,.s_axi_bvalid (m_axil_bvalid )
    ,.s_axi_bready (m_axil_bready )
    ,.s_axi_araddr (m_axil_araddr )
    ,.s_axi_arprot (m_axil_arprot )
    ,.s_axi_arvalid(m_axil_arvalid)
    ,.s_axi_arready(m_axil_arready)
    ,.s_axi_rdata  (m_axil_rdata  )
    ,.s_axi_rresp  (m_axil_rresp  )
    ,.s_axi_rvalid (m_axil_rvalid )
    ,.s_axi_rready (m_axil_rready )
    ,.reg_o        (csr)
    ,.status_i     (status_all)
  );

endmodule

`default_nettype wire
