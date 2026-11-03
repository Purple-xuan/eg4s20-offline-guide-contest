`timescale 1ns/1ps

module wav_riff_parser (
    input  wire        clk,
    input  wire        rst_n,
    input  wire        parse_start,
    input  wire [31:0] file_size,
    input  wire        file_valid,
    input  wire [7:0]  file_byte,
    input  wire [31:0] file_byte_offset,
    input  wire        file_done,
    input  wire [7:0]  file_error,
    output wire        parse_busy,
    output reg         parse_done,
    output reg         parse_error,
    output reg  [3:0]  error_code,
    output reg  [1:0]  channel_count,
    output reg  [31:0] sample_rate,
    output reg  [31:0] byte_rate,
    output reg  [15:0] block_align,
    output reg  [15:0] bits_per_sample,
    output reg  [31:0] data_offset,
    output reg  [31:0] data_size
);
    localparam ERR_NONE         = 4'd0;
    localparam ERR_RIFF         = 4'd1;
    localparam ERR_WAVE         = 4'd2;
    localparam ERR_MALFORMED    = 4'd3;
    localparam ERR_FMT_MISSING  = 4'd4;
    localparam ERR_UNSUPPORTED  = 4'd5;
    localparam ERR_DATA_MISSING = 4'd6;
    localparam ERR_FILE         = 4'd7;

    localparam ST_IDLE       = 3'd0;
    localparam ST_RIFF       = 3'd1;
    localparam ST_CHUNK_ID   = 3'd2;
    localparam ST_CHUNK_SIZE = 3'd3;
    localparam ST_CHUNK_BODY = 3'd4;
    localparam ST_PAD        = 3'd5;
    localparam ST_FINISH     = 3'd6;

    localparam CHUNK_OTHER = 1'b0;
    localparam CHUNK_FMT   = 1'b1;

    reg [2:0] state;
    reg [3:0] riff_index;
    reg [31:0] riff_size;
    reg [1:0] chunk_id_index;
    reg [31:0] chunk_id;
    reg [1:0] chunk_size_index;
    reg [31:0] chunk_size;
    reg [31:0] chunk_remaining;
    reg [31:0] riff_size_limit;
    reg [31:0] chunk_byte_index;
    reg chunk_kind;
    reg chunk_has_pad;
    reg fmt_seen;
    reg [15:0] audio_format;

    wire [31:0] chunk_size_candidate =
        {file_byte, chunk_size[23:0]};
    wire [31:0] chunk_data_offset = file_byte_offset + 1'b1;
    wire data_size_aligned =
        (block_align == 16'd2 && !chunk_size_candidate[0]) ||
        (block_align == 16'd4 && chunk_size_candidate[1:0] == 2'b00);
    wire fmt_core_supported =
        audio_format == 16'd1 && sample_rate == 32'd48000 &&
        ((channel_count == 1 && block_align == 16'd2 &&
          byte_rate == 32'd96000) ||
         (channel_count == 2 && block_align == 16'd4 &&
          byte_rate == 32'd192000));

    assign parse_busy = (state != ST_IDLE);

    task finish_with_error;
        input [3:0] code;
        begin
            parse_error <= 1'b1;
            error_code <= code;
            state <= ST_FINISH;
        end
    endtask

    task finish_success;
        begin
            parse_error <= 1'b0;
            error_code <= ERR_NONE;
            state <= ST_FINISH;
        end
    endtask

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state <= ST_IDLE;
            parse_done <= 1'b0;
            parse_error <= 1'b0;
            error_code <= ERR_NONE;
            channel_count <= 2'd0;
            sample_rate <= 32'd0;
            byte_rate <= 32'd0;
            block_align <= 16'd0;
            bits_per_sample <= 16'd0;
            data_offset <= 32'd0;
            data_size <= 32'd0;
            riff_index <= 4'd0;
            riff_size <= 32'd0;
            chunk_id_index <= 2'd0;
            chunk_id <= 32'd0;
            chunk_size_index <= 2'd0;
            chunk_size <= 32'd0;
            chunk_remaining <= 32'd0;
            riff_size_limit <= 32'd0;
            chunk_byte_index <= 32'd0;
            chunk_kind <= CHUNK_OTHER;
            chunk_has_pad <= 1'b0;
            fmt_seen <= 1'b0;
            audio_format <= 16'd0;
        end else begin
            parse_done <= 1'b0;

            if (state != ST_IDLE && state != ST_FINISH &&
                file_error != 0)
                finish_with_error(ERR_FILE);
            else if (state != ST_IDLE && state != ST_FINISH && file_done)
                finish_with_error(ERR_DATA_MISSING);

            case (state)
                ST_IDLE: if (parse_start) begin
                    parse_error <= 1'b0;
                    error_code <= ERR_NONE;
                    channel_count <= 2'd0;
                    sample_rate <= 32'd0;
                    byte_rate <= 32'd0;
                    block_align <= 16'd0;
                    bits_per_sample <= 16'd0;
                    data_offset <= 32'd0;
                    data_size <= 32'd0;
                    riff_index <= 4'd0;
                    riff_size <= 32'd0;
                    chunk_id_index <= 2'd0;
                    chunk_id <= 32'd0;
                    chunk_size_index <= 2'd0;
                    chunk_size <= 32'd0;
                    chunk_remaining <= 32'd0;
                    // File metadata is stable for a parse; capture this bound
                    // before RIFF bytes arrive instead of subtracting in its check.
                    riff_size_limit <= file_size - 32'd8;
                    chunk_byte_index <= 32'd0;
                    chunk_kind <= CHUNK_OTHER;
                    chunk_has_pad <= 1'b0;
                    fmt_seen <= 1'b0;
                    audio_format <= 16'd0;
                    if (file_size < 32'd20)
                        finish_with_error(ERR_MALFORMED);
                    else
                        state <= ST_RIFF;
                end

                ST_RIFF: if (file_valid) begin
                    case (riff_index)
                        4'd0: if (file_byte != "R") finish_with_error(ERR_RIFF);
                        4'd1: if (file_byte != "I") finish_with_error(ERR_RIFF);
                        4'd2: if (file_byte != "F") finish_with_error(ERR_RIFF);
                        4'd3: if (file_byte != "F") finish_with_error(ERR_RIFF);
                        4'd4: riff_size[7:0] <= file_byte;
                        4'd5: riff_size[15:8] <= file_byte;
                        4'd6: riff_size[23:16] <= file_byte;
                        4'd7: begin
                            riff_size[31:24] <= file_byte;
                            if ({file_byte, riff_size[23:0]} < 32'd12 ||
                                {file_byte, riff_size[23:0]} > riff_size_limit)
                                finish_with_error(ERR_MALFORMED);
                        end
                        4'd8: if (file_byte != "W") finish_with_error(ERR_WAVE);
                        4'd9: if (file_byte != "A") finish_with_error(ERR_WAVE);
                        4'd10: if (file_byte != "V") finish_with_error(ERR_WAVE);
                        4'd11: begin
                            if (file_byte != "E")
                                finish_with_error(ERR_WAVE);
                            else begin
                                chunk_id_index <= 2'd0;
                                chunk_id <= 32'd0;
                                state <= ST_CHUNK_ID;
                            end
                        end
                        default: finish_with_error(ERR_MALFORMED);
                    endcase
                    if (riff_index != 4'd11)
                        riff_index <= riff_index + 1'b1;
                end

                ST_CHUNK_ID: if (file_valid) begin
                    case (chunk_id_index)
                        2'd0: chunk_id[7:0] <= file_byte;
                        2'd1: chunk_id[15:8] <= file_byte;
                        2'd2: chunk_id[23:16] <= file_byte;
                        default: begin
                            chunk_id[31:24] <= file_byte;
                            chunk_size_index <= 2'd0;
                            chunk_size <= 32'd0;
                            state <= ST_CHUNK_SIZE;
                        end
                    endcase
                    chunk_id_index <= chunk_id_index + 1'b1;
                end

                ST_CHUNK_SIZE: if (file_valid) begin
                    case (chunk_size_index)
                        2'd0: chunk_size[7:0] <= file_byte;
                        2'd1: chunk_size[15:8] <= file_byte;
                        2'd2: chunk_size[23:16] <= file_byte;
                        default: begin
                            chunk_size[31:24] <= file_byte;
                            if (chunk_size_candidate > file_size) begin
                                finish_with_error(ERR_MALFORMED);
                            end else if (chunk_id == 32'h61746164) begin
                                if (!fmt_seen) begin
                                    finish_with_error(ERR_FMT_MISSING);
                                end else if (chunk_size_candidate == 0 ||
                                             !data_size_aligned) begin
                                    finish_with_error(ERR_MALFORMED);
                                end else begin
                                    data_offset <= chunk_data_offset;
                                    data_size <= chunk_size_candidate;
                                    finish_success;
                                end
                            end else begin
                                chunk_kind <= (chunk_id == 32'h20746d66) ?
                                              CHUNK_FMT : CHUNK_OTHER;
                                if (chunk_id == 32'h20746d66 &&
                                    chunk_size_candidate < 16) begin
                                    finish_with_error(ERR_MALFORMED);
                                end else if (chunk_size_candidate == 0) begin
                                    chunk_id_index <= 2'd0;
                                    chunk_id <= 32'd0;
                                    state <= ST_CHUNK_ID;
                                end else begin
                                    chunk_remaining <= chunk_size_candidate;
                                    chunk_byte_index <= 32'd0;
                                    chunk_has_pad <= chunk_size_candidate[0];
                                    state <= ST_CHUNK_BODY;
                                end
                            end
                        end
                    endcase
                    chunk_size_index <= chunk_size_index + 1'b1;
                end

                ST_CHUNK_BODY: if (file_valid) begin
                    if (chunk_kind == CHUNK_FMT) begin
                        case (chunk_byte_index)
                            32'd0: audio_format[7:0] <= file_byte;
                            32'd1: audio_format[15:8] <= file_byte;
                            32'd2: channel_count <= file_byte[1:0];
                            32'd4: sample_rate[7:0] <= file_byte;
                            32'd5: sample_rate[15:8] <= file_byte;
                            32'd6: sample_rate[23:16] <= file_byte;
                            32'd7: sample_rate[31:24] <= file_byte;
                            32'd8: byte_rate[7:0] <= file_byte;
                            32'd9: byte_rate[15:8] <= file_byte;
                            32'd10: byte_rate[23:16] <= file_byte;
                            32'd11: byte_rate[31:24] <= file_byte;
                            32'd12: block_align[7:0] <= file_byte;
                            32'd13: block_align[15:8] <= file_byte;
                            32'd14: bits_per_sample[7:0] <= file_byte;
                            32'd15: begin
                                bits_per_sample[15:8] <= file_byte;
                                if (!fmt_core_supported ||
                                    {file_byte, bits_per_sample[7:0]} != 16'd16 ||
                                    block_align != ({14'd0, channel_count} << 1))
                                    finish_with_error(ERR_UNSUPPORTED);
                                else
                                    fmt_seen <= 1'b1;
                            end
                            default: begin end
                        endcase
                    end

                    if (!(chunk_kind == CHUNK_FMT &&
                          chunk_byte_index == 32'd15 &&
                           (!fmt_core_supported ||
                           {file_byte, bits_per_sample[7:0]} != 16'd16 ||
                            block_align != ({14'd0, channel_count} << 1)))) begin
                        if (chunk_remaining == 1) begin
                            if (chunk_has_pad)
                                state <= ST_PAD;
                            else begin
                                chunk_id_index <= 2'd0;
                                chunk_id <= 32'd0;
                                state <= ST_CHUNK_ID;
                            end
                        end else begin
                            chunk_remaining <= chunk_remaining - 1'b1;
                            chunk_byte_index <= chunk_byte_index + 1'b1;
                        end
                    end
                end

                ST_PAD: if (file_valid) begin
                    chunk_id_index <= 2'd0;
                    chunk_id <= 32'd0;
                    state <= ST_CHUNK_ID;
                end

                ST_FINISH: begin
                    parse_done <= 1'b1;
                    state <= ST_IDLE;
                end

                default: state <= ST_IDLE;
            endcase
        end
    end
endmodule
