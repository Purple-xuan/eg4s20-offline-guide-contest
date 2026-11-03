`timescale 1ns/1ps

module fat32_bmp_reader #(
    parameter integer CLK_FREQ_HZ = 100_000_000,
    parameter integer WRITE_TIMEOUT_MS = 500,
    parameter integer ENABLE_PIXEL_BACKPRESSURE = 0,
    parameter integer ENABLE_DYNAMIC_HEADER = 0,
    parameter integer USE_RESOLUTION_WHITELIST = 1
) (
    input  wire        clk,
    input  wire        rst,
    input  wire        sd_init_done,
    input  wire        scan_start,
    output reg         scan_done,
    output reg         scan_error,
    output wire [7:0]  scan_error_code,
    output wire [7:0]  resource_valid,
    output wire [31:0] resource0_cluster,
    output wire [31:0] resource1_cluster,
    output wire [31:0] resource2_cluster,
    output wire [31:0] resource3_cluster,
    output wire [31:0] resource4_cluster,
    output wire [31:0] resource5_cluster,
    output wire [31:0] resource6_cluster,
    output wire [31:0] resource7_cluster,
    output wire [31:0] resource0_size,
    output wire [31:0] resource1_size,
    output wire [31:0] resource2_size,
    output wire [31:0] resource3_size,
    output wire [31:0] resource4_size,
    output wire [31:0] resource5_size,
    output wire [31:0] resource6_size,
    output wire [31:0] resource7_size,
    output wire [7:0]  audio_valid,
    input  wire [3:0] audio_query_index,
    output wire [31:0] audio_query_cluster,
    output wire [31:0] audio_query_size,
    output wire [7:0] hotspot_audio_valid,
    output wire        emergency_bmp_valid,
    output wire [31:0] emergency_bmp_cluster,
    output wire [31:0] emergency_bmp_size,
    output wire        emergency_wav_valid,
    output wire [31:0] emergency_wav_cluster,
    output wire [31:0] emergency_wav_size,
    output wire        bgm_valid,
    output wire [31:0] bgm_cluster,
    output wire [31:0] bgm_size,
    output wire [7:0]  fs_sectors_per_cluster,
    output wire [31:0] fs_fat_start_lba,
    output wire [31:0] fs_data_start_lba,
    output wire [31:0] fs_max_cluster,
    output wire [23:0] scan_boot_debug,
    input  wire        load_start,
    input  wire [31:0] load_cluster,
    input  wire [31:0] load_file_size,
    input  wire [15:0] bmp_width,
    input  wire [15:0] bmp_height,
    output wire        ready,
    output reg         write_req,
    input  wire        write_req_ack,
    output reg         bmp_data_wr_en,
    output reg  [23:0] bmp_data,
    output reg         load_done,
    output reg         load_error,
    output reg  [2:0]  bmp_error,
    input  wire        pixel_continue,
    output wire        bmp_metadata_done,
    output wire        bmp_metadata_valid,
    output wire [3:0]  bmp_metadata_error,
    output wire [15:0] bmp_source_width,
    output wire [15:0] bmp_source_height,
    output wire        bmp_top_down,
    output wire        sector_req,
    output wire [31:0] sector_lba,
    input  wire        sector_busy,
    input  wire        sector_valid,
    input  wire [7:0]  sector_byte,
    input  wire [8:0]  sector_byte_index,
    input  wire        sector_done,
    input  wire [7:0]  sector_error
);
    localparam ERR_NONE       = 3'd0;
    localparam ERR_HEADER     = 3'd1;
    localparam ERR_TIMEOUT    = 3'd2;
    localparam ERR_TRUNCATED  = 3'd3;
    localparam ERR_FILESYSTEM = 3'd4;

    localparam ST_IDLE       = 2'd0;
    localparam ST_WRITE_WAIT = 2'd1;
    localparam ST_STREAM     = 2'd2;
    localparam integer WRITE_TIMEOUT_CYCLES =
        (CLK_FREQ_HZ / 1000) * WRITE_TIMEOUT_MS;

    reg [1:0] state;
    reg [31:0] write_timeout_count;
    reg streamer_start;
    reg [31:0] selected_cluster;
    reg [31:0] selected_file_size;

    wire scanner_busy;
    wire scanner_done_pulse;
    wire [7:0] scanner_error;
    wire scanner_sector_req;
    wire [31:0] scanner_sector_lba;

    wire streamer_busy;
    wire streamer_done;
    wire streamer_valid;
    wire [7:0] streamer_byte;
    wire [31:0] streamer_offset;
    wire [7:0] streamer_error;
    wire streamer_sector_req;
    wire [31:0] streamer_sector_lba;
    wire stream_owner = (state == ST_STREAM);
    wire streamer_continue = ENABLE_PIXEL_BACKPRESSURE ?
                             pixel_continue : 1'b1;

    reg [7:0] signature0, signature1;
    reg [31:0] header_file_size;
    reg [31:0] pixel_offset;
    reg [31:0] dib_size;
    reg [31:0] image_width;
    reg [31:0] image_height;
    reg [15:0] planes;
    reg [15:0] bit_count;
    reg [31:0] compression;
    reg header_valid;
    reg header_failed;
    reg [15:0] completed_rows;
    reg [31:0] row_byte_count;
    reg [1:0] rgb_byte_index;
    reg [15:0] rgb_low;

    wire parser_header_done;
    wire parser_metadata_valid;
    wire [3:0] parser_error_code;
    wire [15:0] parser_width;
    wire [15:0] parser_height;
    wire parser_top_down;
    wire [31:0] parser_row_stride;
    wire [31:0] parser_pixel_offset;
    wire [7:0] parser_pixel_format;
    wire [15:0] parser_bits_per_pixel;
    wire [31:0] parser_compression;

    wire [15:0] decode_width = ENABLE_DYNAMIC_HEADER ?
                              parser_width : bmp_width;
    wire [15:0] decode_height = ENABLE_DYNAMIC_HEADER ?
                               parser_height : bmp_height;
    wire [31:0] decode_pixel_offset = ENABLE_DYNAMIC_HEADER ?
                                      parser_pixel_offset : pixel_offset;
    reg [31:0] expected_row_bytes;
    always @(posedge clk)
        if (parser_header_done)
            expected_row_bytes <=
                ({16'd0, decode_width} << 1) + {16'd0, decode_width};
    wire [31:0] legacy_row_stride =
        (expected_row_bytes + 3) & 32'hfffffffc;
    wire [31:0] expected_row_stride = ENABLE_DYNAMIC_HEADER ?
                                      parser_row_stride : legacy_row_stride;

    assign bmp_metadata_done = parser_header_done;
    assign bmp_metadata_valid = parser_metadata_valid;
    assign bmp_metadata_error = parser_error_code;
    assign bmp_source_width = parser_width;
    assign bmp_source_height = parser_height;
    assign bmp_top_down = parser_top_down;

    assign ready = (state == ST_IDLE) && !scanner_busy && !streamer_busy;
    assign scan_error_code = scanner_error;
    assign sector_req = stream_owner ? streamer_sector_req : scanner_sector_req;
    assign sector_lba = stream_owner ? streamer_sector_lba : scanner_sector_lba;

    fat32_volume_scanner u_volume_scanner (
        .clk(clk), .rst_n(~rst), .scan_start(scan_start),
        .scan_busy(scanner_busy), .scan_done(scanner_done_pulse),
        .fs_error(scanner_error), .partition_lba(),
        .sectors_per_cluster(fs_sectors_per_cluster),
        .fat_start_lba(fs_fat_start_lba),
        .data_start_lba(fs_data_start_lba),
        .max_cluster(fs_max_cluster), .resource_valid(resource_valid),
        .resource0_cluster(resource0_cluster),
        .resource1_cluster(resource1_cluster),
        .resource2_cluster(resource2_cluster),
        .resource3_cluster(resource3_cluster),
        .resource4_cluster(resource4_cluster),
        .resource5_cluster(resource5_cluster),
        .resource6_cluster(resource6_cluster),
        .resource7_cluster(resource7_cluster),
        .resource0_size(resource0_size), .resource1_size(resource1_size),
        .resource2_size(resource2_size), .resource3_size(resource3_size),
        .resource4_size(resource4_size), .resource5_size(resource5_size),
        .resource6_size(resource6_size), .resource7_size(resource7_size),
        .audio_valid(audio_valid),
        .audio_query_index(audio_query_index),
        .audio_query_cluster(audio_query_cluster),
        .audio_query_size(audio_query_size),
        .hotspot_audio_valid(hotspot_audio_valid),
        .emergency_bmp_valid(emergency_bmp_valid),
        .emergency_bmp_cluster(emergency_bmp_cluster),
        .emergency_bmp_size(emergency_bmp_size),
        .emergency_wav_valid(emergency_wav_valid),
        .emergency_wav_cluster(emergency_wav_cluster),
        .emergency_wav_size(emergency_wav_size),
        .bgm_valid(bgm_valid), .bgm_cluster(bgm_cluster), .bgm_size(bgm_size),
        .boot_debug(scan_boot_debug),
        .sector_req(scanner_sector_req), .sector_lba(scanner_sector_lba),
        .sector_busy(stream_owner ? 1'b0 : sector_busy),
        .sector_valid(stream_owner ? 1'b0 : sector_valid),
        .sector_byte(sector_byte), .sector_byte_index(sector_byte_index),
        .sector_done(stream_owner ? 1'b0 : sector_done),
        .sector_error(stream_owner ? 8'd0 : sector_error)
    );

    fat32_file_streamer u_file_streamer (
        .clk(clk), .rst_n(~rst), .file_start(streamer_start),
        .file_abort(1'b0),
        .first_cluster(selected_cluster), .file_size(selected_file_size),
        .file_continue(streamer_continue),
        .sectors_per_cluster(fs_sectors_per_cluster),
        .fat_start_lba(fs_fat_start_lba),
        .data_start_lba(fs_data_start_lba),
        .max_cluster(fs_max_cluster), .file_busy(streamer_busy),
        .file_done(streamer_done), .file_valid(streamer_valid),
        .file_byte(streamer_byte), .file_byte_offset(streamer_offset),
        .fs_error(streamer_error), .sector_req(streamer_sector_req),
        .sector_lba(streamer_sector_lba),
        .sector_busy(stream_owner ? sector_busy : 1'b0),
        .sector_valid(stream_owner ? sector_valid : 1'b0),
        .sector_byte(sector_byte), .sector_byte_index(sector_byte_index),
        .sector_done(stream_owner ? sector_done : 1'b0),
        .sector_error(stream_owner ? sector_error : 8'd0)
    );

    bmp24_header_parser #(
        .MAX_WIDTH(1920),
        .MAX_HEIGHT(1080),
        .USE_RESOLUTION_WHITELIST(USE_RESOLUTION_WHITELIST)
    ) u_header_parser (
        .clk(clk), .rst(rst), .start(streamer_start),
        .file_size(selected_file_size),
        .byte_valid(streamer_valid), .byte_offset(streamer_offset),
        .byte_data(streamer_byte), .header_done(parser_header_done),
        .metadata_valid(parser_metadata_valid),
        .error_code(parser_error_code), .image_width(parser_width),
        .image_height(parser_height), .top_down(parser_top_down),
        .row_stride(parser_row_stride),
        .pixel_offset(parser_pixel_offset),
        .pixel_format(parser_pixel_format),
        .bits_per_pixel(parser_bits_per_pixel),
        .compression(parser_compression)
    );

    always @(posedge clk or posedge rst) begin
        if (rst) begin
            state <= ST_IDLE;
            scan_done <= 1'b0;
            scan_error <= 1'b0;
            write_req <= 1'b0;
            load_done <= 1'b0;
            load_error <= 1'b0;
            bmp_error <= ERR_NONE;
            bmp_data_wr_en <= 1'b0;
            bmp_data <= 24'd0;
            streamer_start <= 1'b0;
            selected_cluster <= 32'd0;
            selected_file_size <= 32'd0;
            write_timeout_count <= 32'd0;
            signature0 <= 8'd0;
            signature1 <= 8'd0;
            header_file_size <= 32'd0;
            pixel_offset <= 32'd54;
            dib_size <= 32'd0;
            image_width <= 32'd0;
            image_height <= 32'd0;
            planes <= 16'd0;
            bit_count <= 16'd0;
            compression <= 32'd0;
            header_valid <= 1'b0;
            header_failed <= 1'b0;
            completed_rows <= 16'd0;
            row_byte_count <= 32'd0;
            rgb_byte_index <= 2'd0;
            rgb_low <= 16'd0;
        end else begin
            scan_error <= 1'b0;
            load_done <= 1'b0;
            load_error <= 1'b0;
            bmp_data_wr_en <= 1'b0;
            streamer_start <= 1'b0;

            if (scan_start)
                scan_done <= 1'b0;
            if (scanner_done_pulse) begin
                scan_done <= 1'b1;
                if ((scanner_error != 0 && scanner_error != 8'h22) ||
                    resource_valid == 0)
                    scan_error <= 1'b1;
            end

            case (state)
                ST_IDLE: begin
                    write_req <= 1'b0;
                    write_timeout_count <= 32'd0;
                    if (load_start) begin
                        selected_cluster <= load_cluster;
                        selected_file_size <= load_file_size;
                        bmp_error <= ERR_NONE;
                        signature0 <= 8'd0;
                        signature1 <= 8'd0;
                        header_file_size <= 32'd0;
                        pixel_offset <= 32'd54;
                        dib_size <= 32'd0;
                        image_width <= 32'd0;
                        image_height <= 32'd0;
                        planes <= 16'd0;
                        bit_count <= 16'd0;
                        compression <= 32'd0;
                        header_valid <= 1'b0;
                        header_failed <= 1'b0;
                        completed_rows <= 16'd0;
                        row_byte_count <= 32'd0;
                        rgb_byte_index <= 2'd0;
                        rgb_low <= 16'd0;
                        write_req <= 1'b1;
                        state <= ST_WRITE_WAIT;
                    end
                end

                ST_WRITE_WAIT: begin
                    write_req <= 1'b1;
                    if (!sd_init_done) begin
                        write_req <= 1'b0;
                        bmp_error <= ERR_TIMEOUT;
                        load_error <= 1'b1;
                        state <= ST_IDLE;
                    end else if (write_req_ack) begin
                        write_req <= 1'b0;
                        write_timeout_count <= 32'd0;
                        streamer_start <= 1'b1;
                        state <= ST_STREAM;
                    end else if (write_timeout_count >= WRITE_TIMEOUT_CYCLES - 1) begin
                        write_req <= 1'b0;
                        bmp_error <= ERR_TIMEOUT;
                        load_error <= 1'b1;
                        state <= ST_IDLE;
                    end else begin
                        write_timeout_count <= write_timeout_count + 1'b1;
                    end
                end

                ST_STREAM: begin
                    if (ENABLE_DYNAMIC_HEADER && parser_header_done) begin
                        header_valid <= parser_metadata_valid;
                        header_failed <= !parser_metadata_valid;
                    end

                    if (streamer_valid) begin
                        case (streamer_offset)
                            32'd0:  signature0 <= streamer_byte;
                            32'd1:  signature1 <= streamer_byte;
                            32'd2:  header_file_size[7:0] <= streamer_byte;
                            32'd3:  header_file_size[15:8] <= streamer_byte;
                            32'd4:  header_file_size[23:16] <= streamer_byte;
                            32'd5:  header_file_size[31:24] <= streamer_byte;
                            32'd10: pixel_offset[7:0] <= streamer_byte;
                            32'd11: pixel_offset[15:8] <= streamer_byte;
                            32'd12: pixel_offset[23:16] <= streamer_byte;
                            32'd13: pixel_offset[31:24] <= streamer_byte;
                            32'd14: dib_size[7:0] <= streamer_byte;
                            32'd15: dib_size[15:8] <= streamer_byte;
                            32'd16: dib_size[23:16] <= streamer_byte;
                            32'd17: dib_size[31:24] <= streamer_byte;
                            32'd18: image_width[7:0] <= streamer_byte;
                            32'd19: image_width[15:8] <= streamer_byte;
                            32'd20: image_width[23:16] <= streamer_byte;
                            32'd21: image_width[31:24] <= streamer_byte;
                            32'd22: image_height[7:0] <= streamer_byte;
                            32'd23: image_height[15:8] <= streamer_byte;
                            32'd24: image_height[23:16] <= streamer_byte;
                            32'd25: image_height[31:24] <= streamer_byte;
                            32'd26: planes[7:0] <= streamer_byte;
                            32'd27: planes[15:8] <= streamer_byte;
                            32'd28: bit_count[7:0] <= streamer_byte;
                            32'd29: bit_count[15:8] <= streamer_byte;
                            32'd30: compression[7:0] <= streamer_byte;
                            32'd31: compression[15:8] <= streamer_byte;
                            32'd32: compression[23:16] <= streamer_byte;
                            32'd33: compression[31:24] <= streamer_byte;
                            default: begin end
                        endcase

                        if (!ENABLE_DYNAMIC_HEADER && streamer_offset == 32'd53) begin
                            if (signature0 == "B" && signature1 == "M" &&
                                dib_size >= 32'd40 &&
                                image_width == {16'd0, bmp_width} &&
                                image_height == {16'd0, bmp_height} &&
                                planes == 16'd1 && bit_count == 16'd24 &&
                                compression == 32'd0 && pixel_offset >= 32'd54 &&
                                header_file_size <= selected_file_size &&
                                header_file_size >= pixel_offset &&
                                selected_file_size >= pixel_offset)
                                header_valid <= 1'b1;
                            else
                                header_failed <= 1'b1;
                        end

                        if (header_valid &&
                            streamer_offset >= decode_pixel_offset &&
                            completed_rows < decode_height) begin
                            if (row_byte_count < expected_row_bytes) begin
                                case (rgb_byte_index)
                                    2'd0: begin
                                        rgb_low[7:0] <= streamer_byte;
                                        rgb_byte_index <= 2'd1;
                                    end
                                    2'd1: begin
                                        rgb_low[15:8] <= streamer_byte;
                                        rgb_byte_index <= 2'd2;
                                    end
                                    default: begin
                                        bmp_data <= {streamer_byte, rgb_low};
                                        bmp_data_wr_en <= 1'b1;
                                        rgb_byte_index <= 2'd0;
                                    end
                                endcase
                            end

                            if (row_byte_count + 1'b1 >= expected_row_stride) begin
                                row_byte_count <= 32'd0;
                                completed_rows <= completed_rows + 1'b1;
                            end else begin
                                row_byte_count <= row_byte_count + 1'b1;
                            end
                        end
                    end

                    if (streamer_done) begin
                        if (streamer_error != 0) begin
                            bmp_error <= (streamer_error == 8'h10) ?
                                         ERR_TIMEOUT : ERR_FILESYSTEM;
                            load_error <= 1'b1;
                        end else if (header_failed || !header_valid) begin
                            bmp_error <= ERR_HEADER;
                            load_error <= 1'b1;
                        end else if (completed_rows != decode_height ||
                                     row_byte_count != 0 || rgb_byte_index != 0) begin
                            bmp_error <= ERR_TRUNCATED;
                            load_error <= 1'b1;
                        end else begin
                            bmp_error <= ERR_NONE;
                            load_done <= 1'b1;
                        end
                        state <= ST_IDLE;
                    end
                end

                default: state <= ST_IDLE;
            endcase
        end
    end
endmodule
