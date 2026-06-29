

# LEDs
set_property PACKAGE_PIN BP46 [get_ports {led[0]}]
set_property PACKAGE_PIN BN46 [get_ports {led[1]}]
#set_property PACKAGE_PIN BP44 [get_ports {led[2]}]
#set_property PACKAGE_PIN BP43 [get_ports {led[3]}]
set_property IOSTANDARD LVCMOS18 [get_ports {led[*]}]

# Reset
set_property PACKAGE_PIN BG43 [get_ports {rstn}]
set_property IOSTANDARD LVCMOS18 [get_ports {rstn}]
set_property PULLTYPE PULLUP [get_ports {rstn}]



# Bitstream
set_property BITSTREAM.GENERAL.COMPRESS        True  [current_design]



# External refclk
set_property PACKAGE_PIN   BH45     [get_ports {ext_refclk_n}]
set_property PACKAGE_PIN   BH44     [get_ports {ext_refclk_p}]
set_property IOSTANDARD    LVDS     [get_ports {ext_refclk_p}]
set_property DIFF_TERM_ADV TERM_100 [get_ports {ext_refclk_p}]
