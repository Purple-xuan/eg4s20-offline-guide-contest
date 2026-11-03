`timescale 1ns/1ps

module guide_status_cdc (
    input  wire       src_clk,
    input  wire       src_rst_n,
    input  wire [3:0] src_media_id,
    input  wire [1:0] src_display_bank,
    input  wire       src_display_valid,
    input  wire       src_auto_enabled,
    input  wire       src_audio_active,
    input  wire       src_emergency_active,
    input  wire [7:0] src_error_code,
    output wire       src_busy,

    input  wire       pix_clk,
    input  wire       pix_rst_n,
    input  wire       frame_start,
    output reg  [3:0] active_media_id,
    output reg  [1:0] active_display_bank,
    output reg        active_display_valid,
    output reg        active_auto_enabled,
    output reg        active_audio_active,
    output reg        active_emergency_active,
    output reg  [7:0] active_error_code,
    output reg        status_commit
);

    localparam integer STATUS_WIDTH = 18;

    wire [STATUS_WIDTH-1:0] source_status = {
        src_error_code,
        src_emergency_active,
        src_audio_active,
        src_auto_enabled,
        src_display_valid,
        src_display_bank,
        src_media_id
    };

    reg [STATUS_WIDTH-1:0] source_mailbox;
    reg request_toggle;
    reg launch_pending;
    (* async_reg = "true" *) reg ack_sync1;
    (* async_reg = "true" *) reg ack_sync2;

    (* async_reg = "true" *) reg request_sync1;
    (* async_reg = "true" *) reg request_sync2;
    reg request_seen;
    reg acknowledge_toggle;
    reg [STATUS_WIDTH-1:0] mailbox_sync1;
    reg [STATUS_WIDTH-1:0] mailbox_sync2;
    reg [STATUS_WIDTH-1:0] pending_status;
    reg pending_valid;
    reg capture_pending;
    reg capture_toggle;

    assign src_busy = launch_pending || (request_toggle != ack_sync2);

    // The mailbox remains unchanged until the pixel domain acknowledges it.
    // If inputs change while busy, the latest complete bundle is sent next.
    always @(posedge src_clk or negedge src_rst_n) begin
        if (!src_rst_n) begin
            source_mailbox <= {STATUS_WIDTH{1'b0}};
            request_toggle <= 1'b0;
            launch_pending <= 1'b0;
            ack_sync1 <= 1'b0;
            ack_sync2 <= 1'b0;
        end else begin
            ack_sync1 <= acknowledge_toggle;
            ack_sync2 <= ack_sync1;

            // Bundled data must be stable before its request crosses the CDC.
            // Stage the complete bundle for one source clock, then toggle the
            // request while holding the mailbox until acknowledgement.
            if (launch_pending) begin
                request_toggle <= ~request_toggle;
                launch_pending <= 1'b0;
            end else if (request_toggle == ack_sync2 &&
                         source_status != source_mailbox) begin
                source_mailbox <= source_status;
                launch_pending <= 1'b1;
            end
        end
    end

    // The request toggle qualifies the multi-cycle mailbox transfer. Captured
    // status may be replaced by a newer bundle, but visible outputs change only
    // at frame_start so every video frame sees one coherent configuration.
    always @(posedge pix_clk or negedge pix_rst_n) begin
        if (!pix_rst_n) begin
            request_sync1 <= 1'b0;
            request_sync2 <= 1'b0;
            request_seen <= 1'b0;
            acknowledge_toggle <= 1'b0;
            mailbox_sync1 <= {STATUS_WIDTH{1'b0}};
            mailbox_sync2 <= {STATUS_WIDTH{1'b0}};
            pending_status <= {STATUS_WIDTH{1'b0}};
            pending_valid <= 1'b0;
            capture_pending <= 1'b0;
            capture_toggle <= 1'b0;
            active_media_id <= 4'd0;
            active_display_bank <= 2'd0;
            active_display_valid <= 1'b0;
            active_auto_enabled <= 1'b0;
            active_audio_active <= 1'b0;
            active_emergency_active <= 1'b0;
            active_error_code <= 8'd0;
            status_commit <= 1'b0;
        end else begin
            request_sync1 <= request_toggle;
            request_sync2 <= request_sync1;
            mailbox_sync1 <= source_mailbox;
            mailbox_sync2 <= mailbox_sync1;
            status_commit <= 1'b0;

            if (frame_start && pending_valid) begin
                {
                    active_error_code,
                    active_emergency_active,
                    active_audio_active,
                    active_auto_enabled,
                    active_display_valid,
                    active_display_bank,
                    active_media_id
                } <= pending_status;
                pending_valid <= 1'b0;
                status_commit <= 1'b1;
            end

            // Wait one additional pixel clock after seeing the synchronized
            // request. This keeps mailbox settling separate from request
            // detection before acknowledging the source.
            if (capture_pending) begin
                acknowledge_toggle <= capture_toggle;
                pending_status <= mailbox_sync2;
                pending_valid <= 1'b1;
                capture_pending <= 1'b0;
            end

            // Keep this block after the frame commit. If a new request and a
            // frame boundary coincide, the old bundle commits and the new one
            // remains pending for the following frame.
            if (request_sync2 != request_seen) begin
                request_seen <= request_sync2;
                capture_toggle <= request_sync2;
                capture_pending <= 1'b1;
            end
        end
    end

endmodule
