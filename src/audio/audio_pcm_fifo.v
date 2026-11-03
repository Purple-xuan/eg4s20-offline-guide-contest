`timescale 1ns/1ps

module audio_pcm_fifo #(
    parameter integer ADDR_WIDTH = 9,
    parameter integer MONO_STORAGE = 0,
    parameter integer PREFILL_FRAMES = 256,
    parameter integer RESUME_FREE_FRAMES = 256
) (
    input  wire        wr_clk,
    input  wire        wr_rst_n,
    input  wire        stream_start,
    input  wire        stream_stop,
    input  wire        stream_end,
    input  wire [4:0]  stream_tag,
    input  wire [1:0]  channel_count,
    input  wire        pcm_valid,
    input  wire [7:0]  pcm_byte,
    output wire        pcm_continue,
    output wire        fifo_full,
    output wire [ADDR_WIDTH:0] wr_level,

    input  wire        rd_clk,
    input  wire        rd_rst_n,
    input  wire        sample_tick,
    input  wire        playback_pause,
    output reg         sample_valid,
    output reg signed [15:0] sample_left,
    output reg signed [15:0] sample_right,
    output reg         playback_active,
    output reg         playback_done,
    output reg         playback_complete,
    output wire        playback_start,
    output wire        sample_consumed,
    output reg [4:0]   playback_tag,
    output reg  [31:0] underflow_count,
    output wire [ADDR_WIDTH:0] rd_level
);
    localparam integer DEPTH = (1 << ADDR_WIDTH);
    localparam integer SAMPLE_WIDTH = MONO_STORAGE ? 16 : 32;
    localparam integer REFILL_STOP_LEVEL =
        (DEPTH > 256) ? (DEPTH - 256) : (DEPTH - 2);

    reg [1:0] byte_index;
    reg [7:0] byte0, byte1, byte2;
    reg fifo_write_enable;
    reg [SAMPLE_WIDTH-1:0] fifo_write_data;
    wire signed [16:0] stereo_sum =
        $signed({byte1[7],byte1,byte0}) + $signed({pcm_byte[7],pcm_byte,byte2});
    reg refill_paused;
    reg stream_start_toggle_wr;
    reg stream_end_toggle_wr;
    reg stream_run_wr;
    reg [4:0] stream_tag_wr;
    reg [4:0] tag_sync1, tag_sync2;

    reg start_sync1, start_sync2, start_seen_rd;
    reg end_sync1, end_sync2, end_seen_rd;
    reg run_sync1, run_sync2, stream_live_rd;
    reg [2:0] end_settle_rd;
    reg stream_ended_rd;
    reg prefill_ready;
    (* async_reg="true" *) reg pause_meta_rd, pause_sync_rd;

    wire [SAMPLE_WIDTH-1:0] fifo_read_data;
    wire fifo_read_valid;
    wire fifo_empty;
    wire fifo_almost_full;
    wire fifo_almost_empty;
    wire [ADDR_WIDTH-1:0] fifo_wr_level;
    wire [ADDR_WIDTH-1:0] fifo_rd_level;
    wire start_event_rd = start_sync2 != start_seen_rd;
    wire end_event_rd = end_sync2 != end_seen_rd;
    wire fifo_read_enable = sample_tick && !pause_sync_rd &&
                            run_sync2 && stream_live_rd &&
                            prefill_ready && !fifo_empty;
    wire fifo_reset = !wr_rst_n || !rd_rst_n || stream_start || stream_stop;
    assign playback_start = start_event_rd;
    assign sample_consumed = fifo_read_enable;

    assign wr_level = {1'b0, fifo_wr_level};
    assign rd_level = {1'b0, fifo_rd_level};
    assign pcm_continue = !refill_paused && !fifo_full;

    rfifo_32_32_512 #(
        .DATA_WIDTH_W(SAMPLE_WIDTH),
        .DATA_WIDTH_R(SAMPLE_WIDTH),
        .ADDR_WIDTH_W(ADDR_WIDTH),
        .ADDR_WIDTH_R(ADDR_WIDTH),
        .AL_FULL_NUM(REFILL_STOP_LEVEL),
        .AL_EMPTY_NUM(2),
        .SHOW_AHEAD_EN(1'b1),
        .OUTREG_EN("NOREG")
    ) u_pcm_storage (
        .rst(fifo_reset),
        .clkw(wr_clk),
        .clkr(rd_clk),
        .we(fifo_write_enable),
        .di(fifo_write_data),
        .re(fifo_read_enable),
        .dout(fifo_read_data),
        .valid(fifo_read_valid),
        .full_flag(fifo_full),
        .empty_flag(fifo_empty),
        .afull(fifo_almost_full),
        .aempty(fifo_almost_empty),
        .wrusedw(fifo_wr_level),
        .rdusedw(fifo_rd_level)
    );

    always @(posedge wr_clk or negedge wr_rst_n) begin
        if (!wr_rst_n) begin
            byte_index <= 2'd0;
            byte0 <= 8'd0;
            byte1 <= 8'd0;
            byte2 <= 8'd0;
            fifo_write_enable <= 1'b0;
            fifo_write_data <= 32'd0;
            refill_paused <= 1'b0;
            stream_start_toggle_wr <= 1'b0;
            stream_end_toggle_wr <= 1'b0;
            stream_run_wr <= 1'b0;
            stream_tag_wr <= 0;
        end else begin
            fifo_write_enable <= 1'b0;

            if (stream_stop) begin
                byte_index <= 2'd0;
                refill_paused <= 1'b0;
                stream_run_wr <= 1'b0;
            end else if (stream_start) begin
                byte_index <= 2'd0;
                refill_paused <= 1'b0;
                stream_run_wr <= 1'b1;
                stream_start_toggle_wr <= ~stream_start_toggle_wr;
                stream_tag_wr <= stream_tag;
            end else begin
                if (refill_paused && wr_level <= DEPTH - RESUME_FREE_FRAMES)
                    refill_paused <= 1'b0;
                else if (!refill_paused && wr_level >= REFILL_STOP_LEVEL)
                    refill_paused <= 1'b1;

                if (pcm_valid && stream_run_wr) begin
                    case (byte_index)
                        2'd0: begin
                            byte0 <= pcm_byte;
                            byte_index <= 2'd1;
                        end
                        2'd1: begin
                            byte1 <= pcm_byte;
                            if (channel_count == 1) begin
                                if (!fifo_full) begin
                                    fifo_write_data <=
                                        {{pcm_byte, byte0}, {pcm_byte, byte0}};
                                    fifo_write_enable <= 1'b1;
                                end
                                byte_index <= 2'd0;
                            end else begin
                                byte_index <= 2'd2;
                            end
                        end
                        2'd2: begin
                            byte2 <= pcm_byte;
                            byte_index <= 2'd3;
                        end
                        default: begin
                            if (!fifo_full) begin
                                    fifo_write_data <= MONO_STORAGE ?
                                        {16'd0,stereo_sum[16:1]} :
                                        {{pcm_byte, byte2}, {byte1, byte0}};
                                fifo_write_enable <= 1'b1;
                            end
                            byte_index <= 2'd0;
                        end
                    endcase
                end
            end

            if (stream_end && stream_run_wr && !stream_stop && !stream_start)
                stream_end_toggle_wr <= ~stream_end_toggle_wr;
        end
    end

    always @(posedge rd_clk or negedge rd_rst_n) begin
        if (!rd_rst_n) begin
            start_sync1 <= 1'b0;
            start_sync2 <= 1'b0;
            start_seen_rd <= 1'b0;
            end_sync1 <= 1'b0;
            end_sync2 <= 1'b0;
            end_seen_rd <= 1'b0;
            run_sync1 <= 1'b0;
            run_sync2 <= 1'b0;
            stream_live_rd <= 1'b0;
            end_settle_rd <= 0;
            stream_ended_rd <= 1'b0;
            sample_valid <= 1'b0;
            sample_left <= 16'sd0;
            sample_right <= 16'sd0;
            playback_active <= 1'b0;
            playback_done <= 1'b0;
            playback_complete <= 1'b0;
            underflow_count <= 32'd0;
            prefill_ready <= 1'b0;
            pause_meta_rd <= 1'b0;
            pause_sync_rd <= 1'b0;
            tag_sync1 <= 0;
            tag_sync2 <= 0;
            playback_tag <= 0;
        end else begin
            // The tag is held for the stream and crosses with its start toggle.
            tag_sync1 <= stream_tag_wr;
            tag_sync2 <= tag_sync1;
            start_sync1 <= stream_start_toggle_wr;
            start_sync2 <= start_sync1;
            end_sync1 <= stream_end_toggle_wr;
            end_sync2 <= end_sync1;
            run_sync1 <= stream_run_wr;
            run_sync2 <= run_sync1;
            pause_meta_rd <= playback_pause;
            pause_sync_rd <= pause_meta_rd;
            sample_valid <= sample_tick;
            playback_done <= 1'b0;

            if (start_event_rd) begin
                start_seen_rd <= start_sync2;
                end_seen_rd <= end_sync2;
                stream_ended_rd <= 1'b0;
                stream_live_rd <= 1'b1;
                end_settle_rd <= 0;
                playback_complete <= 1'b0;
                sample_left <= 16'sd0;
                sample_right <= 16'sd0;
                playback_active <= 1'b0;
                prefill_ready <= 1'b0;
                underflow_count <= 32'd0;
                playback_tag <= tag_sync2;
            end else if (!run_sync2) begin
                end_seen_rd <= end_sync2;
                stream_live_rd <= 1'b0;
                stream_ended_rd <= 1'b0;
                end_settle_rd <= 0;
                prefill_ready <= 1'b0;
                playback_active <= 1'b0;
                playback_complete <= 1'b0;
                sample_left <= 0;
                sample_right <= 0;
            end else begin
                if (stream_live_rd && !prefill_ready && rd_level >= PREFILL_FRAMES) begin
                    prefill_ready <= 1'b1;
                    playback_active <= 1'b1;
                end else if (stream_live_rd && !prefill_ready && stream_ended_rd &&
                             !fifo_empty) begin
                    prefill_ready <= 1'b1;
                    playback_active <= 1'b1;
                end

                if (end_event_rd) begin
                    end_seen_rd <= end_sync2;
                    if (stream_live_rd) begin
                        stream_ended_rd <= 1'b1;
                        // Let the final registered write and FIFO pointer CDC
                        // settle before accepting an empty (including bad WAV).
                        end_settle_rd <= 3'd7;
                    end
                end else if (end_settle_rd != 0) begin
                    end_settle_rd <= end_settle_rd - 1'b1;
                end

                if (sample_tick) begin
                    sample_valid <= 1'b1;
                    if (!pause_sync_rd && stream_live_rd && prefill_ready && !fifo_empty) begin
                        sample_left <= fifo_read_data[15:0];
                        sample_right <= MONO_STORAGE ? fifo_read_data[15:0] :
                            (fifo_read_data >> 16);
                    end else begin
                        sample_left <= 16'sd0;
                        sample_right <= 16'sd0;
                        if (!pause_sync_rd && playback_active && !stream_ended_rd)
                            underflow_count <= underflow_count + 1'b1;
                    end

                    if (!pause_sync_rd && stream_live_rd && stream_ended_rd && end_settle_rd == 0 &&
                        (fifo_empty || (prefill_ready && rd_level == 1))) begin
                        playback_active <= 1'b0;
                        playback_done <= 1'b1;
                        playback_complete <= 1'b1;
                        stream_live_rd <= 1'b0;
                        prefill_ready <= 1'b0;
                        stream_ended_rd <= 1'b0;
                    end
                end
            end
        end
    end
endmodule
