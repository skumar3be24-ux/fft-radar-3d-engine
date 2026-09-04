// =============================================================================
// ctm_stub -- CORNER TURN: INTERFACE CONTRACT + BEHAVIOURAL MODEL
//
// >>> THE REAL BLOCK IS OWNED BY SOMEONE ELSE. THIS IS THE SPEC + A STAND-IN <<<
//
// Replace this instance in radar_dsp_3d_top.sv with the real DDR-backed block.
// Nothing else in the pipeline should need to change.
//
// =============================================================================
// 1. WHAT IT MUST DO
// =============================================================================
// The Range FFT emits RANGE-FASTEST (one chirp at a time).
// The Doppler FFT needs CHIRP-FASTEST (one range bin across all chirps).
// The corner turn is the transpose between them.
//
//   written:  for c in 0..N_CHIRP-1        read:  for r in 0..N_RANGE-1
//               for r in 0..N_RANGE-1               for c in 0..N_CHIRP-1
//                 write beat (c,r)                    read beat (c,r)
//
// BOTH SIDES USE THE SAME ADDRESS FUNCTION. Only the loop nesting differs:
//
//     addr(c,r) = c * N_RANGE + r
//
// If the read uses a different formula from the write it fetches unrelated
// elements. That is the defect found in both earlier CTM versions on 31 Aug:
// one used `rd_chirp + rd_range*128` against a write of `wr_range +
// wr_chirp*512` (agreeing at 2 addresses out of 65 536); the other simply
// incremented the read pointer, performing no transpose at all.
//
// =============================================================================
// 2. WHY THE BUS IS 128 BITS
// =============================================================================
// One beat = one (range, chirp) cell for ALL FOUR ANTENNAS:
//
//     tdata[ 31:  0] = antenna 0   {Im[15:0], Re[15:0]}  Q1.15
//     tdata[ 63: 32] = antenna 1
//     tdata[ 95: 64] = antenna 2
//     tdata[127: 96] = antenna 3
//
// Two reasons, both load-bearing:
//
//   a) The four Doppler lanes must stay in LOCKSTEP, or the angle transform
//      combines antennas from different cells. One TVALID/TREADY makes drift
//      structurally impossible.
//
//   b) It is the DDR layout that performs. Antennas contiguous means one burst
//      fetches a whole cell:
//
//          byte_addr = (chirp * N_RANGE + range) * 16
//
//      Reading 16 consecutive range bins is then 256 contiguous bytes.
//      Scatter the antennas instead and you get 16-byte reads, which collapse
//      DDR throughput no matter how wide the bus is. Measured on Zynq: 128-byte
//      transfers achieved 6 MB/s where 16 MB transfers achieved 1 539 MB/s --
//      a 252x swing from access pattern alone.
//
// =============================================================================
// 3. MANDATORY REQUIREMENTS
// =============================================================================
//  1. FULL BACKPRESSURE BOTH PORTS. s_axis_tready must be able to go low.
//     Tying it to 1'b1 silently drops data the instant the writer outruns the
//     memory. tb_ctm_transpose.sv fails a block that never deasserts TREADY.
//
//  2. PING-PONG. Frame k+1 must be accepted while frame k is read out, or the
//     pipeline stalls a whole frame every frame. Read-side and write-side bank
//     selects must be SEPARATE registers -- sharing one corrupts the read when
//     the write side flips it mid-frame.
//
//  3. BLK_EXP PASSTHROUGH on tuser. Constant across a frame. Losing it makes
//     the output scale unrecoverable.
//
//  4. TLAST on the final beat of each output frame.
//
//  5. CAPACITY -- READ BEFORE CHOOSING AN ARCHITECTURE.
//
//        cube  = 1024 range x 256 chirp x 16 B  =  4.19 MB
//        ping-pong needs two of those           =  8.39 MB
//        XC7K325T total Block RAM               =  2.00 MB
//
//     IT DOES NOT FIT ON CHIP. Not at these dimensions, not on this device, in
//     no arrangement. The real block MUST be DDR-backed. MIG is already
//     generated in ctm_test/. Keep only a working slice on chip:
//
//        working buffer = 16..32 range bins x N_CHIRP x 16 B
//                       = 64..128 kB   (a few percent of BRAM)
//
//     Structure: stream writes to DDR sequentially (fast); read back in
//     range-BLOCKS, not single rows. One row at a time means one useful word
//     per DRAM row activation and the bandwidth disappears.
//
//  6. CLOCK DOMAIN CROSSING -- ADDED 3 Sep, THIS CHANGES THE DESIGN.
//
//     The generated MIG (ctm_test/.../mig.prj) is configured:
//
//         TimePeriod  1250 ps  ->  800 MHz memory clock (DDR3-1600)
//         PHYRatio    4:1      ->  ui_clk = 200 MHz
//         DataWidth   64 bits
//
//     The MIG user interface therefore runs at 200 MHz. This pipeline is
//     constrained at 100 MHz (constraints/ooc_radar_dsp_3d_top.xdc). The
//     corner turn spans TWO CLOCK DOMAINS:
//
//         write side : 100 MHz aclk   (from the Range FFT via axis_pack4)
//         DDR side   : 200 MHz ui_clk (MIG native/AXI interface)
//         read side  : 100 MHz aclk   (to the Doppler lanes)
//
//     Running the whole DSP at 200 MHz is NOT an option: measured
//     post-synthesis Fmax is 182 MHz (WNS +4.505 ns at 100 MHz), and
//     post-route will be lower. It will not close.
//
//     So the CDC belongs INSIDE this block: asynchronous FIFOs on the
//     write and read paths, with the AXI-Stream ports staying on aclk so
//     nothing else in the pipeline changes. Everything specified in
//     sections 1-5 above still applies unchanged on the aclk side.
//
//     This module's single-aclk port list is a SIMULATION MODEL
//     simplification. The real block needs ui_clk, its reset, and proper
//     CDC constraints (set_max_delay -datapath_only, or whatever the
//     chosen FIFO primitive requires). tb_ctm_transpose.sv is
//     single-clock and tests the transpose CONTRACT, not the CDC -- the
//     crossing needs its own verification.
//
//     Headroom is not the problem: 64 bits x 1600 MT/s = 12.8 GB/s
//     theoretical against the 819 MB/s required below. Even at poor
//     efficiency there is enormous margin. The difficulty is correctness
//     across the crossing, not throughput.
//
//  7. REQUIRED BANDWIDTH is independent of transform size:
//
//        BW = 2 * bytes_per_sample * N_rx * f_sample
//           = 2 * 4 * 4 * 25.6 MSPS  =  819 MB/s
//
//     N_range and N_chirp cancel exactly -- a bigger FFT means more data but a
//     proportionally longer frame. You cannot buy headroom by shrinking the
//     transform.
//
// =============================================================================
// 4. THIS MODEL
// =============================================================================
// Behavioural only. Allocates the whole cube as a flat array: fine in
// simulation at small dimensions, WILL NOT SYNTHESISE at full size. Use small
// N_RANGE / N_CHIRP in testbenches and in build_synth.tcl until the real block
// lands.
//
// CONFIRMED 2 Sep: "will not synthesise at full size" undersold it. Vivado's
// synth_design RTL elaborator has an internal ceiling around 1,000,000 bits
// for one flattened array variable. That is a synthesis FRONT-END parser
// limit, unrelated to real BRAM budget (445 RAMB36 =~ 16 Mb, plenty) -- and
// it fires at ANY cube worth simulating. Even the reduced check_elab.tcl
// cube (256 range x 16 chirp) hits it: 2 banks x 4096 x 128b = 1,048,576
// bits > the ~1,000,000 limit. The real build_synth.tcl cube (1024x16 =
// 4.19 Mbit) was never going to get past this either.
//
// Fix: stop asking one array-based implementation to serve both simulation
// and synthesis. `` `ifdef SYNTHESIS `` below swaps the whole body for a
// trivial 1-deep register stage -- zero array, full AXI-Stream backpressure,
// tuser/tlast passthrough, port-compatible, but NOT a transpose. Its only
// job is letting the REST of the pipeline elaborate/synthesize around this
// instance. check_elab.tcl and build_synth.tcl pass `-verilog_define
// SYNTHESIS` explicitly so this path is selected deterministically, not by
// relying on whatever Vivado's synth_design does or doesn't predefine.
// xvlog (used by run_unit_tests.ps1 / tb_ctm_transpose.sv) does not define
// it, so simulation always gets the real transpose model below.
//
// DO NOT trust utilization or timing numbers for this instance from any
// build that used the SYNTHESIS branch -- they describe a register, not a
// corner turn. Swap in the real block before those numbers mean anything.
// =============================================================================
`timescale 1ns / 1ps
`default_nettype none

