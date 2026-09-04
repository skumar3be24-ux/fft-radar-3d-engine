`timescale 1ns / 1ps

module radar_dsp_top #(
    parameter DATA_WIDTH = 32,
    parameter RANGE_BINS = 1024,
    parameter CHIRPS_PER_TILE = 64,
    parameter TOTAL_CHIRPS = 256,
    parameter LANES = 4
)(
    input  wire                               clk,
    input  wire                               rst_n,
    input  wire                               start_cube,

    // Upstream AXI-Stream (From ADC)
    input  wire [LANES*DATA_WIDTH-1:0]        s_axis_adc_tdata,
    input  wire                               s_axis_adc_tvalid,
    output wire                               s_axis_adc_tready,

    // FFT Configuration Channels
    input  wire [31:0]                        s_axis_range_config_tdata,
    input  wire                               s_axis_range_config_tvalid,
    output wire                               s_axis_range_config_tready,

    input  wire [31:0]                        s_axis_doppler_config_tdata,
    input  wire                               s_axis_doppler_config_tvalid,
    output wire                               s_axis_doppler_config_tready,

    input  wire [31:0]                        s_axis_angle_config_tdata,
    input  wire                               s_axis_angle_config_tvalid,
    output wire                               s_axis_angle_config_tready,

    // Downstream AXI-Stream (3D Angle FFT Output)
    output wire [LANES*DATA_WIDTH-1:0]        m_axis_angle_tdata,
    output wire                               m_axis_angle_tvalid,
    output wire                               m_axis_angle_tlast,
    input  wire                               m_axis_angle_tready
);

    // =======================================================
    // INTERNAL INTERCONNECT BUSES
    // =======================================================
    wire [LANES*DATA_WIDTH-1:0] range_to_ctm_tdata;
    wire                        range_to_ctm_tvalid;
    wire                        range_to_ctm_tlast;
    wire                        range_to_ctm_tready;

    wire [LANES*DATA_WIDTH-1:0] ctm_to_doppler_tdata;
    wire                        ctm_to_doppler_tvalid;
    wire                        ctm_to_doppler_tlast;
    wire                        ctm_to_doppler_tready;

    wire [LANES*DATA_WIDTH-1:0] doppler_to_angle_tdata;
    wire                        doppler_to_angle_tvalid;
    wire                        doppler_to_angle_tlast;
    wire                        doppler_to_angle_tready;

    // =======================================================
    // 1. RANGE FFT (Fast-Time Transform)
    // =======================================================
    xfft_0 u_range_fft (
        .aclk                  (clk),
        .aresetn               (rst_n),
        .s_axis_config_tdata   (s_axis_range_config_tdata),
        .s_axis_config_tvalid  (s_axis_range_config_tvalid),
        .s_axis_config_tready  (s_axis_range_config_tready),
        .s_axis_data_tdata     (s_axis_adc_tdata),
        .s_axis_data_tvalid    (s_axis_adc_tvalid),
        .s_axis_data_tlast     (1'b0), 
        .s_axis_data_tready    (s_axis_adc_tready),
        .m_axis_data_tdata     (range_to_ctm_tdata),
        .m_axis_data_tvalid    (range_to_ctm_tvalid),
        .m_axis_data_tlast     (range_to_ctm_tlast),
        .m_axis_data_tready    (range_to_ctm_tready),
        .event_frame_started   (),
        .event_tlast_unexpected(),
        .event_tlast_missing   (),
        .event_status_channel_halt(),
        .event_data_in_channel_halt(),
        .event_data_out_channel_halt()
    );

    // =======================================================
    // 2. CORNER TURN MEMORY (CTM Matrix Transpose)
    // =======================================================
    ctm_tiled_pingpong #(
        .DATA_WIDTH(DATA_WIDTH),
        .RANGE_BINS(RANGE_BINS),
        .CHIRPS_PER_TILE(CHIRPS_PER_TILE),
        .TOTAL_CHIRPS(TOTAL_CHIRPS),
        .LANES(LANES)
    ) u_ctm (
        .clk              (clk),
        .rst_n            (rst_n),
        .start_cube       (start_cube),
        .s_axis_data_in   (range_to_ctm_tdata),
        .s_axis_valid_in  (range_to_ctm_tvalid),
        .s_axis_ready_out (range_to_ctm_tready),
        .m_axis_data_out  (ctm_to_doppler_tdata),
        .m_axis_valid_out (ctm_to_doppler_tvalid),
        .m_axis_tlast     (ctm_to_doppler_tlast),
        .m_axis_ready_in  (ctm_to_doppler_tready)
    );

    // =======================================================
    // 3. DOPPLER FFT (Slow-Time Transform)
    // =======================================================
    xfft_0 u_doppler_fft (
        .aclk                  (clk),
        .aresetn               (rst_n),
        .s_axis_config_tdata   (s_axis_doppler_config_tdata),
        .s_axis_config_tvalid  (s_axis_doppler_config_tvalid),
        .s_axis_config_tready  (s_axis_doppler_config_tready),
        .s_axis_data_tdata     (ctm_to_doppler_tdata),
        .s_axis_data_tvalid    (ctm_to_doppler_tvalid),
        .s_axis_data_tlast     (ctm_to_doppler_tlast),
        .s_axis_data_tready    (ctm_to_doppler_tready),
        .m_axis_data_tdata     (doppler_to_angle_tdata),
        .m_axis_data_tvalid    (doppler_to_angle_tvalid),
        .m_axis_data_tlast     (doppler_to_angle_tlast),
        .m_axis_data_tready    (doppler_to_angle_tready),
        .event_frame_started   (),
        .event_tlast_unexpected(),
        .event_tlast_missing   (),
        .event_status_channel_halt(),
        .event_data_in_channel_halt(),
        .event_data_out_channel_halt()
    );

    // =======================================================
    // 4. ANGLE FFT (Spatial/Azimuth Transform - 3rd Dimension)
    // =======================================================
    xfft_0 u_angle_fft (
        .aclk                  (clk),
        .aresetn               (rst_n),
        .s_axis_config_tdata   (s_axis_angle_config_tdata),
        .s_axis_config_tvalid  (s_axis_angle_config_tvalid),
        .s_axis_config_tready  (s_axis_angle_config_tready),
        .s_axis_data_tdata     (doppler_to_angle_tdata),
        .s_axis_data_tvalid    (doppler_to_angle_tvalid),
        .s_axis_data_tlast     (doppler_to_angle_tlast),
        .s_axis_data_tready    (doppler_to_angle_tready),
        .m_axis_data_tdata     (m_axis_angle_tdata),
        .m_axis_data_tvalid    (m_axis_angle_tvalid),
        .m_axis_data_tlast     (m_axis_angle_tlast),
        .m_axis_data_tready    (m_axis_angle_tready),
        .event_frame_started   (),
        .event_tlast_unexpected(),
        .event_tlast_missing   (),
        .event_status_channel_halt(),
        .event_data_in_channel_halt(),
        .event_data_out_channel_halt()
    );

endmodule