
module top(
    input                       key_gallery_n,
    input                       key_prev_n,
    input                       key_volume_n,
    input                       key_roi_mode_n,
    input                       key_roi_confirm_n,
    input                       key_roi_back_n,
    input                       key_roi_left_n,
    input                       key_roi_right_n,
    input                       key_roi_up_n,
    input                       key_roi_down_n,
    input                       clk,
    input                       rst_n,
    input                       key1,           // Next page
    input                       key2,           // Previous page
    input                       key3,           // 独立应急切换（KEY3，B1）
    input                       sw1,            // Volume adjustment (SW1, C8)
    input                       sw2,            // Hotspot selection (SW2, C7)
    input                       sw3,            // Brightness adjustment mode (SW3, C6)
    input                       sw4,            // Contrast adjustment mode (SW4, C5)
    input                       touch_rx,       // TJC panel TX, J2 pin 13 / N1
    output                      touch_tx,       // TJC panel RX, J2 pin 14 / M2

    output [5:0]                seg_sel,
    output [7:0]                seg_data,

    // HDMI TMDS
    output                      HDMI_CLK_P,
    output                      HDMI_D2_P,
    output                      HDMI_D1_P,
    output                      HDMI_D0_P,

    // HDMI DDC
    output                      HDMI_DDC_SCL,
    inout                       HDMI_DDC_SDA,

    // TF card SPI
    output                      sd_ncs,
    output                      sd_dclk,
    output                      sd_mosi,
    input                       sd_miso
);

parameter MEM_DATA_BITS = 32;
parameter ADDR_BITS     = 21;
parameter BUSRT_BITS    = 10;
parameter FRAME_PIXELS  = 24'd921600;   // 1280*720
parameter FRAME_WORDS   = 24'd460800;   // two RGB565 pixels per SDRAM word

// Compact the user-facing page number after removing the former page 7.
// Internal slot 7 remains PIC8/AUD8 so media and subtitle indices are stable.
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

wire Sdr_init_done;
wire Sdr_init_ref_vld;
wire Sdr_busy;

wire sd_card_clk;
wire sd_pll_clk_unused;
localparam integer SD_CLK_FREQ_HZ = 50_000_000;
wire ext_mem_clk;
wire ext_mem_clk_sft;
wire video_ref_clk;
wire video_clk;
wire hdmi_5x_clk;
wire sys_pll_lock;
wire video_ref_pll_lock;
wire video_pll_lock;

wire sys_rst_n;
wire sdcard_rst_n;
localparam integer DEBOUNCE_MS_CLKS = SD_CLK_FREQ_HZ / 1000;
reg [15:0] debounce_ms_div;
reg debounce_ms_tick;
always @(posedge sd_card_clk or negedge sdcard_rst_n) begin
    if (!sdcard_rst_n) begin
        debounce_ms_div <= 0;
        debounce_ms_tick <= 0;
    end else begin
        debounce_ms_tick <= debounce_ms_div == DEBOUNCE_MS_CLKS - 1;
        debounce_ms_div <= debounce_ms_div == DEBOUNCE_MS_CLKS - 1 ?
                           16'd0 : debounce_ms_div + 1'b1;
    end
end
wire mem_rst_n;
wire video_rst_n;
wire hdmi_5x_rst_n;
wire Sdr_init_done_sd;

wire hs;
wire vs;
wire de;

wire [23:0] vout_data_raw;
wire [23:0] vout_data;
wire        display_valid;
wire        display_valid_video;
wire        display_valid_mem;

wire [3:0]  state_code;
wire [3:0]  state_code_sys;
wire        display_valid_sys;
wire [2:0]  current_image_index;
wire [2:0]  current_image_index_sys;
wire        media_auto_play_en;
wire [7:0]  media_error_code;
wire [2:0] fault_notice_state_sd, fault_notice_state_video;
wire [1:0] fault_notice_epoch_sd, fault_notice_epoch_video;
wire        emergency_enter_event;
wire        emergency_exit_event;
wire        emergency_toggle_event;
wire        guide_next_event;
wire        guide_prev_event;
wire        adjust_up_level_n,adjust_down_level_n;
wire        brightness_adjust_mode;
wire [6:0]  brightness_percent_sd;
wire [7:0]  brightness_setting_sd;
wire        brightness_adjust_mode_video;
wire [6:0]  brightness_percent_video;
wire [7:0]  brightness_setting_video;
wire        contrast_adjust_mode;
wire [7:0]  contrast_percent_sd, contrast_setting_sd;
wire        contrast_adjust_mode_video;
wire [7:0]  contrast_percent_video, contrast_setting_video;
wire        volume_adjust_mode;
wire [6:0]  volume_percent_sd, volume_percent_video;
wire [7:0]  volume_setting_sd, volume_setting_video;
wire        volume_adjust_mode_video;
wire        picture_adjust_mode = brightness_adjust_mode || contrast_adjust_mode || volume_adjust_mode;
wire [1:0] roi_mode;
wire roi_active, roi_zoom_requested, roi_request_valid, roi_request_ready;
wire roi_available, roi_busy, roi_display_zoom, instant_switch_sd, instant_switch_video;
wire [3:0] roi_source_step, roi_size_units, roi_request_units, roi_display_units;
wire [7:0] roi_grid_x;
wire [6:0] roi_grid_y;
wire [7:0] roi_request_grid_x, roi_display_grid_x;
wire [6:0] roi_request_grid_y, roi_display_grid_y;
wire [15:0] roi_x, roi_y, roi_width, roi_height;
wire roi_owns_keys = roi_active || roi_display_zoom || roi_busy;
wire [1:0] roi_mode_video;
wire [7:0] roi_grid_x_video;
wire [6:0] roi_grid_y_video;
wire [3:0] roi_size_video, roi_display_units_video;
wire roi_display_zoom_video, roi_busy_video;
wire roi_thumbnail_ready, roi_thumbnail_ready_sd;
wire [3:0] roi_thumbnail_page, roi_thumbnail_page_sd;
wire [23:0] roi_thumbnail_rgb;
wire gallery_active, gallery_select_valid, gallery_select_ready;
wire [2:0] gallery_selected, gallery_select_page;
wire [2:0] home_state;
wire [1:0] route_select_sd,route_select_video;
wire [2:0] route_choice_sd,route_choice_video;
wire [1:0] route_type_sd,route_type_video,route_interest_sd,route_interest_video;
wire [2:0] route_station_sd,route_station_video;
wire [1:0] hotspot_mode_sd, hotspot_mode_video;
wire [2:0] hotspot_page_sd, hotspot_page_video;
wire [1:0] hotspot_region_sd, hotspot_region_video;
wire hotspot_replay_sd, hotspot_missing_audio_sd;
wire hotspot_target_pending_sd, hotspot_done_sd;
reg hotspot_display_ack_video;
reg [2:0] hotspot_ack_page_video;
reg [1:0] hotspot_ack_region_video;
wire hotspot_ack_sd;
wire [2:0] hotspot_ack_page_sd;
wire [1:0] hotspot_ack_region_sd;
wire hotspot_video_ready_sd=hotspot_ack_sd && hotspot_ack_page_sd==hotspot_page_sd &&
                            hotspot_ack_region_sd==hotspot_region_sd;
wire [3:0] osd_media_id;
wire osd_display_valid;
reg emergency_video_sync2;
wire home_navigation_busy,home_auto_run,home_audio_mute,home_auto_step,home_roi_allowed,home_auto_paused,home_silent_auto;
wire nav_active_sd,nav_cancel_sd,nav_active_video,nav_target_ready_video;
wire [3:0] nav_epoch_sd,nav_epoch_video,nav_ack_epoch_video,nav_ack_epoch_sd;
wire [2:0] nav_profile_sd,nav_profile_video,nav_index_sd,nav_index_video,nav_target_video;
wire [1:0] nav_direction_sd,nav_direction_video;
wire [10:0] nav_anchor_x_sd,nav_anchor_x_video;
wire [9:0] nav_anchor_y_sd,nav_anchor_y_video;
wire nav_busy_video,nav_commit_video,nav_audio_video,nav_complete_video,nav_failed_video;
wire nav_commit_sd,nav_audio_sd,nav_complete_sd,nav_failed_sd,nav_dark_sd,nav_dark_video;
wire nav_ack_matches=nav_ack_epoch_sd==nav_epoch_sd;
wire nav_select_enable=!nav_active_sd || (nav_ack_matches && nav_commit_sd);
wire nav_early_audio_sd=nav_active_sd && nav_profile_sd==2 && nav_ack_matches && nav_audio_sd;
wire nav_keep_audio_sd=nav_active_sd && !(nav_ack_matches && nav_dark_sd);
wire [2:0] nav_shown_slot_video;
wire nav_shown_valid_video,nav_shown_emergency_video,nav_shown_roi_video,nav_shown_wipe_video;
wire [6:0] nav_reveal_level;
wire [23:0] nav_rgb;
wire nav_hs,nav_vs,nav_de;
reg [10:0] nav_pixel_x;
reg [9:0] nav_pixel_y;
reg nav_de_d;
wire [2:0] resident_shown_slot_mem,home_shown_slot_sd;
wire resident_shown_valid_mem,resident_shown_emergency_mem,resident_shown_roi_mem;
wire home_shown_valid_sd,home_shown_emergency_sd,home_shown_roi_sd,home_transition_sd;
wire [2:0] home_state_video,home_page_video;
wire home_valid_video,home_busy_video,home_auto_video,home_audio_video;
wire [7:0] home_error_video;
wire home_welcome_video=home_page_video==0 && home_valid_video &&
    ((home_state_video==0 && !home_busy_video) ||
     (nav_active_video && nav_profile_video==1 && !nav_dark_video));
