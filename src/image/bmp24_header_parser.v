`timescale 1ns/1ps

// Streaming parser for the BITMAPFILEHEADER and BITMAPINFOHEADER fields used
// by uncompressed 24-bit BMP files. Metadata is committed after byte 33, well
// before the earliest supported pixel offset (54), so downstream loaders can
// decide how to route or scale the pixel stream without losing its first byte.
module bmp24_header_parser #(
    parameter integer MAX_WIDTH = 1920,
    parameter integer MAX_HEIGHT = 1080,
    parameter integer USE_RESOLUTION_WHITELIST = 1
) (
    input  wire        clk,
    input  wire        rst,
    input  wire        start,
    input  wire [31:0] file_size,
    input  wire        byte_valid,
    input  wire [31:0] byte_offset,
    input  wire [7:0]  byte_data,

    output reg         header_done,
    output reg         metadata_valid,
    output reg  [3:0]  error_code,
    output reg  [15:0] image_width,
    output reg  [15:0] image_height,
    output reg         top_down,
    output reg  [31:0] row_stride,
    output reg  [31:0] pixel_offset,
    output reg  [7:0]  pixel_format,
    output reg  [15:0] bits_per_pixel,
    output reg  [31:0] compression
);
    localparam [3:0] ERR_NONE       = 4'd0;
    localparam [3:0] ERR_SIGNATURE  = 4'd1;
    localparam [3:0] ERR_DIB        = 4'd2;
    localparam [3:0] ERR_DIMENSIONS = 4'd3;
    localparam [3:0] ERR_FORMAT     = 4'd4;
    localparam [3:0] ERR_OFFSET     = 4'd5;
    localparam [3:0] ERR_LENGTH     = 4'd6;
    localparam [3:0] ERR_RESOLUTION = 4'd7;

    localparam [7:0] PIXEL_FORMAT_INVALID = 8'd0;
    localparam [7:0] PIXEL_FORMAT_BGR888  = 8'd1;

    reg [7:0] signature0;
    reg [7:0] signature1;
    reg [31:0] header_file_size;
    reg [31:0] dib_size;
    reg [31:0] width_raw;
    reg [31:0] height_raw;
    reg [15:0] planes;
    reg [15:0] bit_count_raw;
    reg [31:0] compression_raw;
    reg [1:0] validation_stage;
    reg [3:0] basic_error_code;
    reg [33:0] pixel_bytes_q;
    reg [34:0] required_end_q;

    wire [31:0] compression_candidate = {byte_data, compression_raw[23:0]};
    wire [31:0] height_magnitude =
        height_raw[31] ? (~height_raw + 1'b1) : height_raw;
    wire [17:0] row_bytes_calc =
        ({2'd0, width_raw[15:0]} << 1) + {2'd0, width_raw[15:0]};
    wire [17:0] row_stride_calc = (row_bytes_calc + 3) & 18'h3fffc;
    // Multiply registered dimensions, away from the stride and sign logic.
    wire [33:0] pixel_bytes_calc =
        row_stride[17:0] * image_height;
    wire [32:0] minimum_offset_calc = 33'd14 + {1'b0, dib_size};

    function resolution_supported;
        input [31:0] width;
        input [31:0] height;
        begin
            resolution_supported =
                (width == 32'd640  && height == 32'd360) ||
                (width == 32'd640  && height == 32'd480) ||
                (width == 32'd960  && height == 32'd540) ||
                (width == 32'd1280 && height == 32'd720) ||
                (width == 32'd1920 && height == 32'd1080);
        end
    endfunction

    always @(posedge clk or posedge rst) begin
        if (rst) begin
            header_done <= 1'b0;
            metadata_valid <= 1'b0;
            error_code <= ERR_NONE;
            image_width <= 16'd0;
            image_height <= 16'd0;
            top_down <= 1'b0;
            row_stride <= 32'd0;
            pixel_offset <= 32'd54;
            pixel_format <= PIXEL_FORMAT_INVALID;
            bits_per_pixel <= 16'd0;
            compression <= 32'd0;
            signature0 <= 8'd0;
            signature1 <= 8'd0;
            header_file_size <= 32'd0;
            dib_size <= 32'd0;
            width_raw <= 32'd0;
            height_raw <= 32'd0;
            planes <= 16'd0;
            bit_count_raw <= 16'd0;
            compression_raw <= 32'd0;
            validation_stage <= 2'd0;
            basic_error_code <= ERR_NONE;
            pixel_bytes_q <= 34'd0;
            required_end_q <= 35'd0;
        end else begin
            header_done <= 1'b0;

            if (validation_stage == 2'd1) begin
                pixel_bytes_q <= pixel_bytes_calc;
                validation_stage <= 2'd2;
            end else if (validation_stage == 2'd2) begin
                required_end_q <=
                    {3'd0, pixel_offset} + {1'b0, pixel_bytes_q};
                validation_stage <= 2'd3;
            end else if (validation_stage == 2'd3) begin
                header_done <= 1'b1;
                validation_stage <= 2'd0;
                if (basic_error_code != ERR_NONE) begin
                    metadata_valid <= 1'b0;
                    error_code <= basic_error_code;
                end else if (required_end_q[34:32] != 0 ||
                             required_end_q > {3'd0, header_file_size} ||
                             header_file_size > file_size ||
                             required_end_q > {3'd0, file_size}) begin
                    metadata_valid <= 1'b0;
                    error_code <= ERR_LENGTH;
                end else begin
                    metadata_valid <= 1'b1;
                    error_code <= ERR_NONE;
                end
            end

            if (start) begin
                header_done <= 1'b0;
                metadata_valid <= 1'b0;
                error_code <= ERR_NONE;
                image_width <= 16'd0;
                image_height <= 16'd0;
                top_down <= 1'b0;
                row_stride <= 32'd0;
                pixel_offset <= 32'd54;
                pixel_format <= PIXEL_FORMAT_INVALID;
                bits_per_pixel <= 16'd0;
                compression <= 32'd0;
                signature0 <= 8'd0;
                signature1 <= 8'd0;
                header_file_size <= 32'd0;
                dib_size <= 32'd0;
                width_raw <= 32'd0;
                height_raw <= 32'd0;
                planes <= 16'd0;
                bit_count_raw <= 16'd0;
                compression_raw <= 32'd0;
                validation_stage <= 2'd0;
                basic_error_code <= ERR_NONE;
                pixel_bytes_q <= 34'd0;
                required_end_q <= 35'd0;
            end else if (byte_valid) begin
                case (byte_offset)
                    32'd0:  signature0 <= byte_data;
                    32'd1:  signature1 <= byte_data;
                    32'd2:  header_file_size[7:0] <= byte_data;
                    32'd3:  header_file_size[15:8] <= byte_data;
                    32'd4:  header_file_size[23:16] <= byte_data;
                    32'd5:  header_file_size[31:24] <= byte_data;
                    32'd10: pixel_offset[7:0] <= byte_data;
                    32'd11: pixel_offset[15:8] <= byte_data;
                    32'd12: pixel_offset[23:16] <= byte_data;
                    32'd13: pixel_offset[31:24] <= byte_data;
                    32'd14: dib_size[7:0] <= byte_data;
                    32'd15: dib_size[15:8] <= byte_data;
                    32'd16: dib_size[23:16] <= byte_data;
                    32'd17: dib_size[31:24] <= byte_data;
                    32'd18: width_raw[7:0] <= byte_data;
                    32'd19: width_raw[15:8] <= byte_data;
                    32'd20: width_raw[23:16] <= byte_data;
                    32'd21: width_raw[31:24] <= byte_data;
                    32'd22: height_raw[7:0] <= byte_data;
                    32'd23: height_raw[15:8] <= byte_data;
                    32'd24: height_raw[23:16] <= byte_data;
                    32'd25: height_raw[31:24] <= byte_data;
                    32'd26: planes[7:0] <= byte_data;
                    32'd27: planes[15:8] <= byte_data;
                    32'd28: bit_count_raw[7:0] <= byte_data;
                    32'd29: bit_count_raw[15:8] <= byte_data;
                    32'd30: compression_raw[7:0] <= byte_data;
                    32'd31: compression_raw[15:8] <= byte_data;
                    32'd32: compression_raw[23:16] <= byte_data;
                    32'd33: begin
                        compression_raw[31:24] <= byte_data;
                        validation_stage <= 2'd1;
                        image_width <= width_raw[15:0];
                        image_height <= height_magnitude[15:0];
                        top_down <= height_raw[31];
                        row_stride <= {14'd0, row_stride_calc};
                        bits_per_pixel <= bit_count_raw;
                        compression <= compression_candidate;
                        pixel_format <= (planes == 16'd1 &&
                                         bit_count_raw == 16'd24 &&
                                         compression_candidate == 32'd0) ?
                                        PIXEL_FORMAT_BGR888 :
                                        PIXEL_FORMAT_INVALID;

                        if (signature0 != "B" || signature1 != "M") begin
                            basic_error_code <= ERR_SIGNATURE;
                        end else if (dib_size < 32'd40) begin
                            basic_error_code <= ERR_DIB;
                        end else if (width_raw[31] || width_raw == 0 ||
                                     height_magnitude == 0 ||
                                     width_raw > MAX_WIDTH ||
                                     height_magnitude > MAX_HEIGHT) begin
                            basic_error_code <= ERR_DIMENSIONS;
                        end else if (planes != 16'd1 ||
                                     bit_count_raw != 16'd24 ||
                                     compression_candidate != 32'd0) begin
                            basic_error_code <= ERR_FORMAT;
                        end else if (pixel_offset < 32'd54 ||
                                     minimum_offset_calc > {1'b0, pixel_offset}) begin
                            basic_error_code <= ERR_OFFSET;
                        end else if (USE_RESOLUTION_WHITELIST != 0 &&
                                     !resolution_supported(width_raw,
                                                           height_magnitude)) begin
                            basic_error_code <= ERR_RESOLUTION;
                        end else begin
                            basic_error_code <= ERR_NONE;
                        end
                    end
                    default: begin end
                endcase
            end
        end
    end
endmodule
