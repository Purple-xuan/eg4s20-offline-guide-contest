`timescale 1ns/1ps

// Keep the HDMI raster running during startup, empty-card scans and recovery.
// Missing image samples are black pixels in a complete frame.
module media_video_input (
    input wire clk, rst_n,
    input wire in_hs, in_vs, in_de,
    input wire [11:0] pixel_x, pixel_y,
    input wire image_available, pixel_valid,
    input wire [23:0] rgb_in,
    output reg out_hs, out_vs, out_de, out_pixel_valid,
    output reg [11:0] out_x, out_y,
    output reg [23:0] rgb_out
);
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            out_hs<=1;out_vs<=1;out_de<=0;out_pixel_valid<=0;
            out_x<=0;out_y<=0;rgb_out<=0;
        end else begin
            out_hs<=in_hs;out_vs<=in_vs;out_de<=in_de;
            out_pixel_valid<=in_de && image_available && pixel_valid;
            out_x<=pixel_x;out_y<=pixel_y;
            rgb_out<=image_available && pixel_valid ? rgb_in : 24'd0;
        end
    end
endmodule
