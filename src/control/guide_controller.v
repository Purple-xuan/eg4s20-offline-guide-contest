`timescale 1ns/1ps

module guide_controller (
    input  wire       clk,
    input  wire       rst,
    input  wire       next_event,
    input  wire       toggle_auto_event,
    input  wire       toggle_emergency_event,
    input  wire       error_active,
    output reg  [1:0] state,
    output reg        next_page_pulse,
    output wire       auto_play_enabled,
    output wire       emergency_active,
    output reg        emergency_enter_pulse,
    output reg        emergency_exit_pulse
);

    localparam [1:0] NORMAL_AUTO   = 2'd0;
    localparam [1:0] NORMAL_MANUAL = 2'd1;
    localparam [1:0] EMERGENCY     = 2'd2;
    localparam [1:0] ERROR         = 2'd3;

    reg saved_auto_mode;

    assign auto_play_enabled = state == NORMAL_AUTO;
    assign emergency_active = state == EMERGENCY;

    always @(posedge clk or posedge rst) begin
        if (rst) begin
            state <= NORMAL_MANUAL;
            saved_auto_mode <= 1'b0;
            next_page_pulse <= 1'b0;
            emergency_enter_pulse <= 1'b0;
            emergency_exit_pulse <= 1'b0;
        end else begin
            next_page_pulse <= 1'b0;
            emergency_enter_pulse <= 1'b0;
            emergency_exit_pulse <= 1'b0;

            // Emergency toggles have priority over normal events and errors.
            if (toggle_emergency_event) begin
                if (state == EMERGENCY) begin
                    state <= error_active ? ERROR :
                             (saved_auto_mode ? NORMAL_AUTO : NORMAL_MANUAL);
                    emergency_exit_pulse <= 1'b1;
                end else begin
                    if (state == NORMAL_AUTO)
                        saved_auto_mode <= 1'b1;
                    else if (state == NORMAL_MANUAL)
                        saved_auto_mode <= 1'b0;
                    state <= EMERGENCY;
                    emergency_enter_pulse <= 1'b1;
                end
            end else if (state == EMERGENCY) begin
                state <= EMERGENCY;
            end else if (error_active) begin
                state <= ERROR;
            end else if (state == ERROR) begin
                state <= saved_auto_mode ? NORMAL_AUTO : NORMAL_MANUAL;
            end else begin
                if (toggle_auto_event) begin
                    saved_auto_mode <= ~saved_auto_mode;
                    state <= saved_auto_mode ? NORMAL_MANUAL : NORMAL_AUTO;
                end
                if (next_event)
                    next_page_pulse <= 1'b1;
            end
        end
    end

endmodule
