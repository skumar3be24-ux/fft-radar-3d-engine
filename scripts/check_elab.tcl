# -----------------------------------------------------------------------------
# check_elab.tcl -- ELABORATE ONLY. Catches errors before any long run.
#
#   vivado -mode batch -source scripts/check_elab.tcl
#
# Runs in under a minute and finds the things that actually bite:
#   * syntax errors
#   * port name / width mismatches between modules
#   * missing or duplicated module definitions
#   * unconnected or multiply-driven nets
#   * parameter overrides that do not exist
#
# It does NOT place, route or report timing. Do this first; only run
# build_synth.tcl once this is clean.
# -----------------------------------------------------------------------------

set part_name "xc7k325tffg900-2"
set top_name  "radar_dsp_3d_top"

# FROZEN SPEC: 1024 range x 256 Doppler x 4 RX. Was 256 x 16 back when
# ctm_stub held the cube as a flat array and had to be kept small to
# elaborate; that no longer applies (the SYNTHESIS branch is a register).
# Elaborating the real dimensions costs nothing and means this check
# actually exercises the shipped configuration.
set n_range 1024
set n_chirp 256

# DOPPLER_SEL=1 -> DOPPLER_NFFT1=8 -> 2**8 = 256, matching n_chirp.
# This now equals the module default; passed explicitly so the intent is
# visible in the log rather than implied.
set doppler_sel 1

puts "\n=== ELABORATION CHECK ==="
puts "    part = $part_name"
puts "    top  = $top_name"
puts "    cube = ${n_range} range x ${n_chirp} chirp x 4 ant  (FROZEN SPEC)"
puts "    Doppler transform = [expr {$doppler_sel ? 256 : 128}]-point\n"

create_project -in_memory -part $part_name

# ---- RTL ---------------------------------------------------------------------
# Explicit list, NOT a glob. rtl/ still contains superseded files
# (radar_dsp_top.v, ctm_tiled_pingpong.v, angle_fft_lane.sv) which would
# collide or pull in the old broken versions.
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
puts ">>> [llength $rtl_files] RTL files read"

# ---- IP ----------------------------------------------------------------------
set xci ./vivado_ip_kc705/xfft_gen.srcs/sources_1/ip/xfft_0/xfft_0.xci
if {![file exists $xci]} {
    puts "*** MISSING IP: $xci"
    puts "    run: vivado -mode batch -source scripts/create_fft_ip.tcl"
    exit 1
}
read_ip $xci
generate_target {synthesis instantiation_template} [get_ips xfft_0]
puts ">>> IP xfft_0 read"

# ---- elaborate ---------------------------------------------------------------
# -verilog_define SYNTHESIS: deterministically selects the register-stage
# placeholder inside ctm_stub.sv instead of its flat-array simulation model.
# That array blows past Vivado's ~1,000,000-bit single-variable elaboration
# ceiling at any cube worth simulating (confirmed 2 Sep at 256x16) -- this is
# a synth_design front-end limit, unrelated to real BRAM budget. Do NOT rely
# on Vivado predefining this macro; pass it explicitly so behaviour doesn't
# depend on tool version or flow.
if {[catch {
    synth_design -top $top_name -part $part_name -mode out_of_context -rtl \
        -generic N_RANGE=$n_range -generic N_CHIRP=$n_chirp \
        -generic DOPPLER_SEL=$doppler_sel \
        -verilog_define SYNTHESIS
} msg]} {
    puts "\n*** ELABORATION FAILED"
    puts $msg
    exit 1
}

puts "\n>>> ELABORATION CLEAN"

# ---- structural sanity -------------------------------------------------------
puts "\n=== instance count by module ==="
foreach m {fft_lane doppler_lane ctm_stub angle_fft4_par complex_mag2 ca_cfar
           axis_pack4 axis_unpack4 exp_accum window_lane axis_skid} {
    set n [llength [get_cells -hier -filter "REF_NAME == $m"]]
    puts [format "  %-16s %d" $m $n]
}

puts "\nExpected: 4 fft_lane, 4 doppler_lane, 1 ctm_stub, 1 angle_fft4_par,"
puts "          4 complex_mag2, 4 ca_cfar, 3 axis_pack4, 3 axis_unpack4, 1 exp_accum"
puts "\nIf any count is 0 the module was optimised away -- usually a dangling"
puts "output or a tied-off input. Investigate before synthesising.\n"
