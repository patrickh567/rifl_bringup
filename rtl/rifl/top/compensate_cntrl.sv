//MIT License
//
//Author: Qianfeng (Clark) Shen;Contact: qianfeng.shen@gmail.com
//
//Copyright (c) 2021 swift-link
//
//Permission is hereby granted, free of charge, to any person obtaining a copy of this software and associated documentation files (the "Software"), to deal in the Software without restriction, including without limitation the rights to use, copy, modify, merge, publish, distribute, sublicense, and/or sell copies of the Software, and to permit persons to whom the Software is furnished to do so, subject to the following conditions:
//
//The above copyright notice and this permission notice shall be included in all copies or substantial portions of the Software.
//
//THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.
//
`timescale 1ns / 1ps
//---------------------------------------------------------------------------------------
// Clock compensation: FIXED-RATE idle insertion (the standard-protocol scheme, cf. PCIe
// SKP / Aurora CC / Interlaken skip): unconditionally request one idle-frame insertion
// every 2^COMP_PERIOD_LOG2 frames, on every link, from the moment the tx clock is
// active.  1/1024 reserves ~0.1% bandwidth = ~977ppm of compensation capacity, ~10x any
// plausible refclk-pair mismatch, so the far end's un-flow-controlled RX elastic buffer
// can never accumulate a backlog -- no measurement, no sign decision, no unprotected
// startup window.  The receiver discards idle frames before its elastic buffer, so
// over-insertion is harmless (benign read-side gaps).
//
// The previous MEASURED compensation (decide a ppm sign from phase drift, then insert
// at the measured rate) is retained below as TELEMETRY ONLY: comp_type/comp_locked
// report the measured drift direction for health monitoring (confirming the real
// mismatch stays far inside the fixed insertion budget).  It steers nothing.
//---------------------------------------------------------------------------------------
module clock_compensate(
    input logic init_clk,
    input logic tx_frame_clk,
    input logic rx_frame_clk,
    input logic rst,
    input logic clock_active,
    output logic compensate,
//status / telemetry (init_clk domain): measured ppm-sign resolved (locked) + 2-bit sign
    output logic comp_locked,
    output logic [1:0] comp_type,
//far-end link-up (= &rx_up, tx_frame_clk): gates the telemetry drift window so it only
//measures while the recovered rx_frame_clk is stable, and re-measures after a link drop
    input  logic far_end_up
);
    localparam bit [1:0] UNKNOWN = 2'd0;
    localparam bit [1:0] YES = 2'd1;
    localparam bit [1:0] NO = 2'd2;
    localparam int CNT_WIDTH = 4;

//---- fixed-rate insertion (tx_frame_clk) ----
    localparam int COMP_PERIOD_LOG2 = 10;          // one idle per 2^10 = 1024 frames (~0.1% BW,
                                                   //   ~977ppm capacity vs <=~100ppm worst-case
                                                   //   refclk mismatch -> ~10x margin)
    logic [COMP_PERIOD_LOG2-1:0] comp_period_cnt;

    logic [CNT_WIDTH-1:0] tx_cnt_gray, rx_cnt_gray;
    logic [CNT_WIDTH-1:0] tx_cnt_gray_init_synced, rx_cnt_gray_init_synced;
    logic [CNT_WIDTH-1:0] tx_cnt_init_synced, rx_cnt_init_synced;

    logic [1:0] compensate_type;
    logic [CNT_WIDTH-1:0] cnt_difference_wire;

//---- drift-based ppm-sign estimator (init_clk, TELEMETRY ONLY).  Measure the tx-rx
//     phase-difference SLEW over a FIXED window and decide only at the window END,
//     with a threshold set ABOVE the bounded phase wander.  Reports the true drift
//     direction for links with >= a few ppm of real mismatch; the shared-refclk links
//     legitimately stay UNKNOWN.  Nothing in the datapath consumes this. ----
    localparam int WIN_WIDTH = 23;                 // window = 2^23 init_clk (~84ms @100MHz)
    localparam int DRIFT_T   = 32;                 // decide when |windowed slew| >= 32 counts
    localparam int ACC_WIDTH = 16;                 // signed windowed-slew accumulator
    logic [WIN_WIDTH-1:0]        win_cnt;          // window counter
    logic                        win_tick;         // 1-cycle pulse at each window boundary
    logic [CNT_WIDTH-1:0]        diff_last;        // previous phase difference
    logic signed [CNT_WIDTH-1:0] step_signed;      // per-cycle signed drift step (wrap-safe)
    logic signed [ACC_WIDTH-1:0] drift_acc;        // windowed integrated (unwrapped) slew
    logic                        far_end_up_synced;

//---- fixed-rate insertion counter: free-running; request one idle-frame substitution
//     at each rollover.  Registered output, active whenever the tx clock is active --
//     including the entire bring-up, so there is no unprotected startup window. ----
    always_ff @(posedge tx_frame_clk or posedge rst) begin
        if (rst) begin
            comp_period_cnt <= '0;
            compensate      <= 1'b0;
        end
        else if (~clock_active) begin
            comp_period_cnt <= '0;
            compensate      <= 1'b0;
        end
        else begin
            comp_period_cnt <= comp_period_cnt + 1'b1;
            compensate      <= (comp_period_cnt == {COMP_PERIOD_LOG2{1'b1}});
        end
    end

//gray code counters
    graycntr #(
        .SIZE (CNT_WIDTH)
    ) tx_cntr(
        .rst  (~clock_active),
        .clk  (tx_frame_clk),
        .inc  (1'b1),
        .gray (tx_cnt_gray)
    );
    graycntr #(
        .SIZE (CNT_WIDTH)
    ) rx_cntr(
        .rst  (~clock_active),
        .clk  (rx_frame_clk),
        .inc  (1'b1),
        .gray (rx_cnt_gray)
    );
//cdc
    sync_signle_bit #(
        .SIZE      (CNT_WIDTH),
        .N_STAGE   (5)
    ) sync_tx_cntr(
    	.clk_in  (tx_frame_clk),
        .clk_out (init_clk),
        .rst     (rst),
        .din     (tx_cnt_gray),
        .dout    (tx_cnt_gray_init_synced)
    );
    sync_signle_bit #(
        .SIZE      (CNT_WIDTH),
        .N_STAGE   (5)
    ) sync_rx_cntr(
    	.clk_in  (rx_frame_clk),
        .clk_out (init_clk),
        .rst     (rst),
        .din     (rx_cnt_gray),
        .dout    (rx_cnt_gray_init_synced)
    );
//gray to bin
    gray2bin #(
        .SIZE (CNT_WIDTH)
    ) u_gray2bin_tx(
    	.gray (tx_cnt_gray_init_synced),
        .bin  (tx_cnt_init_synced)
    );
    gray2bin #(
        .SIZE (CNT_WIDTH)
    ) u_gray2bin_rx(
    	.gray (rx_cnt_gray_init_synced),
        .bin  (rx_cnt_init_synced)
    );

    assign cnt_difference_wire = tx_cnt_init_synced - rx_cnt_init_synced;

    // Sign decision (telemetry): evaluate the windowed slew only at the window
    // boundary, so the reading reflects real frequency drift accumulated over the
    // whole window, not a transient wander excursion.  Re-arms to UNKNOWN on far-end
    // link-down so a reconnect re-measures cleanly.
    always_ff @(posedge init_clk or posedge rst) begin
        if (rst)
            compensate_type <= UNKNOWN;
        else if (~clock_active | ~far_end_up_synced)
            compensate_type <= UNKNOWN;
        else if (compensate_type == UNKNOWN && win_tick) begin
            if (drift_acc >= DRIFT_T)
                compensate_type <= YES;     // net slew up   over the window -> tx faster than rx
            else if (drift_acc <= -DRIFT_T)
                compensate_type <= NO;       // net slew down over the window -> rx faster than tx
            // else |slew| < threshold: no resolvable ppm this window -> stay UNKNOWN
        end
    end

//---- windowed drift accumulator: sum the per-cycle signed phase-difference step
//     over a fixed window (telescopes to the unwrapped total slew), restarting the
//     sum at each window boundary.  step = signed(diff_now - diff_last) is wrap-safe
//     (|step|<8).  The window counter free-runs; win_tick marks the boundary where
//     the sign FSM samples the completed window's slew. ----
    assign step_signed = $signed(cnt_difference_wire - diff_last);
    assign win_tick    = (win_cnt == {WIN_WIDTH{1'b1}});
    always_ff @(posedge init_clk or posedge rst) begin
        if (rst)
            win_cnt <= '0;
        else if (~clock_active | ~far_end_up_synced)
            win_cnt <= '0;
        else
            win_cnt <= win_cnt + 1'b1;
    end
    always_ff @(posedge init_clk or posedge rst) begin
        if (rst) begin
            diff_last <= {CNT_WIDTH{1'b0}};
            drift_acc <= '0;
        end
        else if (~clock_active | ~far_end_up_synced) begin
            diff_last <= cnt_difference_wire;      // new baseline; no step accumulated this edge
            drift_acc <= '0;
        end
        else begin
            diff_last <= cnt_difference_wire;
            if (win_tick)
                drift_acc <= step_signed;          // window boundary: restart the sum from this step
            else
                drift_acc <= drift_acc + step_signed;
        end
    end

//---- far-end link-up (CDC &rx_up into init_clk).  The telemetry measurement is gated
//     on this LEVEL: it runs only while the link is up (stable recovered rx_frame_clk)
//     and holds in reset otherwise, so the bring-up transient never corrupts a window
//     and a link-down re-measures cleanly on re-up. ----
    sync_signle_bit #(.SIZE(1), .N_STAGE(3)) u_sync_far_end_up (
        .clk_in (tx_frame_clk), .clk_out(init_clk), .rst(rst),
        .din    (far_end_up),   .dout   (far_end_up_synced));

//status outputs (init_clk domain): comp_type is the measured ppm-sign FSM state;
//comp_locked is high once the sign has resolved out of UNKNOWN (drops on rst /
//~clock_active / far-end link-down).
    assign comp_type   = compensate_type;
    assign comp_locked = (compensate_type != UNKNOWN);

endmodule
