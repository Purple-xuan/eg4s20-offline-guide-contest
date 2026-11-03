`timescale 1ns/1ps

module media_frame_reader #(
    parameter integer ADDR_WIDTH = 21,
    parameter integer IMAGE_WORDS = 460800,
    parameter integer FRAME_PIXELS = IMAGE_WORDS * 2,
    parameter integer FRAME_WIDTH = 1280,
    parameter integer FIFO_DEPTH = 512,
    parameter integer FIFO_MARGIN = 8,
    parameter integer BURST_SIZE = 128,
    parameter integer BURST_GAP_CYCLES = 12,
    parameter integer MAX_INFLIGHT_BURSTS = 2,
    parameter integer DRAIN_TIMEOUT_CYCLES = 64,
    parameter integer DIAG_RETURN_PATTERN = 0,
    parameter integer DIAG_SYNTH_STREAM = 0,
    parameter integer ENABLE_MANUAL_WIPE = 0,
    parameter integer WIPE_FRAMES = 48,
    parameter integer SDRAM_PAGE_WORDS = 256,
    parameter integer WIPE_WORD_ALIGNMENT = 1,
    parameter integer ENABLE_GALLERY_SDRAM = 0
) (
    input  wire                  mem_clk,
    input  wire                  mem_rst_n,
    input  wire                  controller_init_done,
    input  wire                  controller_busy,
    input  wire                  refresh_active,
    input  wire                  writer_busy,
    output reg                   app_rd_en,
    output reg  [ADDR_WIDTH-1:0] app_rd_addr,
    input  wire                  sdram_rd_valid,
    input  wire [31:0]           sdram_rd_data,

    input  wire                  pix_clk,
    input  wire                  pix_rst_n,
    input  wire                  frame_start,
    input  wire [1:0]            active_index,
    input  wire                  manual_switch,
    input  wire                  reverse_switch,
    input  wire                  emergency_active,
    input  wire                  gallery_active,
    input  wire [7:0]            gallery_ready_mask,
    input  wire                  pixel_consume,
    output wire [23:0]           pixel_rgb,
    output wire                  pixel_valid,
    output reg                   underflow,

    output reg                   reader_busy,
    output reg                   frame_read_done,
    output reg  [1:0]            reader_index,
    output wire [1:0]            reader_target_index,
    output wire                  manual_wipe_active,
    output reg                   manual_page_pulse,
    output reg  [7:0]            reader_error,
    output wire                  reader_idle,
    output wire                  reader_command_busy,
    output wire                  reader_urgent
);
    localparam [7:0] ERR_NONE          = 8'h00;
    localparam [7:0] ERR_FRAME_OVERRUN = 8'h61;
    localparam [7:0] ERR_FIFO_OVERFLOW = 8'h62;
    localparam [7:0] ERR_UNDERFLOW     = 8'h63;
    localparam [7:0] ERR_SHORT_FRAME   = 8'h64;
    localparam integer FIFO_COUNT_W = (FIFO_DEPTH <= 2) ? 1 : $clog2(FIFO_DEPTH);
    localparam integer BURST_COUNT_W =
        (BURST_SIZE < 2) ? 1 : $clog2(BURST_SIZE + 1);
    localparam integer INFLIGHT_COUNT_W =
        (MAX_INFLIGHT_BURSTS * BURST_SIZE < 2) ? 1 :
        $clog2(MAX_INFLIGHT_BURSTS * BURST_SIZE + 1);

    reg request_pending_pix;
    reg request_launch_pix;
    reg request_toggle_pix;
    reg [1:0] request_index_pix;
    reg [8:0] request_gallery_pix;
    (* async_reg="true" *) reg [8:0] gallery_sync1_mem, gallery_sync2_mem;
    reg [8:0] reload_gallery_mem;
    reg gallery_mem;
    reg [7:0] gallery_ready_mem;
    reg [9:0] line_mem;
    reg frame_armed_pix;
    reg [ADDR_WIDTH:0] consumed_count_pix;

    (* async_reg = "true" *) reg request_sync1_mem;
    (* async_reg = "true" *) reg request_sync2_mem;
    reg request_sync3_mem;
    reg request_seen_mem;
    (* async_reg = "true" *) reg [1:0] index_sync1_mem;
    (* async_reg = "true" *) reg [1:0] index_sync2_mem;
    reg reload_pending_mem;
    reg [1:0] reload_index_mem;
    reg [2:0] fifo_reset_count_mem;
    reg [ADDR_WIDTH:0] issued_count_mem;
    reg [ADDR_WIDTH:0] returned_count_mem;
    reg [INFLIGHT_COUNT_W-1:0] inflight_count_mem;
    reg inflight_empty_mem /* fehdl keep="true" */;
    reg burst_active_mem;
    reg [BURST_COUNT_W-1:0] burst_issued_mem;
    reg [BURST_COUNT_W-1:0] burst_target_mem;
    reg [7:0] burst_gap_count_mem;
    reg [ADDR_WIDTH:0] diag_written_count_mem;
    reg [10:0] diag_column_mem;
    reg [23:0] diag_rgb_mem;
    reg [1:0] fifo_release_mem;
    reg [1:0] fifo_release_pix;
    reg pixel_half;
    reg frame_bad_pix;

    localparam integer LINE_WORDS = FRAME_WIDTH / 2;
    localparam integer COLUMN_W = $clog2(LINE_WORDS + 1);
    // The vendor controller emits fixed four-word SDRAM bursts. Quantize
    // the edge, not individual commands, so both images stay aligned.
    localparam integer WIPE_UNITS = LINE_WORDS / WIPE_WORD_ALIGNMENT;
    localparam integer WIPE_STEP = (WIPE_UNITS / WIPE_FRAMES) * WIPE_WORD_ALIGNMENT;
    localparam integer WIPE_REMAINDER = WIPE_UNITS % WIPE_FRAMES;
    localparam integer FRACTION_W = (WIPE_FRAMES < 2) ? 1 : $clog2(WIPE_FRAMES + 1);
    localparam integer PAGE_W = $clog2(SDRAM_PAGE_WORDS + 1);
    reg [FRACTION_W-1:0] fraction_pix;
    reg [COLUMN_W-1:0] edge_pix;
    wire [FRACTION_W:0] fraction_sum = {1'b0, fraction_pix} + WIPE_REMAINDER;
    wire [COLUMN_W:0] next_edge_pix = {1'b0, edge_pix} + WIPE_STEP +
                                     ((fraction_sum >= WIPE_FRAMES) ? WIPE_WORD_ALIGNMENT : 0);
    reg wipe_pix;
    reg [1:0] old_bank_pix;
    reg request_wipe_pix;
    reg [COLUMN_W-1:0] request_edge_pix;
    reg [1:0] request_old_pix;
    reg request_reverse_pix;
    (* async_reg = "true" *) reg [COLUMN_W+3:0] wipe_sync1_mem, wipe_sync2_mem;
    reg [COLUMN_W+3:0] reload_wipe_mem;
    reg reverse_mem;
    reg wipe_mem;
    reg [COLUMN_W-1:0] edge_mem, column_mem;
    reg [1:0] old_bank_mem, target_bank_mem;
    assign reader_target_index = target_bank_mem;
    assign manual_wipe_active = wipe_pix;

    wire fifo_reset_request = !mem_rst_n || !pix_rst_n ||
                              !controller_init_done ||
                              (fifo_reset_count_mem != 0);
    wire fifo_reset = fifo_reset_request ||
                      !fifo_release_mem[1] || !fifo_release_pix[1];
    wire fifo_full;
    wire fifo_empty;
    wire fifo_almost_full;
    wire [FIFO_COUNT_W-1:0] fifo_wrusedw;
    wire [31:0] fifo_raw_data;
    wire fifo_raw_valid;
    wire fifo_raw_read_en;
    wire prefetch_valid;
    wire [31:0] prefetch_data;
    wire word_pop = pixel_consume && prefetch_valid && pixel_half && !frame_bad_pix;
    wire [ADDR_WIDTH:0] inflight_words =
        {{(ADDR_WIDTH+1-INFLIGHT_COUNT_W){1'b0}}, inflight_count_mem};
    wire final_return = returned_count_mem == IMAGE_WORDS - 1;
    wire [ADDR_WIDTH+1:0] reserved_words =
        {{(ADDR_WIDTH+2-FIFO_COUNT_W){1'b0}}, fifo_wrusedw} +
        {{1{1'b0}}, inflight_words};
    localparam integer FULL_BURSTS_ONLY = (IMAGE_WORDS % BURST_SIZE) == 0;
    wire [ADDR_WIDTH:0] remaining_words = IMAGE_WORDS - issued_count_mem;
    wire [ADDR_WIDTH:0] normal_burst_words =
        FULL_BURSTS_ONLY ? BURST_SIZE :
        ((remaining_words > BURST_SIZE) ? BURST_SIZE : remaining_words);
    reg [COLUMN_W-1:0] split_mem;
    wire target_segment_mem = (column_mem < split_mem) ^ reverse_mem;
    wire [COLUMN_W-1:0] segment_words = column_mem < split_mem ?
        split_mem - column_mem : LINE_WORDS - column_mem;
    // Plan only while the address is stationary. A command must end at the
    // configured address page, as well as the image edge and line boundary.
    reg [2:0] plan_state_mem;
    reg [ADDR_WIDTH-1:0] plan_addr_mem, burst_addr_mem;
    reg [BURST_COUNT_W-1:0] plan_normal_mem, plan_words_mem;
    reg [COLUMN_W-1:0] plan_segment_mem;
    reg plan_wipe_mem;
    reg plan_fill_mem, burst_fill_mem;
    reg [ADDR_WIDTH-1:0] gallery_page_base_q, gallery_row_offset_q;
    reg [7:0] gallery_row_q;
    reg [8:0] gallery_word_q;
    reg [BURST_COUNT_W-1:0] gallery_segment_q;
    wire [1:0] gallery_grid_row=line_mem>=496 ? 2 : (line_mem>=264 ? 1 : 0);
    wire [9:0] gallery_top=gallery_grid_row==2 ? 496 : (gallery_grid_row==1 ? 264 : 32);
    wire [9:0] gallery_local_y=line_mem-gallery_top;
    wire [1:0] gallery_grid_col=column_mem>=440 ? 2 : (column_mem>=240 ? 1 : 0);
    wire [COLUMN_W-1:0] gallery_left=gallery_grid_col==2 ? 440 : (gallery_grid_col==1 ? 240 : 40);
    wire gallery_image_column=column_mem>=gallery_left && column_mem<gallery_left+160;
    wire [3:0] gallery_slot=gallery_grid_row*3+gallery_grid_col;
    // Decode readiness by row and column without an add followed by an
    // eight-way variable bit select on the SDRAM command planning path.
    wire [2:0] gallery_row_ready=gallery_grid_row==0 ? gallery_ready_mem[2:0] :
        gallery_grid_row==1 ? gallery_ready_mem[5:3] : {1'b0,gallery_ready_mem[7:6]};
    wire gallery_cell_ready=(gallery_grid_col==0 && gallery_row_ready[0]) ||
        (gallery_grid_col==1 && gallery_row_ready[1]) ||
        (gallery_grid_col==2 && gallery_row_ready[2]);
    wire gallery_image=gallery_image_column && gallery_local_y<180 &&
        gallery_cell_ready;
    wire [COLUMN_W-1:0] gallery_segment_end=column_mem<40 ? 40 :
        column_mem<200 ? 200 : column_mem<240 ? 240 :
        column_mem<400 ? 400 : column_mem<440 ? 440 :
        column_mem<600 ? 600 : LINE_WORDS;
    wire [COLUMN_W-1:0] gallery_segment=gallery_segment_end-column_mem;
    function [ADDR_WIDTH-1:0] thumbnail_base;
        input [2:0] id;
        begin
            case(id)
                0:thumbnail_base=1843200;
                1:thumbnail_base=1872000;
                2:thumbnail_base=1900800;
                3:thumbnail_base=1929600;
                4:thumbnail_base=1958400;
                5:thumbnail_base=1987200;
                6:thumbnail_base=2016000;
                default:thumbnail_base=2044800;
            endcase
        end
    endfunction
    wire [PAGE_W-1:0] plan_page_words = SDRAM_PAGE_WORDS -
                                      (plan_addr_mem & (SDRAM_PAGE_WORDS - 1));
    wire [BURST_COUNT_W-1:0] plan_image_words = plan_wipe_mem &&
        plan_segment_mem < plan_normal_mem ? plan_segment_mem : plan_normal_mem;
    wire [BURST_COUNT_W-1:0] plan_bounded_words =
        plan_page_words < plan_image_words ? plan_page_words : plan_image_words;
    // Reserve a full burst conservatively. This removes the edge-dependent
    // subtract/min/add/compare chain from the 125 MHz FIFO safety path.
    wire inflight_window_ok = (MAX_INFLIGHT_BURSTS == 1) ?
        inflight_empty_mem :
        (inflight_words <= ((MAX_INFLIGHT_BURSTS - 1) * BURST_SIZE));
    wire fifo_reservation_ok =
        reserved_words <= (FIFO_DEPTH - FIFO_MARGIN - BURST_SIZE);
    reg inflight_window_ok_q;
    reg fifo_reservation_ok_q;
    reg [15:0] drain_quiet_count_mem;
    assign reader_idle = !reader_busy && !burst_active_mem &&
                         inflight_empty_mem && !app_rd_en;
    assign reader_command_busy = burst_active_mem ||
                                 !inflight_empty_mem || app_rd_en;
    // Reserve the next idle SDRAM slot for video whenever another read burst
    // fits. This prevents a ready background writer from adding one full write
    // burst of latency just as the display FIFO reaches its refill threshold.
    assign reader_urgent = !DIAG_SYNTH_STREAM && reader_busy &&
                           controller_init_done &&
                           fifo_reset_count_mem == 0 &&
                           !burst_active_mem && inflight_empty_mem &&
                           issued_count_mem != IMAGE_WORDS &&
                           fifo_reservation_ok_q;
    // The SDRAM wrapper arbitrates refresh/write activity internally.  Do not
    // launch a read command while it reports a command or refresh in progress;
    // the legacy frame reader made the same guarantee through App_rd_busy.
    wire start_burst = !DIAG_SYNTH_STREAM && reader_busy && controller_init_done &&
                       !controller_busy && !refresh_active && !writer_busy &&
                       fifo_reset_count_mem == 0 && !burst_active_mem &&
                       burst_gap_count_mem == 0 &&
                       issued_count_mem != IMAGE_WORDS &&
                       !reload_pending_mem && request_sync2_mem == request_seen_mem &&
                       plan_state_mem == 2 &&
                       (!plan_fill_mem || inflight_empty_mem) &&
                       inflight_window_ok_q && fifo_reservation_ok_q;
    wire issue_allowed = !DIAG_SYNTH_STREAM && reader_busy && burst_active_mem;
    wire issue_read=issue_allowed && !burst_fill_mem;
    wire fill_write=issue_allowed && burst_fill_mem;
    wire word_return=sdram_rd_valid || fill_write;
    wire diag_stream_write = DIAG_SYNTH_STREAM && reader_busy &&
                             !fifo_reset && !fifo_full;
    // The FIFO primitive rejects a write while full and the reader reports
    // that condition below.  Omitting fifo_full here keeps the normal write
    // enable off its long address/level feedback path; reservation logic
    // already leaves a full burst of headroom.
    wire fifo_write_enable = DIAG_SYNTH_STREAM ? diag_stream_write :
                             (word_return && !fifo_reset);
    wire [15:0] diag_rgb565 = {
        diag_rgb_mem[23:19], diag_rgb_mem[15:10], diag_rgb_mem[7:3]
    };
    wire [31:0] fifo_write_data = (DIAG_RETURN_PATTERN || DIAG_SYNTH_STREAM) ?
                                  {diag_rgb565, diag_rgb565} :
                                  (fill_write ? 32'd0 : sdram_rd_data);

    always @* begin
        if (diag_column_mem < FRAME_WIDTH / 8)
            diag_rgb_mem = 24'hffffff;
        else if (diag_column_mem < FRAME_WIDTH / 4)
            diag_rgb_mem = 24'hffff00;
        else if (diag_column_mem < (FRAME_WIDTH * 3) / 8)
            diag_rgb_mem = 24'h00ffff;
        else if (diag_column_mem < FRAME_WIDTH / 2)
            diag_rgb_mem = 24'h00ff00;
        else if (diag_column_mem < (FRAME_WIDTH * 5) / 8)
            diag_rgb_mem = 24'hff00ff;
        else if (diag_column_mem < (FRAME_WIDTH * 3) / 4)
            diag_rgb_mem = 24'hff0000;
        else if (diag_column_mem < (FRAME_WIDTH * 7) / 8)
            diag_rgb_mem = 24'h0000ff;
        else
            diag_rgb_mem = 24'h000000;
    end

    function [ADDR_WIDTH-1:0] bank_base;
        input [1:0] index;
        begin
            case (index)
                2'd0: bank_base = {ADDR_WIDTH{1'b0}};
                2'd1: bank_base = IMAGE_WORDS;
                2'd2: bank_base = IMAGE_WORDS * 2;
                default: bank_base = IMAGE_WORDS * 3;
            endcase
        end
    endfunction

    // Capture frame parameters first, then notify memory one pixel clock later.
    // The extra destination toggle stage also tolerates data synchronizer skew.
    always @(posedge pix_clk or negedge pix_rst_n) begin
        if (!pix_rst_n) begin
            request_pending_pix <= 1'b0;
            request_launch_pix <= 1'b0;
            request_toggle_pix <= 1'b0;
            request_index_pix <= 2'd0;
            request_gallery_pix<=0;
            frame_armed_pix <= 1'b0;
            consumed_count_pix <= 0;
            underflow <= 1'b0;
            fifo_release_pix <= 2'b00;
            pixel_half <= 1'b0;
            frame_bad_pix <= 1'b0;
            fraction_pix <= 0;
            wipe_pix <= 1'b0;
            edge_pix <= 0;
            old_bank_pix <= 0;
            request_wipe_pix <= 1'b0;
            request_edge_pix <= 0;
            request_old_pix <= 0;
            request_reverse_pix <= 0;
            manual_page_pulse <= 1'b0;
        end else begin
            manual_page_pulse <= 1'b0;
            if (request_launch_pix) begin
                request_toggle_pix <= ~request_toggle_pix;
                request_launch_pix <= 1'b0;
            end
            if (fifo_reset_request)
                fifo_release_pix <= 2'b00;
            else
                fifo_release_pix <= {fifo_release_pix[0], 1'b1};

            if (frame_start) begin
                if (frame_armed_pix && consumed_count_pix != FRAME_PIXELS) begin
                    underflow <= 1'b1;
                end
                consumed_count_pix <= 0;
                request_pending_pix <= 1'b1;
                pixel_half <= 1'b0;
                frame_bad_pix <= 1'b0;
            end else if (request_pending_pix) begin
                request_index_pix <= active_index;
                request_gallery_pix<={ENABLE_GALLERY_SDRAM && gallery_active,gallery_ready_mask};
                manual_page_pulse <= frame_armed_pix && manual_switch &&
                                     !emergency_active && active_index != request_index_pix;
                // Capture the cause and bank together, including a bank that
                // becomes synchronized in the cycle after frame_start.
                request_old_pix <= old_bank_pix;
                if (!ENABLE_MANUAL_WIPE || emergency_active) begin
                    wipe_pix <= 1'b0;
                    request_wipe_pix <= 1'b0;
                end else if (active_index != request_index_pix) begin
                    request_reverse_pix <= reverse_switch;
                    // Latch direction with the new bank for the entire wipe.
                    // Manual-only signaling keeps automatic changes silent.
                    wipe_pix <= frame_armed_pix && !emergency_active;
                    request_wipe_pix <= frame_armed_pix && !emergency_active;
                    edge_pix <= WIPE_STEP;
                    request_edge_pix <= WIPE_STEP;
                    fraction_pix <= WIPE_REMAINDER;
                    old_bank_pix <= request_index_pix;
                    request_old_pix <= request_index_pix;
                end else if (wipe_pix && next_edge_pix < LINE_WORDS) begin
                    edge_pix <= next_edge_pix[COLUMN_W-1:0];
                    request_edge_pix <= next_edge_pix[COLUMN_W-1:0];
                    fraction_pix <= fraction_sum >= WIPE_FRAMES ?
                                    fraction_sum - WIPE_FRAMES : fraction_sum;
                    request_wipe_pix <= 1'b1;
                end else begin
                    wipe_pix <= 1'b0;
                    request_wipe_pix <= 1'b0;
                end
                request_launch_pix <= 1'b1;
                request_pending_pix <= 1'b0;
                frame_armed_pix <= 1'b1;
            end

            if (pixel_consume && !frame_bad_pix) begin
                if (prefetch_valid) begin
                    consumed_count_pix <= consumed_count_pix + 1'b1;
                    pixel_half <= ~pixel_half;
                end else if (frame_armed_pix) begin
                    underflow <= 1'b1;
                    // Never resume a delayed stream at the wrong screen
                    // coordinate. The next frame request resets and refills it.
                    frame_bad_pix <= 1'b1;
                end
            end
        end
    end

    always @(posedge mem_clk or negedge mem_rst_n) begin
        if (!mem_rst_n) begin
            request_sync1_mem <= 1'b0;
            request_sync2_mem <= 1'b0;
            request_sync3_mem <= 1'b0;
            request_seen_mem <= 1'b0;
            index_sync1_mem <= 2'd0;
            index_sync2_mem <= 2'd0;
            reload_pending_mem <= 1'b0;
            reload_index_mem <= 2'd0;
            fifo_reset_count_mem <= 3'd0;
            issued_count_mem <= 0;
            returned_count_mem <= 0;
            inflight_count_mem <= 0;
            inflight_empty_mem <= 1'b1;
            burst_active_mem <= 1'b0;
            burst_issued_mem <= 0;
            burst_target_mem <= 0;
            burst_gap_count_mem <= 0;
            diag_written_count_mem <= 0;
            diag_column_mem <= 0;
            fifo_release_mem <= 2'b00;
            inflight_window_ok_q <= 1'b1;
            fifo_reservation_ok_q <= 1'b1;
            drain_quiet_count_mem <= 16'd0;
            app_rd_en <= 1'b0;
            app_rd_addr <= 0;
            reader_busy <= 1'b0;
            frame_read_done <= 1'b0;
            reader_index <= 2'd0;
            reader_error <= ERR_NONE;
            wipe_sync1_mem <= 0;
            wipe_sync2_mem <= 0;
            reload_wipe_mem <= 0;
            wipe_mem <= 1'b0;
            reverse_mem <= 1'b0;
            split_mem <= 0;
            edge_mem <= 0;
            column_mem <= 0;
            old_bank_mem <= 0;
            target_bank_mem <= 0;
            plan_state_mem <= 0;
            plan_addr_mem <= 0;
            burst_addr_mem <= 0;
            plan_normal_mem <= 0;
            plan_words_mem <= 0;
            plan_segment_mem <= 0;
            plan_wipe_mem <= 0;
            gallery_sync1_mem<=0;gallery_sync2_mem<=0;reload_gallery_mem<=0;
            gallery_mem<=0;gallery_ready_mem<=0;line_mem<=0;
            plan_fill_mem<=0;burst_fill_mem<=0;
            gallery_page_base_q<=0;gallery_row_offset_q<=0;
            gallery_row_q<=0;gallery_word_q<=0;gallery_segment_q<=0;
        end else begin
            if (fifo_reset_request)
                fifo_release_mem <= 2'b00;
            else
                fifo_release_mem <= {fifo_release_mem[0], 1'b1};

            request_sync1_mem <= request_toggle_pix;
            request_sync2_mem <= request_sync1_mem;
            request_sync3_mem <= request_sync2_mem;
            index_sync1_mem <= request_index_pix;
            index_sync2_mem <= index_sync1_mem;
            gallery_sync1_mem<=request_gallery_pix;
            gallery_sync2_mem<=gallery_sync1_mem;
            wipe_sync1_mem <= {request_reverse_pix, request_wipe_pix, request_old_pix, request_edge_pix};
            wipe_sync2_mem <= wipe_sync1_mem;
            app_rd_en <= 1'b0;
            frame_read_done <= 1'b0;
            inflight_window_ok_q <= inflight_window_ok;
            fifo_reservation_ok_q <= fifo_reservation_ok;

            if (reader_busy && fifo_reset_count_mem == 0 &&
                !burst_active_mem && !app_rd_en) begin
                if (plan_state_mem == 0) begin
                    plan_fill_mem<=0;
                    if(ENABLE_GALLERY_SDRAM && gallery_mem) begin
                        gallery_page_base_q<=thumbnail_base(gallery_slot[2:0]);
                        gallery_row_q<=gallery_local_y[7:0];
                        gallery_word_q<=column_mem-gallery_left;
                        gallery_segment_q<=gallery_segment;
                        plan_fill_mem<=!gallery_image;
                        plan_wipe_mem<=0;
                        plan_state_mem<=3;
                    end else begin
                        plan_addr_mem <= bank_base(wipe_mem ?
                            (target_segment_mem ? target_bank_mem : old_bank_mem) :
                            reader_index) + issued_count_mem[ADDR_WIDTH-1:0];
                        plan_normal_mem <= normal_burst_words[BURST_COUNT_W-1:0];
                        plan_segment_mem <= segment_words;
                        plan_wipe_mem <= wipe_mem;
                        plan_state_mem <= 1;
                    end
                end else if(plan_state_mem==3) begin
                    gallery_row_offset_q<=({{(ADDR_WIDTH-8){1'b0}},gallery_row_q}<<7)+
                                          ({{(ADDR_WIDTH-8){1'b0}},gallery_row_q}<<5);
                    plan_normal_mem<=gallery_segment_q;
                    plan_state_mem<=4;
                end else if(plan_state_mem==4) begin
                    plan_addr_mem<=gallery_page_base_q+gallery_row_offset_q+gallery_word_q;
                    plan_state_mem<=1;
                end else if (plan_state_mem == 1) begin
                    plan_words_mem <= plan_bounded_words;
                    plan_state_mem <= 2;
                end
            end

            if (controller_init_done || inflight_empty_mem || sdram_rd_valid)
                drain_quiet_count_mem <= 16'd0;
            else if (drain_quiet_count_mem < DRAIN_TIMEOUT_CYCLES)
                drain_quiet_count_mem <= drain_quiet_count_mem + 1'b1;

            if (fifo_reset_count_mem != 0)
                fifo_reset_count_mem <= fifo_reset_count_mem - 1'b1;
            if (burst_gap_count_mem != 0)
                burst_gap_count_mem <= burst_gap_count_mem - 1'b1;

            case ({issue_read, sdram_rd_valid})
                2'b10: begin
                    inflight_count_mem <= inflight_count_mem + 1'b1;
                    inflight_empty_mem <= 1'b0;
                end
                2'b01: begin
                    if (!inflight_empty_mem) begin
                        inflight_count_mem <= inflight_count_mem - 1'b1;
                        if (inflight_count_mem == 1)
                            inflight_empty_mem <= 1'b1;
                    end
                end
                default: begin
                    inflight_count_mem <= inflight_count_mem;
                    inflight_empty_mem <= inflight_empty_mem;
                end
            endcase

            if (request_sync3_mem != request_seen_mem) begin
                plan_state_mem <= 0;
                request_seen_mem <= request_sync3_mem;
                reload_pending_mem <= 1'b1;
                reload_index_mem <= index_sync2_mem;
                reload_wipe_mem <= wipe_sync2_mem;
                reload_gallery_mem<=gallery_sync2_mem;
                if (reader_busy || !inflight_empty_mem) begin
                    reader_busy <= 1'b0;
                    burst_active_mem <= 1'b0;
                    reader_error <= ERR_FRAME_OVERRUN;
                end
            end

            if (reload_pending_mem && inflight_empty_mem) begin
                plan_state_mem <= 0;
                reload_pending_mem <= 1'b0;
                // A mixed frame still owns the old bank. Acknowledge the new
                // bank only once no future read can reference the old image.
                reader_index <= reload_wipe_mem[COLUMN_W+2] ?
                    reload_wipe_mem[COLUMN_W+1:COLUMN_W] : reload_index_mem;
                wipe_mem <= reload_wipe_mem[COLUMN_W+2];
                reverse_mem <= reload_wipe_mem[COLUMN_W+3];
                split_mem <= reload_wipe_mem[COLUMN_W+3] ?
                    LINE_WORDS - reload_wipe_mem[COLUMN_W-1:0] :
                    reload_wipe_mem[COLUMN_W-1:0];
                old_bank_mem <= reload_wipe_mem[COLUMN_W+1:COLUMN_W];
                edge_mem <= reload_wipe_mem[COLUMN_W-1:0];
                target_bank_mem <= reload_index_mem;
                column_mem <= 0;
                line_mem<=0;
                gallery_mem<=ENABLE_GALLERY_SDRAM && reload_gallery_mem[8];
                gallery_ready_mem<=reload_gallery_mem[7:0];
                burst_fill_mem<=0;
                issued_count_mem <= 0;
                returned_count_mem <= 0;
                inflight_count_mem <= 0;
                inflight_empty_mem <= 1'b1;
                burst_active_mem <= 1'b0;
                burst_issued_mem <= 0;
                burst_target_mem <= 0;
                burst_gap_count_mem <= 0;
                diag_written_count_mem <= 0;
                diag_column_mem <= 0;
                fifo_reset_count_mem <= 3'd4;
                reader_busy <= 1'b1;
                reader_error <= ERR_NONE;
            end

            if (start_burst) begin
                plan_state_mem <= 0;
                burst_addr_mem <= plan_addr_mem;
                burst_active_mem <= 1'b1;
                burst_issued_mem <= 0;
                burst_target_mem <= plan_words_mem;
                burst_fill_mem<=plan_fill_mem;
            end

            if (issue_allowed) begin
                app_rd_en <= !burst_fill_mem;
                app_rd_addr <= burst_addr_mem;
                burst_addr_mem <= burst_addr_mem + 1'b1;
                column_mem <= column_mem == LINE_WORDS - 1 ? 0 : column_mem + 1'b1;
                if(column_mem==LINE_WORDS-1) line_mem<=line_mem+1'b1;
                issued_count_mem <= issued_count_mem + 1'b1;
                burst_issued_mem <= burst_issued_mem + 1'b1;
                if (burst_issued_mem + 1'b1 == burst_target_mem) begin
                    burst_active_mem <= 1'b0;
                    burst_gap_count_mem <= BURST_GAP_CYCLES;
                end
            end

            if (!DIAG_SYNTH_STREAM && word_return) begin
                returned_count_mem <= returned_count_mem + 1'b1;
                if (fifo_full) begin
                    reader_busy <= 1'b0;
                    burst_active_mem <= 1'b0;
                    reader_error <= ERR_FIFO_OVERFLOW;
                end else if (final_return) begin
                    reader_busy <= 1'b0;
                    burst_active_mem <= 1'b0;
                    frame_read_done <= 1'b1;
                end
            end

            if (DIAG_SYNTH_STREAM && diag_stream_write) begin
                diag_written_count_mem <= diag_written_count_mem + 1'b1;
                diag_column_mem <= (diag_column_mem >= FRAME_WIDTH - 2) ?
                                   11'd0 : diag_column_mem + 2'd2;
                if (diag_written_count_mem == IMAGE_WORDS - 1) begin
                    reader_busy <= 1'b0;
                    frame_read_done <= 1'b1;
                end
            end else if (!DIAG_SYNTH_STREAM && DIAG_RETURN_PATTERN &&
                         sdram_rd_valid) begin
                diag_column_mem <= (diag_column_mem >= FRAME_WIDTH - 2) ?
                                   11'd0 : diag_column_mem + 2'd2;
            end

            // Page replacement writes use the same SDRAM command port. Stop
            // issuing reads and hold the FIFO reset while display is disabled;
            // reader_idle rises only after all already-issued reads return.
            if (!controller_init_done) begin
                plan_state_mem <= 0;
                app_rd_en <= 1'b0;
                reload_pending_mem <= 1'b0;
                reader_busy <= 1'b0;
                burst_active_mem <= 1'b0;
                burst_issued_mem <= 0;
                burst_target_mem <= 0;
                burst_gap_count_mem <= 0;
                fifo_reset_count_mem <= 3'd4;
                // The vendor SDRAM interface has a fixed, short read latency.
                // If an issued-count bookkeeping mismatch leaves no response
                // activity for much longer than that latency, release the
                // drain handshake instead of blocking page replacement forever.
                if (!inflight_empty_mem && !sdram_rd_valid &&
                    drain_quiet_count_mem >= DRAIN_TIMEOUT_CYCLES - 1) begin
                    inflight_count_mem <= 0;
                    inflight_empty_mem <= 1'b1;
                end
            end
        end
    end

    rfifo_32_32_512 #(
        .DATA_WIDTH_W(32), .DATA_WIDTH_R(32),
        .ADDR_WIDTH_W(FIFO_COUNT_W), .ADDR_WIDTH_R(FIFO_COUNT_W),
        .AL_FULL_NUM(FIFO_DEPTH-FIFO_MARGIN), .AL_EMPTY_NUM(2),
        .SHOW_AHEAD_EN(1'b0), .OUTREG_EN("NOREG")
    ) u_read_fifo (
        .rst(fifo_reset), .clkw(mem_clk), .clkr(pix_clk),
        .we(fifo_write_enable), .di(fifo_write_data),
        .re(fifo_raw_read_en), .dout(fifo_raw_data), .valid(fifo_raw_valid),
        .full_flag(fifo_full), .empty_flag(fifo_empty),
        .afull(fifo_almost_full), .aempty(),
        .wrusedw(fifo_wrusedw), .rdusedw()
    );

    fifo_prefetch_2 #(.DATA_WIDTH(32)) u_prefetch (
        .clk(pix_clk), .rst(fifo_reset), .raw_empty(fifo_empty),
        .raw_valid(fifo_raw_valid), .raw_data(fifo_raw_data),
        .raw_read_en(fifo_raw_read_en), .consume(word_pop),
        .out_valid(prefetch_valid), .out_empty(), .out_data(prefetch_data)
    );

    wire [15:0] selected_rgb565 = pixel_half ?
                                  prefetch_data[31:16] : prefetch_data[15:0];
    assign pixel_rgb = {
        selected_rgb565[15:11], selected_rgb565[15:13],
        selected_rgb565[10:5], selected_rgb565[10:9],
        selected_rgb565[4:0], selected_rgb565[4:2]
    };
    assign pixel_valid = prefetch_valid && !frame_bad_pix;

    always @(posedge pix_clk or negedge pix_rst_n) begin
        if (!pix_rst_n) begin
            // The memory-domain error remains authoritative for controller faults.
        end else if (underflow) begin
            // underflow is exported separately; the Top may merge it as 8'h63.
        end
    end

endmodule
