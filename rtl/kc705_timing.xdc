# 250 MHz System Clock (4.0ns period)
create_clock -period 4.000 -name clk_250mhz -waveform {0.000 2.000} [get_ports sys_clk_p]

# KC705 Evaluation Board Target Pins
set_property PACKAGE_PIN AD12 [get_ports sys_clk_p]
set_property IOSTANDARD LVDS [get_ports sys_clk_p]

set_property PACKAGE_PIN AB7 [get_ports sys_rst_n]
set_property IOSTANDARD LVCMOS15 [get_ports sys_rst_n]