wire [7:0] gallery_resource_mask, thumbnail_ready_mask;
wire [7:0] failed_page_mask;
wire bad_page_notice;
wire [7:0] thumbnail_ram_ready_mask, thumbnail_sdram_ready_mask;
wire thumbnail_capture_ready, frame_pixel_ready, thumbnail_writer_busy;
wire frame_app_wr_en, thumbnail_app_wr_en;
wire [ADDR_BITS-1:0] frame_app_wr_addr, thumbnail_app_wr_addr;
wire [31:0] frame_app_wr_data, thumbnail_app_wr_data;
wire [3:0] frame_app_wr_mask;
wire thumbnail_start, thumbnail_commit, thumbnail_pixel_valid;
wire [2:0] thumbnail_page;
wire [23:0] thumbnail_pixel_rgb, gallery_thumbnail_rgb;
wire gallery_active_video;
wire [2:0] gallery_selected_video;
wire [7:0] gallery_resource_video, thumbnail_ready_video;
wire gallery_overlay_hit;
wire [23:0] gallery_overlay_color;
reg gallery_overlay_hit_q;
reg [23:0] gallery_overlay_color_q;
wire        reverse_switch_sd;
wire        reverse_switch_video;
wire [11:0] touch_key_n;
wire touch_next_n, touch_prev_n, touch_emergency_n, touch_hotspot_enable;
wire touch_settings_open;
wire [1:0] touch_adjust_mode;
wire touch_slider_valid;
wire [6:0] touch_slider_percent;
wire [7:0] touch_contrast_percent = {1'b0,touch_slider_percent} + 8'd50;
wire [3:0] touch_menu_command;
wire touch_region_valid;
wire [1:0] touch_region_index;
wire [11:0] home_keys_n =
    {key_roi_down_n,key_roi_right_n,key2,key_roi_up_n,key1,
     key_roi_mode_n,key_volume_n,key_roi_confirm_n,key_prev_n,
     key_roi_left_n,key_roi_back_n,key_gallery_n} & touch_key_n;
wire [6:0] roi_keys_n =
    {key_roi_mode_n,key_volume_n,key_roi_confirm_n,key_prev_n,
     key_roi_left_n,key_roi_back_n,key_roi_right_n} &
    {touch_key_n[6:3],touch_key_n[2:1],touch_key_n[10]};
wire [3:0] touch_page = home_state==0 ? 4'd0 :
    home_state==1 ? (route_select_sd==3 ? 4'd11 : route_select_sd==2 ? 4'd3 : route_select_sd==1 ? 4'd2 : 4'd1) :
    home_state==4 ? 4'd9 :
    touch_settings_open ? 4'd10 :
    roi_owns_keys ? 4'd8 :
    home_state==3 ? 4'd7 :
    hotspot_mode_sd==1 ? 4'd5 : hotspot_mode_sd==2 ? 4'd6 : 4'd4;

tjc_touch_uart #(.CLK_HZ(SD_CLK_FREQ_HZ), .BAUD(9600)) u_tjc_touch (
    .clk(sd_card_clk), .rst(~sdcard_rst_n), .uart_rx(touch_rx), .uart_tx(touch_tx),
    .screen_page(touch_page), .content_page(current_image_index), .key_n(touch_key_n),
    .next_n(touch_next_n), .prev_n(touch_prev_n),
    .emergency_n(touch_emergency_n), .hotspot_enable(touch_hotspot_enable),
    .settings_open(touch_settings_open), .adjust_mode(touch_adjust_mode),
    .slider_valid(touch_slider_valid), .slider_percent(touch_slider_percent),
    .menu_command(touch_menu_command),
    .region_valid(touch_region_valid), .region_index(touch_region_index)
);

key_press_debounce #(.CLK_FREQ_HZ(SD_CLK_FREQ_HZ), .DEBOUNCE_MS(20)) u_prev_key (
    .clk(sd_card_clk), .rst(~sdcard_rst_n), .button_in(key2 & touch_prev_n),
    .press_pulse(guide_prev_event), .button_stable_out()
);
button_level_debounce #(.CLK_FREQ_HZ(SD_CLK_FREQ_HZ), .DEBOUNCE_MS(20),
    .USE_SHARED_TICK(1)) u_adjust_up (
    .clk(sd_card_clk), .rst(~sdcard_rst_n), .ms_tick(debounce_ms_tick),
    .button_in_n(key_volume_n & touch_key_n[5]),
    .stable_level_n(adjust_up_level_n)
);
button_level_debounce #(.CLK_FREQ_HZ(SD_CLK_FREQ_HZ), .DEBOUNCE_MS(20),
    .USE_SHARED_TICK(1)) u_adjust_down (
    .clk(sd_card_clk), .rst(~sdcard_rst_n), .ms_tick(debounce_ms_tick),
    .button_in_n(key_roi_mode_n & touch_key_n[6]),
    .stable_level_n(adjust_down_level_n)
);
wire        guide_auto_event;
wire        emergency_active_media;
wire        emergency_active_ctrl;
wire        emergency_warning_active = emergency_active_ctrl &&
                                               !emergency_active_media;
