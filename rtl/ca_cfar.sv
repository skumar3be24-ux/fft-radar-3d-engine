`timescale 1ns / 1ps
`default_nettype none

module ca_cfar #(
    parameter int DATA_WIDTH = 32,
    parameter int LEAD_CELLS = 4,   // Number of leading reference cells
    parameter int TRAIL_CELLS= 4,   // Number of trailing reference cells
    parameter int GUARD_CELLS= 2    // Number of guard cells on each side
) (
    input  wire        aclk,
    input  wire        aresetn,

    // Configuration threshold multiplier (e.g., fixed-point scale factor for Pfa)
    input  wire [15:0] threshold_scale_i,

    // Input Power Stream (from complex_mag2)
    input  wire [DATA_WIDTH-1:0] s_axis_tdata,
    input  wire                  s_axis_tvalid,
    output wire                  s_axis_tready,
    input  wire                  s_axis_tlast,
    input  wire [7:0]            s_axis_tuser,

    // Output Detection Stream (1-bit target flag + power data + metadata)
    output wire [DATA_WIDTH-1:0] m_axis_tdata,
    output wire                  m_axis_tvalid,
    input  wire                  m_axis_tready,
    output wire                  m_axis_tlast,
    output wire [7:0]            m_axis_tuser,
    output wire                  target_detected_o // High if CUT exceeds threshold
);

    // Total reference cells
    localparam int REF_CELLS = LEAD_CELLS + TRAIL_CELLS;
    localparam int TOTAL_WINDOW = REF_CELLS + (2 * GUARD_CELLS) + 1;

    // For a clean, synthesizable sliding window without massive multi-port RAMs,
    // we use a shift-register delay line matching the total window size.
    logic [DATA_WIDTH-1:0] window_pipe [TOTAL_WINDOW-1:0];
    logic                  valid_pipe  [TOTAL_WINDOW-1:0];
    logic                  last_pipe   [TOTAL_WINDOW-1:0];
    logic [7:0]            tuser_pipe  [TOTAL_WINDOW-1:0];

    integer i;
    always_ff @(posedge aclk) begin
        if (!aresetn) begin
            for (i = 0; i < TOTAL_WINDOW; i = i + 1) begin
                window_pipe[i] <= '0;
                valid_pipe[i]  <= 1'b0;
                last_pipe[i]   <= 1'b0;
                tuser_pipe[i]  <= '0;
            end
        end else if (m_axis_tready) begin
            window_pipe[0] <= s_axis_tdata;
            valid_pipe[0]  <= s_axis_tvalid;
            last_pipe[0]   <= s_axis_tlast;
            tuser_pipe[0]  <= s_axis_tuser;

            for (i = 1; i < TOTAL_WINDOW; i = i + 1) begin
                window_pipe[i] <= window_pipe[i-1];
                valid_pipe[i]  <= valid_pipe[i-1];
                last_pipe[i]   <= last_pipe[i-1];
                tuser_pipe[i]  <= tuser_pipe[i-1];
            end
        end
    end

    // The Cell Under Test (CUT) sits exactly in the middle of the window pipeline
    localparam int CUT_INDEX = LEAD_CELLS + GUARD_CELLS;
    wire [DATA_WIDTH-1:0] cut_value = window_pipe[CUT_INDEX];

    // Sum up the reference cells (excluding guard cells and CUT)
    // Using combinatorial addition across the leading and trailing reference blocks
    logic [DATA_WIDTH+3:0] noise_sum; // Extra bits to prevent overflow
    
    always_comb begin
        noise_sum = '0;
        // Add leading reference cells
        for (int c = 0; c < LEAD_CELLS; c = c + 1) begin
            noise_sum = noise_sum + window_pipe[c];
        end
        // Add trailing reference cells (skipping guard cells and CUT)
        for (int c = CUT_INDEX + GUARD_CELLS + 1; c < TOTAL_WINDOW; c = c + 1) begin
            noise_sum = noise_sum + window_pipe[c];
        end
    end

    // Calculate threshold: (Noise_Sum / REF_CELLS) * threshold_scale_i
    // Division is a bit-shift, so REF_CELLS must be a power of two.
    //
    // FIXED 31 Aug: the shift was hardcoded to 3 (divide by 8) with a comment
    // "assuming REF_CELLS = 8". Changing LEAD_CELLS or TRAIL_CELLS would then
    // silently scale the threshold wrongly -- detections would still be
    // produced, just at the wrong rate, which is very hard to spot. Derived
    // from the parameters now, with a compile-time check.
    localparam int REF_SHIFT = $clog2(REF_CELLS);

`ifndef SYNTHESIS
    // Simulation-only. A bare `initial $error` can upset synthesis, so it is
    // guarded rather than left in the synthesised source.
    initial begin
        if ((1 << REF_SHIFT) != REF_CELLS)
            $error("ca_cfar: LEAD_CELLS+TRAIL_CELLS (%0d) must be a power of two", REF_CELLS);
    end
`endif

    wire [DATA_WIDTH-1:0] noise_average = noise_sum[DATA_WIDTH+REF_SHIFT-1 -: DATA_WIDTH];
    wire [DATA_WIDTH+15:0] dynamic_threshold = noise_average * threshold_scale_i;

    // Target detection comparison (scaled appropriately)
    // CUT is compared against the threshold
    logic target_flag;
    assign target_flag = ( {16'h0, cut_value} > dynamic_threshold );

    // Output assignment stage
    assign m_axis_tdata  = cut_value;
    assign m_axis_tvalid = valid_pipe[CUT_INDEX];
    assign m_axis_tlast  = last_pipe[CUT_INDEX];
    assign m_axis_tuser  = tuser_pipe[CUT_INDEX];
    assign target_detected_o = target_flag & valid_pipe[CUT_INDEX];
    assign s_axis_tready = m_axis_tready;

endmodule

`default_nettype wire
