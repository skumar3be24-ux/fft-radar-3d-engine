# Force the exact KC705 hardware platform
create_project -force ctm_bandwidth_test ./ctm_test -part xc7k325tffg900-2
set_property board_part xilinx.com:kc705:part0:1.6 [current_project]

puts ">>> Generating MIG 7 Series DDR3 Controller..."
create_ip -name mig_7series -vendor xilinx.com -library ip -module_name mig_ddr3_0

# ENFORCE THE BOARD PRESET - Do not attempt to manually map pins
set_property -dict [list CONFIG.BOARD_MIG_PARAM {ddr3_sdram}] [get_ips mig_ddr3_0]

generate_target {instantiation_template synthesis} [get_ips mig_ddr3_0]

puts ">>> MIG Generation Complete."
puts ">>> WARNING: You must manually supply a stable 200 MHz reference clock (sys_clk_i) for calibration."