`timescale 1ns/1ps

// Extracts one pixel from each H_STEP by V_STEP block of a canonical frame.
// Backpressure is applied only while a selected thumbnail pixel is pending.
module thumbnail_downsampler #(
    parameter integer INPUT_WIDTH  = 1280,
    parameter integer INPUT_HEIGHT = 720,
    parameter integer H_STEP       = 4,
    parameter integer V_STEP       = 4
) (
    input  wire        clk,
    input  wire        rst,

    input  wire        in_valid,
    output wire        in_ready,
    input  wire [23:0] in_pixel,

    output reg         out_valid,
    input  wire        out_ready,
    output reg  [23:0] out_pixel,
    output reg         out_sof,
    output reg         out_eol,
    output reg         out_eof
);
    localparam integer OUTPUT_WIDTH  = INPUT_WIDTH / H_STEP;
    localparam integer OUTPUT_HEIGHT = INPUT_HEIGHT / V_STEP;

    reg [15:0] input_x;
    reg [15:0] input_y;
    reg [15:0] horizontal_phase;
    reg [15:0] vertical_phase;
    reg [15:0] output_x;
    reg [15:0] output_y;

    wire output_slot_available = !out_valid || out_ready;
    wire select_input = horizontal_phase == 0 && vertical_phase == 0;
    wire input_accept = in_valid && in_ready;

    assign in_ready = output_slot_available;

    always @(posedge clk or posedge rst) begin
        if (rst) begin
            input_x <= 16'd0;
            input_y <= 16'd0;
            horizontal_phase <= 16'd0;
            vertical_phase <= 16'd0;
            output_x <= 16'd0;
            output_y <= 16'd0;
            out_valid <= 1'b0;
            out_pixel <= 24'd0;
            out_sof <= 1'b0;
            out_eol <= 1'b0;
            out_eof <= 1'b0;
        end else begin
            if (out_valid && out_ready)
                out_valid <= 1'b0;

            if (input_accept) begin
                if (select_input) begin
                    out_valid <= 1'b1;
                    out_pixel <= in_pixel;
                    out_sof <= output_x == 0 && output_y == 0;
                    out_eol <= output_x == OUTPUT_WIDTH - 1;
                    out_eof <= output_x == OUTPUT_WIDTH - 1 &&
                               output_y == OUTPUT_HEIGHT - 1;

                    if (output_x == OUTPUT_WIDTH - 1) begin
                        output_x <= 16'd0;
                        if (output_y == OUTPUT_HEIGHT - 1)
                            output_y <= 16'd0;
                        else
                            output_y <= output_y + 1'b1;
                    end else begin
                        output_x <= output_x + 1'b1;
                    end
                end

                if (input_x == INPUT_WIDTH - 1) begin
                    input_x <= 16'd0;
                    horizontal_phase <= 16'd0;
                    if (input_y == INPUT_HEIGHT - 1) begin
                        input_y <= 16'd0;
                        vertical_phase <= 16'd0;
                    end else begin
                        input_y <= input_y + 1'b1;
                        if (vertical_phase == V_STEP - 1)
                            vertical_phase <= 16'd0;
                        else
                            vertical_phase <= vertical_phase + 1'b1;
                    end
                end else begin
                    input_x <= input_x + 1'b1;
                    if (horizontal_phase == H_STEP - 1)
                        horizontal_phase <= 16'd0;
                    else
                        horizontal_phase <= horizontal_phase + 1'b1;
                end
            end
        end
    end
endmodule
