`timescale 1ns/1ps

module sd_sector_adapter #(
    parameter integer CLK_FREQ_HZ = 100_000_000,
    parameter integer READ_TIMEOUT_MS = 500
) (
    input  wire        clk,
    input  wire        rst,
    input  wire        sector_req,
    input  wire [31:0] sector_lba,
    output wire        sector_busy,
    output reg         sector_valid,
    output reg  [7:0]  sector_byte,
    output reg  [8:0]  sector_byte_index,
    output reg         sector_done,
    output reg  [7:0]  sector_error,
    output reg         sd_sec_read,
    output reg  [31:0] sd_sec_read_addr,
    input  wire        sd_sec_read_data_valid,
    input  wire [7:0]  sd_sec_read_data,
    input  wire        sd_sec_read_end
);
    localparam ST_IDLE = 1'b0;
    localparam ST_READ = 1'b1;
    localparam [7:0] ERR_NONE = 8'h00;
    localparam [7:0] ERR_TIMEOUT = 8'h01;
    localparam integer TIMEOUT_CYCLES =
        (CLK_FREQ_HZ / 1000) * READ_TIMEOUT_MS;

    reg state;
    reg [31:0] timeout_count;
    reg [8:0] receive_byte_index;

    assign sector_busy = (state != ST_IDLE);

    always @(posedge clk or posedge rst) begin
        if (rst) begin
            state             <= ST_IDLE;
            timeout_count     <= 32'd0;
            sector_valid      <= 1'b0;
            sector_byte       <= 8'd0;
            sector_byte_index <= 9'd0;
            receive_byte_index <= 9'd0;
            sector_done       <= 1'b0;
            sector_error      <= ERR_NONE;
            sd_sec_read       <= 1'b0;
            sd_sec_read_addr  <= 32'd0;
        end else begin
            sector_valid <= 1'b0;
            sector_done  <= 1'b0;

            case (state)
                ST_IDLE: begin
                    sd_sec_read   <= 1'b0;
                    timeout_count <= 32'd0;
                    if (sector_req) begin
                        sd_sec_read_addr  <= sector_lba;
                        sd_sec_read       <= 1'b1;
                        receive_byte_index <= 9'd0;
                        sector_error      <= ERR_NONE;
                        state             <= ST_READ;
                    end
                end

                ST_READ: begin
                    sd_sec_read <= 1'b1;
                    if (sd_sec_read_data_valid) begin
                        sector_valid <= 1'b1;
                        sector_byte  <= sd_sec_read_data;
                        sector_byte_index <= receive_byte_index;
                        if (receive_byte_index != 9'd511)
                            receive_byte_index <= receive_byte_index + 1'b1;
                        timeout_count <= 32'd0;
                    end else if (sd_sec_read_end) begin
                        sd_sec_read   <= 1'b0;
                        sector_done   <= 1'b1;
                        timeout_count <= 32'd0;
                        state         <= ST_IDLE;
                    end else if (timeout_count >= TIMEOUT_CYCLES - 1) begin
                        sd_sec_read  <= 1'b0;
                        sector_error <= ERR_TIMEOUT;
                        sector_done  <= 1'b1;
                        state        <= ST_IDLE;
                    end else begin
                        timeout_count <= timeout_count + 1'b1;
                    end
                end
            endcase
        end
    end
endmodule
