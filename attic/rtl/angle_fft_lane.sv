`timescale 1ns / 1ps
`default_nettype none

module angle_fft_lane #(
    parameter int DATA_WIDTH = 32
) (
    input  wire        aclk,
    input  wire        aresetn,

    // Input from CFAR or Doppler pipeline (per antenna channel stream)
    input  wire [DATA_WIDTH-1:0] s_axis_tdata,
    input  wire                  s_axis_tvalid,
    output wire                  s_axis_tready,
    input  wire                  s_axis_tlast,
    input  wire [7:0]            s_axis_tuser,

    // Output 3D Point Cloud Stream (Azimuth/Elevation angle bins)
    output wire [DATA_WIDTH-1:0] m_axis_tdata,
    output wire                  m_axis_tvalid,
    input  wire                  m_axis_tready,
    output wire                  m_axis_tlast,
    output wire [7:0]            m_axis_tuser
);

    // For a 4-channel antenna array, a small 4-point transform can be structured 
    // using pipelined butterfly stages or an instantiated lightweight FFT core.
    // Here we provide the structural AXI-Stream wrapper and data alignment pipeline.

    logic [DATA_WIDTH-1:0] pipe_data  [3:0];
    logic                  pipe_valid [3:0];
    logic                  pipe_last  [3:0];
    logic [7:0]            pipe_tuser [3:0];

    integer i;
    always_ff @(posedge aclk) begin
        if (!aresetn) begin
            for (i = 0; i < 4; i = i + 1) begin
                pipe_data[i]  <= '0;
                pipe_valid[i] <= 1'b0;
                pipe_last[i]  <= 1'b0;
                pipe_tuser[i] <= '0;
            end
        end else if (m_axis_tready) begin
            pipe_data[0]  <= s_axis_tdata;
            pipe_valid[0] <= s_axis_tvalid;
            pipe_last[0]  <= s_axis_tlast;
            pipe_tuser[0] <= s_axis_tuser;

            for (i = 1; i < 4; i = i + 1) begin
                pipe_data[i]  <= pipe_data[i-1];
                pipe_valid[i] <= pipe_valid[i-1];
                pipe_last[i]  <= pipe_last[i-1];
                pipe_tuser[i] <= pipe_tuser[i-1];
            end
        end
    end

    // Output assignment stage (ready for integration with angle-of-arrival processing)
    assign m_axis_tdata  = pipe_data[3];
    assign m_axis_tvalid = pipe_valid[3];
    assign m_axis_tlast  = pipe_last[3];
    assign m_axis_tuser  = pipe_tuser[3];
    assign s_axis_tready = m_axis_tready;

endmodule

`default_nettype wire