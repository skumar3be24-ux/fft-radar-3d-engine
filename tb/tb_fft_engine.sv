// -----------------------------------------------------------------------------
// tb_fft_engine -- self-checking testbench for fft_engine_top
//
// Deliberately has NO external dependencies (no Python, no data files). It
// generates its own stimulus with SystemVerilog real math and checks structural
// properties plus peak-bin position. That is enough to catch the one thing
// synthesis cannot: whether the config word field layout is correct.
//
// Checks performed per frame:
//   C1  beat count == N
//   C2  TLAST asserted exactly once, on the final beat
//   C3  TUSER (BLK_EXP) constant across all N beats
//   C4  no X/Z on any output beat
//   C5  peak bin == the injected tone bin
//
// C5 is the important one. A wrong NFFT field gives the wrong transform size and
// the peak lands in the wrong place; a wrong FWD_INV field gives an inverse
// transform and the peak mirrors to N-k. Either way this check fails loudly.
//
// Test matrix: transform size {1024, 2048} x backpressure {clean, gaps, stalls}
// plus a runtime size switch between consecutive frames -- the case the previous
// fft_config_fsm could not do at all.
// -----------------------------------------------------------------------------
`timescale 1ns / 1ps
`default_nettype none

module tb_fft_engine;

    localparam realtime CLK_P = 10.0;      // 100 MHz, frozen spec

    logic aclk = 1'b0;
    logic aresetn = 1'b0;
    always #(CLK_P/2.0) aclk = ~aclk;

    // ---- DUT ---------------------------------------------------------------
    logic        nfft_sel;
    logic [4:0]  nfft_applied;
    logic        busy;
    logic [7:0]  blk_exp_dbg;

    logic [31:0] s_tdata;
    logic        s_tvalid, s_tready, s_tlast;

    logic [31:0] m_tdata;
    logic [7:0]  m_tuser;
    logic        m_tvalid, m_tready, m_tlast;

    fft_engine_top #(.NUM_LANES(1)) dut (
        .aclk          (aclk),
        .aresetn       (aresetn),
        .nfft_sel_i    (nfft_sel),
        .nfft_applied_o(nfft_applied),
        .busy_o        (busy),
        .blk_exp_dbg_o (blk_exp_dbg),
        .s_axis_tdata  (s_tdata),
        .s_axis_tvalid (s_tvalid),
        .s_axis_tready (s_tready),
        .s_axis_tlast  (s_tlast),
        .m_axis_tdata  (m_tdata),
        .m_axis_tuser  (m_tuser),
        .m_axis_tvalid (m_tvalid),
        .m_axis_tready (m_tready),
        .m_axis_tlast  (m_tlast)
    );

    // ---- scoreboard --------------------------------------------------------
    int errors   = 0;
    int checks   = 0;
    int frames_done = 0;

    task automatic chk(input bit cond, input string msg);
        checks++;
        if (!cond) begin
            errors++;
            $display("  [FAIL] %s", msg);
        end
    endtask

    // ---- stimulus ----------------------------------------------------------
    // Complex tone at bin k: x[n] = A * exp(j*2*pi*k*n/N)
    //
    // Amplitude 0.4, NOT 0.5. At 0.5 a full-scale tone lands exactly on the BFP
    // overflow boundary -- the ideal peak sits one LSB above Q1.15 full scale and
    // correct hardware fails the check. This is the project's recorded spec
    // error #2; do not raise this value.
    localparam real AMPL = 0.4;

    task automatic drive_frame(input int N, input int k, input int gap_pct);
        real th, re_r, im_r;
        logic signed [15:0] re_q, im_q;
        for (int n = 0; n < N; n++) begin
            // optional gap before this sample
            while (gap_pct > 0 && ($urandom_range(99) < gap_pct)) begin
                s_tvalid <= 1'b0;
                @(posedge aclk);
            end

            th   = 2.0 * 3.14159265358979 * real'(k) * real'(n) / real'(N);
            re_r = AMPL * 32767.0 * $cos(th);
            im_r = AMPL * 32767.0 * $sin(th);
            re_q = 16'(int'(re_r));
            im_q = 16'(int'(im_r));

            s_tdata  <= {im_q, re_q};          // {Q, I} per interface contract
            s_tlast  <= (n == N-1);
            s_tvalid <= 1'b1;
            @(posedge aclk);
            while (!s_tready) @(posedge aclk); // hold until accepted
        end
        s_tvalid <= 1'b0;
        s_tlast  <= 1'b0;
    endtask

    // ---- monitor -----------------------------------------------------------
    task automatic collect_frame(input int N, input int k, input int stall_pct);
        logic [31:0] obuf [];
        logic [7:0]  u0;
        int          cnt;
        int          peak_bin;
        longint      peak_mag, mag;
        int          re, im;
        bit          tuser_const;
        bit          early_tlast;

        obuf = new[N];
        cnt = 0;
        tuser_const = 1'b1;
        early_tlast = 1'b0;

        forever begin
            m_tready <= !(stall_pct > 0 && ($urandom_range(99) < stall_pct));
            @(posedge aclk);
            if (m_tvalid && m_tready) begin
                if (cnt < N) begin
                    obuf[cnt] = m_tdata;
                    if (cnt == 0) u0 = m_tuser;
                    else if (m_tuser !== u0) tuser_const = 1'b0;
                end
                if (m_tlast && (cnt != N-1)) early_tlast = 1'b1;
                cnt++;
                if (m_tlast) break;
                if (cnt > N + 16) break;       // runaway guard
            end
        end
        m_tready <= 1'b1;

        // ---- checks
        chk(cnt == N, $sformatf("C1 beat count: got %0d expected %0d", cnt, N));
        chk(!early_tlast, "C2 TLAST asserted before final beat");
        chk(tuser_const, "C3 TUSER (BLK_EXP) not constant across frame");

        peak_mag = 0; peak_bin = -1;
        for (int i = 0; i < N && i < cnt; i++) begin
            if (^obuf[i] === 1'bx) begin
                chk(1'b0, $sformatf("C4 X/Z on output beat %0d", i));
                break;
            end
            re  = int'($signed(obuf[i][15:0]));
            im  = int'($signed(obuf[i][31:16]));
            mag = longint'(re)*longint'(re) + longint'(im)*longint'(im);
            if (mag > peak_mag) begin peak_mag = mag; peak_bin = i; end
        end

        chk(peak_bin == k,
            $sformatf("C5 peak bin: got %0d expected %0d  (N=%0d, BLK_EXP=%0d)",
                      peak_bin, k, N, u0));

        $display("  N=%4d k=%4d -> peak_bin=%4d  BLK_EXP=%0d  beats=%0d",
                 N, k, peak_bin, u0, cnt);
        frames_done++;
    endtask

    // ---- one test case -----------------------------------------------------
    task automatic run_case(input string name, input bit sel, input int N,
                            input int k, input int gap_pct, input int stall_pct);
        $display("\n[TEST] %s  (gaps %0d%%, stalls %0d%%)", name, gap_pct, stall_pct);
        nfft_sel = sel;
        repeat (8) @(posedge aclk);            // let config settle at frame edge
        fork
            drive_frame(N, k, gap_pct);
            collect_frame(N, k, stall_pct);
        join
    endtask

    // ---- main --------------------------------------------------------------
    initial begin
        s_tvalid = 1'b0;
        s_tlast  = 1'b0;
        s_tdata  = '0;
        m_tready = 1'b1;
        nfft_sel = 1'b0;

        repeat (20) @(posedge aclk);
        aresetn = 1'b1;
        repeat (20) @(posedge aclk);

        $display("\n=================================================");
        $display(" fft_engine_top -- self-checking testbench");
        $display("=================================================");

        // C5 on the first case is the config-word layout check. If NFFT or
        // FWD_INV sit in the wrong bits, this is where it shows up.
        run_case("1024-pt, clean",        1'b0, 1024,  40,  0,  0);
        run_case("1024-pt, source gaps",  1'b0, 1024, 137, 30,  0);
        run_case("1024-pt, sink stalls",  1'b0, 1024, 300,  0, 40);
        run_case("1024-pt, both",         1'b0, 1024, 511, 25, 50);

        // Runtime size switch. The previous fft_config_fsm latched itself off
        // after the first handshake and could never reach this state.
        run_case("2048-pt after switch",  1'b1, 2048,  80,  0,  0);
        run_case("2048-pt, both",         1'b1, 2048, 777, 25, 50);

        // Switch back down -- proves re-arm works in both directions.
        run_case("1024-pt, switched back",1'b0, 1024,  40,  0,  0);

        $display("\n=================================================");
        $display(" frames: %0d   checks: %0d   errors: %0d", frames_done, checks, errors);
        if (errors == 0) $display(" RESULT: PASS");
        else             $display(" RESULT: FAIL");
        $display("=================================================\n");
        $finish;
    end

    // watchdog
    initial begin
        #5ms;
        $display("\n[FAIL] watchdog timeout -- engine stalled");
        $display(" RESULT: FAIL");
        $finish;
    end

endmodule

`default_nettype wire
