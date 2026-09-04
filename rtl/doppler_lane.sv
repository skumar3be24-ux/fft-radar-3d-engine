`timescale 1ns / 1ps
`default_nettype none

module doppler_lane #(
    parameter int CFG_W    = 16,
    parameter int STATUS_W = 8,
    // NFFT select values, same mechanism as fft_lane's. Defaults (7/8 ->
    // 128/256) are the frozen Doppler spec. Override only for a reduced-size
    // functional smoke test.
    parameter int NFFT_SEL0 = 7,
    parameter int NFFT_SEL1 = 8
) (
    input  wire        aclk,
    input  wire        aresetn,

    // control
    // FIXED 2 Sep: this comment said "0 = 64-point, 1 = 128-point" -- wrong,
    // did not match the actual NFFT_SEL0/1 values below (7/8 -> 128/256),
    // nor radar_dsp_3d_top.sv's own DOPPLER_SEL comment (0->128pt, 1->256pt).
    // Stale/contradictory comment, not a functional bug -- but exactly the
    // kind of thing that misleads whoever reads this file next.
    input  wire        nfft_sel_i,     // 0 = 128-point Doppler, 1 = 256-point Doppler
    output wire [4:0]  nfft_applied_o,

    // input from Corner Turn Memory (CTM)
    input  wire [31:0] s_axis_tdata,
    input  wire        s_axis_tvalid,
    output wire        s_axis_tready,
    input  wire        s_axis_tlast,

    // output to Magnitude/CFAR stage (Range-Doppler bins)
    output wire [31:0] m_axis_tdata,
    output wire [7:0]  m_axis_tuser,   // BLK_EXP for Doppler frame
    output wire        m_axis_tvalid,
    input  wire        m_axis_tready,
    output wire        m_axis_tlast,

    // status
    output wire        busy_o
);

    // 1. Input Skid Buffer for timing isolation
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

    // Frame active tracking for config gating
    logic frame_active;
    wire  in_fire = si_tvalid & si_tready;

    always_ff @(posedge aclk) begin
        if (!aresetn)                 frame_active <= 1'b0;
        else if (in_fire && si_tlast) frame_active <= 1'b0;
        else if (in_fire)             frame_active <= 1'b1;
    end

    // 2. Doppler Config FSM (Reuses your proven FSM structure)
    wire [CFG_W-1:0] cfg_tdata;
    wire             cfg_tvalid, cfg_tready;
    wire             gate_input;

    // Without these the module would inherit the range defaults (1024/2048).
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

    // Config Gating
    wire xfft_s_tvalid = si_tvalid & ~gate_input;
    wire xfft_s_tready;
    assign si_tready = xfft_s_tready & ~gate_input;

    // 3. Doppler FFT Core Instance 
    // Note: In a full project, you instantiate a second Xilinx FFT IP core 
    // configured for your Doppler length (e.g., xfft_doppler). 
    wire [31:0] fft_tdata;
    wire [7:0]  fft_tuser;
    wire        fft_tvalid, fft_tready, fft_tlast;

    wire [STATUS_W-1:0] st_tdata;
    wire                st_tvalid, st_tready;

    xfft_0 u_doppler_xfft (
        .aclk                 (aclk),
        .aresetn              (aresetn),

        .s_axis_config_tdata  (cfg_tdata),
        .s_axis_config_tvalid (cfg_tvalid),
        .s_axis_config_tready (cfg_tready),

        .s_axis_data_tdata    (si_tdata),
        .s_axis_data_tvalid   (xfft_s_tvalid),
        .s_axis_data_tready   (xfft_s_tready),
        .s_axis_data_tlast    (si_tlast),

        .m_axis_data_tdata    (fft_tdata),
        .m_axis_data_tuser    (fft_tuser),
        .m_axis_data_tvalid   (fft_tvalid),
        .m_axis_data_tready   (fft_tready),
        .m_axis_data_tlast    (fft_tlast),

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

    // Status Drain (Mandatory for Xilinx FFT IP)
    fft_status_capture #(.STATUS_W(STATUS_W)) u_status (
        .aclk(aclk), .aresetn(aresetn),
        .s_axis_status_tdata (st_tdata),
        .s_axis_status_tvalid(st_tvalid),
        .s_axis_status_tready(st_tready),
        .blk_exp_dbg_o       (),
        .blk_exp_seen_o      ()
    );

    // 4. Output Skid Buffer
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

    assign busy_o = frame_active | fft_tvalid | m_axis_tvalid;

endmodule

`default_nettype wire