`timescale 1ns / 1ps
`default_nettype none

module radar_multilane_top #(
    parameter int NUM_LANES = 4,
    parameter int DATA_WIDTH = 32
) (
    input  wire                  aclk,
    input  wire                  aresetn,
    input  wire                  nfft_sel_i,
    input  wire [15:0]           cfar_threshold_i,

    // Multi-channel Input Streams (Array for 4 Antennas)
    input  wire [NUM_LANES-1:0][DATA_WIDTH-1:0] s_axis_tdata,
    input  wire [NUM_LANES-1:0]                 s_axis_tvalid,
    output wire [NUM_LANES-1:0]                 s_axis_tready,
    input  wire [NUM_LANES-1:0]                 s_axis_tlast,

    // Multi-channel Output Streams (CFAR Target Flagged Outputs)
    output wire [NUM_LANES-1:0][DATA_WIDTH-1:0] m_axis_tdata,
    output wire [NUM_LANES-1:0]                 m_axis_tvalid,
    input  wire [NUM_LANES-1:0]                 m_axis_tready,
    output wire [NUM_LANES-1:0]                 m_axis_tlast,
    output wire [NUM_LANES-1:0]                 target_detected_o
);

    // Generate parallel hardware lanes to process all antenna channels simultaneously
    genvar g;
    generate
        for (g = 0; g < NUM_LANES; g = g + 1) begin : gen_radar_lanes

            wire [DATA_WIDTH-1:0] fft_m_tdata;
            wire [7:0]            fft_m_tuser;
            wire                  fft_m_tvalid, fft_m_tready, fft_m_tlast;
            
            wire [DATA_WIDTH-1:0] mag_m_tdata;
            wire                  mag_m_tvalid, mag_m_tready, mag_m_tlast;
            wire [7:0]            mag_m_tuser;

            // 1. Windowed FFT Lane
            fft_lane #(
                .CFG_W(16),
                .STATUS_W(8)
            ) u_fft_lane (
                .aclk           (aclk),
                .aresetn        (aresetn),
                .nfft_sel_i     (nfft_sel_i),
                .nfft_applied_o (),
                .s_axis_tdata   (s_axis_tdata[g]),
                .s_axis_tvalid  (s_axis_tvalid[g]),
                .s_axis_tready  (s_axis_tready[g]),
                .s_axis_tlast   (s_axis_tlast[g]),
                .m_axis_tdata   (fft_m_tdata),
                .m_axis_tuser   (fft_m_tuser),
                .m_axis_tvalid  (fft_m_tvalid),
                .m_axis_tready  (fft_m_tready),
                .m_axis_tlast   (fft_m_tlast),
                .busy_o         (),
                .blk_exp_dbg_o  ()
            );

            // 2. Magnitude-Squared Power Block
            complex_mag2 u_mag2 (
                .aclk           (aclk),
                .aresetn        (aresetn),
                .s_axis_tdata   (fft_m_tdata),
                .s_axis_tvalid  (fft_m_tvalid),
                .s_axis_tready  (fft_m_tready),
                .s_axis_tlast   (fft_m_tlast),
                .s_axis_tuser   (fft_m_tuser),
                .m_axis_tdata   (mag_m_tdata),
                .m_axis_tvalid  (mag_m_tvalid),
                .m_axis_tready  (mag_m_tready),
                .m_axis_tuser   (mag_m_tuser),
                .m_axis_tlast   (mag_m_tlast)
            );

            // 3. CA-CFAR Target Detector
            ca_cfar #(
                .DATA_WIDTH (DATA_WIDTH),
                .LEAD_CELLS (4),
                .TRAIL_CELLS(4),
                .GUARD_CELLS(2)
            ) u_cfar (
                .aclk                (aclk),
                .aresetn             (aresetn),
                .threshold_scale_i   (cfar_threshold_i),
                .s_axis_tdata        (mag_m_tdata),
                .s_axis_tvalid       (mag_m_tvalid),
                .s_axis_tready       (mag_m_tready),
                .s_axis_tlast        (mag_m_tlast),
                .s_axis_tuser        (mag_m_tuser),
                .m_axis_tdata        (m_axis_tdata[g]),
                .m_axis_tvalid       (m_axis_tvalid[g]),
                .m_axis_tready       (m_axis_tready[g]),
                .m_axis_tlast        (m_axis_tlast[g]),
                .m_axis_tuser        (),
                .target_detected_o   (target_detected_o[g])
            );

            assign mag_m_tready = m_axis_tready[g];

        end
    endgenerate

endmodule

`default_nettype wire