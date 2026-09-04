# -----------------------------------------------------------------------------
# SUPERSEDED 2 Sep -- targets the OLD radar_dsp_top (single-lane stub) plus
# the broken ctm_tiled_pingpong.v transpose. Moved to attic/scripts/ with the
# RTL it reads. Use build_synth.tcl (and scripts/check_elab.tcl first) instead.
# -----------------------------------------------------------------------------
read_verilog -sv ctm_rtl/ctm_tiled_pingpong.v
read_verilog -sv ctm_rtl/radar_dsp_top.v

# Use Kintex-7 KC705 IP path
if {[file exists "vivado_ip_kc705/xfft_0/xfft_0.xci"]} {
    read_ip vivado_ip_kc705/xfft_0/xfft_0.xci
} else {
    read_ip vivado_ip/xfft_gen.srcs/sources_1/ip/xfft_0/xfft_0.xci
}

# Target Kintex-7 XC7K325T ( KC705 Evaluation Board )
synth_design -top radar_dsp_top -part xc7k325tffg900-2 -mode out_of_context

if {[llength [get_ports -quiet clk]] > 0} {
    create_clock -period 10.000 -name clk [get_ports clk]
} elseif {[llength [get_ports -quiet aclk]] > 0} {
    create_clock -period 10.000 -name aclk [get_ports aclk]
} else {
    create_clock -period 10.000 -name sys_clk [get_ports *clk*]
}

report_utilization -file reports/ooc_synth_utilization.txt
report_timing_summary -file reports/ooc_synth_timing.txt