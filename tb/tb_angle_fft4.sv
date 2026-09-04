// -----------------------------------------------------------------------------
// tb_angle_fft4 -- checks the 4-point DFT against hand-computed values
//
// This asserts on DATA, not on beat counts. A shift register (which is what
// angle_fft_lane.sv actually was) fails every one of these cases.
//
// Runs in microseconds and needs no Xilinx IP.
// -----------------------------------------------------------------------------
`timescale 1ns / 1ps

module tb_angle_fft4;

    logic aclk = 0, aresetn = 0;
    always #5 aclk = ~aclk;              // 100 MHz

    logic [31:0] s_tdata;  logic s_tvalid, s_tlast;  logic [7:0] s_tuser;
    wire         s_tready;
    wire  [31:0] m_tdata;  wire  m_tvalid, m_tlast;  wire  [7:0] m_tuser;
    logic        m_tready;

    angle_fft4 dut (
        .aclk(aclk), .aresetn(aresetn),
        .s_axis_tdata(s_tdata), .s_axis_tvalid(s_tvalid),
        .s_axis_tready(s_tready), .s_axis_tlast(s_tlast), .s_axis_tuser(s_tuser),
        .m_axis_tdata(m_tdata), .m_axis_tvalid(m_tvalid),
        .m_axis_tready(m_tready), .m_axis_tlast(m_tlast), .m_axis_tuser(m_tuser)
    );

    int errors = 0, checks = 0;

    task automatic chk(input bit c, input string msg);
        checks++;
        if (!c) begin errors++; $display("  [FAIL] %s", msg); end
    endtask

    // ---- drive 4 antenna samples ------------------------------------------
    task automatic push4(input int re[4], input int im[4], input int unsigned e);
        for (int n = 0; n < 4; n++) begin
            s_tdata  <= {16'(im[n]), 16'(re[n])};
            s_tuser  <= 8'(e);
            s_tlast  <= (n == 3);
            s_tvalid <= 1'b1;
            @(posedge aclk);
            while (!s_tready) @(posedge aclk);
        end
        s_tvalid <= 1'b0;
        s_tlast  <= 1'b0;
    endtask

    // ---- collect 4 angle bins ---------------------------------------------
    task automatic pop4(output int re[4], output int im[4], output int unsigned e);
        for (int k = 0; k < 4; k++) begin
            m_tready <= 1'b1;
            @(posedge aclk);
            while (!m_tvalid) @(posedge aclk);
            re[k] = $signed(m_tdata[15:0]);
            im[k] = $signed(m_tdata[31:16]);
            e     = m_tuser;
        end
        m_tready <= 1'b0;
    endtask

    task automatic run_case(input string name,
                            input int  ire[4], input int iim[4], input int unsigned iexp,
                            input int  ere[4], input int eim[4]);
        int ore[4], oim[4];  int unsigned oexp;
        $display("\n[TEST] %s", name);
        fork
            push4(ire, iim, iexp);
            pop4 (ore, oim, oexp);
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
        $display("  X = [(%0d,%0d) (%0d,%0d) (%0d,%0d) (%0d,%0d)]  exp %0d -> %0d",
                 ore[0],oim[0], ore[1],oim[1], ore[2],oim[2], ore[3],oim[3], iexp, oexp);
    endtask

    initial begin
        s_tvalid = 0; s_tlast = 0; s_tdata = 0; s_tuser = 0; m_tready = 0;
        repeat (8) @(posedge aclk);
        aresetn = 1;
        repeat (4) @(posedge aclk);

        $display("\n=================================================");
        $display(" angle_fft4 -- 4-point DFT value checks");
        $display("=================================================");

        // ---- impulse: x = [A,0,0,0]  ->  X[k] = A for all k -----------------
        // A = 16384, /4 scaling -> every bin 4096
        run_case("impulse -> flat spectrum",
                 '{16384, 0, 0, 0}, '{0, 0, 0, 0}, 5,
                 '{4096, 4096, 4096, 4096}, '{0, 0, 0, 0});

        // ---- DC: x = [A,A,A,A]  ->  X[0] = 4A, rest 0 ----------------------
        // A = 4096 -> X[0] = 16384, /4 -> 4096
        run_case("DC -> energy only in bin 0",
                 '{4096, 4096, 4096, 4096}, '{0, 0, 0, 0}, 3,
                 '{4096, 0, 0, 0}, '{0, 0, 0, 0});

        // ---- rotating phasor x[n] = A * j^n  ->  single peak at k = 1 -------
        // X[1] = 4A = 32768, /4 -> 8192.  This is the case a shift register
        // cannot fake: it requires the -j twiddles to be applied correctly.
        run_case("phasor j^n -> single peak at bin 1",
                 '{8192, 0, -8192, 0}, '{0, 8192, 0, -8192}, 7,
                 '{0, 8192, 0, 0}, '{0, 0, 0, 0});

        // ---- alternating x[n] = A * (-1)^n  ->  peak at k = 2 --------------
        run_case("alternating -> peak at bin 2",
                 '{4096, -4096, 4096, -4096}, '{0, 0, 0, 0}, 0,
                 '{0, 0, 4096, 0}, '{0, 0, 0, 0});

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
