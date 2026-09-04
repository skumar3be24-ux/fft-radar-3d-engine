// =============================================================================
// radar_dsp_3d_top -- 3-D radar DSP chain, 4-lane antenna-parallel
//
//  128b in                                                          128b out
//  (4 ant) ─►unpack─►4x window+RangeFFT─►pack─►[CORNER TURN]─┐
//                                                            │
//            ┌───────────────────────────────────────────────┘
//            ▼
//         unpack─►4x DopplerFFT─►pack─►AngleFFT(comb)─►unpack─►4x |X|²─►4x CFAR─►pack
//
// -----------------------------------------------------------------------------
// WHY 4 LANES AND NOT 1
// -----------------------------------------------------------------------------
//  * Throughput: 4 x 1 sample/clock = 400 MSPS at 100 MHz, against 102.4 MSPS
//    required. Measured Fmax on this part is 162 MHz, so there is 6x headroom.
//  * Latency: the four antennas of a cell arrive on the SAME clock edge, so the
//    angle transform is a combinational butterfly -- no buffer, no reordering.
//  * Memory: that removes the SECOND CORNER TURN entirely, which is a 40 %
//    reduction in DDR traffic (2 052 -> 1 233 MB/s), and CFAR before writeback
//    takes it to 819 MB/s.
//  * Cost: ~180 of 840 DSP and ~92 of 890 RAMB18. The device is not the limit.
//
// A single time-multiplexed lane would need >103 MHz just for the range stage,
// would need a demux after the corner turn, and would reintroduce the second
// transpose. It is worse on every axis that matters here.
//
// -----------------------------------------------------------------------------
// THE CORNER TURN IS A PLACEHOLDER
// -----------------------------------------------------------------------------
// u_ctm instantiates ctm_stub -- a behavioural model, NOT synthesisable at full
// dimensions. The real block must be DDR-backed; see ctm_stub.sv for the full
// contract. Swapping it is a one-line change and nothing else moves.
//
// -----------------------------------------------------------------------------
// BLOCK EXPONENT -- the thing most likely to be got wrong silently
// -----------------------------------------------------------------------------
//   after Range FFT     value * 2^Er
//   after Doppler FFT   value * 2^(Er+Ed)         <- Doppler reports only Ed
//   after Angle FFT     value * 2^(Er+Ed+2)       <- /4 inside angle_fft4_par
//   after |X|^2         value * 2^(2*(Er+Ed+2))   <- squaring doubles it
//
// u_exp carries Er across the Doppler stage's latency so it can be added back.
// m_axis_tuser carries (Er+Ed+2). THE CONSUMER MUST DOUBLE IT, because the
// output is magnitude-squared. Not doubled here on purpose: TUSER then means
// the same thing at every interface in the design.
// =============================================================================
`timescale 1ns / 1ps
`default_nettype none

