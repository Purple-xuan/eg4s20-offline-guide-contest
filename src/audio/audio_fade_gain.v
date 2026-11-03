`timescale 1ns/1ps

// Display the final HDMI mix. 64 peak windows span about 43 ms at 48 kHz.
// One small BRAM avoids a register array and its pixel-rate read multiplexer.
module audio_waveform_overlay #(
    parameter [21:0] HOLD_CYCLES = 22'd3700000
) (
    input wire clk, rst_n, sample_valid,
    input wire signed [15:0] left_pcm, right_pcm,
    input wire [11:0] pixel_x_early, pixel_x, pixel_y,
    input wire in_de,
    output wire hit,
    output wire [23:0] color
);
    reg [5:0] write_index;
    reg [4:0] sample_count;
    reg [7:0] peak;
    reg [21:0] visible_hold;
    reg history_ready;
    wire [15:0] left_abs = left_pcm[15] ? (~left_pcm + 16'd1) : left_pcm;
    wire [15:0] right_abs = right_pcm[15] ? (~right_pcm + 16'd1) : right_pcm;
    wire [15:0] abs_max = left_abs > right_abs ? left_abs : right_abs;
    wire [8:0] scaled = abs_max[15:7];
    wire [7:0] sample_level = scaled[8] ? 8'd255 : scaled[7:0];
    wire sample_commit = rst_n && sample_valid && sample_count == 5'd31;
    wire [7:0] commit_level = peak > sample_level ? peak : sample_level;
    // Synchronous RAM output arrives with the next raster stage.
    wire [5:0] read_index = (pixel_x_early - 12'd128) >> 4;
    wire [7:0] level_read;
    EG_LOGIC_BRAM #(
        .DATA_WIDTH_A(8), .DATA_WIDTH_B(8),
        .ADDR_WIDTH_A(6), .ADDR_WIDTH_B(6),
        .DATA_DEPTH_A(64), .DATA_DEPTH_B(64), .MODE("DP"),
        .REGMODE_A("NOREG"), .REGMODE_B("NOREG"),
        .WRITEMODE_A("NORMAL"), .WRITEMODE_B("NORMAL"),
        .RESETMODE("SYNC"), .BYTE_ENABLE(0), .BYTE_A(1), .BYTE_B(1),
        .IMPLEMENT("9K")
    ) u_history (
        .doa(), .dob(level_read), .dia(commit_level), .dib(8'd0),
        .cea(1'b1), .ocea(1'b1), .clka(clk),
        .wea(sample_commit), .rsta(1'b0),
        .ceb(1'b1), .oceb(1'b1), .clkb(clk), .web(1'b0), .rstb(1'b0),
        .bea(1'b1), .beb(1'b1), .addra(write_index), .addrb(read_index)
    );
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            write_index <= 0;
            sample_count <= 0;
            peak <= 0;
            visible_hold <= 0;
            history_ready <= 0;
        end else begin
            if (visible_hold != 0) visible_hold <= visible_hold - 1'b1;
            if (sample_valid) begin
                if (sample_level > peak) peak <= sample_level;
                if (sample_count == 5'd31) begin
                    write_index <= write_index + 1'b1;
                    sample_count <= 0;
                    peak <= 0;
                    if (write_index == 6'd63) history_ready <= 1;
                end else sample_count <= sample_count + 1'b1;
                if (sample_level >= 8'd3) visible_hold <= HOLD_CYCLES;
            end
        end
    end
    wire bar_x_valid = pixel_x >= 12'd128 && pixel_x < 12'd1152;
    wire [9:0] original_height = 10'd2 + {4'd0,level_read[7:3],1'b0};
    wire [9:0] height = level_read != 0 && original_height < 10'd6 ?
        10'd6 : original_height;
    // Captions end at y=648 (including large text); bars start at y=652.
    assign hit = in_de && history_ready && visible_hold != 0 &&
        bar_x_valid && pixel_x[3:0] < 4'd11 &&
        pixel_y >= (10'd716 - height) && pixel_y < 12'd716;
    assign color = 24'h9bdde6;
endmodule

// Apply the video fade envelope to signed PCM samples without changing the
// sample-valid cadence.  The audio and video paths share video_clk, so the
// frame-rate envelope is stable for every 48 kHz sample interval.
module audio_fade_gain (
    input  wire              clk,
    input  wire              rst_n,
    input  wire              sample_valid,
    input  wire signed [23:0] left_in,
    input  wire signed [23:0] right_in,
    input  wire [7:0]        fade_alpha,
    input  wire              emergency_active,
    output reg               sample_valid_out,
    output reg signed [23:0] left_out,
    output reg signed [23:0] right_out
);
    wire [7:0] gain = emergency_active ? 8'd255 : fade_alpha;
    // 255 + 1 = 256 needs ten signed bits; nine bits would wrap to -256.
    wire signed [9:0] gain_scale = {2'b0, gain} + 10'sd1;
    // WAV input is signed 16-bit PCM sign-extended to 24 bits. Keep the
    // multiply at 16x10 so this stage does not consume a full 24-bit DSP path.
    wire signed [15:0] left_pcm16 = left_in[15:0];
    wire signed [15:0] right_pcm16 = right_in[15:0];
    wire signed [25:0] left_product = left_pcm16 * gain_scale;
    wire signed [25:0] right_product = right_pcm16 * gain_scale;
    reg signed [25:0] left_product_q;
    reg signed [25:0] right_product_q;
    reg product_valid_q;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            sample_valid_out <= 1'b0;
            left_out <= 24'sd0;
            right_out <= 24'sd0;
            left_product_q <= 26'sd0;
            right_product_q <= 26'sd0;
            product_valid_q <= 1'b0;
        end else begin
            sample_valid_out <= product_valid_q;
            if (product_valid_q) begin
                left_out <= {{8{left_product_q[23]}}, left_product_q[23:8]};
                right_out <= {{8{right_product_q[23]}}, right_product_q[23:8]};
            end else begin
                left_out <= 24'sd0;
                right_out <= 24'sd0;
            end
            product_valid_q <= sample_valid;
            if (sample_valid) begin
                left_product_q <= left_product;
                right_product_q <= right_product;
            end
        end
    end
endmodule

// Narration has priority; reduce music under speech and clip signed overflow.
module audio_narration_bgm_mix (
    input wire clk, rst_n, sample_valid, narration_active, emergency_active,
    input wire signed [23:0] left_in, right_in,
    input wire signed [15:0] bgm_left, bgm_right,
    output reg sample_valid_out,
    output reg signed [23:0] left_out, right_out
);
    wire signed [15:0] music_left = emergency_active ? 16'sd0 :
        narration_active ? ($signed(bgm_left) >>> 3) : bgm_left;
    wire signed [15:0] music_right = emergency_active ? 16'sd0 :
        narration_active ? ($signed(bgm_right) >>> 3) : bgm_right;
    wire signed [16:0] sum_left = $signed(left_in[15:0]) + $signed(music_left);
    wire signed [16:0] sum_right = $signed(right_in[15:0]) + $signed(music_right);
    function signed [23:0] clip;
        input signed [16:0] value;
        begin
            clip = value > 17'sd32767 ? 24'sd32767 :
                value < -17'sd32768 ? -24'sd32768 : {{7{value[16]}},value};
        end
    endfunction
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin sample_valid_out<=0; left_out<=0; right_out<=0; end
        else begin
            sample_valid_out<=sample_valid;
            if (sample_valid) begin left_out<=clip(sum_left); right_out<=clip(sum_right); end
        end
    end
endmodule

// Attenuate the signed 16-bit mix, then align it to the HDMI 24-bit sample
// field. Slew gain at the sample rate; a full-range ramp takes about 5.3 ms.
module audio_volume_gain (
    input wire clk, rst_n, sample_valid,
    input wire signed [23:0] left_in, right_in,
    input wire [8:0] target_gain,
    output reg sample_valid_out,
    output reg signed [23:0] left_out, right_out
);
    reg [8:0] current_gain;
    wire signed [9:0] scale = $signed({1'b0,current_gain});
    wire signed [25:0] left_product = $signed(left_in[15:0]) * scale;
    wire signed [25:0] right_product = $signed(right_in[15:0]) * scale;
    reg signed [25:0] left_product_q, right_product_q;
    reg product_valid_q;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            current_gain <= 9'd256;
            left_product_q <= 0;
            right_product_q <= 0;
            product_valid_q <= 0;
            sample_valid_out <= 0;
            left_out <= 0;
            right_out <= 0;
        end else begin
            product_valid_q <= sample_valid;
            sample_valid_out <= product_valid_q;
            if (sample_valid) begin
                if (current_gain < target_gain) current_gain <= current_gain + 1'b1;
                else if (current_gain > target_gain) current_gain <= current_gain - 1'b1;
                left_product_q <= left_product;
                right_product_q <= right_product;
            end
            if (product_valid_q) begin
                left_out <= {left_product_q[23:8],8'b0};
                right_out <= {right_product_q[23:8],8'b0};
            end else begin
                left_out <= 0;
                right_out <= 0;
            end
        end
    end
endmodule

// 40 ms, approximately 1 kHz confirmation tone at the existing 48 kHz rate.
// Keep the cue after the narration fade so it remains audible during a wipe.
module manual_page_beep (
    input wire clk, rst_n, trigger, emergency_active, sample_valid,
    input wire signed [23:0] left_in, right_in,
    output reg sample_valid_out,
    output reg signed [23:0] left_out, right_out
);
    reg active;
    reg [10:0] sample_count;
    reg [15:0] phase;
    wire [10:0] tail_count = 11'd1919 - sample_count;
    wire [7:0] envelope = sample_count < 128 ? {1'b0,sample_count[6:0]} :
                          tail_count < 128 ? {1'b0,tail_count[6:0]} : 8'd128;
    reg signed [11:0] wave;
    always @* begin
        case (phase[15:12])
            0,8: wave = 0;
            1,7: wave = 784;
            2,6: wave = 1448;
            3,5: wave = 1892;
            4: wave = 2047;
            9,15: wave = -784;
            10,14: wave = -1448;
            11,13: wave = -1892;
            default: wave = -2047;
        endcase
    end
    wire signed [20:0] shaped = wave * $signed({1'b0,envelope});
    wire signed [23:0] cue = active && !emergency_active ?
                            {{10{shaped[20]}},shaped[20:7]} : 24'sd0;
    reg signed [23:0] cue_q, left_q, right_q;
    reg signed [24:0] mixed_left_q, mixed_right_q;
    reg cue_valid_q, mix_valid_q;
    function signed [23:0] saturate_pcm16;
        input signed [24:0] value;
        begin
            if (value > 25'sd32767) saturate_pcm16 = 24'sd32767;
            else if (value < -25'sd32768) saturate_pcm16 = -24'sd32768;
            else saturate_pcm16 = value[23:0];
        end
    endfunction
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            active <= 0;
            sample_count <= 0;
            phase <= 0;
            cue_q <= 0;
            left_q <= 0;
            right_q <= 0;
            mixed_left_q <= 0;
            mixed_right_q <= 0;
            cue_valid_q <= 0;
            mix_valid_q <= 0;
            sample_valid_out <= 0;
            left_out <= 0;
            right_out <= 0;
        end else begin
            // Separate envelope multiplication, mixing and saturation so
            // the cue does not extend the pixel-clock critical path.
            cue_valid_q <= sample_valid;
            mix_valid_q <= cue_valid_q;
            sample_valid_out <= mix_valid_q;
            if (cue_valid_q) begin
                mixed_left_q <= {left_q[23],left_q} + {cue_q[23],cue_q};
                mixed_right_q <= {right_q[23],right_q} + {cue_q[23],cue_q};
            end
            if (mix_valid_q) begin
                left_out <= saturate_pcm16(mixed_left_q);
                right_out <= saturate_pcm16(mixed_right_q);
            end
            if (sample_valid) begin
                cue_q <= cue;
                left_q <= left_in;
                right_q <= right_in;
                if (active) begin
                    phase <= phase + 16'd1365;
                    if (sample_count == 1919) active <= 0;
                    else sample_count <= sample_count + 1'b1;
                end
            end
            if (trigger) begin
                active <= 1;
                sample_count <= 0;
                phase <= 0;
            end
            if (emergency_active) begin
                active <= 0;
                sample_count <= 0;
                phase <= 0;
            end
        end
    end
endmodule
