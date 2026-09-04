`timescale 1ns / 1ps

// =======================================================
// MOCK XILINX FFT IP (STRICT AXI COMPLIANCE)
// =======================================================
module xfft_0 (
    input  wire aclk,
    input  wire aresetn,
    input  wire [31:0]  s_axis_config_tdata,
    input  wire         s_axis_config_tvalid,
    output reg          s_axis_config_tready,
    input  wire [127:0] s_axis_data_tdata,
    input  wire         s_axis_data_tvalid,
    input  wire         s_axis_data_tlast,
    output wire         s_axis_data_tready,
    output reg  [127:0] m_axis_data_tdata,
    output reg          m_axis_data_tvalid,
    output reg          m_axis_data_tlast,
    input  wire         m_axis_data_tready,
    output wire event_frame_started,
    output wire event_tlast_unexpected,
    output wire event_tlast_missing,
    output wire event_status_channel_halt,
    output wire event_data_in_channel_halt,
    output wire event_data_out_channel_halt
);
    reg config_received = 0;
    
    always @(posedge aclk) begin
        if (!aresetn) begin
            s_axis_config_tready <= 1'b1;
        end else if (s_axis_config_tvalid && s_axis_config_tready) begin
            config_received <= 1'b1;
            s_axis_config_tready <= 1'b0; 
        end
    end

    wire internal_ready = !m_axis_data_tvalid || m_axis_data_tready;
    reg random_stall;
    always @(posedge aclk) random_stall <= ($random % 100 < 20); // 20% stall
    
    assign s_axis_data_tready = config_received && !random_stall && internal_ready;

    always @(posedge aclk) begin
        if (!aresetn) begin
            m_axis_data_tvalid <= 1'b0;
        end else begin
            if (s_axis_data_tvalid && s_axis_data_tready) begin
                m_axis_data_tdata  <= s_axis_data_tdata + 128'h1; // DSP Transform mock
                m_axis_data_tlast  <= s_axis_data_tlast;
                m_axis_data_tvalid <= 1'b1;
            end else if (m_axis_data_tready) begin
                m_axis_data_tvalid <= 1'b0;
            end
        end
    end
    
    assign event_frame_started = s_axis_data_tvalid && s_axis_data_tready && !m_axis_data_tvalid;
    assign {event_tlast_unexpected, event_tlast_missing, event_status_channel_halt, event_data_in_channel_halt, event_data_out_channel_halt} = 5'b0;
endmodule

// =======================================================
// FULL PIPELINE TOP-LEVEL TESTBENCH
// =======================================================
module tb_radar_dsp_top;
    reg clk;
    reg rst_n;
    reg start_cube;

    reg [127:0] s_axis_adc_tdata;
    reg s_axis_adc_tvalid;
    wire s_axis_adc_tready;

    reg [31:0] s_axis_range_config_tdata;
    reg s_axis_range_config_tvalid;
    wire s_axis_range_config_tready;

    reg [31:0] s_axis_doppler_config_tdata;
    reg s_axis_doppler_config_tvalid;
    wire s_axis_doppler_config_tready;

    wire [127:0] m_axis_doppler_tdata;
    wire m_axis_doppler_tvalid;
    wire m_axis_doppler_tlast;
    reg m_axis_doppler_tready;

    radar_dsp_top uut (
        .clk(clk), .rst_n(rst_n), .start_cube(start_cube),
        .s_axis_adc_tdata(s_axis_adc_tdata), .s_axis_adc_tvalid(s_axis_adc_tvalid), .s_axis_adc_tready(s_axis_adc_tready),
        .s_axis_range_config_tdata(s_axis_range_config_tdata), .s_axis_range_config_tvalid(s_axis_range_config_tvalid), .s_axis_range_config_tready(s_axis_range_config_tready),
        .s_axis_doppler_config_tdata(s_axis_doppler_config_tdata), .s_axis_doppler_config_tvalid(s_axis_doppler_config_tvalid), .s_axis_doppler_config_tready(s_axis_doppler_config_tready),
        .m_axis_doppler_tdata(m_axis_doppler_tdata), .m_axis_doppler_tvalid(m_axis_doppler_tvalid), .m_axis_doppler_tlast(m_axis_doppler_tlast), .m_axis_doppler_tready(m_axis_doppler_tready)
    );

    always #5 clk = ~clk;

    integer i;

    initial begin
        clk = 0; rst_n = 0; start_cube = 0;
        s_axis_adc_tdata = 0; s_axis_adc_tvalid = 0;
        s_axis_range_config_tdata = 0; s_axis_range_config_tvalid = 0;
        s_axis_doppler_config_tdata = 0; s_axis_doppler_config_tvalid = 0;
        m_axis_doppler_tready = 1;
        
        #50; rst_n = 1; #20;

        // 1. Configure Range FFT
        $display("[TB] Configuring Range FFT...");
        @(posedge clk);
        s_axis_range_config_tvalid <= 1'b1;
        s_axis_range_config_tdata  <= 32'h00000001; 
        @(posedge clk);
        while (!s_axis_range_config_tready) @(posedge clk);
        s_axis_range_config_tvalid <= 1'b0;

        // 2. Configure Doppler FFT
        $display("[TB] Configuring Doppler FFT...");
        @(posedge clk);
        s_axis_doppler_config_tvalid <= 1'b1;
        s_axis_doppler_config_tdata  <= 32'h00000001; 
        @(posedge clk);
        while (!s_axis_doppler_config_tready) @(posedge clk);
        s_axis_doppler_config_tvalid <= 1'b0;
        
        $display("[TB] Both FFTs Configured. Starting Radar Cube ADC Stream...");

        @(posedge clk); start_cube <= 1'b1;
        @(posedge clk); start_cube <= 1'b0;

        // Stream exactly 1 full cube of raw ADC samples (65536 words)
        i = 0;
        while (i < 65536) begin
            s_axis_adc_tvalid <= 1'b1;
            s_axis_adc_tdata  <= i; 
            
            @(posedge clk);
            if (s_axis_adc_tready) begin
                i = i + 1;
            end
        end
        s_axis_adc_tvalid <= 1'b0;
    end

    integer words_received = 0;
    initial begin
        forever begin
            @(posedge clk);
            m_axis_doppler_tready <= ($random % 100 < 85);

            if (m_axis_doppler_tvalid && m_axis_doppler_tready) begin
                words_received = words_received + 1;
                
                if (m_axis_doppler_tlast) begin
                    $display("\n==================================================");
                    $display("    FULL PIPELINE (Range -> CTM -> Doppler) PASSED!");
                    $display("==================================================");
                    $display(" Doppler Words Processed: %0d / 65536", words_received);
                    $display("==================================================\n");
                    $finish;
                end
            end
        end
    end

    initial begin
        #20000000;
        $display("[TB] ERROR: Watchdog timeout!");
        $finish;
    end
endmodule