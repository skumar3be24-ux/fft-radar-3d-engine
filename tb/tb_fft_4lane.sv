`timescale 1ns / 1ps
`default_nettype none

module tb_fft_4lane;

    // 1. Clock and Reset
    logic aclk;
    logic aresetn;

    always #5 aclk = ~aclk; // 100 MHz clock

    // 2. Interface Signals (Scaled for 4 Lanes: 4 * 32 bits = 128 bits wide)
    logic        nfft_sel_i;
    logic [4:0]  nfft_applied_o;
    logic [3:0]  busy_o;
    logic [31:0] blk_exp_dbg_o; // 8 bits * 4 lanes

    // Input AXI-Stream
    logic [127:0] s_axis_tdata;
    logic [3:0]   s_axis_tvalid;
    logic [3:0]   s_axis_tready;
    logic [3:0]   s_axis_tlast;

    // Output AXI-Stream
    logic [127:0] m_axis_tdata;
    logic [31:0]  m_axis_tuser;
    logic [3:0]   m_axis_tvalid;
    logic [3:0]   m_axis_tready;
    logic [3:0]   m_axis_tlast;  // ADDED: Output TLAST for CTM memory boundaries

    // 3. Instantiate the Device Under Test (DUT)
    fft_engine_top #(
        .NUM_LANES(4),
        .CFG_W(16),
        .STATUS_W(8)
    ) dut (
        .aclk(aclk),
        .aresetn(aresetn),
        .nfft_sel_i(nfft_sel_i),
        .nfft_applied_o(nfft_applied_o),
        .busy_o(busy_o),
        .blk_exp_dbg_o(blk_exp_dbg_o),
        
        .s_axis_tdata(s_axis_tdata),
        .s_axis_tvalid(s_axis_tvalid),
        .s_axis_tready(s_axis_tready),
        .s_axis_tlast(s_axis_tlast),
        
        .m_axis_tdata(m_axis_tdata),
        .m_axis_tuser(m_axis_tuser),
        .m_axis_tvalid(m_axis_tvalid),
        .m_axis_tready(m_axis_tready),
        .m_axis_tlast(m_axis_tlast) // ADDED: Wired to DUT
    );

    // 4. Stimulus Process
    initial begin
        // Initialize everything to zero
        aclk = 0;
        aresetn = 0;
        nfft_sel_i = 0; // 1024-point FFT
        s_axis_tdata = 128'd0;
        s_axis_tvalid = 4'b0000;
        s_axis_tlast = 4'b0000;
        m_axis_tready = 4'b1111; // Always ready to receive output

        // Hold reset
        #100;
        aresetn = 1;
        #50;

        // Fire dummy data into all 4 lanes
        $display("STARTING DATA INJECTION: 4 LANES");
        
        @(posedge aclk);
        s_axis_tvalid = 4'b1111;
        
        // Feed 1024 samples (just a basic loop to test the pipeline)
        for (int i = 0; i < 1024; i++) begin
            // Replicate the counter data across all 4 lanes for tracking
            s_axis_tdata = { {16'd0, i[15:0]}, {16'd0, i[15:0]}, {16'd0, i[15:0]}, {16'd0, i[15:0]} };
            
            if (i == 1023) s_axis_tlast = 4'b1111; // Assert TLAST on the final sample
            else           s_axis_tlast = 4'b0000;

            @(posedge aclk);
            // Brutal reality check: If tready drops, we must stall. 
            // (Skipping full backpressure logic here just to get the pipeline flushed)
        end
        
        s_axis_tvalid = 4'b0000;
        s_axis_tlast = 4'b0000;

        // Wait for FFT to process and flush out
        #50000;
        
        $display("SIMULATION COMPLETE.");
        $finish;
    end

    // 5. Golden Data Extraction
    integer fd;
    initial begin
        fd = $fopen("golden_4lane_out.txt", "w");
        if (fd == 0) begin
            $display("ERROR: Could not open golden file for writing.");
            $finish;
        end
        $fdisplay(fd, "Time_ns, TLAST, TVALID, TDATA_HEX");
    end

    // Monitor the output and write to file
    always @(posedge aclk) begin
        if (m_axis_tvalid && m_axis_tready) begin
            $fdisplay(fd, "%0t, %b, %b, %h", $time, m_axis_tlast, m_axis_tvalid, m_axis_tdata);
        end
    end

endmodule