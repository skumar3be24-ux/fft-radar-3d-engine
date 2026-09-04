# report_all.tcl -- terminal-only post-implementation reporting
#
#   vivado -mode batch -source scripts/report_all.tcl
#
# Assumes build.tcl / run_impl.tcl have already produced an implemented run.
# Writes reports/ and prints the headline numbers to stdout.

# ---- locate the project without hardcoding a name -------------------------
set xpr [lindex [glob -nocomplain -directory . -join * *.xpr] 0]
if {$xpr eq ""} {
    set xpr [lindex [glob -nocomplain -directory . -join * * *.xpr] 0]
}
if {$xpr eq ""} {
    puts "ERROR: no .xpr found. Edit the glob or pass the path explicitly."
    exit 1
}
puts "INFO: opening $xpr"
open_project $xpr

file mkdir reports

# ---- implemented run ------------------------------------------------------
open_run impl_1

report_utilization      -file reports/util.rpt
report_timing_summary   -file reports/timing_summary.rpt
report_timing -max_paths 20 -sort_by group -file reports/timing_paths.rpt
report_clocks           -file reports/clocks.rpt

# ---- headline numbers to stdout ------------------------------------------
puts "\n================ HEADLINE ================"

set wns [get_property SLACK [get_timing_paths -delay_type max_rise -max_paths 1]]
set whs [get_property SLACK [get_timing_paths -delay_type min_rise -max_paths 1]]
puts [format "WNS (setup) : %s ns" $wns]
puts [format "WHS (hold)  : %s ns" $whs]

foreach {name filt} {
    LUT    {REF_NAME =~ LUT*}
    FF     {REF_NAME =~ FD*}
    DSP48  {REF_NAME =~ DSP48*}
    RAMB36 {REF_NAME =~ RAMB36*}
    RAMB18 {REF_NAME =~ RAMB18*}
} {
    puts [format "%-7s: %d" $name [llength [get_cells -hier -filter $filt]]]
}

puts "=========================================="
puts "xc7z020 budget: 53200 LUT / 106400 FF / 220 DSP48E1 / 140 RAMB36"
puts "Full reports in reports/"

# ---- dump every xfft CONFIG.* so the spec gaps can be frozen (G1..G5) -----
foreach ip [get_ips] {
    puts "\n---- IP: $ip ----"
    report_property -all [get_ips $ip] -file reports/ip_$ip.rpt
    puts "properties -> reports/ip_$ip.rpt"
}

close_project