wire [3:0]  osd_media_code = emergency_active_media ? 4'd8 :
                                                {1'b0, current_image_index};
wire [1:0]  guide_state;
wire [3:0]  current_image_display_sys =
             page_display_number(current_image_index_sys);
wire [6:0]  seg_data_status;


wire        sd_card_write_en;
wire [31:0] sd_card_write_data;
wire        sd_card_write_req;
wire        sd_card_write_req_ack;
wire        sd_card_write_req_ack_mem;
wire        sd_card_write_ready;
wire        sd_card_write_v_flip;
wire        sd_card_write_last;
wire        resident_request_valid, resident_request_accepted;
wire [2:0]  resident_load_slot;
wire        resident_load_flip, resident_source_error;
wire        resident_load_valid_mem, resident_load_ready_mem;
wire [2:0]  resident_load_slot_mem;
wire        resident_load_flip_mem;
wire [7:0]  resident_ready_mask_mem, resident_error_mask_mem;
wire [7:0]  resident_ready_mask_sd, resident_error_mask_sd;
wire        resident_writer_busy, resident_writer_en;
wire [20:0] resident_writer_addr;
wire [31:0] resident_writer_data;
wire        resident_reader_busy, resident_underflow, resident_frame_tick;
wire        resident_overview_ready;
wire [2:0]  resident_overview_slot;
wire [23:0] resident_overview_rgb;
wire [13:0] resident_overview_address;
wire        resident_display_valid_mem, resident_emergency_mem;
wire        resident_gallery_mem, resident_roi_mem;
wire [2:0]  resident_display_slot_mem;
wire [7:0]  resident_grid_x_mem;
wire [6:0]  resident_grid_y_mem;
wire [3:0]  resident_units_mem;
wire        resident_reverse_mem, resident_instant_mem;
wire [1:0] resident_return_kind_mem;
wire [2:0] resident_return_index_mem;
wire        frame_write_finish;
reg         frame_write_toggle_mem;
wire        frame_write_abort_toggle;
wire        frame_write_abort_ack_toggle;

wire [1:0]  write_buf_idx;
wire [1:0]  disp_buf_idx;
wire [1:0]  disp_buf_idx_video;
wire        manual_switch_sd;
wire        manual_switch_video;
wire [23:0] manual_unity_rgb;
wire [1:0]  transition_display_bank;
wire        frame_start;
wire        reader_idle_mem;
wire        reader_idle_sd;
wire        fade_transition_active_sd;
wire        fade_transition_active;
wire [1:0]  reader_buf_idx_mem;
wire [1:0]  reader_fade_bank_mem;
wire        manual_wipe_active;
wire        manual_page_pulse;
wire [1:0]  reader_buf_idx_sd;
wire        reader_command_busy;
wire        reader_urgent;
wire        frame_write_engine_busy;

wire App_rd_en;
wire [ADDR_BITS-1:0] App_rd_addr;
wire Sdr_rd_en;
wire [MEM_DATA_BITS-1:0] Sdr_rd_dout;
wire App_wr_en;
wire [ADDR_BITS-1:0] App_wr_addr;
wire [MEM_DATA_BITS-1:0] App_wr_din;
wire [3:0] App_wr_dm;


// HDMI 1.4b 音频发射相关
wire        audio_valid;
wire [23:0] audio_left_data;
wire [23:0] audio_right_data;
wire        tone_sample_valid;
wire [23:0] audio_left_tone_data;
wire [23:0] audio_right_tone_data;
wire        wav_audio_valid;
wire signed [23:0] wav_audio_left;
wire signed [23:0] wav_audio_right;
wire        wav_audio_active;
wire        faded_audio_valid;
wire signed [23:0] faded_audio_left;
wire signed [23:0] faded_audio_right;
wire cue_audio_valid;
wire signed [23:0] cue_audio_left, cue_audio_right;
wire        wav_audio_active_sd;
wire        wav_audio_done;
wire        wav_playback_start, wav_sample_consumed;
wire [4:0]  wav_audio_page;
wire [31:0] wav_audio_underflow_count;
wire signed [15:0] bgm_left_pcm, bgm_right_pcm;

wire        acr_valid;
wire [19:0] acr_cts;
wire [19:0] acr_n;

wire        axis_s_user;
wire        axis_s_valid;
wire        axis_s_last;
wire [23:0] axis_s_data;
wire        axis_s_ready;

wire        edid_trig;
wire        edid_valid;
wire [7:0]  edid_data;

wire [9:0]  tmds_ch0_data;
wire [9:0]  tmds_ch1_data;
wire [9:0]  tmds_ch2_data;
wire [9:0]  tmds_clk_data;
wire        hdmi_video_locked;

// Hold every domain in reset until all clock generators are stable.
wire ext_rst_n;
assign ext_rst_n = rst_n & sys_pll_lock & video_ref_pll_lock & video_pll_lock;

// 保持你原来的 TF / SDRAM / video 时钟
EG_LOGIC_BUFG u_sd_clock_buffer (.i(clk), .o(sd_card_clk));
sys_pll sys_pll_m0(
    .refclk     (clk),
    .clk0_out   (sd_pll_clk_unused),
    .clk1_out   (ext_mem_clk),
    .clk2_out   (ext_mem_clk_sft),
    .reset      (~rst_n),
    .extlock    (sys_pll_lock)
);

video_ref_pll video_ref_pll_m0(
    .refclk     (clk),
    .clk0_out   (video_ref_clk),
    .reset      (~rst_n),
    .extlock    (video_ref_pll_lock)
);

video_pll video_pll_m0(
    .refclk     (video_ref_clk),
    .clk0_out   (video_clk),
    .clk1_out   (hdmi_5x_clk),
    .reset      (~rst_n | ~video_ref_pll_lock),
    .extlock    (video_pll_lock)
);

reset_sync u_sys_reset (
    .clk        (clk),
    .ext_rst_n  (ext_rst_n),
    .rst_n_sync (sys_rst_n)
);

reset_sync u_sdcard_reset (
    .clk        (sd_card_clk),
    .ext_rst_n  (ext_rst_n),
    .rst_n_sync (sdcard_rst_n)
);

reset_sync u_mem_reset (
    .clk        (ext_mem_clk),
    .ext_rst_n  (ext_rst_n),
    .rst_n_sync (mem_rst_n)
);

reset_sync u_video_reset (
    .clk        (video_clk),
    .ext_rst_n  (ext_rst_n),
    .rst_n_sync (video_rst_n)
);

reset_sync u_hdmi_5x_reset (
    .clk        (hdmi_5x_clk),
    .ext_rst_n  (ext_rst_n),
    .rst_n_sync (hdmi_5x_rst_n)
);

sync_2ff u_sdram_init_sync (
    .clk        (sd_card_clk),
    .rst_n      (sdcard_rst_n),
    .async_in   (Sdr_init_done),
    .sync_out   (Sdr_init_done_sd)
);

// Emergency control is debounced in the SD/control clock domain.
input_event_router #(
    .CLK_FREQ_HZ(SD_CLK_FREQ_HZ), .DEBOUNCE_MS(20), .LONG_PRESS_MS(1500),
    .ENABLE_NEXT_LONG_PRESS(0), .USE_SHARED_DEBOUNCE_TICK(1)
) u_guide_input_router (
    .clk(sd_card_clk), .rst(~sdcard_rst_n), .debounce_ms_tick(debounce_ms_tick),
    .key_next_n(key1 & touch_next_n), .key_auto_n(1'b1),
    .key_emergency_n(key3 & touch_emergency_n),
    .brightness_adjust_mode(picture_adjust_mode || roi_owns_keys ||
                            (home_state!=2 && home_state!=3) || home_navigation_busy),
    .next_event(guide_next_event), .toggle_auto_event(guide_auto_event),
    .toggle_emergency_event(emergency_toggle_event),
    .key_next_pressed(), .key_auto_pressed()
);

brightness_key_control #(.CLK_FREQ_HZ(SD_CLK_FREQ_HZ),
    .USE_SHARED_DEBOUNCE_TICK(1)) u_brightness_key_control (
    .clk(sd_card_clk), .rst(~sdcard_rst_n), .debounce_ms_tick(debounce_ms_tick),
    .mode_switch(sw3 || (touch_settings_open && touch_adjust_mode==2)),
    .increase_pressed(~adjust_up_level_n), .decrease_pressed(~adjust_down_level_n),
    .direct_valid(touch_slider_valid && touch_adjust_mode==2),
    .direct_percent({1'b0,touch_slider_percent}),
    .emergency_active(emergency_active_ctrl || contrast_adjust_mode || volume_adjust_mode),
    .adjust_mode(brightness_adjust_mode),
    .percent(brightness_percent_sd), .setting(brightness_setting_sd)
);

// Volume owns the shared keys before contrast, then brightness.
brightness_key_control #(.MIN_PERCENT(50), .MAX_PERCENT(150),
    .PERCENT_BITS(8), .CONTRAST(1), .CLK_FREQ_HZ(SD_CLK_FREQ_HZ),
    .USE_SHARED_DEBOUNCE_TICK(1)) u_contrast_key_control (
    .clk(sd_card_clk), .rst(~sdcard_rst_n), .debounce_ms_tick(debounce_ms_tick),
    .mode_switch(sw4 || (touch_settings_open && touch_adjust_mode==3)),
    .increase_pressed(~adjust_up_level_n), .decrease_pressed(~adjust_down_level_n),
    .direct_valid(touch_slider_valid && touch_adjust_mode==3),
    .direct_percent(touch_contrast_percent),
    .emergency_active(emergency_active_ctrl || volume_adjust_mode),
    .adjust_mode(contrast_adjust_mode),
    .percent(contrast_percent_sd), .setting(contrast_setting_sd)
);

brightness_key_control #(.CLK_FREQ_HZ(SD_CLK_FREQ_HZ), .MIN_PERCENT(0),
    .USE_SHARED_DEBOUNCE_TICK(1)) u_volume_key_control (
    .clk(sd_card_clk), .rst(~sdcard_rst_n), .debounce_ms_tick(debounce_ms_tick),
    .mode_switch(sw1 || (touch_settings_open && touch_adjust_mode==1)),
    .increase_pressed(~adjust_up_level_n), .decrease_pressed(~adjust_down_level_n),
    .direct_valid(touch_slider_valid && touch_adjust_mode==1),
    .direct_percent({1'b0,touch_slider_percent}),
    .emergency_active(emergency_active_ctrl), .adjust_mode(volume_adjust_mode),
    .percent(volume_percent_sd), .setting(volume_setting_sd)
);

roi_zoom_control #(.CLK_FREQ_HZ(SD_CLK_FREQ_HZ)) u_roi_zoom_control (
    .clk(sd_card_clk), .rst(~sdcard_rst_n),
    .keys_n(roi_keys_n),
    .increase_pressed(1'b0), .decrease_pressed(1'b0),
    .available(roi_available), .suspended(!home_roi_allowed || picture_adjust_mode),
    .image_index(current_image_index), .source_step(roi_source_step),
    .load_busy(roi_busy),
    .request_ready(roi_request_ready),
    .mode(roi_mode), .active(roi_active), .zoom_requested(roi_zoom_requested),
    .request_valid(roi_request_valid), .request_units(roi_request_units),
    .request_grid_x(roi_request_grid_x), .request_grid_y(roi_request_grid_y),
    .request_x(roi_x), .request_y(roi_y), .request_width(roi_width), .request_height(roi_height),
    .grid_x(roi_grid_x), .grid_y(roi_grid_y), .size_units(roi_size_units)
);

home_menu_control #(.CLK_FREQ_HZ(SD_CLK_FREQ_HZ),.ENABLE_NAV_EFFECT(1),
    .ENABLE_INTERACTIVE_ROUTES(1)) u_home_menu_control (
    .clk(sd_card_clk), .rst(~sdcard_rst_n),
    .keys_n(home_keys_n),
    .available(display_valid),.emergency(emergency_active_ctrl || emergency_active_media),
    .hotspot_enable(sw2 || touch_hotspot_enable),
    .touch_menu_command(touch_menu_command),
    .touch_region_valid(touch_region_valid),
    .touch_region_index(touch_region_index),
    .adjusting(picture_adjust_mode),.roi_owns_keys(roi_owns_keys),
    .transition_busy(home_transition_sd),
    .shown_page(home_shown_slot_sd==6 ? 3'd7 : home_shown_slot_sd),
    .shown_valid(home_shown_valid_sd),.shown_emergency(home_shown_emergency_sd),
    .shown_roi(home_shown_roi_sd),
    .resource_mask(gallery_resource_mask),.failed_page_mask(failed_page_mask),
    .bad_page_notice(bad_page_notice),.current_page(current_image_index),
    .select_ready(gallery_select_ready && nav_select_enable && !nav_cancel_sd),.auto_step(home_auto_step),
    .hotspot_done(hotspot_done_sd),
    .nav_ack_epoch(nav_ack_epoch_sd),.nav_complete(nav_complete_sd),.nav_failed(nav_failed_sd),
    .nav_active(nav_active_sd),.nav_cancel(nav_cancel_sd),.nav_epoch(nav_epoch_sd),
    .nav_profile(nav_profile_sd),.nav_menu_index(nav_index_sd),.nav_direction(nav_direction_sd),
    .nav_anchor_x(nav_anchor_x_sd),.nav_anchor_y(nav_anchor_y_sd),
    .next_event(guide_next_event),.state(home_state),
    .menu_active(gallery_active),.selected(gallery_selected),
    .select_valid(gallery_select_valid),.select_page(gallery_select_page),
    .navigation_busy(home_navigation_busy),.auto_run(home_auto_run),.audio_mute(home_audio_mute),
    .roi_allowed(home_roi_allowed),.auto_paused(home_auto_paused),.silent_auto(home_silent_auto),
    .hotspot_mode(hotspot_mode_sd),.hotspot_page(hotspot_page_sd),
    .hotspot_region(hotspot_region_sd),.hotspot_replay(hotspot_replay_sd),
    .hotspot_target_pending(hotspot_target_pending_sd),
    .route_select(route_select_sd),.route_choice(route_choice_sd),.route_type(route_type_sd),
    .route_interest(route_interest_sd),.route_station(route_station_sd)
);

page_switch_cdc #(.WIDTH(7),.RESET_VALUE(7'd0)) u_hotspot_to_video (
    .src_clk(sd_card_clk),.src_rst_n(sdcard_rst_n),
    .src_page({hotspot_mode_sd,hotspot_page_sd,hotspot_region_sd}),
    .pix_clk(video_clk),.pix_rst_n(video_rst_n),.frame_start(frame_start),
    .pix_page({hotspot_mode_video,hotspot_page_video,hotspot_region_video})
);
always @(posedge video_clk or negedge video_rst_n) begin
    if(!video_rst_n) begin
        hotspot_display_ack_video<=0;hotspot_ack_page_video<=0;hotspot_ack_region_video<=0;
    end else if(frame_start) begin
        hotspot_display_ack_video<=hotspot_mode_video==2 &&
            osd_media_id=={1'b0,hotspot_page_video} && osd_display_valid &&
            !emergency_video_sync2;
        hotspot_ack_page_video<=hotspot_page_video;
        hotspot_ack_region_video<=hotspot_region_video;
    end
end
page_switch_cdc #(.WIDTH(6),.RESET_VALUE(6'd0)) u_hotspot_display_ack (
    .src_clk(video_clk),.src_rst_n(video_rst_n),
    .src_page({hotspot_display_ack_video,hotspot_ack_page_video,hotspot_ack_region_video}),
    .pix_clk(sd_card_clk),.pix_rst_n(sdcard_rst_n),.frame_start(1'b1),
    .pix_page({hotspot_ack_sd,hotspot_ack_page_sd,hotspot_ack_region_sd})
);

// Isolate mode ownership from the media controller's request decode path.
reg media_next_event, media_prev_event;
always @(posedge sd_card_clk or negedge sdcard_rst_n) begin
    if (!sdcard_rst_n) begin
        media_next_event <= 0;
        media_prev_event <= 0;
    end else begin
        // Feed the same debounced page events to the media controller.  The
        // home-menu controller consumes these events for its state change,
        // while sd_card_bmp also needs the origin direction for the wipe.
        media_next_event <= guide_next_event;
        media_prev_event <= guide_prev_event;
    end
end

page_switch_cdc #(.WIDTH(49), .RESET_VALUE({1'b0,7'd100,8'd255,1'b0,8'd100,8'd128,1'b0,7'd100,8'd255})) u_brightness_cdc (
    .src_clk(sd_card_clk), .src_rst_n(sdcard_rst_n),
    .src_page({brightness_adjust_mode,brightness_percent_sd,brightness_setting_sd,
               contrast_adjust_mode,contrast_percent_sd,contrast_setting_sd,
               volume_adjust_mode,volume_percent_sd,volume_setting_sd}),
    .pix_clk(video_clk), .pix_rst_n(video_rst_n), .frame_start(frame_start),
    .pix_page({brightness_adjust_mode_video,brightness_percent_video,brightness_setting_video,
               contrast_adjust_mode_video,contrast_percent_video,contrast_setting_video,
               volume_adjust_mode_video,volume_percent_video,volume_setting_video})
);

guide_controller u_guide_controller (
    .clk(sd_card_clk), .rst(~sdcard_rst_n),
    .next_event(1'b0), .toggle_auto_event(1'b0),
    .toggle_emergency_event(emergency_toggle_event),
    .error_active(|media_error_code),
    .state(guide_state), .next_page_pulse(),
    .auto_play_enabled(), .emergency_active(emergency_active_ctrl),
    .emergency_enter_pulse(emergency_enter_event),
    .emergency_exit_pulse(emergency_exit_event)
);

// Keep the functional framebuffer switch on the P1-proven path. OSD status
// transport must not sit inside the reader acknowledgement loop.
sync_2ff u_display_valid_video_sync (
    .clk        (video_clk),
    .rst_n      (video_rst_n),
    .async_in   (display_valid),
    .sync_out   (display_valid_video)
);

page_switch_cdc #(.WIDTH(32), .RESET_VALUE(32'd0)) u_page_switch_cdc (
    .src_clk(sd_card_clk), .src_rst_n(sdcard_rst_n),
    .src_page({roi_mode,roi_display_zoom ? roi_display_grid_x : roi_grid_x,
               roi_display_zoom ? roi_display_grid_y : roi_grid_y,
               roi_size_units,roi_display_units,roi_display_zoom,roi_busy,
               instant_switch_sd, reverse_switch_sd, manual_switch_sd, disp_buf_idx}),
    .pix_clk(video_clk), .pix_rst_n(video_rst_n), .frame_start(frame_start),
    .pix_page({roi_mode_video,roi_grid_x_video,roi_grid_y_video,roi_size_video,
               roi_display_units_video,roi_display_zoom_video,roi_busy_video,
               instant_switch_video, reverse_switch_video, manual_switch_video, disp_buf_idx_video})
);

// display_valid is generated in the SD-card domain and enables the SDRAM
// reader. Synchronize it independently into the memory domain so no SD-domain
// level participates in 125 MHz reader control logic.
sync_2ff u_display_valid_mem_sync (
    .clk        (ext_mem_clk),
    .rst_n      (mem_rst_n),
    .async_in   (display_valid),
    .sync_out   (display_valid_mem)
);

sync_2ff u_audio_active_sd_sync (
    .clk        (sd_card_clk),
    .rst_n      (sdcard_rst_n),
    .async_in   (wav_audio_active),
    .sync_out   (wav_audio_active_sd)
);

