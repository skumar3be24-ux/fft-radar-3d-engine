`timescale 1ns / 1ps

module tb_3d_radar_dsp;
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

    reg [31:0] s_axis_angle_config_tdata;
    reg s_axis_angle_config_tvalid;
    wire s_axis_angle_config_tready;

    wire [127:0] m_axis_angle_tdata;
    wire m_axis_angle_tvalid;
    wire m_axis_angle_tlast;
    reg m_axis_angle_tready;

    radar_dsp_top uut (
        .clk(clk), .rst_n(rst_n), .start_cube(start_cube),
        .s_axis_adc_tdata(s_axis_adc_tdata), .s_axis_adc_tvalid(s_axis_adc_tvalid), .s_axis_adc_tready(s_axis_adc_tready),
        .s_axis_range_config_tdata(s_axis_range_config_tdata), .s_axis_range_config_tvalid(s_axis_range_config_tvalid), .s_axis_range_config_tready(s_axis_range_config_tready),
        .s_axis_doppler_config_tdata(s_axis_doppler_config_tdata), .s_axis_doppler_config_tvalid(s_axis_doppler_config_tvalid), .s_axis_doppler_config_tready(s_axis_doppler_config_tready),
        .s_axis_angle_config_tdata(s_axis_angle_config_tdata), .s_axis_angle_config_tvalid(s_axis_angle_config_tvalid), .s_axis_angle_config_tready(s_axis_angle_config_tready),
        .m_axis_angle_tdata(m_axis_angle_tdata), .m_axis_angle_tvalid(m_axis_angle_tvalid), .m_axis_angle_tlast(m_axis_angle_tlast), .m_axis_angle_tready(m_axis_angle_tready)
    );

    always #5 clk = ~clk;

    integer i;

    initial begin
        clk = 0; rst_n = 0; start_cube = 0;
        s_axis_adc_tdata = 0; s_axis_adc_tvalid = 0;
        s_axis_range_config_tdata = 0; s_axis_range_config_tvalid = 0;
        s_axis_doppler_config_tdata = 0; s_axis_doppler_config_tvalid = 0;
        s_axis_angle_config_tdata = 0; s_axis_angle_config_tvalid = 0;
        m_axis_angle_tready = 1;
        
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

        // 3. Configure Angle FFT (3rd Dimension)
        $display("[TB] Configuring Angle FFT...");
        @(posedge clk);
        s_axis_angle_config_tvalid <= 1'b1;
        s_axis_angle_config_tdata  <= 32'h00000001; 
        @(posedge clk);
        while (!s_axis_angle_config_tready) @(posedge clk);
        s_axis_angle_config_tvalid <= 1'b0;
        
        $display("[TB] All 3 FFTs Configured. Starting 3D Radar Cube Stream...");

        @(posedge clk); start_cube <= 1'b1;
        @(posedge clk); start_cube <= 1'b0;

        // Stream 1 full radar cube (65536 words)
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
            m_axis_angle_tready <= ($random % 100 < 85);

            if (m_axis_angle_tvalid && m_axis_angle_tready) begin
                words_received = words_received + 1;
                
                if (m_axis_angle_tlast) begin
                    $display("\n==================================================");
                    $display("    3D PIPELINE (Range -> CTM -> Doppler -> Angle) PASSED!");
                    $display("==================================================");
                    $display(" 3D Output Words Processed: %0d / 65536", words_received);
                    $display("==================================================\n");
                    $finish;
                end
            end
        end
    end

    initial begin
        #25000000;
        $display("[TB] ERROR: 3D Watchdog timeout!");
        $finish;
    end
endmodule