module radar_dsp_3d_top #(
    // =====================================================================
    // CUBE DIMENSIONS -- THE FROZEN SPEC: 1024 range x 256 Doppler x 4 RX
    // =====================================================================
    // CORRECTED 2 Sep. These defaults were N_CHIRP=16 with DOPPLER_SEL=0
    // (a 128-point Doppler transform) -- left over from when ctm_stub held
    // the whole cube as a flat array and had to be kept small. That reason
    // is gone: under -verilog_define SYNTHESIS the corner turn is a 1-deep
    // register with no array at all.
    //
    // The defaults now ARE the spec. Anything that wants a reduced size
    // must say so explicitly (tb_radar_dsp_3d_top_smoke.sv does), rather
    // than the spec silently being whatever was convenient last.
    //
    //   N_RANGE = 1024  must equal 2**RANGE_NFFT0   (RANGE_SEL=0   -> 1024)
    //   N_CHIRP =  256  must equal 2**DOPPLER_NFFT1 (DOPPLER_SEL=1 ->  256)
    //   4 antennas is structural -- the 128-bit bus, not a parameter.
    //
    // The simulation-only assertion below enforces the two equalities.
    parameter int N_RANGE     = 1024,
    parameter int N_CHIRP     = 256,

    parameter bit RANGE_SEL   = 1'b0,   // 0 -> 1024-pt, 1 -> 2048-pt
    parameter bit DOPPLER_SEL = 1'b1,   // 0 ->  128-pt, 1 ->  256-pt  <- spec

    // NFFT select values fed to the Range/Doppler xfft cores. Defaults are
    // the frozen spec (1024/2048 and 128/256) -- leave them alone for any
    // real build. Override ONLY for a reduced-size functional smoke test
    // against the same already-generated xfft_0 core (built runtime-
    // configurable up to 2048, so 8 is legal without IP regeneration). If
    // you override these, N_RANGE/N_CHIRP MUST be updated to match
    // (2**RANGE_NFFT_SEL and 2**DOPPLER_NFFT_SEL respectively) or the
    // consistency check below will fail loudly, on purpose.
    parameter int RANGE_NFFT0   = 10,   // -> 1024
    parameter int RANGE_NFFT1   = 11,   // -> 2048
    parameter int DOPPLER_NFFT0 = 7,    // -> 128
    parameter int DOPPLER_NFFT1 = 8     // -> 256
) (
    input  wire         aclk,
    input  wire         aresetn,

    // raw ADC, 4 antennas packed: lane L = antenna L, {Q[15:0], I[15:0]}
    input  wire [127:0] s_axis_tdata,
    input  wire         s_axis_tvalid,
    output wire         s_axis_tready,
    input  wire         s_axis_tlast,       // on sample N_RANGE-1 of a chirp

    // detections: lane K = angle bin K, 32-bit unsigned power
    output wire [127:0] m_axis_tdata,
    output wire         m_axis_tvalid,
    input  wire         m_axis_tready,
    output wire         m_axis_tlast,
    output wire [7:0]   m_axis_tuser,       // Er+Ed+2  (consumer doubles)
    output wire [3:0]   m_axis_tdetect,     // per angle bin: target present

    input  wire [15:0]  threshold_scale_i,  // CFAR: 65536 == unity

    output wire         busy_o,
    output wire         exp_ovfl_o
);

    // =========================================================================
    // PARAMETER CONSISTENCY CHECK -- simulation only
    // =========================================================================
    // N_RANGE/N_CHIRP set the corner-turn's frame length (when u_ctm asserts
    // TLAST). RANGE_SEL/DOPPLER_SEL set the xfft cores' ACTUAL configured
    // transform length via fft_config_fsm. THESE ARE TWO INDEPENDENT
    // PARAMETERS WITH NO WIRING BETWEEN THEM. If they disagree, the corner
    // turn hands the Range or Doppler FFT core a frame that is shorter or
    // longer than the transform length it's configured for -- the xfft core
    // needs exactly N valid samples before TLAST, per Xilinx PG109. Get this
    // wrong and you get either a truncated/garbage transform or a stalled
    // core, and nothing in check_elab.tcl or build_synth.tcl would catch it,
    // because those only prove structural connectivity, not that the numbers
    // flowing through are correct.
    //
    // FOUND 2 Sep: the header comment "N_RANGE/N_CHIRP small for simulation"
    // is only true for STRUCTURAL checks (elaboration/synthesis). The default
    // N_CHIRP=16 does NOT match DOPPLER_SEL=0's 128-point transform -- running
    // this module for functional simulation with the defaults as-is would
    // silently feed the Doppler FFT the wrong frame length. This assertion
    // makes that loud instead of silent. It is compiled out under SYNTHESIS
    // (via the same -verilog_define SYNTHESIS used for ctm_stub.sv) so it
    // does not block check_elab.tcl / build_synth.tcl, which use reduced
    // dimensions on purpose and don't care about functional correctness.
    // =========================================================================
