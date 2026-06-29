`timescale 1 ps / 1 ps
`default_nettype none

// -----------------------------------------------------------------------------
// AXI-stream traffic generator/checker for RIFL optical-link bring-up.
//
// Timing-optimized version:
//   * VIO configuration is captured into local registers at start.
//   * Random packet length mode uses a stateful deterministic 16-bit LFSR
//     schedule instead of a stateless hash+multiply path.
//   * Packet lengths are precomputed one packet ahead, so packet-boundary
//     updates assign cur_len <= next_len rather than recomputing a multiply.
//
// Both nodes should be configured with the same seed and packet-length schedule
// so the checker can regenerate expected data locally. TX/RX configuration is
// captured independently on tx_start_i/rx_start_i, so the receiver can be
// armed before or after the transmitter for backpressure testing.
//
// Packet length is in this module's AXIS flits, i.e. data_width_p-bit words.
// For the current top-level insertion point this is dma_data_width_lp bits
// in the axi_hbm_clk domain.
// -----------------------------------------------------------------------------
module axis_traffic_gen_checker
  #(parameter data_width_p       = 512
   ,parameter counter_width_p    = 64
   ,parameter packet_len_width_p = 16
   ,parameter gap_width_p        = 16
   )
  (input  wire clk_i
  ,input  wire reset_i

  // VIO-style control. TX and RX can be started/stopped independently.
  // Start inputs are edge-detected; stop_i/clear_i are levels.
  ,input  wire tx_start_i
  ,input  wire tx_stop_i
  ,input  wire rx_start_i
  ,input  wire rx_stop_i
  ,input  wire clear_i

  // 0: fixed cfg_pkt_len_i.
  // 1: sweep cfg_pkt_len_min_i..cfg_pkt_len_max_i, incrementing once per packet.
  // 2/3: deterministic pseudo-random length in cfg_pkt_len_min_i..cfg_pkt_len_max_i.
  //      Random mode now uses a stateful LFSR sequence. TX and RX regenerate
  //      the same sequence independently when configured with the same seed.
  ,input  wire [1:0] cfg_len_mode_i
  ,input  wire [packet_len_width_p-1:0] cfg_pkt_len_i
  ,input  wire [packet_len_width_p-1:0] cfg_pkt_len_min_i
  ,input  wire [packet_len_width_p-1:0] cfg_pkt_len_max_i
  ,input  wire [gap_width_p-1:0]        cfg_gap_i
  // 0 means run forever.
  ,input  wire [counter_width_p-1:0]    cfg_packet_count_i
  ,input  wire [31:0]                   cfg_seed_i

  // TX AXIS toward converter/RIFL.
  ,output logic [data_width_p-1:0] tx_tdata_o
  ,output logic                    tx_tlast_o
  ,input  wire                     tx_tready_i
  ,output logic                    tx_tvalid_o

  // RX AXIS from converter/RIFL.
  ,input  wire [data_width_p-1:0]  rx_tdata_i
  ,input  wire                     rx_tlast_i
  ,output wire                     rx_tready_o
  ,input  wire                     rx_tvalid_i

  // Status/counters.
  ,output logic                    tx_busy_o
  ,output logic                    tx_done_o
  ,output logic                    rx_active_o
  ,output logic                    rx_done_o
  ,output logic                    error_o
  ,output logic [3:0]              error_kind_o

  ,output logic [counter_width_p-1:0] sent_flit_count_o
  ,output logic [counter_width_p-1:0] sent_packet_count_o
  ,output logic [counter_width_p-1:0] recv_flit_count_o
  ,output logic [counter_width_p-1:0] recv_packet_count_o

  // First-error debug snapshot.
  ,output logic [counter_width_p-1:0] err_pkt_idx_o
  ,output logic [31:0]                err_flit_idx_o
  ,output logic [63:0]                err_expected_lo_o
  ,output logic [63:0]                err_actual_lo_o
  ,output logic                       err_expected_last_o
  ,output logic                       err_actual_last_o
  );

  localparam words_lp = data_width_p / 32;

