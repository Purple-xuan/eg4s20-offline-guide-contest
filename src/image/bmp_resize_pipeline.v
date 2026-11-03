`timescale 1ns/1ps

// Joins the sector-safe input reservoir to the loader-side scaler. Supported
// production resolutions are 16:9, so the initial viewport fills the target.
module bmp_resize_pipeline #(
    parameter integer TARGET_WIDTH = 1280,
    parameter integer TARGET_HEIGHT = 720,
    parameter integer MAX_SOURCE_WIDTH = 1920,
    parameter integer MAX_SOURCE_HEIGHT = 1080,
    parameter integer ENABLE_ROI = 0,
    parameter integer RESTART_ON_START = 0
) (
    input  wire        clk,
    input  wire        rst,
    input  wire        start,
    input  wire [15:0] source_width,
    input  wire [15:0] source_height,
    input  wire        source_top_down,
    input  wire        crop_enable,
    input  wire [15:0] crop_x, crop_y, crop_width, crop_height,

    input  wire        raw_valid,
    input  wire [23:0] raw_pixel,
    output wire        raw_ready,
    output wire        allow_next_sector,

    output wire        pixel_valid,
    input  wire        pixel_ready,
    output wire [23:0] pixel_rgb,
    output wire        pixel_sof,
    output wire        pixel_eol,
    output wire        pixel_eof,

    output reg         write_v_flip,
    output wire        busy,
    output wire        done,
    output wire        pipeline_error
);
    wire reservoir_valid;
    wire reservoir_ready;
    wire [23:0] reservoir_pixel;
    wire reservoir_overflow;
    wire [8:0] reservoir_level;
    wire [15:0] scaled_x;
    wire [15:0] scaled_y;
    wire scaler_config_error;
    localparam [15:0] TARGET_WIDTH_16 = TARGET_WIDTH;
    localparam [15:0] TARGET_HEIGHT_16 = TARGET_HEIGHT;

    always @(posedge clk or posedge rst) begin
        if (rst)
            write_v_flip <= 1'b1;
        else if (start)
            write_v_flip <= !source_top_down;
    end

    bmp_pixel_reservoir u_reservoir (
        .clk(clk), .rst(rst), .clear(start),
        .in_valid(raw_valid), .in_ready(raw_ready), .in_pixel(raw_pixel),
        .out_valid(reservoir_valid), .out_ready(reservoir_ready),
        .out_pixel(reservoir_pixel),
        .allow_next_sector(allow_next_sector),
        .level(reservoir_level), .overflow(reservoir_overflow)
    );

    nearest_letterbox_scaler #(
        .TARGET_WIDTH(TARGET_WIDTH),
        .TARGET_HEIGHT(TARGET_HEIGHT),
        .MAX_SOURCE_WIDTH(MAX_SOURCE_WIDTH),
        .MAX_SOURCE_HEIGHT(MAX_SOURCE_HEIGHT), .ENABLE_ROI(ENABLE_ROI),
        .RESTART_ON_START(RESTART_ON_START)
    ) u_scaler (
        .clk(clk), .rst(rst), .start(start),
        .source_width(source_width), .source_height(source_height),
        .active_width(TARGET_WIDTH_16), .active_height(TARGET_HEIGHT_16),
        .x_offset(16'd0), .y_offset(16'd0),
        .crop_enable(crop_enable), .crop_x(crop_x), .crop_y(crop_y),
        .crop_width(crop_width), .crop_height(crop_height),
        .source_reverse_y(!source_top_down),
        .in_valid(reservoir_valid), .in_ready(reservoir_ready),
        .in_pixel(reservoir_pixel),
        .out_valid(pixel_valid), .out_ready(pixel_ready),
        .out_pixel(pixel_rgb), .out_x(scaled_x), .out_y(scaled_y),
        .out_sof(pixel_sof), .out_eol(pixel_eol), .out_eof(pixel_eof),
        .busy(busy), .done(done), .config_error(scaler_config_error)
    );

    assign pipeline_error = reservoir_overflow || scaler_config_error;
endmodule
