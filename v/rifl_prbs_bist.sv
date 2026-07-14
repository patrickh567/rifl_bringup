`timescale 1 ps / 1 ps
`default_nettype none

// -----------------------------------------------------------------------------
// rifl_prbs_bist : per-link PRBS BER generator + SELF-SYNCHRONIZING checker.
//
// (IBERT-style rewrite.)  The transmit side streams a continuous maximal-length
// PRBS-31 (x^31 + x^28 + 1), 256 bits/beat, in full beats (tkeep all-ones),
// chopped into fixed-size RIFL frames only so the link has periodic TLASTs.  The
// data is byte-continuous across frames.
//
// The receive side does NOT regenerate the sequence from a seed.  It exploits the
// fact that every PRBS-31 output bit obeys a fixed recurrence:
//
//     o[n] = o[n-28] ^ o[n-31]
//
// so the checker simply tests, for every received bit, whether it equals the XOR
// of the two received bits 28 and 31 positions back:
//
//     err[n] = r[n] ^ r[n-28] ^ r[n-31]      (0 for on-sequence data)
//
// This depends ONLY on received bits, so there is no phase/seed/packet-index to
// align -- the checker is self-synchronizing.  A startup slip, a dropped or
// duplicated beat, or a whole missed packet costs only a short error burst; the
// check re-locks by itself within one beat (31 bits) as its 31-bit history refills
// with post-event data.  It structurally cannot have the "off-by-one-beat forever"
// desync of a predict-from-seed checker.
//
// Notes:
//  * Error multiplication: a single received bit error trips the recurrence at
//    positions n, n+28, n+31 -> ~3 flagged violations per real bit error.  We count
//    errored BEATS (a beat with >=1 violation); 0 = clean.  Divide-by-3 is only
//    relevant if software later popcounts the per-beat violation vectors.
//  * All-zeros blind spot: an all-zeros stream trivially satisfies the recurrence.
//    A live PRBS is never all-zeros; a DEAD link (constant 0) would falsely read 0.
//    Rely on RIFL link-up + a real stream flowing (and see recv_beat_count_o > 0).
//  * force_error_i injects a single flipped data bit periodically at the generator
//    to prove the checker + error FIFO (replaces the old seed-perturb self-test).
//    Its three recurrence violations land in one beat, so error_count climbs by +1
//    per injection (do NOT divide error_count by 3); the first injection is delayed
//    past the checker settle window so the count starts moving promptly.
//
// Timing (~390 MHz link clock, 2.56 ns): err[k] is a 3-input XOR per bit (shallow);
// the 256->1 reduce is pipelined p1 (register) -> p2 (grouped 16-bit OR) -> p3
// (16->1) -> stage 3 (count + record), same structure as before.
//
// Disable is graceful: the generator finishes the current frame (its TLAST) before
// releasing the link, so no partial frame is left on the wire.
// -----------------------------------------------------------------------------
module rifl_prbs_bist
  #(parameter integer data_width_p       = 256
   ,parameter integer packet_len_width_p = 16
   ,parameter integer counter_width_p    = 32
   ,localparam integer keep_width_lp     = data_width_p/8   // 32
   ,localparam integer prbs_width_lp     = 31
   ,localparam integer rec_width_lp      = 3*data_width_p   // 768-bit error record
   ,localparam integer default_frame_lp  = 64               // beats/frame if cfg is 0
   ,localparam integer prime_beats_lp    = 32               // checker settle after enable
   )
  (input  wire clk_i
  ,input  wire reset_i                                       // active-high (usr reset)

  // ---- configuration (CDC-synced + quasi-static; captured on the enable edge) ----
  ,input  wire                          prbs_enable_i        // per-link enable + arm (level)
  ,input  wire                          clear_i              // clear counters + error buffer
  ,input  wire [packet_len_width_p-1:0] cfg_len_mask_i       // unused (kept for interface compat)
  ,input  wire [packet_len_width_p-1:0] cfg_pkt_len_min_i    // frame size in beats (0 -> default)
  ,input  wire [31:0]                   cfg_seed_i           // PRBS seed (generator)
  ,input  wire                          force_error_i        // inject generator bit errors (self-test)

  // ---- TX AXIS toward the RIFL link (mux-selected in the subsystem) ----
  ,output logic [data_width_p-1:0]      tx_tdata_o
  ,output logic [keep_width_lp-1:0]     tx_tkeep_o
  ,output logic                         tx_tlast_o
  ,output logic                         tx_tvalid_o
  ,input  wire                          tx_tready_i
  ,output wire                          tx_active_o          // running or draining (TX mux select)

  // ---- RX AXIS from the RIFL link (tapped in the subsystem) ----
  ,input  wire [data_width_p-1:0]       rx_tdata_i
  ,input  wire [keep_width_lp-1:0]      rx_tkeep_i           // unused (full-beat stream)
  ,input  wire                          rx_tlast_i           // unused for the data check
  ,input  wire                          rx_tvalid_i
  ,output wire                          rx_tready_o

  // ---- status ----
  ,output logic [counter_width_p-1:0]   error_count_o        // errored beats (saturating); 0 = clean
  ,output logic [counter_width_p-1:0]   sent_packet_count_o  // frames sent
  ,output logic [counter_width_p-1:0]   recv_packet_count_o  // beats checked

  // ---- compact error record -> error FIFO (3 x 256-bit beats per record) ----
  //   beat0 = received data, beat1 = violation vector (which bits broke), beat2 = {beat index}
  ,output logic [data_width_p-1:0]      err_axis_tdata_o
  ,output logic                         err_axis_tlast_o     // last (3rd) beat of a record
  ,output logic                         err_axis_tvalid_o
  ,input  wire                          err_axis_tready_i
  );

  // ---------------------------------------------------------------------------
  // Parallel PRBS-31 (x^31 + x^28 + 1): advance 256 steps, emit 256 bits.
  // Returns {next_state[30:0], data[255:0]}.  Shallow XOR matrix (~2 LUT levels).
  // bits[k] is sequence position (beat_start + k); bits[0] is the earliest.
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

  function automatic [prbs_width_lp-1:0] prbs_seed(input [31:0] seed_i);
    logic [prbs_width_lp-1:0] s;
    begin
      s = seed_i[prbs_width_lp-1:0];
      prbs_seed = (s == '0) ? prbs_width_lp'(1) : s;   // never the forbidden all-zero state
    end
  endfunction

  // ---------------------------------------------------------------------------
  // Enable-edge detect + quasi-static frame length.
  // ---------------------------------------------------------------------------
  logic enable_r;
  wire  enable_pulse = prbs_enable_i & ~enable_r;
  logic [packet_len_width_p-1:0] frame_len_r;

  always_ff @(posedge clk_i) begin
    if (reset_i) begin
      enable_r    <= 1'b0;
      frame_len_r <= packet_len_width_p'(default_frame_lp);
    end else begin
      enable_r    <= prbs_enable_i;
      frame_len_r <= (cfg_pkt_len_min_i < packet_len_width_p'(2))
                       ? packet_len_width_p'(default_frame_lp) : cfg_pkt_len_min_i;
    end
  end

  // ---------------------------------------------------------------------------
  // TX generator: continuous PRBS, full beats, TLAST every frame_len_r beats.
  // ---------------------------------------------------------------------------
  logic [prbs_width_lp-1:0]      tx_prbs_r;
  logic [packet_len_width_p-1:0] tx_frame_cnt_r;
  logic [7:0]                    tx_inj_cnt_r;      // error-injection spacing (every 256 beats)
  logic                          tx_run_r;

  assign tx_active_o = tx_run_r;

  wire [prbs_width_lp-1:0] tx_prbs_next;
  wire [data_width_p-1:0]  tx_prbs_data;
  assign {tx_prbs_next, tx_prbs_data} = prbs_step(tx_prbs_r);

  wire tx_hs         = tx_tvalid_o & tx_tready_i;
  wire tx_frame_last = (tx_frame_cnt_r == frame_len_r - packet_len_width_p'(1));
  wire tx_inject     = force_error_i & (tx_inj_cnt_r == 8'd0);   // flip bit 0 periodically

  always_comb begin
    tx_tvalid_o = tx_run_r;
    tx_tdata_o  = tx_inject ? (tx_prbs_data ^ {{(data_width_p-1){1'b0}}, 1'b1}) : tx_prbs_data;
    tx_tkeep_o  = '1;                                          // always full beats
    tx_tlast_o  = tx_frame_last;
  end

  always_ff @(posedge clk_i) begin
    if (reset_i | clear_i) begin
      tx_run_r <= 1'b0;
    end else if (enable_pulse) begin
      tx_run_r       <= 1'b1;
      tx_prbs_r      <= prbs_seed(cfg_seed_i);
      tx_frame_cnt_r <= '0;
      tx_inj_cnt_r   <= 8'd128;   // first injected error lands well after the RX settle window
    end else if (tx_run_r & tx_hs) begin
      tx_prbs_r    <= tx_prbs_next;                            // advance one beat (clean sequence)
      tx_inj_cnt_r <= tx_inj_cnt_r + 8'd1;
      if (tx_frame_last) begin
        tx_frame_cnt_r <= '0;
        if (~prbs_enable_i) tx_run_r <= 1'b0;                  // graceful stop at a frame boundary
      end else begin
        tx_frame_cnt_r <= tx_frame_cnt_r + packet_len_width_p'(1);
      end
    end
  end

  // ---------------------------------------------------------------------------
  // RX self-synchronizing checker.
  //   history = previous beat's top 31 bits (sequence positions 225..255).
  //   err[k]  = r[k] ^ tap28(k) ^ tap31(k)
  //     tap28(k) = (k>=28) ? r[k-28] : hist[k+3]       // n-28 lands in prev beat for k<28
  //     tap31(k) = (k>=31) ? r[k-31] : hist[k]         // n-31 lands in prev beat for k<31
  // hist[j] holds prev-beat bit 225+j (hist[0]=prev[225], hist[30]=prev[255]).
  // ---------------------------------------------------------------------------
  logic [prbs_width_lp-1:0] hist_r;                            // prev beat bits [255:225]
  logic [7:0]               prime_r;                           // settle countdown after enable
  logic                     rx_run_r;

  assign rx_tready_o = rx_run_r;
  wire   rx_hs       = rx_tvalid_i & rx_tready_o;
  wire   rx_check    = rx_run_r & rx_hs & (prime_r == 8'd0);   // count only past the settle window

  wire [data_width_p-1:0] rx_err_vec;
  for (genvar gk = 0; gk < data_width_p; gk++) begin: recur
    wire tap28 = (gk >= 28) ? rx_tdata_i[gk-28] : hist_r[gk+3];
    wire tap31 = (gk >= 31) ? rx_tdata_i[gk-31] : hist_r[gk];
    assign rx_err_vec[gk] = rx_tdata_i[gk] ^ tap28 ^ tap31;
  end

  // ---- compare pipeline (kept shallow) ----
  logic                       p1_valid;
  logic [data_width_p-1:0]    p1_err_vec, p1_rcv_data;
  logic [counter_width_p-1:0] p1_beat_idx;

  logic                       p2_valid;
  logic [data_width_p/16-1:0] p2_partial;                      // grouped-OR of the violation vector
  logic [data_width_p-1:0]    p2_err_vec, p2_rcv_data;
  logic [counter_width_p-1:0] p2_beat_idx;

  logic                       p3_valid, p3_has_err;
  logic [data_width_p-1:0]    p3_err_vec, p3_rcv_data;
  logic [counter_width_p-1:0] p3_beat_idx;

  // ---- error record (built directly from the p3-stage errored beat) ----
  wire  [data_width_p-1:0]    q_meta = { {(data_width_p-counter_width_p){1'b0}}, p3_beat_idx };

  logic                    emit_busy_r;
  logic [1:0]              emit_cnt_r;
  logic [rec_width_lp-1:0] emit_rec_r;
  wire  emit_hs  = err_axis_tvalid_o & err_axis_tready_i;
  wire  push_now = p3_valid & p3_has_err & ~emit_busy_r;
  assign err_axis_tvalid_o = emit_busy_r;
  assign err_axis_tdata_o  = emit_rec_r[emit_cnt_r*data_width_p +: data_width_p];
  assign err_axis_tlast_o  = (emit_cnt_r == 2'd2);

  always_ff @(posedge clk_i) begin
    if (reset_i | clear_i) begin
      rx_run_r            <= 1'b0;
      hist_r              <= '0;
      prime_r             <= 8'(prime_beats_lp);
      p1_valid            <= 1'b0;
      p2_valid            <= 1'b0;
      p3_valid            <= 1'b0;
      error_count_o       <= '0;
      sent_packet_count_o <= '0;
      recv_packet_count_o <= '0;
      emit_busy_r         <= 1'b0;
      emit_cnt_r          <= 2'd0;
    end else begin
      if (~prbs_enable_i) rx_run_r <= 1'b0;                    // abrupt RX stop; pipeline drains via valids

      if (enable_pulse) begin
        rx_run_r            <= 1'b1;
        hist_r              <= '0;
        prime_r             <= 8'(prime_beats_lp);             // settle: fill history + skip startup transient
        p1_valid            <= 1'b0;
        p2_valid            <= 1'b0;
        p3_valid            <= 1'b0;
        error_count_o       <= '0;
        recv_packet_count_o <= '0;
        sent_packet_count_o <= '0;
        emit_busy_r         <= 1'b0;
        emit_cnt_r          <= 2'd0;
      end else begin
        // frames sent (mirror of the TX FSM boundary)
        if (tx_run_r & tx_hs & tx_frame_last & (sent_packet_count_o != '1))
          sent_packet_count_o <= sent_packet_count_o + counter_width_p'(1);

        // history + settle advance every received beat
        if (rx_run_r & rx_hs) begin
          hist_r <= rx_tdata_i[data_width_p-1 -: prbs_width_lp];   // top 31 bits [255:225]
          if (prime_r != 8'd0) prime_r <= prime_r - 8'd1;
        end

        // ---- stage p1: register the violation vector + received beat (only once settled) ----
        p1_valid <= rx_check;
        if (rx_check) begin
          p1_err_vec  <= rx_err_vec;
          p1_rcv_data <= rx_tdata_i;
          p1_beat_idx <= recv_packet_count_o;
          if (recv_packet_count_o != '1) recv_packet_count_o <= recv_packet_count_o + counter_width_p'(1);
        end

        // ---- stage p2: grouped 16-bit OR ----
        p2_valid <= p1_valid;
        if (p1_valid) begin
          for (int g = 0; g < data_width_p/16; g++) p2_partial[g] <= |p1_err_vec[g*16 +: 16];
          p2_err_vec  <= p1_err_vec;
          p2_rcv_data <= p1_rcv_data;
          p2_beat_idx <= p1_beat_idx;
        end

        // ---- stage p3: 16 -> 1 reduce ----
        p3_valid <= p2_valid;
        if (p2_valid) begin
          p3_has_err  <= |p2_partial;
          p3_err_vec  <= p2_err_vec;
          p3_rcv_data <= p2_rcv_data;
          p3_beat_idx <= p2_beat_idx;
        end

        // ---- stage 3: count errored beats + capture a record ----
        if (p3_valid & p3_has_err & (error_count_o != '1))
          error_count_o <= error_count_o + counter_width_p'(1);

        // ---- error-record emitter: push each errored beat while the emitter is free ----
        if (push_now) begin
          emit_rec_r  <= {q_meta, p3_err_vec, p3_rcv_data};
          emit_busy_r <= 1'b1;
          emit_cnt_r  <= 2'd0;
        end else if (emit_busy_r & emit_hs) begin
          if (emit_cnt_r == 2'd2) emit_busy_r <= 1'b0;
          else                    emit_cnt_r  <= emit_cnt_r + 2'd1;
        end
      end
    end
  end

  // tie off genuinely-unused inputs to keep lint quiet (kept for interface compatibility)
  wire _unused = &{1'b0, cfg_len_mask_i, rx_tkeep_i, rx_tlast_i};

endmodule

`default_nettype wire
