`timescale 1ns/1ps

// Two pixel clocks, in parallel with osd_pipe/osd_adjust. All coordinates
// refer to the approved 1280x720 emergency-evacuation-preview-v2 artwork.
module emergency_route_overlay #(
    parameter integer FRAMES_PER_STEP = 2
) (
    input wire clk, rst_n, frame_start,
    input wire emergency_active, media_ready, high_contrast,
    input wire in_de,
    input wire [11:0] pixel_x, pixel_y,
    input wire [23:0] background_rgb,
    output reg hit,
    output reg [23:0] color
);
    reg enabled, contrast_q;
    reg [5:0] frame_div, phase;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            enabled<=0; contrast_q<=0; frame_div<=0; phase<=0;
        end else if (frame_start) begin
            enabled<=emergency_active && media_ready;
            contrast_q<=high_contrast;
            if (!emergency_active || !media_ready || !enabled) begin
                frame_div<=0; phase<=0;
            end else if (frame_div==FRAMES_PER_STEP-1) begin
                frame_div<=0; phase<=phase+1'b1;
            end else frame_div<=frame_div+1'b1;
        end
    end

    reg route_area;
    reg [5:0] along;
    reg [3:0] across;
    // Small modular coordinates move chevrons in the direction of each
    // existing static arrow. The current-position label is excluded.
    always @* begin
        route_area=0; along=0; across=0;
        if (pixel_x>=386 && pixel_x<680 && pixel_y>=414 && pixel_y<=426) begin
            route_area=1;
            along=6'd0-pixel_x[5:0]-phase;
            across=pixel_y>=420 ? pixel_y-12'd420 : 12'd420-pixel_y;
        end else if (((pixel_x>=849 && pixel_x<1110 && pixel_y>=414 && pixel_y<=426) ||
                      (pixel_x>=736 && pixel_x<1174 && pixel_y>=535 && pixel_y<=547))) begin
            route_area=1;
            along=pixel_x[5:0]-phase;
            if (pixel_y<500)
                across=pixel_y>=420 ? pixel_y-12'd420 : 12'd420-pixel_y;
            else across=pixel_y>=541 ? pixel_y-12'd541 : 12'd541-pixel_y;
        end else if (pixel_x>=714 && pixel_x<=726 && pixel_y>=486 && pixel_y<533) begin
            route_area=1;
            along=pixel_y[5:0]-phase;
            across=pixel_x>=720 ? pixel_x-12'd720 : 12'd720-pixel_x;
        end else if (pixel_x>=1112 && pixel_x<=1124 && pixel_y>=430 && pixel_y<533) begin
            route_area=1;
            along=pixel_y[5:0]-phase;
            across=pixel_x>=1118 ? pixel_x-12'd1118 : 12'd1118-pixel_x;
        end
    end

    wire exit_a = pixel_x>=347 && pixel_x<389 && pixel_y>=395 && pixel_y<448 &&
        (pixel_x<350 || pixel_x>=386 || pixel_y<398 || pixel_y>=445);
    wire exit_b = pixel_x>=1173 && pixel_x<1221 && pixel_y>=521 && pixel_y<572 &&
        (pixel_x<1176 || pixel_x>=1218 || pixel_y<524 || pixel_y>=569);
    // Recolor red pixels of the triangle, status dot and status frame. The
    // aligned base image retains scaled outlines; the status text is excluded.
    wire warning_area = pixel_x>=24 && pixel_x<72 && pixel_y>=32 && pixel_y<80;
    wire status_area = pixel_x>=1044 && pixel_x<1242 && pixel_y>=32 && pixel_y<84 &&
        (pixel_x<1084 || pixel_x>=1228 || pixel_y<43 || pixel_y>=73);
    wire warning_ink = (warning_area || status_area) &&
        background_rgb[23] && !background_rgb[15] && !background_rgb[7];
    reg valid_q, route_q, exit_q, warning_q, animate_q;
    reg [5:0] along_q;
    reg [3:0] across_q;
    reg [1:0] pulse_q;
    reg [1:0] warning_pulse_q;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            valid_q<=0; route_q<=0; exit_q<=0; warning_q<=0; animate_q<=0;
            along_q<=0; across_q<=0; pulse_q<=0; warning_pulse_q<=0;
        end else begin
            valid_q<=in_de && enabled && emergency_active && media_ready;
            route_q<=route_area;
            exit_q<=exit_a || exit_b;
            warning_q<=warning_ink;
            animate_q<=!contrast_q;
            along_q<=along; across_q<=across;
            // 2 frames per pixel step, 32 steps per pulse: about 0.94Hz.
            pulse_q<=phase[4:3];
            // Four brightness steps in 32 video frames, about 1.86Hz.
            warning_pulse_q<=phase[3:2];
        end
    end
    wire [6:0] chevron = {1'b0,along_q}+{2'b0,across_q,1'b0};
    wire route_ink = route_q && chevron>=8 && chevron<13;
    reg [23:0] exit_color, warning_color;
    always @* begin
        case (pulse_q)
            0: exit_color=24'h218657;
            1: exit_color=24'h34b97c;
            2: exit_color=24'hadffda;
            default: exit_color=24'h4de0a0;
        endcase
        case (warning_pulse_q)
            0: warning_color=24'hff655c;
            2: warning_color=24'h8f3036;
            default: warning_color=24'hd84542;
        endcase
    end
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin hit<=0; color<=0; end
        else begin
            hit<=valid_q && (exit_q || (animate_q && (route_ink || warning_q)));
            color<=exit_q ? (animate_q ? exit_color : 24'h4de0a0) :
                   (warning_q ? warning_color : 24'hfff5bb);
        end
    end
endmodule
