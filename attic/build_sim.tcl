# -----------------------------------------------------------------------------
# SUPERSEDED 2 Sep -- this builds the OLD single-lane stub pipeline
# (radar_dsp_top.v + the broken ctm_tiled_pingpong.v), not the current
# 4-lane radar_dsp_3d_top.sv. Moved to attic/ alongside the RTL it points at.
# Use build_synth.tcl (and scripts/check_elab.tcl first) instead.
# -----------------------------------------------------------------------------
create_project radar_dsp_engine ./vivado_proj -part xc7k325tffg900-2 -force
add_files -norecurse {./rtl/radar_dsp_top.v ./rtl/ctm_tiled_pingpong.v ./rtl/kc705_timing.xdc}
add_files -fileset sim_1 -norecurse ./sim/tb_radar_dsp_top.v
set_property top tb_radar_dsp_top [get_filesets sim_1]

puts "Generating XFFT IP Core..."
create_ip -name xfft -vendor xilinx.com -library ip -version 9.1 -module_name xfft_0
set_property -dict [list CONFIG.transform_length {512} CONFIG.implementation_options {pipelined_streaming_io}] [get_ips xfft_0]
generate_target {instantiation_template simulation} [get_ips xfft_0]

puts "SUCCESS: Project and IP created. Ready for simulation."
