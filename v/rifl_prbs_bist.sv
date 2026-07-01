`timescale 1 ps / 1 ps
`default_nettype none

// -----------------------------------------------------------------------------
// rifl_prbs_bist : per-link PRBS packet generator + self-checking receiver.
//
// When enabled, the transmit side emits back-to-back packets of pseudo-random
// data (a maximal-length PRBS-31 sequence, 256 bits/beat), of random length
// (1..max, from a 16-bit length LFSR), with a random number of valid bytes in
// the last beat (its tkeep).  The receive side regenerates the identical
// expected packet stream (same seed) and compares data, packet length, and
// tkeep for every beat.  A packet that mismatches anywhere is counted and (if
// the error buffer has room and is not mid-write) a compact fixed-size record of
// the first divergence is emitted as three 256-bit beats for software to read.
//
// TX and RX carry two independent sequences: the data PRBS advances once per
// accepted beat; the length/tkeep LFSR advances once per packet.  Both ends run
// them from the same captured seed, so over a lossless, in-order RIFL link they
// stay bit-synchronized.  A single corrupted data word flags one error without
// desyncing either sequence.
//
// The generator's combinational data output is registered downstream by a skid
// buffer in the subsystem before it reaches the RIFL link.
// -----------------------------------------------------------------------------
module rifl_prbs_bist
  #(parameter integer data_width_p       = 256
   ,parameter integer packet_len_width_p = 16
   ,parameter integer counter_width_p    = 32
   ,localparam integer keep_width_lp     = data_width_p/8   // 32
   ,localparam integer prbs_width_lp     = 31
   ,localparam integer rec_width_lp      = 3*data_width_p   // 768-bit error record
   )
  (input  wire clk_i
  ,input  wire reset_i                                       // active-high (usr reset)

  // ---- configuration (CDC-synced + quasi-static; captured on the enable edge) ----
  ,input  wire                          prbs_enable_i        // per-link enable + arm (level)
  ,input  wire                          clear_i              // clear counters + error buffer
  ,input  wire [1:0]                    cfg_len_mode_i       // 0 fixed / 1 sweep / 2,3 random
  ,input  wire [packet_len_width_p-1:0] cfg_pkt_len_i        // fixed / max length (beats)
  ,input  wire [packet_len_width_p-1:0] cfg_pkt_len_min_i    // min length (beats)
  ,input  wire [31:0]                   cfg_seed_i           // PRBS + length seed
  ,input  wire                          seed_perturb_i       // XOR a constant into the seed (forced-error test)

  // ---- TX AXIS toward the RIFL link (mux-selected in the subsystem) ----
  ,output logic [data_width_p-1:0]      tx_tdata_o
  ,output logic [keep_width_lp-1:0]     tx_tkeep_o
  ,output logic                         tx_tlast_o
  ,output logic                         tx_tvalid_o
  ,input  wire                          tx_tready_i

  // ---- RX AXIS from the RIFL link (tapped in the subsystem) ----
  ,input  wire [data_width_p-1:0]       rx_tdata_i
  ,input  wire [keep_width_lp-1:0]      rx_tkeep_i
  ,input  wire                          rx_tlast_i
  ,input  wire                          rx_tvalid_i
  ,output wire                          rx_tready_o

  // ---- status ----
  ,output logic [counter_width_p-1:0]   error_count_o        // corrupted packets (saturating)
  ,output logic [counter_width_p-1:0]   sent_packet_count_o
  ,output logic [counter_width_p-1:0]   recv_packet_count_o

  // ---- compact error record -> error FIFO (3 x 256-bit beats per record) ----
  ,output logic [data_width_p-1:0]      err_axis_tdata_o
  ,output logic                         err_axis_tlast_o     // last (3rd) beat of a record
  ,output logic                         err_axis_tvalid_o
  ,input  wire                          err_axis_tready_i
  );

  // ---------------------------------------------------------------------------
  // Parallel PRBS-31 (x^31 + x^28 + 1): advance 256 steps, emit 256 bits.
  // Returns {next_state[30:0], data[255:0]}.
  // ---------------------------------------------------------------------------
  function automatic [prbs_width_lp+data_width_p-1:0] prbs_step(input [prbs_width_lp-1:0] s_in);
    logic [prbs_width_lp-1:0] s;
    logic [data_width_p-1:0]  bits;
    logic fb;
    begin
      s = s_in;
      for (int k = 0; k < data_width_p; k++) begin
        bits[k] = s[prbs_width_lp-1];
        fb      = s[prbs_width_lp-1] ^ s[prbs_width_lp-4];   // taps 31,28
        s       = {s[prbs_width_lp-2:0], fb};
      end
      prbs_step = {s, bits};
    end
  endfunction

  function automatic [prbs_width_lp-1:0] prbs_seed(input [31:0] seed_i, input perturb_i);
    logic [prbs_width_lp-1:0] s;
    begin
      s = seed_i[prbs_width_lp-1:0] ^ (perturb_i ? prbs_width_lp'(31'h2AAA_AAAA) : '0);
      prbs_seed = (s == '0) ? prbs_width_lp'(1) : s;
    end
  endfunction

  // ---------------------------------------------------------------------------
  // Length + tkeep helpers (length: 16-bit Fibonacci LFSR, reused pattern).
  // ---------------------------------------------------------------------------
  function automatic [packet_len_width_p-1:0] nonzero_len(input [packet_len_width_p-1:0] len_i);
    nonzero_len = (len_i == '0) ? packet_len_width_p'(1) : len_i;
  endfunction
  function automatic [packet_len_width_p-1:0] sane_max_len
    (input [packet_len_width_p-1:0] min_i, input [packet_len_width_p-1:0] max_i);
    logic [packet_len_width_p-1:0] min_nz;
    begin min_nz = nonzero_len(min_i); sane_max_len = (max_i < min_nz) ? min_nz : max_i; end
  endfunction
  function automatic [packet_len_width_p-1:0] mask_for_range(input [packet_len_width_p-1:0] range_i);
    logic [packet_len_width_p-1:0] m;
    begin
      m = range_i - packet_len_width_p'(1);
      for (int sh = 1; sh < packet_len_width_p; sh = sh << 1) m = m | (m >> sh);
      mask_for_range = m;
    end
  endfunction
  function automatic [15:0] lfsr_seed(input [31:0] seed_i);
    logic [15:0] s;
    begin s = seed_i[15:0] ^ seed_i[31:16] ^ 16'hace1; lfsr_seed = (s == 16'h0) ? 16'h1 : s; end
  endfunction
  function automatic [15:0] lfsr16_next(input [15:0] state_i);
    // x^16 + x^14 + x^13 + x^11 + 1
    lfsr16_next = {state_i[14:0], state_i[15] ^ state_i[13] ^ state_i[12] ^ state_i[10]};
  endfunction
  function automatic [packet_len_width_p-1:0] rand_len_from_lfsr
    (input [15:0] rand_i, input [packet_len_width_p-1:0] min_i
    ,input [packet_len_width_p-1:0] range_i, input [packet_len_width_p-1:0] mask_i);
    logic [packet_len_width_p-1:0] off;
    begin
      off = packet_len_width_p'(rand_i) & mask_i;
      if (off >= range_i) off = off - range_i;
      rand_len_from_lfsr = min_i + off;
    end
  endfunction
  function automatic [packet_len_width_p-1:0] len_from_mode
    (input [1:0] mode_i, input [packet_len_width_p-1:0] cur_i, input first_i
    ,input [packet_len_width_p-1:0] fixed_i, input [packet_len_width_p-1:0] min_i
    ,input [packet_len_width_p-1:0] max_i, input [packet_len_width_p-1:0] range_i
    ,input [packet_len_width_p-1:0] mask_i, input [15:0] rand_i);
    begin
      unique case (mode_i)
        2'd0:    len_from_mode = fixed_i;
        2'd1:    len_from_mode = first_i ? min_i : ((cur_i >= max_i) ? min_i : (cur_i + packet_len_width_p'(1)));
        default: len_from_mode = rand_len_from_lfsr(rand_i, min_i, range_i, mask_i);
      endcase
    end
  endfunction
  // random valid-byte count for the last beat: 1..keep_width from LFSR high bits
  function automatic [keep_width_lp-1:0] tkeep_from_lfsr(input [15:0] rand_i);
    int nbytes; logic [keep_width_lp-1:0] m;
    begin
      nbytes = (rand_i[15:11] % keep_width_lp) + 1;   // 1..32
      m = '0;
      for (int b = 0; b < keep_width_lp; b++) m[b] = (b < nbytes);
      tkeep_from_lfsr = m;
    end
  endfunction
  // byte-replicate a tkeep mask to data width for a masked data compare
  function automatic [data_width_p-1:0] keep_to_bits(input [keep_width_lp-1:0] k_i);
    logic [data_width_p-1:0] b;
    begin for (int j = 0; j < keep_width_lp; j++) b[j*8 +: 8] = {8{k_i[j]}}; keep_to_bits = b; end
  endfunction

  // ---------------------------------------------------------------------------
  // Enable edge-detect + captured (quasi-static) configuration.
  // ---------------------------------------------------------------------------
  logic enable_r;
  wire  enable_pulse = prbs_enable_i & ~enable_r;

  logic [1:0]                    cfg_mode_r;
  logic [packet_len_width_p-1:0] cfg_fixed_r, cfg_min_r, cfg_max_r, cfg_range_r, cfg_mask_r;

  always_ff @(posedge clk_i) begin
    if (reset_i) begin
      enable_r    <= 1'b0;
      cfg_mode_r  <= '0;
      cfg_fixed_r <= packet_len_width_p'(1);
      cfg_min_r   <= packet_len_width_p'(1);
      cfg_max_r   <= packet_len_width_p'(1);
      cfg_range_r <= packet_len_width_p'(1);
      cfg_mask_r  <= '0;
    end else begin
      enable_r <= prbs_enable_i;
      if (enable_pulse) begin
        logic [packet_len_width_p-1:0] mn, mx, rg;
        mn = nonzero_len(cfg_pkt_len_min_i);
        mx = sane_max_len(cfg_pkt_len_min_i, cfg_pkt_len_i);
        rg = (mx - mn) + packet_len_width_p'(1);
        cfg_mode_r  <= cfg_len_mode_i;
        cfg_fixed_r <= nonzero_len(cfg_pkt_len_i);
        cfg_min_r   <= mn;
        cfg_max_r   <= mx;
        cfg_range_r <= rg;
        cfg_mask_r  <= mask_for_range(rg);
      end
    end
  end

  // ---------------------------------------------------------------------------
  // TX generator.
  // ---------------------------------------------------------------------------
  logic [prbs_width_lp-1:0]      tx_prbs_r;
  logic [15:0]                   tx_lfsr_r;          // length LFSR state for the NEXT packet
  logic [packet_len_width_p-1:0] tx_cur_len_r, tx_next_len_r;
  logic [keep_width_lp-1:0]      tx_cur_keep_r, tx_next_keep_r;
  logic [packet_len_width_p-1:0] tx_flit_idx_r;
  logic                          tx_run_r;

  wire [prbs_width_lp-1:0] tx_prbs_next;
  wire [data_width_p-1:0]  tx_prbs_data;
  assign {tx_prbs_next, tx_prbs_data} = prbs_step(tx_prbs_r);

  wire tx_hs   = tx_tvalid_o & tx_tready_i;
  wire tx_last = (tx_flit_idx_r == (tx_cur_len_r - packet_len_width_p'(1)));

  always_comb begin
    tx_tvalid_o = tx_run_r;
    tx_tdata_o  = tx_prbs_data;
    tx_tlast_o  = tx_last;
    tx_tkeep_o  = tx_last ? tx_cur_keep_r : '1;
  end

  always_ff @(posedge clk_i) begin
    if (reset_i | clear_i) begin
      tx_run_r <= 1'b0;
    end else if (enable_pulse) begin
      logic [prbs_width_lp-1:0] pseed;
      logic [15:0]              lseed, lseed_n;
      logic [packet_len_width_p-1:0] mn, mx, rg, mk, fl, nl;
      pseed   = prbs_seed(cfg_seed_i, 1'b0);           // TX always sends the canonical sequence
      lseed   = lfsr_seed(cfg_seed_i);
      lseed_n = lfsr16_next(lseed);
      mn = nonzero_len(cfg_pkt_len_min_i);
      mx = sane_max_len(cfg_pkt_len_min_i, cfg_pkt_len_i);
      rg = (mx - mn) + packet_len_width_p'(1);
      mk = mask_for_range(rg);
      fl = len_from_mode(cfg_len_mode_i, '0, 1'b1, nonzero_len(cfg_pkt_len_i), mn, mx, rg, mk, lseed);
      nl = len_from_mode(cfg_len_mode_i, fl, 1'b0, nonzero_len(cfg_pkt_len_i), mn, mx, rg, mk, lseed_n);
      tx_run_r       <= 1'b1;
      tx_prbs_r      <= pseed;
      tx_lfsr_r      <= lseed_n;
      tx_cur_len_r   <= fl;
      tx_next_len_r  <= nl;
      tx_cur_keep_r  <= tkeep_from_lfsr(lseed);
      tx_next_keep_r <= tkeep_from_lfsr(lseed_n);
      tx_flit_idx_r  <= '0;
    end else if (~prbs_enable_i) begin
      tx_run_r <= 1'b0;
    end else if (tx_hs) begin
      tx_prbs_r <= tx_prbs_next;                     // advance data PRBS per beat
      if (tx_last) begin
        logic [15:0] lnn;
        lnn = lfsr16_next(tx_lfsr_r);
        tx_flit_idx_r  <= '0;
        tx_cur_len_r   <= tx_next_len_r;
        tx_cur_keep_r  <= tx_next_keep_r;
        tx_next_len_r  <= len_from_mode(cfg_mode_r, tx_next_len_r, 1'b0, cfg_fixed_r,
                                        cfg_min_r, cfg_max_r, cfg_range_r, cfg_mask_r, lnn);
        tx_next_keep_r <= tkeep_from_lfsr(lnn);
        tx_lfsr_r      <= lnn;
      end else begin
        tx_flit_idx_r <= tx_flit_idx_r + packet_len_width_p'(1);
      end
    end
  end

  // ---------------------------------------------------------------------------
  // RX checker.
  // ---------------------------------------------------------------------------
  logic [prbs_width_lp-1:0]      rx_prbs_r;
  logic [15:0]                   rx_lfsr_r;
  logic [packet_len_width_p-1:0] rx_cur_len_r, rx_next_len_r;
  logic [keep_width_lp-1:0]      rx_cur_keep_r, rx_next_keep_r;
  logic [packet_len_width_p-1:0] rx_flit_idx_r;
  logic [counter_width_p-1:0]    rx_pkt_idx_r;
  logic                          rx_run_r;
  logic                          pkt_err_r;          // this packet has mismatched somewhere

  assign rx_tready_o = rx_run_r;

  wire [prbs_width_lp-1:0] rx_prbs_next;
  wire [data_width_p-1:0]  rx_exp_data;
  assign {rx_prbs_next, rx_exp_data} = prbs_step(rx_prbs_r);

  wire rx_hs        = rx_tvalid_i & rx_tready_o;
  wire rx_exp_last  = (rx_flit_idx_r == (rx_cur_len_r - packet_len_width_p'(1)));
  wire [keep_width_lp-1:0] rx_exp_keep = rx_exp_last ? rx_cur_keep_r : '1;
  wire [data_width_p-1:0]  keep_bits   = keep_to_bits(rx_exp_keep);

  wire data_mismatch  = |((rx_tdata_i ^ rx_exp_data) & keep_bits);
  wire last_mismatch  = (rx_tlast_i  != rx_exp_last);
  wire tkeep_mismatch = (rx_tkeep_i  != rx_exp_keep);
  wire flit_error     = rx_hs & (data_mismatch | last_mismatch | tkeep_mismatch);

  // captured first-divergence fields for the current packet
  logic [counter_width_p-1:0] rec_pkt_idx_r;
  logic [31:0]                rec_flit_idx_r;
  logic [data_width_p-1:0]    rec_exp_data_r, rec_rcv_data_r;
  logic [keep_width_lp-1:0]   rec_exp_keep_r, rec_rcv_keep_r;
  logic [7:0]                 rec_flags_r;

  // ---- error-record emit FSM: 3 x 256-bit beats ----
  logic                    emit_busy_r;
  logic [1:0]              emit_cnt_r;
  logic [rec_width_lp-1:0] emit_rec_r;                // {beat2, beat1, beat0}
  wire  emit_hs = err_axis_tvalid_o & err_axis_tready_i;

  assign err_axis_tvalid_o = emit_busy_r;
  assign err_axis_tdata_o  = emit_rec_r[emit_cnt_r*data_width_p +: data_width_p];
  assign err_axis_tlast_o  = (emit_cnt_r == 2'd2);

  // Record content: the latched first-divergence fields when the error was
  // earlier in the packet; when the FIRST error lands on this very (last) beat,
  // pkt_err_r is still 0, so take the current beat's fields instead.
  wire                       pkt_err_now = pkt_err_r | flit_error;
  wire [counter_width_p-1:0] q_pkt_idx   = pkt_err_r ? rec_pkt_idx_r  : rx_pkt_idx_r;
  wire [31:0]                q_flit_idx  = pkt_err_r ? rec_flit_idx_r : 32'(rx_flit_idx_r);
  wire [data_width_p-1:0]    q_exp_data  = pkt_err_r ? rec_exp_data_r : rx_exp_data;
  wire [data_width_p-1:0]    q_rcv_data  = pkt_err_r ? rec_rcv_data_r : rx_tdata_i;
  wire [keep_width_lp-1:0]   q_exp_keep  = pkt_err_r ? rec_exp_keep_r : rx_exp_keep;
  wire [keep_width_lp-1:0]   q_rcv_keep  = pkt_err_r ? rec_rcv_keep_r : rx_tkeep_i;
  wire [7:0]                 q_flags     = pkt_err_r ? rec_flags_r
                             : {rx_exp_last, rx_tlast_i, 2'b00, tkeep_mismatch, last_mismatch, data_mismatch, 1'b0};
  wire [data_width_p-1:0]    q_beat2 =
       { {(data_width_p-136){1'b0}}, q_flags, q_rcv_keep, q_exp_keep, q_flit_idx, q_pkt_idx };
  // push a record on the packet's tlast if it mismatched anywhere and the emitter is free
  wire push_now = rx_hs & rx_tlast_i & pkt_err_now & ~emit_busy_r;

  always_ff @(posedge clk_i) begin
    if (reset_i | clear_i) begin
      rx_run_r            <= 1'b0;
      rx_prbs_r           <= prbs_width_lp'(1);
      rx_lfsr_r           <= 16'h1;
      rx_cur_len_r        <= packet_len_width_p'(1);
      rx_next_len_r       <= packet_len_width_p'(1);
      rx_cur_keep_r       <= '1;
      rx_next_keep_r      <= '1;
      rx_flit_idx_r       <= '0;
      rx_pkt_idx_r        <= '0;
      pkt_err_r           <= 1'b0;
      error_count_o       <= '0;
      sent_packet_count_o <= '0;
      recv_packet_count_o <= '0;
      emit_busy_r         <= 1'b0;
      emit_cnt_r          <= 2'd0;
    end else begin
      // TX packet counter (mirror of the TX FSM's boundary)
      if (tx_hs & tx_last & tx_run_r & (sent_packet_count_o != '1))
        sent_packet_count_o <= sent_packet_count_o + counter_width_p'(1);

      if (enable_pulse) begin
        logic [15:0] lseed, lseed_n;
        logic [packet_len_width_p-1:0] mn, mx, rg, mk, fl, nl;
        lseed   = lfsr_seed(cfg_seed_i);
        lseed_n = lfsr16_next(lseed);
        mn = nonzero_len(cfg_pkt_len_min_i);
        mx = sane_max_len(cfg_pkt_len_min_i, cfg_pkt_len_i);
        rg = (mx - mn) + packet_len_width_p'(1);
        mk = mask_for_range(rg);
        fl = len_from_mode(cfg_len_mode_i, '0, 1'b1, nonzero_len(cfg_pkt_len_i), mn, mx, rg, mk, lseed);
        nl = len_from_mode(cfg_len_mode_i, fl, 1'b0, nonzero_len(cfg_pkt_len_i), mn, mx, rg, mk, lseed_n);
        rx_run_r       <= 1'b1;
        rx_prbs_r      <= prbs_seed(cfg_seed_i, seed_perturb_i);  // perturb -> checker expects a
                                                                 // different data sequence (forced-error test)
        rx_lfsr_r      <= lseed_n;
        rx_cur_len_r   <= fl;
        rx_next_len_r  <= nl;
        rx_cur_keep_r  <= tkeep_from_lfsr(lseed);
        rx_next_keep_r <= tkeep_from_lfsr(lseed_n);
        rx_flit_idx_r  <= '0;
        rx_pkt_idx_r   <= '0;
        pkt_err_r      <= 1'b0;
        error_count_o       <= '0;                       // fresh run zeroes the counters
        recv_packet_count_o <= '0;
        sent_packet_count_o <= '0;
        emit_busy_r         <= 1'b0;
        emit_cnt_r          <= 2'd0;
      end else if (~prbs_enable_i) begin
        rx_run_r <= 1'b0;                                // hold counters/FIFO for read-back
      end else if (rx_hs) begin
        rx_prbs_r <= rx_prbs_next;                       // advance data PRBS per beat

        // latch the first divergence of this packet
        if (flit_error & ~pkt_err_r) begin
          pkt_err_r      <= 1'b1;
          rec_pkt_idx_r  <= rx_pkt_idx_r;
          rec_flit_idx_r <= 32'(rx_flit_idx_r);
          rec_exp_data_r <= rx_exp_data;
          rec_rcv_data_r <= rx_tdata_i;
          rec_exp_keep_r <= rx_exp_keep;
          rec_rcv_keep_r <= rx_tkeep_i;
          rec_flags_r    <= {rx_exp_last, rx_tlast_i, 2'b00, tkeep_mismatch, last_mismatch, data_mismatch, 1'b0};
        end

        if (rx_tlast_i) begin
          logic [15:0] lnn;
          lnn = lfsr16_next(rx_lfsr_r);
          if (recv_packet_count_o != '1) recv_packet_count_o <= recv_packet_count_o + counter_width_p'(1);
          rx_pkt_idx_r   <= rx_pkt_idx_r + counter_width_p'(1);
          rx_flit_idx_r  <= '0;
          rx_cur_len_r   <= rx_next_len_r;
          rx_cur_keep_r  <= rx_next_keep_r;
          rx_next_len_r  <= len_from_mode(cfg_mode_r, rx_next_len_r, 1'b0, cfg_fixed_r,
                                          cfg_min_r, cfg_max_r, cfg_range_r, cfg_mask_r, lnn);
          rx_next_keep_r <= tkeep_from_lfsr(lnn);
          rx_lfsr_r      <= lnn;
          // count + (maybe) emit a record for this corrupted packet
          if (pkt_err_now & (error_count_o != '1))
            error_count_o <= error_count_o + counter_width_p'(1);
          pkt_err_r <= 1'b0;
        end else begin
          rx_flit_idx_r <= rx_flit_idx_r + packet_len_width_p'(1);
        end
      end

      // ---- error-record emitter ----
      if (push_now) begin
        emit_rec_r  <= {q_beat2, q_rcv_data, q_exp_data};
        emit_busy_r <= 1'b1;
        emit_cnt_r  <= 2'd0;
      end else if (emit_busy_r & emit_hs) begin
        if (emit_cnt_r == 2'd2) emit_busy_r <= 1'b0;
        else                    emit_cnt_r  <= emit_cnt_r + 2'd1;
      end
    end
  end

endmodule

`default_nettype wire
