`timescale 1ns/1ps

module input_event_router #(
    parameter integer CLK_FREQ_HZ   = 100_000_000,
    parameter integer DEBOUNCE_MS   = 20,
    parameter integer LONG_PRESS_MS = 1500,
    parameter integer ENABLE_NEXT_LONG_PRESS = 1,
    parameter integer USE_SHARED_DEBOUNCE_TICK = 0
) (
    input  wire clk,
    input  wire rst,
    input  wire debounce_ms_tick,
    input  wire key_next_n,
    input  wire key_auto_n,
    input  wire key_emergency_n,
    input  wire brightness_adjust_mode,
    output reg  next_event,
    output reg  toggle_auto_event,
    output reg  toggle_emergency_event,
    output wire key_next_pressed,
    output wire key_auto_pressed
);

    localparam integer LONG_PRESS_CYCLES_RAW =
        (CLK_FREQ_HZ / 1000) * LONG_PRESS_MS;
    localparam integer LONG_PRESS_CYCLES =
        (LONG_PRESS_CYCLES_RAW < 1) ? 1 : LONG_PRESS_CYCLES_RAW;
    localparam integer HOLD_BITS = (LONG_PRESS_CYCLES > 1) ? $clog2(LONG_PRESS_CYCLES) : 1;

    wire next_level_n;
    wire auto_level_n;
    wire emergency_level_n;
    reg next_level_d;
    reg auto_level_d;
    reg emergency_level_d;
    reg [HOLD_BITS-1:0] next_hold_count;
    reg next_long_reported;
    reg adjust_mode_d, next_blocked;

    assign key_next_pressed = ~next_level_n;
    assign key_auto_pressed = ~auto_level_n;

    button_level_debounce #(
        .CLK_FREQ_HZ(CLK_FREQ_HZ),
        .DEBOUNCE_MS(DEBOUNCE_MS), .USE_SHARED_TICK(USE_SHARED_DEBOUNCE_TICK)
    ) u_next_debounce (
        .clk(clk),
        .rst(rst),
        .ms_tick(debounce_ms_tick),
        .button_in_n(key_next_n),
        .stable_level_n(next_level_n)
    );

    button_level_debounce #(
        .CLK_FREQ_HZ(CLK_FREQ_HZ),
        .DEBOUNCE_MS(DEBOUNCE_MS), .USE_SHARED_TICK(USE_SHARED_DEBOUNCE_TICK)
    ) u_auto_debounce (
        .clk(clk),
        .rst(rst),
        .ms_tick(debounce_ms_tick),
        .button_in_n(key_auto_n),
        .stable_level_n(auto_level_n)
    );

    button_level_debounce #(
        .CLK_FREQ_HZ(CLK_FREQ_HZ),
        .DEBOUNCE_MS(DEBOUNCE_MS), .USE_SHARED_TICK(USE_SHARED_DEBOUNCE_TICK)
    ) u_emergency_debounce (
        .clk(clk),
        .rst(rst),
        .ms_tick(debounce_ms_tick),
        .button_in_n(key_emergency_n),
        .stable_level_n(emergency_level_n)
    );

    always @(posedge clk or posedge rst) begin
        if (rst) begin
            next_level_d <= 1'b1;
            auto_level_d <= 1'b1;
            emergency_level_d <= 1'b1;
            next_hold_count <= 32'd0;
            next_long_reported <= 1'b0;
            adjust_mode_d <= 1'b0;
            next_blocked <= 1'b0;
            next_event <= 1'b0;
            toggle_auto_event <= 1'b0;
            toggle_emergency_event <= 1'b0;
        end else begin
            next_level_d <= next_level_n;
            auto_level_d <= auto_level_n;
            emergency_level_d <= emergency_level_n;
            adjust_mode_d <= brightness_adjust_mode;
            next_event <= 1'b0;
            toggle_auto_event <= 1'b0;
            toggle_emergency_event <= 1'b0;

            if (auto_level_d && !auto_level_n)
                toggle_auto_event <= 1'b1;

            // KEY3 is a dedicated, debounced emergency toggle. It is
            // intentionally independent of KEY1's long-press path.
            if (emergency_level_d && !emergency_level_n)
                toggle_emergency_event <= 1'b1;

            // Consume the full press across a mode change. Releasing a key
            // used for picture adjustment must not turn a page or enter emergency.
            if (brightness_adjust_mode || adjust_mode_d != brightness_adjust_mode || next_blocked) begin
                next_hold_count <= 0;
                next_long_reported <= 0;
                next_blocked <= brightness_adjust_mode ||
                                adjust_mode_d != brightness_adjust_mode || !next_level_n;
            end else if (!next_level_n) begin
                if (next_level_d) begin
                    next_hold_count <= 32'd1;
                    next_long_reported <= 1'b0;
                end else if (ENABLE_NEXT_LONG_PRESS && !next_long_reported) begin
                    if (next_hold_count >= LONG_PRESS_CYCLES - 1) begin
                        toggle_emergency_event <= 1'b1;
                        next_long_reported <= 1'b1;
                    end else begin
                        next_hold_count <= next_hold_count + 1'b1;
                    end
                end
            end else begin
                if (!next_level_d && !next_long_reported)
                    next_event <= 1'b1;
                next_hold_count <= 32'd0;
                next_long_reported <= 1'b0;
            end
        end
    end

endmodule

module button_level_debounce #(
    parameter integer CLK_FREQ_HZ = 100_000_000,
    parameter integer DEBOUNCE_MS = 20,
    parameter integer USE_SHARED_TICK = 0
) (
    input  wire clk,
    input  wire rst,
    input  wire ms_tick,
    input  wire button_in_n,
    output reg  stable_level_n
);

    localparam integer DEBOUNCE_CYCLES_RAW =
        (CLK_FREQ_HZ / 1000) * DEBOUNCE_MS;
    localparam integer DEBOUNCE_CYCLES =
        (DEBOUNCE_CYCLES_RAW < 1) ? 1 : DEBOUNCE_CYCLES_RAW;
    localparam integer COUNT_BITS = USE_SHARED_TICK ?
        ((DEBOUNCE_MS > 1) ? $clog2(DEBOUNCE_MS) : 1) :
        ((DEBOUNCE_CYCLES > 1) ? $clog2(DEBOUNCE_CYCLES) : 1);
    localparam integer COUNT_LIMIT = USE_SHARED_TICK ? DEBOUNCE_MS : DEBOUNCE_CYCLES;

    reg sync_0;
    reg sync_1;
    reg [COUNT_BITS-1:0] debounce_count;

    always @(posedge clk or posedge rst) begin
        if (rst) begin
            sync_0 <= 1'b1;
            sync_1 <= 1'b1;
            stable_level_n <= 1'b1;
            debounce_count <= 32'd0;
        end else begin
            sync_0 <= button_in_n;
            sync_1 <= sync_0;

            if (sync_1 == stable_level_n) begin
                debounce_count <= 32'd0;
            end else if ((!USE_SHARED_TICK || ms_tick) &&
                         debounce_count >= COUNT_LIMIT - 1) begin
                stable_level_n <= sync_1;
                debounce_count <= 32'd0;
            end else if (!USE_SHARED_TICK || ms_tick) begin
                debounce_count <= debounce_count + 1'b1;
            end
        end
    end

endmodule