`ifndef SYNTHESIS
  initial begin
    if ((data_width_p % 32) != 0)
      $error("axis_traffic_gen_checker: data_width_p must be a multiple of 32");
    if (packet_len_width_p > 16)
      $error("axis_traffic_gen_checker: timing-optimized randlen assumes packet_len_width_p <= 16");
  end
`endif

  function automatic [31:0] mix32(input [31:0] x_i);
    logic [31:0] x;
    begin
      x = x_i;
      x = x ^ (x << 13);
      x = x ^ (x >> 17);
      x = x ^ (x << 5);
      mix32 = x;
    end
  endfunction

  function automatic [data_width_p-1:0] make_data
    (input [31:0] seed_i
    ,input [counter_width_p-1:0] pkt_i
    ,input [31:0] flit_i
    );
    logic [data_width_p-1:0] data;
    logic [31:0] x;
    begin
      data = '0;
      for (int word_i = 0; word_i < words_lp; word_i++) begin
        logic [31:0] word32;
        word32 = word_i;
        x = seed_i
          ^ pkt_i[31:0]
          ^ pkt_i[counter_width_p-1 -: 32]
          ^ {flit_i[15:0], flit_i[31:16]}
          ^ (32'h9e37_79b9 + (word32 << 16) + word32)
          ^ {word32[7:0], ~word32[7:0], (word32[7:0] + 8'h5a), flit_i[7:0]};
        data[word_i*32 +: 32] = mix32(x);
      end
      make_data = data;
    end
  endfunction

  function automatic [packet_len_width_p-1:0] nonzero_len
    (input [packet_len_width_p-1:0] len_i);
    begin
      nonzero_len = (len_i == '0) ? packet_len_width_p'(1) : len_i;
    end
  endfunction

  function automatic [packet_len_width_p-1:0] sane_max_len
    (input [packet_len_width_p-1:0] min_i
    ,input [packet_len_width_p-1:0] max_i
    );
    logic [packet_len_width_p-1:0] min_nz;
    begin
      min_nz = nonzero_len(min_i);
      sane_max_len = (max_i < min_nz) ? min_nz : max_i;
    end
  endfunction

  function automatic [packet_len_width_p-1:0] range_from_minmax
    (input [packet_len_width_p-1:0] min_i
    ,input [packet_len_width_p-1:0] max_i
    );
    logic [packet_len_width_p-1:0] min_nz, max_nz;
    begin
      min_nz = nonzero_len(min_i);
      max_nz = sane_max_len(min_i, max_i);
      range_from_minmax = (max_nz - min_nz) + packet_len_width_p'(1);
    end
  endfunction

  function automatic [packet_len_width_p-1:0] mask_for_range
    (input [packet_len_width_p-1:0] range_i);
    logic [packet_len_width_p-1:0] m;
    begin
      m = range_i - packet_len_width_p'(1);
      for (int sh = 1; sh < packet_len_width_p; sh = sh << 1) begin
        m = m | (m >> sh);
      end
      mask_for_range = m;
    end
  endfunction

  function automatic [15:0] lfsr_seed(input [31:0] seed_i);
    logic [15:0] s;
    begin
      s = seed_i[15:0] ^ seed_i[31:16] ^ 16'hace1;
      lfsr_seed = (s == 16'h0000) ? 16'h1 : s;
    end
  endfunction

  function automatic [15:0] lfsr16_next(input [15:0] state_i);
    logic fb;
    begin
      // Fibonacci maximal-length polynomial: x^16 + x^14 + x^13 + x^11 + 1.
      fb = state_i[15] ^ state_i[13] ^ state_i[12] ^ state_i[10];
      lfsr16_next = {state_i[14:0], fb};
    end
  endfunction

  function automatic [packet_len_width_p-1:0] rand_len_from_lfsr
    (input [15:0] rand_i
    ,input [packet_len_width_p-1:0] min_i
    ,input [packet_len_width_p-1:0] range_i
    ,input [packet_len_width_p-1:0] mask_i
    );
    logic [packet_len_width_p-1:0] offset;
    begin
      // Timing-friendly mapping.  It is not perfectly uniform, but it avoids
      // the previous rand16*range DSP/multiply critical path.
      offset = packet_len_width_p'(rand_i) & mask_i;
      if (offset >= range_i)
        offset = offset - range_i;
      rand_len_from_lfsr = min_i + offset;
    end
  endfunction

  function automatic [packet_len_width_p-1:0] first_len_cached
    (input [1:0] mode_i
    ,input [packet_len_width_p-1:0] fixed_i
    ,input [packet_len_width_p-1:0] min_i
    ,input [packet_len_width_p-1:0] range_i
    ,input [packet_len_width_p-1:0] mask_i
    ,input [15:0] rand_i
    );
    begin
      unique case (mode_i)
        2'd0: first_len_cached = fixed_i;
        2'd1: first_len_cached = min_i;
        default: first_len_cached = rand_len_from_lfsr(rand_i, min_i, range_i, mask_i);
      endcase
    end
  endfunction

  function automatic [packet_len_width_p-1:0] next_len_cached
    (input [1:0] mode_i
    ,input [packet_len_width_p-1:0] cur_i
    ,input [packet_len_width_p-1:0] fixed_i
    ,input [packet_len_width_p-1:0] min_i
    ,input [packet_len_width_p-1:0] max_i
    ,input [packet_len_width_p-1:0] range_i
    ,input [packet_len_width_p-1:0] mask_i
    ,input [15:0] rand_i
    );
    begin
      unique case (mode_i)
        2'd0: next_len_cached = fixed_i;
        2'd1: next_len_cached = (cur_i >= max_i) ? min_i : (cur_i + packet_len_width_p'(1));
        default: next_len_cached = rand_len_from_lfsr(rand_i, min_i, range_i, mask_i);
      endcase
    end
  endfunction

  // Edge-detect VIO starts and capture TX/RX configuration independently.
  logic tx_start_r, rx_start_r;
  wire tx_start_pulse = tx_start_i & ~tx_start_r;
  wire rx_start_pulse = rx_start_i & ~rx_start_r;

  logic tx_start_pending_r, rx_start_pending_r;
  wire tx_run_start = tx_start_pending_r & ~tx_stop_i;
  wire rx_run_start = rx_start_pending_r & ~rx_stop_i;

  // TX-side captured configuration.
  logic [1:0] tx_cfg_len_mode_r;
  logic [packet_len_width_p-1:0] tx_cfg_fixed_len_r;
  logic [packet_len_width_p-1:0] tx_cfg_min_len_r;
  logic [packet_len_width_p-1:0] tx_cfg_max_len_r;
  logic [packet_len_width_p-1:0] tx_cfg_range_r;
  logic [packet_len_width_p-1:0] tx_cfg_range_mask_r;
  logic [gap_width_p-1:0]        tx_cfg_gap_r;
  logic [counter_width_p-1:0]    tx_cfg_packet_count_r;
  logic [31:0]                   tx_cfg_seed_r;
  logic [15:0]                   tx_cfg_lfsr_seed_r;
  logic [15:0]                   tx_cfg_lfsr_seed_next_r;

  // RX-side captured configuration.
  logic [1:0] rx_cfg_len_mode_r;
  logic [packet_len_width_p-1:0] rx_cfg_fixed_len_r;
  logic [packet_len_width_p-1:0] rx_cfg_min_len_r;
  logic [packet_len_width_p-1:0] rx_cfg_max_len_r;
  logic [packet_len_width_p-1:0] rx_cfg_range_r;
  logic [packet_len_width_p-1:0] rx_cfg_range_mask_r;
  logic [counter_width_p-1:0]    rx_cfg_packet_count_r;
  logic [31:0]                   rx_cfg_seed_r;
  logic [15:0]                   rx_cfg_lfsr_seed_r;
  logic [15:0]                   rx_cfg_lfsr_seed_next_r;

  always_ff @(posedge clk_i) begin
    if (reset_i) begin
      tx_start_r                 <= 1'b0;
      rx_start_r                 <= 1'b0;
      tx_start_pending_r         <= 1'b0;
      rx_start_pending_r         <= 1'b0;

      tx_cfg_len_mode_r          <= '0;
      tx_cfg_fixed_len_r         <= packet_len_width_p'(1);
      tx_cfg_min_len_r           <= packet_len_width_p'(1);
      tx_cfg_max_len_r           <= packet_len_width_p'(1);
      tx_cfg_range_r             <= packet_len_width_p'(1);
      tx_cfg_range_mask_r        <= '0;
      tx_cfg_gap_r               <= '0;
      tx_cfg_packet_count_r      <= '0;
      tx_cfg_seed_r              <= '0;
      tx_cfg_lfsr_seed_r         <= 16'hace1;
      tx_cfg_lfsr_seed_next_r    <= lfsr16_next(16'hace1);

      rx_cfg_len_mode_r          <= '0;
      rx_cfg_fixed_len_r         <= packet_len_width_p'(1);
      rx_cfg_min_len_r           <= packet_len_width_p'(1);
      rx_cfg_max_len_r           <= packet_len_width_p'(1);
      rx_cfg_range_r             <= packet_len_width_p'(1);
      rx_cfg_range_mask_r        <= '0;
      rx_cfg_packet_count_r      <= '0;
      rx_cfg_seed_r              <= '0;
      rx_cfg_lfsr_seed_r         <= 16'hace1;
      rx_cfg_lfsr_seed_next_r    <= lfsr16_next(16'hace1);
    end else begin
      tx_start_r <= tx_start_i;
      rx_start_r <= rx_start_i;

      if (clear_i) begin
        tx_start_pending_r <= 1'b0;
        rx_start_pending_r <= 1'b0;
      end else begin
        if (tx_start_pulse & ~tx_stop_i) begin
          logic [packet_len_width_p-1:0] min_nz;
          logic [packet_len_width_p-1:0] max_nz;
          logic [packet_len_width_p-1:0] range_nz;
          logic [15:0] seed_lfsr;

          min_nz    = nonzero_len(cfg_pkt_len_min_i);
          max_nz    = sane_max_len(cfg_pkt_len_min_i, cfg_pkt_len_max_i);
          range_nz  = (max_nz - min_nz) + packet_len_width_p'(1);
          seed_lfsr = lfsr_seed(cfg_seed_i);

          tx_cfg_len_mode_r       <= cfg_len_mode_i;
          tx_cfg_fixed_len_r      <= nonzero_len(cfg_pkt_len_i);
          tx_cfg_min_len_r        <= min_nz;
          tx_cfg_max_len_r        <= max_nz;
          tx_cfg_range_r          <= range_nz;
          tx_cfg_range_mask_r     <= mask_for_range(range_nz);
          tx_cfg_gap_r            <= cfg_gap_i;
          tx_cfg_packet_count_r   <= cfg_packet_count_i;
          tx_cfg_seed_r           <= cfg_seed_i;
          tx_cfg_lfsr_seed_r      <= seed_lfsr;
          tx_cfg_lfsr_seed_next_r <= lfsr16_next(seed_lfsr);
          tx_start_pending_r      <= 1'b1;
        end else if (tx_start_pending_r) begin
          tx_start_pending_r <= 1'b0;
        end

        if (rx_start_pulse & ~rx_stop_i) begin
          logic [packet_len_width_p-1:0] min_nz;
          logic [packet_len_width_p-1:0] max_nz;
          logic [packet_len_width_p-1:0] range_nz;
          logic [15:0] seed_lfsr;

          min_nz    = nonzero_len(cfg_pkt_len_min_i);
          max_nz    = sane_max_len(cfg_pkt_len_min_i, cfg_pkt_len_max_i);
          range_nz  = (max_nz - min_nz) + packet_len_width_p'(1);
          seed_lfsr = lfsr_seed(cfg_seed_i);

          rx_cfg_len_mode_r       <= cfg_len_mode_i;
          rx_cfg_fixed_len_r      <= nonzero_len(cfg_pkt_len_i);
          rx_cfg_min_len_r        <= min_nz;
          rx_cfg_max_len_r        <= max_nz;
          rx_cfg_range_r          <= range_nz;
          rx_cfg_range_mask_r     <= mask_for_range(range_nz);
          rx_cfg_packet_count_r   <= cfg_packet_count_i;
          rx_cfg_seed_r           <= cfg_seed_i;
          rx_cfg_lfsr_seed_r      <= seed_lfsr;
          rx_cfg_lfsr_seed_next_r <= lfsr16_next(seed_lfsr);
          rx_start_pending_r      <= 1'b1;
        end else if (rx_start_pending_r) begin
          rx_start_pending_r <= 1'b0;
        end
      end
    end
  end

  // TX state.
  logic [counter_width_p-1:0] tx_pkt_idx_r;
  logic [31:0]                tx_flit_idx_r;
  logic [packet_len_width_p-1:0] tx_cur_len_r;
  logic [packet_len_width_p-1:0] tx_next_len_r;
  logic [15:0]                   tx_next_lfsr_r;
  logic [gap_width_p-1:0]        tx_gap_count_r;

  wire tx_target_reached = (tx_cfg_packet_count_r != '0)
                         & (sent_packet_count_o >= tx_cfg_packet_count_r);

  wire tx_in_gap = (tx_gap_count_r != '0);
  wire tx_send_v = tx_busy_o & ~tx_done_o & ~tx_target_reached & ~tx_in_gap;
  wire tx_hs     = tx_tvalid_o & tx_tready_i;
  wire tx_last   = (tx_flit_idx_r == (32'(tx_cur_len_r)-1));

  always_comb begin
    tx_tvalid_o = tx_send_v;
    tx_tlast_o  = tx_last;
    tx_tdata_o  = make_data(tx_cfg_seed_r, tx_pkt_idx_r, tx_flit_idx_r);
  end

  always_ff @(posedge clk_i) begin
    if (reset_i) begin
      tx_busy_o           <= 1'b0;
      tx_done_o           <= 1'b0;
      sent_flit_count_o   <= '0;
      sent_packet_count_o <= '0;
      tx_pkt_idx_r        <= '0;
      tx_flit_idx_r       <= '0;
      tx_cur_len_r        <= '0;
      tx_next_len_r       <= '0;
      tx_next_lfsr_r      <= '0;
      tx_gap_count_r      <= '0;
    end else begin
      if (clear_i | tx_start_pulse) begin
        tx_busy_o           <= 1'b0;
        tx_done_o           <= 1'b0;
        sent_flit_count_o   <= '0;
        sent_packet_count_o <= '0;
        tx_pkt_idx_r        <= '0;
        tx_flit_idx_r       <= '0;
        tx_cur_len_r        <= '0;
        tx_next_len_r       <= '0;
        tx_next_lfsr_r      <= '0;
        tx_gap_count_r      <= '0;
      end else if (tx_run_start) begin
        logic [packet_len_width_p-1:0] first_len;
        first_len = first_len_cached(tx_cfg_len_mode_r, tx_cfg_fixed_len_r, tx_cfg_min_len_r,
                                     tx_cfg_range_r, tx_cfg_range_mask_r, tx_cfg_lfsr_seed_r);
        tx_busy_o           <= 1'b1;
        tx_done_o           <= 1'b0;
        sent_flit_count_o   <= '0;
        sent_packet_count_o <= '0;
        tx_pkt_idx_r        <= '0;
        tx_flit_idx_r       <= '0;
        tx_cur_len_r        <= first_len;
        tx_next_len_r       <= next_len_cached(tx_cfg_len_mode_r, first_len,
                                               tx_cfg_fixed_len_r, tx_cfg_min_len_r, tx_cfg_max_len_r,
                                               tx_cfg_range_r, tx_cfg_range_mask_r, tx_cfg_lfsr_seed_next_r);
        tx_next_lfsr_r      <= tx_cfg_lfsr_seed_next_r;
        tx_gap_count_r      <= '0;
      end else if (tx_stop_i) begin
        tx_busy_o      <= 1'b0;
        tx_done_o      <= tx_done_o;
        tx_gap_count_r <= '0;
      end else if (tx_busy_o & ~tx_done_o) begin
        if (tx_target_reached) begin
          tx_done_o <= 1'b1;
          tx_busy_o <= 1'b0;
        end else if (tx_in_gap) begin
          tx_gap_count_r <= tx_gap_count_r - gap_width_p'(1);
        end else if (tx_hs) begin
          sent_flit_count_o <= sent_flit_count_o + counter_width_p'(1);

          if (tx_last) begin
            logic [15:0] tx_lfsr_next_next;
            tx_lfsr_next_next = lfsr16_next(tx_next_lfsr_r);

            sent_packet_count_o <= sent_packet_count_o + counter_width_p'(1);
            tx_pkt_idx_r        <= tx_pkt_idx_r + counter_width_p'(1);
            tx_flit_idx_r       <= '0;
            tx_cur_len_r        <= tx_next_len_r;
            tx_next_len_r       <= next_len_cached(tx_cfg_len_mode_r, tx_next_len_r,
                                                   tx_cfg_fixed_len_r, tx_cfg_min_len_r, tx_cfg_max_len_r,
                                                   tx_cfg_range_r, tx_cfg_range_mask_r, tx_lfsr_next_next);
            tx_next_lfsr_r      <= tx_lfsr_next_next;
            tx_gap_count_r      <= tx_cfg_gap_r;

            if ((tx_cfg_packet_count_r != '0)
                & ((sent_packet_count_o + counter_width_p'(1)) >= tx_cfg_packet_count_r)) begin
              tx_done_o <= 1'b1;
              tx_busy_o <= 1'b0;
            end
          end else begin
            tx_flit_idx_r <= tx_flit_idx_r + 32'd1;
          end
        end
      end
    end
  end

  // RX checker state.
  logic [counter_width_p-1:0] rx_pkt_idx_r;
  logic [31:0]                rx_flit_idx_r;
  logic [packet_len_width_p-1:0] rx_cur_len_r;
  logic [packet_len_width_p-1:0] rx_next_len_r;
  logic [15:0]                   rx_next_lfsr_r;

  wire rx_hs = rx_tvalid_i & rx_tready_o;
  wire rx_expected_last = (rx_flit_idx_r == (32'(rx_cur_len_r)-1));
  wire [data_width_p-1:0] rx_expected_data = make_data(rx_cfg_seed_r, rx_pkt_idx_r, rx_flit_idx_r);
  wire rx_extra_after_target = (rx_cfg_packet_count_r != '0)
                             & (recv_packet_count_o >= rx_cfg_packet_count_r);

  // Sink only when the RX checker has been armed.  This lets VIO control
  // whether the peer transmitter sees backpressure at startup.
  assign rx_tready_o = rx_active_o & ~rx_stop_i;

  always_ff @(posedge clk_i) begin
    if (reset_i) begin
      rx_active_o          <= 1'b0;
      rx_done_o            <= 1'b0;
      recv_flit_count_o    <= '0;
      recv_packet_count_o  <= '0;
      rx_pkt_idx_r         <= '0;
      rx_flit_idx_r        <= '0;
      rx_cur_len_r         <= '0;
      rx_next_len_r        <= '0;
      rx_next_lfsr_r       <= '0;
      error_o              <= 1'b0;
      error_kind_o         <= '0;
      err_pkt_idx_o        <= '0;
      err_flit_idx_o       <= '0;
      err_expected_lo_o    <= '0;
      err_actual_lo_o      <= '0;
      err_expected_last_o  <= 1'b0;
      err_actual_last_o    <= 1'b0;
    end else begin
      if (clear_i | rx_start_pulse) begin
        rx_active_o          <= 1'b0;
        rx_done_o            <= 1'b0;
        recv_flit_count_o    <= '0;
        recv_packet_count_o  <= '0;
        rx_pkt_idx_r         <= '0;
        rx_flit_idx_r        <= '0;
        rx_cur_len_r         <= '0;
        rx_next_len_r        <= '0;
        rx_next_lfsr_r       <= '0;
        error_o              <= 1'b0;
        error_kind_o         <= '0;
        err_pkt_idx_o        <= '0;
        err_flit_idx_o       <= '0;
        err_expected_lo_o    <= '0;
        err_actual_lo_o      <= '0;
        err_expected_last_o  <= 1'b0;
        err_actual_last_o    <= 1'b0;
      end else if (rx_run_start) begin
        logic [packet_len_width_p-1:0] first_len;
        first_len = first_len_cached(rx_cfg_len_mode_r, rx_cfg_fixed_len_r, rx_cfg_min_len_r,
                                     rx_cfg_range_r, rx_cfg_range_mask_r, rx_cfg_lfsr_seed_r);
        rx_active_o          <= 1'b1;
        rx_done_o            <= 1'b0;
        recv_flit_count_o    <= '0;
        recv_packet_count_o  <= '0;
        rx_pkt_idx_r         <= '0;
        rx_flit_idx_r        <= '0;
        rx_cur_len_r         <= first_len;
        rx_next_len_r        <= next_len_cached(rx_cfg_len_mode_r, first_len,
                                                rx_cfg_fixed_len_r, rx_cfg_min_len_r, rx_cfg_max_len_r,
                                                rx_cfg_range_r, rx_cfg_range_mask_r, rx_cfg_lfsr_seed_next_r);
        rx_next_lfsr_r       <= rx_cfg_lfsr_seed_next_r;
        error_o              <= 1'b0;
        error_kind_o         <= '0;
        err_pkt_idx_o        <= '0;
        err_flit_idx_o       <= '0;
        err_expected_lo_o    <= '0;
        err_actual_lo_o      <= '0;
        err_expected_last_o  <= 1'b0;
        err_actual_last_o    <= 1'b0;
      end else if (rx_stop_i) begin
        rx_active_o <= 1'b0;
      end else if (rx_hs) begin
        recv_flit_count_o <= recv_flit_count_o + counter_width_p'(1);

        if (!error_o) begin
          if (rx_extra_after_target) begin
            error_o             <= 1'b1;
            error_kind_o        <= 4'd3;
            err_pkt_idx_o       <= rx_pkt_idx_r;
            err_flit_idx_o      <= rx_flit_idx_r;
            err_expected_lo_o   <= '0;
            err_actual_lo_o     <= rx_tdata_i[63:0];
            err_expected_last_o <= 1'b0;
            err_actual_last_o   <= rx_tlast_i;
          end else if (rx_tdata_i != rx_expected_data) begin
            error_o             <= 1'b1;
            error_kind_o        <= 4'd1;
            err_pkt_idx_o       <= rx_pkt_idx_r;
            err_flit_idx_o      <= rx_flit_idx_r;
            err_expected_lo_o   <= rx_expected_data[63:0];
            err_actual_lo_o     <= rx_tdata_i[63:0];
            err_expected_last_o <= rx_expected_last;
            err_actual_last_o   <= rx_tlast_i;
          end else if (rx_tlast_i != rx_expected_last) begin
            error_o             <= 1'b1;
            error_kind_o        <= 4'd2;
            err_pkt_idx_o       <= rx_pkt_idx_r;
            err_flit_idx_o      <= rx_flit_idx_r;
            err_expected_lo_o   <= rx_expected_data[63:0];
            err_actual_lo_o     <= rx_tdata_i[63:0];
            err_expected_last_o <= rx_expected_last;
            err_actual_last_o   <= rx_tlast_i;
          end
        end

        if (rx_tlast_i) begin
          logic [15:0] rx_lfsr_next_next;
          rx_lfsr_next_next = lfsr16_next(rx_next_lfsr_r);

          recv_packet_count_o <= recv_packet_count_o + counter_width_p'(1);
          rx_pkt_idx_r        <= rx_pkt_idx_r + counter_width_p'(1);
          rx_flit_idx_r       <= '0;
          rx_cur_len_r        <= rx_next_len_r;
          rx_next_len_r       <= next_len_cached(rx_cfg_len_mode_r, rx_next_len_r,
                                                 rx_cfg_fixed_len_r, rx_cfg_min_len_r, rx_cfg_max_len_r,
                                                 rx_cfg_range_r, rx_cfg_range_mask_r, rx_lfsr_next_next);
          rx_next_lfsr_r      <= rx_lfsr_next_next;

          if ((rx_cfg_packet_count_r != '0)
              & ((recv_packet_count_o + counter_width_p'(1)) >= rx_cfg_packet_count_r)) begin
            rx_done_o <= 1'b1;
          end
        end else begin
          rx_flit_idx_r <= rx_flit_idx_r + 32'd1;
        end
      end
    end
  end

endmodule

`default_nettype wire
