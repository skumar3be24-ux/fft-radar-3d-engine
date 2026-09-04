// -----------------------------------------------------------------------------
// angle_fft4_par -- 4-point DFT across antennas, all four in the same cycle
//
// THIS IS THE FUSION. Because the four Doppler lanes run in lockstep, all four
// antenna values of a (range, Doppler) cell arrive on the same clock edge. The
// angle transform therefore needs:
//
//     no input buffer, no output buffer, no reordering, and NO SECOND CORNER
//     TURN -- which is the 40% DDR traffic saving.
//
// Compare the serial variant (angle_fft4.sv): 4 beats in, 4 beats out, 8 cycles
// of occupancy and a ping-pong buffer. This version is 1 cycle, 16 adders,
// zero DSP, zero BRAM.
//
// MATHS  (W = exp(-j2pi/4) = -j)
//     s0 = x0 + x2      d0 = x0 - x2
//     s1 = x1 + x3      d1 = x1 - x3
//     X0 = s0 + s1                    X2 = s0 - s1
//     X1 = d0 - j*d1                  X3 = d0 + j*d1
//   with  -j*(a+jb) = (b, -a)   and   +j*(a+jb) = (-b, a)
//
// SCALE
//   4-point gain is 4, i.e. 2 bits. Outputs are rounded and shifted right by 2
//   to stay in Q1.15, so the block exponent grows by exactly 2.
//
// LANE MAP
//   input  lane L = antenna L
//   output lane K = angle bin K
// -----------------------------------------------------------------------------
`timescale 1ns / 1ps
`default_nettype none

module angle_fft4_par (
    input  wire         aclk,
    input  wire         aresetn,

    input  wire [127:0] s_axis_tdata,    // 4 antennas, {Im,Re} Q1.15 each
    input  wire         s_axis_tvalid,
    output wire         s_axis_tready,
    input  wire         s_axis_tlast,
    input  wire [7:0]   s_axis_tuser,    // Er + Ed

    output wire [127:0] m_axis_tdata,    // 4 angle bins
    output wire         m_axis_tvalid,
    input  wire         m_axis_tready,
    output wire         m_axis_tlast,
    output wire [7:0]   m_axis_tuser     // Er + Ed + 2
);

    // ---- unpack -------------------------------------------------------------
    wire signed [15:0] x_re [0:3];
    wire signed [15:0] x_im [0:3];

    genvar g;
    generate
        for (g = 0; g < 4; g++) begin : g_unpack
            assign x_re[g] = s_axis_tdata[32*g +:  16];
            assign x_im[g] = s_axis_tdata[32*g + 16 +: 16];
        end
    endgenerate

    // ---- butterfly, combinational ------------------------------------------
    wire signed [16:0] s0_re = x_re[0] + x_re[2];
    wire signed [16:0] s0_im = x_im[0] + x_im[2];
    wire signed [16:0] d0_re = x_re[0] - x_re[2];
    wire signed [16:0] d0_im = x_im[0] - x_im[2];

    wire signed [16:0] s1_re = x_re[1] + x_re[3];
    wire signed [16:0] s1_im = x_im[1] + x_im[3];
    wire signed [16:0] d1_re = x_re[1] - x_re[3];
    wire signed [16:0] d1_im = x_im[1] - x_im[3];

    wire signed [17:0] X_re [0:3];
    wire signed [17:0] X_im [0:3];

    assign X_re[0] = s0_re + s1_re;   assign X_im[0] = s0_im + s1_im;
    assign X_re[2] = s0_re - s1_re;   assign X_im[2] = s0_im - s1_im;
    assign X_re[1] = d0_re + d1_im;   assign X_im[1] = d0_im - d1_re;
    assign X_re[3] = d0_re - d1_im;   assign X_im[3] = d0_im + d1_re;

    // ---- round >>2 and saturate back to Q1.15 -------------------------------
    function automatic logic signed [15:0] scale16(input logic signed [17:0] v);
        logic signed [17:0] r;
        begin
            r = (v >>> 2) + (v[1] ? 18'sd1 : 18'sd0);
            if      (r >  18'sd32767) scale16 =  16'sd32767;
            else if (r < -18'sd32768) scale16 = -16'sd32768;
            else                      scale16 = r[15:0];
        end
    endfunction

    wire [127:0] packed_out;
    generate
        for (g = 0; g < 4; g++) begin : g_pack
            assign packed_out[32*g      +: 16] = scale16(X_re[g]);
            assign packed_out[32*g + 16 +: 16] = scale16(X_im[g]);
        end
    endgenerate

    // ---- single register slice, full throughput -----------------------------
    logic [127:0] d_r;
    logic [7:0]   u_r;
    logic         l_r, v_r;

    assign s_axis_tready = ~v_r | m_axis_tready;

    always_ff @(posedge aclk) begin
        if (!aresetn) begin
            v_r <= 1'b0;
        end else if (s_axis_tready) begin
            v_r <= s_axis_tvalid;
            if (s_axis_tvalid) begin
                d_r <= packed_out;
                u_r <= s_axis_tuser + 8'd2;   // divided by 4 -> exponent +2
                l_r <= s_axis_tlast;
            end
        end
    end

    assign m_axis_tdata  = d_r;
    assign m_axis_tvalid = v_r;
    assign m_axis_tlast  = l_r;
    assign m_axis_tuser  = u_r;

endmodule

`default_nettype wire
