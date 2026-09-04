// -----------------------------------------------------------------------------
// axis_skid -- AXI4-Stream register slice (skid buffer)
//
// Breaks the combinational tready path between blocks while sustaining full
// throughput (1 beat/clock) when the sink is not stalling.
//
// Why this exists: a block that does `assign s_tready = m_tready;` forwards the
// downstream ready combinationally. Chain several separately-owned blocks like
// that and tready becomes one long combinational path across the whole design,
// which no single owner can debug. Register every block boundary.
//
// Latency    : 1 cycle
// Throughput : 1 beat/clock (no bubbles)
// Resources  : ~2*(DW+UW+1) FF
// -----------------------------------------------------------------------------
`timescale 1ns / 1ps
`default_nettype none

module axis_skid #(
    parameter int DW = 32,          // tdata width
    parameter int UW = 1            // tuser width (set 1 and tie off if unused)
) (
    input  wire            aclk,
    input  wire            aresetn,

    input  wire [DW-1:0]   s_axis_tdata,
    input  wire [UW-1:0]   s_axis_tuser,
    input  wire            s_axis_tlast,
    input  wire            s_axis_tvalid,
    output wire            s_axis_tready,

    output wire [DW-1:0]   m_axis_tdata,
    output wire [UW-1:0]   m_axis_tuser,
    output wire            m_axis_tlast,
    output wire            m_axis_tvalid,
    input  wire            m_axis_tready
);

    localparam int PW = DW + UW + 1;                       // packed payload width

    wire [PW-1:0] s_payload = {s_axis_tlast, s_axis_tuser, s_axis_tdata};

    // Output register
    logic [PW-1:0] out_payload;
    logic          out_valid;

    // Skid register -- holds one beat accepted while the output was stalled
    logic [PW-1:0] skid_payload;
    logic          skid_valid;

    // Accept whenever the skid slot is free.
    assign s_axis_tready = ~skid_valid;

    wire s_fire = s_axis_tvalid & s_axis_tready;

    always_ff @(posedge aclk) begin
        if (!aresetn) begin
            out_valid  <= 1'b0;
            skid_valid <= 1'b0;
        end else begin
            // ---- load skid: input accepted while output cannot advance -----
            // Mutually exclusive with the output update below, because this
            // arm requires (out_valid && !m_axis_tready) and that arm requires
            // (!out_valid || m_axis_tready).
            if (s_fire && out_valid && !m_axis_tready) begin
                skid_valid   <= 1'b1;
                skid_payload <= s_payload;
            end

            // ---- advance output --------------------------------------------
            if (!out_valid || m_axis_tready) begin
                if (skid_valid) begin
                    out_valid   <= 1'b1;
                    out_payload <= skid_payload;
                    skid_valid  <= 1'b0;
                end else begin
                    out_valid   <= s_fire;
                    out_payload <= s_payload;
                end
            end
        end
    end

    assign {m_axis_tlast, m_axis_tuser, m_axis_tdata} = out_payload;
    assign m_axis_tvalid = out_valid;

endmodule

`default_nettype wire
