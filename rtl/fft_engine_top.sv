// -----------------------------------------------------------------------------
// fft_engine_top -- NUM_LANES replicated FFT lanes
//
// Block boundary (FFT_ENGINE_BLOCK.md):
//   upstream   : input buffer / corner-turn read  (owned elsewhere)
//   downstream : output processing -- magnitude, framing, packing, DMA
//                                     (owned elsewhere)
//
// This block does NOT contain: window function, magnitude / magnitude-squared,
// frame header, 256-bit packing, width conversion, DMA, DDR. Those are other
// people's blocks. Adding them here would break the agreed division of work
// and hard-code decisions that belong downstream.
//
// Control is exposed as plain ports rather than an AXI-Lite slave, because the
// project already has an AXI-Lite CSR IP (ip_repo/fft_ctrl_axi_1_0). Wire this
// to that rather than duplicating the boilerplate.
//
// Per-lane streams are flattened into single vectors so the module remains
// Verilog-instantiable from a block design.
// -----------------------------------------------------------------------------
`timescale 1ns / 1ps
`default_nettype none

module fft_engine_top #(
    parameter int NUM_LANES = 1,    // one lane per RX antenna / chirp
    parameter int CFG_W     = 16,   // xfft config channel width -- VERIFY
    parameter int STATUS_W  = 8     // xfft status channel width -- VERIFY
) (
    input  wire                        aclk,
    input  wire                        aresetn,

    // ------------------------------------------------------------- control --
    input  wire                        nfft_sel_i,      // 0 = 1024, 1 = 2048
    output wire [4:0]                  nfft_applied_o,
    output wire [NUM_LANES-1:0]        busy_o,
    output wire [8*NUM_LANES-1:0]      blk_exp_dbg_o,   // CSR readback only


    // -------------------------------------------------------- sample input --
    // lane L occupies bits [32*L +: 32]
    input  wire [32*NUM_LANES-1:0]     s_axis_tdata,
    input  wire [NUM_LANES-1:0]        s_axis_tvalid,
    output wire [NUM_LANES-1:0]        s_axis_tready,
    input  wire [NUM_LANES-1:0]        s_axis_tlast,

    // ----------------------------------------------------------- bin output --
    output wire [32*NUM_LANES-1:0]     m_axis_tdata,
    output wire [8*NUM_LANES-1:0]      m_axis_tuser,    // BLK_EXP per lane
    output wire [NUM_LANES-1:0]        m_axis_tvalid,
    input  wire [NUM_LANES-1:0]        m_axis_tready,
    output wire [NUM_LANES-1:0]        m_axis_tlast
);

    wire [4:0] nfft_applied [NUM_LANES-1:0];

    genvar L;
    generate
        for (L = 0; L < NUM_LANES; L = L + 1) begin : g_lane
            fft_lane #(
                .CFG_W   (CFG_W),
                .STATUS_W(STATUS_W)
            ) u_lane (
                .aclk          (aclk),
                .aresetn       (aresetn),

                .nfft_sel_i    (nfft_sel_i),
                .nfft_applied_o(nfft_applied[L]),

                .s_axis_tdata  (s_axis_tdata[32*L +: 32]),
                .s_axis_tvalid (s_axis_tvalid[L]),
                .s_axis_tready (s_axis_tready[L]),
                .s_axis_tlast  (s_axis_tlast[L]),

                .m_axis_tdata  (m_axis_tdata[32*L +: 32]),
                .m_axis_tuser  (m_axis_tuser[8*L +: 8]),
                .m_axis_tvalid (m_axis_tvalid[L]),
                .m_axis_tready (m_axis_tready[L]),
                .m_axis_tlast  (m_axis_tlast[L]),

                .busy_o        (busy_o[L]),
                .blk_exp_dbg_o (blk_exp_dbg_o[8*L +: 8])
            );
        end
    endgenerate

    // All lanes share nfft_sel_i, so lane 0 is representative.
    assign nfft_applied_o = nfft_applied[0];

endmodule

`default_nettype wire