`ifndef SYNTHESIS
    initial begin
        automatic int range_pts   = 1 << (RANGE_SEL   ? RANGE_NFFT1   : RANGE_NFFT0);
        automatic int doppler_pts = 1 << (DOPPLER_SEL ? DOPPLER_NFFT1 : DOPPLER_NFFT0);
        if (N_RANGE != range_pts)
            $error("radar_dsp_3d_top: N_RANGE=%0d does not match RANGE_SEL's configured Range FFT transform length (%0d). For structural-only elaboration/synthesis (check_elab.tcl, build_synth.tcl) this is expected and harmless. For FUNCTIONAL simulation it means the corner turn will hand the Range FFT core a frame of the wrong length -- fix N_RANGE or RANGE_SEL before trusting any data out of this instance.", N_RANGE, range_pts);
        if (N_CHIRP != doppler_pts)
            $error("radar_dsp_3d_top: N_CHIRP=%0d does not match DOPPLER_SEL's configured Doppler FFT transform length (%0d). Same failure mode as N_RANGE above, on the Doppler stage. The default N_CHIRP=16 is a STRUCTURAL-ONLY value -- do not use it for functional simulation.", N_CHIRP, doppler_pts);
    end
`endif

    genvar L;

    // ======================= STAGE 1: window + Range FFT ====================
    wire [127:0] u1_tdata;
    wire [3:0]   u1_tvalid, u1_tready, u1_tlast;
    wire [7:0]   u1_tuser;

    axis_unpack4 u_unpack_adc (
        .aclk(aclk), .aresetn(aresetn),
        .s_axis_tdata (s_axis_tdata),
        .s_axis_tvalid(s_axis_tvalid),
        .s_axis_tready(s_axis_tready),
        .s_axis_tlast (s_axis_tlast),
        .s_axis_tuser (8'd0),
        .m_axis_tdata (u1_tdata),
        .m_axis_tvalid(u1_tvalid),
        .m_axis_tready(u1_tready),
        .m_axis_tlast (u1_tlast),
        .m_axis_tuser (u1_tuser)
    );

    wire [127:0] rng_tdata;
    wire [3:0]   rng_tvalid, rng_tready, rng_tlast;
    wire [7:0]   rng_tuser [0:3];
    wire [3:0]   rng_busy;

    generate
        for (L = 0; L < 4; L++) begin : g_range
            fft_lane #(
                .NFFT_SEL0(RANGE_NFFT0),
                .NFFT_SEL1(RANGE_NFFT1)
            ) u_range (
                .aclk          (aclk),
                .aresetn       (aresetn),
                .nfft_sel_i    (RANGE_SEL),
                .nfft_applied_o(),
                .s_axis_tdata  (u1_tdata[32*L +: 32]),
                .s_axis_tvalid (u1_tvalid[L]),
                .s_axis_tready (u1_tready[L]),
                .s_axis_tlast  (u1_tlast[L]),
                .m_axis_tdata  (rng_tdata[32*L +: 32]),
                .m_axis_tuser  (rng_tuser[L]),
                .m_axis_tvalid (rng_tvalid[L]),
                .m_axis_tready (rng_tready[L]),
                .m_axis_tlast  (rng_tlast[L]),
                .busy_o        (rng_busy[L]),
                .blk_exp_dbg_o ()
            );
        end
    endgenerate

    // All four lanes are identical and identically fed, so Er is common.
    wire [127:0] ctm_in_tdata;
    wire         ctm_in_tvalid, ctm_in_tready, ctm_in_tlast;
    wire [7:0]   ctm_in_tuser;

    axis_pack4 u_pack_range (
        .aclk(aclk), .aresetn(aresetn),
        .s_axis_tdata (rng_tdata),
        .s_axis_tvalid(rng_tvalid),
        .s_axis_tready(rng_tready),
        .s_axis_tlast (rng_tlast),
        .s_axis_tuser (rng_tuser[0]),
        .m_axis_tdata (ctm_in_tdata),
        .m_axis_tvalid(ctm_in_tvalid),
        .m_axis_tready(ctm_in_tready),
        .m_axis_tlast (ctm_in_tlast),
        .m_axis_tuser (ctm_in_tuser)
    );

    // ======================= STAGE 2: CORNER TURN ===========================
    // <<<<<<<<<<<<  SWAP THIS INSTANCE FOR THE REAL BLOCK  >>>>>>>>>>>>
    wire [127:0] ctm_tdata;
    wire         ctm_tvalid, ctm_tready, ctm_tlast;
    wire [7:0]   ctm_tuser;

    ctm_stub #(
        .N_RANGE(N_RANGE),
        .N_CHIRP(N_CHIRP)
    ) u_ctm (
        .aclk(aclk), .aresetn(aresetn),
        .s_axis_tdata (ctm_in_tdata),
        .s_axis_tvalid(ctm_in_tvalid),
        .s_axis_tready(ctm_in_tready),
        .s_axis_tlast (ctm_in_tlast),
        .s_axis_tuser (ctm_in_tuser),
        .m_axis_tdata (ctm_tdata),
        .m_axis_tvalid(ctm_tvalid),
        .m_axis_tready(ctm_tready),
        .m_axis_tlast (ctm_tlast),
        .m_axis_tuser (ctm_tuser)
    );

    // ======================= STAGE 3: Doppler FFT ===========================
    wire [127:0] u2_tdata;
    wire [3:0]   u2_tvalid, u2_tready, u2_tlast;
    wire [7:0]   u2_tuser;

    axis_unpack4 u_unpack_ctm (
        .aclk(aclk), .aresetn(aresetn),
        .s_axis_tdata (ctm_tdata),
        .s_axis_tvalid(ctm_tvalid),
        .s_axis_tready(ctm_tready),
        .s_axis_tlast (ctm_tlast),
        .s_axis_tuser (ctm_tuser),
        .m_axis_tdata (u2_tdata),
        .m_axis_tvalid(u2_tvalid),
        .m_axis_tready(u2_tready),
        .m_axis_tlast (u2_tlast),
        .m_axis_tuser (u2_tuser)
    );

    wire [127:0] dop_tdata;
    wire [3:0]   dop_tvalid, dop_tready, dop_tlast;
    wire [7:0]   dop_tuser [0:3];
    wire [3:0]   dop_busy;

    generate
        for (L = 0; L < 4; L++) begin : g_doppler
            doppler_lane #(
                .NFFT_SEL0(DOPPLER_NFFT0),
                .NFFT_SEL1(DOPPLER_NFFT1)
            ) u_doppler (
                .aclk          (aclk),
                .aresetn       (aresetn),
                .nfft_sel_i    (DOPPLER_SEL),
                .nfft_applied_o(),
                .s_axis_tdata  (u2_tdata[32*L +: 32]),
                .s_axis_tvalid (u2_tvalid[L]),
                .s_axis_tready (u2_tready[L]),
                .s_axis_tlast  (u2_tlast[L]),
                .m_axis_tdata  (dop_tdata[32*L +: 32]),
                .m_axis_tuser  (dop_tuser[L]),
                .m_axis_tvalid (dop_tvalid[L]),
                .m_axis_tready (dop_tready[L]),
                .m_axis_tlast  (dop_tlast[L]),
                .busy_o        (dop_busy[L])
            );
        end
    endgenerate

    // ---- carry Er across the Doppler latency and sum ----------------------
    wire [7:0] range_exp_held;

    exp_accum #(.DEPTH_LG(2)) u_exp (
        .aclk   (aclk),
        .aresetn(aresetn),
        .push_i (ctm_tvalid & ctm_tready & ctm_tlast),
        .exp_i  (ctm_tuser),
        .pop_i  (dop_tvalid[0] & dop_tready[0] & dop_tlast[0]),
        .exp_o  (range_exp_held),
        .valid_o(),
        .ovfl_o (exp_ovfl_o)
    );

    wire [7:0] dop_exp_total = dop_tuser[0] + range_exp_held;   // Er + Ed

    wire [127:0] ang_in_tdata;
    wire         ang_in_tvalid, ang_in_tready, ang_in_tlast;
    wire [7:0]   ang_in_tuser;

    axis_pack4 u_pack_doppler (
        .aclk(aclk), .aresetn(aresetn),
        .s_axis_tdata (dop_tdata),
        .s_axis_tvalid(dop_tvalid),
        .s_axis_tready(dop_tready),
        .s_axis_tlast (dop_tlast),
        .s_axis_tuser (dop_exp_total),
        .m_axis_tdata (ang_in_tdata),
        .m_axis_tvalid(ang_in_tvalid),
        .m_axis_tready(ang_in_tready),
        .m_axis_tlast (ang_in_tlast),
        .m_axis_tuser (ang_in_tuser)
    );

    // ======================= STAGE 4: Angle FFT (combinational) =============
    // No second corner turn: all four antennas of the cell are already aligned.
    wire [127:0] ang_tdata;
    wire         ang_tvalid, ang_tready, ang_tlast;
    wire [7:0]   ang_tuser;

    angle_fft4_par u_angle (
        .aclk(aclk), .aresetn(aresetn),
        .s_axis_tdata (ang_in_tdata),
        .s_axis_tvalid(ang_in_tvalid),
        .s_axis_tready(ang_in_tready),
        .s_axis_tlast (ang_in_tlast),
        .s_axis_tuser (ang_in_tuser),
        .m_axis_tdata (ang_tdata),
        .m_axis_tvalid(ang_tvalid),
        .m_axis_tready(ang_tready),
        .m_axis_tlast (ang_tlast),
        .m_axis_tuser (ang_tuser)
    );

    // ======================= STAGE 5+6: |X|^2 then CFAR =====================
    // Lane K is now ANGLE BIN K, not antenna K.
    wire [127:0] u3_tdata;
    wire [3:0]   u3_tvalid, u3_tready, u3_tlast;
    wire [7:0]   u3_tuser;

    axis_unpack4 u_unpack_angle (
        .aclk(aclk), .aresetn(aresetn),
        .s_axis_tdata (ang_tdata),
        .s_axis_tvalid(ang_tvalid),
        .s_axis_tready(ang_tready),
        .s_axis_tlast (ang_tlast),
        .s_axis_tuser (ang_tuser),
        .m_axis_tdata (u3_tdata),
        .m_axis_tvalid(u3_tvalid),
        .m_axis_tready(u3_tready),
        .m_axis_tlast (u3_tlast),
        .m_axis_tuser (u3_tuser)
    );

    wire [127:0] mag_tdata,  cfar_tdata;
    wire [3:0]   mag_tvalid, mag_tready, mag_tlast;
    wire [3:0]   cfar_tvalid, cfar_tready, cfar_tlast;
    wire [7:0]   mag_tuser [0:3];
    wire [7:0]   cfar_tuser[0:3];

    // Skid between CFAR and the output join -- see the deadlock note at u_skid_out.
    wire [127:0] out_tdata;
    wire [3:0]   out_tvalid, out_tready, out_tlast;
    wire [7:0]   out_tuser [0:3];

    generate
        for (L = 0; L < 4; L++) begin : g_out
            complex_mag2 u_mag (
                .aclk(aclk), .aresetn(aresetn),
                .s_axis_tdata (u3_tdata[32*L +: 32]),
                .s_axis_tvalid(u3_tvalid[L]),
                .s_axis_tready(u3_tready[L]),
                .s_axis_tlast (u3_tlast[L]),
                .s_axis_tuser (u3_tuser),
                .m_axis_tdata (mag_tdata[32*L +: 32]),
                .m_axis_tvalid(mag_tvalid[L]),
                .m_axis_tready(mag_tready[L]),
                .m_axis_tuser (mag_tuser[L]),
                .m_axis_tlast (mag_tlast[L])
            );

            ca_cfar #(
                .DATA_WIDTH(32), .LEAD_CELLS(4), .TRAIL_CELLS(4), .GUARD_CELLS(2)
            ) u_cfar (
                .aclk(aclk), .aresetn(aresetn),
                .threshold_scale_i(threshold_scale_i),
                .s_axis_tdata     (mag_tdata[32*L +: 32]),
                .s_axis_tvalid    (mag_tvalid[L]),
                .s_axis_tready    (mag_tready[L]),
                .s_axis_tlast     (mag_tlast[L]),
                .s_axis_tuser     (mag_tuser[L]),
                .m_axis_tdata     (cfar_tdata[32*L +: 32]),
                .m_axis_tvalid    (cfar_tvalid[L]),
                .m_axis_tready    (cfar_tready[L]),
                .m_axis_tlast     (cfar_tlast[L]),
                .m_axis_tuser     (cfar_tuser[L]),
                .target_detected_o(m_axis_tdetect[L])
            );

            // =============================================================
            // DEADLOCK FIX, 2 Sep -- found by simulation, provable in code.
            // =============================================================
            // ca_cfar advances its pipeline only `else if (m_axis_tready)`,
            // so its TVALID depends on its TREADY. axis_pack4's join drives
            // s_axis_tready = {4{all_valid & m_axis_tready}}, so its TREADY
            // depends on TVALID. Wired directly together that is a circular
            // combinational dependency with no escape:
            //
            //   valid_pipe = 0 (reset)
            //     -> cfar m_axis_tvalid = 0
            //     -> pack all_valid = 0
            //     -> pack s_axis_tready = 0
            //     -> cfar m_axis_tready = 0
            //     -> cfar pipeline frozen, valid_pipe stays 0  ... forever.
            //
            // That is why the smoke test drained all 256 input beats (the
            // upstream skids absorb them) and produced exactly ZERO output
            // beats across a 200us watchdog, at every transform size tried.
            //
            // This skid breaks the loop at the only place it exists. Its
            // s_axis_tready = ~skid_valid is high when empty REGARDLESS of
            // downstream ready, which unfreezes the CFAR; its m_axis_tvalid
            // is a register, so the join sees a ready-independent valid.
            // g_range/g_doppler already end in axis_skid, which is exactly
            // why those two joins were never affected.
            //
            // NOTE: ca_cfar itself still has the underlying "TVALID depends
            // on TREADY" property. It is contained here, but anyone
            // instantiating ca_cfar behind another join must add a skid or
            // hit this same deadlock. Same for complex_mag2's stall idiom.
            // =============================================================
            axis_skid #(.DW(32), .UW(8)) u_skid_out (
                .aclk(aclk), .aresetn(aresetn),
                .s_axis_tdata (cfar_tdata[32*L +: 32]),
                .s_axis_tuser (cfar_tuser[L]),
                .s_axis_tlast (cfar_tlast[L]),
                .s_axis_tvalid(cfar_tvalid[L]),
                .s_axis_tready(cfar_tready[L]),
                .m_axis_tdata (out_tdata[32*L +: 32]),
                .m_axis_tuser (out_tuser[L]),
                .m_axis_tlast (out_tlast[L]),
                .m_axis_tvalid(out_tvalid[L]),
                .m_axis_tready(out_tready[L])
            );
        end
    endgenerate

    axis_pack4 u_pack_out (
        .aclk(aclk), .aresetn(aresetn),
        .s_axis_tdata (out_tdata),
        .s_axis_tvalid(out_tvalid),
        .s_axis_tready(out_tready),
        .s_axis_tlast (out_tlast),
        .s_axis_tuser (out_tuser[0]),
        .m_axis_tdata (m_axis_tdata),
        .m_axis_tvalid(m_axis_tvalid),
        .m_axis_tready(m_axis_tready),
        .m_axis_tlast (m_axis_tlast),
        .m_axis_tuser (m_axis_tuser)
    );

    assign busy_o = (|rng_busy) | (|dop_busy) | ctm_tvalid | ang_tvalid;

endmodule

`default_nettype wire
