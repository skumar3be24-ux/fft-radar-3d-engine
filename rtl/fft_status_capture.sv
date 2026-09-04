// -----------------------------------------------------------------------------
// fft_status_capture -- drains the xfft status channel
//
// SOLE REMAINING JOB: keep m_axis_status_tready asserted.
//
// Leaving that port unconnected lets the core's status FIFO fill, and it trips
// an internal assertion ("add_1 must be in range [-1,DEPTH-1]") on the SECOND
// frame. The symptom looks like a throughput or backpressure fault and is not;
// the only prior warning is an elaboration message about an unconnected port,
// which is easy to miss. This module owns the port so it cannot be forgotten.
//
// -----------------------------------------------------------------------------
// REVISION: the BLK_EXP pairing FIFO that used to live here has been removed.
//
// The generated core reports C_M_AXIS_DATA_TUSER_WIDTH = 8 with both optional
// output fields disabled (C_HAS_XK_INDEX = 0, C_HAS_OVFLO = 0). The only field
// that can occupy those 8 bits is BLK_EXP, present because scaling is block
// floating point. The core therefore already presents the block exponent on
// m_axis_data_tuser, beat-aligned with its own output data.
//
// Taking BLK_EXP from the data channel's TUSER is strictly better than pairing
// it by hand: alignment is guaranteed by the IP rather than by an assumption
// about the relative timing of two AXI-Stream channels. fft_lane now does that,
// and this module keeps only the drain.
//
// The latched value below is for CSR readback and debug. It is NOT the value
// forwarded downstream -- do not wire it into the datapath.
// -----------------------------------------------------------------------------
`timescale 1ns / 1ps
`default_nettype none

module fft_status_capture #(
    parameter int STATUS_W = 8      // confirmed from xfft_0.veo: [7:0]
) (
    input  wire                 aclk,
    input  wire                 aresetn,

    input  wire [STATUS_W-1:0]  s_axis_status_tdata,
    input  wire                 s_axis_status_tvalid,
    output wire                 s_axis_status_tready,

    output logic [7:0]          blk_exp_dbg_o,      // CSR / debug only
    output logic                blk_exp_seen_o
);

    // Unconditional. Never gate this on anything downstream -- that is exactly
    // the failure mode this module exists to prevent.
    assign s_axis_status_tready = 1'b1;

    always_ff @(posedge aclk) begin
        if (!aresetn) begin
            blk_exp_dbg_o  <= 8'd0;
            blk_exp_seen_o <= 1'b0;
        end else if (s_axis_status_tvalid && s_axis_status_tready) begin
            blk_exp_dbg_o  <= s_axis_status_tdata[7:0];
            blk_exp_seen_o <= 1'b1;
        end
    end

endmodule

`default_nettype wire
