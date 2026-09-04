`timescale 1ns / 1ps

module tb_ctm;
    reg clk;
    reg rst_n;
    reg start_cube;
    reg [127:0] s_axis_data_in;
    reg s_axis_valid_in;
    wire s_axis_ready_out;
    wire [127:0] m_axis_data_out;
    wire m_axis_valid_out;
    wire m_axis_tlast;
    reg m_axis_ready_in;

    ctm_tiled_pingpong uut (
        .clk(clk), .rst_n(rst_n), .start_cube(start_cube),
        .s_axis_data_in(s_axis_data_in), .s_axis_valid_in(s_axis_valid_in), .s_axis_ready_out(s_axis_ready_out),
        .m_axis_data_out(m_axis_data_out), .m_axis_valid_out(m_axis_valid_out), .m_axis_tlast(m_axis_tlast), .m_axis_ready_in(m_axis_ready_in)
    );

    always #5 clk = ~clk;

    // Upstream Transmission Task (with randomized throttling)
    task send_word(input [127:0] data);
        begin
            s_axis_valid_in <= 1'b1;
            s_axis_data_in  <= data;
            @(posedge clk);
            while (!s_axis_ready_out) @(posedge clk); // Wait if ping-pong is full
            s_axis_valid_in <= 1'b0;
            
            // Randomly simulate ADC/upstream bottlenecks (20% chance to pause)
            if ($random % 100 < 20) repeat ($random % 3) @(posedge clk);
        end
    endtask

    integer i;

    // Main Stimulus
    initial begin
        clk = 0; rst_n = 0; start_cube = 0; 
        s_axis_data_in = 0; s_axis_valid_in = 0; 
        
        #50; rst_n = 1; #20;

        // Flush pipeline
        @(posedge clk); start_cube <= 1'b1;
        @(posedge clk); start_cube <= 1'b0;

        $display("[TB] Streaming TWO FULL CUBES (131,072 words) with randomized bottlenecks...");
        
        for (i = 0; i < 131072; i = i + 1) begin
            send_word({32'h3, 32'h2, 32'h1, 32'h0} + i);
        end

        $display("[TB] Transmission complete. Waiting for downstream to drain...");
    end

    // Random Backpressure Generator (Simulates FFT stalls)
    initial begin
        m_axis_ready_in = 1;
        #100;
        forever begin
            @(posedge clk);
            // Randomly simulate FFT processing stalls (30% chance to pause)
            if ($random % 100 < 30) begin
                m_axis_ready_in <= 0;
                repeat ($random % 5) @(posedge clk);
                m_axis_ready_in <= 1;
            end
        end
    end

    // Downstream Verification Monitor
    integer read_count = 0;
    initial begin
        forever begin
            @(posedge clk);
            if (m_axis_valid_out && m_axis_ready_in) begin
                // Check if the data exactly matches what was injected
                if (m_axis_data_out !== {32'h3, 32'h2, 32'h1, 32'h0} + read_count) begin
                    $display("==================================================");
                    $display("[FAIL] DATA CORRUPTION DETECTED at word %0d!", read_count);
                    $display("       Expected: %h", {32'h3, 32'h2, 32'h1, 32'h0} + read_count);
                    $display("       Received: %h", m_axis_data_out);
                    $display("==================================================");
                    $finish;
                end
                
                if (m_axis_tlast) $display("[TB] Received TLAST at word %0d (Cube Boundary)", read_count);

                read_count = read_count + 1;
                
                // If we safely drain all 131,072 words across the ping-pong banks
                if (read_count == 131072) begin
                    $display("\n==================================================");
                    $display("       TRUE PING-PONG VERIFICATION PASSED         ");
                    $display("==================================================");
                    $display(" Total Words Verified: %0d", read_count);
                    $display(" Backpressure Survived: YES");
                    $display("==================================================\n");
                    $finish;
                end
            end
        end
    end

    initial begin
        #30000000;
        $display("[TB] ERROR: Watchdog timeout!");
        $finish;
    end
endmodule