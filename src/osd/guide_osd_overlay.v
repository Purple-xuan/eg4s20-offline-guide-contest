`timescale 1ns/1ps

// Zero-cycle video path. Configuration is synchronous to pclk and commits
// on frame_start; CDC and normalized active-area coordinates belong upstream.
module guide_osd_overlay #(
    parameter integer OSD_X = 16,
    parameter integer OSD_Y = 16,
    parameter integer SCALE = 2,
    parameter integer SUBTITLE_ENABLE = 0,
    parameter integer SUBTITLE_SPEED = 2,
    parameter integer BRIGHTNESS_UI_ENABLE = 0,
    parameter integer BRIGHTNESS_SEPARATE_OUTPUT = 0,
    parameter integer CONTRAST_UI_ENABLE = 0,
    parameter integer VOLUME_UI_ENABLE = 0,
    parameter integer BASE_SEPARATE_OUTPUT = 0,
    parameter integer STATUS_PIPELINED = 0
) (
    input wire pclk,
    input wire rst_n,
    input wire frame_start,
    input wire in_hs,
    input wire in_vs,
    input wire in_de,
    input wire [11:0] pixel_x,
    input wire [11:0] pixel_y,
    input wire [11:0] status_pixel_x_early,
    input wire [11:0] status_pixel_y_early,
    input wire [23:0] rgb_in,
    input wire [3:0] media_id,
    input wire auto_enabled,
    input wire audio_active,
    input wire emergency_active,
    input wire high_contrast_mode,
    input wire large_text_mode,
    input wire brightness_adjust_enabled,
    input wire [7:0] brightness_percent,
    input wire contrast_adjust_enabled,
    input wire volume_adjust_enabled,
    input wire [7:0] error_code,
    output wire out_hs,
    output wire out_vs,
    output wire out_de,
    output wire [23:0] rgb_out,
    output wire [23:0] brightness_overlay_rgb,
    output wire brightness_overlay_active,
    output wire [23:0] base_overlay_rgb,
    output wire base_overlay_active,
    output wire osd_active
);
    reg emergency_q, high_contrast_q, large_text_q;
    reg [11:0] subtitle_offset;
    reg brightness_ui_q;
    reg contrast_ui_q;
    reg volume_ui_q;
    wire volume_ui = VOLUME_UI_ENABLE && volume_adjust_enabled;
    wire contrast_ui = CONTRAST_UI_ENABLE && contrast_adjust_enabled && !volume_ui;
    wire [7:0] display_remainder = brightness_percent >= 100 ?
        brightness_percent - 8'd100 : brightness_percent;
    // All 8-bit input values fit in ten bits after scaling. Keep this small
    // constant operation in the carry chain instead of a routed DSP macro.
    wire [9:0] brightness_scaled = {1'b0, brightness_percent, 1'b0} +
                                   {2'b0, brightness_percent};
    reg [9:0] brightness_fill_top;
    reg [4:0] brightness_hundreds, brightness_tens, brightness_ones;
    reg [34:0] brightness_bits0, brightness_bits1, brightness_bits2, adjustment_label_bits;
    wire [4:0] brightness_tens_next = brightness_percent < 10 ? 5'd20 : display_remainder / 10;
    always @(posedge pclk or negedge rst_n) begin
        if (!rst_n) begin
            emergency_q <= 0;
            high_contrast_q <= 0;
            large_text_q <= 0;
            // Start with the message already visible, then scroll it left.
            subtitle_offset <= 12'd640;
            brightness_ui_q <= 0;
            contrast_ui_q <= 0;
            volume_ui_q <= 0;
            brightness_fill_top <= 180;
            brightness_hundreds <= 1;
            brightness_tens <= 0;
            brightness_ones <= 0;
            brightness_bits0 <= brightness_glyph(1);
            brightness_bits1 <= brightness_glyph(0);
            brightness_bits2 <= brightness_glyph(0);
            adjustment_label_bits <= glyph(5'd11);
        end else if (frame_start) begin
            emergency_q <= emergency_active;
            high_contrast_q <= high_contrast_mode;
            large_text_q <= large_text_mode;
            if (BRIGHTNESS_UI_ENABLE) begin
                brightness_ui_q <= brightness_adjust_enabled;
                contrast_ui_q <= contrast_ui;
                volume_ui_q <= volume_ui;
                brightness_fill_top <= contrast_ui ?
                    10'd630 - brightness_scaled : 10'd480 - brightness_scaled;
                brightness_hundreds <= brightness_percent >= 100 ? 5'd1 : 5'd20;
                brightness_tens <= brightness_percent < 10 ? 5'd20 : display_remainder / 10;
                brightness_ones <= display_remainder % 10;
                brightness_bits0 <= brightness_glyph(brightness_percent >= 100 ? 5'd1 : 5'd20);
                brightness_bits1 <= brightness_glyph(brightness_tens_next);
                brightness_bits2 <= brightness_glyph(display_remainder % 10);
                adjustment_label_bits <= glyph(volume_ui ? 5'd25 : (contrast_ui ? 5'd12 : 5'd11));
            end
            if (subtitle_offset >= (large_text_q ?
                                    (12'd1280 + 12'd320 - SUBTITLE_SPEED) :
                                    (12'd1280 + 12'd160 - SUBTITLE_SPEED)))
                subtitle_offset <= 12'd0;
            else
                subtitle_offset <= subtitle_offset + SUBTITLE_SPEED;
        end
    end

    function integer scale_shift;
        input integer value;
        integer v;
        begin
            scale_shift = 0;
            for (v = value; v > 1; v = v >> 1)
                scale_shift = scale_shift + 1;
        end
    endfunction
    localparam integer SAFE_SCALE = (SCALE > 0) ? SCALE : 1;
    localparam integer SHIFT = scale_shift(SAFE_SCALE);

    // Seven rows, MSB first; each cell is 8x8 with transparent spacing.
    function [34:0] glyph;
        input [4:0] code;
        begin
            case (code)
                0: glyph = {5'b01110,5'b10001,5'b10011,5'b10101,5'b11001,5'b10001,5'b01110};
                1: glyph = {5'b00100,5'b01100,5'b00100,5'b00100,5'b00100,5'b00100,5'b01110};
                2: glyph = {5'b01110,5'b10001,5'b00001,5'b00010,5'b00100,5'b01000,5'b11111};
                3: glyph = {5'b11110,5'b00001,5'b00001,5'b01110,5'b00001,5'b00001,5'b11110};
                4: glyph = {5'b00010,5'b00110,5'b01010,5'b10010,5'b11111,5'b00010,5'b00010};
                5: glyph = {5'b11111,5'b10000,5'b10000,5'b11110,5'b00001,5'b00001,5'b11110};
                6: glyph = {5'b01110,5'b10000,5'b10000,5'b11110,5'b10001,5'b10001,5'b01110};
                7: glyph = {5'b11111,5'b00001,5'b00010,5'b00100,5'b01000,5'b01000,5'b01000};
                8: glyph = {5'b01110,5'b10001,5'b10001,5'b01110,5'b10001,5'b10001,5'b01110};
                9: glyph = {5'b01110,5'b10001,5'b10001,5'b01111,5'b00001,5'b00001,5'b01110};
                10: glyph = {5'b01110,5'b10001,5'b10001,5'b11111,5'b10001,5'b10001,5'b10001};
                11: glyph = {5'b11110,5'b10001,5'b10001,5'b11110,5'b10001,5'b10001,5'b11110};
                12: glyph = {5'b01111,5'b10000,5'b10000,5'b10000,5'b10000,5'b10000,5'b01111};
                13: glyph = {5'b11110,5'b10001,5'b10001,5'b10001,5'b10001,5'b10001,5'b11110};
                14: glyph = {5'b11111,5'b10000,5'b10000,5'b11110,5'b10000,5'b10000,5'b11111};
                15: glyph = {5'b11111,5'b10000,5'b10000,5'b11110,5'b10000,5'b10000,5'b10000};
                16: glyph = {5'b10001,5'b11011,5'b10101,5'b10101,5'b10001,5'b10001,5'b10001}; // M
                17: glyph = {5'b11110,5'b10001,5'b10001,5'b11110,5'b10000,5'b10000,5'b10000}; // P
                18: glyph = {5'b01111,5'b10000,5'b10000,5'b01110,5'b00001,5'b00001,5'b11110}; // S
                19: glyph = {5'b00100,5'b00100,5'b00100,5'b00100,5'b00100,5'b00000,5'b00100}; // !
                21: glyph = {5'b11110,5'b10001,5'b10001,5'b11110,5'b10100,5'b10010,5'b10001}; // R
                22: glyph = {5'b01110,5'b10001,5'b10000,5'b10111,5'b10001,5'b10001,5'b01110}; // G
                23: glyph = {5'b10001,5'b11001,5'b10101,5'b10011,5'b10001,5'b10001,5'b10001}; // N
                24: glyph = {5'b10001,5'b10001,5'b01010,5'b00100,5'b00100,5'b00100,5'b00100}; // Y
                25: glyph = {5'b10001,5'b10001,5'b10001,5'b10001,5'b01010,5'b01010,5'b00100}; // V
                26: glyph = {5'b10001,5'b10001,5'b10001,5'b10001,5'b10001,5'b10001,5'b01110}; // U
                27: glyph = {5'b11111,5'b00100,5'b00100,5'b00100,5'b00100,5'b00100,5'b00100}; // T
                28: glyph = {5'b10001,5'b10001,5'b10001,5'b11111,5'b10001,5'b10001,5'b10001}; // H
                29: glyph = {5'b10000,5'b10000,5'b10000,5'b10000,5'b10000,5'b10000,5'b11111}; // L
                30: glyph = {5'b11001,5'b11010,5'b00100,5'b00100,5'b01000,5'b10110,5'b00110}; // %
                default: glyph = 0;
            endcase
        end
    endfunction

    // Fixed emergency copy uses the same small synthesizable font. Keeping
    // the message in logic makes the first warning independent of TF latency.
    function [4:0] emergency_title_code;
        input [3:0] index;
        begin
            case (index)
                0: emergency_title_code = 5'd14; // E
                1: emergency_title_code = 5'd16; // M
                2: emergency_title_code = 5'd14; // E
                3: emergency_title_code = 5'd21; // R
                4: emergency_title_code = 5'd22; // G
                5: emergency_title_code = 5'd14; // E
                6: emergency_title_code = 5'd23; // N
                7: emergency_title_code = 5'd12; // C
                default: emergency_title_code = 5'd24; // Y
            endcase
        end
    endfunction

    function [4:0] emergency_action_code;
        input [3:0] index;
        begin
            case (index)
                0: emergency_action_code = 5'd14; // E
                1: emergency_action_code = 5'd25; // V
                2: emergency_action_code = 5'd10; // A
                3: emergency_action_code = 5'd12; // C
                4: emergency_action_code = 5'd26; // U
                5: emergency_action_code = 5'd10; // A
                6: emergency_action_code = 5'd27; // T
                default: emergency_action_code = 5'd14; // E
            endcase
        end
    endfunction

    function glyph_pixel;
        input [34:0] bits;
        input [2:0] row;
        input [2:0] col;
        reg [4:0] row_bits;
        begin
            case (row)
                0: row_bits = bits[34:30];
                1: row_bits = bits[29:25];
                2: row_bits = bits[24:20];
                3: row_bits = bits[19:15];
                4: row_bits = bits[14:10];
                5: row_bits = bits[9:5];
                6: row_bits = bits[4:0];
                default: row_bits = 0;
            endcase
            case (col)
                0: glyph_pixel = row_bits[4];
                1: glyph_pixel = row_bits[3];
                2: glyph_pixel = row_bits[2];
                3: glyph_pixel = row_bits[1];
                4: glyph_pixel = row_bits[0];
                default: glyph_pixel = 0;
            endcase
        end
    endfunction

    // Fixed, deliberately small subtitle vocabulary. The text is kept in
    // logic so it is deterministic and does not add a TF/CDC dependency.
    function [4:0] subtitle_code;
        input [3:0] index;
        begin
            case (index)
                0: subtitle_code = 5'd17; // P
                1: subtitle_code = 5'd21; // R
                2: subtitle_code = 5'd14; // E
                3: subtitle_code = 5'd18; // S
                4: subtitle_code = 5'd18; // S
                5: subtitle_code = 5'd20; // space
                6: subtitle_code = 5'd17; // P
                7: subtitle_code = 5'd10; // A
                8: subtitle_code = 5'd22; // G
                9: subtitle_code = 5'd14; // E
                default: subtitle_code = 5'd20;
            endcase
        end
    endfunction

    wire emergency_border = emergency_q &&
        (pixel_x < 12'd24 || pixel_x >= 12'd1256 ||
         pixel_y < 12'd24 || pixel_y >= 12'd696);
    wire emergency_panel = emergency_q &&
        pixel_x >= 12'd328 && pixel_x < 12'd952 &&
        pixel_y >= 12'd246 && pixel_y < 12'd474;
    wire title_box = emergency_q &&
        pixel_x >= 12'd352 && pixel_x < 12'd928 &&
        pixel_y >= 12'd276 && pixel_y < 12'd332;
    wire action_box = emergency_q &&
        pixel_x >= 12'd384 && pixel_x < 12'd896 &&
        pixel_y >= 12'd386 && pixel_y < 12'd442;
    wire [9:0] title_dx = pixel_x - 12'd352;
    wire [8:0] title_dy = pixel_y - 12'd276;
    wire [9:0] action_dx = pixel_x - 12'd384;
    wire [8:0] action_dy = pixel_y - 12'd386;
    wire [3:0] title_char, action_char;
    wire [2:0] title_col, action_col, title_row, action_row;
    generate
        if (STATUS_PIPELINED) begin : g_emergency_geometry_pipeline
            wire [9:0] title_dx_early = status_pixel_x_early - 12'd352;
            wire [8:0] title_dy_early = status_pixel_y_early - 12'd276;
            wire [9:0] action_dx_early = status_pixel_x_early - 12'd384;
            wire [8:0] action_dy_early = status_pixel_y_early - 12'd386;
            reg [3:0] title_char_q, action_char_q;
            reg [2:0] title_col_q, action_col_q, title_row_q, action_row_q;
            always @(posedge pclk or negedge rst_n) begin
                if (!rst_n) begin
                    title_char_q<=0; action_char_q<=0;
                    title_col_q<=0; action_col_q<=0;
                    title_row_q<=0; action_row_q<=0;
                end else begin
                    title_char_q<=title_dx_early[9:6];
                    title_col_q<=title_dx_early[5:3];
                    title_row_q<=title_dy_early[5:3];
                    action_char_q<=action_dx_early[9:6];
                    action_col_q<=action_dx_early[5:3];
                    action_row_q<=action_dy_early[5:3];
                end
            end
            assign title_char=title_char_q;
            assign title_col=title_col_q;
            assign title_row=title_row_q;
            assign action_char=action_char_q;
            assign action_col=action_col_q;
            assign action_row=action_row_q;
        end else begin : g_emergency_geometry_direct
            assign title_char=title_dx[9:6];
            assign title_col=title_dx[5:3];
            assign title_row=title_dy[5:3];
            assign action_char=action_dx[9:6];
            assign action_col=action_dx[5:3];
            assign action_row=action_dy[5:3];
        end
    endgenerate
    wire [34:0] title_bits = glyph(emergency_title_code(title_char));
    wire [34:0] action_bits = glyph(emergency_action_code(action_char));
    wire title_ink = title_box && glyph_pixel(title_bits, title_row, title_col);
    wire action_ink = action_box && glyph_pixel(action_bits, action_row, action_col);
    // Ten 8-pixel cells use 2x scale normally and 4x in large-text mode.
    // The unsigned range checks avoid signed subtractors in the live pixel
    // path while still allowing the message to enter from the right.
    wire [12:0] subtitle_sum = {1'b0, pixel_x} + subtitle_offset;
    wire subtitle_window = SUBTITLE_ENABLE && !emergency_q &&
        pixel_y >= (large_text_q ? 12'd656 : 12'd680) &&
        pixel_y < (large_text_q ? 12'd684 : 12'd694) &&
        subtitle_sum >= 13'd1280 &&
        subtitle_sum < (large_text_q ? 13'd1600 : 13'd1440);
    wire [12:0] subtitle_rel_x = subtitle_sum - 13'd1280;
    wire [3:0] subtitle_char = large_text_q ?
        subtitle_rel_x[8:5] : subtitle_rel_x[7:4];
    wire [2:0] subtitle_col = large_text_q ?
        subtitle_rel_x[4:2] : subtitle_rel_x[3:1];
    wire [2:0] subtitle_row = large_text_q ?
        ((pixel_y - 12'd656) >> 2) : ((pixel_y - 12'd680) >> 1);
    wire [34:0] subtitle_bits = glyph(subtitle_code(subtitle_char));
    wire subtitle_ink = subtitle_window &&
        glyph_pixel(subtitle_bits, subtitle_row, subtitle_col);
    wire emergency_hit = emergency_border || emergency_panel;
    wire high_contrast_subtitle_bg = high_contrast_q && SUBTITLE_ENABLE &&
        !emergency_q &&
        pixel_y >= (large_text_q ? 12'd650 : 12'd674) &&
        pixel_y < (large_text_q ? 12'd692 : 12'd700);
    wire normal_hit = subtitle_ink || high_contrast_subtitle_bg;
    wire brightness_panel = BRIGHTNESS_UI_ENABLE && brightness_ui_q && !emergency_q &&
        pixel_x >= 1152 && pixel_x < 1272 && pixel_y >= 152 && pixel_y < 552;
    wire brightness_track_border = pixel_x >= 1188 && pixel_x < 1236 &&
        pixel_y >= 176 && pixel_y < 484;
    wire brightness_track = pixel_x >= 1192 && pixel_x < 1232 &&
        pixel_y >= 180 && pixel_y < 480;
    wire brightness_fill = brightness_track && pixel_y >= brightness_fill_top;
    wire brightness_text_row = pixel_y >= 504 && pixel_y < 532;
    wire [2:0] brightness_glyph_y;
    wire [2:0] brightness_glyph_x0, brightness_glyph_x1;
    wire [2:0] brightness_glyph_x2, brightness_glyph_x3;
    wire [2:0] adjustment_glyph_y, adjustment_glyph_x;
    generate
        if (STATUS_PIPELINED) begin : g_adjustment_geometry_pipeline
            reg [2:0] row_q, col0_q, col1_q, col2_q, col3_q;
            reg [2:0] label_row_q, label_col_q;
            always @(posedge pclk or negedge rst_n) begin
                if (!rst_n) begin
                    row_q<=0; col0_q<=0; col1_q<=0; col2_q<=0; col3_q<=0;
                    label_row_q<=0; label_col_q<=0;
                end else begin
                    // Prepare coordinates beside the upstream pixel register.
                    row_q <= (status_pixel_y_early - 12'd504) >> 2;
                    col0_q <= (status_pixel_x_early - 12'd1164) >> 2;
                    col1_q <= (status_pixel_x_early - 12'd1188) >> 2;
                    col2_q <= (status_pixel_x_early - 12'd1212) >> 2;
                    col3_q <= (status_pixel_x_early - 12'd1236) >> 2;
                    label_row_q <= (status_pixel_y_early - 12'd156) >> 1;
                    label_col_q <= (status_pixel_x_early - 12'd1207) >> 1;
                end
            end
            assign brightness_glyph_y=row_q;
            assign brightness_glyph_x0=col0_q;
            assign brightness_glyph_x1=col1_q;
            assign brightness_glyph_x2=col2_q;
            assign brightness_glyph_x3=col3_q;
            assign adjustment_glyph_y=label_row_q;
            assign adjustment_glyph_x=label_col_q;
        end else begin : g_adjustment_geometry_combinational
            assign brightness_glyph_y=(pixel_y - 12'd504) >> 2;
            assign brightness_glyph_x0=(pixel_x - 12'd1164) >> 2;
            assign brightness_glyph_x1=(pixel_x - 12'd1188) >> 2;
            assign brightness_glyph_x2=(pixel_x - 12'd1212) >> 2;
            assign brightness_glyph_x3=(pixel_x - 12'd1236) >> 2;
            assign adjustment_glyph_y=(pixel_y - 12'd156) >> 1;
            assign adjustment_glyph_x=(pixel_x - 12'd1207) >> 1;
        end
    endgenerate
    function [34:0] brightness_glyph;
        input [4:0] value;
        begin
            case (value)
                0: brightness_glyph = glyph(0);
                1: brightness_glyph = glyph(1);
                2: brightness_glyph = glyph(2);
                3: brightness_glyph = glyph(3);
                4: brightness_glyph = glyph(4);
                5: brightness_glyph = glyph(5);
                6: brightness_glyph = glyph(6);
                7: brightness_glyph = glyph(7);
                8: brightness_glyph = glyph(8);
                9: brightness_glyph = glyph(9);
                30: brightness_glyph = glyph(30);
                default: brightness_glyph = 0;
            endcase
        end
    endfunction
    wire brightness_text_ink = brightness_text_row && (
        (pixel_x >= 1164 && pixel_x < 1184 &&
         glyph_pixel(brightness_bits0, brightness_glyph_y, brightness_glyph_x0)) ||
        (pixel_x >= 1188 && pixel_x < 1208 &&
         glyph_pixel(brightness_bits1, brightness_glyph_y, brightness_glyph_x1)) ||
        (pixel_x >= 1212 && pixel_x < 1232 &&
         glyph_pixel(brightness_bits2, brightness_glyph_y, brightness_glyph_x2)) ||
        (pixel_x >= 1236 && pixel_x < 1256 &&
         glyph_pixel(glyph(5'd30), brightness_glyph_y, brightness_glyph_x3)));
    // Compact B/C/V indicator identifies the parameter in the shared panel.
    wire adjustment_label_ink = pixel_x >= 1207 && pixel_x < 1217 &&
        pixel_y >= 156 && pixel_y < 170 &&
        glyph_pixel(adjustment_label_bits,
                    adjustment_glyph_y, adjustment_glyph_x);
    wire [23:0] brightness_rgb = brightness_text_ink || brightness_fill || adjustment_label_ink ? 24'hffffff :
        (brightness_track ? 24'h303640 :
         (brightness_track_border ? 24'h78828c : 24'h161a20));
    assign brightness_overlay_rgb = brightness_rgb;
    assign brightness_overlay_active = rst_n && in_de && brightness_panel;
    wire hit = emergency_q ? emergency_hit : normal_hit;
    wire [23:0] osd_rgb = emergency_q ?
                         ((title_ink || action_ink) ? 24'hffffff : 24'hcc0000) :
                         (high_contrast_subtitle_bg && !subtitle_ink ? 24'h000000 :
                          (high_contrast_q ? 24'hffff00 :
                           24'h00ffff));
    wire [23:0] high_contrast_background = {
        1'b0, rgb_in[23:17], 1'b0, rgb_in[15:9], 1'b0, rgb_in[7:1]
    };
    assign base_overlay_rgb = osd_rgb;
    assign base_overlay_active = rst_n && in_de && hit;
    assign out_hs = rst_n ? in_hs : 1'b1;
    assign out_vs = rst_n ? in_vs : 1'b1;
    assign out_de = rst_n && in_de;
    assign osd_active = rst_n && in_de && (hit || brightness_panel);
    assign rgb_out = !out_de ? 24'h000000 :
                     ((!BRIGHTNESS_SEPARATE_OUTPUT && brightness_panel) ? brightness_rgb : ((!BASE_SEPARATE_OUTPUT && hit) ? osd_rgb :
                      ((high_contrast_q && !emergency_q) ?
                       high_contrast_background : rgb_in)));
endmodule
