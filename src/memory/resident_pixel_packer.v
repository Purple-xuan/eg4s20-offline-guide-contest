`timescale 1ns/1ps

// One frame of 960x540 RGB888 pixels in BMP stream order. The producer holds
// pixel_valid/data/last while stalled. The consumer accepts packed words in
// order; last must coincide with the final accepted pixel.
module resident_pixel_packer #(
    parameter integer FRAME_WIDTH=960,
    parameter integer FRAME_HEIGHT=540
) (
    input wire clk, rst_n, start,
    input wire pixel_valid, pixel_last,
    output wire pixel_ready,
    input wire [23:0] pixel_rgb,
    output reg word_valid,
    input wire word_ready,
    output reg [31:0] word_data,
    output reg stream_done, stream_error
);
    localparam integer FRAME_PIXELS=FRAME_WIDTH*FRAME_HEIGHT;
    reg active, half, last_word_pending;
    reg [18:0] accepted;
    reg [15:0] low_pixel;
    wire [15:0] rgb565={pixel_rgb[23:19],pixel_rgb[15:10],pixel_rgb[7:3]};
    wire take=pixel_valid && pixel_ready;
    assign pixel_ready=active && !stream_done && !stream_error &&
                       (!half || !word_valid || word_ready);

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            active<=0; half<=0; last_word_pending<=0; accepted<=0; low_pixel<=0;
            word_valid<=0; word_data<=0; stream_done<=0; stream_error<=0;
        end else if (start) begin
            active<=1; half<=0; last_word_pending<=0; accepted<=0; low_pixel<=0;
            word_valid<=0; stream_done<=0; stream_error<=0;
        end else begin
            if (word_valid && word_ready) begin
                word_valid<=0;
                if (last_word_pending) begin
                    last_word_pending<=0;
                    stream_done<=1;
                end
            end
            if (take) begin
                accepted<=accepted+1'b1;
                if (pixel_last != (accepted==FRAME_PIXELS-1)) begin
                    stream_error<=1;
                    active<=0;
                end else if (!half) begin
                    low_pixel<=rgb565;
                    half<=1;
                end else begin
                    word_data<={rgb565,low_pixel};
                    word_valid<=1;
                    half<=0;
                    if (pixel_last) begin last_word_pending<=1; active<=0; end
                end
            end
        end
    end
endmodule
