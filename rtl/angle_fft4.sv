// -----------------------------------------------------------------------------
// angle_fft4 -- true 4-point DFT across the RX antenna axis
//
// Replaces the previous placeholder in angle_fft_lane.sv, which was a 4-deep
// shift register and performed no transform at all.
//
// WHY THIS IS NOT AN xfft IP INSTANCE
//   The Xilinx FFT core has a hard minimum transform length of 8. More
//   importantly, a 4-point DFT needs NO MULTIPLIERS: its twiddles are
//   1, -j, -1, +j, all of which are sign flips and real/imaginary swaps.
//   Streaming a 4-point transform through a pipelined IP would cost a deep
//   fixed pipeline and a whole core to perform sixteen additions.
//
// MATHS
//   X[k] = sum_{n=0..3} x[n] * W^(nk),  W = exp(-j2pi/4) = -j
//
//   Decimation in time:
//     s0 = x0 + x2      d0 = x0 - x2
//     s1 = x1 + x3      d1 = x1 - x3
//
//     X[0] = s0 + s1
//     X[2] = s0 - s1
//     X[1] = d0 - j*d1
//     X[3] = d0 + j*d1
//
//   and for a complex value (a + jb):
//     -j*(a + jb) =  b - ja     (re =  b, im = -a)
//     +j*(a + jb) = -b + ja     (re = -b, im =  a)
//
//   so
//     X[1].re = d0.re + d1.im     X[1].im = d0.im - d1.re
//     X[3].re = d0.re - d1.im     X[3].im = d0.im + d1.re
//
//   Total cost: 16 real adders. Zero DSP48. Zero BRAM.
//
// BIT GROWTH AND BLK_EXP
//   A 4-point DFT has a processing gain of up to 4, i.e. 2 bits. Inputs are
//   Q1.15, so full-precision outputs need 18 bits. To keep the frozen 32-bit
//   {Im,Re} interface we round and shift right by 2, returning to Q1.15, and
//   INCREMENT THE BLOCK EXPONENT BY 2 to compensate:
//
//       m_axis_tuser = s_axis_tuser + 2
//
//   Getting this wrong gives a plausible-looking magnitude that is off by 4x.
//   Rounding is round-half-away-from-zero, then saturated.
//
// INTERFACE
//   Serial in, serial out: four consecutive beats are the four antennas of one
//   (range, Doppler) cell; four consecutive beats out are its four angle bins.
//   Ping-pong buffered, so it sustains one beat per clock with no bubbles.
//   TLAST on the fourth input beat propagates to the fourth output beat.
// -----------------------------------------------------------------------------
`timescale 1ns / 1ps
`default_nettype none

