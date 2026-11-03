`timescale 1ns/1ps

// Memory-domain descriptors; source-domain pixels. The BMP parser/scaler
// upstream supplies exactly 960x540 pixels and marks the last accepted beat.
module resident_image_uploader #(
    parameter integer ROWS=540
) (
    input wire src_clk, src_rst_n,
    input wire mem_clk, mem_rst_n,
    input wire controller_init_done, controller_busy, refresh_active,
    input wire reader_busy, reader_urgent,
    input wire load_valid,
    output wire load_ready,
    input wire [2:0] load_slot,
    input wire load_flip,
    input wire pixel_valid, pixel_last,
    output wire pixel_ready,
    input wire [23:0] pixel_rgb,
    input wire source_error, cancel,
    output wire load_busy, load_done, load_failed, load_cancelled,
    output wire [7:0] ready_mask, error_mask,
    output wire all_normal_ready, emergency_ready,
    output wire write_busy, app_wr_en,
    output wire [20:0] app_wr_addr,
    output wire [31:0] app_wr_data
);
    wire bridge_allowed, writer_ready;
    wire word_valid, word_ready, stream_done, stream_error;
    wire [31:0] word_data;
    wire accepted=load_valid && load_ready;
    assign load_ready=bridge_allowed && writer_ready;
    resident_upload_bridge #(.FRAME_HEIGHT(ROWS)) bridge(
        .src_clk(src_clk),.src_rst_n(src_rst_n),
        .mem_clk(mem_clk),.mem_rst_n(mem_rst_n),
        .load_accept(accepted),.load_busy(load_busy),.load_allowed(bridge_allowed),
        .pixel_valid(pixel_valid),.pixel_last(pixel_last),.pixel_ready(pixel_ready),
        .pixel_rgb(pixel_rgb),.source_error(source_error),
        .word_valid(word_valid),.word_ready(word_ready),.word_data(word_data),
        .stream_done(stream_done),.stream_error(stream_error)
    );
    resident_slot_writer #(.ROWS(ROWS)) writer(
        .clk(mem_clk),.rst_n(mem_rst_n),
        .controller_init_done(controller_init_done),
        .controller_busy(controller_busy),.refresh_active(refresh_active),
        .reader_busy(reader_busy),.reader_urgent(reader_urgent),
        .load_valid(accepted),.load_ready(writer_ready),
        .load_slot(load_slot),.load_flip(load_flip),
        .word_valid(word_valid),.word_ready(word_ready),.word_data(word_data),
        .stream_done(stream_done),.stream_error(stream_error),.cancel(cancel),
        .load_busy(load_busy),.load_done(load_done),
        .load_failed(load_failed),.load_cancelled(load_cancelled),
        .ready_mask(ready_mask),.error_mask(error_mask),
        .all_normal_ready(all_normal_ready),.emergency_ready(emergency_ready),
        .write_busy(write_busy),.app_wr_en(app_wr_en),
        .app_wr_addr(app_wr_addr),.app_wr_data(app_wr_data)
    );
endmodule
