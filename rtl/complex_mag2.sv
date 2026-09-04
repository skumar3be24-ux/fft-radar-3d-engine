// -----------------------------------------------------------------------------
// complex_mag2 -- |X|^2 = Re^2 + Im^2, 32-bit unsigned
//
// FIXED 31 Aug: the previous version computed
//     re_sq     <= re_q1 * re_q1;
//     im_sq     <= im_q1 * im_q1;
//     power_sum <= (re_q1 * re_q1) + (im_q1 * im_q1);   // RECOMPUTED
// re_sq/im_sq were never read, and the squares appeared twice, inferring up to
// four multipliers where two are needed. Now: multiply in stage 2, accumulate in
// stage 3, which is also the shape that maps onto a DSP48E1 PCIN cascade.
//
// WIDTH
//   Inputs are signed Q1.15. Worst case is (-32768)^2 + (-32768)^2 = 2^30 + 2^30
//   = 2^31, so the output must be 32-bit UNSIGNED. 31 bits is not enough --
//   this was recorded as spec error #4 early in the project.
//
// SCALE
//   tuser carries BLK_EXP for the complex input. After squaring the true scale
//   is 2^(2*BLK_EXP). tuser is passed through UNCHANGED; the consumer must
//   double it. Documented here because it is invisible at the interface.
// -----------------------------------------------------------------------------
`timescale 1ns / 1ps
`default_nettype none

module complex_mag2 (
    input  wire        aclk,
    input  wire        aresetn,

    // Input AXI-Stream (Complex: {Im[15:0], Re[15:0]})
    input  wire [31:0] s_axis_tdata,
    input  wire        s_axis_tvalid,
    output wire        s_axis_tready,
    input  wire        s_axis_tlast,
    input  wire [7:0]  s_axis_tuser,   // BLK_EXP passthrough

    // Output AXI-Stream (32-bit unsigned magnitude-squared)
    output wire [31:0] m_axis_tdata,
    output wire        m_axis_tvalid,
    input  wire        m_axis_tready,
    output wire [7:0]  m_axis_tuser,
    output wire        m_axis_tlast
);

    wire signed [15:0] re_in = s_axis_tdata[15:0];
    wire signed [15:0] im_in = s_axis_tdata[31:16];

    // ---- stage 1: capture ---------------------------------------------------
    logic signed [15:0] re_q1, im_q1;
    logic               valid_q1, last_q1;
    logic [7:0]         tuser_q1;

    always_ff @(posedge aclk) begin
        if (!aresetn) begin
            valid_q1 <= 1'b0;
            last_q1  <= 1'b0;
        end else if (m_axis_tready) begin
            re_q1    <= re_in;
            im_q1    <= im_in;
            valid_q1 <= s_axis_tvalid;
            last_q1  <= s_axis_tlast;
            tuser_q1 <= s_axis_tuser;
        end
    end

    // ---- stage 2: two multipliers, once each --------------------------------
    logic [30:0] re_sq, im_sq;          // max (2^15)^2 = 2^30 -> 31 bits
    logic        valid_q2, last_q2;
    logic [7:0]  tuser_q2;

    always_ff @(posedge aclk) begin
        if (!aresetn) begin
            valid_q2 <= 1'b0;
            last_q2  <= 1'b0;
        end else if (m_axis_tready) begin
            re_sq    <= re_q1 * re_q1;
            im_sq    <= im_q1 * im_q1;
            valid_q2 <= valid_q1;
            last_q2  <= last_q1;
            tuser_q2 <= tuser_q1;
        end
    end

    // ---- stage 3: accumulate ------------------------------------------------
    logic [31:0] power_sum;             // 2^30 + 2^30 = 2^31 -> 32 bits
    logic        valid_q3, last_q3;
    logic [7:0]  tuser_q3;

    always_ff @(posedge aclk) begin
        if (!aresetn) begin
            valid_q3 <= 1'b0;
            last_q3  <= 1'b0;
        end else if (m_axis_tready) begin
            power_sum <= {1'b0, re_sq} + {1'b0, im_sq};
            valid_q3  <= valid_q2;
            last_q3   <= last_q2;
            tuser_q3  <= tuser_q2;
        end
    end

    assign m_axis_tdata  = power_sum;
    assign m_axis_tvalid = valid_q3;
    assign m_axis_tlast  = last_q3;
    assign m_axis_tuser  = tuser_q3;
    assign s_axis_tready = m_axis_tready;

endmodule

`default_nettype wire
