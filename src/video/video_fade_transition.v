`timescale 1ns/1ps

// Single-reader fade transition. The SD controller publishes a desired bank;
// this block keeps the reader on the old bank until the output is fully black,
// then waits for the reader acknowledgement before fading the new bank in.
// Emergency mode cancels any normal transition and follows the desired bank
// directly so urgent content is never delayed by the visual effect.
module video_fade_transition #(
    parameter integer FADE_FRAMES = 8
) (
    input  wire        clk,
    input  wire        rst_n,
    input  wire        frame_start,
    input  wire        display_valid,
    input  wire        emergency_active,
    input  wire [1:0]  desired_bank,
    input  wire [1:0]  reader_bank_async,

    input  wire        in_hs,
    input  wire        in_vs,
    input  wire        in_de,
    input  wire [23:0] rgb_in,

    output reg  [1:0]  active_bank,
    output wire [7:0]  fade_alpha,
    output wire        transition_active,
    output reg         out_hs,
    output reg         out_vs,
    output reg         out_de,
    output reg  [23:0] rgb_out
);
    localparam [1:0] S_IDLE = 2'd0;
    localparam [1:0] S_OUT  = 2'd1;
    localparam [1:0] S_HOLD = 2'd2;
    localparam [1:0] S_IN   = 2'd3;
    localparam integer FADE_STEP = 256 / FADE_FRAMES;

    reg [1:0] state;
    reg [1:0] target_bank;
    reg [7:0] alpha;
    reg [1:0] reader_bank_sync1;
    reg [1:0] reader_bank_sync2;

    wire [8:0] alpha_scale = {1'b0, alpha} + 9'd1;
    wire [16:0] scaled_r = rgb_in[23:16] * alpha_scale;
    wire [16:0] scaled_g = rgb_in[15:8]  * alpha_scale;
    wire [16:0] scaled_b = rgb_in[7:0]   * alpha_scale;

    assign fade_alpha = alpha;
    assign transition_active = state != S_IDLE;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state <= S_IDLE;
            target_bank <= 2'd0;
            active_bank <= 2'd0;
            alpha <= 8'd255;
            reader_bank_sync1 <= 2'd0;
            reader_bank_sync2 <= 2'd0;
        end else begin
            reader_bank_sync1 <= reader_bank_async;
            reader_bank_sync2 <= reader_bank_sync1;

            if (!display_valid) begin
                state <= S_IDLE;
                active_bank <= reader_bank_sync2;
                target_bank <= desired_bank;
                alpha <= 8'd255;
            end else if (emergency_active) begin
                state <= S_IDLE;
                active_bank <= desired_bank;
                target_bank <= desired_bank;
                alpha <= 8'd255;
            end else if (frame_start) begin
                case (state)
                    S_IDLE: begin
                        alpha <= 8'd255;
                        // The proven reader path owns bank switching. Start
                        // fading when the requested bank differs from the
                        // bank actually acknowledged by the reader.
                        active_bank <= reader_bank_sync2;
                        if (desired_bank != reader_bank_sync2) begin
                            target_bank <= desired_bank;
                            state <= S_OUT;
                            alpha <= 8'd255 - FADE_STEP;
                        end
                    end

                    S_OUT: begin
                        if (alpha <= FADE_STEP) begin
                            alpha <= 8'd0;
                            active_bank <= target_bank;
                            state <= S_HOLD;
                        end else begin
                            alpha <= alpha - FADE_STEP;
                        end
                    end

                    S_HOLD: begin
                        alpha <= 8'd0;
                        if (reader_bank_sync2 == target_bank) begin
                            state <= S_IN;
                            alpha <= FADE_STEP;
                        end
                    end

                    S_IN: begin
                        if (alpha >= (8'd255 - FADE_STEP)) begin
                            alpha <= 8'd255;
                            state <= S_IDLE;
                        end else begin
                            alpha <= alpha + FADE_STEP;
                        end
                    end

                    default: begin
                        state <= S_IDLE;
                        alpha <= 8'd255;
                    end
                endcase
            end
        end
    end

    // One registered pixel stage keeps the complete video bundle aligned.
    // alpha=255 is exact unity; alpha=0 always truncates to black.
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            out_hs <= 1'b1;
            out_vs <= 1'b1;
            out_de <= 1'b0;
            rgb_out <= 24'd0;
        end else begin
            out_hs <= in_hs;
            out_vs <= in_vs;
            out_de <= in_de;
            rgb_out <= in_de ? {scaled_r[15:8], scaled_g[15:8],
                                scaled_b[15:8]} : 24'd0;
        end
    end
endmodule
