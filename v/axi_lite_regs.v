`timescale 1 ps / 1 ps
`default_nettype none

// -----------------------------------------------------------------------------
// axi_lite_regs
//
// AXI4-Lite slave with a parameterizable register map:
//   * NUM_REGS    read/write "control" registers (offsets 0 .. NUM_REGS-1),
//                 exposed on reg_o for use as control bits.
//   * NUM_STATUS  read-only "status" registers (offsets NUM_REGS ..
//                 NUM_REGS+NUM_STATUS-1), whose read data comes from status_i.
//
// Register i is at byte offset i*4 (32-bit word addressing).
//   * Writes to the control region honor WSTRB (per-byte).  Writes to the
//     status region (or out of range) are accepted with an OKAY response but
//     have no effect (read-only).
//   * Reads return the control value, the live status_i value, or 0 (out of
//     range).
//
// Single clock domain (aclk).  Standard AXI4-Lite (no bursts, no IDs).
// Set NUM_STATUS = 0 if no status registers are needed (status_i is then unused).
// -----------------------------------------------------------------------------
module axi_lite_regs #
(
    parameter integer NUM_REGS        = 16    // read/write control registers
  , parameter integer NUM_STATUS      = 0     // read-only status registers
  , parameter integer AXI_ADDR_WIDTH  = 32
  , localparam integer DATA_WIDTH     = 32
  , localparam integer STRB_WIDTH     = DATA_WIDTH/8
  , localparam integer ADDR_LSB       = 2                                  // 4 bytes/reg
  , localparam integer TOTAL_REGS     = NUM_REGS + NUM_STATUS
  , localparam integer REG_SEL_BITS   = (TOTAL_REGS  <= 1) ? 1 : $clog2(TOTAL_REGS)
  , localparam integer STATUS_W       = (NUM_STATUS  <  1) ? 1 : NUM_STATUS
  , localparam integer STATUS_SEL_BITS= (STATUS_W    <= 1) ? 1 : $clog2(STATUS_W)
)
(
    input  wire                       aclk
  , input  wire                       aresetn

  // ---- AXI4-Lite slave : write address ----
  , input  wire [AXI_ADDR_WIDTH-1:0]  s_axi_awaddr
  , input  wire [2:0]                 s_axi_awprot
  , input  wire                       s_axi_awvalid
  , output wire                       s_axi_awready
  // ---- write data ----
  , input  wire [DATA_WIDTH-1:0]      s_axi_wdata
  , input  wire [STRB_WIDTH-1:0]      s_axi_wstrb
  , input  wire                       s_axi_wvalid
  , output wire                       s_axi_wready
  // ---- write response ----
  , output wire [1:0]                 s_axi_bresp
  , output wire                       s_axi_bvalid
  , input  wire                       s_axi_bready

  // ---- AXI4-Lite slave : read address ----
  , input  wire [AXI_ADDR_WIDTH-1:0]  s_axi_araddr
  , input  wire [2:0]                 s_axi_arprot
  , input  wire                       s_axi_arvalid
  , output wire                       s_axi_arready
  // ---- read data ----
  , output wire [DATA_WIDTH-1:0]      s_axi_rdata
  , output wire [1:0]                 s_axi_rresp
  , output wire                       s_axi_rvalid
  , input  wire                       s_axi_rready

  // ---- read/write control registers (outputs) ----
  , output wire [NUM_REGS-1:0][DATA_WIDTH-1:0] reg_o
  // ---- read-only status registers (inputs); unused when NUM_STATUS == 0 ----
  , input  wire [STATUS_W-1:0][DATA_WIDTH-1:0] status_i
);

  logic [NUM_REGS-1:0][DATA_WIDTH-1:0] regs;

  logic                      awready_q, wready_q, bvalid_q, aw_en;
  logic                      arready_q, rvalid_q;
  logic [DATA_WIDTH-1:0]     rdata_q;
  logic [AXI_ADDR_WIDTH-1:0] awaddr_q, araddr_q;

  assign s_axi_awready = awready_q;
  assign s_axi_wready  = wready_q;
  assign s_axi_bvalid  = bvalid_q;
  assign s_axi_bresp   = 2'b00;            // OKAY
  assign s_axi_arready = arready_q;
  assign s_axi_rvalid  = rvalid_q;
  assign s_axi_rdata   = rdata_q;
  assign s_axi_rresp   = 2'b00;            // OKAY
  assign reg_o         = regs;

  wire [REG_SEL_BITS-1:0] wr_index = awaddr_q[ADDR_LSB +: REG_SEL_BITS];
  wire [REG_SEL_BITS-1:0] rd_index = araddr_q[ADDR_LSB +: REG_SEL_BITS];
  wire                    wr_fire  = awready_q & s_axi_awvalid & wready_q & s_axi_wvalid;

  // status read select (only meaningful for rd_index in the status range)
  wire [STATUS_SEL_BITS-1:0] status_sel = rd_index - NUM_REGS;

  // combinational read data: control reg, status input, or zero
  logic [DATA_WIDTH-1:0] rd_data_c;
  always_comb begin
    if (rd_index < NUM_REGS)
      rd_data_c = regs[rd_index];
    else if (rd_index < TOTAL_REGS)
      rd_data_c = status_i[status_sel];
    else
      rd_data_c = '0;
  end

  // ---- write address handshake (one outstanding write, gated by aw_en) ----
  always_ff @(posedge aclk) begin
    if (~aresetn) begin
      awready_q <= 1'b0;
      aw_en     <= 1'b1;
      awaddr_q  <= '0;
    end else if (~awready_q && s_axi_awvalid && s_axi_wvalid && aw_en) begin
      awready_q <= 1'b1;
      aw_en     <= 1'b0;
      awaddr_q  <= s_axi_awaddr;
    end else if (s_axi_bready && bvalid_q) begin
      awready_q <= 1'b0;
      aw_en     <= 1'b1;
    end else begin
      awready_q <= 1'b0;
    end
  end

  // ---- write data handshake ----
  always_ff @(posedge aclk) begin
    if (~aresetn)
      wready_q <= 1'b0;
    else if (~wready_q && s_axi_wvalid && s_axi_awvalid && aw_en)
      wready_q <= 1'b1;
    else
      wready_q <= 1'b0;
  end

  // ---- control-register write (byte strobes); status region is read-only ----
  always_ff @(posedge aclk) begin
    if (~aresetn) begin
      regs <= '0;
    end else if (wr_fire && (wr_index < NUM_REGS)) begin
      for (int bi = 0; bi < STRB_WIDTH; bi++)
        if (s_axi_wstrb[bi])
          regs[wr_index][bi*8 +: 8] <= s_axi_wdata[bi*8 +: 8];
    end
  end

  // ---- write response ----
  always_ff @(posedge aclk) begin
    if (~aresetn)
      bvalid_q <= 1'b0;
    else if (awready_q && s_axi_awvalid && ~bvalid_q && wready_q && s_axi_wvalid)
      bvalid_q <= 1'b1;
    else if (s_axi_bready && bvalid_q)
      bvalid_q <= 1'b0;
  end

  // ---- read address handshake ----
  always_ff @(posedge aclk) begin
    if (~aresetn) begin
      arready_q <= 1'b0;
      araddr_q  <= '0;
    end else if (~arready_q && s_axi_arvalid) begin
      arready_q <= 1'b1;
      araddr_q  <= s_axi_araddr;
    end else begin
      arready_q <= 1'b0;
    end
  end

  // ---- read data ----
  always_ff @(posedge aclk) begin
    if (~aresetn) begin
      rvalid_q <= 1'b0;
      rdata_q  <= '0;
    end else if (arready_q && s_axi_arvalid && ~rvalid_q) begin
      rvalid_q <= 1'b1;
      rdata_q  <= rd_data_c;
    end else if (rvalid_q && s_axi_rready) begin
      rvalid_q <= 1'b0;
    end
  end

endmodule

`default_nettype wire
