`timescale 1ns/1ps
module guide_route_overlay (
    input wire clk,rst_n,in_de,
    input wire [1:0] route_select,
    input wire [1:0] route_type,
    input wire [2:0] route_choice,
    input wire [2:0] route_station,page,
    input wire [1:0] hotspot_mode,
    input wire hidden,high_contrast,
    input wire [11:0] pixel_x,pixel_y,
    output reg hit,
    output reg [23:0] color
);
    reg panel,text_window,choice_border,choice_fill;
    reg [4:0] line;
    reg [4:0] position;
    reg [11:0] local_x,local_y,glyph_x,glyph_y;
    reg [10:0] x0;
    reg [9:0] y0;
    reg [2:0] kind;
`include "guide_route_font.vh"
    always @* begin
        kind=0;x0=0;y0=0;
        if(route_select==1 && page==1) begin kind=1;x0=330;y0=200;end
        else if(route_select==2 && page==1) begin kind=4;x0=240;y0=145;end
        else if(route_select==3 && page==1) begin kind=5;x0=330;y0=200;end
        else if(route_type!=0 && page!=1) begin
            kind=2;x0=580;y0=16;
        end
        local_x=pixel_x-{1'b0,x0};
        local_y=pixel_y-{2'b0,y0};
        glyph_x=0;glyph_y=0;
        panel=0;text_window=0;choice_border=0;choice_fill=0;line=0;position=0;
        if(kind==1) begin
            panel=local_x<620 && local_y<330;
            if(local_x>=28 && local_x<580) begin
                glyph_x=local_x-12'd32;
                position=glyph_x>>5;
                if(local_y>=32 && local_y<64) begin
                    glyph_y=(local_y-12'd32)>>1;
                    line=0;text_window=1;
                end else if(local_y>=96 && local_y<128) begin
                    glyph_y=(local_y-12'd96)>>1;
                    line=1;text_window=1;
                end else if(local_y>=160 && local_y<192) begin
                    glyph_y=(local_y-12'd160)>>1;
                    line=2;text_window=1;
                end else if(local_y>=256 && local_y<288) begin
                    glyph_y=(local_y-12'd256)>>1;
                    line=3;text_window=1;
                end
            end
            choice_fill=local_x>=20 && local_x<600 &&
                ((local_y>=86 && local_y<142 && route_choice==0) ||
                 (local_y>=150 && local_y<206 && route_choice==1));
            choice_border=choice_fill && local_x<24;
        end else if(kind==5) begin
            panel=local_x<620 && local_y<330;
            if(local_x>=28 && local_x<580) begin
                glyph_x=local_x-12'd32;position=glyph_x>>5;
                if(local_y>=32 && local_y<64) begin glyph_y=(local_y-12'd32)>>1;line=14;text_window=1;end
                else if(local_y>=96 && local_y<128) begin glyph_y=(local_y-12'd96)>>1;line=15;text_window=1;end
                else if(local_y>=160 && local_y<192) begin glyph_y=(local_y-12'd160)>>1;line=16;text_window=1;end
                else if(local_y>=256 && local_y<288) begin glyph_y=(local_y-12'd256)>>1;line=17;text_window=1;end
            end
            choice_fill=local_x>=20 && local_x<600 &&
                ((local_y>=86 && local_y<142 && route_choice==0) ||
                 (local_y>=150 && local_y<206 && route_choice==1));
            choice_border=choice_fill && local_x<24;
        end else if(kind==4) begin
            panel=local_x<800 && local_y<430;
            if(local_x>=32 && local_x<768) begin
                glyph_x=local_x-12'd32;
                position=glyph_x>>5;
                if(local_y>=32 && local_y<64) begin
                    glyph_y=local_y-12'd32;line=4;text_window=1;
                end else if(local_y>=84 && local_y<116) begin
                    line=8;glyph_y=local_y-12'd84;text_window=1;
                end else if(local_y>=132 && local_y<164) begin
                    line=9;glyph_y=local_y-12'd132;text_window=1;
                end else if(local_y>=180 && local_y<212) begin
                    line=10;glyph_y=local_y-12'd180;text_window=1;
                end else if(local_y>=228 && local_y<260) begin
                    line=11;glyph_y=local_y-12'd228;text_window=1;
                end else if(local_y>=276 && local_y<308) begin
                    line=12;glyph_y=local_y-12'd276;text_window=1;
                end else if(local_y>=324 && local_y<356) begin
                    line=13;glyph_y=local_y-12'd324;text_window=1;
                end else if(local_y>=380 && local_y<412) begin
                    line=3;glyph_y=local_y-12'd380;text_window=1;
                end
            end
            choice_fill=local_x>=20 && local_x<780 &&
                local_y>=76+route_choice*48 && local_y<124+route_choice*48;
            choice_border=choice_fill && local_x<24;
        end else if(kind==2) begin
            panel=local_x<160 && local_y<32;
            glyph_x=local_x-12'd16;glyph_y=local_y-12'd8;
            position=glyph_x>>4;
            line=route_type==2 ? 7 : 6;
            text_window=local_x>=16 && local_x<144 && local_y>=8 && local_y<24;
        end
    end
    reg [4:0] line_q;
    reg [4:0] position_q;
    reg [1:0] route_type_q;
    reg [2:0] route_station_q,page_q;
    wire [2:0] full_station=page_q==2 ? 3'd1 : page_q==3 ? 3'd2 :
                            page_q==4 ? 3'd3 : page_q==5 ? 3'd4 : 3'd5;
    wire [6:0] glyph=(line_q==6 || line_q==7) && position_q==5 ?
        route_number(route_type_q!=2 ? full_station : route_station_q+3'd1) :
        route_glyph(line_q,position_q);
    wire [3:0] row=glyph_y[4:1];
    wire [3:0] col=kind==2 ? glyph_x[3:0] : glyph_x[4:1];
    wire [11:0] map_y=pixel_y-12'd200;
    wire [11:0] choice_y=pixel_y-12'd145;
    wire [3:0] map_row=map_y>=32 && map_y<64 ? (map_y-12'd32)>>1 :
                       map_y>=96 && map_y<128 ? (map_y-12'd96)>>1 :
                       map_y>=160 && map_y<192 ? (map_y-12'd160)>>1 :
                       (map_y-12'd256)>>1;
    wire [3:0] choice_row=choice_y>=32 && choice_y<64 ? (choice_y-12'd32)>>1 :
                         choice_y>=84 && choice_y<116 ? (choice_y-12'd84)>>1 :
                         choice_y>=132 && choice_y<164 ? (choice_y-12'd132)>>1 :
                         choice_y>=180 && choice_y<212 ? (choice_y-12'd180)>>1 :
                         choice_y>=228 && choice_y<260 ? (choice_y-12'd228)>>1 :
                         choice_y>=276 && choice_y<308 ? (choice_y-12'd276)>>1 :
                         choice_y>=324 && choice_y<356 ? (choice_y-12'd324)>>1 :
                         (choice_y-12'd380)>>1;
    reg [3:0] map_row_q,choice_row_q,label_row_q;
    reg [2:0] kind_q;
    wire [3:0] row_q=kind_q==1 ? map_row_q :
                     kind_q==4 ? choice_row_q : label_row_q;
    wire [5:0] glyph_index=glyph[5:0]-6'd1;
    wire [9:0] font_address=glyph!=0 && row_q<16 ? {glyph_index,row_q} : 10'd0;
    reg [15:0] font_row;
    reg de_q,panel_q,text_q,border_q,fill_q,contrast_q;
    reg [3:0] col_q;
    reg de_qq,panel_qq,text_qq,border_qq,fill_qq,contrast_qq;
    reg [3:0] col_qq;
    always @(posedge clk) font_row<=font_rows[font_address];
    always @(posedge clk or negedge rst_n) begin
        if(!rst_n) begin
            de_q<=0;panel_q<=0;text_q<=0;border_q<=0;fill_q<=0;contrast_q<=0;
            col_q<=0;line_q<=0;position_q<=0;
            map_row_q<=0;choice_row_q<=0;label_row_q<=0;kind_q<=0;
            route_type_q<=0;route_station_q<=0;page_q<=0;
            de_qq<=0;panel_qq<=0;text_qq<=0;border_qq<=0;fill_qq<=0;contrast_qq<=0;
            col_qq<=0;
        end else begin
            line_q<=line;
            position_q<=position;
            route_type_q<=route_type;
            route_station_q<=route_station;
            page_q<=page;
            map_row_q<=map_row;
            choice_row_q<=choice_row;
            label_row_q<=glyph_y[3:0];
            kind_q<=kind;
            de_q<=in_de;
            panel_q<=panel && !hidden;
            text_q<=text_window && col<16 && row<16;
            border_q<=choice_border;
            fill_q<=choice_fill;
            contrast_q<=high_contrast;
            col_q<=col;
            de_qq<=de_q;
            panel_qq<=panel_q;
            text_qq<=text_q && glyph!=0;
            border_qq<=border_q;
            fill_qq<=fill_q;
            contrast_qq<=contrast_q;
            col_qq<=col_q;
        end
    end
    always @* begin
        hit=de_qq && panel_qq;
        color=text_qq && font_row[15-col_qq] ?
            (contrast_qq ? 24'hffffff : 24'hf2f5ee) :
            border_qq ? (contrast_qq ? 24'hffffff : 24'h67d8c0) :
            fill_qq ? (contrast_qq ? 24'h303030 : 24'h20534f) :
            (contrast_qq ? 24'h000000 : 24'h102a33);
    end
endmodule