module angle_fft4 (
    input  wire        aclk,
    input  wire        aresetn,

    // one beat per antenna, 4 beats = one cell
    input  wire [31:0] s_axis_tdata,    // {Im[15:0], Re[15:0]} Q1.15
    input  wire        s_axis_tvalid,
    output wire        s_axis_tready,
    input  wire        s_axis_tlast,
    input  wire [7:0]  s_axis_tuser,    // BLK_EXP in

    // 4 beats = 4 angle bins of that cell
    output wire [31:0] m_axis_tdata,
    output wire        m_axis_tvalid,
    input  wire        m_axis_tready,
    output wire        m_axis_tlast,
    output wire [7:0]  m_axis_tuser     // BLK_EXP + 2
);

    // ---------------------------------------------------------- ping-pong ----
    logic signed [15:0] buf_re [0:1][0:3];
    logic signed [15:0] buf_im [0:1][0:3];
    logic [7:0]         buf_exp[0:1];
    logic               buf_last[0:1];
    logic               buf_full[0:1];

    logic       wr_sel, rd_sel;
    logic [1:0] wr_cnt, rd_cnt;

    assign s_axis_tready = ~buf_full[wr_sel];
    wire in_fire  = s_axis_tvalid & s_axis_tready;
    wire out_fire = m_axis_tvalid & m_axis_tready;

    // ---------------------------------------------------------- collect -----
    always_ff @(posedge aclk) begin
        if (!aresetn) begin
            wr_sel <= 1'b0;
            wr_cnt <= 2'd0;
        end else if (in_fire) begin
            buf_re[wr_sel][wr_cnt] <= s_axis_tdata[15:0];
            buf_im[wr_sel][wr_cnt] <= s_axis_tdata[31:16];
            if (wr_cnt == 2'd0) buf_exp[wr_sel] <= s_axis_tuser;
            if (wr_cnt == 2'd3) begin
                buf_last[wr_sel] <= s_axis_tlast;
                wr_cnt <= 2'd0;
                wr_sel <= ~wr_sel;
            end else begin
                wr_cnt <= wr_cnt + 2'd1;
            end
        end
    end

    // ---------------------------------------------------------- full flags --
    wire set_full = in_fire  && (wr_cnt == 2'd3);
    wire clr_full = out_fire && (rd_cnt == 2'd3);

    always_ff @(posedge aclk) begin
        if (!aresetn) begin
            buf_full[0] <= 1'b0;
            buf_full[1] <= 1'b0;
        end else begin
            if (set_full) buf_full[wr_sel] <= 1'b1;
            if (clr_full) buf_full[rd_sel] <= 1'b0;
        end
    end

    // ---------------------------------------------------------- butterfly ---
    // Combinational, from the buffer currently being read. 18-bit intermediates.
    logic signed [16:0] s0_re, s0_im, s1_re, s1_im;
    logic signed [16:0] d0_re, d0_im, d1_re, d1_im;

    always_comb begin
        s0_re = $signed(buf_re[rd_sel][0]) + $signed(buf_re[rd_sel][2]);
        s0_im = $signed(buf_im[rd_sel][0]) + $signed(buf_im[rd_sel][2]);
        d0_re = $signed(buf_re[rd_sel][0]) - $signed(buf_re[rd_sel][2]);
        d0_im = $signed(buf_im[rd_sel][0]) - $signed(buf_im[rd_sel][2]);

        s1_re = $signed(buf_re[rd_sel][1]) + $signed(buf_re[rd_sel][3]);
        s1_im = $signed(buf_im[rd_sel][1]) + $signed(buf_im[rd_sel][3]);
        d1_re = $signed(buf_re[rd_sel][1]) - $signed(buf_re[rd_sel][3]);
        d1_im = $signed(buf_im[rd_sel][1]) - $signed(buf_im[rd_sel][3]);
    end

    logic signed [17:0] x_re [0:3];
    logic signed [17:0] x_im [0:3];

    always_comb begin
        x_re[0] = s0_re + s1_re;        x_im[0] = s0_im + s1_im;   // X[0]
        x_re[2] = s0_re - s1_re;        x_im[2] = s0_im - s1_im;   // X[2]
        x_re[1] = d0_re + d1_im;        x_im[1] = d0_im - d1_re;   // X[1] = d0 - j*d1
        x_re[3] = d0_re - d1_im;        x_im[3] = d0_im + d1_re;   // X[3] = d0 + j*d1
    end

    // ---------------------------------------------------------- scale -------
    // >>2 with round-half-away-from-zero, then saturate to 16 bits.
    function automatic logic signed [15:0] scale16(input logic signed [17:0] v);
        logic signed [17:0] r;
        begin
            r = (v >>> 2) + ((v[1]) ? 18'sd1 : 18'sd0);   // round on bit 1
            if      (r >  18'sd32767) scale16 =  16'sd32767;
            else if (r < -18'sd32768) scale16 = -16'sd32768;
            else                      scale16 = r[15:0];
        end
    endfunction

    wire signed [15:0] out_re = scale16(x_re[rd_cnt]);
    wire signed [15:0] out_im = scale16(x_im[rd_cnt]);

    // ---------------------------------------------------------- emit --------
    always_ff @(posedge aclk) begin
        if (!aresetn) begin
            rd_sel <= 1'b0;
            rd_cnt <= 2'd0;
        end else if (out_fire) begin
            if (rd_cnt == 2'd3) begin
                rd_cnt <= 2'd0;
                rd_sel <= ~rd_sel;
            end else begin
                rd_cnt <= rd_cnt + 2'd1;
            end
        end
    end

    assign m_axis_tvalid = buf_full[rd_sel];
    assign m_axis_tdata  = {out_im, out_re};
    assign m_axis_tlast  = buf_last[rd_sel] && (rd_cnt == 2'd3);

    // Data was divided by 4, so the shared exponent grows by 2.
    assign m_axis_tuser  = buf_exp[rd_sel] + 8'd2;

endmodule

`default_nettype wire
