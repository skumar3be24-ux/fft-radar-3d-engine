`timescale 1ns / 1ps

module tb_radar_dsp_top;

    parameter NUM_RX_CHANNELS = 4;
    parameter CLK_PERIOD = 10; // 100 MHz clock

    logic clk;
    logic rst_n;
    
    // 4-Channel Parallel AXI-Stream Inputs
    logic [31:0] s_axis_tdata [0:NUM_RX_CHANNELS-1];
    logic        s_axis_tvalid [0:NUM_RX_CHANNELS-1];
    logic        s_axis_tready [0:NUM_RX_CHANNELS-1]; // FIX: Removed [31:0] here
    
    // 4-Channel Parallel AXI-Stream Outputs
    logic [31:0] m_axis_tdata [0:NUM_RX_CHANNELS-1];
    logic        m_axis_tvalid [0:NUM_RX_CHANNELS-1];
    logic        m_axis_tready [0:NUM_RX_CHANNELS-1];

    // Instantiate the Top-Level DUT
    radar_dsp_top #(
        .NUM_RX_CHANNELS(NUM_RX_CHANNELS)
    ) dut (
        .clk(clk),
        .rst_n(rst_n),
        .s_axis_tdata(s_axis_tdata),
        .s_axis_tvalid(s_axis_tvalid),
        .s_axis_tready(s_axis_tready),
        .m_axis_tdata(m_axis_tdata),
        .m_axis_tvalid(m_axis_tvalid),
        .m_axis_tready(m_axis_tready)
    );

    // Clock Generation
    initial begin
        clk = 0;
        forever #(CLK_PERIOD / 2) clk = ~clk;
    end

    // Test Stimulus
    integer i, ch;
    initial begin
        rst_n = 0;
        for (ch = 0; ch < NUM_RX_CHANNELS; ch = ch + 1) begin
            s_axis_tvalid[ch] = 0;
            s_axis_tdata[ch]  = 32'b0;
            m_axis_tready[ch] = 1;
        end
        
        #(CLK_PERIOD * 10);
        rst_n = 1;
        #(CLK_PERIOD * 5);

        // Stream synthetic radar chirps into all 4 channels simultaneously
        for (i = 0; i < 1024; i = i + 1) begin
            @(posedge clk);
            for (ch = 0; ch < NUM_RX_CHANNELS; ch = ch + 1) begin
                s_axis_tvalid[ch] = 1'b1;
                // Inject simple alternating tone pattern as dummy IQ data
                s_axis_tdata[ch]  = {16'd100 * (ch + 1), 16'd50 * i}; 
            end
        end

        // Deassert valid after one full range profile
        @(posedge clk);
        for (ch = 0; ch < NUM_RX_CHANNELS; ch = ch + 1) begin
            s_axis_tvalid[ch] = 0;
            s_axis_tdata[ch]  = 32'b0;
        end

        #(CLK_PERIOD * 200);
        $finish;
    end

endmodule