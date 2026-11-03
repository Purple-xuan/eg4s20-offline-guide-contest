`timescale 1ns/1ps
// Frame-stable source-image regions. All constants are output coordinates.
module hotspot_overlay (
    input wire pclk, rst_n, frame_start,
    input wire [1:0] mode,
    input wire [2:0] page,
    input wire [1:0] region,
    input wire hidden, in_de,
    input wire [11:0] pixel_x, pixel_y,
    input wire [23:0] background_rgb,
    output reg hit,
    output reg [23:0] color
);
    reg [1:0] mode_q, region_q;
    reg [2:0] page_q;
    reg [10:0] x0,x1,y0,y1,panel_x0,panel_x1;
    reg box, panel, border_line, border_corner, panel_edge;
    always @(posedge pclk or negedge rst_n) begin
        if(!rst_n) begin
            mode_q<=0;page_q<=0;region_q<=0;
            x0<=0;x1<=0;y0<=0;y1<=0;panel_x0<=0;panel_x1<=0;
        end else if(frame_start) begin
            mode_q<=mode;page_q<=page;region_q<=region;
            case(page)
                2: begin
                    case(region)
                        0: begin x0<=65;x1<=363;y0<=200;y1<=383;panel_x0<=853;panel_x1<=1270;end
                        1: begin x0<=413;x1<=807;y0<=200;y1<=383;panel_x0<=853;panel_x1<=1270;end
                        2: begin x0<=889;x1<=1055;y0<=199;y1<=355;panel_x0<=40;panel_x1<=520;end
                        3: begin x0<=1076;x1<=1220;y0<=199;y1<=355;panel_x0<=40;panel_x1<=520;end
                    endcase
                end
                4,5: begin
                    y0<=120;y1<=634;
                    if(region[0]) begin x0<=651;x1<=1249;panel_x0<=21;panel_x1<=485;end
                    else begin x0<=32;x1<=629;panel_x0<=661;panel_x1<=1125;end
                end
                default: begin x0<=0;x1<=0;y0<=0;y1<=0;panel_x0<=0;panel_x1<=0;end
            endcase
        end
    end
    always @* begin
        box=0;panel=0;border_line=0;border_corner=0;panel_edge=0;
        hit=0;color=background_rgb;
        if(in_de && !hidden && mode_q!=0 &&
           (page_q==2 || page_q==4 || page_q==5)) begin
            box=pixel_x>=x0 && pixel_x<x1 && pixel_y>=y0 && pixel_y<y1;
            border_line=box && (pixel_x<x0+4 || pixel_x>=x1-4 ||
                         pixel_y<y0+4 || pixel_y>=y1-4);
            border_corner=border_line &&
                          (pixel_x<x0+24 || pixel_x>=x1-24) &&
                          (pixel_y<y0+24 || pixel_y>=y1-24);
            panel=mode_q==2 && pixel_x>=panel_x0 && pixel_x<panel_x1 &&
                  pixel_y>=400 && pixel_y<615;
            panel_edge=panel && (pixel_x==panel_x0 || pixel_x==panel_x1-1 ||
                                 pixel_y==400 || pixel_y==614);
            if(panel) begin
                hit=1;
                color=panel_edge ? 24'h67d8c0 : 24'h102a33;
            end
            if(border_line) begin
                hit=1;
                color=border_corner ? 24'hffbf55 : 24'hecf8f4;
            end
        end
    end
endmodule
