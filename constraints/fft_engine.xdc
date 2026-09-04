# -----------------------------------------------------------------------------
# fft_engine.xdc -- out-of-context timing constraint for the FFT engine block
#
# 100 MHz / 10.000 ns, per frozen spec section 2 (Zynq PS FCLK_CLK0).
#
# This is a BLOCK-LEVEL constraint for synthesising fft_engine_top on its own.
# When the block is integrated, the real clock comes from the PS and this file
# should not be added to the system project -- it would create a second,
# conflicting clock definition on the same net.
# -----------------------------------------------------------------------------

create_clock -period 10.000 -name aclk -waveform {0.000 5.000} [get_ports aclk]

# Block boundaries are registered by axis_skid, so the I/O paths below do not
# represent real chip pins -- this is a synthesis-only wrapper. Relax them so
# the report shows internal logic timing rather than meaningless I/O paths.
set_false_path -from [get_ports aresetn]
