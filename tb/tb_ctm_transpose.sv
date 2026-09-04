// =============================================================================
// tb_ctm_transpose -- ACCEPTANCE TEST FOR THE CORNER TURN
//
// Hand this to whoever builds the real corner turn. Point the DUT instance at
// their module and it must pass unchanged.
//
// WHY THIS EXISTS
//   The previous 3-D testbench reported
//       "3D PIPELINE PASSED!  Output Words Processed: 65536 / 65536"
//   That is a BEAT COUNT. A plain FIFO passes it. A block returning garbage
//   passes it. Both earlier corner-turn versions passed it while transposing
//   incorrectly or not at all.
//
//   This checks WHICH cell came out, in WHAT ORDER, on WHICH antenna lane.
//
// METHOD
//   Every 32-bit lane is self-identifying:
//       tdata[32L +: 32] = { lane[7:0], chirp[7:0], range[15:0] }
//
//   Written range-fastest, it must return chirp-fastest. For output beat k:
//       c = k % N_CHIRP
//       r = k / N_CHIRP
//   and every lane L must carry {L, c, r}.
//
//   Also checked: TLAST placement, TUSER survival, and that TREADY actually
//   deasserts -- a block with tready tied high fails the backpressure case.
// =============================================================================
`timescale 1ns / 1ps

module tb_ctm_transpose;

    localparam int N_RANGE = 16;
    localparam int N_CHIRP = 8;
    localparam int CUBE    = N_RANGE * N_CHIRP;
    localparam int EXP_VAL = 9;

    logic aclk = 0, aresetn = 0;
    always #5 aclk = ~aclk;

    logic [127:0] s_tdata;  logic s_tvalid, s_tlast;  logic [7:0] s_tuser;
    wire          s_tready;
    wire  [127:0] m_tdata;  wire  m_tvalid, m_tlast;  wire  [7:0] m_tuser;
    logic         m_tready;

    // <<< POINT THIS AT THE REAL BLOCK WHEN IT ARRIVES >>>
    ctm_stub #(.N_RANGE(N_RANGE), .N_CHIRP(N_CHIRP)) dut (
        .aclk(aclk), .aresetn(aresetn),
        .s_axis_tdata(s_tdata), .s_axis_tvalid(s_tvalid),
        .s_axis_tready(s_tready), .s_axis_tlast(s_tlast), .s_axis_tuser(s_tuser),
        .m_axis_tdata(m_tdata), .m_axis_tvalid(m_tvalid),
        .m_axis_tready(m_tready), .m_axis_tlast(m_tlast), .m_axis_tuser(m_tuser)
    );

    int  errors = 0, checks = 0;
    bit  saw_tready_low = 0;

    task automatic chk(input bit c, input string msg);
        checks++;
        if (!c) begin
            errors++;
            if (errors <= 12) $display("  [FAIL] %s", msg);
        end
    endtask

    function automatic logic [31:0] tag(input int lane, input int c, input int r);
        tag = {8'(lane), 8'(c), 16'(r)};
    endfunction

    always @(posedge aclk)
        if (aresetn && !s_tready) saw_tready_low <= 1'b1;

    // ---- writer: range fastest --------------------------------------------
    task automatic write_cube(input int gap_pct);
        for (int c = 0; c < N_CHIRP; c++)
        for (int r = 0; r < N_RANGE; r++) begin
            while (gap_pct > 0 && ($urandom_range(99) < gap_pct)) begin
                s_tvalid <= 1'b0;
                @(posedge aclk);
            end
            for (int L = 0; L < 4; L++) s_tdata[32*L +: 32] <= tag(L, c, r);
            s_tuser  <= 8'(EXP_VAL);
            s_tlast  <= (c == N_CHIRP-1) && (r == N_RANGE-1);
            s_tvalid <= 1'b1;
            @(posedge aclk);
            while (!s_tready) @(posedge aclk);
        end
        s_tvalid <= 1'b0;
        s_tlast  <= 1'b0;
    endtask

    // ---- reader: must be chirp fastest ------------------------------------
    task automatic read_and_check(input int stall_pct);
        int exp_r, exp_c;
        for (int k = 0; k < CUBE; k++) begin
            m_tready <= !(stall_pct > 0 && ($urandom_range(99) < stall_pct));
            @(posedge aclk);
            while (!(m_tvalid && m_tready)) begin
                m_tready <= !(stall_pct > 0 && ($urandom_range(99) < stall_pct));
                @(posedge aclk);
            end

            exp_c = k % N_CHIRP;
            exp_r = k / N_CHIRP;

            for (int L = 0; L < 4; L++)
                chk(m_tdata[32*L +: 32] == tag(L, exp_c, exp_r),
                    $sformatf("beat %0d lane %0d: got %08x expected %08x (r=%0d c=%0d)",
                              k, L, m_tdata[32*L +: 32], tag(L, exp_c, exp_r),
                              exp_r, exp_c));

            chk(m_tuser == EXP_VAL,
                $sformatf("beat %0d: BLK_EXP lost, got %0d expected %0d",
                          k, m_tuser, EXP_VAL));
            chk(m_tlast == (k == CUBE-1),
                $sformatf("beat %0d: TLAST wrong (%0b)", k, m_tlast));
        end
        m_tready <= 1'b0;
    endtask

    task automatic run_case(input string name, input int gap, input int stall);
        $display("\n[TEST] %s  (gaps %0d%%, stalls %0d%%)", name, gap, stall);
        fork
            write_cube(gap);
            read_and_check(stall);
        join
        $display("  %0d beats x 4 lanes checked", CUBE);
    endtask

    initial begin
        s_tvalid = 0; s_tlast = 0; s_tdata = '0; s_tuser = 0; m_tready = 0;
        repeat (8) @(posedge aclk);
        aresetn = 1;
        repeat (4) @(posedge aclk);

        $display("\n=================================================");
        $display(" CORNER TURN ACCEPTANCE TEST");
        $display(" %0d range x %0d chirp x 4 ant packed = %0d beats of 128b",
                 N_RANGE, N_CHIRP, CUBE);
        $display("=================================================");

        run_case("clean",            0,  0);
        run_case("source gaps",     30,  0);
        run_case("sink stalls",      0, 40);
        run_case("gaps and stalls", 25, 50);

        chk(saw_tready_low,
            "TREADY never went low -- backpressure is not implemented");

        $display("\n=================================================");
        $display(" checks: %0d   errors: %0d", checks, errors);
        if (errors == 0) $display(" RESULT: PASS");
        else             $display(" RESULT: FAIL  (first 12 shown)");
        $display("=================================================\n");
        $finish;
    end

    initial begin
        #5ms;
        $display("\n[FAIL] watchdog timeout -- corner turn stalled");
        $display(" RESULT: FAIL");
        $finish;
    end

endmodule
