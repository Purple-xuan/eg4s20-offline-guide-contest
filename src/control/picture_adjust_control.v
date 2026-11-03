`timescale 1ns/1ps

// Both settings arrive through an atomic frame-boundary mailbox.
module picture_adjust_control (
    input  wire       clk,
    input  wire       rst_n,
    input  wire       frame_start,
    input  wire [7:0] brightness_setting,
    input  wire [7:0] contrast_setting,
    input  wire       emergency_active_async,
    output wire [7:0] brightness,
    output wire [7:0] contrast
);
    reg emergency_sync1, emergency_sync2;

    reg emergency_active_frame;
    reg [7:0] selected_brightness;
    reg [7:0] selected_contrast;

    assign brightness = emergency_active_frame ? 8'd255 : selected_brightness;
    assign contrast = emergency_active_frame ? 8'd128 : selected_contrast;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            emergency_sync1 <= 1'b0;
            emergency_sync2 <= 1'b0;
        end else begin
            emergency_sync1 <= emergency_active_async;
            emergency_sync2 <= emergency_sync1;
        end
    end

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            emergency_active_frame <= 1'b0;
            selected_brightness <= 8'd255;
            selected_contrast <= 8'd128;
        end else if (frame_start) begin
            emergency_active_frame <= emergency_sync2;
            selected_brightness <= brightness_setting;
            selected_contrast <= contrast_setting;
        end
    end
endmodule

// Volume is available independently of the home navigation state. Keeping
// the toggle and adjustment together lets the integration test use the same
// button path as the board, including release guards and emergency suspension.
module volume_key_control #(
    parameter integer CLK_FREQ_HZ=100_000_000,
    parameter integer DEBOUNCE_MS=20
) (
    input wire clk,rst,button_n,increase_pressed,decrease_pressed,
    input wire emergency_active,
    output wire adjust_mode,
    output wire [6:0] percent,
    output wire [7:0] setting
);
    wire level_n;
    reg level_d,requested;
    button_level_debounce #(.CLK_FREQ_HZ(CLK_FREQ_HZ),.DEBOUNCE_MS(DEBOUNCE_MS)) button (
        .clk(clk),.rst(rst),.button_in_n(button_n),.stable_level_n(level_n));
    always @(posedge clk or posedge rst) begin
        if(rst) begin level_d<=1;requested<=0;end
        else begin
            level_d<=level_n;
            if(level_d && !level_n && !emergency_active) requested<=!requested;
        end
    end
    brightness_key_control #(.CLK_FREQ_HZ(CLK_FREQ_HZ),.DEBOUNCE_MS(0),.MIN_PERCENT(0)) control (
        .clk(clk),.rst(rst),.mode_switch(requested),
        .increase_pressed(increase_pressed),.decrease_pressed(decrease_pressed),
        .direct_valid(1'b0),.direct_percent(8'd0),
        .emergency_active(emergency_active),.adjust_mode(adjust_mode),
        .percent(percent),.setting(setting));
endmodule

module brightness_key_control #(
    parameter integer CLK_FREQ_HZ = 100_000_000,
    parameter integer DEBOUNCE_MS = 20,
    parameter integer HOLD_DELAY_MS = 350,
    parameter integer REPEAT_MS = 40,
    parameter integer MIN_PERCENT = 30,
    parameter integer MAX_PERCENT = 100,
    parameter integer PERCENT_BITS = 7,
    parameter integer CONTRAST = 0,
    parameter integer USE_SHARED_DEBOUNCE_TICK = 0
) (
    input wire clk, rst,
    input wire debounce_ms_tick,
    input wire mode_switch,
    input wire increase_pressed, decrease_pressed,
    input wire direct_valid,
    input wire [7:0] direct_percent,
    input wire emergency_active,
    output wire adjust_mode,
    output reg [PERCENT_BITS-1:0] percent,
    output wire [7:0] setting
);
    localparam integer HOLD_CYCLES = (CLK_FREQ_HZ / 1000) * HOLD_DELAY_MS;
    localparam integer REPEAT_CYCLES = (CLK_FREQ_HZ / 1000) * REPEAT_MS;
    localparam integer COUNT_W = $clog2(HOLD_CYCLES + REPEAT_CYCLES + 2);
    wire mode_n;
    reg [COUNT_W-1:0] repeat_count;
    reg keys_ready, key_held, held_direction;
    wire one_key = increase_pressed ^ decrease_pressed;
    wire repeat_step = key_held && repeat_count == 0;
    wire step = adjust_mode && keys_ready && one_key &&
                (!key_held || held_direction != increase_pressed || repeat_step);
    // round(256*percent/100)-1, implemented as a small ROM so the mailbox
    // comparator does not sit after a multiplier and two arithmetic stages.
    function [7:0] gain_for_percent;
        input [6:0] value;
        begin
            case (value)
            7'd0: gain_for_percent = 8'd0;
            7'd1: gain_for_percent = 8'd2;
            7'd2: gain_for_percent = 8'd4;
            7'd3: gain_for_percent = 8'd7;
            7'd4: gain_for_percent = 8'd9;
            7'd5: gain_for_percent = 8'd12;
            7'd6: gain_for_percent = 8'd14;
            7'd7: gain_for_percent = 8'd17;
            7'd8: gain_for_percent = 8'd19;
            7'd9: gain_for_percent = 8'd22;
            7'd10: gain_for_percent = 8'd25;
            7'd11: gain_for_percent = 8'd27;
            7'd12: gain_for_percent = 8'd30;
            7'd13: gain_for_percent = 8'd32;
            7'd14: gain_for_percent = 8'd35;
            7'd15: gain_for_percent = 8'd37;
            7'd16: gain_for_percent = 8'd40;
            7'd17: gain_for_percent = 8'd43;
            7'd18: gain_for_percent = 8'd45;
            7'd19: gain_for_percent = 8'd48;
            7'd20: gain_for_percent = 8'd50;
            7'd21: gain_for_percent = 8'd53;
            7'd22: gain_for_percent = 8'd55;
            7'd23: gain_for_percent = 8'd58;
            7'd24: gain_for_percent = 8'd60;
            7'd25: gain_for_percent = 8'd63;
            7'd26: gain_for_percent = 8'd66;
            7'd27: gain_for_percent = 8'd68;
            7'd28: gain_for_percent = 8'd71;
            7'd29: gain_for_percent = 8'd73;
            7'd30: gain_for_percent = 8'd76;
            7'd31: gain_for_percent = 8'd78;
            7'd32: gain_for_percent = 8'd81;
            7'd33: gain_for_percent = 8'd83;
            7'd34: gain_for_percent = 8'd86;
            7'd35: gain_for_percent = 8'd89;
            7'd36: gain_for_percent = 8'd91;
            7'd37: gain_for_percent = 8'd94;
            7'd38: gain_for_percent = 8'd96;
            7'd39: gain_for_percent = 8'd99;
            7'd40: gain_for_percent = 8'd101;
            7'd41: gain_for_percent = 8'd104;
            7'd42: gain_for_percent = 8'd107;
            7'd43: gain_for_percent = 8'd109;
            7'd44: gain_for_percent = 8'd112;
            7'd45: gain_for_percent = 8'd114;
            7'd46: gain_for_percent = 8'd117;
            7'd47: gain_for_percent = 8'd119;
            7'd48: gain_for_percent = 8'd122;
            7'd49: gain_for_percent = 8'd124;
            7'd50: gain_for_percent = 8'd127;
            7'd51: gain_for_percent = 8'd130;
            7'd52: gain_for_percent = 8'd132;
            7'd53: gain_for_percent = 8'd135;
            7'd54: gain_for_percent = 8'd137;
            7'd55: gain_for_percent = 8'd140;
            7'd56: gain_for_percent = 8'd142;
            7'd57: gain_for_percent = 8'd145;
            7'd58: gain_for_percent = 8'd147;
            7'd59: gain_for_percent = 8'd150;
            7'd60: gain_for_percent = 8'd153;
            7'd61: gain_for_percent = 8'd155;
            7'd62: gain_for_percent = 8'd158;
            7'd63: gain_for_percent = 8'd160;
            7'd64: gain_for_percent = 8'd163;
            7'd65: gain_for_percent = 8'd165;
            7'd66: gain_for_percent = 8'd168;
            7'd67: gain_for_percent = 8'd171;
            7'd68: gain_for_percent = 8'd173;
            7'd69: gain_for_percent = 8'd176;
            7'd70: gain_for_percent = 8'd178;
            7'd71: gain_for_percent = 8'd181;
            7'd72: gain_for_percent = 8'd183;
            7'd73: gain_for_percent = 8'd186;
            7'd74: gain_for_percent = 8'd188;
            7'd75: gain_for_percent = 8'd191;
            7'd76: gain_for_percent = 8'd194;
            7'd77: gain_for_percent = 8'd196;
            7'd78: gain_for_percent = 8'd199;
            7'd79: gain_for_percent = 8'd201;
            7'd80: gain_for_percent = 8'd204;
            7'd81: gain_for_percent = 8'd206;
            7'd82: gain_for_percent = 8'd209;
            7'd83: gain_for_percent = 8'd211;
            7'd84: gain_for_percent = 8'd214;
            7'd85: gain_for_percent = 8'd217;
            7'd86: gain_for_percent = 8'd219;
            7'd87: gain_for_percent = 8'd222;
            7'd88: gain_for_percent = 8'd224;
            7'd89: gain_for_percent = 8'd227;
            7'd90: gain_for_percent = 8'd229;
            7'd91: gain_for_percent = 8'd232;
            7'd92: gain_for_percent = 8'd235;
            7'd93: gain_for_percent = 8'd237;
            7'd94: gain_for_percent = 8'd240;
            7'd95: gain_for_percent = 8'd242;
            7'd96: gain_for_percent = 8'd245;
            7'd97: gain_for_percent = 8'd247;
            7'd98: gain_for_percent = 8'd250;
            7'd99: gain_for_percent = 8'd252;
            7'd100: gain_for_percent = 8'd255;
            default: gain_for_percent = 8'd255;
            endcase
        end
    endfunction
    // Contrast arithmetic uses 128 as unity; retain a ROM on the control path.
    function [7:0] contrast_for_percent;
        input [7:0] value;
        begin
            case (value)
                8'd50: contrast_for_percent = 8'd64;
                8'd51: contrast_for_percent = 8'd65;
                8'd52: contrast_for_percent = 8'd67;
                8'd53: contrast_for_percent = 8'd68;
                8'd54: contrast_for_percent = 8'd69;
                8'd55: contrast_for_percent = 8'd70;
                8'd56: contrast_for_percent = 8'd72;
                8'd57: contrast_for_percent = 8'd73;
                8'd58: contrast_for_percent = 8'd74;
                8'd59: contrast_for_percent = 8'd76;
                8'd60: contrast_for_percent = 8'd77;
                8'd61: contrast_for_percent = 8'd78;
                8'd62: contrast_for_percent = 8'd79;
                8'd63: contrast_for_percent = 8'd81;
                8'd64: contrast_for_percent = 8'd82;
                8'd65: contrast_for_percent = 8'd83;
                8'd66: contrast_for_percent = 8'd84;
                8'd67: contrast_for_percent = 8'd86;
                8'd68: contrast_for_percent = 8'd87;
                8'd69: contrast_for_percent = 8'd88;
                8'd70: contrast_for_percent = 8'd90;
                8'd71: contrast_for_percent = 8'd91;
                8'd72: contrast_for_percent = 8'd92;
                8'd73: contrast_for_percent = 8'd93;
                8'd74: contrast_for_percent = 8'd95;
                8'd75: contrast_for_percent = 8'd96;
                8'd76: contrast_for_percent = 8'd97;
                8'd77: contrast_for_percent = 8'd99;
                8'd78: contrast_for_percent = 8'd100;
                8'd79: contrast_for_percent = 8'd101;
                8'd80: contrast_for_percent = 8'd102;
                8'd81: contrast_for_percent = 8'd104;
                8'd82: contrast_for_percent = 8'd105;
                8'd83: contrast_for_percent = 8'd106;
                8'd84: contrast_for_percent = 8'd108;
                8'd85: contrast_for_percent = 8'd109;
                8'd86: contrast_for_percent = 8'd110;
                8'd87: contrast_for_percent = 8'd111;
                8'd88: contrast_for_percent = 8'd113;
                8'd89: contrast_for_percent = 8'd114;
                8'd90: contrast_for_percent = 8'd115;
                8'd91: contrast_for_percent = 8'd116;
                8'd92: contrast_for_percent = 8'd118;
                8'd93: contrast_for_percent = 8'd119;
                8'd94: contrast_for_percent = 8'd120;
                8'd95: contrast_for_percent = 8'd122;
                8'd96: contrast_for_percent = 8'd123;
                8'd97: contrast_for_percent = 8'd124;
                8'd98: contrast_for_percent = 8'd125;
                8'd99: contrast_for_percent = 8'd127;
                8'd100: contrast_for_percent = 8'd128;
                8'd101: contrast_for_percent = 8'd129;
                8'd102: contrast_for_percent = 8'd131;
                8'd103: contrast_for_percent = 8'd132;
                8'd104: contrast_for_percent = 8'd133;
                8'd105: contrast_for_percent = 8'd134;
                8'd106: contrast_for_percent = 8'd136;
                8'd107: contrast_for_percent = 8'd137;
                8'd108: contrast_for_percent = 8'd138;
                8'd109: contrast_for_percent = 8'd140;
                8'd110: contrast_for_percent = 8'd141;
                8'd111: contrast_for_percent = 8'd142;
                8'd112: contrast_for_percent = 8'd143;
                8'd113: contrast_for_percent = 8'd145;
                8'd114: contrast_for_percent = 8'd146;
                8'd115: contrast_for_percent = 8'd147;
                8'd116: contrast_for_percent = 8'd148;
                8'd117: contrast_for_percent = 8'd150;
                8'd118: contrast_for_percent = 8'd151;
                8'd119: contrast_for_percent = 8'd152;
                8'd120: contrast_for_percent = 8'd154;
                8'd121: contrast_for_percent = 8'd155;
                8'd122: contrast_for_percent = 8'd156;
                8'd123: contrast_for_percent = 8'd157;
                8'd124: contrast_for_percent = 8'd159;
                8'd125: contrast_for_percent = 8'd160;
                8'd126: contrast_for_percent = 8'd161;
                8'd127: contrast_for_percent = 8'd163;
                8'd128: contrast_for_percent = 8'd164;
                8'd129: contrast_for_percent = 8'd165;
                8'd130: contrast_for_percent = 8'd166;
                8'd131: contrast_for_percent = 8'd168;
                8'd132: contrast_for_percent = 8'd169;
                8'd133: contrast_for_percent = 8'd170;
                8'd134: contrast_for_percent = 8'd172;
                8'd135: contrast_for_percent = 8'd173;
                8'd136: contrast_for_percent = 8'd174;
                8'd137: contrast_for_percent = 8'd175;
                8'd138: contrast_for_percent = 8'd177;
                8'd139: contrast_for_percent = 8'd178;
                8'd140: contrast_for_percent = 8'd179;
                8'd141: contrast_for_percent = 8'd180;
                8'd142: contrast_for_percent = 8'd182;
                8'd143: contrast_for_percent = 8'd183;
                8'd144: contrast_for_percent = 8'd184;
                8'd145: contrast_for_percent = 8'd186;
                8'd146: contrast_for_percent = 8'd187;
                8'd147: contrast_for_percent = 8'd188;
                8'd148: contrast_for_percent = 8'd189;
                8'd149: contrast_for_percent = 8'd191;
                8'd150: contrast_for_percent = 8'd192;
                default: contrast_for_percent = 8'd128;
            endcase
        end
    endfunction
    // The UI changes percent at human speed. Use a synchronous block ROM
    // instead of a large combinational decode. Address with the next percent
    // so the registered gain and percent change on the same clock edge.
    (* ram_style="bram", rom_style="bram" *)
    reg [7:0] setting_rom [0:(1<<PERCENT_BITS)-1];
    integer rom_index;
    initial begin
        for (rom_index=0; rom_index<(1<<PERCENT_BITS); rom_index=rom_index+1)
            setting_rom[rom_index] = CONTRAST ? contrast_for_percent(rom_index) : gain_for_percent(rom_index);
    end
    wire [PERCENT_BITS-1:0] direct_clamped =
        direct_percent < MIN_PERCENT ? MIN_PERCENT :
        direct_percent > MAX_PERCENT ? MAX_PERCENT : direct_percent;
    wire [PERCENT_BITS-1:0] next_percent = rst ? 100 :
        direct_valid && adjust_mode ? direct_clamped :
        step && increase_pressed && percent < MAX_PERCENT ? percent+1'b1 :
        step && decrease_pressed && percent > MIN_PERCENT ? percent-1'b1 : percent;
    reg [7:0] setting_q;
    always @(posedge clk)
        setting_q <= setting_rom[next_percent];
    assign setting = setting_q;
    assign adjust_mode = !mode_n && !emergency_active;
    button_level_debounce #(.CLK_FREQ_HZ(CLK_FREQ_HZ), .DEBOUNCE_MS(DEBOUNCE_MS),
        .USE_SHARED_TICK(USE_SHARED_DEBOUNCE_TICK))
    u_mode_debounce (.clk(clk), .rst(rst), .ms_tick(debounce_ms_tick),
        .button_in_n(~mode_switch), .stable_level_n(mode_n));

    always @(posedge clk or posedge rst) begin
        if (rst) begin
            percent <= 100;
            repeat_count <= 0;
            keys_ready <= 0;
            key_held <= 0;
            held_direction <= 0;
        end else if (!adjust_mode) begin
            keys_ready <= 0;
            key_held <= 0;
            repeat_count <= 0;
        end else if (!keys_ready) begin
            if (!increase_pressed && !decrease_pressed)
                keys_ready <= 1;
        end else begin
            if (!one_key) begin
                key_held <= 0;
                repeat_count <= 0;
            end else if (!key_held || held_direction != increase_pressed) begin
                key_held <= 1;
                held_direction <= increase_pressed;
                repeat_count <= HOLD_CYCLES > 0 ? HOLD_CYCLES - 1 : 0;
            end else if (repeat_count == 0) begin
                repeat_count <= REPEAT_CYCLES > 0 ? REPEAT_CYCLES - 1 : 0;
            end else begin
                repeat_count <= repeat_count - 1'b1;
            end
            if (direct_valid) begin
                percent <= direct_clamped;
                key_held <= 0;
                repeat_count <= 0;
            end else if (step) begin
                if (increase_pressed && percent < MAX_PERCENT)
                    percent <= percent + 1'b1;
                else if (decrease_pressed && percent > MIN_PERCENT)
                    percent <= percent - 1'b1;
            end
        end
    end
endmodule
