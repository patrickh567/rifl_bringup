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
module clock_compensate(
    input logic init_clk,
    input logic tx_frame_clk,
    input logic rx_frame_clk,
    input logic rst,
    input logic clock_active,
    output logic compensate,
//status (init_clk domain): ppm sign resolved (locked) + the 2-bit sign type
    output logic comp_locked,
    output logic [1:0] comp_type,
//comp ready-gate (tx_frame_clk domain) + far-end re-arm input (= &rx_up, tx_frame_clk)
    output logic comp_ready,
    input  logic far_end_up
);
    localparam bit [1:0] UNKNOWN = 2'd0;
    localparam bit [1:0] YES = 2'd1;
    localparam bit [1:0] NO = 2'd2;
    localparam int CNT_WIDTH = 4;

    logic [CNT_WIDTH-1:0] tx_cnt_gray, rx_cnt_gray;
    logic [CNT_WIDTH-1:0] tx_cnt_gray_init_synced, rx_cnt_gray_init_synced;
    logic [CNT_WIDTH-1:0] tx_cnt_init_synced, rx_cnt_init_synced;
    logic [CNT_WIDTH-1:0] tx_cnt_init_syncedp1;
    logic [CNT_WIDTH-1:0] rx_cnt_init_syncedp1;

    logic [1:0] compensate_type;
    logic [CNT_WIDTH-1:0] cnt_difference;
    logic [CNT_WIDTH-1:0] cnt_difference_wire;
    logic cnt_diff_flag;
    logic [CNT_WIDTH-1:0] compensate_cnt_init;
    logic compensate_cnt_init_vld;
    logic compensate_cnt_init_vld_wire;
    logic compensate_cnt_init_rdy;
    logic [CNT_WIDTH-1:0] compensate_cnt_tx;
    logic compensate_cnt_tx_vld;
    logic [CNT_WIDTH-1:0] compensate_cnt;

//---- drift-based ppm-sign estimator (init_clk).  Measure the tx-rx phase-difference
//     SLEW over a FIXED window and decide only at the window END, with a threshold
//     set ABOVE the bounded phase wander.  Over a long window the real frequency
//     drift accumulates far past the wander, so the sign is unambiguous -- unlike
//     deciding on the first small excursion, which fires on start-up phase/wander
//     (that was the failure mode: it wrong-latched ~half the bring-ups). ----
    localparam int WIN_WIDTH = 23;                 // window = 2^23 init_clk (~84ms @100MHz).  Long enough
                                                   //   that even a few-ppm real offset slews >= DRIFT_T,
                                                   //   yet bounded so the shared-refclk links' tiny
                                                   //   residual never accumulates to threshold.
    localparam int DRIFT_T   = 32;                 // decide when |windowed slew| >= 32 counts (> wander;
                                                   //   a >=~4ppm link slews >=32 counts over an 84ms window)
    localparam int ACC_WIDTH = 16;                 // signed windowed-slew accumulator
    localparam int ARM_WIDTH = 24;                 // ready-gate timeout (~168ms) > one window, so real
                                                   //   links resolve before the no-ppm links time out
    logic [WIN_WIDTH-1:0]        win_cnt;           // window counter
    logic                        win_tick;         // 1-cycle pulse at each window boundary
    logic [CNT_WIDTH-1:0]        diff_last;         // previous phase difference
    logic signed [CNT_WIDTH-1:0] step_signed;      // per-cycle signed drift step (wrap-safe)
    logic signed [ACC_WIDTH-1:0] drift_acc;        // windowed integrated (unwrapped) slew