sync_2ff u_display_valid_sys_sync (
    .clk        (clk),
    .rst_n      (sys_rst_n),
    .async_in   (display_valid),
    .sync_out   (display_valid_sys)
);

sync_2ff u_current_image_sync_0 (
    .clk        (clk), .rst_n(sys_rst_n),
    .async_in   (current_image_index[0]),
    .sync_out   (current_image_index_sys[0])
);

sync_2ff u_current_image_sync_1 (
    .clk        (clk), .rst_n(sys_rst_n),
    .async_in   (current_image_index[1]),
    .sync_out   (current_image_index_sys[1])
);

sync_2ff u_current_image_sync_2 (
    .clk        (clk),
    .rst_n      (sys_rst_n),
    .async_in   (current_image_index[2]),
    .sync_out   (current_image_index_sys[2])
);

sync_2ff u_reader_idle_sd_sync (
    .clk        (sd_card_clk),
    .rst_n      (sdcard_rst_n),
    .async_in   (reader_idle_mem),
    .sync_out   (reader_idle_sd)
);

sync_2ff u_fade_transition_active_sd_sync (
    .clk        (sd_card_clk),
    .rst_n      (sdcard_rst_n),
    .async_in   (fade_transition_active || manual_wipe_active),
    .sync_out   (fade_transition_active_sd)
);

// Do not recycle the old display bank until the memory-domain reader has
// accepted the new bank at a video frame boundary.
sync_2ff u_reader_bank_sd_sync_0 (
    .clk        (sd_card_clk),
    .rst_n      (sdcard_rst_n),
    .async_in   (reader_buf_idx_mem[0]),
    .sync_out   (reader_buf_idx_sd[0])
);

sync_2ff u_reader_bank_sd_sync_1 (
    .clk        (sd_card_clk),
    .rst_n      (sdcard_rst_n),
    .async_in   (reader_buf_idx_mem[1]),
    .sync_out   (reader_buf_idx_sd[1])
);

sync_2ff u_state_code_sync_0 (
    .clk        (clk),
    .rst_n      (sys_rst_n),
    .async_in   (state_code[0]),
    .sync_out   (state_code_sys[0])
);

sync_2ff u_state_code_sync_1 (
    .clk        (clk),
    .rst_n      (sys_rst_n),
    .async_in   (state_code[1]),
    .sync_out   (state_code_sys[1])
);

sync_2ff u_state_code_sync_2 (
    .clk        (clk),
    .rst_n      (sys_rst_n),
    .async_in   (state_code[2]),
    .sync_out   (state_code_sys[2])
);

sync_2ff u_state_code_sync_3 (
    .clk        (clk),
    .rst_n      (sys_rst_n),
    .async_in   (state_code[3]),
    .sync_out   (state_code_sys[3])
);

sync_2ff u_sd_write_ack_sync (
    .clk        (sd_card_clk),
    .rst_n      (sdcard_rst_n),
    .async_in   (sd_card_write_req),
    .sync_out   (sd_card_write_req_ack)
);

// mem_clk 域把 write_finish 单拍转成 toggle，供 sd_card_clk 域可靠同步
always @(posedge ext_mem_clk or negedge mem_rst_n) begin
    if (!mem_rst_n)
        frame_write_toggle_mem <= 1'b0;
    else if (frame_write_finish)
        frame_write_toggle_mem <= ~frame_write_toggle_mem;
end

