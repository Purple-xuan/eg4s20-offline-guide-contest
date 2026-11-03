
module top(
    input                       clk,
    input                       rst_n,
    input                       key1,           // 手动下一张
    input                       key2,           // 自动播放 开/关

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
parameter FRAME_PIXELS  = 24'd307200;   // 640*480
parameter BUF0_ADDR     = 24'd0;
parameter BUF1_ADDR     = FRAME_PIXELS;

wire Sdr_init_done;
wire Sdr_init_ref_vld;
wire Sdr_busy;

wire sd_card_clk;
wire ext_mem_clk;
wire ext_mem_clk_sft;
wire video_clk;
wire hdmi_5x_clk;

wire hs;
wire vs;
wire de;

wire [23:0] vout_data_raw;
wire [23:0] vout_data;
wire        display_valid;

wire [3:0]  state_code;
wire [6:0]  seg_data_0;

wire        video_read_req;
wire        video_read_req_ack;
wire        video_read_en;
wire [31:0] video_read_data;

wire        sd_card_write_en;
wire [31:0] sd_card_write_data;
wire        sd_card_write_req;
wire        sd_card_write_req_ack;
wire        frame_write_finish;
reg         frame_write_toggle_mem;

wire [1:0]  write_buf_idx;
wire [1:0]  disp_buf_idx;

wire App_rd_en;
wire [ADDR_BITS-1:0] App_rd_addr;
wire Sdr_rd_en;
wire [MEM_DATA_BITS-1:0] Sdr_rd_dout;
wire App_wr_en;
wire [ADDR_BITS-1:0] App_wr_addr;
wire [MEM_DATA_BITS-1:0] App_wr_din;
wire [3:0] App_wr_dm;

wire hs_0;
wire vs_0;
wire de_0;

// HDMI 1.4b 音频发射相关



// PLL 锁定信号（从 video_pll 引出）
wire video_pll_lock;

// 高有效复位：给老模块用（sd_card_bmp / frame_read_write / sdram / video_delay 等）
// 低有效复位：给完赛 bridge 用
wire rst_all    = ~rst_n;
wire video_rst_n = ~rst_all;                 // 给完赛模块用，低有效
assign HDMI_DDC_SCL = 1'b1;
assign HDMI_DDC_SDA = 1'bz;

// 保持你原来的 TF / SDRAM / video 时钟
sys_pll sys_pll_m0(
    .refclk     (clk),
    .clk0_out   (sd_card_clk),
    .clk1_out   (ext_mem_clk),
    .clk2_out   (ext_mem_clk_sft),
    .reset      (1'b0)
);

video_pll video_pll_m0(
    .refclk     (clk),
    .clk0_out   (video_clk),
    .clk1_out   (hdmi_5x_clk),
    .reset      (1'b0),
    .extlock    (video_pll_lock)   
);



// mem_clk 域把 write_finish 单拍转成 toggle，供 sd_card_clk 域可靠同步
always @(posedge ext_mem_clk or posedge rst_all) begin
    if (rst_all)
        frame_write_toggle_mem <= 1'b0;
    else if (frame_write_finish)
        frame_write_toggle_mem <= ~frame_write_toggle_mem;
end

// ===================== TF 多图扫描与缓存（双缓冲） =====================
sd_card_bmp #(
    .CLK_FREQ_HZ       (100_000_000),
    .SCAN_START_SECTOR (32'd0),
    .SCAN_MAX_SECTOR   (32'd131071),
    .SCAN_TARGET_COUNT (3'd3)
) sd_card_bmp_m0(
    .clk               (sd_card_clk),
    .rst               (rst_all),
    .key_next          (key1),
    .key_auto          (key2),
    .key_next_event    (1'b0),
    .key_auto_event    (1'b0),
    .emergency_enter   (1'b0),
    .emergency_exit    (1'b0),
    .emergency_active  (),
    .state_code        (state_code),
    .bmp_width         (16'd640),
    .bmp_height        (16'd480),
    .display_valid     (display_valid),

    .write_finish_toggle(frame_write_toggle_mem),
    .write_buf_idx     (write_buf_idx),
    .disp_buf_idx      (disp_buf_idx),

    .write_req         (sd_card_write_req),
    .write_req_ack     (sd_card_write_req_ack),
    .write_en          (sd_card_write_en),
    .write_data        (sd_card_write_data),
    .SD_nCS            (sd_ncs),
    .SD_DCLK           (sd_dclk),
    .SD_MOSI           (sd_mosi),
    .SD_MISO           (sd_miso)
);

seg_decoder seg_decoder_m0(
    .bin_data          (state_code),
    .seg_data          (seg_data_0)
);

seg_scan seg_scan_m0(
    .clk               (clk),
    .rst_n             (rst_n),
    .seg_sel           (seg_sel),
    .seg_data          (seg_data),
    .seg_data_0        ({1'b1,7'b1111_111}),
    .seg_data_1        ({1'b1,7'b1111_111}),
    .seg_data_2        ({1'b1,7'b1111_111}),
    .seg_data_3        ({1'b1,7'b1111_111}),
    .seg_data_4        ({1'b1,7'b1111_111}),
    .seg_data_5        ({1'b1,seg_data_0})
);

// ===================== 原图像时序与帧缓存 =====================
video_timing_data video_timing_data_m0(
    .video_clk         (video_clk),
    .rst               (rst_all),
    .read_req          (video_read_req),
    .read_req_ack      (video_read_req_ack),
    .hs                (hs_0),
    .vs                (vs_0),
    .de                (de_0)
);

video_delay video_delay_m0(
    .video_clk         (video_clk),
    .rst               (rst_all),
    .read_en           (video_read_en),
    .read_data         (video_read_data[31:8]),
    .hs                (hs_0),
    .vs                (vs_0),
    .de                (de_0),
    .hs_r              (hs),
    .vs_r              (vs),
    .de_r              (de),
    .vout_data         (vout_data_raw)
);

reg display_valid_sync0, display_valid_sync1;
always @(posedge video_clk or posedge rst_all) begin
    if (rst_all) begin
        display_valid_sync0 <= 1'b0;
        display_valid_sync1 <= 1'b0;
    end else begin
        display_valid_sync0 <= display_valid;
        display_valid_sync1 <= display_valid_sync0;
    end
end

reg  [9:0] video_x_cnt;
reg        de_r_d;
wire       de_r_rising = de & ~de_r_d;   // de_r 上升沿，标志一行 active 开始

always @(posedge video_clk or posedge rst_all) begin
    if (rst_all) begin
        video_x_cnt <= 10'd640;   // 复位后落在 blank 区，等第一个 de_r 上升沿对齐
        de_r_d      <= 1'b0;
    end else begin
        de_r_d <= de;

        if (de_r_rising)
            video_x_cnt <= 10'd1;      // 上升沿这一拍 x=0（用组合逻辑修正），下一拍从 1 开始
        else if (video_x_cnt == 10'd799)
            video_x_cnt <= 10'd640;    // 一行 800 拍走完，回到 blank 起点
        else
            video_x_cnt <= video_x_cnt + 1'b1;
    end
end

wire [9:0] video_x = de_r_rising ? 10'd0 : video_x_cnt;

// 首图提交前黑屏；提交后一直显示当前显示缓冲区内容
assign vout_data = display_valid_sync1 ? vout_data_raw : 24'd0;
frame_read_write #(
    .WRITE_V_FLIP     (1),
    .FRAME_WIDTH      (640),
    .FRAME_HEIGHT     (480)
) frame_read_write_m0(
    .mem_clk           (ext_mem_clk),
    .rst               (rst_all),
    .Sdr_init_done     (Sdr_init_done),
    .Sdr_init_ref_vld  (Sdr_init_ref_vld),
    .Sdr_busy          (Sdr_busy),

    .App_rd_en         (App_rd_en),
    .App_rd_addr       (App_rd_addr),
    .Sdr_rd_en         (Sdr_rd_en),
    .Sdr_rd_dout       (Sdr_rd_dout),

    .read_clk          (video_clk),
    .read_req          (video_read_req),
    .read_req_ack      (video_read_req_ack),
    .read_finish       (),
    .read_addr_0       (BUF0_ADDR),
    .read_addr_1       (BUF1_ADDR),
    .read_addr_2       (24'd0),
    .read_addr_3       (24'd0),
    .read_addr_index   (disp_buf_idx),
    .read_len          (FRAME_PIXELS),
    .read_en           (video_read_en),
    .read_data         (video_read_data),

    .App_wr_en         (App_wr_en),
    .App_wr_addr       (App_wr_addr),
    .App_wr_din        (App_wr_din),
    .App_wr_dm         (App_wr_dm),

    .write_clk         (sd_card_clk),
    .write_req         (sd_card_write_req),
    .write_req_ack     (sd_card_write_req_ack),
    .write_finish      (frame_write_finish),
    .write_addr_0      (BUF0_ADDR),
    .write_addr_1      (BUF1_ADDR),
    .write_addr_2      (24'd0),
    .write_addr_3      (24'd0),
    .write_addr_index  (write_buf_idx),
    .write_len         (FRAME_PIXELS),
    .write_en          (sd_card_write_en),
    .write_data        (sd_card_write_data)
);

sdram U3(
    .Clk               (ext_mem_clk),
    .Clk_sft           (ext_mem_clk_sft),
    .Rst               (rst_all),
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
// 完赛架构：HDMI 音频桥接（含正弦波音源 + 音频包封装 + TMDS 编码）
wire [9:0] bridge_ch0, bridge_ch1, bridge_ch2;
wire       seq_err, tone_ovf, pcm_err, blip_act;
wire       pcm_tap_valid;
wire signed [15:0] pcm_tap_left;

media_hdmi_audio_bridge u_media_bridge (
    .pixel_clk       (video_clk),
    .pixel_rst_n     (video_rst_n),
    .video_hsync     (hs),
    .video_vsync     (vs),
    .video_de        (de),
    .video_x         (video_x),
    .video_rgb       (vout_data),
    .media_id        (disp_buf_idx),
    .volume          (8'd128),
    .channel0_symbol (bridge_ch0),
    .channel1_symbol (bridge_ch1),
    .channel2_symbol (bridge_ch2),
    .sequence_error  (seq_err),
    .tone_overflow   (tone_ovf),
    .pcm_contract_error(pcm_err),
    .blip_active     (blip_act),
    .pcm_tap_valid   (pcm_tap_valid),
    .pcm_tap_left    (pcm_tap_left)
);

wire [9:0] tmds_ch0_data, tmds_ch1_data, tmds_ch2_data, tmds_clk_data;

hdmi_1_4b_transmitter_core_wrapper #(
    .HTOTAL            (800),
    .HSA               (96),
    .HFP               (16),
    .HBP               (48),
    .HACTIVE           (640),
    .VTOTAL            (525),
    .VSA               (2),
    .VFP               (10),
    .VBP               (33),
    .VACTIVE           (480),
    .VIDEO_TPG         ("Disable"),
    .VIDEO_FORMAT      ("RGB"),
    .VIDEO_VIC         (1),
    .AUDIO_SAMPLE_RATE ("48K"),
    .IIC_SCL_DIV       (125)
) u_hdmi_transmitter (
    .I_pixel_clk       (video_clk),
    .I_rst             (rst_all),
    .I_edid_read_trig  (1'b0),
    .O_edid_read_valid(),
    .O_edid_read_data  (),
    .I_axis_s_user     (1'b0),
    .I_axis_s_valid    (1'b0),
    .I_axis_s_last     (1'b0),
    .I_axis_s_data     (24'd0),
    .O_axis_s_ready    (),
    .I_audio_valid     (1'b0),
    .I_audio_left_data (24'd0),
    .I_audio_right_data(24'd0),
    .O_video_locked    (),
    .O_ddc_scl         (),
    .IO_ddc_sda        (),
    .O_ch0_tmds_data   (tmds_ch0_data),
    .O_ch1_tmds_data   (tmds_ch1_data),
    .O_ch2_tmds_data   (tmds_ch2_data),
    .O_clk_tmds_data   (tmds_clk_data)
);




hdmi_phy_wrapper u_hdmi2phy_wrapper(
    .I_pixel_clk      (video_clk),
    .I_serial_clk     (hdmi_5x_clk),
    .I_rst            (rst_all),
    .I_tmds_channel_0  (bridge_ch0),
    .I_tmds_channel_1  (bridge_ch1),
    .I_tmds_channel_2  (bridge_ch2),
    .I_tmds_channel_clk(tmds_clk_data),
    .O_tmds_ch0_p     (HDMI_D0_P),
    .O_tmds_ch1_p     (HDMI_D1_P),
    .O_tmds_ch2_p     (HDMI_D2_P),
    .O_tmds_clk_p     (HDMI_CLK_P)
);
endmodule
