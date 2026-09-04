`timescale 1ns / 1ps
`default_nettype none

module tb_window;

    logic aclk;
    logic aresetn;

    always #5 aclk = ~aclk;

    // AXI Inputs
    logic [31:0] s_axis_tdata;
    logic        s_axis_tvalid;
    wire         s_axis_tready;
    logic        s_axis_tlast;

    // AXI Outputs
    wire [31:0] m_axis_tdata;
    wire        m_axis_tvalid;
    logic       m_axis_tready;
    wire        m_axis_tlast;

    window_lane dut (
        .aclk(aclk),
        .aresetn(aresetn),
        .s_axis_tdata(s_axis_tdata),
        .s_axis_tvalid(s_axis_tvalid),
        .s_axis_tready(s_axis_tready),
        .s_axis_tlast(s_axis_tlast),
        .m_axis_tdata(m_axis_tdata),
        .m_axis_tvalid(m_axis_tvalid),
        .m_axis_tready(m_axis_tready),
        .m_axis_tlast(m_axis_tlast)
    );

    initial begin
        aclk = 0;
        aresetn = 0;
        s_axis_tdata = 32'd0;
        s_axis_tvalid = 0;
        s_axis_tlast = 0;
        m_axis_tready = 1;

        #100 aresetn = 1;
        #25;
        
        $display("FIRING DATA INTO WINDOW MULTIPLIER...");
        @(posedge aclk);
        s_axis_tvalid = 1;
        
        // Feed 10 samples of '1.0' (7FFF) to check the front edge of the Hanning curve
        for (int i = 0; i < 10; i++) begin
            s_axis_tdata = {16'h7fff, 16'h7fff}; // {Q, I}
            s_axis_tlast = (i == 9);
            @(posedge aclk);
        end
        
        s_axis_tvalid = 0;
        s_axis_tlast = 0;

        #100;
        $display("TEST COMPLETE.");
        $finish;
    end

    // Monitor Output
    always @(posedge aclk) begin
        if (m_axis_tvalid && m_axis_tready) begin
            $display("Time: %0t | TLAST: %b | I_OUT: %h | Q_OUT: %h", 
                     $time, m_axis_tlast, m_axis_tdata[15:0], m_axis_tdata[31:16]);
        end
    end

endmodule