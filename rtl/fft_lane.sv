// -----------------------------------------------------------------------------
// fft_lane -- one FFT lane: skid in, window, xfft v9.1, status capture, skid out
//
// Interface contract (see FFT_ENGINE_BLOCK.md section 2):
//   in  : 32-bit {Q[15:0], I[15:0]} Q1.15 complex samples, TLAST on sample N-1
//   out : 32-bit {Im[15:0], Re[15:0]} Q1.15 complex bins,  TLAST on bin N-1
//         TUSER[7:0] = BLK_EXP for this frame, constant across all N beats
//
// The lane emits COMPLEX bins, not magnitude. Magnitude, magnitude-squared,
// framing and packing belong to the output-processing block. Squaring here
// would discard phase and make this lane unusable for the Doppler and AoA
// stages, which are coherent.
//
// Both boundaries are registered so this lane's timing is self-contained.
// -----------------------------------------------------------------------------
`timescale 1ns / 1ps
`default_nettype none

module fft_lane #(
    parameter int CFG_W    = 16,    // xfft config channel width
    parameter int STATUS_W = 8,     // xfft status channel width
    // NFFT select values: nfft_sel_i picks between these two (2^N points each).
    // Defaults (10/11 -> 1024/2048) are the frozen Range spec. Override only
    // for a reduced-size functional smoke test against the SAME already
    // generated xfft_0 core -- it was built with
    // run_time_configurable_transform_length=true up to N=2048, so any
    // power-of-two down to the architecture minimum (8) is legal at runtime
    // without regenerating the IP. Added 2 Sep alongside doppler_lane's
    // existing override, for the same reason: without it a reduced N_RANGE
    // has no way to actually reach the FFT core.
    parameter int NFFT_SEL0 = 10,
    parameter int NFFT_SEL1 = 11
) (
    input  wire        aclk,
    input  wire        aresetn,

    // control
    input  wire        nfft_sel_i,     // 0 = 1024, 1 = 2048
    output wire [4:0]  nfft_applied_o,

    // sample input
    input  wire [31:0] s_axis_tdata,
    input  wire        s_axis_tvalid,
    output wire        s_axis_tready,
    input  wire        s_axis_tlast,

    // bin output
    output wire [31:0] m_axis_tdata,
    output wire [7:0]  m_axis_tuser,   // BLK_EXP
    output wire        m_axis_tvalid,
    input  wire        m_axis_tready,
    output wire        m_axis_tlast,

    // status
    output wire        busy_o,
    output wire [7:0]  blk_exp_dbg_o   // CSR/debug readback only, NOT the datapath
);

    // ---------------------------------------------------------------- input --
    wire [31:0] si_tdata;
    wire        si_tvalid, si_tready, si_tlast;

    axis_skid #(.DW(32), .UW(1)) u_skid_in (
        .aclk(aclk), .aresetn(aresetn),
        .s_axis_tdata (s_axis_tdata),
        .s_axis_tuser (1'b0),
        .s_axis_tlast (s_axis_tlast),
        .s_axis_tvalid(s_axis_tvalid),
        .s_axis_tready(s_axis_tready),
        .m_axis_tdata (si_tdata),
        .m_axis_tuser (),
        .m_axis_tlast (si_tlast),
        .m_axis_tvalid(si_tvalid),
        .m_axis_tready(si_tready)
    );

    // Track whether a frame is in flight on the input, so config writes can be
    // fenced to frame boundaries.
    logic frame_active;
    wire  in_fire = si_tvalid & si_tready;

    always_ff @(posedge aclk) begin
        if (!aresetn)                 frame_active <= 1'b0;
        else if (in_fire && si_tlast) frame_active <= 1'b0;
        else if (in_fire)             frame_active <= 1'b1;
    end

    // --------------------------------------------------------------- config --
    wire [CFG_W-1:0] cfg_tdata;
    wire             cfg_tvalid, cfg_tready;
    wire             gate_input;

    fft_config_fsm #(
        .CFG_W     (CFG_W),
        .NFFT_SEL0 (NFFT_SEL0),
        .NFFT_SEL1 (NFFT_SEL1)
    ) u_cfg (
        .aclk(aclk), .aresetn(aresetn),
        .nfft_sel_i          (nfft_sel_i),
        .frame_active_i      (frame_active),
        .m_axis_config_tdata (cfg_tdata),
        .m_axis_config_tvalid(cfg_tvalid),
        .m_axis_config_tready(cfg_tready),
        .gate_input_o        (gate_input),
        .nfft_applied_o      (nfft_applied_o)
    );

    // --------------------------------------------------------------- window --
    wire [31:0] win_tdata;
    wire        win_tvalid, win_tready, win_tlast;

    // Hold samples off while a config write is outstanding, BEFORE the window block
    wire gated_si_tvalid = si_tvalid & ~gate_input;
    wire gated_si_tready;
    assign si_tready = gated_si_tready & ~gate_input;

    window_lane u_window (
        .aclk         (aclk),
        .aresetn      (aresetn),
        .s_axis_tdata (si_tdata),
        .s_axis_tvalid(gated_si_tvalid),
        .s_axis_tready(gated_si_tready),
        .s_axis_tlast (si_tlast),
        
        .m_axis_tdata (win_tdata),
        .m_axis_tvalid(win_tvalid),
        .m_axis_tready(win_tready),
        .m_axis_tlast (win_tlast)
    );

    // ------------------------------------------------------------------ xfft --
    wire [31:0] fft_tdata;
    wire [7:0]  fft_tuser;      // BLK_EXP, beat-aligned by the core
    wire        fft_tvalid, fft_tready, fft_tlast;

    wire [STATUS_W-1:0] st_tdata;
    wire                st_tvalid, st_tready;

    xfft_0 u_xfft (
        .aclk                 (aclk),
        .aresetn              (aresetn),

        .s_axis_config_tdata  (cfg_tdata),
        .s_axis_config_tvalid (cfg_tvalid),
        .s_axis_config_tready (cfg_tready),

        // Wired directly to the Window output instead of the Skid buffer
        .s_axis_data_tdata    (win_tdata),
        .s_axis_data_tvalid   (win_tvalid),
        .s_axis_data_tready   (win_tready),
        .s_axis_data_tlast    (win_tlast),

        .m_axis_data_tdata    (fft_tdata),
        .m_axis_data_tuser    (fft_tuser),      // BLK_EXP, aligned by the IP
        .m_axis_data_tvalid   (fft_tvalid),
        .m_axis_data_tready   (fft_tready),
        .m_axis_data_tlast    (fft_tlast),

        // NEVER leave this unconnected -- see fft_status_capture header.
        .m_axis_status_tdata  (st_tdata),
        .m_axis_status_tvalid (st_tvalid),
        .m_axis_status_tready (st_tready),

        .event_frame_started        (),
        .event_tlast_unexpected     (),
        .event_tlast_missing        (),
        .event_status_channel_halt  (),
        .event_data_in_channel_halt (),
        .event_data_out_channel_halt()
    );

    // ---------------------------------------------------------- status drain --
    // Drain only. BLK_EXP for the datapath comes from m_axis_data_tuser above,
    // which the core aligns to its own output beats -- no hand-pairing, and no
    // assumption about the relative timing of the status and data channels.
    fft_status_capture #(.STATUS_W(STATUS_W)) u_status (
        .aclk(aclk), .aresetn(aresetn),
        .s_axis_status_tdata (st_tdata),
        .s_axis_status_tvalid(st_tvalid),
        .s_axis_status_tready(st_tready),
        .blk_exp_dbg_o       (blk_exp_dbg_o),
        .blk_exp_seen_o      ()
    );

    // --------------------------------------------------------------- output --
    axis_skid #(.DW(32), .UW(8)) u_skid_out (
        .aclk(aclk), .aresetn(aresetn),
        .s_axis_tdata (fft_tdata),
        .s_axis_tuser (fft_tuser),
        .s_axis_tlast (fft_tlast),
        .s_axis_tvalid(fft_tvalid),
        .s_axis_tready(fft_tready),
        .m_axis_tdata (m_axis_tdata),
        .m_axis_tuser (m_axis_tuser),
        .m_axis_tlast (m_axis_tlast),
        .m_axis_tvalid(m_axis_tvalid),
        .m_axis_tready(m_axis_tready)
    );

    // Added win_tvalid to busy tracking to account for the 2-cycle pipeline
    assign busy_o = frame_active | win_tvalid | fft_tvalid | m_axis_tvalid;

endmodule

`default_nettype wire