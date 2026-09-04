# -----------------------------------------------------------------------------
# build_synth.tcl -- out-of-context synthesis of the full 3-D chain
#
#   vivado -mode batch -source build_synth.tcl
#
# FIXED 31 Aug: this script previously read
#     # Define the exact Kintex-7 silicon part (KC705 board)
#     set part_name "xc7a200tfbg676-2"
# The comment said Kintex-7; the value was ARTIX-7 200T. Every number in
# synth_utilization.txt and synth_timing.txt was therefore for a device that is
# not on the desk (134,600 LUT / 740 DSP / 365 BRAM instead of the KC705's
# 203,800 / 840 / 445).
# -----------------------------------------------------------------------------

set part_name "xc7k325tffg900-2"       ;# Kintex-7 XC7K325T, KC705
set top_name  "radar_dsp_3d_top"

# FIXED 2 Sep: this was 1024 x 16 with the Doppler core left at its 128-point
# default -- i.e. NOT the frozen spec. Any utilization/timing report from that
# build described the wrong design, and optimistically so: a 256-point Doppler
# FFT needs materially more BRAM for its delay lines than a 128-point one.
#
# The old comment here ("keep the cube small or BRAM inference explodes") was
# true when ctm_stub held the whole cube as a flat array. It no longer is --
# under -verilog_define SYNTHESIS that module is a 1-deep register with no
# array at all, so full-size dimensions cost nothing to synthesise.
#
# Frozen spec: 1024 range x 256 Doppler x 4 antennas (4.19 MB cube).
set n_range 1024
set n_chirp 256

# DOPPLER_SEL=1 picks DOPPLER_NFFT1=8 -> 2^8 = 256, matching n_chirp.
# Left at its 0 default this selects a 128-point transform and the design
# silently does not match the spec. RANGE_SEL stays 0 (-> 2^10 = 1024),
# which already matches n_range.
set doppler_sel 1

puts "=== part=$part_name  top=$top_name  cube=${n_range}x${n_chirp}x4"
puts "=== Doppler transform: [expr {$doppler_sel ? 256 : 128}]-point (DOPPLER_SEL=$doppler_sel)"
puts "=== NOTE: u_ctm is the register placeholder here, NOT the real corner"
puts "===       turn. These numbers are 'everything except the CTM'. The real"
puts "===       DDR-backed block plus its MIG controller will add substantially"
puts "===       on top -- do not read this as the final device utilization."
create_project -in_memory -part $part_name

puts "--- READING RTL ---"
# Explicit list, NOT a glob. rtl/ still contains superseded modules:
#   radar_dsp_top.v        stub, replaced by radar_dsp_3d_top.sv
#   ctm_tiled_pingpong.v   broken transpose, now the corner-turn owner's job
#   angle_fft_lane.sv      shift-register placeholder, replaced by angle_fft4_par
#   radar_multilane_top.sv earlier experiment
# A glob would drag them in and either collide or silently synthesise the wrong
# thing. Move them to attic/ when convenient.
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
    read_verilog -sv $f
}

puts "--- READING IP ---"
read_ip ./vivado_ip_kc705/xfft_gen.srcs/sources_1/ip/xfft_0/xfft_0.xci
generate_target synthesis [get_ips xfft_0]

puts "--- READING CONSTRAINTS ---"
# FIXED 3 Sep. This used to read rtl/kc705_timing.xdc, which constrained
# ports named sys_clk_p/sys_rst_n that do not exist on this module (its
# clock is aclk), and carried a UTF-8 BOM that made Vivado reject line 1.
# Result: create_clock never ran, every path was unconstrained, and the
# first successful synthesis reported an EMPTY WNS -- which reads like
# success and means "timing was never analysed".
#
# rtl/kc705_timing.xdc is a BOARD-level file for the real top (sys_clk_p,
# MIG, pin assignments). It is not applicable to an out-of-context run of
# this block. Keep the two separate.
set xdc ./constraints/ooc_radar_dsp_3d_top.xdc
if {![file exists $xdc]} { puts "*** MISSING: $xdc" ; exit 1 }
read_xdc $xdc

puts "--- SYNTHESIS ---"
# -verilog_define SYNTHESIS: forces ctm_stub.sv onto its register-stage
# placeholder, not its flat-array simulation model, which cannot elaborate
# at this cube (1024x16 = 4.19 Mbit, vs Vivado's ~1,000,000-bit elaboration
# ceiling -- confirmed 2 Sep). Utilization/timing for the u_ctm instance in
# this report describe a register, not the real corner turn.
synth_design -top $top_name -part $part_name -mode out_of_context \
    -generic N_RANGE=$n_range -generic N_CHIRP=$n_chirp \
    -generic DOPPLER_SEL=$doppler_sel \
    -verilog_define SYNTHESIS

file mkdir reports
report_utilization    -file reports/top3d_utilization.rpt
report_timing_summary -file reports/top3d_timing.rpt

puts "\n========= 3-D TOP post-synthesis ($part_name) ========="
foreach {name filt} {
    LUT    {REF_NAME =~ LUT*}
    FF     {REF_NAME =~ FD*}
    DSP48  {REF_NAME =~ DSP48*}
    RAMB36 {REF_NAME =~ RAMB36*}
    RAMB18 {REF_NAME =~ RAMB18*}
} {
    puts [format "%-7s: %d" $name [llength [get_cells -hier -filter $filt]]]
}
# Report WNS, and REFUSE to report it silently as blank. An empty WNS does
# not mean timing passed -- it means no constrained paths were analysed,
# which is what happened on the 3 Sep run before the XDC was fixed.
set clks [get_clocks -quiet]
if {[llength $clks] == 0} {
    puts "WNS    : *** NO CLOCK DEFINED -- TIMING NOT ANALYSED ***"
    puts "         The XDC did not create a clock. Any conclusion about"
    puts "         timing from this run would be meaningless."
} else {
    set paths [get_timing_paths -quiet -delay_type max_rise -max_paths 1]
    if {[llength $paths] == 0} {
        puts "WNS    : *** NO TIMING PATHS FOUND -- check the constraints ***"
    } else {
        set wns [get_property SLACK [lindex $paths 0]]
        puts [format "WNS    : %s ns  (clock: %s)" $wns [get_property NAME [lindex $clks 0]]]
        if {$wns < 0} {
            puts "         *** NEGATIVE SLACK -- TIMING NOT MET ***"
        }
    }
}
puts "budget : 203800 LUT / 407600 FF / 840 DSP48E1 / 445 RAMB36"
puts "======================================================="
puts "Reports in reports/top3d_*.rpt"
