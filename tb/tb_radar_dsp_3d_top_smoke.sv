// -----------------------------------------------------------------------------
// tb_radar_dsp_3d_top_smoke -- first-ever end-to-end test of the ACTUAL top
// level, radar_dsp_3d_top.sv, through the real xfft_0 IP core (not a mock).
//
// Nothing before this testbench exercised the full chain. tb_radar_pipeline.sv
// and tb_fft_4lane.sv both predate the 4-lane packed architecture and don't
// instantiate radar_dsp_3d_top at all. Module-level tests (angle_fft4_par,
// ctm_transpose) proved their pieces correct in isolation; this is the first
// check that Range -> corner-turn -> Doppler -> Angle -> |X|^2 -> CFAR agree
// with each other on framing and produce sane data end to end.
//
// SCALE: 16-point Range and 16-point Doppler transforms (N_RANGE=16,
// N_CHIRP=16), NOT the real 1024/128 spec. Legal without regenerating the
// xfft_0 IP -- it was built with run_time_configurable_transform_length=true
// up to N=2048. The point is to prove the PIPELINE PLUMBING (framing, TLAST
// cadence, BLK_EXP bookkeeping, backpressure) end to end, fast, not to
// validate the real cube size -- that needs real hardware or a much longer
// simulation.
//
// CHANGED 2 Sep from an original 8-point attempt: the first run of this
// testbench at N=8 produced ZERO output beats in a 200us watchdog window --
// a full stall, not a data-correctness failure. Leading hypothesis, not yet
// confirmed: 8 points may be below the real minimum this specific generated
// core accepts at runtime (the architecture is internally Radix-2^2 per
// earlier project notes, and the exact minimum for THIS core's generation
// options was never independently confirmed -- "8" was carried over from a
// general note about the Pipelined Streaming I/O architecture, not verified
// against this project's actual xfft_0.xci). 16 is a cheap, fast next data
// point: if it also stalls at 0 beats, the hypothesis is wrong and the real
// cause is elsewhere (config channel handshake, gating logic, or this
// testbench itself). If 16 runs cleanly, that's strong evidence the minimum
// transform size was the problem.
//
// STIMULUS: constant DC value on all 4 antennas, every input cell. A DFT of
// a constant concentrates all energy in bin 0, which gives real, checkable
// structure without hand-replicating the core's block-floating-point
// rounding (this testbench does NOT claim bit-exactness).
//
// CORRECTED 2 Sep -- this used to claim the concentration holds for all
// THREE transforms. It does not, and the first run proved it:
//   * ANGLE:   holds exactly. All 4 antennas identical -> bin 0 only,
//              bins 1-3 exactly zero.
//   * DOPPLER: holds. Every chirp is identical -> doppler bin 0 only.
//   * RANGE:   does NOT hold, for a real reason. window_lane applies a
//              fixed 1024-point Hanning window regardless of the configured
//              transform length, so at N_RANGE=16 the FFT sees w[0..15] of
//              a 1024-point window -- a near-zero rising ramp, not a flat
//              DC. Ramps leak. The measured leakage is symmetric about DC
//              (range +-1 equal, range +-2 equal), which is what a correct
//              FFT of a ramp looks like.
//
// So the range-dimension check asserts only that bin 0 is the peak. The
// window ROM not scaling with transform size is a genuine limitation, and
// it means reduced-size runs are structurally meaningful but never
// numerically representative of the real 1024-point system.
//
// NOT COVERED: this stimulus never varies chirp-to-chirp, so it does not
// exercise whether BLK_EXP genuinely stays constant across all N_CHIRP
// chirps of a real (non-constant) cube -- ctm_stub.sv only latches the
// FIRST chirp's exponent for the whole frame (see its section 3
// requirement #3). That is an open assumption, not proven by this test.
//
// WHAT THIS PROVES IF IT PASSES: the framing contract holds end to end
// (input TLAST every N_RANGE samples, output TLAST every N_DOPPLER bins,
// exactly N_RANGE x N_DOPPLER beats out for N_RANGE x N_CHIRP beats in),
// no protocol violation/hang across 6 cascaded stages plus 2 real xfft
// cores, and energy lands where basic DFT math says it must.
//
// WHAT THIS DOES NOT PROVE: bit-exact numeric correctness against a golden
// model, real-cube-size timing/behaviour, or the corner turn's real
// (DDR-backed) implementation -- ctm_stub.sv's simulation-model branch is
// what's under test here, not the real block.
// -----------------------------------------------------------------------------
`timescale 1ns / 1ps
`default_nettype none

