`timescale 1ns/1ps

// Absorbs all pixels that can be produced by an already requested 512-byte
// FAT sector. The downstream scaler may stop between source rows.
module bmp_pixel_reservoir #(
    parameter integer DEPTH = 256,
    parameter integer ADDR_WIDTH = 8,
    parameter integer MAX_SECTOR_PIXELS = 171
) (
    input  wire                  clk,
    input  wire                  rst,
    input  wire                  clear,

    input  wire                  in_valid,
    output wire                  in_ready,
    input  wire [23:0]           in_pixel,

    output wire                  out_valid,
    input  wire                  out_ready,
    output wire [23:0]           out_pixel,

    output wire                  allow_next_sector,
    output wire [ADDR_WIDTH:0]   level,
    output reg                   overflow
);
    reg [ADDR_WIDTH:0] ram_level;
    reg [23:0] output_data;
    reg output_valid;
    reg [1:0] ready_pipe;

    wire [23:0] ram_data;
    wire ram_valid;
    wire ram_full;
    wire initialized = ready_pipe[1];

    wire push = in_valid && in_ready;
    wire pop = output_valid && out_ready;
    wire bypass = push && ram_level == 0 && (!output_valid || pop);
    wire ram_write = push && !bypass;
    wire ram_read = ram_valid && (!output_valid || pop);
    wire [ADDR_WIDTH:0] total_level =
        ram_level + {{ADDR_WIDTH{1'b0}}, output_valid};

    assign level = total_level;
    assign in_ready = initialized && total_level < DEPTH && !ram_full;
    assign out_valid = output_valid;
    assign out_pixel = output_data;
    // Compare stored entries directly so the sector handshake does not wait
    // for the occupancy adder. output_valid contributes exactly one entry.
    localparam integer SECTOR_LIMIT = DEPTH - MAX_SECTOR_PIXELS;
    assign allow_next_sector = initialized &&
        (ram_level < SECTOR_LIMIT || (ram_level == SECTOR_LIMIT && !output_valid));

    // The generated project FIFO is the proven TD block-RAM template. Its
    // 255 stored entries plus output_data provide an exact 256-pixel capacity.
    wfifo_32_32_512 #(
        .DATA_WIDTH_W(24),
        .DATA_WIDTH_R(24),
        .ADDR_WIDTH_W(ADDR_WIDTH),
        .ADDR_WIDTH_R(ADDR_WIDTH),
        .AL_FULL_NUM(DEPTH - 2),
        .AL_EMPTY_NUM(2),
        .SHOW_AHEAD_EN(1'b1),
        .OUTREG_EN("NOREG")
    ) u_storage (
        .rst(rst || clear),
        .clkw(clk), .clkr(clk),
        .we(ram_write), .di(in_pixel),
        .re(ram_read), .dout(ram_data), .valid(ram_valid),
        .full_flag(ram_full), .empty_flag(),
        .afull(), .aempty(), .wrusedw(), .rdusedw()
    );

    always @(posedge clk or posedge rst) begin
        if (rst) begin
            ram_level <= {(ADDR_WIDTH+1){1'b0}};
            output_data <= 24'd0;
            output_valid <= 1'b0;
            ready_pipe <= 2'b00;
            overflow <= 1'b0;
        end else if (clear) begin
            ram_level <= {(ADDR_WIDTH+1){1'b0}};
            output_data <= 24'd0;
            output_valid <= 1'b0;
            ready_pipe <= 2'b00;
            overflow <= 1'b0;
        end else begin
            ready_pipe <= {ready_pipe[0], 1'b1};

            if (initialized && in_valid && !in_ready)
                overflow <= 1'b1;

            case ({ram_write, ram_read})
                2'b10: ram_level <= ram_level + 1'b1;
                2'b01: ram_level <= ram_level - 1'b1;
                default: begin end
            endcase

            if (ram_read) begin
                output_data <= ram_data;
                output_valid <= 1'b1;
            end else if (bypass) begin
                output_data <= in_pixel;
                output_valid <= 1'b1;
            end else if (pop) begin
                output_valid <= 1'b0;
            end
        end
    end
endmodule
