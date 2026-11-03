`timescale 1ns/1ps

module wav_file_stream_reader (
    input  wire        clk,
    input  wire        rst_n,
    input  wire        stream_start,
    input  wire        stream_stop,
    input  wire [31:0] first_cluster,
    input  wire [31:0] file_size,
    input  wire [7:0]  sectors_per_cluster,
    input  wire [31:0] fat_start_lba,
    input  wire [31:0] data_start_lba,
    input  wire [31:0] max_cluster,
    input  wire        pcm_continue,
    output wire        stream_busy,
    output reg         stream_done,
    output reg         stream_error,
    output reg  [7:0]  stream_error_code,
    output wire [1:0]  channel_count,
    output wire [31:0] sample_rate,
    output wire [15:0] block_align,
    output reg         pcm_valid,
    output reg  [7:0]  pcm_byte,
    output reg  [31:0] pcm_byte_offset,
    output reg         sector_req,
    output reg  [31:0] sector_lba,
    input  wire        sector_busy,
    input  wire        sector_valid,
    input  wire [7:0]  sector_byte,
    input  wire [8:0]  sector_byte_index,
    input  wire        sector_done,
    input  wire [7:0]  sector_error
);
    wire file_busy;
    wire file_done;
    wire file_valid;
    wire [7:0] file_byte;
    wire [31:0] file_byte_offset;
    wire [7:0] file_fs_error;
    wire file_sector_req;
    wire [31:0] file_sector_lba;

    wire parser_busy;
    wire parser_done;
    wire parser_error;
    wire [3:0] parser_error_code;
    wire [1:0] parser_channel_count;
    wire [31:0] parser_sample_rate;
    wire [31:0] parser_byte_rate;
    wire [15:0] parser_block_align;
    wire [15:0] parser_bits_per_sample;
    wire [31:0] parser_data_offset;
    wire [31:0] parser_data_size;

    wire format_ready = parser_data_size != 0 && !parser_error;
    wire [31:0] parser_data_end = parser_data_offset + parser_data_size;
    wire allow_next_sector = !format_ready || pcm_continue;
    reg [31:0] pcm_byte_count;

    assign stream_busy = file_busy || parser_busy;
    assign channel_count = parser_channel_count;
    assign sample_rate = parser_sample_rate;
    assign block_align = parser_block_align;

    // A full music track may span more clusters than the short narration WAVs.
    fat32_file_streamer #(.MAX_VISITED_CLUSTERS(131072)) u_file_streamer (
        .clk(clk), .rst_n(rst_n), .file_start(stream_start),
        .file_abort(stream_stop),
        .first_cluster(first_cluster), .file_size(file_size),
        .file_continue(allow_next_sector),
        .sectors_per_cluster(sectors_per_cluster),
        .fat_start_lba(fat_start_lba), .data_start_lba(data_start_lba),
        .max_cluster(max_cluster), .file_busy(file_busy),
        .file_done(file_done), .file_valid(file_valid),
        .file_byte(file_byte), .file_byte_offset(file_byte_offset),
        .fs_error(file_fs_error), .sector_req(file_sector_req),
        .sector_lba(file_sector_lba), .sector_busy(sector_busy),
        .sector_valid(sector_valid), .sector_byte(sector_byte),
        .sector_byte_index(sector_byte_index), .sector_done(sector_done),
        .sector_error(sector_error)
    );

    wav_riff_parser u_parser (
        .clk(clk), .rst_n(rst_n && !stream_stop), .parse_start(stream_start),
        .file_size(file_size), .file_valid(file_valid),
        .file_byte(file_byte), .file_byte_offset(file_byte_offset),
        .file_done(file_done), .file_error(file_fs_error),
        .parse_busy(parser_busy), .parse_done(parser_done),
        .parse_error(parser_error), .error_code(parser_error_code),
        .channel_count(parser_channel_count),
        .sample_rate(parser_sample_rate), .byte_rate(parser_byte_rate),
        .block_align(parser_block_align),
        .bits_per_sample(parser_bits_per_sample),
        .data_offset(parser_data_offset), .data_size(parser_data_size)
    );

    always @(*) begin
        sector_req = file_sector_req;
        sector_lba = file_sector_lba;
    end

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            stream_done <= 1'b0;
            stream_error <= 1'b0;
            stream_error_code <= 8'd0;
            pcm_valid <= 1'b0;
            pcm_byte <= 8'd0;
            pcm_byte_offset <= 32'd0;
            pcm_byte_count <= 32'd0;
        end else begin
            stream_done <= 1'b0;
            pcm_valid <= 1'b0;

            if (stream_start) begin
                stream_error <= 1'b0;
                stream_error_code <= 8'd0;
                pcm_byte_offset <= 32'd0;
                pcm_byte_count <= 32'd0;
            end

            if (parser_done && parser_error) begin
                stream_error <= 1'b1;
                stream_error_code <= {4'h3, parser_error_code};
                stream_done <= 1'b1;
            end else if (file_done && file_fs_error != 0) begin
                stream_error <= 1'b1;
                stream_error_code <= file_fs_error;
                stream_done <= 1'b1;
            end else if (file_done && format_ready &&
                         pcm_byte_count < parser_data_size) begin
                stream_error <= 1'b1;
                stream_error_code <= 8'h36;
                stream_done <= 1'b1;
            end else if (file_valid && format_ready &&
                         file_byte_offset >= parser_data_offset &&
                         file_byte_offset < parser_data_end) begin
                pcm_valid <= 1'b1;
                pcm_byte <= file_byte;
                pcm_byte_offset <= pcm_byte_count;
                pcm_byte_count <= pcm_byte_count + 1'b1;
                if (file_byte_offset + 1'b1 == parser_data_end)
                    stream_done <= 1'b1;
            end else if (file_done && !format_ready) begin
                stream_error <= 1'b1;
                stream_error_code <= 8'h36;
                stream_done <= 1'b1;
            end
        end
    end
endmodule

// The supplied narration, emergency and converted BGM assets use the canonical
// 44-byte PCM header. Validate every header byte and both sizes, then stream
// the remaining payload without duplicating general RIFF chunk/cursor logic.
module canonical_wav_file_stream_reader (
    input wire clk, rst_n, stream_start, stream_stop,
    input wire [31:0] first_cluster, file_size,
    input wire [7:0] sectors_per_cluster,
    input wire [31:0] fat_start_lba, data_start_lba, max_cluster,
    input wire pcm_continue,
    output wire stream_busy,
    output reg stream_done, stream_error,
    output reg [7:0] stream_error_code,
    output reg [1:0] channel_count,
    output reg pcm_valid,
    output reg [7:0] pcm_byte,
    output wire sector_req,
    output wire [31:0] sector_lba,
    input wire sector_busy, sector_valid,
    input wire [7:0] sector_byte,
    input wire [8:0] sector_byte_index,
    input wire sector_done,
    input wire [7:0] sector_error
);
    (* fsm_encoding="sequential" *) reg [5:0] header_index;
    reg running, header_bad;
    wire file_done, file_valid;
    wire [7:0] file_byte, file_error;
    wire size_valid = file_size>44 && !file_size[0];
    wire [31:0] riff_bytes = file_size-32'd8;
    wire [31:0] data_bytes = file_size-32'd44;
    reg header_error_q;
    reg [7:0] expected;
    always @* begin
        expected=0;
        case(header_index)
            0:expected="R";1:expected="I";2,3:expected="F";
            4:expected=riff_bytes[7:0];5:expected=riff_bytes[15:8];
            6:expected=riff_bytes[23:16];7:expected=riff_bytes[31:24];
            8:expected="W";9:expected="A";10:expected="V";11:expected="E";
            12:expected="f";13:expected="m";14:expected="t";15:expected=" ";
            16:expected=16;20:expected=1;
            22:expected=file_byte;
            24:expected=8'h80;25:expected=8'hbb;
            29:expected=channel_count==2 ? 8'hee : 8'h77;
            30:expected=channel_count==2 ? 2 : 1;
            32:expected=channel_count==2 ? 4 : 2;
            34:expected=16;
            36:expected="d";37:expected="a";38:expected="t";39:expected="a";
            40:expected=data_bytes[7:0];41:expected=data_bytes[15:8];
            42:expected=data_bytes[23:16];43:expected=data_bytes[31:24];
        endcase
    end
    wire bad_byte = file_byte!=expected ||
        (header_index==22 && file_byte!=1 && file_byte!=2) ||
        (header_index==43 && channel_count==2 && data_bytes[1:0]!=0);
    // Finish header validation before feeding the stream-control fanout.
    // A rejected final header byte must suppress the first payload byte.
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) header_error_q <= 0;
        else if (stream_start || stream_stop) header_error_q <= 0;
        else header_error_q <= file_valid && header_index<44 && bad_byte;
    end
    fat32_file_streamer #(.MAX_VISITED_CLUSTERS(131072)) u_file_streamer (
        .clk(clk), .rst_n(rst_n), .file_start(stream_start && size_valid),
        .file_abort(stream_stop || (header_bad && !stream_start)),
        .first_cluster(first_cluster), .file_size(file_size),
        .file_continue(header_index<44 || pcm_continue),
        .sectors_per_cluster(sectors_per_cluster), .fat_start_lba(fat_start_lba),
        .data_start_lba(data_start_lba), .max_cluster(max_cluster),
        .file_busy(stream_busy), .file_done(file_done), .file_valid(file_valid),
        .file_byte(file_byte), .file_byte_offset(), .fs_error(file_error),
        .sector_req(sector_req), .sector_lba(sector_lba), .sector_busy(sector_busy),
        .sector_valid(sector_valid), .sector_byte(sector_byte),
        .sector_byte_index(sector_byte_index), .sector_done(sector_done),
        .sector_error(sector_error)
    );
    always @(posedge clk or negedge rst_n) begin
        if(!rst_n) begin
            header_index<=0;running<=0;header_bad<=0;channel_count<=1;
            stream_done<=0;stream_error<=0;stream_error_code<=0;
            pcm_valid<=0;pcm_byte<=0;
        end else begin
            stream_done<=0;pcm_valid<=0;
            if(stream_stop) begin running<=0;header_bad<=0;end
            else if(stream_start) begin
                header_index<=0;running<=size_valid;header_bad<=0;channel_count<=1;
                stream_error<=!size_valid;stream_error_code<=size_valid ? 0 : 8'h36;
                stream_done<=!size_valid;
            end else if(running) begin
                if(header_error_q) begin
                    running<=0;header_bad<=1;
                    stream_error<=1;stream_error_code<=8'h35;stream_done<=1;
                end else begin
                    if(file_valid) begin
                        if(header_index<44) begin
                            header_index<=header_index+1'b1;
                            if(header_index==22) channel_count<=file_byte[1:0];
                        end else begin pcm_valid<=1;pcm_byte<=file_byte;end
                    end
                    if(file_done) begin
                        running<=0;stream_done<=1;
                        if(file_error!=0 || header_index<44) begin
                            stream_error<=1;
                            stream_error_code<=file_error!=0 ? file_error : 8'h36;
                        end
                    end
                end
            end
        end
    end
endmodule
