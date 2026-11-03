`timescale 1ns/1ps

// Four-cycle RGB brightness/contrast stage. brightness and contrast are
// expected to be stable for the current frame before entering this module.
// brightness=255 and contrast=128 are unity settings.
module brightness_contrast_adjust (
    input  wire        clk,
    input  wire        rst_n,
    input  wire        in_hs,
    input  wire        in_vs,
    input  wire        in_de,
    input  wire [23:0] rgb_in,
    input  wire [7:0]  brightness,
    input  wire [7:0]  contrast,
    output reg         out_de,
    output reg         out_hs,
    output reg         out_vs,
    output reg  [23:0] rgb_out
);
    function [7:0] saturate_channel;
        input signed [19:0] value;
        begin
            if (value < 0)
                saturate_channel = 8'd0;
            else if (value > 255)
                saturate_channel = 8'd255;
            else
                saturate_channel = value[7:0];
        end
    endfunction

    reg hs_d1, hs_d2, hs_d3;
    reg vs_d1, vs_d2, vs_d3;
    reg de_d1, de_d2, de_d3;
    (* keep = "true" *) reg [23:0] rgb_d1 /* fehdl keep="true" */;
    reg [8:0] bright_r_d2, bright_g_d2, bright_b_d2;
    reg signed [19:0] contrast_r_d3, contrast_g_d3, contrast_b_d3;
    wire [8:0] brightness_scale = {1'b0, brightness} + 9'd1;
    wire signed [9:0] contrast_scale = $signed({2'b00, contrast});
    wire [16:0] bright_mul_r = rgb_d1[23:16] * brightness_scale;
    wire [16:0] bright_mul_g = rgb_d1[15:8]  * brightness_scale;
    wire [16:0] bright_mul_b = rgb_d1[7:0]   * brightness_scale;
    wire signed [9:0] centered_r = $signed({1'b0, bright_r_d2}) - 10'sd128;
    wire signed [9:0] centered_g = $signed({1'b0, bright_g_d2}) - 10'sd128;
    wire signed [9:0] centered_b = $signed({1'b0, bright_b_d2}) - 10'sd128;
    wire signed [19:0] contrast_mul_r = centered_r * contrast_scale;
    wire signed [19:0] contrast_mul_g = centered_g * contrast_scale;
    wire signed [19:0] contrast_mul_b = centered_b * contrast_scale;
    wire signed [19:0] adjusted_r = (contrast_r_d3 >>> 7) + 20'sd128;
    wire signed [19:0] adjusted_g = (contrast_g_d3 >>> 7) + 20'sd128;
    wire signed [19:0] adjusted_b = (contrast_b_d3 >>> 7) + 20'sd128;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            hs_d1 <= 1'b1;
            hs_d2 <= 1'b1;
            hs_d3 <= 1'b1;
            vs_d1 <= 1'b1;
            vs_d2 <= 1'b1;
            vs_d3 <= 1'b1;
            de_d1 <= 1'b0;
            de_d2 <= 1'b0;
            de_d3 <= 1'b0;
            rgb_d1 <= 24'd0;
            bright_r_d2 <= 9'd0;
            bright_g_d2 <= 9'd0;
            bright_b_d2 <= 9'd0;
            contrast_r_d3 <= 20'sd0;
            contrast_g_d3 <= 20'sd0;
            contrast_b_d3 <= 20'sd0;
            out_hs  <= 1'b1;
            out_vs  <= 1'b1;
            out_de  <= 1'b0;
            rgb_out <= 24'h000000;
        end else begin
            hs_d1 <= in_hs;
            hs_d2 <= hs_d1;
            hs_d3 <= hs_d2;
            vs_d1 <= in_vs;
            vs_d2 <= vs_d1;
            vs_d3 <= vs_d2;
            de_d1 <= in_de;
            de_d2 <= de_d1;
            de_d3 <= de_d2;
            out_hs <= hs_d3;
            out_vs <= vs_d3;
            out_de <= de_d3;

            // Stage 1 isolates the OSD combinational path from the DSP input.
            // Hold arithmetic operands during blanking. HS/VS/DE keep their
            // four-cycle cadence; each data stage follows its own valid bit
            // so the first and last visible pixels are still processed.
            if (in_de) rgb_d1 <= rgb_in;

            // Stage 2: brightness=(pixel*(cfg+1))/256.
            if (de_d1) begin
                bright_r_d2 <= bright_mul_r[16:8];
                bright_g_d2 <= bright_mul_g[16:8];
                bright_b_d2 <= bright_mul_b[16:8];
            end

            // Stage 3: signed contrast around midpoint 128.
            if (de_d2) begin
                contrast_r_d3 <= contrast_mul_r;
                contrast_g_d3 <= contrast_mul_g;
                contrast_b_d3 <= contrast_mul_b;
            end

            // Stage 4: rescale, re-center, and saturate.
            if (de_d3)
                rgb_out <= {saturate_channel(adjusted_r),
                            saturate_channel(adjusted_g),
                            saturate_channel(adjusted_b)};
        end
    end
endmodule
