`timescale 1ns/1ps

module fat32_file_streamer #(
    parameter integer MAX_VISITED_CLUSTERS = 8192
) (
    input  wire        clk,
    input  wire        rst_n,
    input  wire        file_start,
    input  wire        file_abort,
    input  wire [31:0] first_cluster,
    input  wire [31:0] file_size,
    input  wire        file_continue,
    input  wire [7:0]  sectors_per_cluster,
    input  wire [31:0] fat_start_lba,
    input  wire [31:0] data_start_lba,
    input  wire [31:0] max_cluster,
    output wire        file_busy,
    output reg         file_done,
    output reg         file_valid,
    output reg  [7:0]  file_byte,
    output reg  [31:0] file_byte_offset,
    output reg  [7:0]  fs_error,
    output wire        sector_req,
    output reg  [31:0] sector_lba,
    input  wire        sector_busy,
    input  wire        sector_valid,
    input  wire [7:0]  sector_byte,
    input  wire [8:0]  sector_byte_index,
    input  wire        sector_done,
    input  wire [7:0]  sector_error
);
    localparam ERR_NONE              = 8'h00;
    localparam ERR_SECTOR            = 8'h10;
    localparam ERR_FAT_LOOP          = 8'h23;
    localparam ERR_CLUSTER_RANGE     = 8'h24;
    localparam ERR_EARLY_EOF         = 8'h25;
    localparam ERR_VISITED_EXHAUSTED = 8'h26;

    localparam ST_IDLE      = 4'd0;
    localparam ST_DATA_REQ  = 4'd1;
    localparam ST_DATA_WAIT = 4'd2;
    localparam ST_FAT_REQ   = 4'd3;
    localparam ST_FAT_WAIT  = 4'd4;
    localparam ST_FAT_PARSE = 4'd5;
    localparam ST_FINISH    = 4'd6;
    localparam ST_DATA_ADDR = 4'd7;
    localparam ST_DATA_BASE = 4'd8;
    localparam ST_DATA_NEXT = 4'd9;
    localparam ST_FAT_ADDR  = 4'd10;
    localparam ST_FAT_VALIDATE = 4'd11;
    localparam integer CHAIN_COUNT_WIDTH = $clog2(MAX_VISITED_CLUSTERS + 1);

    (* fsm_encoding="sequential" *) reg [3:0] state;
    reg [31:0] current_cluster;
    reg [31:0] cluster_sector_offset;
    reg [31:0] remaining_bytes;
    reg [7:0] sector_in_cluster;
    reg [8:0] fat_entry_offset;
    reg [7:0] fat_byte0, fat_byte1, fat_byte2, fat_byte3;
    reg [27:0] candidate_cluster;
    reg [CHAIN_COUNT_WIDTH-1:0] chain_count;
    reg final_chain_check;
    reg [2:0] sectors_per_cluster_shift;
    wire [27:0] parsed_fat_entry =
        {fat_byte3[3:0], fat_byte2, fat_byte1, fat_byte0};

    assign file_busy = (state != ST_IDLE);
    assign sector_req = (state == ST_DATA_REQ && file_continue) ||
                        (state == ST_FAT_REQ);

    function [2:0] spc_shift;
        input [7:0] value;
        begin
            case (value)
                8'd2:   spc_shift = 3'd1;
                8'd4:   spc_shift = 3'd2;
                8'd8:   spc_shift = 3'd3;
                8'd16:  spc_shift = 3'd4;
                8'd32:  spc_shift = 3'd5;
                8'd64:  spc_shift = 3'd6;
                8'd128: spc_shift = 3'd7;
                default: spc_shift = 3'd0;
            endcase
        end
    endfunction

    task finish_with_error;
        input [7:0] code;
        begin
            fs_error <= code;
            state <= ST_FINISH;
        end
    endtask

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state <= ST_IDLE;
            file_done <= 1'b0;
            file_valid <= 1'b0;
            file_byte <= 8'd0;
            file_byte_offset <= 32'd0;
            fs_error <= ERR_NONE;
            sector_lba <= 32'd0;
            current_cluster <= 32'd0;
            cluster_sector_offset <= 32'd0;
            remaining_bytes <= 32'd0;
            sector_in_cluster <= 8'd0;
            fat_entry_offset <= 9'd0;
            fat_byte0 <= 8'd0;
            fat_byte1 <= 8'd0;
            fat_byte2 <= 8'd0;
            fat_byte3 <= 8'd0;
            candidate_cluster <= 28'd0;
            chain_count <= 0;
            final_chain_check <= 1'b0;
            sectors_per_cluster_shift <= 3'd0;
        end else begin
            file_done  <= 1'b0;
            file_valid <= 1'b0;
            if (state == ST_DATA_WAIT && sector_valid && remaining_bytes != 0) begin
                file_valid <= 1'b1;
                file_byte <= sector_byte;
                file_byte_offset <= file_size - remaining_bytes;
                remaining_bytes <= remaining_bytes - 1'b1;
            end

            if (state == ST_FAT_WAIT && sector_valid) begin
                if (sector_byte_index == fat_entry_offset)
                    fat_byte0 <= sector_byte;
                else if (sector_byte_index == fat_entry_offset + 1'b1)
                    fat_byte1 <= sector_byte;
                else if (sector_byte_index == fat_entry_offset + 2'd2)
                    fat_byte2 <= sector_byte;
                else if (sector_byte_index == fat_entry_offset + 2'd3)
                    fat_byte3 <= sector_byte;
            end

            if (file_abort) begin
                state <= ST_IDLE;
                remaining_bytes <= 32'd0;
                sector_in_cluster <= 8'd0;
                final_chain_check <= 1'b0;
            end else case (state)
                ST_IDLE: if (file_start) begin
                    fs_error <= ERR_NONE;
                    file_byte_offset <= 32'd0;
                    remaining_bytes <= file_size;
                    sector_in_cluster <= 8'd0;
                    chain_count <= 1;
                    final_chain_check <= 1'b0;
                    sectors_per_cluster_shift <= spc_shift(sectors_per_cluster);
                    if (file_size == 0) begin
                        finish_with_error(ERR_EARLY_EOF);
                    end else if (first_cluster < 2 || first_cluster > max_cluster ||
                                 sectors_per_cluster == 0) begin
                        finish_with_error(ERR_CLUSTER_RANGE);
                    end else begin
                        current_cluster <= first_cluster;
                        state <= ST_DATA_ADDR;
                    end
                end

                ST_DATA_ADDR: begin
                    // Keep cluster subtraction/shift separate from the LBA adder.
                    cluster_sector_offset <= (current_cluster - 32'd2)
                                             << sectors_per_cluster_shift;
                    state <= ST_DATA_BASE;
                end

                ST_DATA_BASE: begin
                    sector_lba <= data_start_lba + cluster_sector_offset;
                    state <= ST_DATA_REQ;
                end

                ST_DATA_NEXT: begin
                    sector_lba <= sector_lba + 1'b1;
                    state <= ST_DATA_REQ;
                end

                ST_FAT_ADDR: begin
                    sector_lba <= fat_start_lba + (current_cluster >> 7);
                    state <= ST_FAT_REQ;
                end

                ST_DATA_REQ: if (file_continue && !sector_busy) begin
                    state <= ST_DATA_WAIT;
                end

                ST_DATA_WAIT: if (sector_done) begin
                    if (sector_error != 0) begin
                        finish_with_error(ERR_SECTOR);
                    end else if (remaining_bytes == 0 ||
                                 (remaining_bytes == 1 && sector_valid)) begin
                        final_chain_check <= 1'b1;
                        sector_in_cluster <= 8'd0;
                        fat_entry_offset <= {current_cluster[6:0], 2'b00};
                        state <= ST_FAT_ADDR;
                    end else if (sector_in_cluster + 1'b1 < sectors_per_cluster) begin
                        sector_in_cluster <= sector_in_cluster + 1'b1;
                        state <= ST_DATA_NEXT;
                    end else begin
                        sector_in_cluster <= 8'd0;
                        fat_entry_offset <= {current_cluster[6:0], 2'b00};
                        state <= ST_FAT_ADDR;
                    end
                end

                ST_FAT_REQ: if (!sector_busy) begin
                    state <= ST_FAT_WAIT;
                end

                ST_FAT_WAIT: if (sector_done) begin
                    if (sector_error != 0)
                        finish_with_error(ERR_SECTOR);
                    else
                        state <= ST_FAT_PARSE;
                end

                ST_FAT_PARSE: begin
                    candidate_cluster <= parsed_fat_entry;
                    state <= ST_FAT_VALIDATE;
                end

                ST_FAT_VALIDATE: begin
                    if (final_chain_check) begin
                        final_chain_check <= 1'b0;
                        if (candidate_cluster >= 28'hffffff8)
                            state <= ST_FINISH;
                        else
                            finish_with_error(ERR_FAT_LOOP);
                    end else if (candidate_cluster >= 28'hffffff8) begin
                        finish_with_error(ERR_EARLY_EOF);
                    end else if ({4'd0, candidate_cluster} < 2 ||
                                 {4'd0, candidate_cluster} > max_cluster) begin
                        finish_with_error(ERR_CLUSTER_RANGE);
                    end else if (chain_count >= MAX_VISITED_CLUSTERS) begin
                        finish_with_error(ERR_VISITED_EXHAUSTED);
                    end else if ({4'd0, candidate_cluster} == current_cluster) begin
                        finish_with_error(ERR_FAT_LOOP);
                    end else begin
                        chain_count <= chain_count + 1'b1;
                        current_cluster <= {4'd0, candidate_cluster};
                        state <= ST_DATA_ADDR;
                    end
                end

                ST_FINISH: begin
                    file_done <= 1'b1;
                    state <= ST_IDLE;
                end

                default: state <= ST_IDLE;
            endcase
        end
    end
endmodule
