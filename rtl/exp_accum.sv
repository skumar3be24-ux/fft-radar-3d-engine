// -----------------------------------------------------------------------------
// exp_accum -- carries a per-frame block exponent across a pipeline stage
//
// WHY THIS EXISTS
//   Each FFT stage emits its own BLK_EXP. A range-Doppler cell's true scale is
//   2^(E_range + E_doppler), and after magnitude-squaring it is
//   2^(2*(E_range + E_doppler)). If the exponents are not summed, the result is
//   a plausible-looking number that is wrong by orders of magnitude -- which is
//   far worse than an obvious failure, because nothing looks broken.
//
//   The Doppler core overwrites TUSER with its own exponent, discarding the
//   range exponent that arrived with the data. This module holds the range
//   exponent for the duration of the Doppler transform so the two can be added.
//
// WHY A FIFO AND NOT A REGISTER
//   The Doppler stage has ~2N cycles of latency, so by the time frame k emerges
//   the input side has moved on to frame k+1. A single register would hand out
//   the wrong frame's exponent. Frames are strictly ordered, so a short FIFO is
//   sufficient and correct.
//
//   Push on the LAST beat of an input frame, pop on the LAST beat of the
//   matching output frame. Because TUSER is constant across a frame, capturing
//   it at TLAST captures the right value, and the head stays valid for the whole
//   of the corresponding output frame.
//
//   If ovfl_o ever asserts, more frames are in flight than DEPTH allows --
//   investigate rather than simply increasing DEPTH.
// -----------------------------------------------------------------------------
`timescale 1ns / 1ps
`default_nettype none

module exp_accum #(
    parameter int DEPTH_LG = 2          // depth = 2**DEPTH_LG frames in flight
) (
    input  wire       aclk,
    input  wire       aresetn,

    input  wire       push_i,           // pulse: input frame complete
    input  wire [7:0] exp_i,            // exponent of that frame
    input  wire       pop_i,            // pulse: output frame complete

    output wire [7:0] exp_o,            // exponent of the frame now emerging
    output wire       valid_o,
    output wire       ovfl_o            // sticky: too many frames in flight
);

    localparam int DEPTH = 1 << DEPTH_LG;

    logic [7:0]        mem [0:DEPTH-1];
    logic [DEPTH_LG:0] wptr, rptr;
    logic              ovfl;

    wire empty = (wptr == rptr);
    wire full  = (wptr[DEPTH_LG-1:0] == rptr[DEPTH_LG-1:0]) &&
                 (wptr[DEPTH_LG]     != rptr[DEPTH_LG]);

    always_ff @(posedge aclk) begin
        if (!aresetn) begin
            wptr <= '0;
            rptr <= '0;
            ovfl <= 1'b0;
        end else begin
            if (push_i) begin
                if (full) ovfl <= 1'b1;
                else begin
                    mem[wptr[DEPTH_LG-1:0]] <= exp_i;
                    wptr <= wptr + 1'b1;
                end
            end
            if (pop_i && !empty) rptr <= rptr + 1'b1;
        end
    end

    assign exp_o   = empty ? 8'd0 : mem[rptr[DEPTH_LG-1:0]];
    assign valid_o = ~empty;
    assign ovfl_o  = ovfl;

endmodule

`default_nettype wire
