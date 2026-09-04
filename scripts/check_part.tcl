# ---------------------------------------------------------------------------
# check_part.tcl -- is the KC705 device installed, and is it licensed?
#
#   vivado -mode batch -source scripts/check_part.tcl
#
# Two separate questions, and they fail differently:
#   1. INSTALLED  -- was Kintex-7 ticked during Vivado installation?
#                    Fails here as "parts matching: 0".
#   2. LICENSED   -- XC7K325T is NOT in the free Vivado tier (Standard covers
#                    Kintex-7 only up to XC7K160T). It needs Vivado ML
#                    Enterprise or the device-locked licence that shipped with
#                    the KC705 kit. Fails at synth_design, not before.
#
# This script tests both by actually synthesising a trivial design.
# ---------------------------------------------------------------------------

set PARTS {
    xc7k325tffg900-2
    xc7z020clg400-1
}

puts "\n================ DEVICE CHECK ================"

foreach p $PARTS {
    set n [llength [get_parts -quiet $p]]
    if {$n == 0} {
        puts [format "%-22s NOT INSTALLED" $p]
        continue
    }
    set pp [lindex [get_parts $p] 0]
    puts [format "%-22s installed   LUT=%-7s FF=%-7s DSP=%-5s BRAM36=%s" $p \
        [get_property -quiet LUT_ELEMENTS   $pp] \
        [get_property -quiet FLIPFLOPS      $pp] \
        [get_property -quiet DSP            $pp] \
        [get_property -quiet BLOCK_RAMS     $pp]]
}

# ---- licence test: synthesise something trivial on the KC705 part ---------
set TESTPART xc7k325tffg900-2
if {[llength [get_parts -quiet $TESTPART]] == 0} {
    puts "\n*** $TESTPART not installed -- re-run the Vivado installer and tick Kintex-7."
    puts "==============================================\n"
    exit 0
}

file mkdir ./build
set f [open ./build/_lic_probe.v w]
puts $f "module _lic_probe(input wire clk, input wire d, output reg q);"
puts $f "  always @(posedge clk) q <= d;"
puts $f "endmodule"
close $f

puts "\n--- licence probe: synthesising a 1-flop design on $TESTPART ---"
if {[catch {
    create_project -in_memory -part $TESTPART
    read_verilog ./build/_lic_probe.v
    synth_design -top _lic_probe -part $TESTPART -mode out_of_context
} msg]} {
    puts "\n*** SYNTHESIS FAILED"
    puts $msg
    puts "\nIf the message mentions a licence, you need either:"
    puts "  - Vivado ML Enterprise, or"
    puts "  - the device-locked KC705 licence (came with the board;"
    puts "    check your AMD/Xilinx account under Manage Licenses)"
    puts "==============================================\n"
    exit 1
}

puts "\n>>> LICENCE OK -- $TESTPART synthesises. You can build for the KC705."
puts "==============================================\n"
exit 0
