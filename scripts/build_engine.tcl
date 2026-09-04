# -----------------------------------------------------------------------------
# build_engine.tcl -- synthesise AND implement fft_engine_top, project mode
#
#   vivado -mode batch -source scripts/build_engine.tcl
#
# then open the GUI to browse the results:
#
#   vivado vivado_engine/fft_engine.xpr
#
# Uses launch_runs (not bare synth_design) so the results are stored in the
# project. That is what makes "Open Synthesized Design" and "Open Implemented
# Design" work in the GUI, and it gives real post-route timing rather than a
# synthesis estimate.
#
# Prerequisite: scripts/create_fft_ip.tcl has been run.
# -----------------------------------------------------------------------------

# Must match the BOARD set in create_fft_ip.tcl
set BOARD kc705

switch $BOARD {
    zybo  { set PART xc7z020clg400-1
            set IPDIR ./vivado_ip
            set PROJ_DIR ./vivado_engine
            set BUDGET "53200 LUT / 106400 FF / 220 DSP48E1 / 140 RAMB36" }
    kc705 { set PART xc7k325tffg900-2
            set IPDIR ./vivado_ip_kc705
            set PROJ_DIR ./vivado_engine_kc705
            set BUDGET "203800 LUT / 407600 FF / 840 DSP48E1 / 445 RAMB36" }
    default { error "BOARD must be zybo or kc705" }
}
puts "=== BOARD=$BOARD  PART=$PART"

set TOP       fft_engine_top

# Lanes to build. Measured on zybo: 24 DSP / 18 RAMB18 per lane.
set NUM_LANES 1

set XCI $IPDIR/xfft_gen.srcs/sources_1/ip/xfft_0/xfft_0.xci
if {![file exists $XCI]} {
    puts "ERROR: $XCI not found. Run scripts/create_fft_ip.tcl first."
    exit 1
}

file mkdir reports
create_project -force fft_engine $PROJ_DIR -part $PART

add_files [glob ./rtl/*.sv]
add_files -fileset sim_1 [glob ./tb/*.sv]
set_property file_type SystemVerilog [get_files *.sv]

add_files -fileset constrs_1 ./constraints/fft_engine.xdc

read_ip $XCI
generate_target all [get_ips xfft_0]

set_property top $TOP [current_fileset]
set_property generic "NUM_LANES=$NUM_LANES" [current_fileset]
set_property top tb_fft_engine [get_filesets sim_1]
update_compile_order -fileset sources_1
update_compile_order -fileset sim_1

# ---------------------------------------------------------------------------
# Out-of-context mode. This block has ~95 ports and no pin constraints; in a
# normal flow Vivado would try to insert IO buffers and place them, and
# implementation would fail on unconstrained IO. OOC skips buffer insertion and
# reports internal logic timing, which is what we actually want for a block
# that will be instantiated inside a larger design.
# ---------------------------------------------------------------------------
# There is no STEPS.SYNTH_DESIGN.ARGS.MODE property. Extra synth_design
# switches go through the "MORE OPTIONS" property (the space is real, hence
# the braces). If this ever errors, list what exists rather than guessing:
#   join [lsearch -all -inline [lsort [list_property [get_runs synth_1]]] STEPS.SYNTH*] \n
set_property -name {STEPS.SYNTH_DESIGN.ARGS.MORE OPTIONS} \
             -value {-mode out_of_context} \
             -objects [get_runs synth_1]

puts "\n>>> synthesis..."
launch_runs synth_1 -jobs 4
wait_on_run synth_1
if {[get_property PROGRESS [get_runs synth_1]] != "100%"} {
    puts "ERROR: synthesis failed. See $PROJ_DIR/fft_engine.runs/synth_1/"
    exit 1
}

puts "\n>>> implementation..."
launch_runs impl_1 -jobs 4
wait_on_run impl_1
if {[get_property PROGRESS [get_runs impl_1]] != "100%"} {
    puts "ERROR: implementation failed. See $PROJ_DIR/fft_engine.runs/impl_1/"
    exit 1
}

open_run impl_1

report_utilization         -file reports/engine_util_routed.rpt
report_timing_summary      -file reports/engine_timing_routed.rpt
report_timing -max_paths 20 -file reports/engine_paths_routed.rpt

# ---- headline: POST-ROUTE, not synthesis estimate -------------------------
puts "\n========= FFT ENGINE post-route (NUM_LANES=$NUM_LANES) ========="
foreach {name filt} {
    LUT    {REF_NAME =~ LUT*}
    FF     {REF_NAME =~ FD*}
    DSP48  {REF_NAME =~ DSP48*}
    RAMB36 {REF_NAME =~ RAMB36*}
    RAMB18 {REF_NAME =~ RAMB18*}
} {
    puts [format "%-7s: %d" $name [llength [get_cells -hier -filter $filt]]]
}
set wns [get_property SLACK [get_timing_paths -delay_type max_rise -max_paths 1]]
set whs [get_property SLACK [get_timing_paths -delay_type min_rise -max_paths 1]]
puts [format "WNS    : %s ns  (setup, must be >= 0)" $wns]
puts [format "WHS    : %s ns  (hold,  must be >= 0)" $whs]
puts "device budget: $BUDGET"
puts "==============================================================="
# Fmax from the measured critical path -- this decides whether ONE range lane
# can cover the 102.4 MSPS input, or whether two are needed.
if {$wns ne ""} {
    set fmax [expr {1000.0 / (10.0 - $wns)}]
    puts [format "Fmax   : %.1f MHz   (one range lane covers 102.4 MSPS if >= 103 MHz)" $fmax]
}
puts "\nOpen the GUI with:  vivado $PROJ_DIR/fft_engine.xpr"

close_project
