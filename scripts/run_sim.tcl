# -----------------------------------------------------------------------------
# run_sim.tcl -- behavioural simulation of fft_engine_top
#
#   vivado -mode batch -source scripts/run_sim.tcl
#
# Prerequisite: scripts/create_fft_ip.tcl has been run.
#
# Look for "RESULT: PASS" near the end of the output.
# -----------------------------------------------------------------------------

set PART      xc7z020clg400-1
set PROJ_DIR  ./vivado_sim
set TB        tb_fft_engine

set XCI ./vivado_ip/xfft_gen.srcs/sources_1/ip/xfft_0/xfft_0.xci
if {![file exists $XCI]} {
    puts "ERROR: $XCI not found. Run scripts/create_fft_ip.tcl first."
    exit 1
}

create_project -force fft_sim $PROJ_DIR -part $PART

add_files [glob ./rtl/*.sv]
add_files -fileset sim_1 [glob ./tb/*.sv]
set_property file_type SystemVerilog [get_files *.sv]

read_ip $XCI
# Simulation target is what matters here, not synthesis.
generate_target {simulation instantiation_template} [get_ips xfft_0]
export_ip_user_files -of_objects [get_ips xfft_0] -no_script -force

set_property top $TB [get_filesets sim_1]
set_property top_lib xil_defaultlib [get_filesets sim_1]
update_compile_order -fileset sim_1

# Long enough for 7 frames of up to 2048 points plus ~2N latency each.
set_property -name {xsim.simulate.runtime} -value {5ms} \
             -objects [get_filesets sim_1]

launch_simulation
run all

close_project