module ctm_stub #(
    parameter int N_RANGE = 64,
    parameter int N_CHIRP = 16
) (
    input  wire         aclk,
    input  wire         aresetn,

    // from Range FFT -- range fastest
    input  wire [127:0] s_axis_tdata,
    input  wire         s_axis_tvalid,
    output wire         s_axis_tready,
    input  wire         s_axis_tlast,
    input  wire [7:0]   s_axis_tuser,

    // to Doppler FFT -- chirp fastest
    output wire [127:0] m_axis_tdata,
    output wire         m_axis_tvalid,
    input  wire         m_axis_tready,
    output wire         m_axis_tlast,
    output wire [7:0]   m_axis_tuser
);

`ifdef SYNTHESIS
    // =========================================================================
    // SYNTHESIS-ONLY PLACEHOLDER -- see the "CONFIRMED 2 Sep" note above.
    // A trivial 1-deep register, NOT a transpose. Exists only so synth_design
    // can elaborate the rest of the pipeline around this instance without
    // hitting the array-size ceiling. Full AXI-Stream backpressure and
    // tuser/tlast passthrough so downstream connectivity checks are still
    // meaningful -- the DATA ORDERING is not.
    // =========================================================================
    logic [127:0] d_r;
    logic [7:0]   u_r;
    logic         l_r, v_r;

    assign s_axis_tready = ~v_r | m_axis_tready;

    always_ff @(posedge aclk) begin
        if (!aresetn) begin
            v_r <= 1'b0;
        end else if (s_axis_tready) begin
            v_r <= s_axis_tvalid;
            if (s_axis_tvalid) begin
                d_r <= s_axis_tdata;
                u_r <= s_axis_tuser;
                l_r <= s_axis_tlast;
            end
        end
    end

    assign m_axis_tdata  = d_r;
    assign m_axis_tvalid = v_r;
    assign m_axis_tuser  = u_r;
    assign m_axis_tlast  = l_r;

`else
    // =========================================================================
    // SIMULATION MODEL -- the real transpose behaviour described in
    // sections 1-3 above. This is what tb_ctm_transpose.sv actually checks.
    // =========================================================================
    localparam int CUBE = N_RANGE * N_CHIRP;

    logic [127:0] mem  [0:1][0:CUBE-1];
    logic [7:0]   mexp [0:1];
    logic         full [0:1];
    logic         wr_bank, rd_bank;

    logic [$clog2(N_RANGE)-1:0] wr_r, rd_r;
    logic [$clog2(N_CHIRP)-1:0] wr_c, rd_c;

    // Identical on both sides. Only the traversal order differs.
    function automatic int addr(input int c, input int r);
        addr = c * N_RANGE + r;
    endfunction

    assign s_axis_tready = ~full[wr_bank];
    wire in_fire  = s_axis_tvalid & s_axis_tready;
    wire out_fire = m_axis_tvalid & m_axis_tready;

    wire wr_last = (wr_c == N_CHIRP-1) && (wr_r == N_RANGE-1);
    wire rd_last = (rd_r == N_RANGE-1) && (rd_c == N_CHIRP-1);

    // ---- write: range fastest ----------------------------------------------
    always_ff @(posedge aclk) begin
        if (!aresetn) begin
            wr_r <= '0; wr_c <= '0; wr_bank <= 1'b0;
            full[0] <= 1'b0; full[1] <= 1'b0;
        end else begin
            if (in_fire) begin
                mem[wr_bank][addr(wr_c, wr_r)] <= s_axis_tdata;
                if (wr_c == 0 && wr_r == 0) mexp[wr_bank] <= s_axis_tuser;

                if (wr_r == N_RANGE-1) begin
                    wr_r <= '0;
                    wr_c <= (wr_c == N_CHIRP-1) ? '0 : wr_c + 1'b1;
                end else wr_r <= wr_r + 1'b1;

                if (wr_last) begin
                    full[wr_bank] <= 1'b1;
                    wr_bank       <= ~wr_bank;
                end
            end
            if (out_fire && rd_last) full[rd_bank] <= 1'b0;
        end
    end

    // ---- read: chirp fastest -----------------------------------------------
    always_ff @(posedge aclk) begin
        if (!aresetn) begin
            rd_r <= '0; rd_c <= '0; rd_bank <= 1'b0;
        end else if (out_fire) begin
            if (rd_c == N_CHIRP-1) begin
                rd_c <= '0;
                rd_r <= (rd_r == N_RANGE-1) ? '0 : rd_r + 1'b1;
            end else rd_c <= rd_c + 1'b1;

            if (rd_last) rd_bank <= ~rd_bank;
        end
    end

    assign m_axis_tvalid = full[rd_bank];
    assign m_axis_tdata  = mem[rd_bank][addr(rd_c, rd_r)];
    assign m_axis_tuser  = mexp[rd_bank];
    assign m_axis_tlast  = rd_last && m_axis_tvalid;
`endif

endmodule

`default_nettype wire
