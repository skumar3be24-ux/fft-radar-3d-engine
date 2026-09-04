`timescale 1ns / 1ps
`default_nettype none

module window_lane (
    input  wire        aclk,
    input  wire        aresetn,

    // Input AXI-Stream (Raw ADC data: {Q, I})
    input  wire [31:0] s_axis_tdata,
    input  wire        s_axis_tvalid,
    output wire        s_axis_tready,
    input  wire        s_axis_tlast,

    // Output AXI-Stream (Windowed data: {Q, I})
    output wire [31:0] m_axis_tdata,
    output wire        m_axis_tvalid,
    input  wire        m_axis_tready,
    output wire        m_axis_tlast
);

    // 1. Coefficient ROM (Inferred Block RAM)
    logic [15:0] hanning_rom [0:1023];
    initial begin
        // Path is relative to where xvlog/xsim is executed
        $readmemh("rtl/hanning_1024.mem", hanning_rom); 
    end

    // 2. Address Counter
    logic [9:0] addr_cnt;
    
    always_ff @(posedge aclk) begin
        if (!aresetn) begin
            addr_cnt <= '0;
        end else if (s_axis_tvalid && s_axis_tready) begin
            if (s_axis_tlast) addr_cnt <= '0;
            else              addr_cnt <= addr_cnt + 1;
        end
    end

    // 3. Pipeline Stage 1: Memory Read & Data Capture
    logic signed [15:0] coeff_q;
    logic signed [15:0] data_i_q, data_q_q;
    logic valid_q1, last_q1;

    always_ff @(posedge aclk) begin
        if (!aresetn) begin
            valid_q1 <= 1'b0;
            last_q1  <= 1'b0;
        end else if (m_axis_tready) begin // Stalls entire pipeline if downstream is not ready
            coeff_q  <= hanning_rom[addr_cnt];
            data_i_q <= s_axis_tdata[15:0];
            data_q_q <= s_axis_tdata[31:16];
            valid_q1 <= s_axis_tvalid;
            last_q1  <= s_axis_tlast;
        end
    end

    // 4. Pipeline Stage 2: Hardware DSP Multipliers
    logic signed [31:0] mult_i, mult_q;
    logic valid_q2, last_q2;

    always_ff @(posedge aclk) begin
        if (!aresetn) begin
            valid_q2 <= 1'b0;
            last_q2  <= 1'b0;
        end else if (m_axis_tready) begin
            mult_i   <= data_i_q * coeff_q; // Inferred DSP48
            mult_q   <= data_q_q * coeff_q; // Inferred DSP48
            valid_q2 <= valid_q1;
            last_q2  <= last_q1;
        end
    end

    // 5. Output Formatting (Bit Slicing)
    // Brutal math reality: Q1.15 multiplied by Q1.15 yields Q2.30.
    // To drop back to Q1.15 for the FFT engine, we slice bits [30:15].
    assign m_axis_tdata  = {mult_q[30:15], mult_i[30:15]};
    assign m_axis_tvalid = valid_q2;
    assign m_axis_tlast  = last_q2;

    // Backpressure routing
    assign s_axis_tready = m_axis_tready;

endmodule