//---- comp ready-gate + far-end re-arm (init_clk) ----
    logic [ARM_WIDTH-1:0]  arm_timer;
    logic                  arm_expired;
    logic                  comp_ready_init;
    logic                  far_end_up_synced;

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

    sync_multi_bit #(
        .SIZE       (CNT_WIDTH)
    ) u_sync_comp_cnt(
        .rst      (rst),
    	.clk_in   (init_clk),
        .clk_out  (tx_frame_clk),
        .din      (compensate_cnt_init),
        .din_vld  (compensate_cnt_init_vld),
        .din_rdy  (compensate_cnt_init_rdy),
        .dout     (compensate_cnt_tx),
        .dout_vld (compensate_cnt_tx_vld),
        .dout_rdy (~(|compensate_cnt))
    );


    // Sign decision: evaluate the windowed slew only at the window boundary, so the
    // decision reflects real frequency drift (accumulated over the whole window),
    // not a transient wander excursion.  Re-arms to UNKNOWN on far-end reset.
    always_ff @(posedge init_clk or posedge rst) begin
        if (rst)
            compensate_type <= UNKNOWN;
        else if (~clock_active | ~far_end_up_synced)
            compensate_type <= UNKNOWN;
        else if (compensate_type == UNKNOWN && win_tick) begin
            if (drift_acc >= DRIFT_T)
                compensate_type <= YES;     // net slew up   over the window -> tx faster -> insert comp
            else if (drift_acc <= -DRIFT_T)
                compensate_type <= NO;       // net slew down over the window -> rx faster -> no insertion
            // else |slew| < threshold: no resolvable ppm this window -> stay UNKNOWN
        end
    end

    always_ff @(posedge init_clk or posedge rst) begin
        if (rst) begin
            cnt_difference <= {CNT_WIDTH{1'b0}};
            compensate_cnt_init <= {CNT_WIDTH{1'b0}};
            compensate_cnt_init_vld <= 1'b0;
        end
        else if (~clock_active | ~far_end_up_synced) begin
            cnt_difference <= {CNT_WIDTH{1'b0}};
            compensate_cnt_init <= {CNT_WIDTH{1'b0}};
            compensate_cnt_init_vld <= 1'b0;
        end
        else if (compensate_type == YES) begin
            if (compensate_cnt_init_rdy && compensate_cnt_init_vld_wire) begin
                cnt_difference <= cnt_difference_wire;
                compensate_cnt_init <= cnt_difference_wire - cnt_difference;
            end
            if (compensate_cnt_init_rdy)
                compensate_cnt_init_vld <= compensate_cnt_init_vld_wire;
        end
    end

    always_ff @(posedge tx_frame_clk or posedge rst) begin
        if (rst)
            compensate_cnt <= {CNT_WIDTH{1'b0}};
        else if (~clock_active)
            compensate_cnt <= {CNT_WIDTH{1'b0}};
        else if (~(|compensate_cnt)) begin
            if (compensate_cnt_tx_vld)
                compensate_cnt <= compensate_cnt_tx;
        end
        else
            compensate_cnt <= compensate_cnt - 1'b1;
    end

    always_ff @(posedge tx_frame_clk) begin
        compensate <= |compensate_cnt;
    end

    //sometimes cnt_difference_wire can be smaller than cnt_difference even if compensate type is yes
    //leading to a very high difference between cnt_difference_wire and cnt_difference
    //it doesn't reflect the real difference
    assign compensate_cnt_init_vld_wire = cnt_difference_wire != cnt_difference && (cnt_difference_wire-cnt_difference) < 3'd4;
    assign cnt_difference_wire = tx_cnt_init_synced - rx_cnt_init_synced;
    assign tx_cnt_init_syncedp1 = tx_cnt_init_synced + 1'b1;
    assign rx_cnt_init_syncedp1 = rx_cnt_init_synced + 1'b1;

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

//---- far-end link-up (CDC &rx_up into init_clk).  The whole drift measurement +
//     ready-gate is gated on this LEVEL: it runs only while the link is up (stable
//     recovered rx_frame_clk) and holds in reset otherwise, so the bring-up transient
//     never corrupts a window and a link-down re-measures cleanly on re-up. ----
    sync_signle_bit #(.SIZE(1), .N_STAGE(3)) u_sync_far_end_up (
        .clk_in (tx_frame_clk), .clk_out(init_clk), .rst(rst),
        .din    (far_end_up),   .dout   (far_end_up_synced));

//---- ready-gate: release payload once the sign is resolved, or after a timeout so
//     the shared-refclk links (whose counters never diverge -> sign stays UNKNOWN)
//     are not held forever; the timeout is qualified on the link being up. ----
    always_ff @(posedge init_clk or posedge rst) begin
        if (rst)                        arm_timer <= '0;
        else if (~clock_active | ~far_end_up_synced) arm_timer <= '0;
        else if (~arm_expired)          arm_timer <= arm_timer + 1'b1;
    end
    assign arm_expired     = &arm_timer;
    assign comp_ready_init = (compensate_type != UNKNOWN) | (arm_expired & far_end_up_synced);
    sync_signle_bit #(.SIZE(1), .N_STAGE(3)) u_sync_comp_ready (
        .clk_in (init_clk),       .clk_out(tx_frame_clk), .rst(rst),
        .din    (comp_ready_init),.dout   (comp_ready));

//status outputs (init_clk domain): comp_type is the ppm-sign FSM state; comp_locked
//is high once the sign has resolved out of UNKNOWN (it drops with compensate_type on
//rst/~clock_active, and later on the far-end re-arm).
    assign comp_type   = compensate_type;
    assign comp_locked = (compensate_type != UNKNOWN);

endmodule