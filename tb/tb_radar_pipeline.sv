`timescale 1ns / 1ps
`default_nettype none

module tb_radar_pipeline;

    // Clock and Reset
    logic aclk = 0;
    logic aresetn = 0;

    always #5 aclk = ~aclk; // 100 MHz clock (10ns period)

    // Control & Configuration
    logic nfft_sel_i = 1'b0; // 1024-point FFT
    logic [4:0] nfft_applied;
    logic [15:0] cfar_threshold = 16'h0008; // Sensitive threshold scale factor

    // Input Stream (to FFT lane)
    logic [31:0] s_axis_tdata = '0;
    logic        s_axis_tvalid = 0;
    logic        s_axis_tready;
    logic        s_axis_tlast = 0;

    // Intermediate 1: FFT Lane Output -> Magnitude Squared Input
    wire [31:0] fft_m_tdata;
    wire [7:0]  fft_m_tuser;
    wire        fft_m_tvalid, fft_m_tready, fft_m_tlast;
    wire        fft_busy;
    wire [7:0]  blk_exp_dbg;

    // Intermediate 2: Magnitude Squared Output -> CA-CFAR Input
    wire [31:0] mag_m_tdata;
    wire        mag_m_tvalid, mag_m_tready, mag_m_tlast;
    wire [7:0]  mag_m_tuser;

    // CFAR Outputs
    wire [31:0] cfar_m_tdata;
    wire        cfar_m_tvalid, cfar_m_tready, cfar_m_tlast;
    wire [7:0]  cfar_m_tuser;
    wire        target_detected;

    // -------------------------------------------------------------------------
    // Instantiate Block 1: Windowed FFT Lane
    // -------------------------------------------------------------------------
    fft_lane #(
        .CFG_W(16),
        .STATUS_W(8)
    ) u_fft_lane (
        .aclk           (aclk),
        .aresetn        (aresetn),
        .nfft_sel_i     (nfft_sel_i),
        .nfft_applied_o (nfft_applied),
        .s_axis_tdata   (s_axis_tdata),
        .s_axis_tvalid  (s_axis_tvalid),
        .s_axis_tready  (s_axis_tready),
        .s_axis_tlast   (s_axis_tlast),
        .m_axis_tdata   (fft_m_tdata),
        .m_axis_tuser   (fft_m_tuser),
        .m_axis_tvalid  (fft_m_tvalid),
        .m_axis_tready  (fft_m_tready),
        .m_axis_tlast   (fft_m_tlast),
        .busy_o         (fft_busy),
        .blk_exp_dbg_o  (blk_exp_dbg)
    );

    // -------------------------------------------------------------------------
    // Instantiate Block 2: Magnitude-Squared Power Calculator (I^2 + Q^2)
    // -------------------------------------------------------------------------
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

    // -------------------------------------------------------------------------
    // Instantiate Block 3: CA-CFAR Target Detector
    // -------------------------------------------------------------------------
    ca_cfar #(
        .DATA_WIDTH (32),
        .LEAD_CELLS (4),
        .TRAIL_CELLS(4),
        .GUARD_CELLS(2)
    ) u_cfar (
        .aclk                (aclk),
        .aresetn             (aresetn),
        .threshold_scale_i   (cfar_threshold),
        .s_axis_tdata        (mag_m_tdata),
        .s_axis_tvalid       (mag_m_tvalid),
        .s_axis_tready       (mag_m_tready),
        .s_axis_tlast        (mag_m_tlast),
        .s_axis_tuser        (mag_m_tuser),
        .m_axis_tdata        (cfar_m_tdata),
        .m_axis_tvalid       (cfar_m_tvalid),
        .m_axis_tready       (cfar_m_tready),
        .m_axis_tlast        (cfar_m_tlast),
        .m_axis_tuser        (cfar_m_tuser),
        .target_detected_o   (target_detected)
    );

    // Backpressure consumer (always ready to accept data)
    assign cfar_m_tready = 1'b1;

    // -------------------------------------------------------------------------
    // Test Stimulus Drive
    // -------------------------------------------------------------------------
    initial begin
        $display("STARTING FULL RADAR PIPELINE SIMULATION...");
        
        // Reset sequence
        aresetn = 0;
        #100;
        aresetn = 1;
        #50;

        @(posedge aclk);

        // Inject a full 1024-sample frame of baseband chirps
        for (int i = 0; i < 1024; i++) begin
            @(posedge aclk);
            while (!s_axis_tready) @(posedge aclk);

            s_axis_tvalid = 1'b1;
            
            // Inject a simulated target tone cluster around bin 42
            if ((i >= 38) && (i <= 46)) begin
                s_axis_tdata = 32'h7FFF7FFF; // High amplitude target peak
            end else begin
                s_axis_tdata = 32'h00100010; // Low noise floor
            end

            if (i == 1023) begin
                s_axis_tlast = 1'b1;
            end else begin
                s_axis_tlast = 1'b0;
            end
        end

        @(posedge aclk);
        s_axis_tvalid = 0;
        s_axis_tlast  = 0;

        // Extended execution window allowing pipeline latency to clear through CFAR
        #35000;
        $display("PIPELINE SIMULATION COMPLETE.");
        $finish;
    end

    // Monitor Target Detections
    always @(posedge aclk) begin
        if (target_detected) begin
            $display("[RADAR TARGET DETECTED!] Time: %0t ns | Power Data: 0x%08X", $time, cfar_m_tdata);
        end
    end

endmodule

`default_nettype wire