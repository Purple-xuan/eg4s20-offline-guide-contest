`timescale 1ns/1ps

// Frame-atomic navigation mask. Requests and the displayed-page acknowledgement
// arrive through bundled handshakes. This block never selects a media page.
// RGB and all three raster signals have the same three-clock latency.
module navigation_transition_effect #(
    parameter integer NAV_DARKEN_FRAMES=6,
    parameter integer NAV_BLACK_HOLD_FRAMES=4,
    // Slower hierarchy transitions at 60 Hz; ordinary page wipes are separate.
    // Powers of two keep the frame-progress divisions reducible to shifts.
    parameter integer NAV_REVEAL_FRAMES=64,
    parameter integer NAV_HOME_REVEAL_FRAMES=32,
    parameter integer NAV_SETTLE_FRAMES=6,
    parameter integer NAV_EDGE_WIDTH=2,
    parameter [1:0] NAV_DIM_LEVEL=1,
    parameter integer NAV_TOTAL_MAX_FRAMES=48
) (
    input wire clk,rst_n,frame_start,
    input wire request_active,target_ready,target_committed,
    input wire [3:0] request_epoch,
    input wire [2:0] nav_profile,nav_menu_index,
    input wire [1:0] nav_direction,
    input wire [10:0] anchor_x,
    input wire [9:0] anchor_y,
    input wire emergency_active,cancel,
    input wire in_hs,in_vs,in_de,
    input wire [10:0] pixel_x,
    input wire [9:0] pixel_y,
    input wire [23:0] rgb_in,
    output reg out_hs,out_vs,out_de,
    output reg [23:0] rgb_out,
    output wire nav_busy,commit_ready,audio_ready,darken_started,
    output reg complete,failed,
    output reg [3:0] ack_epoch,
    output wire [6:0] target_reveal_level
);
    localparam IDLE=0,PREPARE=1,DARKEN=2,COMMIT=3,REVEAL=4,SETTLE=5;
    localparam HOME_MENU=1,MENU_DETAIL=2,DETAIL_MENU=3,DETAIL_HOME=4,MENU_HOME=5;
    reg [2:0] state,profile;
    reg [2:0] menu_index;
    reg [10:0] ax;
    reg [9:0] ay;
    reg [6:0] count;
    reg [6:0] progress;
    reg blocked;
    wire matching=request_active && request_epoch==ack_epoch;
    wire bypass=emergency_active || cancel || !request_active || !matching || blocked;
    assign nav_busy=state!=IDLE && !bypass;
    assign darken_started=matching && !bypass &&
                          ((state!=IDLE && state!=PREPARE) || complete);
    assign commit_ready=matching && !bypass &&
                        (state==COMMIT || state==REVEAL || state==SETTLE || complete);
    assign audio_ready=matching && !bypass && target_committed &&
                       ((profile==MENU_DETAIL && state==REVEAL && progress>=39) ||
                        (profile==MENU_DETAIL && state==SETTLE) || complete);
    assign target_reveal_level=bypass || complete ? 7'd64 : progress;
    wire [6:0] reveal_frames=profile==MENU_HOME ? NAV_HOME_REVEAL_FRAMES : NAV_REVEAL_FRAMES;
    // These returns are composed from both resident pages by the row reader.
    wire paired_return=profile==HOME_MENU || profile==DETAIL_MENU;
    // Constant divisions and shift/add geometry occur only in frame control.
    // The pixel path below contains registered comparisons and RGB shifts.
    function [6:0] eased;
        input [6:0] n;
        input short_home;
        integer linear;
        begin
            if(short_home) linear=(n*64)/NAV_HOME_REVEAL_FRAMES;
            else linear=(n*64)/NAV_REVEAL_FRAMES;
            if(linear>=64) eased=64;
            else if(linear<32) eased=linear+(linear>>1);
            else eased=48+((linear-32)>>1);
        end
    endfunction
    always @(posedge clk or negedge rst_n) begin
        if(!rst_n) begin
            state<=IDLE;profile<=0;menu_index<=0;ax<=640;ay<=360;
            count<=0;progress<=0;ack_epoch<=0;complete<=0;failed<=0;blocked<=0;
        end else if(emergency_active || cancel) begin
            state<=IDLE;count<=0;progress<=64;complete<=0;failed<=0;blocked<=1;
        end else if(frame_start) begin
            if(!request_active) begin
                state<=IDLE;count<=0;progress<=64;complete<=0;failed<=0;blocked<=0;
                ack_epoch<=request_epoch;
            end else if(request_epoch!=ack_epoch ||
                        (state==IDLE && !complete && !failed && !blocked)) begin
                ack_epoch<=request_epoch;profile<=nav_profile;menu_index<=nav_menu_index;
                ax<=anchor_x;ay<=anchor_y;
                state<=PREPARE;count<=0;progress<=0;complete<=0;failed<=0;blocked<=0;
            end else if(!blocked && !complete && !failed) begin
                case(state)
                    PREPARE: if(target_ready) begin
                        state<=paired_return ? COMMIT : DARKEN;count<=0;
                    end
                    DARKEN: if(count>=NAV_DARKEN_FRAMES-1) begin state<=COMMIT;count<=0;end
                            else count<=count+1'b1;
                    COMMIT: begin
                        if(target_committed && count>=NAV_BLACK_HOLD_FRAMES-1) begin
                            state<=paired_return ? SETTLE : REVEAL;
                            count<=0;progress<=paired_return ? 7'd64 : 7'd0;
                        end else if(count>=(paired_return ? 96 : NAV_TOTAL_MAX_FRAMES)-1) begin
                            state<=IDLE;failed<=1;progress<=64;
                        end else count<=count+1'b1;
                    end
                    REVEAL: begin
                        if(!target_committed) begin state<=IDLE;failed<=1;progress<=64;end
                        else if(count>=reveal_frames-1) begin state<=SETTLE;count<=0;progress<=64;end
                        else begin count<=count+1'b1;progress<=eased(count+1'b1,profile==MENU_HOME);end
                    end
                    SETTLE: if(count>=NAV_SETTLE_FRAMES-1) begin state<=IDLE;complete<=1;end
                            else count<=count+1'b1;
                    default: state<=IDLE;
                endcase
            end
        end
    end

    reg [10:0] radius_x;
    reg [9:0] radius_y;
    reg [10:0] diamond_radius;
    reg [9:0] bottom_y;
    // These registers settle in vertical blanking after frame control changes.
    always @(posedge clk) begin
        radius_x<=(progress<<4)+(progress<<2);
        radius_y<=(progress<<3)+(progress<<2);
        diamond_radius<=progress<<4;
        bottom_y<=progress>=60 ? 0 : 480-(progress<<3);
    end

    reg [10:0] dx_q;
    reg [9:0] dy_q;
    reg [10:0] home_dx_q;
    reg [9:0] home_dy_q,y_q;
    reg hs_q,vs_q,de_q,hs_qq,vs_qq,de_qq;
    reg [23:0] rgb_q,rgb_qq;
    reg reveal_q,edge_q,dark_q;
    reg [1:0] dim_q;
    wire [11:0] diamond_distance={1'b0,home_dx_q}+{2'b0,home_dy_q};
    wire rectangle_hit=dx_q<=radius_x && dy_q<=radius_y;
    function [7:0] dim_channel;
        input [7:0] c;
        input [1:0] level;
        begin
            case(level)
                0:dim_channel=0;
                1:dim_channel=c>>2;
                2:dim_channel=c>>1;
                default:dim_channel=(c>>1)+(c>>2);
            endcase
        end
    endfunction
    always @(posedge clk or negedge rst_n) begin
        if(!rst_n) begin
            dx_q<=0;dy_q<=0;home_dx_q<=0;home_dy_q<=0;y_q<=0;
            hs_q<=1;vs_q<=1;de_q<=0;hs_qq<=1;vs_qq<=1;de_qq<=0;
            rgb_q<=0;rgb_qq<=0;out_hs<=1;out_vs<=1;out_de<=0;rgb_out<=0;
            reveal_q<=1;edge_q<=0;dark_q<=0;dim_q<=NAV_DIM_LEVEL;
        end else begin
            dx_q<=pixel_x>ax ? pixel_x-ax : ax-pixel_x;
            dy_q<=pixel_y>ay ? pixel_y-ay : ay-pixel_y;
            home_dx_q<=pixel_x>640 ? pixel_x-640 : 640-pixel_x;
            home_dy_q<=pixel_y>360 ? pixel_y-360 : 360-pixel_y;
            y_q<=pixel_y;
            hs_q<=in_hs;vs_q<=in_vs;de_q<=in_de;rgb_q<=rgb_in;
            hs_qq<=hs_q;vs_qq<=vs_q;de_qq<=de_q;rgb_qq<=rgb_q;
            reveal_q<=1;edge_q<=0;dark_q<=0;dim_q<=NAV_DIM_LEVEL;
            if(!bypass && !paired_return) begin
                case(state)
                    DARKEN: begin
                        dim_q<=count<2 ? 3 : count<4 ? 2 : NAV_DIM_LEVEL;
                        // Keep the selected source / entrance visible briefly.
                        reveal_q<=count<2 &&
                            (profile==HOME_MENU || profile==MENU_HOME ?
                                diamond_distance<360 : dx_q<181 && dy_q<88);
                    end
                    COMMIT: begin reveal_q<=0;dark_q<=1;end
                    REVEAL: begin
                        // The unrevealed area is a true black field. Reuse
                        // the existing dimmer pipeline with level zero.
                        dim_q<=0;
                        case(profile)
                            MENU_DETAIL: begin
                                reveal_q<=rectangle_hit;
                                edge_q<=count<8 && rectangle_hit &&
                                    (dx_q+NAV_EDGE_WIDTH>=radius_x || dy_q+NAV_EDGE_WIDTH>=radius_y);
                            end
                            DETAIL_HOME: begin
                                reveal_q<=y_q>=bottom_y && home_dx_q<=radius_x+213;
                                edge_q<=count<8 && y_q>=bottom_y && y_q<bottom_y+NAV_EDGE_WIDTH &&
                                    home_dx_q<=radius_x+213;
                            end
                            default: begin
                                reveal_q<=diamond_distance<=diamond_radius;
                                edge_q<=count<8 && diamond_distance<=diamond_radius &&
                                    diamond_distance+NAV_EDGE_WIDTH>=diamond_radius;
                            end
                        endcase
                    end
                    default: begin end
                endcase
            end
            out_hs<=hs_qq;out_vs<=vs_qq;out_de<=de_qq;
            // Emergency bypass also overrides masks already in the pipeline.
            if(!de_qq) rgb_out<=0;
            else if(emergency_active || cancel || bypass) rgb_out<=rgb_qq;
            else if(dark_q) rgb_out<=24'h030b18;
            else if(edge_q) rgb_out<=24'hb4f4ff;
            else if(reveal_q) rgb_out<=rgb_qq;
            else rgb_out<={dim_channel(rgb_qq[23:16],dim_q),
                           dim_channel(rgb_qq[15:8],dim_q),
                           dim_channel(rgb_qq[7:0],dim_q)};
        end
    end
endmodule
