`timescale 1ns/1ps

// Loader-side nearest-neighbor scaler. One source row is buffered while the
// upstream stream is backpressured, then rendered into one or more rows of a
// fixed-size destination frame. Pixels outside the configured viewport are
// emitted as black letterbox/pillarbox pixels.
module nearest_letterbox_scaler #(
    parameter integer TARGET_WIDTH = 1280,
    parameter integer TARGET_HEIGHT = 720,
    parameter integer MAX_SOURCE_WIDTH = 1920,
    parameter integer MAX_SOURCE_HEIGHT = 1080,
    parameter integer ENABLE_ROI = 0,
    parameter integer RESTART_ON_START = 0
) (
    input  wire        clk,
    input  wire        rst,
    input  wire        start,
    input  wire [15:0] source_width,
    input  wire [15:0] source_height,
    input  wire [15:0] active_width,
    input  wire [15:0] active_height,
    input  wire [15:0] x_offset,
    input  wire [15:0] y_offset,
    input  wire        crop_enable,
    input  wire [15:0] crop_x,
    input  wire [15:0] crop_y,
    input  wire [15:0] crop_width,
    input  wire [15:0] crop_height,
    input  wire        source_reverse_y,

    input  wire        in_valid,
    output wire        in_ready,
    input  wire [23:0] in_pixel,

    output reg         out_valid,
    input  wire        out_ready,
    output reg  [23:0] out_pixel,
    output reg  [15:0] out_x,
    output reg  [15:0] out_y,
    output reg         out_sof,
    output reg         out_eol,
    output reg         out_eof,

    output reg         busy,
    output reg         done,
    output reg         config_error
);
    localparam [2:0] ST_IDLE    = 3'd0;
    localparam [2:0] ST_TOP     = 3'd1;
    localparam [2:0] ST_CAPTURE = 3'd2;
    localparam [2:0] ST_ACTIVE  = 3'd3;
    localparam [2:0] ST_DRAIN   = 3'd4;
    localparam [2:0] ST_BOTTOM  = 3'd5;
    localparam [2:0] ST_SETUP   = 3'd6;
    localparam [2:0] ST_BEGIN   = 3'd7;
    localparam integer LINE_BUFFER_DEPTH = 2048;
    localparam integer X_BITS = $clog2(MAX_SOURCE_WIDTH + 1);
    localparam integer Y_BITS = $clog2(MAX_SOURCE_HEIGHT + 1);
    localparam integer FX_BITS = $clog2(TARGET_WIDTH + 1);
    localparam integer FY_BITS = $clog2(TARGET_HEIGHT + 1);
    localparam integer XP_BITS = X_BITS > FX_BITS ? X_BITS : FX_BITS;
    localparam integer YP_BITS = Y_BITS > FY_BITS ? Y_BITS : FY_BITS;

    reg [2:0] state;
    (* ram_style = "bram" *)
    reg [23:0] line_buffer [0:LINE_BUFFER_DEPTH-1];

    reg [X_BITS-1:0] source_width_q;
    reg [Y_BITS-1:0] source_height_q;
    reg [FX_BITS-1:0] active_width_q;
    reg [FY_BITS-1:0] active_height_q;
    reg [FX_BITS-1:0] x_offset_q;
    reg [FY_BITS-1:0] y_offset_q;
    reg [X_BITS-1:0] crop_x_q, crop_width_q;
    reg [Y_BITS-1:0] crop_height_q;
    reg [X_BITS-1:0] crop_last_x_q;
    reg [Y_BITS:0] crop_bottom_q;
    reg [Y_BITS-1:0] crop_y_q, stream_y_q;
    reg reverse_y_q, initial_y_step_q;

    reg [X_BITS-1:0] input_x;
    reg [Y_BITS-1:0] input_y;
    reg [FX_BITS-1:0] frame_x;
    reg [FY_BITS-1:0] frame_y;
    reg [X_BITS-1:0] source_x_select;
    reg [Y_BITS-1:0] desired_source_y;
    reg [XP_BITS-1:0] x_phase;
    reg [YP_BITS-1:0] y_phase;
    reg [FY_BITS-1:0] active_row_index;
    reg        line_read_pending;
    reg [23:0] line_read_data;
    reg        config_invalid_q;

    wire input_state = (state == ST_CAPTURE) || (state == ST_DRAIN);
    assign in_ready = busy && input_state;

    wire use_crop = ENABLE_ROI && crop_enable;
    wire [15:0] selected_x = use_crop ? crop_x : 16'd0;
    wire [15:0] selected_y = use_crop ? crop_y : 16'd0;
    wire [15:0] selected_width = use_crop ? crop_width : source_width;
    wire [15:0] selected_height = use_crop ? crop_height : source_height;
    wire reverse_y = ENABLE_ROI && source_reverse_y;
    // Validate the latched configuration in ST_SETUP.  Keeping the wide
    // header fields out of the start-cycle busy decision removes a long
    // comparator path from the SD-card clock domain.
    wire config_invalid =
        source_width_q == 0 || source_height_q == 0 ||
        source_width_q > MAX_SOURCE_WIDTH ||
        source_width_q > LINE_BUFFER_DEPTH ||
        source_height_q > MAX_SOURCE_HEIGHT ||
        active_width_q == 0 || active_height_q == 0 ||
        active_width_q > TARGET_WIDTH || active_height_q > TARGET_HEIGHT ||
        ({1'b0, x_offset_q} + {1'b0, active_width_q}) > TARGET_WIDTH ||
        ({1'b0, y_offset_q} + {1'b0, active_height_q}) > TARGET_HEIGHT ||
        crop_width_q == 0 || crop_height_q == 0 ||
        ({1'b0, crop_x_q} + {1'b0, crop_width_q}) > source_width_q ||
        ({1'b0, crop_y_q} + {1'b0, crop_height_q}) > source_height_q ||
        crop_width_q > ({1'b0, active_width_q} << 1) ||
        crop_height_q > ({1'b0, active_height_q} << 1);

    wire [XP_BITS:0] x_phase_sum =
        {1'b0, x_phase} + {1'b0, crop_width_q};
    wire [XP_BITS:0] active_width_twice =
        {1'b0, active_width_q, 1'b0};
    wire [YP_BITS:0] y_phase_sum =
        {1'b0, y_phase} + {1'b0, crop_height_q};
    wire [YP_BITS:0] active_height_twice =
        {1'b0, active_height_q, 1'b0};
    wire [1:0] x_step = x_phase_sum >= active_width_twice ? 2'd2 :
                         (x_phase_sum >= active_width_q ? 2'd1 : 2'd0);
    reg [1:0] x_step_q;
    wire [X_BITS:0] next_source_x = {1'b0, source_x_select} + x_step_q;

    wire inside_active_x =
        frame_x >= x_offset_q &&
        frame_x < x_offset_q + active_width_q;
    wire line_write_enable =
        state == ST_CAPTURE && in_valid && in_ready &&
        input_y == desired_source_y;
    wire line_read_enable =
        state == ST_ACTIVE && !out_valid && inside_active_x &&
        !line_read_pending;
    wire line_memory_enable = line_write_enable || line_read_enable;
    wire [10:0] line_memory_address = line_write_enable ?
                input_x : source_x_select;

    // Capture and rendering never overlap, so a single-port RAM is sufficient.
    // Keep this process in the vendor's synchronous block-RAM template.
    // In particular, no reset is applied to the RAM process.
    always @(posedge clk) begin
        if (line_memory_enable) begin
            if (line_write_enable)
                line_buffer[line_memory_address] <= in_pixel;
            else
                line_read_data <= line_buffer[line_memory_address];
        end
    end

    task finish_frame;
        begin
            busy <= 1'b0;
            done <= 1'b1;
            state <= ST_IDLE;
        end
    endtask

    always @(posedge clk or posedge rst) begin
        if (rst) begin
            state <= ST_IDLE;
            source_width_q <= 16'd0;
            source_height_q <= 16'd0;
            active_width_q <= 16'd0;
            active_height_q <= 16'd0;
            x_offset_q <= 16'd0;
            y_offset_q <= 16'd0;
            crop_x_q <= 0;
            crop_width_q <= 0;
            crop_height_q <= 0;
            crop_last_x_q <= 0;
            crop_bottom_q <= 0;
            crop_y_q <= 0;
            stream_y_q <= 0;
            reverse_y_q <= 0;
            initial_y_step_q <= 0;
            input_x <= 16'd0;
            input_y <= 16'd0;
            frame_x <= 16'd0;
            frame_y <= 16'd0;
            source_x_select <= 16'd0;
            desired_source_y <= 16'd0;
            x_phase <= 17'd0;
            x_step_q <= 0;
            y_phase <= 17'd0;
            active_row_index <= 16'd0;
            line_read_pending <= 1'b0;
            out_valid <= 1'b0;
            out_pixel <= 24'd0;
            out_x <= 16'd0;
            out_y <= 16'd0;
            out_sof <= 1'b0;
            out_eol <= 1'b0;
            out_eof <= 1'b0;
            busy <= 1'b0;
            done <= 1'b0;
            config_error <= 1'b0;
            config_invalid_q <= 1'b0;
        end else begin
            done <= 1'b0;
            // Each active pixel has a synchronous RAM read and a valid stage.
            // Use that interval to register the phase decision before bounds checking.
            x_step_q <= x_step;

            if (start && (!busy || RESTART_ON_START)) begin
                out_valid <= 1'b0;
                config_error <= 1'b0;
                source_width_q <= source_width;
                source_height_q <= source_height;
                active_width_q <= active_width;
                active_height_q <= active_height;
                x_offset_q <= x_offset;
                y_offset_q <= y_offset;
                crop_x_q <= selected_x;
                crop_width_q <= selected_width;
                crop_height_q <= selected_height;
                crop_last_x_q <= selected_x + selected_width - 1'b1;
                crop_bottom_q <= selected_y + selected_height;
                crop_y_q <= selected_y;
                reverse_y_q <= reverse_y;
                input_x <= 16'd0;
                input_y <= 16'd0;
                frame_x <= 16'd0;
                frame_y <= 16'd0;
                source_x_select <= selected_x;
                desired_source_y <= 0;
                x_phase <= 17'd0;
                y_phase <= 0;
                active_row_index <= 16'd0;
                line_read_pending <= 1'b0;

                // The configuration is checked from the latched, narrow
                // fields in ST_SETUP.  This adds only an internal setup
                // cycle and avoids routing the raw header bus into busy.
                busy <= 1'b1;
                state <= ST_SETUP;
            end else begin
                if (out_valid && out_ready)
                    out_valid <= 1'b0;

                case (state)
                    ST_SETUP: begin
                        // Register the wide configuration check before it
                        // controls busy/error state. This separates the
                        // crop-width arithmetic from the state register.
                        config_invalid_q <= config_invalid;
                        stream_y_q <= reverse_y_q ? source_height_q - crop_bottom_q : crop_y_q;
                        initial_y_step_q <= reverse_y_q && crop_height_q > active_height_q;
                        y_phase <= !reverse_y_q ? 0 :
                            (crop_height_q > active_height_q ?
                             crop_height_q - 1'b1 - active_height_q : crop_height_q - 1'b1);
                        state <= ST_BEGIN;
                    end
                    ST_BEGIN: begin
                        if (config_invalid_q) begin
                            config_error <= 1'b1;
                            busy <= 1'b0;
                            done <= 1'b1;
                            state <= ST_IDLE;
                        end else begin
                            desired_source_y <= stream_y_q + initial_y_step_q;
                            state <= y_offset_q != 0 ? ST_TOP : ST_CAPTURE;
                        end
                    end
                    ST_TOP: begin
                        if (!out_valid) begin
                            out_valid <= 1'b1;
                            out_pixel <= 24'd0;
                            out_x <= frame_x;
                            out_y <= frame_y;
                            out_sof <= frame_x == 0 && frame_y == 0;
                            out_eol <= frame_x == TARGET_WIDTH - 1;
                            out_eof <= 1'b0;
                        end else if (out_ready) begin
                            if (frame_x == TARGET_WIDTH - 1) begin
                                frame_x <= 16'd0;
                                frame_y <= frame_y + 1'b1;
                                if (frame_y + 1'b1 >= y_offset_q)
                                    state <= ST_CAPTURE;
                            end else begin
                                frame_x <= frame_x + 1'b1;
                            end
                        end
                    end

                    ST_CAPTURE: begin
                        if (in_valid) begin
                            if (input_x + 1'b1 >= source_width_q) begin
                                input_x <= 16'd0;
                                input_y <= input_y + 1'b1;
                                if (input_y == desired_source_y) begin
                                    source_x_select <= crop_x_q;
                                    x_phase <= 17'd0;
                                    state <= ST_ACTIVE;
                                end
                            end else begin
                                input_x <= input_x + 1'b1;
                            end
                        end
                    end

                    ST_ACTIVE: begin
                        if (!out_valid) begin
                            if (!inside_active_x) begin
                                out_valid <= 1'b1;
                                out_pixel <= 24'd0;
                                out_x <= frame_x;
                                out_y <= frame_y;
                                out_sof <= frame_x == 0 && frame_y == 0;
                                out_eol <= frame_x == TARGET_WIDTH - 1;
                                out_eof <= frame_x == TARGET_WIDTH - 1 &&
                                           frame_y == TARGET_HEIGHT - 1;
                            end else if (line_read_pending) begin
                                line_read_pending <= 1'b0;
                                out_valid <= 1'b1;
                                out_pixel <= line_read_data;
                                out_x <= frame_x;
                                out_y <= frame_y;
                                out_sof <= frame_x == 0 && frame_y == 0;
                                out_eol <= frame_x == TARGET_WIDTH - 1;
                                out_eof <= frame_x == TARGET_WIDTH - 1 &&
                                           frame_y == TARGET_HEIGHT - 1;
                            end else begin
                                line_read_pending <= 1'b1;
                            end
                        end else if (out_ready) begin
                            if (frame_x == TARGET_WIDTH - 1) begin
                                frame_x <= 16'd0;
                                frame_y <= frame_y + 1'b1;
                                source_x_select <= crop_x_q;
                                x_phase <= 17'd0;

                                if (active_row_index + 1'b1 >= active_height_q) begin
                                    active_row_index <= active_row_index + 1'b1;
                                    if (input_y >= source_height_q) begin
                                        if (frame_y + 1'b1 >= TARGET_HEIGHT)
                                            finish_frame();
                                        else
                                            state <= ST_BOTTOM;
                                    end else begin
                                        state <= ST_DRAIN;
                                    end
                                end else begin
                                    active_row_index <= active_row_index + 1'b1;
                                    if (y_phase_sum >= active_height_twice) begin
                                        y_phase <= y_phase_sum - active_height_twice;
                                        desired_source_y <= desired_source_y + 2'd2;
                                        state <= ST_CAPTURE;
                                    end else if (y_phase_sum >= active_height_q) begin
                                        y_phase <= y_phase_sum - active_height_q;
                                        desired_source_y <= desired_source_y + 1'b1;
                                        state <= ST_CAPTURE;
                                    end else begin
                                        y_phase <= y_phase_sum[YP_BITS-1:0];
                                    end
                                end
                            end else begin
                                frame_x <= frame_x + 1'b1;
                                if (inside_active_x &&
                                    frame_x + 1'b1 < x_offset_q + active_width_q) begin
                                    if (x_phase_sum >= active_width_twice) begin
                                        x_phase <= x_phase_sum - active_width_twice;
                                    end else if (x_phase_sum >= active_width_q) begin
                                        x_phase <= x_phase_sum - active_width_q;
                                    end else begin
                                        x_phase <= x_phase_sum[XP_BITS-1:0];
                                    end
                                    source_x_select <= next_source_x > crop_last_x_q ?
                                                       crop_last_x_q : next_source_x[X_BITS-1:0];
                                end
                            end
                        end
                    end

                    ST_DRAIN: begin
                        if (in_valid) begin
                            if (input_x + 1'b1 >= source_width_q) begin
                                input_x <= 16'd0;
                                input_y <= input_y + 1'b1;
                                if (input_y + 1'b1 >= source_height_q) begin
                                    if (frame_y >= TARGET_HEIGHT)
                                        finish_frame();
                                    else
                                        state <= ST_BOTTOM;
                                end
                            end else begin
                                input_x <= input_x + 1'b1;
                            end
                        end
                    end

                    ST_BOTTOM: begin
                        if (!out_valid) begin
                            out_valid <= 1'b1;
                            out_pixel <= 24'd0;
                            out_x <= frame_x;
                            out_y <= frame_y;
                            out_sof <= frame_x == 0 && frame_y == 0;
                            out_eol <= frame_x == TARGET_WIDTH - 1;
                            out_eof <= frame_x == TARGET_WIDTH - 1 &&
                                       frame_y == TARGET_HEIGHT - 1;
                        end else if (out_ready) begin
                            if (frame_x == TARGET_WIDTH - 1) begin
                                frame_x <= 16'd0;
                                if (frame_y + 1'b1 >= TARGET_HEIGHT)
                                    finish_frame();
                                else
                                    frame_y <= frame_y + 1'b1;
                            end else begin
                                frame_x <= frame_x + 1'b1;
                            end
                        end
                    end

                    default: begin
                        state <= ST_IDLE;
                        busy <= 1'b0;
                        out_valid <= 1'b0;
                    end
                endcase
            end
        end
    end
endmodule
