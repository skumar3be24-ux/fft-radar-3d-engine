# -----------------------------------------------------------------------------
# create_fft_ip.tcl -- generate xfft_0 against the frozen specification
#
#   vivado -mode batch -source scripts/create_fft_ip.tcl
#
# Frozen values (SPEC_FROZEN.md section 1): Pipelined Streaming I/O, radix-2,
# natural order, BFP, Q1.15 16-bit data and phase, convergent rounding,
# non-realtime throttle, runtime-configurable length 1024/2048.
#
# ---------------------------------------------------------------------------
# IMPORTANT -- property names are version-sensitive. If a set_property call
# errors, do NOT guess a replacement. Dump the real names and values with:
#
#   report_property -all [get_ips xfft_0]
#
# then correct the line below. The script deliberately builds the IP in two
# passes so a bad property name fails loudly instead of silently defaulting.
# ---------------------------------------------------------------------------

# ---------------------------------------------------------------------------
# TARGET BOARD. Set BOARD to zybo or kc705.
#   zybo : Zynq  xc7z020, -1 speed grade, 220 DSP / 140 BRAM36
#   kc705: Kintex xc7k325t, -2 speed grade, 840 DSP / 445 BRAM36
# The RTL is identical for both; only the part and the clock target change.
# ---------------------------------------------------------------------------
set BOARD kc705

switch $BOARD {
    zybo  { set PART xc7z020clg400-1  ; set FCLK 100 ; set PROJ_DIR ./vivado_ip }
    kc705 { set PART xc7k325tffg900-2 ; set FCLK 100 ; set PROJ_DIR ./vivado_ip_kc705 }
    default { error "BOARD must be zybo or kc705" }
}
puts "=== BOARD=$BOARD  PART=$PART  target clock=${FCLK} MHz"

set IP_NAME   xfft_0

# G1: complex multiplier structure. Frozen once for the WHOLE project -- it
# changes rounding, not just DSP count, so a mismatch between this block and
# anyone else's reference build shows up as an unexplained tolerance failure
# much later. Set to 3 to save ~25% DSP, or 4 to match a 4-mult reference.
set G1_MULTS  4

file mkdir $PROJ_DIR
create_project -force xfft_gen $PROJ_DIR -part $PART

create_ip -name xfft -vendor xilinx.com -library ip -version 9.1 \
          -module_name $IP_NAME

# NOTE: with run_time_configurable_transform_length, transform_length sets the
# MAXIMUM size the core is built for. It must be 2048, not 1024, or the runtime
# 2048-point mode required by the frozen spec is physically unbuildable.
# N=1024 then costs the same silicon as N=2048 -- expected, not a bug.
set cfg [list \
    CONFIG.transform_length                        {2048} \
    CONFIG.implementation_options                  {pipelined_streaming_io} \
    CONFIG.run_time_configurable_transform_length  {true} \
    CONFIG.target_clock_frequency                  $FCLK \
    CONFIG.data_format                             {fixed_point} \
    CONFIG.input_width                             {16} \
    CONFIG.phase_factor_width                      {16} \
    CONFIG.scaling_options                         {block_floating_point} \
    CONFIG.rounding_modes                          {convergent_rounding} \
    CONFIG.output_ordering                         {natural_order} \
    CONFIG.throttle_scheme                         {nonrealtime} \
    CONFIG.cyclic_prefix_insertion                 {false} \
    CONFIG.aresetn                                 {true} \
    CONFIG.number_of_stages_using_block_ram_for_data_and_phase_factors {5} \
]

# Valid range for the BRAM-stages parameter is 1..5 (Vivado reported this).
# It is the count of stages, starting from the largest, whose delay lines go in
# block RAM; the rest use distributed RAM / SRL. For N=2048 the stage delays are
# 1024, 512, 256, 128, 64, 32, ... so 5 covers 1984 of 2047 words -- nearly all
# the memory. BRAM is the right home for those: a 1024-word x 32-bit delay is
# about one RAMB36, versus roughly 1024 LUTs as SRL. BRAM is the resource this
# device has spare (140 RAMB36 vs 220 DSP), so max it out.

# Valid values reported by Vivado: use_mults_resources, use_mults_performance,
# use_luts.
if {$G1_MULTS == 3} {
    lappend cfg CONFIG.complex_mult_type {use_mults_resources}     ;# 3-mult
} else {
    lappend cfg CONFIG.complex_mult_type {use_mults_performance}   ;# 4-mult
}

set_property -dict $cfg [get_ips $IP_NAME]

generate_target {instantiation_template synthesis} [get_ips $IP_NAME]
synth_ip [get_ips $IP_NAME]

# ---------------------------------------------------------------------------
# Report what actually got built. Three things to read out of this:
#   1. DSP48E1 and RAMB count  -> feeds the lane-count ceiling
#   2. config / status channel widths -> set CFG_W and STATUS_W in the RTL
#   3. reported latency -> the ~2N estimate replaced by a real number
# ---------------------------------------------------------------------------
file mkdir reports
report_property -all [get_ips $IP_NAME] -file reports/xfft_properties.rpt

puts "\n================ xfft_0 built ================"
puts "Instantiation template: $PROJ_DIR/xfft_gen.srcs/sources_1/ip/$IP_NAME/"
puts "Read the .veo for the ACTUAL port widths and set CFG_W / STATUS_W to match."
puts "Full property dump: reports/xfft_properties.rpt"
puts "=============================================="

close_project
