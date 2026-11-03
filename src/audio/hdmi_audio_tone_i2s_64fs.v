module hdmi_audio_tone_i2s_64fs #(
    parameter [31:0] PHASE_INC = 32'd39370534,
    parameter signed [23:0] AMP = 24'sd2000000,
    parameter integer NOTE_HOLD_FRAMES = 24000
)(
    input  wire I_mclk,
    input  wire I_rst,
    output reg  O_i2s_BCLK,
    output reg  O_i2s_LRCK,
    output reg  O_i2s_DOUT
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

reg [1:0] S_mclk_div;
reg [5:0] S_slot_cnt;
reg [31:0] S_phase_acc;
reg [2:0] S_note_idx;
reg [15:0] S_note_frame_cnt;
reg signed [23:0] S_sample_word;
wire [31:0] W_note_inc = note_inc_lut(S_note_idx);

always @(posedge I_mclk or posedge I_rst) begin
    if (I_rst) begin
        S_mclk_div       <= 2'd0;
        O_i2s_BCLK       <= 1'b0;
        O_i2s_LRCK       <= 1'b0;
        O_i2s_DOUT       <= 1'b0;
        S_slot_cnt       <= 6'd0;
        S_phase_acc      <= 32'd0;
        S_note_idx       <= 3'd0;
        S_note_frame_cnt <= 16'd0;
        S_sample_word    <= 24'sd0;
    end else if (S_mclk_div == 2'd1) begin
        S_mclk_div <= 2'd0;
        O_i2s_BCLK <= ~O_i2s_BCLK;

        // Change data on BCLK falling edges; the receiver samples on rising edges.
        if (O_i2s_BCLK) begin
            O_i2s_LRCK <= S_slot_cnt[5];
            if (S_slot_cnt[4:0] == 5'd0)
                O_i2s_DOUT <= 1'b0;
            else if (S_slot_cnt[4:0] <= 5'd24)
                O_i2s_DOUT <= S_sample_word[24 - S_slot_cnt[4:0]];
            else
                O_i2s_DOUT <= 1'b0;

            if (S_slot_cnt == 6'd0) begin
                S_phase_acc   <= S_phase_acc + W_note_inc;
                S_sample_word <= sine_sample(S_phase_acc[31:28]);

                if (S_note_frame_cnt == NOTE_HOLD_FRAMES - 1) begin
                    S_note_frame_cnt <= 16'd0;
                    S_note_idx <= (S_note_idx == 3'd7) ? 3'd0 : S_note_idx + 3'd1;
                end else begin
                    S_note_frame_cnt <= S_note_frame_cnt + 16'd1;
                end
            end

            S_slot_cnt <= S_slot_cnt + 6'd1;
        end
    end else begin
        S_mclk_div <= S_mclk_div + 2'd1;
    end
end

endmodule
