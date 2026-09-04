// -----------------------------------------------------------------------------
// fft_config_fsm -- drives the xfft v9.1 configuration channel
//
// Replaces the earlier version, which latched `config_sent` high after the first
// handshake and never re-armed. That made the transform size fixed after reset
// and could not meet the frozen requirement for runtime 1024/2048 switching.
//
// Behaviour:
//   * issues a config word after reset
//   * re-issues whenever nfft_sel_i changes
//   * only ever issues BETWEEN frames -- a mid-frame config write corrupts the
//     transform in progress
//   * holds the sample stream off (gate_input_o) until the core has accepted it
// -----------------------------------------------------------------------------
`timescale 1ns / 1ps
`default_nettype none

module fft_config_fsm #(
    // ---------------------------------------------------------------------
    // Config word layout. VERIFY against PG109 and your generated
    // xfft_0.veo before trusting this -- field order and padding depend on
    // which IP options are enabled, and it is the most version-sensitive
    // part of this block.
    //
    // Assumed here: run-time configurable length, 1 channel, BFP scaling,
    // no cyclic prefix.
    //   [4:0]   NFFT     (5 bits, byte padded to [7:0])
    //   [8]     FWD_INV  (1 = forward, byte padded to [15:8])
    // BFP contributes no scaling schedule field.
    // ---------------------------------------------------------------------
    parameter int CFG_W        = 16,
    parameter int NFFT_LSB     = 0,
    parameter int FWD_INV_LSB  = 8,

    // ---------------------------------------------------------------------
    // Transform sizes selected by nfft_sel_i, as log2(N).
    //   Range   stage: 10 / 11  ->  1024 / 2048
    //   Doppler stage:  7 /  8  ->   128 /  256
    //
    // FIXED 31 Aug: these were hardcoded to 10/11. doppler_lane instantiated
    // this module unchanged, so it was asking the core for a 1024- or
    // 2048-point Doppler transform instead of 128/256. The core would have
    // waited for far more input than a Doppler frame contains and stalled.
    // ---------------------------------------------------------------------
    parameter int NFFT_SEL0    = 10,
    parameter int NFFT_SEL1    = 11
) (
    input  wire             aclk,
    input  wire             aresetn,

    // requested transform size: 0 = 1024 (NFFT=10), 1 = 2048 (NFFT=11)
    input  wire             nfft_sel_i,

    // high while a frame is in flight on the sample input
    input  wire             frame_active_i,

    // xfft configuration channel
    output wire [CFG_W-1:0] m_axis_config_tdata,
    output wire             m_axis_config_tvalid,
    input  wire             m_axis_config_tready,

    // hold samples off while a config write is outstanding
    output wire             gate_input_o,
    output wire [4:0]       nfft_applied_o
);

    logic       cfg_pending;
    logic [4:0] nfft_applied;

    wire [4:0] nfft_req = nfft_sel_i ? 5'(NFFT_SEL1) : 5'(NFFT_SEL0);
    wire       cfg_fire = m_axis_config_tvalid & m_axis_config_tready;

    always_ff @(posedge aclk) begin
        if (!aresetn) begin
            cfg_pending  <= 1'b1;          // always configure once out of reset
            // FIXED 2 Sep: was hardcoded to 5'd10 (1024-point) regardless of
            // NFFT_SEL0/NFFT_SEL1. For doppler_lane (NFFT_SEL0=7) or a smoke
            // test with small overrides, this meant the FSM's very first
            // post-reset comparison always saw a mismatch against the WRONG
            // default, and issued one bogus config request (asking the core
            // for a 1024-point transform) before self-correcting one cycle
            // later. Harmless if the core just ignores/overwrites a
            // superseded config, but if it does not -- e.g. two config
            // writes in quick succession confuse its internal handshake --
            // this is exactly the kind of latent bug that only shows up
            // against the real IP, never in a testbench that only checks
            // this FSM's own outputs in isolation. Parameterized so the
            // reset default always matches what will actually be requested.
            nfft_applied <= 5'(NFFT_SEL0);
        end else begin
            // Re-arm on a size change, but only at a frame boundary.
            if ((nfft_req != nfft_applied) && !frame_active_i) begin
                nfft_applied <= nfft_req;
                cfg_pending  <= 1'b1;
            end else if (cfg_fire) begin
                cfg_pending  <= 1'b0;
            end
        end
    end

    // Build the config word. Unused bits are zero.
    logic [CFG_W-1:0] cfg_word;
    always_comb begin
        cfg_word                             = '0;
        cfg_word[NFFT_LSB   +: 5]            = nfft_applied;
        cfg_word[FWD_INV_LSB]                = 1'b1;      // forward transform
    end

    assign m_axis_config_tdata  = cfg_word;
    assign m_axis_config_tvalid = cfg_pending;
    assign gate_input_o         = cfg_pending;
    assign nfft_applied_o       = nfft_applied;

endmodule

`default_nettype wire
