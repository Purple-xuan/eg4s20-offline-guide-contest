`timescale 1ns/1ps

// Fixed SDRAM map for thumbnail pages after the four full-frame regions.
// Addresses are 32-bit SDRAM words, not byte addresses.
module thumbnail_bank_map #(
    parameter integer ADDR_BITS = 21,
    parameter integer FRAME_WORDS = 460800,
    parameter integer THUMB_WIDTH = 320,
    parameter integer THUMB_HEIGHT = 180,
    parameter integer BANK_COUNT = 8
) (
    input  wire [2:0]               bank_index,
    output wire [ADDR_BITS-1:0]     base_addr,
    output wire [ADDR_BITS-1:0]     word_limit,
    output wire                     valid
);
    localparam integer THUMB_WORDS = (THUMB_WIDTH * THUMB_HEIGHT) / 2;
    localparam integer THUMB_BASE = FRAME_WORDS * 4;
    localparam integer THUMB_END = THUMB_BASE + THUMB_WORDS * BANK_COUNT;

    wire [ADDR_BITS-1:0] bank_offset = bank_index * THUMB_WORDS;
    assign base_addr = THUMB_BASE + bank_offset;
    assign word_limit = THUMB_WORDS;
    assign valid = (bank_index < BANK_COUNT) &&
                   (THUMB_BASE + bank_offset + THUMB_WORDS <= (1 << ADDR_BITS));
endmodule
