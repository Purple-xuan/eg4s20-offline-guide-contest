`timescale 1ns/1ps

module sd_card_bmp #(
    parameter integer CLK_FREQ_HZ        = 100_000_000,
    parameter integer SD_READ_TIMEOUT_MS = 500,
    parameter integer READER_ACK_TIMEOUT_MS = 100,
    parameter integer MAX_RETRIES        = 1,
    parameter integer AUTO_PLAY_MS       = 10000,
    parameter integer AUTO_NARRATION_ONLY = 0,
    parameter integer MANUAL_NARRATION_ONLY = 0,
    parameter integer ENABLE_AUTO_BGM    = 0,
    parameter integer NARRATION_BOTH_MODES = 0,
    parameter integer CACHE_BANKS        = 2,
    parameter integer ENABLE_ROI         = 0,
    parameter integer ENABLE_GALLERY     = 0,
    parameter integer RESIDENT_MODE      = 0,
    parameter integer ENABLE_HOME_MENU   = 0,
    parameter integer ENABLE_NAV_TRANSITION = 0
)(
    input                       clk,
    input                       rst,
    input                       sdram_init_done,
    input                       reader_idle,
    input  [1:0]                reader_buf_idx,
    input                       reader_switch_deferred,
    input                       key_next,
    input                       key_auto,
    input                       key_next_event,
    input                       key_prev_event,
    input                       key_auto_event,
    input                       home_auto_run, home_auto_paused,home_silent_auto,
    input                       home_audio_mute, home_navigation_busy,
    input                       bad_page_notice,
    input                       home_navigation_audio_ready,home_navigation_cancel,home_navigation_keep_audio,
    input [1:0]                 hotspot_mode,
    input [2:0]                 hotspot_page,
    input [1:0]                 hotspot_region,
    input                       hotspot_replay,
    input                       hotspot_video_ready,
    input                       hotspot_target_pending,
    output reg                  hotspot_missing_audio,
    output wire                 hotspot_done,
    output                      home_auto_step,
    input                       gallery_active,
    input                       gallery_select_valid,
    input [2:0]                 gallery_select_page,
    input [7:0]                 thumbnail_ready_mask,
    output                      gallery_select_ready,
    output [7:0]                gallery_resource_mask,
    output [7:0]                failed_page_mask,
    output                      thumbnail_start, thumbnail_commit,
    output [2:0]                thumbnail_page,
    output                      thumbnail_pixel_valid,
    output [23:0]               thumbnail_pixel_rgb,
    input                       roi_active,
    input                       roi_zoom,
    input                       roi_request_valid,
    input [15:0]                roi_x, roi_y, roi_width, roi_height,
    input [3:0]                 roi_units,
    input [7:0]                 roi_grid_x,
    input [6:0]                 roi_grid_y,
    output                      roi_available,
    output                      roi_request_ready,
    output                      roi_busy,
    output [3:0]                roi_source_step,
    output reg                  roi_display_zoom,
    output reg [3:0]            roi_display_units,
    output reg [7:0]            roi_display_grid_x,
    output reg [6:0]            roi_display_grid_y,
    output reg                  instant_switch,
    input                       emergency_enter,
    input                       emergency_exit,
    output reg                  emergency_active,
    output reg [3:0]            state_code,
    input  [15:0]               bmp_width,
    input  [15:0]               bmp_height,
    output reg                  display_valid,
    output reg [3:0]            image_count,
    output reg [2:0]            current_image_index,
    output reg                  auto_play_en,
    output reg [7:0]            media_error_code,
    output reg [2:0]            fault_notice_state,
    output reg [1:0]            fault_notice_epoch,

    input                       write_finish_toggle,
    output reg                  write_abort_toggle,
    input                       write_abort_ack_toggle,
    output reg [1:0]            write_buf_idx,
    output reg [1:0]            disp_buf_idx,
    output reg                  manual_switch,
    output reg                  reverse_switch,

    output                      write_req,
    input                       write_req_ack,
    input                       write_ready,
    output                      write_v_flip,
    output                      write_en,
    output [31:0]               write_data,
    input [7:0]                 resident_ready_mask,
    input [7:0]                 resident_error_mask,
    output reg                  resident_request_valid,
    input                       resident_request_accepted,
    output reg [2:0]            resident_load_slot,
    output reg                  resident_load_flip,
    output                      resident_pixel_last,
    output reg                  resident_source_error,
    output                      SD_nCS,
    output                      SD_DCLK,
    output                      SD_MOSI,
     input                       SD_MISO,

     input                       audio_rd_clk,
     input                       audio_rst_n,
     input                       audio_sample_tick,
     output                      audio_sample_valid,
     output signed [23:0]        audio_left_data,
     output signed [23:0]        audio_right_data,
     output                      audio_active,
     output                      audio_done,
     output                      audio_playback_start,
     output                      audio_sample_consumed,
     output [4:0]                audio_page,
     output [31:0]               audio_underflow_count,
     output signed [15:0]        bgm_left_data, bgm_right_data
);

// The original seventh card resource (PIC7/AUD7, zero-based slot 6) is
// intentionally removed from the product.  Keep the original slot numbering
// for PIC8/AUD8 so existing media and subtitle indices remain compatible.
localparam [7:0] REMOVED_PAGE_MASK = 8'b1011_1111;

localparam CTRL_SCAN        = 3'd0;
localparam CTRL_WAIT_READER = 3'd1;
localparam CTRL_LOAD        = 3'd2;
localparam CTRL_SETTLE      = 3'd3;
localparam CTRL_DISPLAY     = 3'd4;
localparam CTRL_RECOVER     = 3'd5;
localparam CTRL_ERROR       = 3'd6;

wire key_next_press;
wire key_auto_press;
wire sd_sec_read;
wire [31:0] sd_sec_read_addr;
wire [7:0] sd_sec_read_data;
wire sd_sec_read_data_valid;
wire sd_sec_read_end;
wire sector_req;
wire [31:0] sector_lba;
wire sector_busy;
wire sector_valid;
wire [7:0] sector_byte;
wire [8:0] sector_byte_index;
wire sector_done;
wire [7:0] sector_error;
wire bmp_sector_req, bmp_sector_busy, bmp_sector_valid;
wire [31:0] bmp_sector_lba;
wire [7:0] bmp_sector_byte, bmp_sector_error;
wire [8:0] bmp_sector_byte_index;
wire bmp_sector_done;
wire wav_sector_req, wav_sector_busy, wav_sector_valid;
wire [31:0] wav_sector_lba;
wire [7:0] wav_sector_byte, wav_sector_error;
wire [8:0] wav_sector_byte_index;
wire wav_sector_done;
wire wav_pcm_continue, wav_stream_busy, wav_stream_done, wav_stream_error;
wire [7:0] wav_stream_error_code;
wire [1:0] wav_channel_count;
wire [31:0] wav_sample_rate;
wire [15:0] wav_block_align;
wire wav_pcm_valid;
wire [7:0] wav_pcm_byte;
wire [31:0] wav_pcm_offset;
wire signed [15:0] audio_left_pcm, audio_right_pcm;
wire audio_playback_complete;
reg [1:0] audio_complete_sync;
reg narration_wait, narration_stream_ended;
reg auto_play_d, auto_deadline;
reg [2:0] narration_page_ready;
wire bmp_data_wr_en;
wire [23:0] bmp_data;
wire bmp_metadata_done, bmp_metadata_valid, bmp_top_down;
wire [3:0] bmp_metadata_error;
wire [15:0] bmp_source_width, bmp_source_height;
wire bmp_pixel_continue;
wire scaled_pixel_valid;
wire [23:0] scaled_pixel_rgb;
wire scaled_pixel_eof;
wire resize_pipeline_error;
wire sd_init_done;
wire bmp_ready;
wire scan_done;
wire [7:0] scan_resource_valid;
wire [31:0] scan_cluster0, scan_cluster1, scan_cluster2, scan_cluster3;
wire [31:0] scan_cluster4, scan_cluster5, scan_cluster6, scan_cluster7;
wire [31:0] scan_size0, scan_size1, scan_size2, scan_size3;
wire [31:0] scan_size4, scan_size5, scan_size6, scan_size7;
  wire [7:0] scan_audio_valid, scan_fs_spc;
  wire [7:0] scan_hotspot_valid;
  wire [31:0] scan_audio_query_cluster, scan_audio_query_size;
  wire scan_emerg_bmp_valid, scan_emerg_wav_valid;
  wire [31:0] scan_emerg_bmp_cluster, scan_emerg_bmp_size;
  wire [31:0] scan_emerg_wav_cluster, scan_emerg_wav_size;
  wire scan_bgm_valid;
  wire [31:0] scan_bgm_cluster, scan_bgm_size;
  wire [31:0] scan_fs_fat_start, scan_fs_data_start, scan_fs_max_cluster;
wire load_done;
wire load_error;
wire scan_error;
wire [7:0] scan_error_code;
wire [2:0] bmp_error;
wire effective_load_error = load_error || resize_pipeline_error;
wire [2:0] effective_bmp_error = resize_pipeline_error ? 3'd1 : bmp_error;

reg scan_start_pulse;
reg load_start_pulse;
reg [31:0] load_cluster;
reg [31:0] load_file_size;
reg scan_kicked;
reg scan_result_armed;
reg scan_done_d;
reg [7:0] resource_mask;
// Scanner metadata remains stable until the next scan, which is only started
// in CTRL_SCAN with display disabled. Keep validity masks as the commit gate.
wire [31:0] img_cluster0=scan_cluster0, img_cluster1=scan_cluster1;
wire [31:0] img_cluster2=scan_cluster2, img_cluster3=scan_cluster3;
wire [31:0] img_cluster4=scan_cluster4, img_cluster5=scan_cluster5;
wire [31:0] img_cluster6=scan_cluster6, img_cluster7=scan_cluster7;
wire [31:0] img_size0=scan_size0, img_size1=scan_size1;
wire [31:0] img_size2=scan_size2, img_size3=scan_size3;
wire [31:0] img_size4=scan_size4, img_size5=scan_size5;
wire [31:0] img_size6=scan_size6, img_size7=scan_size7;
  reg [7:0] audio_resource_mask;
  reg emergency_bmp_valid, emergency_wav_valid;
  wire [31:0] emergency_bmp_cluster=scan_emerg_bmp_cluster, emergency_bmp_size=scan_emerg_bmp_size;
  wire [31:0] emergency_wav_cluster=scan_emerg_wav_cluster, emergency_wav_size=scan_emerg_wav_size;
  reg [2:0] saved_image_index;
  reg [31:0] saved_image_size_q;
  reg emergency_load_pending, emergency_restore_pending;
  reg emergency_request_pending, emergency_exit_pending;
  reg [2:0] audio_index;
  reg hotspot_stream;
  reg [2:0] hotspot_audio_index;
  wire [3:0] scan_audio_query_index =
      {hotspot_stream, hotspot_stream ? hotspot_audio_index : audio_index};
  reg [2:0] hotspot_play_page;
  reg [1:0] hotspot_play_region;
  reg hotspot_request_pending;
  reg [1:0] hotspot_mode_d;
  wire [2:0] hotspot_target_index=hotspot_page==2 ? {1'b0,hotspot_region} :
      hotspot_page==4 ? 3'd4+{2'b0,hotspot_region[0]} :
                        3'd6+{2'b0,hotspot_region[0]};
  reg [31:0] audio_stream_cluster, audio_stream_size;
  reg [1:0] audio_metadata_ready;
  reg audio_start_pulse, audio_stop_pulse, audio_restart_pending;
wire bgm_selected, bgm_start, bgm_stop;
wire bgm_stream_busy, bgm_stream_done, bgm_stream_error;
wire bgm_complete;
reg [1:0] bgm_complete_sync;
wire bgm_pcm_continue, bgm_pcm_valid;
wire [7:0] bgm_pcm_byte;
wire [1:0] bgm_channels;
wire bgm_sector_req, bgm_sector_busy, bgm_sector_valid, bgm_sector_done;
wire [31:0] bgm_sector_lba;
wire [8:0] bgm_sector_byte_index;
wire [7:0] bgm_sector_byte, bgm_sector_error;
wire audio_sector_req, audio_sector_busy, audio_sector_valid, audio_sector_done;
wire [31:0] audio_sector_lba;
wire [8:0] audio_sector_byte_index;
wire [7:0] audio_sector_byte, audio_sector_error;
wire audio_media_error = wav_stream_error || bgm_stream_error ||
    (wav_sector_error != 0) || (audio_sector_error != 0);
wire bgm_wanted;
wire stream_stop = audio_stop_pulse;
wire stream_start = audio_start_pulse && !stream_stop;
wire [31:0] stream_cluster = audio_stream_cluster;
wire [31:0] stream_size = audio_stream_size;
localparam WAIT_NARRATION = AUTO_NARRATION_ONLY || NARRATION_BOTH_MODES;
reg [2:0] load_index;
reg [1:0] pending_buf_idx;
reg [2:0] control_state;
reg [31:0] auto_cnt;
reg [3:0] bank_settle_count;
reg source_done_seen;
reg write_finish_seen;
reg [2:0] wrfin_tgl_sync;
reg [2:0] abort_ack_sync;
reg [1:0] retry_count;
reg retry_pending;
reg recover_keep_display;
reg [3:0] sd_reset_cnt;
reg recovery_scan_pending;
reg audio_error_d;
reg [31:0] recovery_retry_count;
reg prefetch_valid;
reg [2:0] prefetch_index;
reg [1:0] prefetch_buf_idx;
reg advance_pending;
reg advance_manual;
reg [3:0] next_selection;
reg [2:0] next_search_index;
reg [3:0] next_search_count;
reg [2:0] next_search_base;
reg [7:0] next_search_mask;
reg next_search_active;
reg [31:0] reader_wait_count;
reg reader_resync_active;
reg resident_request_started;
localparam integer RECOVERY_RETRY_CYCLES = CLK_FREQ_HZ / 4;
localparam integer STARTUP_NOTICE_CYCLES = CLK_FREQ_HZ * 5;
reg [31:0] startup_notice_count;

// Partition reset fanout across the SD-card subsystem.
(* keep = "true" *) reg rst_control;
(* keep = "true" *) reg rst_bmp;
(* keep = "true" *) reg rst_audio;
(* keep = "true" *) reg rst_arbiter;
(* keep = "true" *) reg rst_sd_core;

function [3:0] count_resources;
    input [7:0] valid;
    integer i;
    begin
        count_resources = 4'd0;
        for (i = 0; i < 8; i = i + 1)
            count_resources = count_resources + valid[i];
    end
endfunction

function [3:0] first_available;
    input [7:0] valid;
    integer i;
    begin
        first_available = 4'd0;
        for (i = 0; i < 8; i = i + 1)
            if (!first_available[3] && valid[i])
                first_available = {1'b1, i[2:0]};
    end
endfunction

function [31:0] cluster_lut;
    input [2:0] index;
    begin
        case (index)
            3'd0: cluster_lut = img_cluster0;
            3'd1: cluster_lut = img_cluster1;
            3'd2: cluster_lut = img_cluster2;
            3'd3: cluster_lut = img_cluster3;
            3'd4: cluster_lut = img_cluster4;
            3'd5: cluster_lut = img_cluster5;
            3'd6: cluster_lut = img_cluster6;
            default: cluster_lut = img_cluster7;
        endcase
    end
endfunction

function [31:0] size_lut;
    input [2:0] index;
    begin
        case (index)
            3'd0: size_lut = img_size0;
            3'd1: size_lut = img_size1;
            3'd2: size_lut = img_size2;
            3'd3: size_lut = img_size3;
            3'd4: size_lut = img_size4;
            3'd5: size_lut = img_size5;
            3'd6: size_lut = img_size6;
            default: size_lut = img_size7;
        endcase
    end
endfunction

function [3:0] scan_error_display;
    input [7:0] code;
    begin
        case (code)
            8'h10: scan_error_display = 4'hb;
            8'h20: scan_error_display = 4'hc;
            8'h21: scan_error_display = 4'hd;
            8'h22: scan_error_display = 4'he;
            8'h27: scan_error_display = 4'hf;
            default: scan_error_display = 4'ha;
        endcase
    end
endfunction

function [3:0] load_error_display;
    input [2:0] code;
    begin
        case (code)
            3'd1: load_error_display = 4'h5;
            3'd2: load_error_display = 4'h6;
            3'd3: load_error_display = 4'h7;
            3'd4: load_error_display = 4'h8;
            default: load_error_display = 4'h0;
        endcase
    end
endfunction

// User-facing page numbers are compacted after removing the former page 7.
// Internal slot 7 still addresses PIC8/AUD8, but it is displayed as page 7.
function [3:0] page_display_number;
    input [2:0] index;
    begin
        case (index)
            3'd0: page_display_number = 4'd1;
            3'd1: page_display_number = 4'd2;
            3'd2: page_display_number = 4'd3;
            3'd3: page_display_number = 4'd4;
            3'd4: page_display_number = 4'd5;
            3'd5: page_display_number = 4'd6;
            3'd7: page_display_number = 4'd7;
            default: page_display_number = 4'd0;
        endcase
    end
endfunction

wire write_finish_pulse = wrfin_tgl_sync[2] ^ wrfin_tgl_sync[1];
wire scan_done_pulse = scan_done && !scan_done_d;
wire sd_core_rst = rst_sd_core || (sd_reset_cnt != 0);
assign bgm_wanted = ENABLE_AUTO_BGM &&
    (ENABLE_HOME_MENU ? (home_auto_run || home_auto_paused || home_silent_auto) : auto_play_en) &&
    display_valid &&
    scan_bgm_valid && !scan_error && !sd_core_rst && !recovery_scan_pending &&
    !emergency_active && !emergency_request_pending && !emergency_load_pending;
wire [31:0] auto_play_cycles = (CLK_FREQ_HZ / 1000) * AUTO_PLAY_MS;
wire [31:0] auto_interval_cycles = home_silent_auto ?
    (CLK_FREQ_HZ / 1000) * 3000 : auto_play_cycles;
wire [31:0] reader_ack_timeout_cycles =
    (CLK_FREQ_HZ / 1000) * READER_ACK_TIMEOUT_MS;
reg auto_tick;
wire [7:0] filtered_resource_valid = scan_resource_valid & REMOVED_PAGE_MASK;
wire [7:0] filtered_audio_valid = scan_audio_valid & REMOVED_PAGE_MASK;
wire [3:0] first_selection = first_available(filtered_resource_valid);
function [2:0] resident_physical;
    input [2:0] logical_page;
    begin resident_physical=logical_page==7 ? 3'd6 : logical_page; end
endfunction
function [2:0] resident_logical;
    input [2:0] physical_slot;
    begin resident_logical=physical_slot==6 ? 3'd7 : physical_slot; end
endfunction
wire [6:0] resident_files={resource_mask[7],resource_mask[5:0]};
wire [6:0] resident_missing=resident_files &
    ~(resident_ready_mask[6:0] | resident_error_mask[6:0]);
wire [3:0] resident_next_missing=first_available({1'b0,resident_missing});
// Home navigation owns page keys. Consuming them here as well can advance the
// media during a wipe while the home controller still waits for its target.
wire next_page_event = key_next_press || (!ENABLE_HOME_MENU && key_next_event);
wire auto_toggle_event = key_auto_press || key_auto_event;
reg advance_reverse;
reg [3:0] prev_selection;
reg [2:0] prev_search_index;
reg [3:0] prev_search_count;
reg prev_search_active;
wire manual_page_event = next_page_event || (!ENABLE_HOME_MENU && key_prev_event);
wire roi_pause;
wire gallery_pause = ENABLE_GALLERY && gallery_active;
assign home_auto_step = ENABLE_HOME_MENU && auto_tick && home_auto_run && !home_navigation_busy;
assign hotspot_done = hotspot_stream && narration_wait &&
    hotspot_play_page==hotspot_page && hotspot_play_region==hotspot_region &&
    hotspot_video_ready && narration_stream_ended && audio_complete_sync[1];
reg home_busy_d,home_complete_d,home_early_audio_d,home_keep_audio_d;
wire navigation_keep_audio=ENABLE_NAV_TRANSITION && home_navigation_keep_audio;
always @(posedge clk or posedge rst_control) begin
    if(rst_control) begin home_busy_d<=0;home_complete_d<=0;home_early_audio_d<=0;home_keep_audio_d<=0;end
    else begin
        home_busy_d<=home_navigation_busy;home_complete_d<=audio_complete_sync[1];
        home_early_audio_d<=ENABLE_NAV_TRANSITION && home_navigation_busy && home_navigation_audio_ready;
        home_keep_audio_d<=navigation_keep_audio;
    end
end
reg direct_pending;
reg [2:0] direct_page;
reg direct_reverse;
wire [2:0] navigation_base=RESIDENT_MODE && direct_pending ? direct_page : current_image_index;
wire navigation_cancel = ENABLE_NAV_TRANSITION && home_navigation_cancel;
wire navigation_audio_open = !home_navigation_busy ||
    (ENABLE_NAV_TRANSITION && home_navigation_audio_ready && !hotspot_target_pending);
wire direct_request = ENABLE_GALLERY && gallery_select_valid && gallery_select_ready && !navigation_cancel;
wire advance_request = !ENABLE_HOME_MENU && !roi_pause && !gallery_pause && !direct_pending &&
    (manual_page_event || (auto_play_en && auto_tick));
wire normal_page_narration = ENABLE_HOME_MENU ? !hotspot_target_pending : NARRATION_BOTH_MODES ?
    (auto_play_en || advance_manual || manual_page_event || direct_pending) : MANUAL_NARRATION_ONLY ?
    (!auto_play_en && (advance_manual || manual_page_event || direct_pending)) :
    (!AUTO_NARRATION_ONLY ||
     (auto_play_en && !advance_manual && !manual_page_event && !direct_pending));
wire select_reverse = direct_pending ? direct_reverse :
    (advance_pending ? advance_reverse : key_prev_event);
wire [3:0] page_selection = direct_pending ? {1'b1,direct_page} :
    (select_reverse ? prev_selection : next_selection);
reg [3:0] cached_valid;
reg [2:0] cached_image [0:3];
reg [3:0] cached_source_step [0:3];
reg roi_full_valid;
reg [1:0] roi_full_bank;
reg [3:0] roi_full_step;
reg roi_loading;
reg [15:0] crop_x_q, crop_y_q, crop_width_q, crop_height_q;
reg [3:0] crop_units_q;
reg [7:0] crop_grid_x_q;
reg [6:0] crop_grid_y_q;
wire roi_selecting = ENABLE_ROI && roi_active;
assign roi_pause = ENABLE_ROI && (roi_active || roi_display_zoom || roi_loading);
assign roi_source_step = RESIDENT_MODE ? 4'd6 :
    (roi_full_valid ? roi_full_step : cached_source_step[disp_buf_idx]);
assign roi_available = ENABLE_ROI && display_valid && !emergency_active &&
    !emergency_request_pending && !emergency_exit_pending && !advance_pending &&
    !advance_request && reader_buf_idx == disp_buf_idx && !reader_switch_deferred &&
    (RESIDENT_MODE || media_error_code == 0);
assign roi_request_ready = roi_available &&
    (RESIDENT_MODE || control_state == CTRL_DISPLAY) &&
    roi_selecting && roi_zoom && !roi_loading;
assign roi_busy = RESIDENT_MODE ? (roi_selecting && reader_switch_deferred) :
    ENABLE_ROI && (roi_loading ||
    (roi_selecting && (control_state != CTRL_DISPLAY || reader_buf_idx != disp_buf_idx || reader_switch_deferred)) ||
    (roi_display_zoom && (!roi_active || !roi_zoom)));
integer cache_reset;
reg gallery_page_valid_q;
reg gallery_resident_ready_q;
reg [2:0] gallery_page_q;
reg bmp_ready_q;
always @(posedge clk or posedge rst_control) begin
    if (rst_control) begin
        gallery_page_valid_q <= 0;
        gallery_resident_ready_q <= 0;
        gallery_page_q <= 0;
        bmp_ready_q <= 0;
    end else begin
        gallery_page_valid_q <= resource_mask[gallery_select_page];
        // Decode resource and resident readiness for the same held page.
        // The page equality below rejects this snapshot when a new intent
        // arrives, keeping the indexed READY mux off the request enable path.
        gallery_resident_ready_q <= resident_ready_mask[resident_physical(gallery_select_page)];
        gallery_page_q <= gallery_select_page;
        // Ready is only consumed to issue a new scan/load or leave recovery.
        bmp_ready_q <= bmp_ready && !scan_start_pulse && !load_start_pulse;
    end
end
assign gallery_resource_mask = resource_mask;
assign failed_page_mask = filtered_resource_valid & ~resource_mask;
assign gallery_select_ready = ENABLE_GALLERY && (ENABLE_HOME_MENU || gallery_pause) && display_valid &&
    (RESIDENT_MODE || control_state==CTRL_DISPLAY) &&
    !roi_pause && !advance_pending && !direct_pending &&
    !emergency_active && !emergency_request_pending && !emergency_exit_pending &&
    !reader_switch_deferred && reader_buf_idx==disp_buf_idx &&
    gallery_page_valid_q && gallery_page_q==gallery_select_page &&
    (RESIDENT_MODE ? gallery_resident_ready_q :
                     media_error_code==0);
wire [3:0] missing_thumbnail = first_available(resource_mask & ~thumbnail_ready_mask);
assign thumbnail_start = !RESIDENT_MODE && ENABLE_GALLERY && load_start_pulse && !roi_loading &&
                         !emergency_load_pending && !emergency_restore_pending;
assign thumbnail_page = load_index;
assign thumbnail_pixel_valid = !RESIDENT_MODE && ENABLE_GALLERY && control_state==CTRL_LOAD &&
    !roi_loading && !emergency_load_pending && !emergency_restore_pending &&
    scaled_pixel_valid && write_ready;
assign thumbnail_pixel_rgb = scaled_pixel_rgb;
assign thumbnail_commit = !RESIDENT_MODE && ENABLE_GALLERY && control_state==CTRL_LOAD &&
    !roi_loading && !emergency_load_pending && !emergency_restore_pending &&
    !effective_load_error && !scan_error && (source_done_seen || load_done) &&
    (write_finish_seen || write_finish_pulse);

function [2:0] find_cached;
    input [2:0] image;
    input [3:0] valid;
    input [11:0] images;
    integer b;
    begin
        find_cached = 0;
        for (b = 0; b < CACHE_BANKS; b = b + 1)
            if (valid[b] && images[b*3 +: 3] == image)
                find_cached = {1'b1, b[1:0]};
    end
endfunction

function [1:0] replacement_bank;
    input [1:0] displayed;
    input [1:0] reading;
    input [3:0] valid;
    input [11:0] images;
    input [2:0] next_image, prev_image;
    input protected_valid;
    input [1:0] protected_bank;
    integer b;
    begin
        replacement_bank = 0;
        // Protect both banks still owned by an in-progress wipe. Prefer
        // evicting a distant page, then prefer an unused bank.
        for (b = 0; b < CACHE_BANKS; b = b + 1)
            if (b != displayed && b != reading && (!protected_valid || b != protected_bank))
                replacement_bank = b[1:0];
        for (b = 0; b < CACHE_BANKS; b = b + 1)
            if (b != displayed && b != reading && (!protected_valid || b != protected_bank) &&
                images[b*3 +: 3] != next_image && images[b*3 +: 3] != prev_image)
                replacement_bank = b[1:0];
        for (b = 0; b < CACHE_BANKS; b = b + 1)
            if (b != displayed && b != reading && (!protected_valid || b != protected_bank) && !valid[b])
                replacement_bank = b[1:0];
    end
endfunction

wire [11:0] cache_images = {cached_image[3], cached_image[2], cached_image[1], cached_image[0]};
wire [2:0] requested_cache = find_cached(page_selection[2:0], cached_valid, cache_images);
wire [2:0] next_cache = find_cached(next_selection[2:0], cached_valid, cache_images);
wire [2:0] prev_cache = find_cached(prev_selection[2:0], cached_valid, cache_images);
wire [1:0] available_bank = CACHE_BANKS > 2 ?
    replacement_bank(disp_buf_idx, reader_buf_idx, cached_valid, cache_images,
                     next_selection[2:0], prev_selection[2:0], ENABLE_ROI && roi_full_valid, roi_full_bank) :
                          ((disp_buf_idx == 0) ? 2'd1 : 2'd0);
wire cache_hit = CACHE_BANKS > 2 ? requested_cache[2] :
                 (prefetch_valid && prefetch_index == page_selection[2:0]);
wire [1:0] cached_bank = CACHE_BANKS > 2 ? requested_cache[1:0] : prefetch_buf_idx;
wire prefetch_next_missing = next_selection[3] &&
    next_selection[2:0] != current_image_index && !next_cache[2];
wire prefetch_prev_missing = prev_selection[3] &&
    prev_selection[2:0] != current_image_index && !prev_cache[2];
wire normal_background_valid = CACHE_BANKS > 2 ?
    (prefetch_next_missing || prefetch_prev_missing) :
    (!prefetch_valid && next_selection[3] && next_selection[2:0] != current_image_index);
wire [3:0] background_candidate = gallery_pause ? missing_thumbnail :
    {normal_background_valid, (CACHE_BANKS > 2 && !prefetch_next_missing) ?
                             prev_selection[2:0] : next_selection[2:0]};
reg [3:0] background_selection_q;
reg background_gallery_q;
reg [2:0] background_state_q;
always @(posedge clk or posedge rst_control) begin
    if(rst_control) begin
        background_selection_q<=0;background_gallery_q<=0;background_state_q<=CTRL_SCAN;
    end else begin
        background_selection_q<=background_candidate;
        background_gallery_q<=gallery_pause;
        background_state_q<=control_state;
    end
end
wire [3:0] background_selection = ENABLE_GALLERY ? background_selection_q : background_candidate;
// After a completed load or gallery ownership change, allow cache/ready
// publication to reach the registered selection before scheduling another read.
wire background_stable = !ENABLE_GALLERY ||
    (background_state_q==CTRL_DISPLAY && background_gallery_q==gallery_pause);

assign write_en = scaled_pixel_valid;
assign write_data = {scaled_pixel_rgb, 8'b0};
assign resident_pixel_last = scaled_pixel_eof;
assign audio_left_data = {{8{audio_left_pcm[15]}}, audio_left_pcm};
assign audio_right_data = {{8{audio_right_pcm[15]}}, audio_right_pcm};

always @(posedge clk or posedge rst) begin
    if (rst) begin
        rst_control <= 1'b1;
        rst_bmp <= 1'b1;
        rst_audio <= 1'b1;
        rst_arbiter <= 1'b1;
        rst_sd_core <= 1'b1;
    end else begin
        rst_control <= 1'b0;
        rst_bmp <= 1'b0;
        rst_audio <= 1'b0;
        rst_arbiter <= 1'b0;
        rst_sd_core <= 1'b0;
    end
end

key_press_debounce #(
    .CLK_FREQ_HZ(CLK_FREQ_HZ), .DEBOUNCE_MS(20)
) u_key_next (
    .clk(clk), .rst(rst_control), .button_in(key_next),
    .press_pulse(key_next_press), .button_stable_out()
);

key_press_debounce #(
    .CLK_FREQ_HZ(CLK_FREQ_HZ), .DEBOUNCE_MS(20)
) u_key_auto (
    .clk(clk), .rst(rst_control), .button_in(key_auto),
    .press_pulse(key_auto_press), .button_stable_out()
);

// Completion is a held level, so the video-to-SD clock crossing cannot lose
// the one-cycle playback_done pulse. EOF alone still leaves PCM in the FIFO.
always @(posedge clk or posedge rst_control) begin
    if (rst_control) begin
        audio_complete_sync <= 0;
        bgm_complete_sync <= 0;
        narration_wait <= 0;
        narration_stream_ended <= 0;
        narration_page_ready <= 0;
    end else begin
        audio_complete_sync <= {audio_complete_sync[0], audio_playback_complete};
        bgm_complete_sync <= {bgm_complete_sync[0], bgm_complete};
        narration_page_ready <= {narration_page_ready[1:0],
            reader_buf_idx == disp_buf_idx && !reader_switch_deferred};
        if (audio_stop_pulse || (!ENABLE_HOME_MENU && !auto_play_en)) begin
            narration_wait <= 0;
            narration_stream_ended <= 0;
        end else if (audio_start_pulse && !emergency_active) begin
            narration_wait <= 1;
            narration_stream_ended <= 0;
        end else begin
            if (wav_stream_done) narration_stream_ended <= 1;
            if (narration_stream_ended && audio_complete_sync[1])
                narration_wait <= 0;
        end
    end
end

// Scanner metadata is stable for the whole session. Select the audio address
// outside the page FSM so restarting the current page adds no wide mux there.
always @(posedge clk or posedge rst_control) begin
    if (rst_control) begin
        audio_stream_cluster <= 0;
        audio_stream_size <= 0;
        audio_metadata_ready <= 0;
    end else begin
        audio_stream_cluster <= emergency_active ? emergency_wav_cluster :
            scan_audio_query_cluster;
        audio_stream_size <= emergency_active ? emergency_wav_size :
            scan_audio_query_size;
        audio_metadata_ready <= audio_stop_pulse ? 2'b00 : {audio_metadata_ready[0],1'b1};
    end
end

always @(posedge clk or posedge rst_control) begin
    if (rst_control) begin
        scan_start_pulse <= 1'b0;
        load_start_pulse <= 1'b0;
        resident_request_valid <= 1'b0;
        resident_load_slot <= 3'd0;
        resident_load_flip <= 1'b0;
        resident_source_error <= 1'b0;
        resident_request_started <= 1'b0;
        load_cluster <= 32'd0;
        load_file_size <= 32'd0;
        scan_kicked <= 1'b0;
        scan_result_armed <= 1'b0;
        scan_done_d <= 1'b0;
        resource_mask <= 8'd0;
        audio_resource_mask <= 8'd0;
        emergency_bmp_valid <= 1'b0;
        emergency_wav_valid <= 1'b0;
        saved_image_index <= 3'd0;
        saved_image_size_q <= 32'd0;
        emergency_load_pending <= 1'b0;
        emergency_restore_pending <= 1'b0;
        emergency_request_pending <= 1'b0;
        emergency_exit_pending <= 1'b0;
        emergency_active <= 1'b0;
        audio_index <= 3'd0;
        hotspot_stream <= 0;
        hotspot_audio_index <= 0;
        hotspot_play_page <= 0;
        hotspot_play_region <= 0;
        hotspot_request_pending <= 0;
        hotspot_mode_d <= 0;
        hotspot_missing_audio <= 0;
        audio_start_pulse <= 1'b0;
        audio_stop_pulse <= 1'b0;

        audio_restart_pending <= 1'b0;
        load_index <= 3'd0;
        pending_buf_idx <= 2'd0;
        write_buf_idx <= 2'd0;
        disp_buf_idx <= 2'd0;
        manual_switch <= 1'b0;
        reverse_switch <= 1'b0;
        advance_reverse <= 1'b0;
        direct_pending <= 0;
        direct_page <= 0;
        direct_reverse <= 1'b0;
        prev_selection <= 0;
        prev_search_index <= 0;
        prev_search_count <= 0;
        prev_search_active <= 0;
        cached_valid <= 0;
        for (cache_reset = 0; cache_reset < 4; cache_reset = cache_reset + 1) begin
            cached_image[cache_reset] <= 0;
            cached_source_step[cache_reset] <= 8;
        end
        roi_full_valid <= 0;
        roi_full_bank <= 0;
        roi_full_step <= 8;
        roi_loading <= 0;
        roi_display_zoom <= 0;
        roi_display_units <= 5;
        roi_display_grid_x <= 0;
        roi_display_grid_y <= 0;
        crop_grid_x_q <= 0;
        crop_grid_y_q <= 0;
        crop_units_q <= 5;
        instant_switch <= 0;
        crop_x_q <= 0;
        crop_y_q <= 0;
        crop_width_q <= 0;
        crop_height_q <= 0;
        advance_manual <= 1'b0;
        current_image_index <= 3'd0;
        image_count <= 4'd0;
        display_valid <= 1'b0;
        auto_play_en <= 1'b0;
        media_error_code <= 8'h00;
        auto_cnt <= 32'd0;
        auto_tick <= 1'b0;
        auto_play_d <= 0;
        auto_deadline <= 0;
        bank_settle_count <= 4'd0;
        source_done_seen <= 1'b0;
        write_finish_seen <= 1'b0;
        wrfin_tgl_sync <= 3'd0;
        abort_ack_sync <= 3'd0;
        write_abort_toggle <= 1'b0;
        retry_count <= 2'd0;
        retry_pending <= 1'b0;
        recover_keep_display <= 1'b0;
        sd_reset_cnt <= 4'd0;
        recovery_scan_pending <= 1'b0;
        audio_error_d <= 1'b0;
        recovery_retry_count <= 32'd0;
        fault_notice_state <= 3'd0;
        fault_notice_epoch <= 2'd0;
        startup_notice_count <= 32'd0;
        prefetch_valid <= 1'b0;
        prefetch_index <= 3'd0;
        prefetch_buf_idx <= 2'd0;
        advance_pending <= 1'b0;
        next_selection <= 4'd0;
        next_search_index <= 3'd0;
        next_search_count <= 4'd0;
        next_search_base <= 3'd0;
        next_search_mask <= 8'd0;
        next_search_active <= 1'b0;
        reader_wait_count <= 32'd0;
        reader_resync_active <= 1'b0;
        control_state <= CTRL_SCAN;
        state_code <= 4'd1;
    end else begin
        // Compare one count early, then register the deadline. This preserves
        // the page interval without putting a 32-bit compare on loader control.
        auto_tick <= auto_play_en && (!ENABLE_HOME_MENU || !home_navigation_busy) &&
                     display_valid && !roi_pause && !gallery_pause && !advance_request &&
                     !auto_toggle_event && (!WAIT_NARRATION || home_silent_auto ||
                     (!narration_wait && !audio_restart_pending && !audio_start_pulse)) && auto_cnt >=
                     (auto_interval_cycles > 1 ? auto_interval_cycles - 2 : 0);
        auto_deadline <= auto_cnt >= (auto_interval_cycles > 1 ? auto_interval_cycles - 2 : 0);
        auto_play_d <= auto_play_en;
        wrfin_tgl_sync <= {wrfin_tgl_sync[1:0], write_finish_toggle};
        abort_ack_sync <= {abort_ack_sync[1:0], write_abort_ack_toggle};
        scan_done_d <= scan_done;
        // scan_done holds the last result across SD-only resets. Accept a
        // result only after this request has actually cleared that old level.
        if (scan_kicked && !scan_done)
            scan_result_armed <= 1'b1;
        audio_error_d <= audio_media_error;
        if (recovery_retry_count != 0)
            recovery_retry_count <= recovery_retry_count - 1'b1;
        if (!display_valid && startup_notice_count < STARTUP_NOTICE_CYCLES)
            startup_notice_count <= startup_notice_count + 1'b1;
        if (!display_valid && startup_notice_count == STARTUP_NOTICE_CYCLES - 1)
            fault_notice_state <= 3'd1;
        if (display_valid && fault_notice_state == 3'd1)
            fault_notice_state <= 3'd6;
        scan_start_pulse <= 1'b0;
        load_start_pulse <= 1'b0;
        if (resident_request_accepted) resident_request_valid<=0;
        audio_start_pulse <= 1'b0;
        audio_stop_pulse <= 1'b0;

        if(direct_request && gallery_select_page!=current_image_index) begin
            direct_pending<=1;
            direct_page<=gallery_select_page;
            // The UI request can be separated from its key pulse by display
            // acknowledgement. Classify direction from the resolved target.
            direct_reverse<=ENABLE_HOME_MENU ?
                (gallery_select_page==prev_selection[2:0] && prev_selection[3]) :
                (gallery_select_page < current_image_index);
        end

        if (roi_selecting && !roi_full_valid && !roi_display_zoom) begin
            roi_full_valid <= 1;
            roi_full_bank <= disp_buf_idx;
            roi_full_step <= cached_source_step[disp_buf_idx];
        end else if (!roi_selecting && !roi_display_zoom && !roi_loading &&
                     reader_buf_idx == disp_buf_idx) begin
            roi_full_valid <= 0;
        end
        if (bmp_metadata_done && bmp_metadata_valid && !roi_loading) begin
            case (bmp_source_width)
                640: cached_source_step[pending_buf_idx] <= 4;
                960: cached_source_step[pending_buf_idx] <= 6;
                1920: cached_source_step[pending_buf_idx] <= 12;
                default: cached_source_step[pending_buf_idx] <= 8;
            endcase
        end

        if (!display_valid || scan_error)
            advance_manual <= 1'b0;

        // Queue emergency transitions until the normal loader reaches a safe
        // display state. Never reinterpret an in-flight normal prefetch as an
        // emergency image.
        if (emergency_enter && !emergency_active && emergency_bmp_valid && display_valid) begin
            direct_pending <= 0;
            saved_image_index <= current_image_index;
            // Capture the restore size at the transition boundary so the
            // later emergency-exit load has no wide LUT path from the saved
            // page index into the loader register.
            saved_image_size_q <= size_lut(current_image_index);
            emergency_request_pending <= 1'b1;
            emergency_exit_pending <= 1'b0;
        end
        if (emergency_exit) begin
            emergency_request_pending <= 1'b0;
            if (emergency_active || emergency_load_pending)
                emergency_exit_pending <= 1'b1;
        end

        if (next_search_base != navigation_base ||
            next_search_mask != resource_mask) begin
            next_search_base <= navigation_base;
            next_search_mask <= resource_mask;
            next_search_index <= navigation_base + 1'b1;
            next_search_count <= 4'd0;
            next_selection <= 4'd0;
            next_search_active <= resource_mask != 0;
            prev_search_index <= navigation_base - 1'b1;
            prev_search_count <= 0;
            prev_selection <= 0;
            prev_search_active <= resource_mask != 0;
        end else if (next_search_active) begin
            if (resource_mask[next_search_index]) begin
                next_selection <= {1'b1, next_search_index};
                next_search_active <= 1'b0;
            end else if (next_search_count == 4'd7) begin
                next_selection <= 4'd0;
                next_search_active <= 1'b0;
            end else begin
                next_search_index <= next_search_index + 1'b1;
                next_search_count <= next_search_count + 1'b1;
            end
        end

        if (next_search_base == navigation_base &&
            next_search_mask == resource_mask && prev_search_active) begin
            if (resource_mask[prev_search_index]) begin
                prev_selection <= {1'b1, prev_search_index};
                prev_search_active <= 0;
            end else if (prev_search_count == 7) begin
                prev_selection <= 0;
                prev_search_active <= 0;
            end else begin
                prev_search_index <= prev_search_index - 1'b1;
                prev_search_count <= prev_search_count + 1'b1;
            end
        end

        // Start ordinary narration after bank acknowledgement and the existing
        // audio fade have settled, so the first words are played at full gain.
        if (audio_restart_pending && (&audio_metadata_ready) && !audio_stop_pulse &&
            !sd_core_rst && sd_init_done && !recovery_scan_pending &&
            (!ENABLE_HOME_MENU || hotspot_mode!=2 || hotspot_stream) &&
            (!ENABLE_HOME_MENU || !hotspot_target_pending || hotspot_stream) &&
            (!hotspot_stream || (hotspot_mode==2 && hotspot_video_ready &&
                 hotspot_play_page==hotspot_page && hotspot_play_region==hotspot_region)) &&
            (!ENABLE_HOME_MENU || emergency_active || (navigation_audio_open && !home_audio_mute)) &&
            (!(AUTO_NARRATION_ONLY || MANUAL_NARRATION_ONLY || NARRATION_BOTH_MODES) || emergency_active ||
            ((&narration_page_ready) && reader_buf_idx == disp_buf_idx && !reader_switch_deferred))) begin
            if (emergency_active || (NARRATION_BOTH_MODES ?
                (!auto_toggle_event && !manual_page_event && !direct_request) :
                (MANUAL_NARRATION_ONLY ?
                    (!auto_play_en && !auto_toggle_event && !manual_page_event && !direct_request) :
                    (!AUTO_NARRATION_ONLY ||
                     (auto_play_en && !auto_toggle_event && !manual_page_event && !direct_request)))))
                audio_start_pulse <= 1'b1;
            audio_restart_pending <= 1'b0;
        end

        if (!ENABLE_HOME_MENU && WAIT_NARRATION && auto_play_en && !auto_play_d &&
            display_valid && !emergency_active && !emergency_load_pending &&
            !emergency_restore_pending && !emergency_request_pending &&
            !audio_restart_pending && !manual_page_event && !direct_request) begin
            audio_index <= current_image_index;
            audio_stop_pulse <= 1;
            audio_restart_pending <= audio_resource_mask[current_image_index];
        end

        if (sd_reset_cnt != 0)
            sd_reset_cnt <= sd_reset_cnt - 1'b1;

        // A removed card can leave resident SDRAM pages usable while the WAV
        // stream is permanently stalled. Restart only the SD transport and
        // rescan in the background; the displayed page remains resident.
        if (RESIDENT_MODE && display_valid && !emergency_active &&
            control_state == CTRL_DISPLAY && audio_media_error && !audio_error_d) begin
            audio_stop_pulse <= 1'b1;
            audio_restart_pending <= 1'b0;
            recovery_scan_pending <= 1'b1;
            fault_notice_state <= 3'd2;
            recovery_retry_count <= 32'd0;
            sd_reset_cnt <= 4'd8;
            scan_kicked <= 1'b0;
            scan_result_armed <= 1'b0;
            control_state <= CTRL_SCAN;
        end else if (RESIDENT_MODE && recovery_scan_pending &&
                     !sd_init_done && recovery_retry_count == 0) begin
            // No card detect pin is available on this board. A slow retry
            // gives a newly inserted card another complete SPI init attempt.
            sd_reset_cnt <= 4'd8;
            scan_kicked <= 1'b0;
            scan_result_armed <= 1'b0;
            recovery_retry_count <= RECOVERY_RETRY_CYCLES;
        end

        // A commit below may queue the replacement after cancelling the old
        // stream, including a cached page accepted on this same clock.
        if ((MANUAL_NARRATION_ONLY || NARRATION_BOTH_MODES) && !emergency_active && !emergency_load_pending &&
            ((manual_page_event && !roi_pause && !gallery_pause) || direct_request)) begin
            audio_stop_pulse <= 1;
            audio_start_pulse <= 0;
            audio_restart_pending <= 0;
        end

        if (control_state != CTRL_WAIT_READER) begin
            reader_wait_count <= 32'd0;
            reader_resync_active <= 1'b0;
        end

        if (RESIDENT_MODE) begin
            if (scan_error && !recovery_scan_pending) begin
                fault_notice_state <= 3'd1;
                display_valid<=0;
                resource_mask<=0;
                image_count<=0;
                media_error_code<=scan_error_code;
                state_code<=scan_error_display(scan_error_code);
                control_state<=CTRL_ERROR;
            end else case (control_state)
                CTRL_SCAN: begin
                    if (!recovery_scan_pending)
                        display_valid<=0;
                    auto_cnt<=0;
                    // The TF rescan only refreshes metadata. Resident pages
                    // remain available for navigation while the card is out.
                    if (recovery_scan_pending && display_valid && !emergency_active) begin
                        if (auto_toggle_event)
                            auto_play_en<=~auto_play_en;
                        if (!navigation_cancel &&
                            (advance_request || advance_pending || direct_pending)) begin
                            if (reader_switch_deferred) begin
                                advance_pending<=1'b1;
                                if (!advance_pending) begin
                                    advance_reverse<=key_prev_event;
                                    advance_manual<=manual_page_event;
                                end
                            end else if (page_selection[3] &&
                                page_selection[2:0]!=current_image_index &&
                                resident_ready_mask[resident_physical(page_selection[2:0])]) begin
                                if (scan_done_pulse && scan_result_armed)
                                    advance_pending<=1'b1;
                                else begin
                                    current_image_index<=page_selection[2:0];
                                    audio_index<=page_selection[2:0];
                                    audio_stop_pulse<=1'b1;
                                    audio_restart_pending<=audio_resource_mask[page_selection[2:0]] &&
                                        normal_page_narration;
                                    manual_switch<=advance_manual || manual_page_event;
                                    reverse_switch<=select_reverse;
                                    instant_switch<=0;
                                    advance_pending<=0;
                                    direct_pending<=0;
                                    state_code<=page_display_number(page_selection[2:0]);
                                end
                            end else if (page_selection[3] &&
                                !resident_ready_mask[resident_physical(page_selection[2:0])]) begin
                                advance_pending<=1'b1;
                            end
                        end
                    end
                    if (!scan_kicked && !sd_core_rst && sd_init_done && sdram_init_done && bmp_ready_q &&
                        (!recovery_scan_pending || recovery_retry_count == 0)) begin
                        scan_start_pulse<=1;
                        scan_kicked<=1;
                        scan_result_armed<=0;
                        state_code<=2;
                    end
                    if (scan_done_pulse && scan_result_armed && recovery_scan_pending) begin
                        if (!scan_error && filtered_resource_valid != 0) begin
                            // Keep all resident image banks and the current
                            // page; replace only filesystem/audio metadata.
                            audio_resource_mask<=filtered_audio_valid;
                            // The removed card forced the old stream to stop.
                            // Queue the displayed page again using the newly
                            // scanned mask so metadata can settle before the
                            // WAV reader is restarted.
                            audio_index<=current_image_index;
                            audio_restart_pending<=filtered_audio_valid[current_image_index] &&
                                normal_page_narration;
                            fault_notice_state <= filtered_audio_valid[current_image_index] ?
                                ((normal_page_narration && (!ENABLE_HOME_MENU || !home_audio_mute)) ?
                                    3'd3 : 3'd7) : 3'd4;
                            emergency_bmp_valid<=scan_emerg_bmp_valid;
                            emergency_wav_valid<=scan_emerg_wav_valid;
                            recovery_scan_pending<=1'b0;
                            recovery_retry_count<=32'd0;
                            media_error_code<=8'h00;
                            control_state<=CTRL_DISPLAY;
                        end else begin
                            scan_kicked<=1'b0;
                            scan_result_armed<=1'b0;
                            recovery_retry_count<=RECOVERY_RETRY_CYCLES;
                            sd_reset_cnt<=4'd8;
                        end
                    end else if (scan_done_pulse && scan_result_armed && !scan_error) begin
                        resource_mask<=filtered_resource_valid;
                        audio_resource_mask<=filtered_audio_valid;
                        image_count<=count_resources(filtered_resource_valid);
                        emergency_bmp_valid<=scan_emerg_bmp_valid;
                        emergency_wav_valid<=scan_emerg_wav_valid;
                        if (first_selection[3]) begin
                            load_index<=first_selection[2:0];
                            resident_load_slot<=resident_physical(first_selection[2:0]);
                            state_code<=3;
                            control_state<=CTRL_WAIT_READER;
                        end else begin
                            state_code<=4'hb;
                            control_state<=CTRL_ERROR;
                        end
                    end
                end
                CTRL_WAIT_READER: begin
                    if (display_valid && auto_toggle_event) begin
                        auto_play_en<=~auto_play_en;
                        auto_cnt<=0;
                    end
                    if (bmp_ready_q) begin
                        if (resident_ready_mask[resident_load_slot] ||
                            resident_error_mask[resident_load_slot]) begin
                            control_state<=CTRL_DISPLAY;
                        end else begin
                            load_cluster<=resident_load_slot==7 ? emergency_bmp_cluster :
                                                                   cluster_lut(load_index);
                            load_file_size<=resident_load_slot==7 ? emergency_bmp_size :
                                                                     size_lut(load_index);
                            load_start_pulse<=1;
                            resident_request_valid<=0;
                            resident_request_started<=0;
                            resident_source_error<=0;
                            control_state<=CTRL_LOAD;
                            state_code<=4;
                        end
                    end
                end
                CTRL_LOAD: begin
                    if (display_valid && auto_play_en && !roi_pause && !gallery_pause &&
                        (!WAIT_NARRATION || !auto_deadline)) auto_cnt<=auto_cnt+1'b1;
                    if (display_valid && auto_toggle_event) begin
                        auto_play_en<=~auto_play_en;
                        auto_cnt<=0;
                    end
                    if (advance_request || direct_pending) advance_pending<=1;
                    if (bmp_metadata_done && bmp_metadata_valid && !resident_request_started) begin
                        resident_load_flip<=!bmp_top_down;
                        resident_request_valid<=1;
                        resident_request_started<=1;
                    end
                    if (effective_load_error) resident_source_error<=1;
                    if (resident_error_mask[resident_load_slot] ||
                        (effective_load_error && !resident_request_started &&
                         !(bmp_metadata_done && bmp_metadata_valid))) begin
                        resident_request_valid<=0;
                        resident_request_started<=0;
                        if (resident_load_slot==7) begin
                            media_error_code<=8'h47;
                            emergency_request_pending<=0;
                            // Header rejection can happen before an upload
                            // descriptor exists, so the memory error mask may
                            // stay clear. Do not repeatedly reopen that file.
                            emergency_bmp_valid<=0;
                        end else begin
                            if (!ENABLE_HOME_MENU || !display_valid) begin
                                fault_notice_state<=3'd5;
                                fault_notice_epoch<=fault_notice_epoch+1'b1;
                            end
                            resource_mask[load_index]<=0;
                            image_count<=image_count-1'b1;
                            if (!ENABLE_HOME_MENU || !display_valid ||
                                (advance_pending && page_selection[3] &&
                                 page_selection[2:0]==load_index))
                                media_error_code<=8'h41;
                            else media_error_code<=0;
                        end
                        state_code<=display_valid ? page_display_number(current_image_index) :
                            (resident_error_mask[resident_load_slot] ? 4'hc : 4'ha);
                        control_state<=CTRL_DISPLAY;
                    end else if (resident_ready_mask[resident_load_slot]) begin
                        resident_request_valid<=0;
                        resident_request_started<=0;
                        resident_source_error<=0;
                        media_error_code<=0;
                        if (!display_valid) begin
                            display_valid<=1;
                            current_image_index<=load_index;
                            audio_index<=load_index;
                            audio_restart_pending<=audio_resource_mask[load_index] &&
                                (!MANUAL_NARRATION_ONLY && (!AUTO_NARRATION_ONLY || auto_play_en));
                            state_code<=page_display_number(load_index);
                        end else if (resident_load_slot!=7 && advance_pending && !navigation_cancel &&
                                     page_selection[3] && page_selection[2:0]==load_index &&
                                     !emergency_active) begin
                            current_image_index<=load_index;
                            audio_index<=load_index;
                            audio_stop_pulse<=1;
                            audio_restart_pending<=audio_resource_mask[load_index] &&
                                normal_page_narration;
                            manual_switch<=advance_manual || manual_page_event;
                            reverse_switch<=select_reverse;
                            instant_switch<=0;
                            advance_pending<=0;
                            direct_pending<=0;
                            state_code<=page_display_number(load_index);
                        end
                        control_state<=CTRL_DISPLAY;
                    end
                    if (emergency_request_pending && resident_ready_mask[7] &&
                        display_valid && !emergency_active) begin
                        emergency_active<=1;
                        emergency_request_pending<=0;
                        direct_pending<=0;
                        advance_pending<=0;
                        roi_display_zoom<=0;
                        instant_switch<=1;
                        audio_stop_pulse<=1;
                        audio_restart_pending<=emergency_wav_valid;
                        state_code<=4'he;
                    end
                end
                CTRL_DISPLAY: begin
                    if (auto_toggle_event && display_valid) begin
                        auto_play_en<=~auto_play_en;
                        auto_cnt<=0;
                    end
                    if (emergency_exit_pending && emergency_active) begin
                        emergency_active<=0;
                        emergency_exit_pending<=0;
                        current_image_index<=saved_image_index;
                        audio_index<=saved_image_index;
                        audio_stop_pulse<=1;
                        audio_restart_pending<=audio_resource_mask[saved_image_index] &&
                            !MANUAL_NARRATION_ONLY && (!AUTO_NARRATION_ONLY || auto_play_en);
                        instant_switch<=1;
                        state_code<=page_display_number(saved_image_index);
                        auto_cnt<=0;
                    end else if (emergency_request_pending && !emergency_active &&
                                 resident_ready_mask[7]) begin
                        emergency_active<=1;
                        emergency_request_pending<=0;
                        direct_pending<=0;
                        advance_pending<=0;
                        roi_display_zoom<=0;
                        instant_switch<=1;
                        audio_stop_pulse<=1;
                        audio_restart_pending<=emergency_wav_valid;
                        state_code<=4'he;
                        auto_cnt<=0;
                    end else if (emergency_active) auto_cnt<=0;
                    else if (roi_display_zoom && (!roi_active || !roi_zoom)) begin
                        roi_display_zoom<=0;
                        instant_switch<=1;
                    end else if (roi_request_valid && roi_request_ready) begin
                        roi_display_zoom<=1;
                        roi_display_units<=roi_units;
                        roi_display_grid_x<=roi_grid_x;
                        roi_display_grid_y<=roi_grid_y;
                        instant_switch<=1;
                    end else if (!navigation_cancel && (advance_request || advance_pending || direct_pending)) begin
                        auto_cnt<=0;
                        if (reader_switch_deferred) begin
                            advance_pending<=1;
                            if (!advance_pending) begin
                                advance_reverse<=key_prev_event;
                                advance_manual<=manual_page_event;
                            end
                        end else if (page_selection[3] &&
                                     page_selection[2:0]!=current_image_index) begin
                            if (resident_ready_mask[resident_physical(page_selection[2:0])]) begin
                                current_image_index<=page_selection[2:0];
                                audio_index<=page_selection[2:0];
                                audio_stop_pulse<=1;
                                audio_restart_pending<=audio_resource_mask[page_selection[2:0]] &&
                                    normal_page_narration;
                                manual_switch<=advance_manual || manual_page_event;
                                reverse_switch<=select_reverse;
                                instant_switch<=0;
                                advance_pending<=0;
                                direct_pending<=0;
                                state_code<=page_display_number(page_selection[2:0]);
                            end else if (!resident_error_mask[resident_physical(page_selection[2:0])]) begin
                                load_index<=page_selection[2:0];
                                resident_load_slot<=resident_physical(page_selection[2:0]);
                                advance_pending<=1;
                                advance_manual<=advance_manual || manual_page_event;
                                advance_reverse<=select_reverse;
                                control_state<=CTRL_WAIT_READER;
                            end
                        end
                    end else begin
                        if (auto_play_en && !roi_pause && !gallery_pause &&
                            (!WAIT_NARRATION || !auto_deadline)) auto_cnt<=auto_cnt+1'b1;
                        else if (!auto_play_en || roi_pause || gallery_pause) auto_cnt<=0;
                        if (!display_valid && !resident_next_missing[3]) begin
                            control_state<=CTRL_ERROR;
                            if (media_error_code!=8'h41)
                                state_code<=4'h7;
                        end else if (display_valid && emergency_bmp_valid &&
                                     !resident_ready_mask[7] &&
                                     !resident_error_mask[7]) begin
                            resident_load_slot<=7;
                            control_state<=CTRL_WAIT_READER;
                        end else if (resident_next_missing[3]) begin
                            resident_load_slot<=resident_next_missing[2:0];
                            load_index<=resident_logical(resident_next_missing[2:0]);
                            control_state<=CTRL_WAIT_READER;
                        end
                    end
                end
                default: begin
                    control_state<=CTRL_SCAN;
                    display_valid<=0;
                end
            endcase
            // Background TF loading never holds up a READY page or ROI.
            if (display_valid && !emergency_active &&
                (control_state==CTRL_WAIT_READER || control_state==CTRL_LOAD)) begin
                if (roi_request_valid && roi_request_ready) begin
                    roi_display_zoom<=1;
                    roi_display_units<=roi_units;
                    roi_display_grid_x<=roi_grid_x;
                    roi_display_grid_y<=roi_grid_y;
                    instant_switch<=1;
                end else if (advance_request || advance_pending || direct_pending) begin
                    if (reader_switch_deferred) begin
                        advance_pending<=1;
                        if (!advance_pending) begin
                            advance_reverse<=key_prev_event;
                            advance_manual<=manual_page_event;
                        end
                    end else if (page_selection[3] &&
                        page_selection[2:0]!=current_image_index &&
                        resident_ready_mask[resident_physical(page_selection[2:0])]) begin
                        current_image_index<=page_selection[2:0];
                        audio_index<=page_selection[2:0];
                        audio_stop_pulse<=1;
                        audio_restart_pending<=audio_resource_mask[page_selection[2:0]] &&
                            normal_page_narration;
                        manual_switch<=advance_manual || manual_page_event;
                        reverse_switch<=select_reverse;
                        instant_switch<=0;
                        advance_pending<=0;
                        direct_pending<=0;
                        state_code<=page_display_number(page_selection[2:0]);
                        auto_cnt<=0;
                    end else advance_pending<=1;
                end
            end
            if (display_valid && emergency_exit_pending && emergency_active &&
                (control_state==CTRL_WAIT_READER || control_state==CTRL_LOAD)) begin
                emergency_active<=0;
                emergency_exit_pending<=0;
                current_image_index<=saved_image_index;
                audio_index<=saved_image_index;
                audio_stop_pulse<=1;
                audio_restart_pending<=audio_resource_mask[saved_image_index] &&
                    !MANUAL_NARRATION_ONLY && (!AUTO_NARRATION_ONLY || auto_play_en);
                instant_switch<=1;
                state_code<=page_display_number(saved_image_index);
            end else if (display_valid && emergency_request_pending &&
                         !emergency_active && resident_ready_mask[7] &&
                         (control_state==CTRL_WAIT_READER || control_state==CTRL_LOAD)) begin
                emergency_active<=1;
                emergency_request_pending<=0;
                direct_pending<=0;
                advance_pending<=0;
                roi_display_zoom<=0;
                instant_switch<=1;
                audio_stop_pulse<=1;
                audio_restart_pending<=emergency_wav_valid;
                state_code<=4'he;
            end
            // Merge presses during a wipe relative to the latest queued
            // target. The existing eight-cycle directory search settles well
            // before the next debounced key event; no combinational page scan.
            if(reader_switch_deferred && manual_page_event && display_valid &&
               !roi_pause && !gallery_pause && !emergency_active &&
               !emergency_request_pending && !emergency_enter &&
               (key_prev_event ? prev_selection[3] : next_selection[3])) begin
                direct_page<=key_prev_event ? prev_selection[2:0] : next_selection[2:0];
                direct_pending<=1;
                advance_pending<=1;
                advance_manual<=1;
                advance_reverse<=key_prev_event;
            end else if(!reader_switch_deferred && direct_pending &&
                        direct_page==current_image_index) begin
                direct_pending<=0;advance_pending<=0;
            end
        end else if (scan_error) begin
            fault_notice_state <= 3'd1;
            direct_pending <= 0;
            cached_valid <= 0;
            display_valid <= 1'b0;
            image_count <= 4'd0;
            resource_mask <= 8'd0;
            prefetch_valid <= 1'b0;
            advance_pending <= 1'b0;
            media_error_code <= scan_error_code;
            state_code <= scan_error_display(scan_error_code);
            control_state <= CTRL_ERROR;
        end else if (effective_load_error && control_state == CTRL_LOAD) begin
            fault_notice_state <= 3'd5;
            fault_notice_epoch <= fault_notice_epoch+1'b1;
            // A background load only modifies the inactive bank. Preserve the
            // active bank while aborting the partial write and waiting for the
            // card to return. Initial-load failures still keep output disabled.
            recover_keep_display <= display_valid;
            if (!display_valid)
                display_valid <= 1'b0;
            source_done_seen <= 1'b0;
            write_finish_seen <= 1'b0;
            prefetch_valid <= 1'b0;
            write_abort_toggle <= ~write_abort_toggle;
            media_error_code <= {5'b01000, effective_bmp_error};
            state_code <= load_error_display(effective_bmp_error);
            control_state <= CTRL_RECOVER;
            if (retry_count < MAX_RETRIES) begin
                retry_count <= retry_count + 1'b1;
                retry_pending <= 1'b1;
            end else begin
                retry_pending <= 1'b0;
            end
            if (effective_bmp_error == 3'd2)
                sd_reset_cnt <= 4'd8;
        end else begin
            case (control_state)
                CTRL_SCAN: begin
                    display_valid <= 1'b0;
                    auto_cnt <= 32'd0;
                    if (!scan_kicked && sd_init_done && sdram_init_done && bmp_ready_q) begin
                        scan_start_pulse <= 1'b1;
                        scan_kicked <= 1'b1;
                        state_code <= 4'd2;
                    end

                    if (scan_done_pulse && first_selection[3]) begin
                        media_error_code <= 8'h00;
                        resource_mask <= filtered_resource_valid;
                        image_count <= count_resources(filtered_resource_valid);
                        audio_resource_mask <= filtered_audio_valid;
                        emergency_bmp_valid <= scan_emerg_bmp_valid;
                        emergency_wav_valid <= scan_emerg_wav_valid;
                        load_index <= first_selection[2:0];
                        pending_buf_idx <= 2'd0;
                        write_buf_idx <= 2'd0;
                        retry_count <= 2'd0;
                        prefetch_valid <= 1'b0;
                        advance_pending <= 1'b0;
                        state_code <= 4'd3;
                        control_state <= CTRL_WAIT_READER;
                    end
                end

                CTRL_WAIT_READER: begin
                    if (!display_valid) begin
                        auto_cnt <= 32'd0;
                    end else if (auto_toggle_event) begin
                        auto_play_en <= ~auto_play_en;
                        auto_cnt <= 32'd0;
                    end else if (advance_request) begin
                        advance_pending <= 1'b1;
                        if (!advance_pending) begin
                            advance_reverse <= key_prev_event;
                            advance_manual <= manual_page_event;
                        end
                        auto_cnt <= 32'd0;
                    end else if (auto_play_en && (!WAIT_NARRATION || !auto_deadline)) begin
                        auto_cnt <= auto_cnt + 1'b1;
                    end

                    // If a bank acknowledgement is lost, briefly disable the
                    // reader so its existing drain watchdog can return it to a
                    // known idle state. Re-enable the current bank and retry;
                    // otherwise every later page and emergency load would wait
                    // here forever.
                    if (reader_resync_active) begin
                        reader_wait_count <= 32'd0;
                        if (!display_valid && reader_idle) begin
                            display_valid <= 1'b1;
                            reader_resync_active <= 1'b0;
                        end
                    end else if (((!display_valid && reader_idle) ||
                                  (display_valid &&
                                   reader_buf_idx == disp_buf_idx)) &&
                                 bmp_ready_q) begin
                        load_cluster <= emergency_load_pending ? emergency_bmp_cluster :
                                        (emergency_restore_pending ? cluster_lut(saved_image_index) : cluster_lut(load_index));
                        load_file_size <= emergency_load_pending ? emergency_bmp_size :
                                          (emergency_restore_pending ? saved_image_size_q : size_lut(load_index));
                        load_start_pulse <= 1'b1;
                        cached_valid[pending_buf_idx] <= 1'b0;
                        source_done_seen <= 1'b0;
                        write_finish_seen <= 1'b0;
                        reader_wait_count <= 32'd0;
                        state_code <= 4'd4;
                        control_state <= CTRL_LOAD;
                    end else if (display_valid && bmp_ready_q &&
                                 reader_buf_idx != disp_buf_idx) begin
                        if (reader_switch_deferred) begin
                            reader_wait_count <= 32'd0;
                        end else if (reader_wait_count >=
                            reader_ack_timeout_cycles - 1'b1) begin
                            display_valid <= 1'b0;
                            reader_wait_count <= 32'd0;
                            reader_resync_active <= 1'b1;
                        end else begin
                            reader_wait_count <= reader_wait_count + 1'b1;
                        end
                    end else begin
                        reader_wait_count <= 32'd0;
                    end
                end

                CTRL_LOAD: begin
                    if (display_valid) begin
                        if (auto_toggle_event) begin
                            auto_play_en <= ~auto_play_en;
                            auto_cnt <= 32'd0;
                        end else if (advance_request) begin
                            advance_pending <= 1'b1;
                            if (!advance_pending) begin
                                advance_reverse <= key_prev_event;
                                advance_manual <= manual_page_event;
                            end
                            auto_cnt <= 32'd0;
                        end else if (auto_play_en && (!WAIT_NARRATION || !auto_deadline)) begin
                            auto_cnt <= auto_cnt + 1'b1;
                        end
                    end

                    if (load_done)
                        source_done_seen <= 1'b1;
                    if (write_finish_pulse)
                        write_finish_seen <= 1'b1;

                    if ((source_done_seen || load_done) &&
                        (write_finish_seen || write_finish_pulse)) begin
                        media_error_code <= 8'h00;
                        source_done_seen <= 1'b0;
                        write_finish_seen <= 1'b0;
                        retry_count <= 2'd0;
                        recover_keep_display <= 1'b0;
                        if (roi_loading) begin
                            // A crop is never advertised as a full-page cache hit.
                            roi_loading <= 0;
                            if (roi_selecting && roi_zoom && !emergency_request_pending) begin
                                disp_buf_idx <= pending_buf_idx;
                                instant_switch <= 1;
                                manual_switch <= 0;
                                reverse_switch <= 0;
                                roi_display_zoom <= 1;
                                roi_display_units <= crop_units_q;
                                roi_display_grid_x <= crop_grid_x_q;
                                roi_display_grid_y <= crop_grid_y_q;
                                bank_settle_count <= 0;
                                control_state <= CTRL_SETTLE;
                            end else control_state <= CTRL_DISPLAY;
                        end else begin
                        if (!emergency_load_pending && !emergency_restore_pending) begin
                            cached_valid[pending_buf_idx] <= 1'b1;
                            cached_image[pending_buf_idx] <= load_index;
                        end
                        if (emergency_load_pending || emergency_restore_pending ||
                            !display_valid || ((advance_pending || advance_request) &&
                            page_selection[3] && load_index == page_selection[2:0])) begin
                            disp_buf_idx <= pending_buf_idx;
                            instant_switch <= 0;
                            roi_display_zoom <= 0;
                            manual_switch <= display_valid &&
                                !emergency_load_pending && !emergency_restore_pending &&
                                (advance_manual || manual_page_event);
                            reverse_switch <= display_valid &&
                                !emergency_load_pending && !emergency_restore_pending && select_reverse;
                            advance_manual <= 1'b0;
                            current_image_index <= emergency_load_pending ? 3'd0 :
                                                   (emergency_restore_pending ? saved_image_index : load_index);
                            audio_index <= emergency_load_pending ? 3'd0 :
                                           (emergency_restore_pending ? saved_image_index : load_index);
                            audio_stop_pulse <= 1'b1;
                            audio_restart_pending <= emergency_load_pending ? emergency_wav_valid :
                                (emergency_restore_pending ?
                                    (audio_resource_mask[saved_image_index] && !MANUAL_NARRATION_ONLY &&
                                     (!AUTO_NARRATION_ONLY || auto_play_en)) :
                                    (audio_resource_mask[load_index] && normal_page_narration));
                            prefetch_valid <= 1'b0;
                            advance_pending <= 1'b0;
                            direct_pending <= 0;
                            bank_settle_count <= 4'd0;
                            auto_cnt <= 32'd0;
                            state_code <= page_display_number(load_index);
                            emergency_active <= emergency_load_pending;
                            emergency_load_pending <= 1'b0;
                            emergency_restore_pending <= 1'b0;
                            control_state <= CTRL_SETTLE;
                        end else begin
                            prefetch_valid <= 1'b1;
                            prefetch_index <= load_index;
                            prefetch_buf_idx <= pending_buf_idx;
                            state_code <= page_display_number(current_image_index);
                            control_state <= CTRL_DISPLAY;
                        end
                        end
                    end
                end

                CTRL_SETTLE: begin
                    if (bank_settle_count == 4'd8) begin
                        display_valid <= 1'b1;
                        auto_cnt <= 32'd0;
                        control_state <= CTRL_DISPLAY;
                    end else begin
                        bank_settle_count <= bank_settle_count + 1'b1;
                    end
                end

                CTRL_DISPLAY: begin
                    if (emergency_exit_pending && emergency_active) begin
                        emergency_restore_pending <= 1'b1;
                        emergency_load_pending <= 1'b0;
                        emergency_exit_pending <= 1'b0;
                        load_index <= saved_image_index;
                        pending_buf_idx <= available_bank;
                        write_buf_idx <= available_bank;
                        state_code <= 4'he;
                        control_state <= CTRL_WAIT_READER;
                    end else if (emergency_request_pending && !emergency_active) begin
                        emergency_load_pending <= 1'b1;
                        emergency_restore_pending <= 1'b0;
                        emergency_request_pending <= 1'b0;
                        pending_buf_idx <= available_bank;
                        write_buf_idx <= available_bank;
                        state_code <= 4'he;
                        control_state <= CTRL_WAIT_READER;
                    end else if (emergency_active) begin
                        auto_cnt <= 32'd0;
                    end else if (ENABLE_ROI && roi_display_zoom &&
                                 (!roi_active || !roi_zoom)) begin
                        if (reader_buf_idx == disp_buf_idx && !reader_switch_deferred) begin
                            disp_buf_idx <= roi_full_bank;
                            instant_switch <= 1;
                            manual_switch <= 0;
                            reverse_switch <= 0;
                            roi_display_zoom <= 0;
                            bank_settle_count <= 0;
                            auto_cnt <= 0;
                            control_state <= CTRL_SETTLE;
                        end
                    end else if (roi_request_valid && roi_request_ready) begin
                        load_index <= current_image_index;
                        pending_buf_idx <= available_bank;
                        write_buf_idx <= available_bank;
                        crop_x_q <= roi_x;
                        crop_y_q <= roi_y;
                        crop_width_q <= roi_width;
                        crop_height_q <= roi_height;
                        crop_units_q <= roi_units;
                        crop_grid_x_q <= roi_grid_x;
                        crop_grid_y_q <= roi_grid_y;
                        roi_loading <= 1;
                        retry_count <= 0;
                        state_code <= 4'd3;
                        control_state <= CTRL_WAIT_READER;
                    end else if (auto_toggle_event) begin
                        auto_play_en <= ~auto_play_en;
                        auto_cnt <= 32'd0;
                    end else if (advance_request || advance_pending || direct_pending) begin
                        auto_cnt <= 32'd0;
                        if (reader_switch_deferred) begin
                            if (!advance_pending) begin
                                advance_pending <= 1'b1;
                                advance_reverse <= key_prev_event;
                                advance_manual <= manual_page_event;
                            end
                        end else if (page_selection[3] &&
                            page_selection[2:0] != current_image_index) begin
                            if (cache_hit && reader_buf_idx == disp_buf_idx) begin
                                disp_buf_idx <= cached_bank;
                                instant_switch <= 0;
                                manual_switch <= advance_manual || manual_page_event;
                                reverse_switch <= select_reverse;
                                advance_manual <= 1'b0;
                                current_image_index <= page_selection[2:0];
                                audio_index <= page_selection[2:0];
                                audio_stop_pulse <= 1'b1;
                                audio_restart_pending <=
                                    audio_resource_mask[page_selection[2:0]] && normal_page_narration;
                                prefetch_valid <= 1'b0;
                                advance_pending <= 1'b0;
                                direct_pending <= 0;
                                bank_settle_count <= 4'd0;
                                state_code <= page_display_number(page_selection[2:0]);
                                control_state <= CTRL_SETTLE;
                            end else begin
                                load_index <= page_selection[2:0];
                                pending_buf_idx <= available_bank;
                                write_buf_idx <= available_bank;
                                prefetch_valid <= 1'b0;
                                advance_pending <= 1'b1;
                                advance_manual <= advance_manual || manual_page_event;
                                advance_reverse <= select_reverse;
                                retry_count <= 2'd0;
                                state_code <= 4'd3;
                                control_state <= CTRL_WAIT_READER;
                            end
                        end
                    end else if (auto_play_en) begin
                        if (!WAIT_NARRATION || !auto_deadline)
                            auto_cnt <= auto_cnt + 1'b1;
                    end else begin
                        auto_cnt <= 32'd0;
                    end

                    if (!direct_request && !direct_pending && !advance_request && !advance_pending && !roi_pause &&
                        !emergency_active && !emergency_request_pending && !emergency_exit_pending &&
                        !reader_switch_deferred && reader_buf_idx==disp_buf_idx &&
                        background_stable && background_selection[3]) begin
                        load_index <= background_selection[2:0];
                        pending_buf_idx <= available_bank;
                        write_buf_idx <= available_bank;
                        retry_count <= 0;
                        state_code <= 4'd3;
                        control_state <= CTRL_WAIT_READER;
                    end
                end

                CTRL_RECOVER: begin
                    display_valid <= recover_keep_display;
                    if (sd_init_done && sd_reset_cnt == 0 && bmp_ready_q &&
                        abort_ack_sync[2] == write_abort_toggle) begin
                        if (retry_pending) begin
                            retry_pending <= 1'b0;
                            state_code <= 4'd3;
                            control_state <= CTRL_WAIT_READER;
                        end else if (recover_keep_display) begin
                            // The active bank is intact. Keep it visible and
                            // stop automatic retries until the user selects a
                            // page again.
                            auto_play_en <= 1'b0;
                            auto_cnt <= 32'd0;
                            prefetch_valid <= 1'b0;
                            advance_pending <= 1'b0;
                            direct_pending <= 0;
                            state_code <= page_display_number(current_image_index);
                            advance_manual <= 1'b0;
                            roi_loading <= 0;
                            control_state <= CTRL_DISPLAY;
                        end else begin
                            control_state <= CTRL_ERROR;
                        end
                    end
                end

                default: begin
                    display_valid <= 1'b0;
                    auto_cnt <= 32'd0;
                end
            endcase
        end
        if (roi_pause || gallery_pause) auto_cnt <= 0;
        // Accept mode changes during the brief bank-settle state as well.
        // A concurrent page commit must never swallow a stop command.
        if ((AUTO_NARRATION_ONLY || MANUAL_NARRATION_ONLY || NARRATION_BOTH_MODES) && auto_toggle_event && display_valid &&
            !emergency_active && (control_state == CTRL_WAIT_READER ||
            control_state == CTRL_LOAD || control_state == CTRL_SETTLE ||
            control_state == CTRL_DISPLAY)) begin
            auto_play_en <= ~auto_play_en;
            auto_cnt <= 0;
            auto_tick <= 0;
            if ((AUTO_NARRATION_ONLY && auto_play_en) ||
                (MANUAL_NARRATION_ONLY && !auto_play_en)) begin
                audio_stop_pulse <= 1;
                audio_start_pulse <= 0;
                audio_restart_pending <= 0;
            end
        end
        if (AUTO_NARRATION_ONLY && !emergency_active && !emergency_load_pending &&
            ((auto_play_d && !auto_play_en) || !display_valid || scan_error ||
             (manual_page_event && !roi_pause && !gallery_pause) || direct_request)) begin
            audio_stop_pulse <= 1;
            audio_start_pulse <= 0;
            audio_restart_pending <= 0;
        end
        if (MANUAL_NARRATION_ONLY && !emergency_active && !emergency_load_pending &&
            ((auto_play_en && !auto_play_d) || !display_valid || scan_error)) begin
            audio_stop_pulse <= 1;
            audio_start_pulse <= 0;
            audio_restart_pending <= 0;
        end
        if (ENABLE_HOME_MENU) begin
            hotspot_mode_d<=hotspot_mode;
            if(hotspot_mode!=2 && hotspot_mode_d==2) begin
                hotspot_stream<=0;hotspot_request_pending<=0;
                hotspot_missing_audio<=0;
                if(hotspot_stream && !navigation_keep_audio) begin
                    audio_stop_pulse<=1;audio_start_pulse<=0;audio_restart_pending<=0;
                end
            end else if(hotspot_mode==2 && (hotspot_mode_d!=2 || hotspot_replay) &&
                        !home_navigation_busy && !emergency_active && !emergency_enter) begin
                hotspot_play_page<=hotspot_page;
                hotspot_play_region<=hotspot_region;
                hotspot_audio_index<=hotspot_target_index;
                hotspot_missing_audio<=!scan_hotspot_valid[hotspot_target_index];
                if(scan_hotspot_valid[hotspot_target_index]) begin
                    hotspot_stream<=1;
                    hotspot_request_pending<=1;
                    audio_stop_pulse<=1;
                    audio_start_pulse<=0;
                    audio_restart_pending<=0;
                end
            end
            if(hotspot_request_pending && hotspot_mode==2 && hotspot_video_ready &&
               hotspot_play_page==hotspot_page && hotspot_play_region==hotspot_region) begin
                hotspot_request_pending<=0;
                audio_restart_pending<=1;
            end
            if(home_navigation_busy || home_audio_mute || !display_valid ||
               emergency_enter || scan_error) begin
                hotspot_request_pending<=0;
                hotspot_stream<=0;
                hotspot_missing_audio<=0;
            end
            if(emergency_enter) begin direct_pending<=0;advance_pending<=0;end
            auto_play_en<=home_auto_run && !emergency_active && !emergency_request_pending;
            if(home_navigation_busy || !home_auto_run || hotspot_mode!=0) begin auto_cnt<=0;auto_tick<=0;end
            // Hierarchy navigation keeps outgoing audio until darkening starts.
            // Ordinary page changes retain their original stop at intent.
            // Preserve the replacement restart queued by the actual commit.
            if(!emergency_active && !emergency_load_pending && !emergency_request_pending) begin
                if((home_navigation_busy && !home_busy_d && !navigation_keep_audio) ||
                   (home_keep_audio_d && !navigation_keep_audio)) begin
                    audio_stop_pulse<=1;audio_start_pulse<=0;audio_restart_pending<=0;
                end
                if((home_audio_mute && !navigation_keep_audio) || !display_valid) begin
                    audio_stop_pulse<=1;audio_start_pulse<=0;audio_restart_pending<=0;
                end else if(home_busy_d && !home_navigation_busy && hotspot_mode==0 &&
                            !hotspot_target_pending &&
                            !home_early_audio_d &&
                            !audio_restart_pending && !audio_start_pulse) begin
                    // Also covers an emergency restoring the same media ID.
                    audio_index<=current_image_index;
                    audio_restart_pending<=audio_resource_mask[current_image_index];
                end else if(!home_navigation_busy && current_image_index==0 &&
                            audio_complete_sync[1] && !home_complete_d) begin
                    // AUD1 loops only after the last PCM sample has drained.
                    audio_index<=0;audio_restart_pending<=audio_resource_mask[0];
                end
            end
            if(navigation_cancel) begin
                direct_pending<=0;advance_pending<=0;
                hotspot_request_pending<=0;hotspot_stream<=0;
                audio_stop_pulse<=1;audio_start_pulse<=0;audio_restart_pending<=0;
            end
            if(hotspot_mode==1 && hotspot_mode_d==0) begin
                audio_stop_pulse<=1;audio_start_pulse<=0;audio_restart_pending<=0;
            end
        end
        if (ENABLE_HOME_MENU && bad_page_notice && display_valid && !emergency_active) begin
            fault_notice_state<=3'd5;
            fault_notice_epoch<=fault_notice_epoch+1'b1;
        end
    end
end

fat32_bmp_reader #(
    .CLK_FREQ_HZ(CLK_FREQ_HZ),
    .WRITE_TIMEOUT_MS(SD_READ_TIMEOUT_MS),
    .ENABLE_PIXEL_BACKPRESSURE(1),
    .ENABLE_DYNAMIC_HEADER(1),
    .USE_RESOLUTION_WHITELIST(1)
) u_fat32_bmp_reader (
    .clk(clk), .rst(rst_bmp), .sd_init_done(sd_init_done), .ready(bmp_ready),
    .scan_start(scan_start_pulse), .scan_done(scan_done),
    .scan_error(scan_error), .scan_error_code(scan_error_code),
    .resource_valid(scan_resource_valid),
    .resource0_cluster(scan_cluster0), .resource1_cluster(scan_cluster1),
    .resource2_cluster(scan_cluster2), .resource3_cluster(scan_cluster3),
    .resource4_cluster(scan_cluster4), .resource5_cluster(scan_cluster5),
    .resource6_cluster(scan_cluster6), .resource7_cluster(scan_cluster7),
    .resource0_size(scan_size0), .resource1_size(scan_size1),
    .resource2_size(scan_size2), .resource3_size(scan_size3),
    .resource4_size(scan_size4), .resource5_size(scan_size5),
    .resource6_size(scan_size6), .resource7_size(scan_size7),
     .audio_valid(scan_audio_valid),
     .audio_query_index(scan_audio_query_index),
     .audio_query_cluster(scan_audio_query_cluster),
     .audio_query_size(scan_audio_query_size),
     .hotspot_audio_valid(scan_hotspot_valid),
     .emergency_bmp_valid(scan_emerg_bmp_valid),
     .emergency_bmp_cluster(scan_emerg_bmp_cluster),
     .emergency_bmp_size(scan_emerg_bmp_size),
     .emergency_wav_valid(scan_emerg_wav_valid),
     .emergency_wav_cluster(scan_emerg_wav_cluster),
     .emergency_wav_size(scan_emerg_wav_size),
     .bgm_valid(scan_bgm_valid), .bgm_cluster(scan_bgm_cluster), .bgm_size(scan_bgm_size),
     .fs_sectors_per_cluster(scan_fs_spc),
     .fs_fat_start_lba(scan_fs_fat_start),
     .fs_data_start_lba(scan_fs_data_start),
     .fs_max_cluster(scan_fs_max_cluster),
    .scan_boot_debug(),
    .load_start(load_start_pulse), .load_cluster(load_cluster),
    .load_file_size(load_file_size), .bmp_width(bmp_width),
    .bmp_height(bmp_height), .write_req(write_req),
    .write_req_ack(write_req_ack), .bmp_data_wr_en(bmp_data_wr_en),
    .bmp_data(bmp_data), .load_done(load_done), .load_error(load_error),
     .bmp_error(bmp_error), .pixel_continue(bmp_pixel_continue),
     .bmp_metadata_done(bmp_metadata_done),
     .bmp_metadata_valid(bmp_metadata_valid),
     .bmp_metadata_error(bmp_metadata_error),
     .bmp_source_width(bmp_source_width),
     .bmp_source_height(bmp_source_height), .bmp_top_down(bmp_top_down),
     .sector_req(bmp_sector_req),
     .sector_lba(bmp_sector_lba), .sector_busy(bmp_sector_busy),
     .sector_valid(bmp_sector_valid), .sector_byte(bmp_sector_byte),
     .sector_byte_index(bmp_sector_byte_index),
     .sector_done(bmp_sector_done), .sector_error(bmp_sector_error)
);

bmp_resize_pipeline #(
    .TARGET_WIDTH(RESIDENT_MODE ? 960 : 1280),
    .TARGET_HEIGHT(RESIDENT_MODE ? 540 : 720),
    .MAX_SOURCE_WIDTH(1920), .MAX_SOURCE_HEIGHT(1080), .ENABLE_ROI(ENABLE_ROI || RESIDENT_MODE),
    // A failed file can leave the scaler busy waiting for missing pixels.
    // A new resident header starts a fresh image and discards that old state.
    .RESTART_ON_START(RESIDENT_MODE)
) u_bmp_resize_pipeline (
    .clk(clk), .rst(rst_bmp),
    .start(bmp_metadata_done && bmp_metadata_valid),
    .source_width(bmp_source_width), .source_height(bmp_source_height),
    .source_top_down(bmp_top_down),
    .crop_enable(!RESIDENT_MODE && roi_loading), .crop_x(crop_x_q), .crop_y(crop_y_q),
    .crop_width(crop_width_q), .crop_height(crop_height_q),
    .raw_valid(bmp_data_wr_en), .raw_pixel(bmp_data), .raw_ready(),
    .allow_next_sector(bmp_pixel_continue),
    .pixel_valid(scaled_pixel_valid), .pixel_ready(write_ready),
    .pixel_rgb(scaled_pixel_rgb), .pixel_sof(), .pixel_eol(), .pixel_eof(scaled_pixel_eof),
    .write_v_flip(write_v_flip), .busy(), .done(),
    .pipeline_error(resize_pipeline_error)
);

 // Separate file positions and FIFOs keep music continuous across page commits.
 auto_bgm_player u_auto_bgm_player (
     .clk(clk), .rst(rst_audio), .wanted(bgm_wanted),
     .stream_busy(bgm_stream_busy), .sector_busy(sector_busy),
     .stream_done(bgm_stream_done), .stream_error(bgm_stream_error),
     .playback_complete(bgm_complete_sync[1]),
     .selected(bgm_selected), .start(bgm_start), .stop(bgm_stop)
 );

 generate if (NARRATION_BOTH_MODES) begin : g_page_pcm
 canonical_wav_file_stream_reader u_wav_file_stream_reader (
     .clk(clk), .rst_n(~(rst_audio || sd_core_rst)), .stream_start(stream_start), .stream_stop(stream_stop),
     .first_cluster(stream_cluster), .file_size(stream_size),
     .sectors_per_cluster(scan_fs_spc), .fat_start_lba(scan_fs_fat_start),
     .data_start_lba(scan_fs_data_start), .max_cluster(scan_fs_max_cluster),
     .pcm_continue(wav_pcm_continue), .stream_busy(wav_stream_busy),
     .stream_done(wav_stream_done), .stream_error(wav_stream_error),
     .stream_error_code(wav_stream_error_code), .channel_count(wav_channel_count),
     .sector_req(wav_sector_req), .sector_lba(wav_sector_lba),
     .sector_busy(wav_sector_busy), .sector_valid(wav_sector_valid),
     .sector_byte(wav_sector_byte), .sector_byte_index(wav_sector_byte_index),
     .sector_done(wav_sector_done), .sector_error(wav_sector_error),
     .pcm_valid(wav_pcm_valid), .pcm_byte(wav_pcm_byte)
 );
 end else begin : g_page_riff
 wav_file_stream_reader u_wav_file_stream_reader (
     .clk(clk), .rst_n(~(rst_audio || sd_core_rst)), .stream_start(stream_start),
     .stream_stop(stream_stop),
     .first_cluster(stream_cluster),
     .file_size(stream_size),
     .sectors_per_cluster(scan_fs_spc),
     .fat_start_lba(scan_fs_fat_start),
     .data_start_lba(scan_fs_data_start),
     .max_cluster(scan_fs_max_cluster),
     .pcm_continue(wav_pcm_continue), .stream_busy(wav_stream_busy),
     .stream_done(wav_stream_done), .stream_error(wav_stream_error),
     .stream_error_code(wav_stream_error_code),
     .channel_count(wav_channel_count), .sample_rate(wav_sample_rate),
     .block_align(wav_block_align), .pcm_valid(wav_pcm_valid),
     .pcm_byte(wav_pcm_byte), .pcm_byte_offset(wav_pcm_offset),
     .sector_req(wav_sector_req), .sector_lba(wav_sector_lba),
     .sector_busy(wav_sector_busy), .sector_valid(wav_sector_valid),
     .sector_byte(wav_sector_byte),
     .sector_byte_index(wav_sector_byte_index),
     .sector_done(wav_sector_done), .sector_error(wav_sector_error)
 );
 end endgenerate

 audio_pcm_fifo #(.MONO_STORAGE(ENABLE_AUTO_BGM)) u_audio_pcm_fifo (
     .wr_clk(clk), .wr_rst_n(~(rst_audio || sd_core_rst)), .stream_start(stream_start),
     .stream_stop(stream_stop),
     .stream_tag(emergency_active ? 5'b01000 : hotspot_stream ?
                 {2'b10,hotspot_audio_index} : {2'b00,audio_index}),
     .stream_end(wav_stream_done), .channel_count(wav_channel_count),
     .pcm_valid(wav_pcm_valid), .pcm_byte(wav_pcm_byte),
     .pcm_continue(wav_pcm_continue), .fifo_full(), .wr_level(),
     .rd_clk(audio_rd_clk), .rd_rst_n(audio_rst_n),
     .sample_tick(audio_sample_tick),
     .playback_pause(ENABLE_HOME_MENU && home_auto_paused && !emergency_active),
     .sample_valid(audio_sample_valid),
     .sample_left(audio_left_pcm), .sample_right(audio_right_pcm),
     .playback_active(audio_active), .playback_done(audio_done),
     .playback_complete(audio_playback_complete),
     .playback_start(audio_playback_start), .sample_consumed(audio_sample_consumed),
     .playback_tag(audio_page),
     .underflow_count(audio_underflow_count), .rd_level()
 );

 generate if (ENABLE_AUTO_BGM) begin : g_bgm
     canonical_wav_file_stream_reader reader (
         .clk(clk), .rst_n(~(rst_audio || sd_core_rst)), .stream_start(bgm_start), .stream_stop(bgm_stop),
         .first_cluster(scan_bgm_cluster), .file_size(scan_bgm_size),
         .sectors_per_cluster(scan_fs_spc), .fat_start_lba(scan_fs_fat_start),
         .data_start_lba(scan_fs_data_start), .max_cluster(scan_fs_max_cluster),
         .pcm_continue(bgm_pcm_continue), .stream_busy(bgm_stream_busy),
         .stream_done(bgm_stream_done), .stream_error(bgm_stream_error),
         .stream_error_code(), .channel_count(bgm_channels),
         .pcm_valid(bgm_pcm_valid), .pcm_byte(bgm_pcm_byte),
         .sector_req(bgm_sector_req), .sector_lba(bgm_sector_lba),
         .sector_busy(bgm_sector_busy), .sector_valid(bgm_sector_valid),
         .sector_byte(bgm_sector_byte), .sector_byte_index(bgm_sector_byte_index),
         .sector_done(bgm_sector_done), .sector_error(bgm_sector_error)
     );
     // All supplied audio is mono. Two 16-bit FIFOs occupy the same two BRAMs
     // as the former stereo FIFO; stereo replacements are downmixed safely.
     audio_pcm_fifo #(.MONO_STORAGE(1)) fifo (
         .wr_clk(clk), .wr_rst_n(~(rst_audio || sd_core_rst)), .stream_start(bgm_start),
         .stream_stop(bgm_stop), .stream_end(bgm_stream_done), .stream_tag(5'h0f),
         .channel_count(bgm_channels), .pcm_valid(bgm_pcm_valid), .pcm_byte(bgm_pcm_byte),
         .pcm_continue(bgm_pcm_continue), .fifo_full(), .wr_level(),
         .rd_clk(audio_rd_clk), .rd_rst_n(audio_rst_n), .sample_tick(audio_sample_tick),
         .playback_pause(ENABLE_HOME_MENU && home_auto_paused && !emergency_active),
         .sample_valid(), .sample_left(bgm_left_data), .sample_right(bgm_right_data),
         .playback_active(), .playback_done(), .playback_complete(bgm_complete),
         .playback_start(), .sample_consumed(), .playback_tag(),
         .underflow_count(), .rd_level()
     );
 end else begin : g_no_bgm
     assign bgm_stream_busy=0, bgm_stream_done=0, bgm_stream_error=0;
     assign bgm_complete=0, bgm_sector_req=0, bgm_sector_lba=0;
     assign bgm_left_data=0, bgm_right_data=0;
 end endgenerate

 sd_sector_arbiter_2 u_audio_sector_arbiter (
     .clk(clk), .rst(rst_arbiter || sd_core_rst),
     .c0_req(wav_sector_req), .c0_lba(wav_sector_lba),
     .c0_busy(wav_sector_busy), .c0_valid(wav_sector_valid),
     .c0_byte(wav_sector_byte), .c0_byte_index(wav_sector_byte_index),
     .c0_done(wav_sector_done), .c0_error(wav_sector_error),
     .c1_req(bgm_sector_req), .c1_lba(bgm_sector_lba),
     .c1_busy(bgm_sector_busy), .c1_valid(bgm_sector_valid),
     .c1_byte(bgm_sector_byte), .c1_byte_index(bgm_sector_byte_index),
     .c1_done(bgm_sector_done), .c1_error(bgm_sector_error),
     .sector_req(audio_sector_req), .sector_lba(audio_sector_lba),
     .sector_busy(audio_sector_busy), .sector_valid(audio_sector_valid),
     .sector_byte(audio_sector_byte), .sector_byte_index(audio_sector_byte_index),
     .sector_done(audio_sector_done), .sector_error(audio_sector_error)
 );

 sd_sector_arbiter_2 u_sd_sector_arbiter_2 (
     // A sector timeout resets the adapter. Flush the matching ownership at
     // the same time so the arbiter cannot wait forever for the aborted
     // transaction's sector_done pulse.
     .clk(clk), .rst(rst_arbiter || sd_core_rst),
     .c0_req(bmp_sector_req), .c0_lba(bmp_sector_lba),
     .c0_busy(bmp_sector_busy), .c0_valid(bmp_sector_valid),
     .c0_byte(bmp_sector_byte), .c0_byte_index(bmp_sector_byte_index),
     .c0_done(bmp_sector_done), .c0_error(bmp_sector_error),
     .c1_req(audio_sector_req), .c1_lba(audio_sector_lba),
     .c1_busy(audio_sector_busy), .c1_valid(audio_sector_valid),
     .c1_byte(audio_sector_byte), .c1_byte_index(audio_sector_byte_index),
     .c1_done(audio_sector_done), .c1_error(audio_sector_error),
     .sector_req(sector_req), .sector_lba(sector_lba),
     .sector_busy(sector_busy), .sector_valid(sector_valid),
     .sector_byte(sector_byte), .sector_byte_index(sector_byte_index),
     .sector_done(sector_done), .sector_error(sector_error)
 );

sd_sector_adapter #(
    .CLK_FREQ_HZ(CLK_FREQ_HZ), .READ_TIMEOUT_MS(SD_READ_TIMEOUT_MS)
) u_sd_sector_adapter (
    .clk(clk), .rst(sd_core_rst), .sector_req(sector_req),
    .sector_lba(sector_lba), .sector_busy(sector_busy),
    .sector_valid(sector_valid), .sector_byte(sector_byte),
    .sector_byte_index(sector_byte_index), .sector_done(sector_done),
    .sector_error(sector_error), .sd_sec_read(sd_sec_read),
    .sd_sec_read_addr(sd_sec_read_addr),
    .sd_sec_read_data_valid(sd_sec_read_data_valid),
    .sd_sec_read_data(sd_sec_read_data), .sd_sec_read_end(sd_sec_read_end)
);

sd_card_top sd_card_top_m0 (
    .clk(clk), .rst(sd_core_rst), .SD_nCS(SD_nCS), .SD_DCLK(SD_DCLK),
    .SD_MOSI(SD_MOSI), .SD_MISO(SD_MISO), .sd_init_done(sd_init_done),
    .sd_sec_read(sd_sec_read), .sd_sec_read_addr(sd_sec_read_addr),
    .sd_sec_read_data(sd_sec_read_data),
    .sd_sec_read_data_valid(sd_sec_read_data_valid),
    .sd_sec_read_end(sd_sec_read_end), .sd_sec_write(1'b0),
    .sd_sec_write_addr(32'd0), .sd_sec_write_data(),
    .sd_sec_write_data_req(), .sd_sec_write_end()
);

endmodule

// A mode change aborts the old WAV and lets the outstanding SD sector retire
// before starting music. EOF is not playback completion: drain the PCM FIFO
// before looping. A bad/missing file stays silent until auto is re-enabled.
module auto_bgm_player (
    input wire clk, rst, wanted,
    input wire stream_busy, sector_busy, stream_done, stream_error,
    input wire playback_complete,
    output reg selected, start, stop
);
    localparam WAIT_IDLE=0, ARM=1, PLAY=2, FAILED=3;
    reg [1:0] state;
    reg [2:0] settle;
    reg ended;
    always @(posedge clk or posedge rst) begin
        if (rst) begin
            selected<=0; start<=0; stop<=0;
            state<=WAIT_IDLE; settle<=0; ended<=0;
        end else begin
            start<=0; stop<=0;
            if (!wanted) begin
                if (selected) stop<=1;
                selected<=0; state<=WAIT_IDLE; settle<=7; ended<=0;
            end else if (!selected) begin
                selected<=1; stop<=1;
                state<=WAIT_IDLE; settle<=7; ended<=0;
            end else case (state)
                WAIT_IDLE: begin
                    if (settle!=0) settle<=settle-1'b1;
                    else if (!stream_busy && !sector_busy) begin
                        start<=1; ended<=0; state<=ARM;
                    end
                end
                ARM: state<=PLAY;
                PLAY: begin
                    if (stream_error) state<=FAILED;
                    else begin
                        if (stream_done) ended<=1;
                        if (ended && playback_complete && !stream_busy) begin
                            stop<=1; settle<=7; state<=WAIT_IDLE;
                        end
                    end
                end
                default: begin end
            endcase
        end
    end
endmodule

module key_press_debounce #(
    parameter integer CLK_FREQ_HZ = 100_000_000,
    parameter integer DEBOUNCE_MS = 20
)(
    input  wire clk,
    input  wire rst,
    input  wire button_in,
    output reg  press_pulse,
    output reg  button_stable_out
);

localparam integer DEBOUNCE_CYCLES = (CLK_FREQ_HZ / 1000) * DEBOUNCE_MS;
localparam integer COUNT_BITS = (DEBOUNCE_CYCLES > 1) ? $clog2(DEBOUNCE_CYCLES) : 1;

reg button_sync0;
reg button_sync1;
reg button_stable;
reg [COUNT_BITS-1:0] cnt;

always @(posedge clk or posedge rst) begin
    if (rst) begin
        button_sync0 <= 1'b1;
        button_sync1 <= 1'b1;
        button_stable <= 1'b1;
        cnt <= 0;
        press_pulse <= 1'b0;
        button_stable_out <= 1'b1;
    end else begin
        button_sync0 <= button_in;
        button_sync1 <= button_sync0;
        press_pulse <= 1'b0;

        if (button_sync1 == button_stable) begin
            cnt <= 0;
        end else if (cnt >= DEBOUNCE_CYCLES - 1) begin
            if (button_stable && !button_sync1)
                press_pulse <= 1'b1;
            button_stable <= button_sync1;
            button_stable_out <= button_sync1;
            cnt <= 0;
        end else begin
            cnt <= cnt + 1'b1;
        end
    end
end

endmodule
