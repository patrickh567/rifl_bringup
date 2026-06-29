##############################################################################
# clk_wiz_0 : MMCM clocking for rifl_subsystem (replaces the firmware_bd BD).
#
#   Input : single-ended 200 MHz, already on a global buffer (rifl_subsystem feeds
#           it from a raw IBUFDS + BUFG on the external differential refclk).
#   Output: clk_out1 = init_clk (100 MHz), clk_out2 = core_clk (250 MHz).
#   No reset input, no locked output (matches the former firmware_bd clk_wiz).
#
# Run from the repo root (sourced by vu47p_rifl_project.tcl):
#   source script/clk_wiz_0.tcl
##############################################################################

create_ip -name clk_wiz -vendor xilinx.com -library ip -version 6.0 -module_name clk_wiz_0

set_property -dict [list \
  CONFIG.PRIM_SOURCE                {Global_buffer} \
  CONFIG.PRIM_IN_FREQ               {200.000} \
  CONFIG.CLKOUT1_REQUESTED_OUT_FREQ {100.000} \
  CONFIG.CLKOUT2_USED               {true} \
  CONFIG.CLKOUT2_REQUESTED_OUT_FREQ {250.000} \
  CONFIG.NUM_OUT_CLKS               {2} \
  CONFIG.USE_LOCKED                 {false} \
  CONFIG.USE_RESET                  {false} \
] [get_ips clk_wiz_0]
