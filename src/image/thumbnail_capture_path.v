`timescale 1ns/1ps

// Complete thumbnail capture boundary. It is intentionally independent of
// the page controller until its SDRAM bandwidth impact is measured.
module thumbnail_capture_path #(
    parameter integer INPUT_WIDTH = 1280,
    parameter integer INPUT_HEIGHT = 720,
    parameter integer H_STEP = 4,
    parameter integer V_STEP = 4,
    parameter integer ADDR_BITS = 21
) (
    input  wire                   clk,
    input  wire                   rst,
    input  wire                   start,
    input  wire [ADDR_BITS-1:0]   base_addr,
    input  wire                   raw_valid,
    output wire                   raw_ready,
    input  wire [23:0]            raw_pixel,
    input  wire                   sdram_init_done,
    input  wire                   refresh_active,
    input  wire                   controller_busy,
    input  wire                   reader_urgent,
    input  wire                   frame_valid,
    input  wire [ADDR_BITS-1:0]   frame_addr,
    input  wire [31:0]            frame_data,
    input  wire [3:0]             frame_mask,
    output wire                   app_wr_en,
    output wire [ADDR_BITS-1:0]   app_wr_addr,
    output wire [31:0]            app_wr_data,
    output wire [3:0]             app_wr_mask,
    output wire                   busy,
    output wire                   done,
    output wire                   error
);
    wire thumb_valid;
    wire thumb_ready;
    wire [23:0] thumb_pixel;
    wire thumb_sof, thumb_eol, thumb_eof;
    wire writer_done;
    wire writer_error;
    wire thumb_grant;
    wire writer_valid;
    wire [ADDR_BITS-1:0] writer_addr;
    wire [31:0] writer_data;
    wire [3:0] writer_mask;

    thumbnail_downsampler #(
        .INPUT_WIDTH(INPUT_WIDTH), .INPUT_HEIGHT(INPUT_HEIGHT),
        .H_STEP(H_STEP), .V_STEP(V_STEP)
    ) u_downsampler (
        .clk(clk), .rst(rst || start),
        .in_valid(raw_valid), .in_ready(raw_ready), .in_pixel(raw_pixel),
        .out_valid(thumb_valid), .out_ready(thumb_ready),
        .out_pixel(thumb_pixel), .out_sof(thumb_sof),
        .out_eol(thumb_eol), .out_eof(thumb_eof)
    );

    thumbnail_frame_writer #(
        .WIDTH(INPUT_WIDTH / H_STEP), .HEIGHT(INPUT_HEIGHT / V_STEP),
        .ADDR_BITS(ADDR_BITS)
    ) u_output_writer (
        .clk(clk), .rst(rst), .start(start), .base_addr(base_addr),
        .in_valid(thumb_valid), .in_ready(thumb_ready), .in_pixel(thumb_pixel),
        .out_valid(writer_valid), .out_ready(thumb_grant),
        .out_addr(writer_addr), .out_data(writer_data),
        .frame_done(writer_done), .error(writer_error)
    );

    thumbnail_write_arbiter #(.ADDR_BITS(ADDR_BITS)) u_arbiter (
        .sdram_init_done(sdram_init_done), .refresh_active(refresh_active),
        .controller_busy(controller_busy), .reader_urgent(reader_urgent),
        .frame_valid(frame_valid), .frame_addr(frame_addr),
        .frame_data(frame_data), .frame_mask(frame_mask),
        .thumb_valid(writer_valid), .thumb_ready(thumb_grant),
        .thumb_addr(writer_addr), .thumb_data(writer_data),
        .app_wr_en(app_wr_en), .app_wr_addr(app_wr_addr),
        .app_wr_data(app_wr_data), .app_wr_mask(app_wr_mask),
        .thumb_grant()
    );

    assign busy = writer_valid || thumb_valid;
    assign done = writer_done;
    assign error = writer_error;
endmodule
