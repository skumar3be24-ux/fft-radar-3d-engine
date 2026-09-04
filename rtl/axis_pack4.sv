// -----------------------------------------------------------------------------
// axis_pack4 / axis_unpack4 -- lane packing for the 4-antenna datapath
//
// WHY PACK AT ALL
//   The antenna-parallel architecture requires all four antennas of a given
//   (range, Doppler) cell to be present on the SAME clock edge, so the 4-point
//   angle transform can be combinational and the second corner turn deleted.
//
//   Carrying four independent 32-bit streams would make that a timing accident:
//   if one lane ever slipped a beat relative to the others, antenna values from
//   different cells would be combined and the angle result would be silently
//   wrong. Packing them into one 128-bit beat makes drift structurally
//   impossible -- there is only one TVALID and one TREADY.
//
//   It also matches the DDR layout the corner turn needs: antennas contiguous,
//   so one burst fetches a whole cell.
//
//     ddr_addr = ((chirp * N_RANGE) + range) * N_ANT + antenna
//
// LANE ORDER
//   lane L occupies bits [32*L +: 32].  Lane 0 = antenna 0.
// -----------------------------------------------------------------------------
`timescale 1ns / 1ps
`default_nettype none

// ============================ 4 x 32b  ->  128b =============================
module axis_pack4 (
    input  wire         aclk,
    input  wire         aresetn,

    input  wire [127:0] s_axis_tdata,    // {ant3, ant2, ant1, ant0}
    input  wire [3:0]   s_axis_tvalid,   // one per lane
    output wire [3:0]   s_axis_tready,
    input  wire [3:0]   s_axis_tlast,
    input  wire [7:0]   s_axis_tuser,    // lanes share one BLK_EXP

    output wire [127:0] m_axis_tdata,
    output wire         m_axis_tvalid,
    input  wire         m_axis_tready,
    output wire         m_axis_tlast,
    output wire [7:0]   m_axis_tuser
);
    // Join: a beat exists only when every lane has one.
    wire all_valid = &s_axis_tvalid;

    assign m_axis_tvalid = all_valid;
    assign m_axis_tdata  = s_axis_tdata;
    assign m_axis_tuser  = s_axis_tuser;

    // Lanes are identical and identically fed, so their TLASTs coincide.
    // Take lane 0 and flag any disagreement in simulation.
    assign m_axis_tlast  = s_axis_tlast[0];

    // Broadcast the same ready to every lane, gated on the join.
    assign s_axis_tready = {4{all_valid & m_axis_tready}};

`ifndef SYNTHESIS
    always @(posedge aclk) begin
        if (aresetn && all_valid && (|s_axis_tlast) && !(&s_axis_tlast))
            $error("axis_pack4: lanes disagree on TLAST (%b) -- lanes have drifted",
                   s_axis_tlast);
    end
`endif
endmodule

// ============================ 128b  ->  4 x 32b =============================
module axis_unpack4 (
    input  wire         aclk,
    input  wire         aresetn,

    input  wire [127:0] s_axis_tdata,
    input  wire         s_axis_tvalid,
    output wire         s_axis_tready,
    input  wire         s_axis_tlast,
    input  wire [7:0]   s_axis_tuser,

    output wire [127:0] m_axis_tdata,
    output wire [3:0]   m_axis_tvalid,
    input  wire [3:0]   m_axis_tready,
    output wire [3:0]   m_axis_tlast,
    output wire [7:0]   m_axis_tuser
);
    // Fork. The naive form
    //     m_axis_tvalid = {4{s_axis_tvalid & (&m_axis_tready)}}
    // is WRONG twice over: AXI-Stream forbids TVALID depending on TREADY, and
    // it creates a combinational loop through each lane's own ready.
    //
    // Correct pattern: gate each lane's valid with the OTHER lanes' readys, so
    // a lane never sees valid&ready unless every lane is consuming the same
    // beat on the same cycle. No lane depends on its own ready.
    wire all_ready = &m_axis_tready;

    assign m_axis_tvalid[0] = s_axis_tvalid & m_axis_tready[1] & m_axis_tready[2] & m_axis_tready[3];
    assign m_axis_tvalid[1] = s_axis_tvalid & m_axis_tready[0] & m_axis_tready[2] & m_axis_tready[3];
    assign m_axis_tvalid[2] = s_axis_tvalid & m_axis_tready[0] & m_axis_tready[1] & m_axis_tready[3];
    assign m_axis_tvalid[3] = s_axis_tvalid & m_axis_tready[0] & m_axis_tready[1] & m_axis_tready[2];

    assign m_axis_tdata  = s_axis_tdata;
    assign m_axis_tlast  = {4{s_axis_tlast}};
    assign m_axis_tuser  = s_axis_tuser;
    assign s_axis_tready = all_ready;

endmodule

`default_nettype wire
