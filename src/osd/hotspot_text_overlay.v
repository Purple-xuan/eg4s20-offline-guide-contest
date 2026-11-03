`timescale 1ns/1ps
module hotspot_text_overlay (
    input wire clk, rst_n, frame_start,
    input wire [1:0] mode,
    input wire [2:0] page,
    input wire [1:0] region,
    input wire hidden,
    input wire playback_start, sample_consumed, audio_active,
    input wire [4:0] audio_tag,
    input wire in_de,
    input wire [11:0] pixel_x, pixel_y,
    output reg hit,
    output reg [23:0] color
);
    wire [2:0] clip = page==2 ? {1'b0,region} :
                       page==4 ? 3'd4+{2'b0,region[0]} :
                                 3'd6+{2'b0,region[0]};
    reg [8:0] sample_divider;
    reg [15:0] elapsed_ticks;
    reg [1:0] cue;
    reg cue_active;
    reg start_q;
    wire [11:0] detail_base,cue_base;
    wire [5:0] detail_len,cue_len;
    wire [15:0] cue_start,cue_end;
    wire [8:0] glyph;
    wire font_bit;
    wire [10:0] panel_x0 = page==2 && region>=2 ? 11'd40 :
                           page==2 ? 11'd853 :
                           region[0] ? 11'd21 : 11'd661;
    wire [11:0] text_x = {1'b0,panel_x0}+12'd16;
    wire [11:0] rel_detail_x=pixel_x-text_x;
    wire [11:0] rel_caption_x=pixel_x-12'd64;
    wire [11:0] rel_detail_y=pixel_y-12'd416;
    wire [11:0] rel_caption_y=pixel_y-12'd646;
    wire detail_window=mode==2 && !hidden && in_de &&
        pixel_y>=416 && pixel_y<608 && pixel_x>=text_x &&
        rel_detail_x<384;
    wire caption_window=mode==2 && !hidden && in_de &&
        audio_active && audio_tag[4:3]==2'b10 && audio_tag[2:0]==clip &&
        pixel_y>=646 && pixel_y<678 && pixel_x>=64 &&
        rel_caption_x<1152 && cue_active;
    // Detail is at y=416..607; caption is at y=646..677.
    wire caption_line=pixel_y[9] && pixel_y[7];
    wire [2:0] detail_line=rel_detail_y[7:5];
    wire [5:0] character=caption_line ? rel_caption_x[10:5] :
                         rel_detail_x[10:5];
    wire [5:0] line_length=caption_line ? cue_len : detail_len;
    wire text_window=(detail_window || caption_window) && character<line_length;
    wire [9:0] text_address=(caption_line ? cue_base : detail_base)+character;
    reg [4:0] font_x_q,font_y_q;
    reg window_q,caption_q,title_q;
    reg window_q2,caption_q2,title_q2;
    wire [3:0] font_col=font_x_q[4:1];
    wire [3:0] font_row=font_y_q[4:1];
    wire in_glyph=font_x_q<32 && font_y_q<32;
    wire [16:0] font_address={glyph,font_row,font_col};

    hotspot_text_data u_data (
        .clk(clk),.clip(clip),.detail_line(detail_line),.cue(cue),
        .detail_base(detail_base),.detail_len(detail_len),
        .cue_base(cue_base),.cue_len(cue_len),
        .cue_start(cue_start),.cue_end(cue_end),
        .text_address(text_address),.glyph(glyph),
        .font_address(font_address),.font_bit(font_bit)
    );
    always @(posedge clk or negedge rst_n) begin
        if(!rst_n) begin
            sample_divider<=0;elapsed_ticks<=0;cue<=0;cue_active<=0;start_q<=0;
            font_x_q<=0;font_y_q<=0;window_q<=0;caption_q<=0;title_q<=0;
            window_q2<=0;caption_q2<=0;title_q2<=0;
            hit<=0;color<=0;
        end else begin
            start_q<=playback_start;
            if(start_q && audio_tag[4:3]==2'b10) begin
                sample_divider<=0;elapsed_ticks<=0;cue<=0;
            end else if(sample_consumed && audio_tag[4:3]==2'b10) begin
                if(sample_divider==479) begin
                    sample_divider<=0;
                    if(elapsed_ticks!=16'hffff) elapsed_ticks<=elapsed_ticks+1'b1;
                end else sample_divider<=sample_divider+1'b1;
            end
            if(elapsed_ticks>=cue_end && cue<2) cue<=cue+1'b1;
            cue_active<=elapsed_ticks>=cue_start && elapsed_ticks<cue_end;
            if(mode!=2 || hidden) begin
                sample_divider<=0;elapsed_ticks<=0;cue<=0;cue_active<=0;
            end
            font_x_q<=caption_line ? rel_caption_x[4:0] : rel_detail_x[4:0];
            font_y_q<=caption_line ? rel_caption_y[4:0] : rel_detail_y[4:0];
            window_q<=text_window;
            caption_q<=caption_window;
            title_q<=detail_window && detail_line==0;
            window_q2<=window_q && in_glyph;
            caption_q2<=caption_q;
            title_q2<=title_q;
            hit<=window_q2 && font_bit;
            color<=caption_q2 || title_q2 ? 24'he8c875 : 24'hf2f5ee;
        end
    end
endmodule
