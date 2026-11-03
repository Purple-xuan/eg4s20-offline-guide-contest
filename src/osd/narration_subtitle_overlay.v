`timescale 1ns/1ps

// Timed Chinese captions. The pixel path matches the two existing raster
// registers between active_x/y and osd_pipe_x/y; no video latency is added.
module narration_subtitle_overlay #(
    parameter integer SAMPLES_PER_TICK = 480,
    parameter integer CAPTION_BOTTOM_INSET = 0,
    parameter integer HOME_MENU_MODE = 0
) (
    input wire clk, rst_n, frame_start,
    input wire playback_start, sample_consumed, audio_active,
    input wire [4:0] audio_page,
    input wire [3:0] displayed_page,
    input wire hotspot_detail_active,
    input wire auto_enabled, emergency_active, gallery_active,
    input wire welcome_enabled,
    input wire large_text, high_contrast,
    input wire in_de,
    input wire [11:0] pixel_x, pixel_y,
    input wire [23:0] background_rgb,
    output wire hit,
    output wire welcome_hit,
    output wire [23:0] color
);
    // Share the caption font port: the welcome strip and captions occupy
    // different scanlines. Prefetch glyphs during horizontal blank so text
    // can pass through the very first column without a pipeline warm-up gap.
    localparam integer WELCOME_WIDTH = HOME_MENU_MODE ? 448 : 352;
    localparam integer WELCOME_END = 1280 + WELCOME_WIDTH - 2;
    reg [10:0] welcome_offset;
    wire [11:0] welcome_left = 12'd1280 - {1'b0,welcome_offset};
    wire [11:0] welcome_x = pixel_x - welcome_left;
    // The welcome strip eases in and out at the screen edges.  The middle
    // section keeps the established two-pixel cadence, while the first and
    // last 96 pixels use one-pixel steps to remove the abrupt start/stop.
    wire [1:0] welcome_step = (welcome_offset < 11'd96 ||
                               welcome_offset > WELCOME_END-96) ? 2'd1 : 2'd2;
    // When the strip is partly off the left edge, skip cells whose end is
    // already behind the two-cycle raster prefetch point.  Floor division
    // keeps a partially visible cell and avoids a clipped-edge gap.
    // Keep the same subtractor/bit-slice structure as the stable release.
    // Adding four before the floor division changes the old ceiling rule to
    // the correct threshold at the two-pixel prefetch boundary.
    wire [11:0] welcome_head = 12'd4094 - welcome_left;
    wire [5:0] welcome_skip = welcome_left[11] ?
        welcome_head[10:5] + (welcome_head[4:0] >= 5'd28) : 6'd0;
    wire [11:0] welcome_scan_start = welcome_left + (welcome_skip << 5);
    wire welcome_y = (!HOME_MENU_MODE || welcome_enabled) &&
                     pixel_y>=12'd52 && pixel_y<12'd92;
    wire welcome_panel = in_de && welcome_y && pixel_x<12'd1280;
    wire welcome_text = welcome_panel && welcome_x<WELCOME_WIDTH;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) welcome_offset<=11'd2;
        else if (frame_start)
            // Offset 2 is the first visible two-pixel step. Wrapping there
            // removes the otherwise blank frame between the last pixels and
            // the next pass entering from the right.
            welcome_offset<=welcome_offset>=WELCOME_END ? 11'd2 :
                welcome_offset+welcome_step;
    end
    reg start_q;
    reg [8:0] sample_divider;
    reg [15:0] elapsed_ticks;
    reg [7:0] cursor, last_cue;
    wire [7:0] first_lookup, last_lookup;
    wire [15:0] cue_start, cue_end;
    wire [11:0] cue_text_base;
    wire [4:0] cue_len0, cue_len1;
    wire [4:0] font_rows;
    reg visible, large_q, contrast_q;
    reg [11:0] text_base;
    reg [4:0] len0, len1;
    (* no_ram *) reg [8:0] active_glyphs [0:35];
    reg [5:0] load_index, load_count;
    reg [11:0] load_base;
    reg load_busy, load_wait, text_ready;
    wire [8:0] loaded_glyph;

    // Fill the current sentence during vertical blank, outside the pixel path.
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            load_index<=0; load_count<=0; load_base<=0;
            load_busy<=0; load_wait<=0; text_ready<=0;
        end else if (frame_start) begin
            load_base<=cue_text_base; load_index<=0;
            load_count<={1'b0,cue_len0}+{1'b0,cue_len1};
            load_busy<=cue_len0!=0; load_wait<=1; text_ready<=0;
        end else if (load_busy) begin
            if (load_wait) load_wait<=0;
            else begin
                if (load_index<36) active_glyphs[load_index]<=loaded_glyph;
                if (load_index+1'b1>=load_count) begin
                    load_busy<=0; text_ready<=1;
                end else begin
                    load_index<=load_index+1'b1; load_wait<=1;
                end
            end
        end
    end

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            start_q<=0; sample_divider<=0; elapsed_ticks<=0;
            cursor<=0; last_cue<=0;
            visible<=0; large_q<=0; contrast_q<=0;
            text_base<=0; len0<=0; len1<=0;
        end else begin
            start_q <= playback_start;
            // The FIFO commits its bundled page tag on playback_start.
            if (start_q) begin
                sample_divider<=0; elapsed_ticks<=0;
                cursor<=first_lookup; last_cue<=last_lookup;
                visible<=0;
            end else begin
                if (sample_consumed) begin
                    if (sample_divider == SAMPLES_PER_TICK-1) begin
                        sample_divider<=0;
                        if (elapsed_ticks!=16'hffff) elapsed_ticks<=elapsed_ticks+1'b1;
                    end else sample_divider<=sample_divider+1'b1;
                end
                if (elapsed_ticks>=cue_end && cursor<last_cue)
                    cursor<=cursor+1'b1;
                if (frame_start) begin
                    visible<=audio_active && audio_page[4:3]==2'b00 &&
                        audio_page[2:0]==displayed_page[2:0] &&
                        !emergency_active && !gallery_active && !hotspot_detail_active &&
                        elapsed_ticks>=cue_start && elapsed_ticks<cue_end && cue_len0!=0;
                    text_base<=cue_text_base; len0<=cue_len0; len1<=cue_len1;
                    large_q<=large_text; contrast_q<=high_contrast;
                end
            end
        end
    end

    wire [11:0] width0 = large_q ? {len0,6'b0} : {len0,5'b0};
    wire [11:0] width1 = large_q ? {len1,6'b0} : {len1,5'b0};
    wire [11:0] left0 = 12'd640 - (width0>>1);
    wire [11:0] left1 = 12'd640 - (width1>>1);
    // Approved content artwork reserves source rows 476..539 as a dark footer.
    wire [11:0] top0 = HOME_MENU_MODE ?
        (len1!=0 ? (large_q ? 12'd578 : 12'd644) :
                   (large_q ? 12'd646 : 12'd660)) :
        (len1!=0 ? (large_q ? 12'd576 : 12'd636) :
                   (large_q ? 12'd640 : 12'd672)) - CAPTION_BOTTOM_INSET;
    wire [11:0] top1 = HOME_MENU_MODE ?
        (large_q ? 12'd646 : 12'd678) :
        (large_q ? 12'd640 : 12'd668) - CAPTION_BOTTOM_INSET;
    wire [11:0] cell_height = large_q ? 12'd64 : 12'd32;
    wire line0 = visible && text_ready && in_de && pixel_x>=left0 && pixel_x<left0+width0 &&
        pixel_y>=top0 && pixel_y<top0+cell_height;
    wire line1 = visible && text_ready && in_de && len1!=0 && pixel_x>=left1 && pixel_x<left1+width1 &&
        pixel_y>=top1 && pixel_y<top1+cell_height;
    reg [5:0] scan_left;
    reg [5:0] scan_character;
    reg [11:0] next_character_x;
    reg [7:0] row_offset;
    reg [16:0] glyph_row_base;
    reg [7:0] outline_row_offset;
    reg [16:0] outline_row_base;
    wire [3:0] outline_row;
    wire second_line_y = len1!=0 && pixel_y>=top1;
    wire [5:0] line_y = pixel_y[5:0] -
        (welcome_y ? 6'd52 : (second_line_y ? top1[5:0] : top0[5:0]));
    wire render_large = large_q && !welcome_y;
    wire [3:0] line_row = welcome_y ? welcome_font_coord(line_y) - 5'd1 :
        (render_large ? line_y>>2 : line_y>>1) - 4'd1;
    wire [8:0] welcome_glyph;
    // Decode the character once and OR masked glyphs in parallel. A variable
    // array read otherwise becomes a deep mux ahead of the row-base adder.
    wire [35:0] scan_select;
    genvar scan_slot;
    generate for (scan_slot=0; scan_slot<36; scan_slot=scan_slot+1) begin: g_scan_select
        assign scan_select[scan_slot] = scan_character == scan_slot;
    end endgenerate
    reg [8:0] caption_scan_glyph;
    integer scan_slot_index;
    always @* begin
        caption_scan_glyph = 9'd0;
        for (scan_slot_index=0; scan_slot_index<36; scan_slot_index=scan_slot_index+1)
            caption_scan_glyph = caption_scan_glyph |
                (active_glyphs[scan_slot_index] & {9{scan_select[scan_slot_index]}});
    end
    wire [8:0] scan_glyph = welcome_y ? welcome_glyph :
        caption_scan_glyph;
    // Select each glyph two pixels before its cell, outside the raster address path.
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            scan_left<=0; scan_character<=0; next_character_x<=0;
            row_offset<=0; glyph_row_base<=0;
            outline_row_offset<=0; outline_row_base<=0;
        end else begin
            if (pixel_x==12'd0) begin
                scan_left<=welcome_y ? welcome_scan_start[5:0] :
                    (second_line_y ? left1[5:0] : left0[5:0]);
                scan_character<=welcome_y ?
                    welcome_skip :
                    (second_line_y ? {1'b0,len0} : 6'd0);
                next_character_x<=welcome_y ?
                    welcome_scan_start+12'd32 :
                    (second_line_y ? left1 : left0)+cell_height;
                row_offset<={line_row,3'b0}+{line_row,1'b0}+line_row;
                outline_row_offset<={outline_row,3'b0}+{outline_row,1'b0}+outline_row;
            end else if (pixel_x==next_character_x-12'd2) begin
                if (scan_character<35) scan_character<=scan_character+1'b1;
                next_character_x<=next_character_x+(welcome_y ? 12'd32 : cell_height);
            end
            glyph_row_base<={scan_glyph,7'b0}+{scan_glyph,2'b0}+row_offset;
            outline_row_base<={scan_glyph,7'b0}+{scan_glyph,2'b0}+outline_row_offset;
        end
    end
    wire [5:0] rel_x = pixel_x[5:0] - scan_left;
    wire [5:0] rel_y = line_y;
    wire [4:0] font_x = welcome_y ? welcome_font_coord({1'b0,rel_x[4:0]})+5'd1 :
        (render_large ? rel_x>>2 : rel_x>>1);
    wire [4:0] font_y = welcome_y ? welcome_font_coord(rel_y) :
        (render_large ? rel_y>>2 : rel_y>>1);
    wire [3:0] glyph_column = font_x[3:0] - 4'd2;
    wire [3:0] glyph_row = font_y[3:0] - 4'd1;
    wire [16:0] font_address = glyph_row_base+glyph_column;
    wire [16:0] outline_address = outline_row_base+glyph_column;
    wire row_first = welcome_y ?
        (line_y==0 || welcome_font_coord(line_y-6'd1)!=font_y) :
        (render_large ? line_y[1:0]==0 : !line_y[0]);
    wire row_last = welcome_y ?
        (welcome_font_coord(line_y+6'd1)!=font_y) :
        (render_large ? line_y[1:0]==3 : line_y[0]);
    assign outline_row = row_first ? glyph_row-4'd1 : glyph_row+4'd1;
    reg panel_q, ink_window_q, contrast_pipe1;
    reg panel_q2, ink_window_q2, contrast_pipe2;
    reg welcome_q, welcome_q2;
    reg [23:0] color_pipe1, color_pipe2;
    wire font_bit;
    wire outline_bit;
    reg outline_window_q;
    reg center_ink_q, left_ink_q, vertical_ink_q;
    reg fade_visible_q, fade_visible_q2;

    // Use exact 2x nearest-neighbor pixels with four-pixel cell padding.
    // The former uneven 2/3-pixel map made fine Chinese strokes look soft.
    function [4:0] welcome_font_coord;
        input [5:0] value;
        begin
            if(value<6'd8) welcome_font_coord=0;
            else if(value<6'd32) welcome_font_coord=((value-6'd8)>>1)+5'd1;
            else welcome_font_coord=5'd15;
        end
    endfunction

    function [2:0] welcome_fade_level;
        input [11:0] value;
        begin
            if (value < 12'd16) welcome_fade_level=3'd0;
            else if (value < 12'd32) welcome_fade_level=3'd1;
            else if (value < 12'd48) welcome_fade_level=3'd2;
            else if (value < 12'd64) welcome_fade_level=3'd3;
            else if (value >= 12'd1264) welcome_fade_level=3'd0;
            else if (value >= 12'd1248) welcome_fade_level=3'd1;
            else if (value >= 12'd1232) welcome_fade_level=3'd2;
            else if (value >= 12'd1216) welcome_fade_level=3'd3;
            else welcome_fade_level=3'd4;
        end
    endfunction

    // Use a compact palette for the four fade steps.  The outside step is
    // the live background, so the glyph enters and leaves without a box;
    // the remaining steps are fixed warm gold shades that synthesize to a
    // small mux instead of 24-bit arithmetic.
    function [23:0] welcome_gradient_color;
        input [2:0] level;
        input [23:0] background;
        begin
            case(level)
                3'd0: welcome_gradient_color=background;
                3'd1: welcome_gradient_color=24'hffe7a0;
                3'd2: welcome_gradient_color=24'hffe7a0;
                3'd3: welcome_gradient_color=24'hffe7a0;
                default: welcome_gradient_color=24'hffe7a0;
            endcase
        end
    endfunction

    wire [2:0] welcome_fade = welcome_fade_level(pixel_x);
    wire [23:0] welcome_color = welcome_gradient_color(welcome_fade,background_rgb);
    wire [23:0] current_color = welcome_panel ? welcome_color :
        (contrast_q ? 24'hffe5a3 : 24'hffd166);
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            outline_window_q<=0; center_ink_q<=0; left_ink_q<=0; vertical_ink_q<=0;
            fade_visible_q<=0; fade_visible_q2<=0;
            panel_q<=0; ink_window_q<=0; contrast_pipe1<=0;
            panel_q2<=0; ink_window_q2<=0; contrast_pipe2<=0;
            welcome_q<=0; welcome_q2<=0;
            color_pipe1<=0; color_pipe2<=0;
        end else begin
            panel_q<=welcome_panel || line0 || line1;
            welcome_q<=welcome_panel; welcome_q2<=welcome_q;
            ink_window_q<=(welcome_text || line0 || line1) && font_x[3:0]>=2 && font_x[3:0]<13 &&
                font_y[3:0]>=1 && glyph_row<font_rows;
            outline_window_q<=(line0 || line1) &&
                font_x[3:0]>=2 && font_x[3:0]<13 && outline_row<font_rows &&
                (row_first || row_last);
            // The two ROM ports provide the next horizontal pixel and the
            // vertical neighbor. Registering the center preserves the existing
            // two-cycle raster alignment and produces a one-screen-pixel edge.
            center_ink_q<=ink_window_q && font_bit;
            left_ink_q<=center_ink_q;
            vertical_ink_q<=outline_window_q && outline_bit;
            fade_visible_q<=!welcome_panel || welcome_fade!=0;
            fade_visible_q2<=fade_visible_q;
            contrast_pipe1<=contrast_q;
            panel_q2<=panel_q; ink_window_q2<=ink_window_q;
            contrast_pipe2<=contrast_pipe1;
            color_pipe1<=current_color;
            color_pipe2<=color_pipe1;
        end
    end
    generate if(HOME_MENU_MODE) begin : home_caption_rom
    home_narration_subtitle_data u_data (
        .clk(clk), .page(audio_page[2:0]), .first_cue(first_lookup), .last_cue(last_lookup),
        .cue(cursor), .start_tick(cue_start), .end_tick(cue_end),
        .text_base(cue_text_base), .len0(cue_len0), .len1(cue_len1),
        .text_address(load_base+load_index), .glyph_index(loaded_glyph), .font_rows(font_rows),
        .welcome_character(scan_character[3:0]), .welcome_glyph(welcome_glyph),
        .font_address(font_address), .font_pixel(font_bit),
        .outline_address(outline_address), .outline_pixel(outline_bit)
    );
    end else begin : legacy_caption_rom
    narration_subtitle_data u_data (
        .clk(clk), .page(audio_page[2:0]), .first_cue(first_lookup), .last_cue(last_lookup),
        .cue(cursor), .start_tick(cue_start), .end_tick(cue_end),
        .text_base(cue_text_base), .len0(cue_len0), .len1(cue_len1),
        .text_address(load_base+load_index), .glyph_index(loaded_glyph), .font_rows(font_rows),
        .welcome_character(scan_character[3:0]), .welcome_glyph(welcome_glyph),
        .font_address(font_address), .font_pixel(font_bit),
        .outline_address(outline_address), .outline_pixel(outline_bit)
    );
    end endgenerate
    wire text_ink = center_ink_q;
    wire text_outline = left_ink_q || (ink_window_q && font_bit) || vertical_ink_q;
    assign hit=rst_n && panel_q2 && fade_visible_q2 &&
        (text_ink || (!welcome_q2 && text_outline));
    assign welcome_hit=hit && welcome_q2;
    assign color=text_ink ? color_pipe2 : 24'h30251b;
endmodule