module tb_radar_dsp_3d_top_smoke;

    localparam int N_RANGE = 16;
    localparam int N_CHIRP = 16;
    localparam int N_OUT   = N_RANGE * N_CHIRP;   // beats expected each side

    logic aclk = 0, aresetn = 0;
    always #5 aclk = ~aclk;   // 100 MHz

    logic  [127:0] s_tdata;
    logic          s_tvalid, s_tlast;
    wire           s_tready;

    wire   [127:0] m_tdata;
    wire           m_tvalid, m_tlast;
    wire   [7:0]   m_tuser;
    wire   [3:0]   m_tdetect;
    logic          m_tready;

    logic  [15:0]  threshold_scale = 16'h0008;  // matches ca_cfar's REF_CELLS=8 default scale
    wire           busy, exp_ovfl;

    radar_dsp_3d_top #(
        .N_RANGE     (N_RANGE),
        .N_CHIRP     (N_CHIRP),
        .RANGE_SEL   (1'b0),
        .DOPPLER_SEL (1'b0),
        .RANGE_NFFT0 (4),   // 2^4 = 16 -- matches N_RANGE, required by the
        .RANGE_NFFT1 (5),   //   consistency assertion added 2 Sep. NFFT1
        .DOPPLER_NFFT0(4),  //   value is unused here (RANGE_SEL/DOPPLER_SEL
        .DOPPLER_NFFT1(5)   //   are tied to 0), given a distinct valid value
                             //   only so it's not a meaningless duplicate.
    ) dut (
        .aclk(aclk), .aresetn(aresetn),
        .s_axis_tdata (s_tdata),
        .s_axis_tvalid(s_tvalid),
        .s_axis_tready(s_tready),
        .s_axis_tlast (s_tlast),
        .m_axis_tdata (m_tdata),
        .m_axis_tvalid(m_tvalid),
        .m_axis_tready(m_tready),
        .m_axis_tlast (m_tlast),
        .m_axis_tuser (m_tuser),
        .m_axis_tdetect(m_tdetect),
        .threshold_scale_i(threshold_scale),
        .busy_o(busy),
        .exp_ovfl_o(exp_ovfl)
    );

    int errors = 0, checks = 0;
    task automatic chk(input bit c, input string msg);
        checks++;
        if (!c) begin errors++; $display("  [FAIL] %s", msg); end
    endtask

    // -------------------------------------------------------------------------
    // PER-STAGE BEAT COUNTERS -- added 2 Sep so a stall is localized in ONE run
    // instead of another round of hypothesize-fix-rerun. Counts accepted beats
    // (valid & ready) at every internal boundary, lane 0 where per-lane. The
    // stage where the count drops to zero IS the blockage -- no interpretation
    // needed. Hierarchical refs: testbench-only, never synthesized.
    // -------------------------------------------------------------------------
    int n_in, n_range, n_ctm_in, n_ctm_out, n_dop, n_ang, n_mag, n_cfar, n_skid, n_out;

    always_ff @(posedge aclk) begin
        if (!aresetn) begin
            n_in <= 0; n_range <= 0; n_ctm_in <= 0; n_ctm_out <= 0; n_dop <= 0;
            n_ang <= 0; n_mag <= 0; n_cfar <= 0; n_skid <= 0; n_out <= 0;
        end else begin
            if (s_tvalid              && s_tready)              n_in      <= n_in      + 1;
            if (dut.rng_tvalid[0]     && dut.rng_tready[0])     n_range   <= n_range   + 1;
            if (dut.ctm_in_tvalid     && dut.ctm_in_tready)     n_ctm_in  <= n_ctm_in  + 1;
            if (dut.ctm_tvalid        && dut.ctm_tready)        n_ctm_out <= n_ctm_out + 1;
            if (dut.dop_tvalid[0]     && dut.dop_tready[0])     n_dop     <= n_dop     + 1;
            if (dut.ang_tvalid        && dut.ang_tready)        n_ang     <= n_ang     + 1;
            if (dut.mag_tvalid[0]     && dut.mag_tready[0])     n_mag     <= n_mag     + 1;
            if (dut.cfar_tvalid[0]    && dut.cfar_tready[0])    n_cfar    <= n_cfar    + 1;
            if (dut.out_tvalid[0]     && dut.out_tready[0])     n_skid    <= n_skid    + 1;
            if (m_tvalid              && m_tready)              n_out     <= n_out     + 1;
        end
    end

    task automatic dump_stage_counts;
        $display("\n--- beats accepted per stage (lane 0 where per-lane) ---");
        $display("  1. top input          : %0d   (expect %0d)", n_in,      N_RANGE*N_CHIRP);
        $display("  2. Range FFT out      : %0d   (expect %0d)", n_range,   N_RANGE*N_CHIRP);
        $display("  3. corner turn in     : %0d   (expect %0d)", n_ctm_in,  N_RANGE*N_CHIRP);
        $display("  4. corner turn out    : %0d   (expect %0d)", n_ctm_out, N_RANGE*N_CHIRP);
        $display("  5. Doppler FFT out    : %0d   (expect %0d)", n_dop,     N_RANGE*N_CHIRP);
        $display("  6. Angle FFT out      : %0d   (expect %0d)", n_ang,     N_OUT);
        $display("  7. |X|^2 out          : %0d   (expect %0d)", n_mag,     N_OUT);
        $display("  8. CFAR out           : %0d   (expect %0d)", n_cfar,    N_OUT);
        $display("  9. output skid out    : %0d   (expect %0d)", n_skid,    N_OUT);
        $display(" 10. top output         : %0d   (expect %0d)", n_out,     N_OUT);
        $display("  The first stage reading 0 (or far below the one above it)");
        $display("  is where the pipeline is blocked.");
    endtask

    // ---- drive N_RANGE*N_CHIRP beats of constant DC, all 4 lanes -----------
    localparam signed [15:0] DC_VAL = 16'sd8192;  // 0.25 in Q1.15

    task automatic drive_cube;
        logic [127:0] beat;
        for (int lane = 0; lane < 4; lane++)
            beat[32*lane +: 32] = {16'(0), 16'(DC_VAL)};   // {Q(im)=0, I(re)=DC_VAL}

        for (int n = 0; n < N_RANGE*N_CHIRP; n++) begin
            s_tdata  <= beat;
            s_tvalid <= 1'b1;
            // TLAST every N_RANGE samples -- "on sample N_RANGE-1 of a chirp"
            s_tlast  <= ((n % N_RANGE) == (N_RANGE-1));
            @(posedge aclk);
            while (!s_tready) @(posedge aclk);
        end
        s_tvalid <= 1'b0;
        s_tlast  <= 1'b0;
    endtask

    // ---- collect output beats, record magnitude-squared and tlast timing --
    logic [31:0] cell_pow [0:N_OUT-1][0:3];   // [cell][angle bin] magnitude^2
    int          out_count = 0;
    int          tlast_positions[$];

    task automatic collect_cube;
        m_tready <= 1'b1;
        while (out_count < N_OUT) begin
            @(posedge aclk);
            if (m_tvalid && m_tready) begin
                for (int lane = 0; lane < 4; lane++)
                    cell_pow[out_count][lane] = m_tdata[32*lane +: 32];
                if (m_tlast) tlast_positions.push_back(out_count);
                out_count++;
            end
        end
    endtask

    initial begin
        s_tvalid = 0; s_tlast = 0; s_tdata = '0; m_tready = 0;
        repeat (10) @(posedge aclk);
        aresetn = 1;
        repeat (5) @(posedge aclk);

        $display("\n=================================================");
        $display(" radar_dsp_3d_top -- end-to-end smoke test (%0dx%0d, DC input)",
                  N_RANGE, N_CHIRP);
        $display("=================================================");

        // ---------------------------------------------------------------------
        // DEBUG, added 2 Sep after two real fixes (window .mem path,
        // fft_config_fsm reset default) still left the pipeline at 0 output
        // beats. Both fixes are confirmed correct by the run that showed this
        // is still failing -- the .mem warnings are gone, so this isn't a
        // repeat of either prior bug. Rather than guess a third time, watch
        // the actual config handshake and see where it stops. $monitor only
        // prints on a change, so if the log shows exactly one line and never
        // another, that IS the answer: nothing downstream of that point ever
        // moves. Lane 0 only -- all 4 lanes are identically driven, so lane 0
        // is representative.
        // ---------------------------------------------------------------------
        // The $monitor that lived here did its job: it proved the input side
        // was healthy (config completed, s_tready high, 253 cycles of
        // uninterrupted streaming into the Range FFT) and therefore that the
        // blockage was downstream -- which led to the ca_cfar/axis_pack4
        // deadlock. Replaced by the per-stage counters above, which localize
        // any future stall directly instead of needing interpretation.

        fork
            drive_cube();
            collect_cube();
        join

        // ---- 1. framing ------------------------------------------------------
        chk(out_count == N_OUT,
            $sformatf("output beat count: got %0d expected %0d", out_count, N_OUT));

        chk(tlast_positions.size() == N_RANGE,
            $sformatf("TLAST count: got %0d expected %0d (once per range bin)",
                       tlast_positions.size(), N_RANGE));

        begin
            automatic bit tlast_ok = 1'b1;
            for (int k = 0; k < tlast_positions.size(); k++)
                if (tlast_positions[k] != (k+1)*N_CHIRP - 1) tlast_ok = 1'b0;
            chk(tlast_ok, $sformatf("TLAST positions not at every %0d-th beat: %p",
                                     N_CHIRP, tlast_positions));
        end

        chk(exp_ovfl == 1'b0, "exp_accum FIFO overflowed (exp_ovfl_o asserted)");

        // ---- 2. energy concentration: DC input -> everything in bin (0,0) ----
        // cell index 0 is (range=0, doppler=0) given natural output ordering.
        // Every other cell should be near-zero by comparison -- DFT of a
        // constant signal has zero energy outside bin 0 in exact math; finite
        // precision means "near zero", not exactly zero, so compare against
        // cell 0's magnitude rather than asserting an absolute threshold.
        // =====================================================================
        // CORRECTED 2 Sep. The first version of these checks was WRONG in two
        // ways, both mine, and the design was right both times:
        //
        //  (a) It asserted every angle bin must have energy. A 4-point DFT of
        //      a constant [A,A,A,A] gives X[0]=4A and X[1]=X[2]=X[3]=0
        //      EXACTLY. Bins 1-3 reading zero is the correct answer, and this
        //      file's own header says so. The check contradicted the physics
        //      it was written from.
        //
        //  (b) It asserted all energy lands in range bin 0. It does not, and
        //      cannot: window_lane applies a fixed 1024-point Hanning window
        //      regardless of the configured transform length. At N_RANGE=16
        //      the FFT therefore sees w[0..15] of a 1024-point window -- a
        //      near-zero RISING RAMP, not a flat DC. A ramp is not constant,
        //      so it leaks across range bins. The measured result is textbook
        //      leakage, symmetric about DC (range +-1 equal, range +-2 equal),
        //      which is evidence the Range FFT is correct, not broken.
        //
        // That window limitation is a REAL property worth knowing: the window
        // ROM is not parameterized by transform size, so any reduced-size run
        // is structurally meaningful but never numerically representative of
        // the real 1024-point system. Fine for this smoke test; not fine to
        // draw signal-quality conclusions from.
        //
        // What IS cleanly assertable with this stimulus:
        //   * angle bin 0 carries energy, bins 1-3 are exactly zero
        //   * every chirp is identical, so ALL energy sits at doppler bin 0
        //     -- a real check on the corner turn AND the Doppler stage
        //   * range bin 0 is the maximum (leakage decays away from DC)
        // =====================================================================
        $display("\n[CHECK] angle dimension: DC across antennas -> bin 0 only");
        begin
            automatic logic [31:0] peak = cell_pow[0][0];
            for (int lane = 0; lane < 4; lane++)
                $display("  angle bin %0d, cell 0 power = %0d", lane, cell_pow[0][lane]);

            chk(peak > 0, "angle bin 0 has no energy -- the chain produced nothing");
            for (int lane = 1; lane < 4; lane++)
                chk(cell_pow[0][lane] == 0,
                    $sformatf("angle bin %0d must be exactly 0 for a constant across antennas, got %0d",
                               lane, cell_pow[0][lane]));

            $display("\n[CHECK] doppler dimension: identical chirps -> doppler bin 0 only");
            for (int c = 0; c < N_OUT; c++) begin
                if ((c % N_CHIRP) != 0) begin
                    chk(cell_pow[c][0] <= (peak >> 6) + 1,
                        $sformatf("cell %0d (range %0d, doppler %0d) power %0d -- every chirp is identical, so all energy must be at doppler bin 0",
                                   c, c / N_CHIRP, c % N_CHIRP, cell_pow[c][0]));
                end
            end

            $display("\n[CHECK] range dimension: bin 0 is the peak (leakage expected)");
            for (int r = 1; r < N_RANGE; r++)
                chk(cell_pow[r*N_CHIRP][0] <= peak,
                    $sformatf("range bin %0d power %0d exceeds range bin 0 (%0d) -- DC-ish input must peak at range 0",
                               r, cell_pow[r*N_CHIRP][0], peak));

            $display("  range-bin profile at doppler 0 (leakage from the 1024-pt window):");
            for (int r = 0; r < N_RANGE; r++)
                if (cell_pow[r*N_CHIRP][0] != 0)
                    $display("    range %0d : %0d", r, cell_pow[r*N_CHIRP][0]);
        end

        // Let the final beat's counter increment land. The counters use
        // non-blocking assignment, so without this the last stages read one
        // short (255 of 256) purely as a sampling artifact -- out_count
        // itself was already correct at 256.
        repeat (3) @(posedge aclk);
        dump_stage_counts();

        $display("\n=================================================");
        $display(" checks: %0d   errors: %0d", checks, errors);
        if (errors == 0) $display(" RESULT: PASS");
        else             $display(" RESULT: FAIL");
        $display("=================================================\n");
        $finish;
    end

    initial begin
        #200us;
        $display("\n[FAIL] watchdog timeout -- pipeline never drained %0d beats (got %0d)",
                  N_OUT, out_count);
        dump_stage_counts();
        $display(" RESULT: FAIL");
        $finish;
    end

endmodule

`default_nettype wire
