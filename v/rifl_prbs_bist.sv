`timescale 1 ps / 1 ps
`default_nettype none

// -----------------------------------------------------------------------------
// rifl_prbs_bist : per-link PRBS packet generator + self-checking receiver.
//
// When enabled, the transmit side emits back-to-back packets of pseudo-random
// data (maximal-length PRBS-31, 256 bits/beat), of random length, with a random
// number of valid bytes in the last beat (its tkeep).  The receive side
// regenerates the identical expected stream (same seed) and compares data,
// packet length, and tkeep for every beat; a packet that mismatches anywhere is
// counted and (if the error buffer has room) a compact record of the first
// divergence is emitted as three 256-bit beats for software to read.
//
// Timing (this is the ~390 MHz link clock, 2.56 ns):
//   * Packet length is min + (lfsr & mask) -- a software-supplied power-of-two
//     mask -- so the length path is an AND + add (no range/mask arithmetic).
//   * The checker's compare is PIPELINED: the lightweight expected model (PRBS +
//     length counters) runs single-cycle; the heavy path (256-bit XOR/mask ->
//     grouped OR -> 16->1 reduce -> flag/record/count) is split across three
//     pipeline registers, so error logging lands a few cycles later (identical).
//   * The generator's combinational data output is registered by a skid buffer in
//     the subsystem before it reaches the link.
//
// Disable is graceful: the generator finishes the current packet (its TLAST)
// before releasing the link, so no partial frame is left on the wire.
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
  ,input  wire [packet_len_width_p-1:0] cfg_len_mask_i       // length randomness mask (2^k-1)
  ,input  wire [packet_len_width_p-1:0] cfg_pkt_len_min_i    // min length (beats); len = min + (lfsr & mask)
  ,input  wire [31:0]                   cfg_seed_i           // PRBS + length seed
  ,input  wire                          seed_perturb_i       // perturb the CHECKER seed (forced-error test)

  // ---- TX AXIS toward the RIFL link (mux-selected in the subsystem) ----
  ,output logic [data_width_p-1:0]      tx_tdata_o
  ,output logic [keep_width_lp-1:0]     tx_tkeep_o
  ,output logic                         tx_tlast_o
  ,output logic                         tx_tvalid_o
  ,input  wire                          tx_tready_i
  ,output wire                          tx_active_o          // running or draining (TX mux select)

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
  // Returns {next_state[30:0], data[255:0]}.  Shallow XOR matrix (~2 LUT levels).
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
  // Length + tkeep helpers.  Length LFSR: 16-bit Fibonacci, one step per packet.
  // Length itself is just min + (lfsr & mask) -- a power-of-two range.
  // ---------------------------------------------------------------------------
  function automatic [15:0] lfsr_seed(input [31:0] seed_i);
    logic [15:0] s;
    begin s = seed_i[15:0] ^ seed_i[31:16] ^ 16'hace1; lfsr_seed = (s == 16'h0) ? 16'h1 : s; end
  endfunction
  function automatic [15:0] lfsr16_next(input [15:0] state_i);
    // x^16 + x^14 + x^13 + x^11 + 1
    lfsr16_next = {state_i[14:0], state_i[15] ^ state_i[13] ^ state_i[12] ^ state_i[10]};
  endfunction
  function automatic [packet_len_width_p-1:0] len_gen
    (input [packet_len_width_p-1:0] min_i, input [packet_len_width_p-1:0] mask_i, input [15:0] rand_i);
    len_gen = min_i + (packet_len_width_p'(rand_i) & mask_i);
  endfunction
  // random valid-byte count for the last beat: 1..keep_width from LFSR high bits.
  // Keep is MSB-aligned (top nbytes lanes valid, lane 0 empty) to match RIFL's
  // partial-beat convention -- RIFL reserves lane 0 of the frame for the length
  // code, so a right-justified (standard-AXI, low-lanes-valid) keep would leave
  // lane 0 valid, RIFL would treat every partial beat as full, drop the length,
  // and the RX width converter would desync.  See commit message.
  function automatic [keep_width_lp-1:0] tkeep_from_lfsr(input [15:0] rand_i);
    int nbytes; logic [keep_width_lp-1:0] m;
    begin
      nbytes = (rand_i[15:11] % keep_width_lp) + 1;   // 1..32
      m = '0;
      for (int b = 0; b < keep_width_lp; b++) m[b] = (b >= keep_width_lp - nbytes);
      tkeep_from_lfsr = m;
    end
  endfunction
  // byte-replicate a tkeep mask to data width for a masked data compare
  function automatic [data_width_p-1:0] keep_to_bits(input [keep_width_lp-1:0] k_i);
    logic [data_width_p-1:0] b;
    begin for (int j = 0; j < keep_width_lp; j++) b[j*8 +: 8] = {8{k_i[j]}}; keep_to_bits = b; end
  endfunction

  // ---------------------------------------------------------------------------
  // Registered (quasi-static) config: min length and length mask.  Registering
  // them keeps the config -> length arithmetic off the timed length path.
  // ---------------------------------------------------------------------------
  logic enable_r;
  wire  enable_pulse = prbs_enable_i & ~enable_r;
  logic [packet_len_width_p-1:0] cfg_min_r, cfg_mask_r;

  always_ff @(posedge clk_i) begin
    if (reset_i) begin
      enable_r   <= 1'b0;
      cfg_min_r  <= packet_len_width_p'(1);
      cfg_mask_r <= '0;
    end else begin
      enable_r   <= prbs_enable_i;
      cfg_min_r  <= (cfg_pkt_len_min_i == '0) ? packet_len_width_p'(1) : cfg_pkt_len_min_i;
      cfg_mask_r <= cfg_len_mask_i;
    end
  end

  // ---------------------------------------------------------------------------
  // TX generator.
  // ---------------------------------------------------------------------------
  logic [prbs_width_lp-1:0]      tx_prbs_r;
  logic [15:0]                   tx_lfsr_r;          // length LFSR state for the CURRENT packet
  logic [packet_len_width_p-1:0] tx_cur_len_r;
  logic [keep_width_lp-1:0]      tx_cur_keep_r;
  logic [packet_len_width_p-1:0] tx_flit_idx_r;
  logic                          tx_run_r;

  assign tx_active_o = tx_run_r;                     // running or draining the final packet

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
      logic [15:0] lseed;
      lseed          = lfsr_seed(cfg_seed_i);
      tx_run_r       <= 1'b1;
      tx_prbs_r      <= prbs_seed(cfg_seed_i, 1'b0);   // TX always sends the canonical sequence
      tx_lfsr_r      <= lseed;
      tx_cur_len_r   <= len_gen(cfg_min_r, cfg_mask_r, lseed);
      tx_cur_keep_r  <= tkeep_from_lfsr(lseed);
      tx_flit_idx_r  <= '0;
    end else if (tx_run_r & tx_hs) begin
      tx_prbs_r <= tx_prbs_next;                       // advance data PRBS per beat
      if (tx_last) begin
        // Packet boundary.  On a pending disable, stop HERE (graceful); otherwise
        // roll to the next packet (advance the length LFSR).
        if (~prbs_enable_i) begin
          tx_run_r <= 1'b0;
        end else begin
          logic [15:0] ln;
          ln            = lfsr16_next(tx_lfsr_r);
          tx_flit_idx_r <= '0;
          tx_lfsr_r     <= ln;
          tx_cur_len_r  <= len_gen(cfg_min_r, cfg_mask_r, ln);
          tx_cur_keep_r <= tkeep_from_lfsr(ln);
        end
      end else begin
        tx_flit_idx_r <= tx_flit_idx_r + packet_len_width_p'(1);
      end
    end
  end

  // ---------------------------------------------------------------------------
  // RX expected model (single-cycle): regenerate the expected data/length/tkeep,
  // advancing the PRBS per received beat and the length LFSR per received packet.
  // ---------------------------------------------------------------------------
  logic [prbs_width_lp-1:0]      rx_prbs_r;
  logic [15:0]                   rx_lfsr_r;
  logic [packet_len_width_p-1:0] rx_cur_len_r;
  logic [keep_width_lp-1:0]      rx_cur_keep_r;
  logic [packet_len_width_p-1:0] rx_flit_idx_r;
  logic [counter_width_p-1:0]    rx_pkt_idx_r;
  logic                          rx_run_r;

  assign rx_tready_o = rx_run_r;

  wire [prbs_width_lp-1:0] rx_prbs_next;
  wire [data_width_p-1:0]  rx_exp_data;
  assign {rx_prbs_next, rx_exp_data} = prbs_step(rx_prbs_r);

  wire rx_hs       = rx_tvalid_i & rx_tready_o;
  wire rx_exp_last = (rx_flit_idx_r == (rx_cur_len_r - packet_len_width_p'(1)));
  wire [keep_width_lp-1:0] rx_exp_keep = rx_exp_last ? rx_cur_keep_r : '1;

  // ---------------------------------------------------------------------------
  // Compare pipeline (kept shallow for the ~390 MHz clock).
  //   p1 : model output registered (expected + received + metadata).
  //   p2 : masked XOR -> grouped 16-bit OR + length/tkeep mismatch flags.
  //   p3 : 16->1 reduce to a single data-mismatch bit + forward.
  //   stage 3 : flag, per-packet accumulate, count + record.
  // ---------------------------------------------------------------------------
  logic                       p1_valid;
  logic [data_width_p-1:0]    p1_exp_data, p1_rcv_data;
  logic [keep_width_lp-1:0]   p1_exp_keep, p1_rcv_keep;
  logic                       p1_exp_last, p1_rcv_last;
  logic [counter_width_p-1:0] p1_pkt_idx;
  logic [31:0]                p1_flit_idx;

  logic                       p2_valid;
  logic [data_width_p/16-1:0] p2_partial;   // grouped-OR of the masked XOR (16 bits/group)
  logic [data_width_p-1:0]    p2_exp_data, p2_rcv_data;
  logic [keep_width_lp-1:0]   p2_exp_keep, p2_rcv_keep;
  logic                       p2_exp_last, p2_rcv_last, p2_last_mm, p2_tkeep_mm;
  logic [counter_width_p-1:0] p2_pkt_idx;
  logic [31:0]                p2_flit_idx;

  logic                       p3_valid, p3_data_mm, p3_last_mm, p3_tkeep_mm;
  logic [data_width_p-1:0]    p3_exp_data, p3_rcv_data;
  logic [keep_width_lp-1:0]   p3_exp_keep, p3_rcv_keep;
  logic                       p3_exp_last, p3_rcv_last;
  logic [counter_width_p-1:0] p3_pkt_idx;
  logic [31:0]                p3_flit_idx;

  // masked byte-wise difference (registered as a grouped-OR into p2, then reduced
  // in stage 2 -- keeps both stages shallow instead of one deep 256->1 reduce).
  wire [data_width_p-1:0] p1_masked = (p1_exp_data ^ p1_rcv_data) & keep_to_bits(p1_exp_keep);

  // stage-3 decode of p3 (the 16->1 reduce is registered into p3_data_mm)
  wire        s3_flit_err = p3_valid & (p3_data_mm | p3_last_mm | p3_tkeep_mm);
  wire [7:0]  s3_flags    = {p3_exp_last, p3_rcv_last, 2'b00, p3_tkeep_mm, p3_last_mm, p3_data_mm, 1'b0};

  logic                       pkt_err_r;             // this packet mismatched somewhere (stage 2)
  logic [counter_width_p-1:0] rec_pkt_idx_r;
  logic [31:0]                rec_flit_idx_r;
  logic [data_width_p-1:0]    rec_exp_data_r, rec_rcv_data_r;
  logic [keep_width_lp-1:0]   rec_exp_keep_r, rec_rcv_keep_r;
  logic [7:0]                 rec_flags_r;

  // record content: latched first-divergence fields, or -- when the first error
  // is on this very (last) beat -- the current stage-3 beat's fields.
  wire                       pkt_err_now = pkt_err_r | s3_flit_err;
  wire [counter_width_p-1:0] q_pkt_idx   = pkt_err_r ? rec_pkt_idx_r  : p3_pkt_idx;
  wire [31:0]                q_flit_idx  = pkt_err_r ? rec_flit_idx_r : p3_flit_idx;
  wire [data_width_p-1:0]    q_exp_data  = pkt_err_r ? rec_exp_data_r : p3_exp_data;
  wire [data_width_p-1:0]    q_rcv_data  = pkt_err_r ? rec_rcv_data_r : p3_rcv_data;
  wire [keep_width_lp-1:0]   q_exp_keep  = pkt_err_r ? rec_exp_keep_r : p3_exp_keep;
  wire [keep_width_lp-1:0]   q_rcv_keep  = pkt_err_r ? rec_rcv_keep_r : p3_rcv_keep;
  wire [7:0]                 q_flags     = pkt_err_r ? rec_flags_r    : s3_flags;
  wire [data_width_p-1:0]    q_beat2 =
       { {(data_width_p-136){1'b0}}, q_flags, q_rcv_keep, q_exp_keep, q_flit_idx, q_pkt_idx };

  // ---- error-record emit FSM: 3 x 256-bit beats ----
  logic                    emit_busy_r;
  logic [1:0]              emit_cnt_r;
  logic [rec_width_lp-1:0] emit_rec_r;
  wire  emit_hs = err_axis_tvalid_o & err_axis_tready_i;
  assign err_axis_tvalid_o = emit_busy_r;
  assign err_axis_tdata_o  = emit_rec_r[emit_cnt_r*data_width_p +: data_width_p];
  assign err_axis_tlast_o  = (emit_cnt_r == 2'd2);

  // push a record on the (stage-3) packet boundary if it mismatched and the emitter is free
  wire push_now = p3_valid & p3_rcv_last & pkt_err_now & ~emit_busy_r;

  always_ff @(posedge clk_i) begin
    if (reset_i | clear_i) begin
      rx_run_r            <= 1'b0;
      rx_prbs_r           <= prbs_width_lp'(1);
      rx_lfsr_r           <= 16'h1;
      rx_cur_len_r        <= packet_len_width_p'(1);
      rx_cur_keep_r       <= '1;
      rx_flit_idx_r       <= '0;
      rx_pkt_idx_r        <= '0;
      p1_valid            <= 1'b0;
      p2_valid            <= 1'b0;
      p3_valid            <= 1'b0;
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
        logic [15:0] lseed;
        lseed               = lfsr_seed(cfg_seed_i);
        rx_run_r            <= 1'b1;
        rx_prbs_r           <= prbs_seed(cfg_seed_i, seed_perturb_i);  // perturb -> forced errors
        rx_lfsr_r           <= lseed;
        rx_cur_len_r        <= len_gen(cfg_min_r, cfg_mask_r, lseed);
        rx_cur_keep_r       <= tkeep_from_lfsr(lseed);
        rx_flit_idx_r       <= '0;
        rx_pkt_idx_r        <= '0;
        p1_valid            <= 1'b0;
        p2_valid            <= 1'b0;
        p3_valid            <= 1'b0;
        pkt_err_r           <= 1'b0;
        error_count_o       <= '0;
        recv_packet_count_o <= '0;
        sent_packet_count_o <= '0;
        emit_busy_r         <= 1'b0;
        emit_cnt_r          <= 2'd0;
      end else begin
        if (~prbs_enable_i) rx_run_r <= 1'b0;           // abrupt RX stop; pipeline drains via valids

        // ---- expected model: advance per received beat/packet ----
        if (rx_run_r & rx_hs) begin
          rx_prbs_r <= rx_prbs_next;
          if (rx_tlast_i) begin
            logic [15:0] ln;
            ln            = lfsr16_next(rx_lfsr_r);
            rx_flit_idx_r <= '0;
            rx_pkt_idx_r  <= rx_pkt_idx_r + counter_width_p'(1);
            rx_lfsr_r     <= ln;
            rx_cur_len_r  <= len_gen(cfg_min_r, cfg_mask_r, ln);
            rx_cur_keep_r <= tkeep_from_lfsr(ln);
          end else begin
            rx_flit_idx_r <= rx_flit_idx_r + packet_len_width_p'(1);
          end
        end

        // ---- pipeline stage p1: register model output + received beat ----
        p1_valid <= rx_run_r & rx_hs;
        if (rx_run_r & rx_hs) begin
          p1_exp_data <= rx_exp_data;   p1_rcv_data <= rx_tdata_i;
          p1_exp_keep <= rx_exp_keep;   p1_rcv_keep <= rx_tkeep_i;
          p1_exp_last <= rx_exp_last;   p1_rcv_last <= rx_tlast_i;
          p1_pkt_idx  <= rx_pkt_idx_r;  p1_flit_idx <= 32'(rx_flit_idx_r);
        end

        // ---- pipeline stage p2: masked XOR -> grouped 16-bit OR + mismatch flags ----
        p2_valid <= p1_valid;
        if (p1_valid) begin
          for (int g = 0; g < data_width_p/16; g++) p2_partial[g] <= |p1_masked[g*16 +: 16];
          p2_last_mm  <= (p1_rcv_last != p1_exp_last);
          p2_tkeep_mm <= (p1_rcv_keep != p1_exp_keep);
          p2_exp_data <= p1_exp_data;   p2_rcv_data <= p1_rcv_data;
          p2_exp_keep <= p1_exp_keep;   p2_rcv_keep <= p1_rcv_keep;
          p2_exp_last <= p1_exp_last;   p2_rcv_last <= p1_rcv_last;
          p2_pkt_idx  <= p1_pkt_idx;    p2_flit_idx <= p1_flit_idx;
        end

        // ---- pipeline stage p3: 16->1 reduce to a single data-mismatch bit ----
        p3_valid <= p2_valid;
        if (p2_valid) begin
          p3_data_mm  <= |p2_partial;
          p3_last_mm  <= p2_last_mm;     p3_tkeep_mm <= p2_tkeep_mm;
          p3_exp_data <= p2_exp_data;    p3_rcv_data <= p2_rcv_data;
          p3_exp_keep <= p2_exp_keep;    p3_rcv_keep <= p2_rcv_keep;
          p3_exp_last <= p2_exp_last;    p3_rcv_last <= p2_rcv_last;
          p3_pkt_idx  <= p2_pkt_idx;     p3_flit_idx <= p2_flit_idx;
        end

        // ---- stage 3: flag, accumulate, count + record ----
        if (p3_valid) begin
          if (s3_flit_err & ~pkt_err_r) begin           // latch the first divergence
            rec_pkt_idx_r  <= p3_pkt_idx;  rec_flit_idx_r <= p3_flit_idx;
            rec_exp_data_r <= p3_exp_data; rec_rcv_data_r <= p3_rcv_data;
            rec_exp_keep_r <= p3_exp_keep; rec_rcv_keep_r <= p3_rcv_keep;
            rec_flags_r    <= s3_flags;
            pkt_err_r      <= 1'b1;
          end
          if (p3_rcv_last) begin                         // packet boundary in stage 3
            if (pkt_err_now & (error_count_o != '1)) error_count_o <= error_count_o + counter_width_p'(1);
            if (recv_packet_count_o != '1)            recv_packet_count_o <= recv_packet_count_o + counter_width_p'(1);
            pkt_err_r <= 1'b0;
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
  end

endmodule

`default_nettype wire
