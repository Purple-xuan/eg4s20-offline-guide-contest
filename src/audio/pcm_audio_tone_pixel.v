// Pixel-clock audio tone source.
// Generates one 24-bit stereo PCM sample at an average 48 kHz rate from
// the video clock, without a separate audio PLL or I2S clock domain.
module pcm_audio_tone_pixel #(
    parameter [31:0] SAMPLE_PHASE_INC = 32'd8246337,
    parameter signed [23:0] AMP = 24'sd2000000,
    parameter integer NOTE_HOLD_FRAMES = 24000
)(
    input  wire       I_clk,
    input  wire       I_rst,
    output reg        O_sample_valid,
    output reg [23:0] O_left_data,
    output reg [23:0] O_right_data
);

function [31:0] note_inc_lut;
    input [2:0] idx;
    begin
        case (idx)
            3'd0: note_inc_lut = 32'd23409862;
            3'd1: note_inc_lut = 32'd26276681;
            3'd2: note_inc_lut = 32'd29494578;
            3'd3: note_inc_lut = 32'd31248410;
            3'd4: note_inc_lut = 32'd35075155;
            3'd5: note_inc_lut = 32'd39370534;
            3'd6: note_inc_lut = 32'd44191930;
            default: note_inc_lut = 32'd46819716;
        endcase
    end
endfunction

function signed [23:0] sine_sample;
    input [3:0] idx;
    reg signed [39:0] scaled;
    begin
        case (idx)
            4'd0:  scaled = 40'sd0;
            4'd1:  scaled = AMP * 16'sd12540;
            4'd2:  scaled = AMP * 16'sd23170;
            4'd3:  scaled = AMP * 16'sd30274;
            4'd4:  scaled = AMP * 16'sd32767;
            4'd5:  scaled = AMP * 16'sd30274;
            4'd6:  scaled = AMP * 16'sd23170;
            4'd7:  scaled = AMP * 16'sd12540;
            4'd8:  scaled = 40'sd0;
            4'd9:  scaled = -AMP * 16'sd12540;
            4'd10: scaled = -AMP * 16'sd23170;
            4'd11: scaled = -AMP * 16'sd30274;
            4'd12: scaled = -AMP * 16'sd32767;
            4'd13: scaled = -AMP * 16'sd30274;
            4'd14: scaled = -AMP * 16'sd23170;
            default: scaled = -AMP * 16'sd12540;
        endcase
        sine_sample = scaled >>> 15;
    end
endfunction

reg [31:0] sample_phase_acc;
reg [31:0] tone_phase_acc;
reg [2:0]  note_idx;
reg [15:0] note_frame_cnt;
wire [31:0] note_phase_inc = note_inc_lut(note_idx);
wire [32:0] sample_phase_sum = {1'b0, sample_phase_acc} + {1'b0, SAMPLE_PHASE_INC};

always @(posedge I_clk or posedge I_rst) begin
    if (I_rst) begin
        sample_phase_acc <= 32'd0;
        tone_phase_acc   <= 32'd0;
        note_idx         <= 3'd0;
        note_frame_cnt   <= 16'd0;
        O_sample_valid   <= 1'b0;
        O_left_data      <= 24'd0;
        O_right_data     <= 24'd0;
    end else begin
        // Overflow is the fractional 48 kHz sample-enable event.
        sample_phase_acc <= sample_phase_sum[31:0];
        O_sample_valid   <= sample_phase_sum[32];
        if (sample_phase_sum[32]) begin
            O_left_data  <= sine_sample(tone_phase_acc[31:28]);
            O_right_data <= sine_sample(tone_phase_acc[31:28]);
            tone_phase_acc <= tone_phase_acc + note_phase_inc;

            if (note_frame_cnt == NOTE_HOLD_FRAMES - 1) begin
                note_frame_cnt <= 16'd0;
                note_idx <= (note_idx == 3'd7) ? 3'd0 : note_idx + 3'd1;
            end else begin
                note_frame_cnt <= note_frame_cnt + 16'd1;
            end
        end
    end
end

endmodule
