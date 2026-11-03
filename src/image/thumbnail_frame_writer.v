`timescale 1ns/1ps

// Packs a thumbnail RGB888 stream into sequential RGB565 SDRAM words.
// The first pixel occupies the low half, matching media_frame_loader.
module thumbnail_frame_writer #(
    parameter integer WIDTH = 320,
    parameter integer HEIGHT = 180,
    parameter integer ADDR_BITS = 21
) (
    input  wire                   clk,
    input  wire                   rst,
    input  wire                   start,
    input  wire [ADDR_BITS-1:0]   base_addr,
    input  wire                   in_valid,
    output wire                   in_ready,
    input  wire [23:0]            in_pixel,
    output reg                    out_valid,
    input  wire                   out_ready,
    output reg  [ADDR_BITS-1:0]   out_addr,
    output reg  [31:0]            out_data,
    output reg                    frame_done,
    output reg                    error
);
    localparam integer PIXELS = WIDTH * HEIGHT;
    localparam integer WORDS = (PIXELS + 1) / 2;

    reg half_valid;
    reg [15:0] first_pixel;
    reg [31:0] accepted_pixels;
    reg [ADDR_BITS-1:0] write_addr;
    wire output_slot = !out_valid || out_ready;
    assign in_ready = !error && output_slot && (!half_valid || in_valid);

    function [15:0] rgb565;
        input [23:0] rgb;
        begin
            rgb565 = {rgb[23:19], rgb[15:10], rgb[7:3]};
        end
    endfunction

    always @(posedge clk or posedge rst) begin
        if (rst) begin
            half_valid <= 1'b0;
            first_pixel <= 16'd0;
            accepted_pixels <= 32'd0;
            out_valid <= 1'b0;
            out_addr <= {ADDR_BITS{1'b0}};
            write_addr <= {ADDR_BITS{1'b0}};
            out_data <= 32'd0;
            frame_done <= 1'b0;
            error <= 1'b0;
        end else begin
            frame_done <= 1'b0;
            if (start) begin
                half_valid <= 1'b0;
                accepted_pixels <= 32'd0;
                out_valid <= 1'b0;
                out_addr <= base_addr;
                write_addr <= base_addr;
                error <= 1'b0;
            end else begin
                if (out_valid && out_ready)
                    out_valid <= 1'b0;

                if (in_valid && in_ready) begin
                    accepted_pixels <= accepted_pixels + 1'b1;
                    if (!half_valid) begin
                        first_pixel <= rgb565(in_pixel);
                        half_valid <= 1'b1;
                    end else begin
                        out_data <= {rgb565(in_pixel), first_pixel};
                        out_valid <= 1'b1;
                        out_addr <= write_addr;
                        half_valid <= 1'b0;
                        write_addr <= write_addr + 1'b1;
                        if (accepted_pixels + 1'b1 == PIXELS)
                            frame_done <= 1'b1;
                    end
                end

                if (in_valid && !in_ready && accepted_pixels < PIXELS)
                    error <= 1'b1;
            end
        end
    end
endmodule
