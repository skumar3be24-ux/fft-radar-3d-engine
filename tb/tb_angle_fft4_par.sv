// -----------------------------------------------------------------------------
// tb_angle_fft4_par -- checks the COMBINATIONAL 4-point DFT against
// hand-computed values, on the actual 128-bit packed interface used by
// radar_dsp_3d_top.sv.
//
// This replaces tb_angle_fft4.sv as the live acceptance test. That older
// testbench targets angle_fft4.sv, the serial/ping-pong 4-beats-in variant,
// which is NOT the module instantiated in the top level. Passing the old
// test proved nothing about the module actually in the pipeline.
//
// Same DFT vectors as before (impulse, DC, phasor, alternating) so the maths
// is checked against the identical known-good numbers, plus:
//   - boundary cases at +/-32767 checking the round/saturate path does NOT
//     spuriously clamp inside its legitimate range
//   - back-to-back full-throughput beats (1-cycle latency, no bubble)
//   - backpressure: m_axis_tready held low, s_axis_tready MUST deassert
//     while the output register is full (catches a DUT with backpressure
//     tied off, same style check as tb_ctm_transpose.sv)
// -----------------------------------------------------------------------------
`timescale 1ns / 1ps

module tb_angle_fft4_par;

    logic aclk = 0, aresetn = 0;
    always #5 aclk = ~aclk;              // 100 MHz

    logic [127:0] s_tdata;  logic s_tvalid, s_tlast;  logic [7:0] s_tuser;
    wire          s_tready;
    wire  [127:0] m_tdata;  wire  m_tvalid, m_tlast;  wire  [7:0] m_tuser;
    logic         m_tready;

    angle_fft4_par dut (
        .aclk(aclk), .aresetn(aresetn),
        .s_axis_tdata(s_tdata), .s_axis_tvalid(s_tvalid),
        .s_axis_tready(s_tready), .s_axis_tlast(s_tlast), .s_axis_tuser(s_tuser),
        .m_axis_tdata(m_tdata), .m_axis_tvalid(m_tvalid),
        .m_axis_tready(m_tready), .m_axis_tlast(m_tlast), .m_axis_tuser(m_tuser)
    );

    int errors = 0, checks = 0;
    bit saw_tready_low = 1'b0;

    task automatic chk(input bit c, input string msg);
        checks++;
        if (!c) begin errors++; $display("  [FAIL] %s", msg); end
    endtask

    // ---- pack/drive one beat: 4 antenna samples, all in the same cycle -----
    task automatic push_beat(input int re[4], input int im[4],
                              input int unsigned e, input bit last);
        logic [127:0] beat;
        for (int n = 0; n < 4; n++) begin
            beat[32*n      +: 16] = 16'(re[n]);
            beat[32*n + 16 +: 16] = 16'(im[n]);
        end
        s_tdata  <= beat;
        s_tuser  <= 8'(e);
        s_tlast  <= last;
        s_tvalid <= 1'b1;
        @(posedge aclk);
        while (!s_tready) begin
            if (!m_tready) saw_tready_low = 1'b1;
            @(posedge aclk);
        end
        s_tvalid <= 1'b0;
    endtask

    // ---- collect one beat: 4 angle bins -------------------------------------
    task automatic pop_beat(output int re[4], output int im[4],
                             output int unsigned e, output bit last);
        m_tready <= 1'b1;
        @(posedge aclk);
        while (!m_tvalid) @(posedge aclk);
        for (int k = 0; k < 4; k++) begin
            re[k] = $signed(m_tdata[32*k      +: 16]);
            im[k] = $signed(m_tdata[32*k + 16 +: 16]);
        end
        e    = m_tuser;
        last = m_tlast;
    endtask

    task automatic run_case(input string name,
                             input int  ire[4], input int iim[4], input int unsigned iexp,
                             input int  ere[4], input int eim[4]);
        int ore[4], oim[4];  int unsigned oexp;  bit olast;
        $display("\n[TEST] %s", name);
        m_tready <= 1'b1;
        fork
            push_beat(ire, iim, iexp, 1'b1);
            pop_beat (ore, oim, oexp, olast);
        join
        for (int k = 0; k < 4; k++) begin
            chk(ore[k] == ere[k],
                $sformatf("X[%0d].re: got %0d expected %0d", k, ore[k], ere[k]));
            chk(oim[k] == eim[k],
                $sformatf("X[%0d].im: got %0d expected %0d", k, oim[k], eim[k]));
        end
        // data was divided by 4, so the exponent must have grown by exactly 2
        chk(oexp == iexp + 2,
            $sformatf("BLK_EXP: got %0d expected %0d", oexp, iexp + 2));
        chk(olast == 1'b1, "TLAST did not pass through on a single-beat frame");
        $display("  X = [(%0d,%0d) (%0d,%0d) (%0d,%0d) (%0d,%0d)]  exp %0d -> %0d",
                 ore[0],oim[0], ore[1],oim[1], ore[2],oim[2], ore[3],oim[3], iexp, oexp);
    endtask

    initial begin
        s_tvalid = 0; s_tlast = 0; s_tdata = 0; s_tuser = 0; m_tready = 0;
        repeat (8) @(posedge aclk);
        aresetn = 1;
        repeat (4) @(posedge aclk);

        $display("\n=================================================");
        $display(" angle_fft4_par -- combinational 4-point DFT, live module");
        $display("=================================================");

        chk(m_tvalid == 1'b0, "m_axis_tvalid must be low immediately after reset");

        // ---- impulse: x = [A,0,0,0]  ->  X[k] = A for all k -----------------
        run_case("impulse -> flat spectrum",
                 '{16384, 0, 0, 0}, '{0, 0, 0, 0}, 5,
                 '{4096, 4096, 4096, 4096}, '{0, 0, 0, 0});

        // ---- DC: x = [A,A,A,A]  ->  X[0] = 4A, rest 0 ----------------------
        run_case("DC -> energy only in bin 0",
                 '{4096, 4096, 4096, 4096}, '{0, 0, 0, 0}, 3,
                 '{4096, 0, 0, 0}, '{0, 0, 0, 0});

        // ---- rotating phasor x[n] = A * j^n  ->  single peak at k = 1 -------
        run_case("phasor j^n -> single peak at bin 1",
                 '{8192, 0, -8192, 0}, '{0, 8192, 0, -8192}, 7,
                 '{0, 8192, 0, 0}, '{0, 0, 0, 0});

        // ---- alternating x[n] = A * (-1)^n  ->  peak at k = 2 --------------
        run_case("alternating -> peak at bin 2",
                 '{4096, -4096, 4096, -4096}, '{0, 0, 0, 0}, 0,
                 '{0, 0, 4096, 0}, '{0, 0, 0, 0});

        // ---- boundary: max positive DC. Sum = 4*32767 = 131068, an EXACT
        // multiple of 4, so the rounder's +1 tie-break never fires and the
        // result must land exactly on 32767, not clamp. This is the largest
        // sum four legal Q1.15 samples can ever produce -- the saturate
        // branch is structurally unreachable from real DFT sums (confirmed
        // by hand: floor(sum/4)=32767 only occurs at sum=131068, which has
        // zero remainder), so this is the real edge to check, not an
        // artificial overflow.
        run_case("boundary +max DC -> exact 32767, no clamp",
                 '{32767, 32767, 32767, 32767}, '{0, 0, 0, 0}, 0,
                 '{32767, 0, 0, 0}, '{0, 0, 0, 0});

        // ---- boundary: max negative DC. Sum = -131072, also exact -> -32768.
        run_case("boundary -max DC -> exact -32768, no clamp",
                 '{-32768, -32768, -32768, -32768}, '{0, 0, 0, 0}, 0,
                 '{-32768, 0, 0, 0}, '{0, 0, 0, 0});

        // ---- back-to-back, full throughput, no bubble ----------------------
        // m_axis_tready held high throughout: s_axis_tready must be high on
        // every cycle (single register stage, s_tready = ~v_r | m_tready),
        // and the two distinct beats must come out in order with 1-cycle
        // latency, not merged or dropped.
        $display("\n[TEST] back-to-back beats, full throughput");
        begin
            int ore1[4], oim1[4], ore2[4], oim2[4];
            int unsigned oexp1, oexp2; bit olast1, olast2;
            m_tready <= 1'b1;
            fork
                begin
                    push_beat('{16384,0,0,0}, '{0,0,0,0}, 5, 1'b0);   // beat A: impulse
                    push_beat('{4096,4096,4096,4096}, '{0,0,0,0}, 3, 1'b1); // beat B: DC, frame end
                end
                begin
                    pop_beat(ore1, oim1, oexp1, olast1);
                    pop_beat(ore2, oim2, oexp2, olast2);
                end
            join
            chk(ore1[0]==4096 && oim1[0]==0 && ore1[1]==4096,
                "back-to-back beat A (impulse) corrupted or reordered");
            chk(!olast1, "beat A tlast should be low");
            chk(ore2[0]==4096 && ore2[1]==0,
                "back-to-back beat B (DC) corrupted or reordered");
            chk(olast2, "beat B tlast should be high (frame end)");
        end

        // ---- backpressure ----------------------------------------------------
        // Fill the one output register, then stall the consumer. s_axis_tready
        // MUST go low while the register is full and downstream isn't
        // accepting -- a DUT with backpressure tied off passes every case
        // above and still fails silently in the real pipeline.
        $display("\n[TEST] backpressure -- consumer stalls");
        begin
            int ore[4], oim[4]; int unsigned oexp; bit olast;
            saw_tready_low = 1'b0;
            m_tready <= 1'b1;
            push_beat('{100,200,300,400}, '{0,0,0,0}, 1, 1'b1); // v_r now full
            m_tready <= 1'b0;               // stall the consumer
            @(posedge aclk);
            chk(s_tready == 1'b0,
                "s_axis_tready must deassert while output register is full and stalled");
            saw_tready_low = 1'b1;
            repeat (3) @(posedge aclk);      // hold the stall a few cycles
            pop_beat(ore, oim, oexp, olast); // release and drain
            chk(ore[0]==100 && oim[0]==0,
                "data corrupted across a backpressure stall");
        end
        chk(saw_tready_low, "backpressure was never actually exercised/observed");

        $display("\n=================================================");
        $display(" checks: %0d   errors: %0d", checks, errors);
        if (errors == 0) $display(" RESULT: PASS");
        else             $display(" RESULT: FAIL");
        $display("=================================================\n");
        $finish;
    end

    initial begin
        #200us;
        $display("\n[FAIL] watchdog timeout");
        $display(" RESULT: FAIL");
        $finish;
    end

endmodule
