`timescale 1ns/1ps

// One-pixel registered overlay. The media notice is a held state transferred
// through page_switch_cdc; all visible changes commit at a frame boundary.
module fault_notice_overlay (
    input wire clk, rst_n, frame_start,
    input wire [2:0] source_state,
    input wire [1:0] source_epoch,
    input wire pcm_consumed,
    input wire [4:0] pcm_page,
    input wire [2:0] displayed_page,
    input wire emergency_active, image_available, narration_expected, high_contrast,
    input wire in_de,
    input wire [10:0] pixel_x,
    input wire [9:0] pixel_y,
    input wire [23:0] rgb_in,
    output wire out_de,
    output wire [23:0] rgb_out,
    output wire notice_visible
);
    reg [2:0] source_seen;
    reg [1:0] epoch_seen;
    reg [3:0] kind;
    reg [7:0] remaining_frames;
    reg pcm_seen;
    wire current_pcm = pcm_consumed && pcm_page[4:3] == 2'b00 &&
                       pcm_page[2:0] == displayed_page;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            source_seen <= 0;
            epoch_seen <= 0;
            kind <= 0;
            remaining_frames <= 0;
            pcm_seen <= 0;
        end else begin
            if ((kind == 4'd3 || kind == 4'd9) && current_pcm) pcm_seen <= 1;
            if (frame_start) begin
                if (source_state != source_seen || source_epoch != epoch_seen) begin
                    source_seen <= source_state;
                    epoch_seen <= source_epoch;
                    kind <= {1'b0, source_state};
                    remaining_frames <= source_state == 3'd5 ? 8'd240 :
                                        source_state == 3'd3 ? 8'd255 : 8'd180;
                    pcm_seen <= 0;
                end else if ((kind == 4'd3 || kind == 4'd9) && !narration_expected) begin
                    kind <= 4'd7;
                    remaining_frames <= 8'd180;
                    pcm_seen <= 0;
                end else if ((kind == 4'd3 || kind == 4'd9) && pcm_seen) begin
                    kind <= 4'd8;
                    remaining_frames <= 8'd180;
                    pcm_seen <= 0;
                end else if (kind == 4'd3 && remaining_frames != 0) begin
                    remaining_frames <= remaining_frames - 1'b1;
                    if (remaining_frames == 1) kind <= 4'd9;
                end else if (kind >= 4'd4 && kind != 4'd9 && remaining_frames != 0 &&
                             (kind != 4'd5 || image_available)) begin
                    remaining_frames <= remaining_frames - 1'b1;
                    if (remaining_frames == 1) kind <= 0;
                end
            end
        end
    end

`include "fault_notice_codes.vh"

    wire panel = pixel_x >= 11'd32 && pixel_x < 11'd552 &&
                 pixel_y >= 10'd104 && pixel_y < 10'd192;
    wire title_area = pixel_x >= 11'd64 && pixel_x < 11'd384 &&
                      pixel_y >= 10'd112 && pixel_y < 10'd144;
    wire detail_area = pixel_x >= 11'd64 && pixel_x < 11'd384 &&
                       pixel_y >= 10'd158 && pixel_y < 10'd174;
    wire [4:0] title_index = (pixel_x - 11'd64) >> 5;
    wire [4:0] detail_index = (pixel_x - 11'd64) >> 4;
    wire [3:0] row = title_area ? (pixel_y - 10'd112) >> 1 :
                                      pixel_y - 10'd158;
    wire [3:0] col = title_area ? (pixel_x - 11'd64) >> 1 :
                                      pixel_x - 11'd64;
    wire [6:0] glyph_code = title_area ?
        notice_glyph_code(kind, 1'b0, title_index) :
        (detail_area ? notice_glyph_code(kind, 1'b1, detail_index) : 7'd0);
    (* ram_style="bram", rom_style="bram" *) reg [15:0] font_rows [0:1023];
`include "fault_notice_font.vh"
    reg [15:0] font_row_q;
    reg [3:0] col_q;
    reg de_q, panel_q, text_q, border_q, stripe_q, title_q, contrast_q;
    reg [23:0] rgb_q;
    reg [1:0] tone_q;
    // Keep the ROM read free of reset so TD can use the BRAM output register.
    // Reset panel_q/de_q mask the uninitialized output during reset.
    always @(posedge clk)
        font_row_q <= font_rows[{glyph_code[5:0],row}];
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            col_q<=0;de_q<=0;panel_q<=0;text_q<=0;
            border_q<=0;stripe_q<=0;title_q<=0;contrast_q<=0;
            rgb_q<=0;tone_q<=0;
        end else begin
            col_q <= col;
            de_q <= in_de;
            panel_q <= panel && kind != 0 && !emergency_active;
            text_q <= (title_area || detail_area) && glyph_code != 0;
            border_q <= pixel_x == 11'd32 || pixel_x == 11'd551 ||
                        pixel_y == 10'd104 || pixel_y == 10'd191;
            stripe_q <= pixel_x >= 11'd40 && pixel_x < 11'd44;
            title_q <= title_area;
            contrast_q <= high_contrast;
            rgb_q <= rgb_in;
            tone_q <= kind == 4'd8 || kind == 4'd6 || kind == 4'd4 || kind == 4'd7 ? 2'd1 :
                      (kind == 4'd1 || kind == 4'd5 ? 2'd2 : 2'd0);
        end
    end
    wire [23:0] accent = contrast_q ? 24'hffe060 :
        (tone_q == 2'd1 ? 24'h43c7ae :
         (tone_q == 2'd2 ? 24'he6a45c : 24'hf2b544));
    wire ink = text_q && font_row_q[15-col_q];
    assign out_de = de_q;
    assign notice_visible = de_q && panel_q;
    assign rgb_out = !de_q ? 24'h000000 :
        (!panel_q ? rgb_q :
         (ink ? (title_q ? 24'hffffff : (contrast_q ? 24'hffffff : 24'hd6e0e4)) :
          ((stripe_q || border_q) ? accent :
           (contrast_q ? 24'h000000 : 24'h18232b))));
endmodule
