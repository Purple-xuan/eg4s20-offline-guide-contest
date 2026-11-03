`timescale 1ns/1ps

// Word-level write arbiter for the future thumbnail path. Existing full-frame
// writes retain priority; thumbnail traffic only uses otherwise idle SDRAM
// write slots and is backpressured while refresh, controller busy, or urgent
// display reads are active.
module thumbnail_write_arbiter #(
    parameter integer ADDR_BITS = 21
) (
    input  wire                   sdram_init_done,
    input  wire                   refresh_active,
    input  wire                   controller_busy,
    input  wire                   reader_urgent,
    input  wire                   frame_valid,
    input  wire [ADDR_BITS-1:0]   frame_addr,
    input  wire [31:0]            frame_data,
    input  wire [3:0]             frame_mask,
    input  wire                   thumb_valid,
    output wire                   thumb_ready,
    input  wire [ADDR_BITS-1:0]   thumb_addr,
    input  wire [31:0]            thumb_data,
    output wire                   app_wr_en,
    output wire [ADDR_BITS-1:0]   app_wr_addr,
    output wire [31:0]            app_wr_data,
    output wire [3:0]             app_wr_mask,
    output wire                   thumb_grant
);
    wire slot_available = sdram_init_done && !refresh_active &&
                          !controller_busy && !reader_urgent;
    assign thumb_grant = slot_available && !frame_valid && thumb_valid;
    assign thumb_ready = thumb_grant;
    assign app_wr_en = slot_available && (frame_valid || thumb_valid);
    assign app_wr_addr = frame_valid ? frame_addr : thumb_addr;
    assign app_wr_data = frame_valid ? frame_data : thumb_data;
    assign app_wr_mask = frame_valid ? frame_mask : 4'b0000;
endmodule