// ===================== TF 8-page index and two-bank page cache =====================
sd_card_bmp #(
    .CLK_FREQ_HZ       (SD_CLK_FREQ_HZ),
    .SD_READ_TIMEOUT_MS(500),
    .AUTO_PLAY_MS      (10000), .NARRATION_BOTH_MODES(1), .ENABLE_AUTO_BGM(1),
    .CACHE_BANKS       (4), .ENABLE_ROI(1), .ENABLE_GALLERY(1),
    .RESIDENT_MODE     (1),.ENABLE_HOME_MENU(1),.ENABLE_NAV_TRANSITION(1)
) sd_card_bmp_m0(
    .clk               (sd_card_clk),
    .rst               (~sdcard_rst_n),
    .sdram_init_done   (Sdr_init_done_sd),
    .reader_idle       (reader_idle_sd),
    .reader_buf_idx    (reader_buf_idx_sd),
    .reader_switch_deferred(fade_transition_active_sd),
    .key_next          (1'b1),
    .key_auto          (1'b1),
    .key_next_event    (media_next_event),
    .key_prev_event    (media_prev_event),
    .key_auto_event    (1'b0),
    .home_auto_run(home_auto_run),.home_auto_paused(home_auto_paused),.home_silent_auto(home_silent_auto),
    .home_audio_mute(home_audio_mute),.bad_page_notice(bad_page_notice),
    .home_navigation_audio_ready(nav_early_audio_sd),.home_navigation_cancel(nav_cancel_sd),
    .home_navigation_keep_audio(nav_keep_audio_sd),
    .hotspot_mode(hotspot_mode_sd),.hotspot_page(hotspot_page_sd),
    .hotspot_region(hotspot_region_sd),.hotspot_replay(hotspot_replay_sd),
    .hotspot_target_pending(hotspot_target_pending_sd),.hotspot_done(hotspot_done_sd),
    .hotspot_video_ready(hotspot_video_ready_sd),
    .hotspot_missing_audio(hotspot_missing_audio_sd),
    .home_navigation_busy(home_navigation_busy),.home_auto_step(home_auto_step),
    .gallery_active(gallery_active),
    .gallery_select_valid(gallery_select_valid && nav_select_enable && !nav_cancel_sd), .gallery_select_page(gallery_select_page),
    .gallery_select_ready(gallery_select_ready), .gallery_resource_mask(gallery_resource_mask),
    .failed_page_mask(failed_page_mask),
    .thumbnail_ready_mask(thumbnail_ram_ready_mask),
    .thumbnail_start(thumbnail_start), .thumbnail_commit(thumbnail_commit),
    .thumbnail_page(thumbnail_page), .thumbnail_pixel_valid(thumbnail_pixel_valid),
    .thumbnail_pixel_rgb(thumbnail_pixel_rgb),
    .roi_active(roi_active), .roi_zoom(roi_zoom_requested),
    .roi_request_valid(roi_request_valid), .roi_request_ready(roi_request_ready),
    .roi_x(roi_x), .roi_y(roi_y), .roi_width(roi_width), .roi_height(roi_height),
    .roi_units(roi_request_units), .roi_display_units(roi_display_units),
    .roi_grid_x(roi_request_grid_x), .roi_grid_y(roi_request_grid_y),
    .roi_display_grid_x(roi_display_grid_x), .roi_display_grid_y(roi_display_grid_y),
    .roi_available(roi_available), .roi_busy(roi_busy), .roi_source_step(roi_source_step),
    .roi_display_zoom(roi_display_zoom), .instant_switch(instant_switch_sd),
    .emergency_enter   (emergency_enter_event),
    .emergency_exit    (emergency_exit_event),
    .emergency_active  (emergency_active_media),
    .state_code        (state_code),
    .bmp_width         (16'd1280),
    .bmp_height        (16'd720),
    .display_valid     (display_valid),
    .image_count       (),
    .current_image_index(current_image_index),
    .auto_play_en      (media_auto_play_en),
    .media_error_code  (media_error_code),
    .fault_notice_state(fault_notice_state_sd),
    .fault_notice_epoch(fault_notice_epoch_sd),

    .write_finish_toggle(frame_write_toggle_mem),
    .write_abort_toggle(frame_write_abort_toggle),
    .write_abort_ack_toggle(frame_write_abort_ack_toggle),
    .write_buf_idx     (write_buf_idx),
    .disp_buf_idx      (disp_buf_idx),
    .manual_switch     (manual_switch_sd),
    .reverse_switch    (reverse_switch_sd),

    .write_req         (sd_card_write_req),
    .write_req_ack     (sd_card_write_req_ack),
    .write_ready       (sd_card_write_ready),
    .write_v_flip      (sd_card_write_v_flip),
    .write_en          (sd_card_write_en),
    .write_data        (sd_card_write_data),
    .resident_ready_mask(resident_ready_mask_sd),
    .resident_error_mask(resident_error_mask_sd),
    .resident_request_valid(resident_request_valid),
    .resident_request_accepted(resident_request_accepted),
    .resident_load_slot(resident_load_slot),
    .resident_load_flip(resident_load_flip),
    .resident_pixel_last(sd_card_write_last),
    .resident_source_error(resident_source_error),
    .SD_nCS            (sd_ncs),
    .SD_DCLK           (sd_dclk),
     .SD_MOSI           (sd_mosi),
     .SD_MISO           (sd_miso),
     .audio_rd_clk      (video_clk),
     .audio_rst_n       (video_rst_n),
     .audio_sample_tick (tone_sample_valid),
     .audio_sample_valid(wav_audio_valid),
     .audio_left_data   (wav_audio_left),
     .audio_right_data  (wav_audio_right),
     .audio_active      (wav_audio_active),
     .audio_done        (wav_audio_done),
     .audio_playback_start(wav_playback_start),
     .audio_sample_consumed(wav_sample_consumed), .audio_page(wav_audio_page),
     .audio_underflow_count(wav_audio_underflow_count),
     .bgm_left_data(bgm_left_pcm), .bgm_right_data(bgm_right_pcm)
);

seg_decoder seg_decoder_status(
    .bin_data          (display_valid_sys ? current_image_display_sys :
                                             state_code_sys),
    .seg_data          (seg_data_status)
);

seg_scan seg_scan_m0(
    .clk               (clk),
    .rst_n             (sys_rst_n),
    .seg_sel           (seg_sel),
    .seg_data          (seg_data),
    .seg_data_0        ({1'b1,7'b1111_111}),
    .seg_data_1        ({1'b1,7'b1111_111}),
    .seg_data_2        ({1'b1,7'b1111_111}),
    .seg_data_3        ({1'b1,7'b1111_111}),
    .seg_data_4        ({1'b1,7'b1111_111}),
    .seg_data_5        ({1'b1,seg_data_status})
);

// ===================== Two-bank image cache =====================
// Eight resources are discovered on the SD card. The selected image is loaded
// into the inactive SDRAM bank while the current bank remains on screen.
wire raw_hs;
wire raw_vs;
wire raw_de;
wire [11:0] timing_x;
wire [11:0] timing_y;
wire [11:0] active_x;
wire [11:0] active_y;
reg [11:0] subtitle_x_early, subtitle_y_early;
reg raw_vs_d;
wire osd_in_hs;
wire osd_in_vs;
wire osd_in_de;
wire osd_in_pixel_valid;
wire [11:0] osd_in_x;
wire [11:0] osd_in_y;
wire [23:0] osd_in_rgb;
reg osd_pipe_hs, osd_pipe_vs, osd_pipe_de;
reg [11:0] osd_pipe_x, osd_pipe_y;
reg [23:0] osd_pipe_rgb;
wire [23:0] reader_rgb;
wire reader_pixel_valid;
wire osd_frame_commit;
wire osd_hs;
wire osd_vs;
wire osd_de;
wire [23:0] osd_rgb;
wire [23:0] osd_brightness_rgb;
wire osd_brightness_active;
wire [23:0] osd_base_rgb;
wire osd_base_active;
wire roi_overlay_hit;
wire [23:0] roi_overlay_color;
wire hotspot_overlay_hit;
wire [23:0] hotspot_overlay_color;
wire hotspot_text_hit;
wire [23:0] hotspot_text_color;
wire route_overlay_hit;
wire [23:0] route_overlay_color;
wire emergency_route_hit;
wire [23:0] emergency_route_color;
wire waveform_hit;
wire [23:0] waveform_color;
reg roi_overlay_hit_q;
reg [23:0] roi_overlay_color_q;
reg hotspot_overlay_hit_q;
reg [23:0] hotspot_overlay_color_q;
reg hotspot_text_hit_q;
reg [23:0] hotspot_text_color_q;
wire        adjusted_hs;
wire        adjusted_vs;
wire        adjusted_de;
wire [23:0] adjusted_rgb;
wire        faded_hs;
wire        faded_vs;
wire        faded_de;
wire [23:0] faded_rgb;
wire [7:0]  fade_alpha;
reg         osd_adjust_hs;
reg         osd_adjust_vs;
reg         osd_adjust_de;
reg  [23:0] osd_adjust_rgb;
reg  [23:0] osd_adjust_brightness_rgb;
reg osd_adjust_brightness_active;
reg [23:0] osd_adjust_base_rgb;
reg osd_adjust_base_active;
wire [7:0]  picture_brightness;
wire [7:0]  picture_contrast;
reg         emergency_video_sync1;
wire [3:0] osd_status_media_id = osd_media_id == 4'd8 ? 4'd8 :
                                  (osd_media_id[2:0] == 3'd7 ? 4'd6 : osd_media_id);
wire [1:0] osd_display_bank;
wire osd_auto_enabled;
wire osd_audio_active;
wire narration_subtitle_hit;
wire welcome_subtitle_hit;
reg welcome_subtitle_hit_q;
wire [23:0] narration_subtitle_color;
wire osd_emergency_active;
wire [7:0] osd_error_code;

always @(posedge video_clk or negedge video_rst_n) begin
    if (!video_rst_n) begin
        emergency_video_sync1 <= 1'b0;
        emergency_video_sync2 <= 1'b0;
    end else begin
        emergency_video_sync1 <= emergency_active_ctrl;
        emergency_video_sync2 <= emergency_video_sync1;
    end
end

video_timing_ctrl #(
    .H_ACT(1280), .H_FP(110), .H_SYNC(40), .H_BP(220),
    .V_ACT(720), .V_FP(5), .V_SYNC(5), .V_BP(20),
    .ACTIVE_LAST(1)
) u_video_timing_ctrl (
    .pclk(video_clk), .rst_n(video_rst_n),
    .hsync(raw_hs), .vsync(raw_vs), .de(raw_de),
    .x(timing_x), .y(timing_y)
);

always @(posedge video_clk or negedge video_rst_n) begin
    if (!video_rst_n)
        raw_vs_d <= 1'b1;
    else
        raw_vs_d <= raw_vs;
end
media_video_input u_media_video_input (
    .clk(video_clk),.rst_n(video_rst_n),
    .in_hs(raw_hs),.in_vs(raw_vs),.in_de(raw_de),
    .pixel_x(active_x),.pixel_y(active_y),
    .image_available(osd_display_valid),.pixel_valid(reader_pixel_valid),
    .rgb_in(reader_rgb),.out_hs(osd_in_hs),.out_vs(osd_in_vs),
    .out_de(osd_in_de),.out_pixel_valid(osd_in_pixel_valid),
    .out_x(osd_in_x),.out_y(osd_in_y),.rgb_out(osd_in_rgb)
);
assign frame_start = raw_vs_d && !raw_vs;
assign active_x = raw_de ? timing_x - 12'd370 : 12'd0;
assign active_y = raw_de ? timing_y - 12'd30 : 12'd0;
always @(posedge video_clk or negedge video_rst_n) begin
    if (!video_rst_n) begin
        subtitle_x_early<=0;
        subtitle_y_early<=0;
    end else begin
        subtitle_x_early<=timing_x-12'd369;
        subtitle_y_early<=timing_y-12'd30;
    end
end
assign osd_frame_commit = timing_x == 12'd369 && timing_y == 12'd30;

// Match the registered thumbnail address and synchronous RAM read. Delay
// the entire raster so normal images, overlays and sync remain aligned.
always @(posedge video_clk or negedge video_rst_n) begin
    if (!video_rst_n) begin
        osd_pipe_hs<=1;osd_pipe_vs<=1;osd_pipe_de<=0;
        osd_pipe_x<=0;osd_pipe_y<=0;osd_pipe_rgb<=0;
    end else begin
        osd_pipe_hs<=osd_in_hs;osd_pipe_vs<=osd_in_vs;osd_pipe_de<=osd_in_de;
        osd_pipe_x<=osd_in_x;osd_pipe_y<=osd_in_y;osd_pipe_rgb<=osd_in_rgb;
    end
end

audio_waveform_overlay u_audio_waveform (
    .clk(video_clk), .rst_n(video_rst_n), .sample_valid(audio_valid),
    .left_pcm(audio_left_data[23:8]), .right_pcm(audio_right_data[23:8]),
    .pixel_x_early(osd_in_x), .pixel_x(osd_pipe_x), .pixel_y(osd_pipe_y),
    .in_de(osd_pipe_de && !emergency_video_sync2),
    .hit(waveform_hit), .color(waveform_color)
);

page_switch_cdc #(.WIDTH(33), .RESET_VALUE(33'd0)) u_resident_descriptor_cdc (
    .src_clk(sd_card_clk),.src_rst_n(sdcard_rst_n),
    .src_page({display_valid,
               emergency_active_media ? 3'd7 :
                   (current_image_index==7 ? 3'd6 : current_image_index),
               emergency_active_media,1'b0,roi_display_zoom,
               roi_display_grid_x,roi_display_grid_y,roi_display_units,
               reverse_switch_sd,(instant_switch_sd || nav_active_sd),
               (nav_active_sd && nav_profile_sd==1 ? 2'd1 :
                nav_active_sd && nav_profile_sd==3 ? 2'd2 : 2'd0),nav_index_sd}),
    .pix_clk(ext_mem_clk),.pix_rst_n(mem_rst_n),
    .frame_start(resident_frame_tick),
    .pix_page({resident_display_valid_mem,resident_display_slot_mem,
               resident_emergency_mem,resident_gallery_mem,resident_roi_mem,
               resident_grid_x_mem,resident_grid_y_mem,resident_units_mem,
               resident_reverse_mem,resident_instant_mem,
               resident_return_kind_mem,resident_return_index_mem})
);
resident_display_engine u_resident_display_engine (
    .mem_clk(ext_mem_clk),.mem_rst_n(mem_rst_n),
    .pix_clk(video_clk),.pix_rst_n(video_rst_n),
    .controller_init_done(Sdr_init_done),.controller_busy(Sdr_busy),
    .refresh_active(Sdr_init_ref_vld),.writer_busy(resident_writer_busy),
    .sdram_rd_valid(Sdr_rd_en),.sdram_rd_data(Sdr_rd_dout),
    .app_rd_en(App_rd_en),.app_rd_addr(App_rd_addr),
    .frame_start(frame_start),.mem_frame_tick(resident_frame_tick),
    .pixel_de(raw_de),.pixel_x(active_x[10:0]),
    .pixel_line_y(timing_y>=30 && timing_y<750 ? timing_y[9:0]-10'd30 : 10'd0),
    .descriptor_valid(resident_display_valid_mem),
    .descriptor_slot(resident_display_slot_mem),
    .descriptor_emergency(resident_emergency_mem),
    .descriptor_gallery(resident_gallery_mem),.descriptor_roi(resident_roi_mem),
    .descriptor_grid_x(resident_grid_x_mem),.descriptor_grid_y(resident_grid_y_mem),
    .descriptor_units(resident_units_mem),
    .descriptor_reverse(resident_reverse_mem),
    .descriptor_instant(resident_instant_mem),
    .descriptor_return_kind(resident_return_kind_mem),
    .descriptor_return_index(resident_return_index_mem),
    .descriptor_ready_mask(resident_ready_mask_mem),
    .pixel_rgb(reader_rgb),.pixel_valid(reader_pixel_valid),
    .underflow(resident_underflow),.reader_busy(resident_reader_busy),
    .reader_urgent(reader_urgent),.transition_active(manual_wipe_active),
    .displayed_slot(resident_shown_slot_mem),.displayed_valid(resident_shown_valid_mem),
    .displayed_emergency(resident_shown_emergency_mem),.displayed_roi(resident_shown_roi_mem),
    .overview_read_address(resident_overview_address),
    .overview_rgb(resident_overview_rgb),
    .overview_ready(resident_overview_ready),
    .overview_slot(resident_overview_slot)
);
assign reader_buf_idx_mem=0;
assign reader_fade_bank_mem=0;
assign reader_idle_mem=!resident_reader_busy;
assign reader_command_busy=resident_reader_busy;
assign manual_page_pulse=0;

// A held, atomic acknowledgement of the actual display configuration. This
// also closes the gap before the first wipe frame reaches the control clock.
page_switch_cdc #(.WIDTH(7),.RESET_VALUE(7'd0)) u_home_display_ack (
    .src_clk(ext_mem_clk),.src_rst_n(mem_rst_n),
    .src_page({resident_shown_valid_mem,resident_shown_slot_mem,
               resident_shown_emergency_mem,resident_shown_roi_mem,manual_wipe_active}),
    .pix_clk(sd_card_clk),.pix_rst_n(sdcard_rst_n),.frame_start(1'b1),
    .pix_page({home_shown_valid_sd,home_shown_slot_sd,home_shown_emergency_sd,
               home_shown_roi_sd,home_transition_sd})
);

guide_status_cdc u_guide_status_cdc (
    .src_clk                  (sd_card_clk),
    .src_rst_n                (sdcard_rst_n),
    // Regular pages are displayed as 1..7 after removing the former page 7.
    // EMERG.BMP remains the ninth resource internally, while PIC8 keeps its
    // original media slot for audio/subtitle compatibility.
    .src_media_id             (osd_media_code),
    .src_display_bank         (disp_buf_idx),
    .src_display_valid        (display_valid),
    .src_auto_enabled         (media_auto_play_en),
    .src_audio_active         (wav_audio_active_sd),
    // Show the built-in warning immediately, then remove it once EMERG.BMP
    // has committed so the authored emergency artwork remains unobstructed.
    .src_emergency_active     (emergency_warning_active),
    .src_error_code           (media_error_code),
    .src_busy                 (),
    .pix_clk                  (video_clk),
    .pix_rst_n                (video_rst_n),
    .frame_start              (frame_start),
    .active_media_id          (osd_media_id),
    .active_display_bank      (osd_display_bank),
    .active_display_valid     (osd_display_valid),
    .active_auto_enabled      (osd_auto_enabled),
    .active_audio_active      (osd_audio_active),
    .active_emergency_active  (osd_emergency_active),
    .active_error_code        (osd_error_code),
    .status_commit            ()
);

narration_subtitle_overlay #(.CAPTION_BOTTOM_INSET(56),.HOME_MENU_MODE(1)) u_narration_subtitles (
    .clk(video_clk), .rst_n(video_rst_n), .frame_start(frame_start),
    .playback_start(wav_playback_start), .sample_consumed(wav_sample_consumed),
    .audio_active(wav_audio_active), .audio_page(wav_audio_page),
    .hotspot_detail_active(hotspot_mode_video==2),
    .displayed_page(osd_media_id), .auto_enabled(osd_auto_enabled),
    .emergency_active(emergency_video_sync2),
    .gallery_active(home_page_video==1 ||
        (home_busy_video && (!nav_active_video || nav_profile_video>=4))),
    .welcome_enabled(home_welcome_video),
    .large_text(1'b0), .high_contrast(1'b0),
    .in_de(raw_de), .pixel_x(subtitle_x_early), .pixel_y(subtitle_y_early),
    .background_rgb(osd_pipe_rgb), .hit(narration_subtitle_hit),
    .welcome_hit(welcome_subtitle_hit),
    .color(narration_subtitle_color)
);

guide_osd_overlay #(
    .SUBTITLE_ENABLE   (0),
    .BRIGHTNESS_UI_ENABLE(1),
    .BRIGHTNESS_SEPARATE_OUTPUT(1),
    .CONTRAST_UI_ENABLE(1),
    .VOLUME_UI_ENABLE(1),
    .BASE_SEPARATE_OUTPUT(1),
    .STATUS_PIPELINED(1),
    .SUBTITLE_SPEED    (2)
) u_guide_osd_overlay (
    .pclk               (video_clk),
    .rst_n              (video_rst_n),
    .frame_start        (osd_frame_commit),
    .in_hs              (osd_pipe_hs),
    .in_vs              (osd_pipe_vs),
    .in_de              (osd_pipe_de),
    .pixel_x            (osd_pipe_x),
    .pixel_y            (osd_pipe_y),
    .status_pixel_x_early(osd_in_x),
    .status_pixel_y_early(osd_in_y),
    .rgb_in             (osd_pipe_rgb),
    .media_id           (osd_status_media_id),
    .auto_enabled       (osd_auto_enabled),
    .audio_active       (osd_audio_active),
    .emergency_active   (osd_emergency_active),
    .high_contrast_mode (1'b0),
    .large_text_mode    (1'b0),
    .brightness_adjust_enabled((brightness_adjust_mode_video || contrast_adjust_mode_video || volume_adjust_mode_video) && !emergency_video_sync2),
    .brightness_percent(volume_adjust_mode_video ? {1'b0,volume_percent_video} :
                        (contrast_adjust_mode_video ? contrast_percent_video : {1'b0,brightness_percent_video})),
    .contrast_adjust_enabled(contrast_adjust_mode_video),
    .volume_adjust_enabled(volume_adjust_mode_video),
    .error_code         (osd_error_code),
    .out_hs             (osd_hs),
    .out_vs             (osd_vs),
    .out_de             (osd_de),
    .rgb_out            (osd_rgb),
    .brightness_overlay_rgb(osd_brightness_rgb),
    .brightness_overlay_active(osd_brightness_active),
    .base_overlay_rgb(osd_base_rgb),
    .base_overlay_active(osd_base_active),
    .osd_active         ()
);

// Break the OSD coordinate/render path before the arithmetic stage. Keep the
// complete video bundle aligned while adding one pixel clock of latency.
always @(posedge video_clk or negedge video_rst_n) begin
    if (!video_rst_n) begin
        osd_adjust_hs  <= 1'b1;
        osd_adjust_vs  <= 1'b1;
        osd_adjust_de  <= 1'b0;
        osd_adjust_rgb <= 24'd0;
        osd_adjust_brightness_rgb <= 0;
        osd_adjust_brightness_active <= 0;
        osd_adjust_base_rgb <= 0;
        osd_adjust_base_active <= 0;
        roi_overlay_hit_q <= 0;
        hotspot_overlay_hit_q <= 0;
        hotspot_text_hit_q <= 0;
        welcome_subtitle_hit_q <= 0;
        roi_overlay_color_q <= 0;
        hotspot_overlay_color_q <= 0;
        hotspot_text_color_q <= 0;
        gallery_overlay_hit_q <= 0;
        gallery_overlay_color_q <= 0;
    end else begin
        osd_adjust_hs  <= osd_hs;
        osd_adjust_vs  <= osd_vs;
        osd_adjust_de  <= osd_de;
        osd_adjust_rgb <= osd_rgb;
        osd_adjust_brightness_rgb <= osd_brightness_rgb;
        osd_adjust_brightness_active <= osd_brightness_active;
        osd_adjust_base_rgb <= narration_subtitle_hit ? narration_subtitle_color :
                               (waveform_hit ? waveform_color : osd_base_rgb);
        osd_adjust_base_active <= narration_subtitle_hit || waveform_hit || osd_base_active;
        roi_overlay_hit_q <= roi_overlay_hit;
        hotspot_overlay_hit_q <= hotspot_overlay_hit;
        hotspot_text_hit_q <= hotspot_text_hit;
        welcome_subtitle_hit_q <= welcome_subtitle_hit;
        roi_overlay_color_q <= roi_overlay_color;
        hotspot_overlay_color_q <= hotspot_overlay_color;
        hotspot_text_color_q <= hotspot_text_color;
        // The menu bitmap is already paired with the outgoing page. Restore
        // its interactive focus after the contraction has fully settled.
        gallery_overlay_hit_q <= gallery_overlay_hit &&
            !(nav_active_video && (nav_profile_video==1 || nav_profile_video==3) && !nav_complete_video);
        gallery_overlay_color_q <= gallery_overlay_color;
    end
end

page_switch_cdc #(.WIDTH(5), .RESET_VALUE(5'd0)) u_roi_thumbnail_status_cdc (
    .src_clk(video_clk), .src_rst_n(video_rst_n),
    .src_page({roi_thumbnail_ready,roi_thumbnail_page}),
    .pix_clk(sd_card_clk), .pix_rst_n(sdcard_rst_n), .frame_start(1'b1),
    .pix_page({roi_thumbnail_ready_sd,roi_thumbnail_page_sd})
);

page_switch_cdc #(.WIDTH(41), .RESET_VALUE(41'd0)) u_gallery_status_cdc (
    .src_clk(sd_card_clk), .src_rst_n(sdcard_rst_n),
    .src_page({route_select_sd,route_choice_sd,route_type_sd,route_interest_sd,route_station_sd,
               home_state,gallery_selected,current_image_index,display_valid,
               home_navigation_busy,media_auto_play_en,wav_audio_active_sd,media_error_code,
               gallery_resource_mask}),
    .pix_clk(video_clk), .pix_rst_n(video_rst_n), .frame_start(frame_start),
    .pix_page({route_select_video,route_choice_video,route_type_video,route_interest_video,route_station_video,
               home_state_video,gallery_selected_video,home_page_video,home_valid_video,
               home_busy_video,home_auto_video,home_audio_video,home_error_video,
               gallery_resource_video})
);
assign gallery_active_video=(home_state_video==1 || (nav_active_video && nav_profile_video==2)) &&
                            home_page_video==1 && home_valid_video &&
                            (!home_busy_video || nav_active_video);

wire [3:0] gallery_lookup_slot;
wire [6:0] gallery_lookup_x;
wire [6:0] gallery_lookup_y;
gallery_layout u_gallery_lookup (
    .x(active_x), .y(active_y), .tile(), .image_area(), .slot(gallery_lookup_slot),
    .local_x(), .local_y(), .thumb_x(gallery_lookup_x), .thumb_y(gallery_lookup_y)
);
wire [7:0] roi_map_x=timing_x[7:0]-8'd190;
wire [6:0] roi_map_y=timing_y[6:0]-7'd46;
assign thumbnail_ram_ready_mask={resident_ready_mask_sd[6],1'b0,
                                  resident_ready_mask_sd[5:0]};
assign thumbnail_ready_mask=thumbnail_ram_ready_mask;
assign resident_overview_address=({7'd0,roi_map_y}<<7)+
    ({7'd0,roi_map_y}<<5)+{6'd0,roi_map_x};
assign roi_thumbnail_page=resident_overview_slot==6 ? 4'd7 :
                          {1'b0,resident_overview_slot};
assign roi_thumbnail_ready=resident_overview_ready &&
                           osd_media_id==roi_thumbnail_page;
assign roi_thumbnail_rgb=resident_overview_rgb;

home_menu_overlay u_gallery_overlay (
    .pclk(video_clk), .rst_n(video_rst_n),
    .active(gallery_active_video && !route_select_video && !emergency_video_sync2 && !brightness_adjust_mode_video &&
            !contrast_adjust_mode_video && !volume_adjust_mode_video),
    .selected(gallery_selected_video),.resource_mask(gallery_resource_video),
    .in_de(osd_in_de), .pixel_x(osd_in_x), .pixel_y(osd_in_y),
    .hit(gallery_overlay_hit), .color(gallery_overlay_color)
);

roi_zoom_overlay #(.PIPELINED(1)) u_roi_zoom_overlay (
    .pclk(video_clk), .rst_n(video_rst_n), .frame_start(osd_frame_commit),
    .mode(roi_mode_video), .grid_x(roi_grid_x_video), .grid_y(roi_grid_y_video),
    .size_units(roi_size_video), .display_units(roi_display_units_video),
    .display_zoom(roi_display_zoom_video), .busy(roi_busy_video),
    .thumbnail_ready(roi_thumbnail_ready), .thumbnail_rgb(roi_thumbnail_rgb),
    .hidden(emergency_video_sync2 || brightness_adjust_mode_video ||
             contrast_adjust_mode_video || volume_adjust_mode_video),
    .in_de(osd_in_de), .pixel_x(osd_in_x), .pixel_y(osd_in_y),
    .hit(roi_overlay_hit), .color(roi_overlay_color)
);

hotspot_overlay u_hotspot_overlay (
    .pclk(video_clk),.rst_n(video_rst_n),.frame_start(osd_frame_commit),
    .mode(hotspot_mode_video),.page(hotspot_page_video),.region(hotspot_region_video),
    .hidden(emergency_video_sync2 || brightness_adjust_mode_video ||
            contrast_adjust_mode_video || volume_adjust_mode_video ||
            roi_mode_video!=0 || roi_display_zoom_video),
    .in_de(osd_in_de),.pixel_x(osd_in_x),.pixel_y(osd_in_y),
    .background_rgb(osd_in_rgb),
    .hit(hotspot_overlay_hit),.color(hotspot_overlay_color)
);

hotspot_text_overlay u_hotspot_text_overlay (
    .clk(video_clk),.rst_n(video_rst_n),.frame_start(frame_start),
    .mode(hotspot_mode_video),.page(hotspot_page_video),.region(hotspot_region_video),
    .hidden(emergency_video_sync2 || brightness_adjust_mode_video ||
            contrast_adjust_mode_video || volume_adjust_mode_video ||
            roi_mode_video!=0 || roi_display_zoom_video),
    .playback_start(wav_playback_start),.sample_consumed(wav_sample_consumed),
    .audio_active(wav_audio_active),.audio_tag(wav_audio_page),
    .in_de(osd_in_de),.pixel_x(osd_in_x),.pixel_y(osd_in_y),
    .hit(hotspot_text_hit),.color(hotspot_text_color)
);

guide_route_overlay u_guide_route_overlay (
    .clk(video_clk),.rst_n(video_rst_n),.in_de(osd_in_de),
    .route_select(route_select_video),.route_type(route_type_video),
    .route_choice(route_choice_video),.route_station(route_station_video),
    .page(home_page_video),.hotspot_mode(hotspot_mode_video),
    .hidden(emergency_video_sync2 || home_busy_video || !home_valid_video ||
            brightness_adjust_mode_video || contrast_adjust_mode_video ||
            volume_adjust_mode_video || roi_mode_video!=0 || roi_display_zoom_video),
    .high_contrast(1'b0),
    .pixel_x(osd_in_x),.pixel_y(osd_in_y),
    .hit(route_overlay_hit),.color(route_overlay_color)
);

// Require both the media commit and the resident display acknowledgement.
// The renderer is parallel to the existing two video registers, so HDMI
// timing and all other overlay latencies remain aligned.
emergency_route_overlay u_emergency_route_overlay (
    .clk(video_clk),.rst_n(video_rst_n),.frame_start(osd_frame_commit),
    .emergency_active(emergency_video_sync2),
    .media_ready(osd_display_valid && osd_media_id==4'd8 &&
                 !osd_emergency_active && nav_shown_valid_video &&
                 nav_shown_emergency_video && nav_shown_slot_video==3'd7 &&
                 osd_error_code==8'd0),
    .high_contrast(1'b0),
    .in_de(osd_in_de),.pixel_x(osd_in_x),.pixel_y(osd_in_y),
    .background_rgb(osd_in_rgb),
    .hit(emergency_route_hit),.color(emergency_route_color)
);

picture_adjust_control u_picture_adjust_control (
    .clk                     (video_clk),
    .rst_n                   (video_rst_n),
    .frame_start             (osd_frame_commit),
    .brightness_setting      (brightness_setting_video),
    .contrast_setting        (contrast_setting_video),
    .emergency_active_async  (emergency_active_ctrl),
    .brightness              (picture_brightness),
    .contrast                (picture_contrast)
);

// P3 stage. Parameters change only at frame boundaries; emergency playback
// temporarily forces unity settings without losing the selected levels.
brightness_contrast_adjust u_brightness_contrast_adjust (
    .clk                (video_clk),
    .rst_n              (video_rst_n),
    .in_hs              (osd_adjust_hs),
    .in_vs              (osd_adjust_vs),
    .in_de              (osd_adjust_de),
    .rgb_in             (emergency_route_hit ? emergency_route_color :
                        (welcome_subtitle_hit_q ? osd_adjust_base_rgb :
                        (route_overlay_hit ? route_overlay_color :
                        (gallery_overlay_hit_q ? gallery_overlay_color_q :
                        (roi_overlay_hit_q ? roi_overlay_color_q :
                        (hotspot_text_hit_q ? hotspot_text_color_q :
                        (hotspot_overlay_hit_q ? hotspot_overlay_color_q :
                        (osd_adjust_brightness_active ? osd_adjust_brightness_rgb :
                        (osd_adjust_base_active ? osd_adjust_base_rgb : osd_adjust_rgb))))))))),
    .brightness         (picture_brightness),
    .contrast           (picture_contrast),
    .out_hs             (adjusted_hs),
    .out_vs             (adjusted_vs),
    .out_de             (adjusted_de),
    .rgb_out            (adjusted_rgb)
);

// The complete composed frame (including all overlays) enters navigation.
// Reconstruct its active coordinates from the already delayed raster bundle.
always @(posedge video_clk or negedge video_rst_n) begin
    if(!video_rst_n) begin nav_pixel_x<=0;nav_pixel_y<=0;nav_de_d<=0;end
    else begin
        nav_de_d<=adjusted_de;
        nav_pixel_x<=adjusted_de ? nav_pixel_x+1'b1 : 0;
        if(frame_start) nav_pixel_y<=0;
        else if(nav_de_d && !adjusted_de) nav_pixel_y<=nav_pixel_y+1'b1;
    end
end
page_switch_cdc #(.WIDTH(38),.RESET_VALUE(38'd0)) u_navigation_request_cdc (
    .src_clk(sd_card_clk),.src_rst_n(sdcard_rst_n),
    .src_page({nav_active_sd,nav_epoch_sd,nav_profile_sd,nav_direction_sd,
               nav_anchor_x_sd,nav_anchor_y_sd,nav_index_sd,gallery_select_page,
               resident_ready_mask_sd[gallery_select_page==7 ? 3'd6 : gallery_select_page]}),
    .pix_clk(video_clk),.pix_rst_n(video_rst_n),.frame_start(frame_start),
    .pix_page({nav_active_video,nav_epoch_video,nav_profile_video,nav_direction_video,
               nav_anchor_x_video,nav_anchor_y_video,nav_index_video,nav_target_video,nav_target_ready_video})
);
page_switch_cdc #(.WIDTH(5),.RESET_VALUE(5'd0)) u_fault_notice_cdc (
    .src_clk(sd_card_clk),.src_rst_n(sdcard_rst_n),
    .src_page({fault_notice_epoch_sd,fault_notice_state_sd}),
    .pix_clk(video_clk),.pix_rst_n(video_rst_n),.frame_start(frame_start),
    .pix_page({fault_notice_epoch_video,fault_notice_state_video})
);
page_switch_cdc #(.WIDTH(7),.RESET_VALUE(7'd0)) u_navigation_display_cdc (
    .src_clk(ext_mem_clk),.src_rst_n(mem_rst_n),
    .src_page({resident_shown_valid_mem,resident_shown_slot_mem,
               resident_shown_emergency_mem,resident_shown_roi_mem,manual_wipe_active}),
    .pix_clk(video_clk),.pix_rst_n(video_rst_n),.frame_start(frame_start),
    .pix_page({nav_shown_valid_video,nav_shown_slot_video,
               nav_shown_emergency_video,nav_shown_roi_video,nav_shown_wipe_video})
);
navigation_transition_effect u_navigation_transition_effect (
    .clk(video_clk),.rst_n(video_rst_n),.frame_start(frame_start),
    .request_active(nav_active_video),.request_epoch(nav_epoch_video),
    .nav_profile(nav_profile_video),.nav_menu_index(nav_index_video),.nav_direction(nav_direction_video),
    .anchor_x(nav_anchor_x_video),.anchor_y(nav_anchor_y_video),
    .target_ready(nav_target_ready_video),
    .target_committed(nav_shown_valid_video && !nav_shown_emergency_video &&
        !nav_shown_roi_video && !nav_shown_wipe_video &&
        nav_shown_slot_video==(nav_target_video==7 ? 3'd6 : nav_target_video) &&
        osd_display_valid && osd_media_id=={1'b0,nav_target_video} &&
        home_valid_video && home_page_video==nav_target_video),
    .emergency_active(emergency_video_sync2),.cancel(!home_valid_video || home_state_video==4),
    .in_hs(adjusted_hs),.in_vs(adjusted_vs),.in_de(adjusted_de),
    .pixel_x(nav_pixel_x),.pixel_y(nav_pixel_y),.rgb_in(adjusted_rgb),
    .out_hs(nav_hs),.out_vs(nav_vs),.out_de(nav_de),.rgb_out(nav_rgb),
    .nav_busy(nav_busy_video),.commit_ready(nav_commit_video),.audio_ready(nav_audio_video),
    .darken_started(nav_dark_video),
    .complete(nav_complete_video),.failed(nav_failed_video),.ack_epoch(nav_ack_epoch_video),
    .target_reveal_level(nav_reveal_level)
);
page_switch_cdc #(.WIDTH(9),.RESET_VALUE(9'd0)) u_navigation_feedback_cdc (
    .src_clk(video_clk),.src_rst_n(video_rst_n),
    .src_page({nav_ack_epoch_video,nav_commit_video,nav_audio_video,nav_complete_video,nav_failed_video,nav_dark_video}),
    .pix_clk(sd_card_clk),.pix_rst_n(sdcard_rst_n),.frame_start(1'b1),
    .pix_page({nav_ack_epoch_sd,nav_commit_sd,nav_audio_sd,nav_complete_sd,nav_failed_sd,nav_dark_sd})
);

// Keep the existing bank/audio envelope. Navigation owns the visible mask;
// ordinary content wipes retain the original unity RGB path through this stage.
video_fade_transition #(
    // 24 video frames gives about 0.32 s per fade at 74.256 MHz/720p,
    // making the visual and audio envelope clearly perceptible.
    .FADE_FRAMES(24)
) u_video_fade_transition (
    .clk               (video_clk),
    .rst_n             (video_rst_n),
    .frame_start       (frame_start),
    .display_valid     (display_valid_video),
    .emergency_active  (emergency_video_sync2 || instant_switch_video || nav_active_video),
    .desired_bank      (disp_buf_idx_video),
    .reader_bank_async (reader_fade_bank_mem),
    .in_hs             (nav_hs),
    .in_vs             (nav_vs),
    .in_de             (nav_de),
    .rgb_in            (nav_rgb),
    .active_bank       (transition_display_bank),
    .fade_alpha        (fade_alpha),
    .transition_active (fade_transition_active),
    .out_hs            (faded_hs),
    .out_vs            (faded_vs),
    .out_de            (faded_de),
    .rgb_out           (faded_rgb)
);

// The banner is composed after navigation, so black reveal frames and page
// wipes cannot erase it. Its one-cycle ROM read matches the fade stage delay.
reg [10:0] notice_x0, notice_x1, notice_x2;
reg [9:0] notice_y0, notice_y1, notice_y2;
always @(posedge video_clk or negedge video_rst_n) begin
    if (!video_rst_n) begin
        notice_x0<=0;notice_x1<=0;notice_x2<=0;
        notice_y0<=0;notice_y1<=0;notice_y2<=0;
    end else begin
        notice_x0<=nav_pixel_x;notice_x1<=notice_x0;notice_x2<=notice_x1;
        notice_y0<=nav_pixel_y;notice_y1<=notice_y0;notice_y2<=notice_y1;
    end
end
wire notice_de, notice_visible;
wire [23:0] notice_rgb;
fault_notice_overlay u_fault_notice_overlay (
    .clk(video_clk),.rst_n(video_rst_n),.frame_start(frame_start),
    .source_state(fault_notice_state_video),.source_epoch(fault_notice_epoch_video),
    .pcm_consumed(wav_sample_consumed),.pcm_page(wav_audio_page),
    .displayed_page(osd_media_id[2:0]),
    .emergency_active(emergency_video_sync2),.image_available(display_valid_video),
    .narration_expected(home_state_video!=1 && home_state_video!=4),
    .high_contrast(1'b0),
    .in_de(nav_de),.pixel_x(notice_x2),.pixel_y(notice_y2),
    .rgb_in(nav_rgb),.out_de(notice_de),.rgb_out(notice_rgb),
    .notice_visible(notice_visible)
);

rgb_video_adapter u_rgb_video_adapter (
    .pclk(video_clk), .rst_n(video_rst_n),
    .hs_in(faded_hs), .vs_in(faded_vs),
    .de_in(faded_de),
    // Both kinds of page change are composed by the reader. Keep unity RGB
    // on the same registered stage as the existing timing bundle.
    .rgb_in(manual_unity_rgb),
    .video_clk(), .video_hs(hs), .video_vs(vs),
    .video_de(de), .video_rgb(vout_data_raw)
);

// Preserve the original fade controller and audio envelope. Manual pictures
// are already wiped by the reader; this unity stage matches its RGB latency.
assign manual_unity_rgb = notice_de ? notice_rgb : 24'd0;

assign vout_data = vout_data_raw;

resident_load_request_cdc u_resident_load_request_cdc (
    .src_clk(sd_card_clk),.src_rst_n(sdcard_rst_n),
    .src_valid(resident_request_valid),.src_slot(resident_load_slot),
    .src_flip(resident_load_flip),.src_accepted(resident_request_accepted),
    .src_busy(),.mem_clk(ext_mem_clk),.mem_rst_n(mem_rst_n),
    .mem_valid(resident_load_valid_mem),.mem_ready(resident_load_ready_mem),
    .mem_slot(resident_load_slot_mem),.mem_flip(resident_load_flip_mem)
);
resident_image_uploader u_resident_image_uploader (
    .src_clk(sd_card_clk),.src_rst_n(sdcard_rst_n),
    .mem_clk(ext_mem_clk),.mem_rst_n(mem_rst_n),
    .controller_init_done(Sdr_init_done),.controller_busy(Sdr_busy),
    .refresh_active(Sdr_init_ref_vld),
    .reader_busy(resident_reader_busy),.reader_urgent(reader_urgent),
    .load_valid(resident_load_valid_mem),.load_ready(resident_load_ready_mem),
    .load_slot(resident_load_slot_mem),.load_flip(resident_load_flip_mem),
    .pixel_valid(sd_card_write_en),.pixel_last(sd_card_write_last),
    .pixel_ready(sd_card_write_ready),.pixel_rgb(sd_card_write_data[31:8]),
    .source_error(resident_source_error),.cancel(1'b0),
    .load_busy(),.load_done(),.load_failed(),.load_cancelled(),
    .ready_mask(resident_ready_mask_mem),.error_mask(resident_error_mask_mem),
    .all_normal_ready(),.emergency_ready(),
    .write_busy(resident_writer_busy),.app_wr_en(resident_writer_en),
    .app_wr_addr(resident_writer_addr),.app_wr_data(resident_writer_data)
);
page_switch_cdc #(.WIDTH(16),.RESET_VALUE(16'd0)) u_resident_status_cdc (
    .src_clk(ext_mem_clk),.src_rst_n(mem_rst_n),
    .src_page({resident_ready_mask_mem,resident_error_mask_mem}),
    .pix_clk(sd_card_clk),.pix_rst_n(sdcard_rst_n),.frame_start(1'b1),
    .pix_page({resident_ready_mask_sd,resident_error_mask_sd})
);
assign sd_card_write_req_ack_mem=1'b0;
assign frame_write_finish=1'b0;
assign frame_write_abort_ack_toggle=1'b0;
assign App_wr_en=resident_writer_en;
assign App_wr_addr=resident_writer_addr;
assign App_wr_din=resident_writer_data;
assign App_wr_dm=4'd0;

sdram U3(
    .Clk               (ext_mem_clk),
    .Clk_sft           (ext_mem_clk_sft),
    .Rst               (~mem_rst_n),
    .Sdr_init_done     (Sdr_init_done),
    .Sdr_init_ref_vld  (Sdr_init_ref_vld),
    .Sdr_busy          (Sdr_busy),
    .App_wr_en         (App_wr_en),
    .App_wr_addr       (App_wr_addr),
    .App_wr_dm         (App_wr_dm),
    .App_wr_din        (App_wr_din),
    .App_rd_en         (App_rd_en),
    .App_rd_addr       (App_rd_addr),
    .Sdr_rd_en         (Sdr_rd_en),
    .Sdr_rd_dout       (Sdr_rd_dout)
);

// The tone generator supplies the exact 48 kHz sample tick. P1 audio data
// always comes from the WAV FIFO; missing, invalid, or drained WAVs are silent.
pcm_audio_tone_pixel #(
    .SAMPLE_PHASE_INC (32'd2776545), // round(48000 / 74250000 * 2^32)
    .AMP               (24'sd2000000)
) u_pcm_audio_tone_pixel (
    .I_clk          (video_clk),
    .I_rst          (~video_rst_n),
    .O_sample_valid (tone_sample_valid),
    .O_left_data    (audio_left_tone_data),
    .O_right_data   (audio_right_tone_data)
);

audio_fade_gain u_audio_fade_gain (
    .clk               (video_clk),
    .rst_n             (video_rst_n),
    .sample_valid      (wav_audio_valid),
    .left_in           (wav_audio_left),
    .right_in          (wav_audio_right),
    .fade_alpha        (fade_alpha),
    .emergency_active  (emergency_video_sync2),
    .sample_valid_out  (faded_audio_valid),
    .left_out          (faded_audio_left),
    .right_out         (faded_audio_right)
);
wire mixed_audio_valid;
wire signed [23:0] mixed_audio_left, mixed_audio_right;
audio_narration_bgm_mix u_audio_narration_bgm_mix (
    .clk(video_clk), .rst_n(video_rst_n),
    .sample_valid(faded_audio_valid), .narration_active(wav_audio_active),
    .emergency_active(emergency_video_sync2),
    .left_in(faded_audio_left), .right_in(faded_audio_right),
    .bgm_left(bgm_left_pcm), .bgm_right(bgm_right_pcm),
    .sample_valid_out(mixed_audio_valid),
    .left_out(mixed_audio_left), .right_out(mixed_audio_right)
);
manual_page_beep u_manual_page_beep (
    .clk(video_clk), .rst_n(video_rst_n),
    .trigger(manual_page_pulse), .emergency_active(emergency_video_sync2),
    .sample_valid(mixed_audio_valid),
    .left_in(mixed_audio_left), .right_in(mixed_audio_right),
    .sample_valid_out(cue_audio_valid),
    .left_out(cue_audio_left), .right_out(cue_audio_right)
);

wire [8:0] user_volume_scale = volume_percent_video == 0 ? 9'd0 :
                             {1'b0,volume_setting_video} + 9'd1;
audio_volume_gain u_audio_volume_gain (
    .clk(video_clk), .rst_n(video_rst_n), .sample_valid(cue_audio_valid),
    .left_in(cue_audio_left), .right_in(cue_audio_right),
    .target_gain(user_volume_scale), .sample_valid_out(audio_valid),
    .left_out(audio_left_data), .right_out(audio_right_data)
);

audio_arc_calculate #(
    .ACR_N         (6144)
) u_audio_arc_calculate (
    .I_clk         (video_clk),
    .I_rst         (~video_rst_n),
    .I_audio_valid (audio_valid),
    .O_acr_valid   (acr_valid),
    .O_acr_cts     (acr_cts),
    .O_acr_n       (acr_n)
);

// ===================== RGB/DE 转 AXIS 视频 =====================
video_rgb_to_axis #(
    .H_ACTIVE(1280)
) u_video_rgb_to_axis(
    .I_clk         (video_clk),
    .I_rst         (~video_rst_n),
    .I_vs          (vs),
    .I_de          (de),
    .I_rgb         (vout_data),
    .O_video_user  (axis_s_user),
    .O_video_valid (axis_s_valid),
    .O_video_last  (axis_s_last),
    .O_video_data  (axis_s_data)
);

// 上电后自动打一拍，触发一次 EDID 读取
startup_pulse #(
    .CNT_MAX(20'd100000)
) u_startup_pulse (
    .I_clk   (video_clk),
    .I_rst   (~video_rst_n),
    .O_pulse (edid_trig)
);

// ===================== 带音频的 HDMI 1.4b 发射 =====================
hdmi_1_4b_transmitter_core_wrapper #(
    .DEVICE                 ( "EG"       ),
    .HTOTAL                 ( 1650       ),
    .HSA                    ( 40         ),
    .HFP                    ( 110        ),
    .HBP                    ( 220        ),
    .HACTIVE                ( 1280       ),
    .VTOTAL                 ( 750        ),
    .VSA                    ( 5          ),
    .VFP                    ( 5          ),
    .VBP                    ( 20         ),
    .VACTIVE                ( 720        ),
    .VIDEO_VIC              ( 4          ),
    .VIDEO_TPG              ( "Disable"  ),
    .VIDEO_FORMAT           ( "RGB"      ),
    .AUDIO_SAMPLE_RATE      ( "48K"      ),
    .IIC_SCL_DIV            ( 750        )
) u_hdmi_1_4b_transmitter_core_wrapper(
    .I_pixel_clk        (video_clk),
    .I_rst              (~video_rst_n),
    .I_edid_read_trig   (edid_trig),
    .O_edid_read_valid  (edid_valid),
    .O_edid_read_data   (edid_data),

    .I_axis_s_user      (axis_s_user),
    .I_axis_s_valid     (axis_s_valid),
    .I_axis_s_last      (axis_s_last),
    .I_axis_s_data      (axis_s_data),
    .O_axis_s_ready     (axis_s_ready),

    .I_audio_valid      (audio_valid),
    .I_audio_left_data  (audio_left_data),
    .I_audio_right_data (audio_right_data),
    .I_acr_valid        (acr_valid),
    .I_acr_cts          (acr_cts),
    .I_acr_n            (acr_n),

    .O_video_locked     (hdmi_video_locked),
    .O_ddc_scl          (HDMI_DDC_SCL),
    .IO_ddc_sda         (HDMI_DDC_SDA),

    .O_ch0_tmds_data    (tmds_ch0_data),
    .O_ch1_tmds_data    (tmds_ch1_data),
    .O_ch2_tmds_data    (tmds_ch2_data),
    .O_clk_tmds_data    (tmds_clk_data)
);

hdmi_phy_wrapper #(
    .DEVICE ( "EG" )
) u_hdmi2phy_wrapper(
    .I_pixel_clk        (video_clk),
    .I_serial_clk       (hdmi_5x_clk),
    .I_pixel_rst        (~video_rst_n),
    .I_serial_rst       (~hdmi_5x_rst_n),
    .I_tmds_channel_0   (tmds_ch0_data),
    .I_tmds_channel_1   (tmds_ch1_data),
    .I_tmds_channel_2   (tmds_ch2_data),
    .I_tmds_channel_clk (tmds_clk_data),
    .O_tmds_ch0_p       (HDMI_D0_P),
    .O_tmds_ch1_p       (HDMI_D1_P),
    .O_tmds_ch2_p       (HDMI_D2_P),
    .O_tmds_clk_p       (HDMI_CLK_P)
);

endmodule

// Hold the bank and transition flags until the pixel domain accepts them
// together at vertical blank. Multi-bit bank changes cannot be torn by CDC.
module page_switch_cdc #(
    parameter integer WIDTH = 4,
    parameter [WIDTH-1:0] RESET_VALUE = 0
) (
    input src_clk, src_rst_n,
    input [WIDTH-1:0] src_page,
    input pix_clk, pix_rst_n, frame_start,
    output reg [WIDTH-1:0] pix_page
);
    reg [WIDTH-1:0] held_page;
    reg request_toggle, ack_toggle;
    reg launch_pending;
    (* async_reg = "true" *) reg ack_sync1, ack_sync2, request_sync1, request_sync2;
    reg request_sync3;
    always @(posedge src_clk or negedge src_rst_n) begin
        if (!src_rst_n) begin
            held_page <= RESET_VALUE;
            request_toggle <= 0;
            launch_pending <= 0;
            ack_sync1 <= 0;
            ack_sync2 <= 0;
        end else begin
            ack_sync1 <= ack_toggle;
            ack_sync2 <= ack_sync1;
            // Hold the complete bundle stable before launching its handshake.
            if (launch_pending) begin
                request_toggle <= ~request_toggle;
                launch_pending <= 0;
            end else if (request_toggle == ack_sync2 && src_page != held_page) begin
                held_page <= src_page;
                launch_pending <= 1;
            end
        end
    end
    always @(posedge pix_clk or negedge pix_rst_n) begin
        if (!pix_rst_n) begin
            request_sync1 <= 0;
            request_sync2 <= 0;
            request_sync3 <= 0;
            ack_toggle <= 0;
            pix_page <= RESET_VALUE;
        end else begin
            request_sync1 <= request_toggle;
            request_sync2 <= request_sync1;
            request_sync3 <= request_sync2;
            if (frame_start && request_sync3 != ack_toggle) begin
                pix_page <= held_page;
                ack_toggle <= request_sync3;
            end
        end
    end
endmodule
