# -----------------------------------------------------------------------------
# run_pipeline_smoke.tcl -- first end-to-end simulation of radar_dsp_3d_top,
# through the REAL xfft_0 IP core, not a mock.
#
#   vivado -mode batch -source scripts/run_pipeline_smoke.tcl
#
# Uses Vivado's PROJECT-based simulation flow (create_project + launch_simulation),
# not the raw xvlog/xelab/xsim flow that run_unit_tests.ps1 uses. That's
# deliberate: the design under test here instantiates the real xfft_0 IP, and
# only the project flow reliably resolves the IP's simulation sources and the
# Xilinx simulation libraries it depends on. Hand-rolling that with raw
# xvlog/xelab would mean guessing at library search paths I have not verified
# -- this project's own vivado_proj/ directory shows this exact flow already
# worked here before, which is why it's used again rather than something new.
#
# Simulation only -- should NOT need the network-restricted Synthesis license
# that blocked build_synth.tcl. If this ALSO fails on a license error, that is
# new information (a different license feature is also unreachable) and worth
# reporting back, not something already known.
# -----------------------------------------------------------------------------

set part_name "xc7k325tffg900-2"
set proj_dir  "./build/pipeline_smoke_proj"
set proj_name "pipeline_smoke"

puts "\n=== END-TO-END PIPELINE SMOKE TEST ==="
puts "    part = $part_name"
puts "    top  = tb_radar_dsp_3d_top_smoke\n"

file delete -force $proj_dir
create_project $proj_name $proj_dir -part $part_name -force

# ---- RTL: same explicit list as check_elab.tcl/build_synth.tcl, plus the
# new smoke testbench. Not a glob -- rtl/ still has files these lists
# deliberately exclude (see build_synth.tcl's comment for why).
set rtl_files {
    rtl/axis_skid.sv
    rtl/axis_pack4.sv
    rtl/fft_config_fsm.sv
    rtl/fft_status_capture.sv
    rtl/window_lane.sv
    rtl/fft_lane.sv
    rtl/doppler_lane.sv
    rtl/ctm_stub.sv
    rtl/exp_accum.sv
    rtl/angle_fft4_par.sv
    rtl/complex_mag2.sv
    rtl/ca_cfar.sv
    rtl/radar_dsp_3d_top.sv
}
foreach f $rtl_files {
    if {![file exists $f]} { puts "*** MISSING: $f" ; exit 1 }
    add_files -norecurse $f
}

set tb_file "tb/tb_radar_dsp_3d_top_smoke.sv"
if {![file exists $tb_file]} { puts "*** MISSING: $tb_file" ; exit 1 }
add_files -fileset sim_1 -norecurse $tb_file

# FIXED 2 Sep, ATTEMPT 1 (WRONG, kept working data files 4mem_file below is
# the real fix): tried `add_files -norecurse $mem_file`, expecting Vivado to
# stage it at the same relative path window_lane.sv asks for
# ($readmemh("rtl/hanning_1024.mem")). It did not -- the run log showed
# "Exported '.../sim_1/behav/xsim/hanning_1024.mem'": Vivado flattens
# exported data files to the run directory ROOT, dropping the rtl/ prefix.
# The warning ("cannot be opened for reading") reproduced unchanged on the
# next run -- all 4 Range lanes STILL got X/uninitialized window
# coefficients. Confirmed by the transcript, not assumed.
#
# FIXED 2 Sep, ATTEMPT 2 (this one): pre-stage the file by hand at the exact
# path xsim actually uses, before launch_simulation ever runs. The run
# directory pattern (<proj_dir>/<proj_name>.sim/sim_1/behav/xsim/) is not a
# guess -- it is the literal path both prior runs printed
# ("Launching behavioral simulation in '...pipeline_smoke.sim/sim_1/behav/xsim'").
# window_lane.sv's $readmemh path is NOT changed -- that would fix this flow
# and break check_elab.tcl/build_synth.tcl, which already pass and resolve
# rtl/hanning_1024.mem correctly relative to their own (repo-root) working
# directory.
set mem_file "rtl/hanning_1024.mem"
if {![file exists $mem_file]} { puts "*** MISSING: $mem_file" ; exit 1 }
add_files -norecurse $mem_file

set xsim_run_dir "${proj_dir}/${proj_name}.sim/sim_1/behav/xsim"
file mkdir "${xsim_run_dir}/rtl"
file copy -force $mem_file "${xsim_run_dir}/rtl/hanning_1024.mem"
puts "--- pre-staged $mem_file at ${xsim_run_dir}/rtl/hanning_1024.mem ---"

set xci "./vivado_ip_kc705/xfft_gen.srcs/sources_1/ip/xfft_0/xfft_0.xci"
if {![file exists $xci]} {
    puts "*** MISSING IP: $xci"
    puts "    run: vivado -mode batch -source scripts/create_fft_ip.tcl"
    exit 1
}
add_files -norecurse $xci

update_compile_order -fileset sources_1
set_property top tb_radar_dsp_3d_top_smoke [get_filesets sim_1]
update_compile_order -fileset sim_1

# NOTE: unlike ctm_stub.sv's other consumers, this is simulation, so
# SYNTHESIS must NOT be defined here -- the real transpose model in
# ctm_stub.sv must be selected, not the register placeholder.

puts "--- LAUNCHING SIMULATION ---"
if {[catch {
    launch_simulation
    run all
} msg]} {
    puts "\n*** SIMULATION LAUNCH FAILED"
    puts $msg
    puts "\nIf this is a license/network error identical to build_synth.tcl's,"
    puts "that is new and unexpected -- simulation was not known to need that"
    puts "server. If it is an IP simulation-library error instead, that is a"
    puts "Vivado project-flow issue to debug, not a design defect -- report"
    puts "the exact message back."
    exit 1
}

puts "\n=== simulation finished -- see transcript above for PASS/FAIL ==="
