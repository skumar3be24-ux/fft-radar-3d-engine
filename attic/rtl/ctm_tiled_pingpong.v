`timescale 1ns / 1ps
module ctm_tiled_pingpong(
    input  logic clk,
    input  logic rst_n,
    
    // AXI4-Stream IN (From Range FFT)
    input  logic [31:0] s_axis_tdata,
    input  logic        s_axis_tvalid,
    output logic        s_axis_tready,
    
    // AXI4-Stream OUT (To Doppler FFT)
    output logic [31:0] m_axis_tdata,
    output logic        m_axis_tvalid,
    input  logic        m_axis_tready
);

    localparam MEM_DEPTH = 65536;
    
    (* ram_style = "block" *) logic [31:0] bank_A [0:MEM_DEPTH-1];
    (* ram_style = "block" *) logic [31:0] bank_B [0:MEM_DEPTH-1];
    
    logic bank_sel; 
    logic [15:0] wr_range_idx, wr_chirp_idx;
    logic [15:0] rd_range_idx, rd_chirp_idx;
    
    logic frame_complete;
    logic read_enable; // NEW: Prevents reading garbage memory
    
    // Write Datapath
    assign s_axis_tready = 1'b1; 
    wire [15:0] wr_addr = wr_range_idx + (wr_chirp_idx * 512);
    
    always_ff @(posedge clk) begin
        if (!rst_n) begin
            wr_range_idx <= 0;
            wr_chirp_idx <= 0;
            frame_complete <= 0;
            bank_sel <= 0;
            read_enable <= 0;
        end else begin
            // Latch read_enable high once the first frame finishes
            if (frame_complete) read_enable <= 1'b1;
            
            if (s_axis_tvalid && s_axis_tready) begin
                if (bank_sel == 1'b0) bank_A[wr_addr] <= s_axis_tdata;
                else                  bank_B[wr_addr] <= s_axis_tdata;
                
                if (wr_range_idx == 511) begin
                    wr_range_idx <= 0;
                    if (wr_chirp_idx == 127) begin
                        wr_chirp_idx <= 0;
                        frame_complete <= 1'b1;
                        bank_sel <= ~bank_sel; 
                    end else begin
                        wr_chirp_idx <= wr_chirp_idx + 1;
                        frame_complete <= 1'b0;
                    end
                end else begin
                    wr_range_idx <= wr_range_idx + 1;
                    frame_complete <= 1'b0;
                end
            end else begin
                frame_complete <= 1'b0;
            end
        end
    end

    // Read Datapath (Strided / Corner-Turned)
    wire [15:0] rd_addr = rd_chirp_idx + (rd_range_idx * 128);
    logic [31:0] rd_data_reg;
    logic rd_valid_reg;
    
    always_ff @(posedge clk) begin
        if (!rst_n) begin
            rd_range_idx <= 0;
            rd_chirp_idx <= 0;
            rd_valid_reg <= 0;
            rd_data_reg <= 32'd0;
        end else if (m_axis_tready && read_enable) begin // NEW: Gated by read_enable
            if (bank_sel == 1'b0) rd_data_reg <= bank_B[rd_addr];
            else                  rd_data_reg <= bank_A[rd_addr];
            
            rd_valid_reg <= 1'b1;
            
            if (rd_chirp_idx == 127) begin
                rd_chirp_idx <= 0;
                if (rd_range_idx == 511) rd_range_idx <= 0;
                else                     rd_range_idx <= rd_range_idx + 1;
            end else begin
                rd_chirp_idx <= rd_chirp_idx + 1;
            end
        end else begin
            rd_valid_reg <= 0;
        end
    end
    
    assign m_axis_tdata = rd_data_reg;
    assign m_axis_tvalid = rd_valid_reg;

endmodule