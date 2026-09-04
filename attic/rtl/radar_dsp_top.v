module radar_dsp_top (
    input  wire        clk,
    input  wire        rst_n,
    // Input from ADC / Range stage
    input  wire [31:0] s_axis_data_tdata,
    input  wire        s_axis_data_tvalid,
    output wire        s_axis_data_tready,
    
    // Final 3D Radar Output (Range -> Doppler -> Angle)
    output wire [31:0] m_axis_tdata,
    output wire        m_axis_tvalid,
    input  wire        m_axis_tready
);

    // Internal wires for pipeline stages
    wire [31:0] doppler_out_tdata;
    wire        doppler_out_tvalid;
    wire        doppler_out_tready;

    // Stage 1 & 2: Range & Doppler Processing Core (Placeholder / Existing logic integration)
    // Assuming intermediate stream passes through or connects from prior FFT instance
    assign doppler_out_tdata  = s_axis_data_tdata;
    assign doppler_out_tvalid = s_axis_data_tvalid;
    assign s_axis_data_tready = doppler_out_tready;

    // Stage 3: Angle FFT Instance Integration (8-point Xilinx IP configured for spatial data)
    angle_fft_0 u_angle_fft (
        .aclk(clk),
        .s_axis_config_tdata(8'b00000001), // Forward FFT configuration
        .s_axis_config_tvalid(1'b1),
        .s_axis_config_tready(),
        .s_axis_data_tdata(doppler_out_tdata),
        .s_axis_data_tvalid(doppler_out_tvalid),
        .s_axis_data_tready(doppler_out_tready),
        .m_axis_data_tdata(m_axis_tdata),
        .m_axis_data_tvalid(m_axis_tvalid),
        .m_axis_data_tready(m_axis_tready)
    );

endmodule