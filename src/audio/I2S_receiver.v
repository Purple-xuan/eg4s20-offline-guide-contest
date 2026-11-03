module I2S_receiver (
    input wire       I_clk,
    input wire       I_rst,
    input wire       I_i2s_BCLK,
    input wire       I_i2s_LRCK,
    input wire       I_i2s_DOUT,
    output reg       O_audio_valid,
    output reg [23:0] O_audio_left_data,
    output reg [23:0] O_audio_right_data
);

reg bclk_1d, bclk_2d, bclk_3d;
reg lrck_1d, lrck_2d, lrck_3d;
reg dout_1d, dout_2d, dout_3d;
reg [5:0] slot_cnt;
reg [4:0] bit_cnt;
reg [23:0] left_shift, right_shift;
reg [23:0] left_hold;

wire bclk_rise = ~bclk_3d & bclk_2d;

always @(posedge I_clk or posedge I_rst) begin
    if (I_rst) begin
        bclk_1d <= 1'b0;
        bclk_2d <= 1'b0;
        bclk_3d <= 1'b0;
        lrck_1d <= 1'b0;
        lrck_2d <= 1'b0;
        lrck_3d <= 1'b0;
        dout_1d <= 1'b0;
        dout_2d <= 1'b0;
        dout_3d <= 1'b0;
        slot_cnt <= 6'd0;
        bit_cnt <= 5'd0;
        left_shift <= 24'd0;
        right_shift <= 24'd0;
        left_hold <= 24'd0;
        O_audio_valid <= 1'b0;
        O_audio_left_data <= 24'd0;
        O_audio_right_data <= 24'd0;
    end else begin
        bclk_1d <= I_i2s_BCLK;
        bclk_2d <= bclk_1d;
        bclk_3d <= bclk_2d;
        lrck_1d <= I_i2s_LRCK;
        lrck_2d <= lrck_1d;
        lrck_3d <= lrck_2d;
        dout_1d <= I_i2s_DOUT;
        dout_2d <= dout_1d;
        dout_3d <= dout_2d;
        O_audio_valid <= 1'b0;

        if (bclk_rise) begin
            if (lrck_3d != slot_cnt[5]) begin
                // The LRCK transition coincides with the channel's dummy I2S bit.
                slot_cnt <= {lrck_3d, 5'd1};
                bit_cnt <= 5'd0;
            end else begin
                slot_cnt <= slot_cnt + 6'd1;
                if (slot_cnt[4:0] == 5'd0) begin
                    bit_cnt <= 5'd0;
                end else if (slot_cnt[4:0] <= 5'd24) begin
                    bit_cnt <= bit_cnt + 5'd1;
                    if (!lrck_3d)
                        left_shift <= {left_shift[22:0], dout_3d};
                    else
                        right_shift <= {right_shift[22:0], dout_3d};

                    if (slot_cnt[4:0] == 5'd24 && !lrck_3d)
                        left_hold <= {left_shift[22:0], dout_3d};

                    if (slot_cnt[4:0] == 5'd24 && lrck_3d) begin
                        O_audio_valid <= 1'b1;
                        O_audio_left_data <= left_hold;
                        O_audio_right_data <= {right_shift[22:0], dout_3d};
                    end
                end
            end
        end
    end
end

endmodule
