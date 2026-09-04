# -----------------------------------------------------------------------------
# Out-of-context timing constraints for radar_dsp_3d_top
#
# Created 3 Sep, after the first successful synthesis reported an EMPTY WNS.
# That was not "timing met" -- it was "timing never analysed". The old
# rtl/kc705_timing.xdc failed three ways at once:
#
#   1. UTF-8 BOM on line 1 -> "Command '<BOM>#' is not supported in the xdc
#      constraint file". Vivado could not parse the first line at all.
#   2. It constrained ports named sys_clk_p / sys_rst_n. This module's ports
#      are aclk / aresetn, so get_ports matched nothing and create_clock
#      never ran. Every path was left unconstrained.
#   3. It asked for 250 MHz. The whole architecture is costed at 100 MHz
#      (4 lanes x 1 sample/clock = 400 MSPS against 102.4 MSPS required).
#
# A synthesis run that reports 0 errors and no WNS has told you nothing
# about timing. This file exists so that stops being possible.
# -----------------------------------------------------------------------------

# 100 MHz. Matches the target the 4-lane architecture was sized for and the
# frequency the xfft cores were generated against (target_clock_frequency
# 100 in scripts/create_fft_ip.tcl).
create_clock -period 10.000 -name aclk [get_ports aclk]

# Reset is asynchronous-assert / synchronous-deassert and is not on a timed
# path into the core logic. Exclude it rather than leave it unconstrained
# and silently reported.
set_false_path -from [get_ports aresetn]

# -----------------------------------------------------------------------------
# NOT set here, deliberately: PACKAGE_PIN and IOSTANDARD.
#
# Pin assignments are meaningless in out-of-context mode -- there are no
# physical pins, this module is a block to be integrated, not a top level.
# They belong in the board-level XDC that constrains the real top (the one
# with sys_clk_p, the MIG, and the corner turn wired up). Putting them here
# produces exactly the "No ports matched" noise that hid the missing clock.
# -----------------------------------------------------------------------------
