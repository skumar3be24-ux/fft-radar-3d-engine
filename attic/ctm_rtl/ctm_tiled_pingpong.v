`timescale 1ns / 1ps

module ctm_tiled_pingpong #(
    parameter DATA_WIDTH = 32,
    parameter RANGE_BINS = 1024,
    parameter CHIRPS_PER_TILE = 64,
    parameter TOTAL_CHIRPS = 256,
    parameter LANES = 4
)(
    input  wire                     clk,
    input  wire                     rst_n,
    input  wire                     start_cube, 
    
    input  wire [LANES*DATA_WIDTH-1:0] s_axis_data_in,
    input  wire                     s_axis_valid_in,
    output wire                     s_axis_ready_out,
    
    output reg  [LANES*DATA_WIDTH-1:0] m_axis_data_out,
    output reg                      m_axis_valid_out,
    output wire                     m_axis_tlast, 
    input  wire                     m_axis_ready_in
);

    localparam WORDS_PER_BANK = (32'd1 * RANGE_BINS * TOTAL_CHIRPS) / LANES; 
    localparam PTR_WIDTH = $clog2(WORDS_PER_BANK);

    (* ram_style = "block" *) reg [LANES*DATA_WIDTH-1:0] bank_A [0:WORDS_PER_BANK-1];
    (* ram_style = "block" *) reg [LANES*DATA_WIDTH-1:0] bank_B [0:WORDS_PER_BANK-1];

    // --- WRITE DOMAIN ---
    reg [PTR_WIDTH-1:0] wr_ptr;
    reg                 wr_bank; 
    reg                 bank_A_full;
    reg                 bank_B_full;

    assign s_axis_ready_out = (wr_bank == 1'b0) ? !bank_A_full : !bank_B_full;
    wire write_fire = s_axis_valid_in && s_axis_ready_out;

    // --- READ DOMAIN (BRAM FETCH) ---
    reg [PTR_WIDTH-1:0] rd_ptr;
    reg                 rd_fetch_bank;
    reg                 rd_out_bank;   
    reg [PTR_WIDTH-1:0] output_cnt;    

    wire can_fetch = (rd_fetch_bank == 1'b0) ? bank_A_full : bank_B_full;
    
    // THE ELEGANT FIX: Map AXI Backpressure directly to BRAM Enable
    // We only fetch if we have data (can_fetch) AND the output is either empty or being consumed
    wire mem_rd_en = can_fetch && (!m_axis_valid_out || m_axis_ready_in);
    wire read_fire = m_axis_valid_out && m_axis_ready_in;
    
    assign m_axis_tlast = (output_cnt == WORDS_PER_BANK - 1) && m_axis_valid_out;

    // --- FULL FLAG MANAGEMENT ---
    wire set_A_full = (write_fire && wr_bank == 1'b0 && wr_ptr == WORDS_PER_BANK - 1);
    wire clr_A_full = (read_fire  && rd_out_bank == 1'b0 && output_cnt == WORDS_PER_BANK - 1);
    
    wire set_B_full = (write_fire && wr_bank == 1'b1 && wr_ptr == WORDS_PER_BANK - 1);
    wire clr_B_full = (read_fire  && rd_out_bank == 1'b1 && output_cnt == WORDS_PER_BANK - 1);

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            bank_A_full <= 1'b0;
            bank_B_full <= 1'b0;
        end else if (start_cube) begin
            bank_A_full <= 1'b0;
            bank_B_full <= 1'b0;
        end else begin
            if (set_A_full && !clr_A_full) bank_A_full <= 1'b1;
            else if (clr_A_full && !set_A_full) bank_A_full <= 1'b0;

            if (set_B_full && !clr_B_full) bank_B_full <= 1'b1;
            else if (clr_B_full && !set_B_full) bank_B_full <= 1'b0;
        end
    end

    // --- WRITE PIPELINE ---
    always @(posedge clk) begin
        if (write_fire) begin
            if (wr_bank == 1'b0) bank_A[wr_ptr] <= s_axis_data_in;
            else                 bank_B[wr_ptr] <= s_axis_data_in;
        end
    end

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            wr_ptr  <= {PTR_WIDTH{1'b0}};
            wr_bank <= 1'b0;
        end else if (start_cube) begin
            wr_ptr  <= {PTR_WIDTH{1'b0}};
            wr_bank <= 1'b0;
        end else if (write_fire) begin
            if (wr_ptr == WORDS_PER_BANK - 1) begin
                wr_ptr  <= {PTR_WIDTH{1'b0}};
                wr_bank <= ~wr_bank;
            end else begin
                wr_ptr <= wr_ptr + 1'b1;
            end
        end
    end

    // --- READ PIPELINE (DIRECT BRAM MAPPING) ---
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            rd_ptr           <= {PTR_WIDTH{1'b0}};
            rd_fetch_bank    <= 1'b0;
            m_axis_valid_out <= 1'b0;
            m_axis_data_out  <= {LANES*DATA_WIDTH{1'b0}};
        end else if (start_cube) begin
            rd_ptr           <= {PTR_WIDTH{1'b0}};
            rd_fetch_bank    <= 1'b0;
            m_axis_valid_out <= 1'b0;
            m_axis_data_out  <= {LANES*DATA_WIDTH{1'b0}};
        end else begin
            // Valid Out Management
            if (mem_rd_en) m_axis_valid_out <= 1'b1;
            else if (m_axis_ready_in) m_axis_valid_out <= 1'b0;

            // BRAM Fetch & Output Register
            if (mem_rd_en) begin
                if (rd_fetch_bank == 1'b0) m_axis_data_out <= bank_A[rd_ptr];
                else                       m_axis_data_out <= bank_B[rd_ptr];

                if (rd_ptr == WORDS_PER_BANK - 1) begin
                    rd_ptr        <= {PTR_WIDTH{1'b0}};
                    rd_fetch_bank <= ~rd_fetch_bank;
                end else begin
                    rd_ptr <= rd_ptr + 1'b1;
                end
            end
        end
    end

    // --- OUTPUT HANDSHAKE TRACKING ---
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            output_cnt  <= {PTR_WIDTH{1'b0}};
            rd_out_bank <= 1'b0;
        end else if (start_cube) begin
            output_cnt  <= {PTR_WIDTH{1'b0}};
            rd_out_bank <= 1'b0;
        end else if (read_fire) begin
            if (output_cnt == WORDS_PER_BANK - 1) begin
                output_cnt  <= {PTR_WIDTH{1'b0}};
                rd_out_bank <= ~rd_out_bank;
            end else begin
                output_cnt <= output_cnt + 1'b1;
            end
        end
    end

endmodule