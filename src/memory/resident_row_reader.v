`timescale 1ns/1ps

// Memory-clock domain only. The caller reserves an entire free source-row
// buffer before req_valid/req_ready. Responses cannot be backpressured.
// One request owns the controller read port until busy falls. Cancellation
// stops at a command boundary and DRAINS all issued words before re-use.
// CDC, source-row ownership and frame descriptor submission belong upstream.
module resident_row_reader (
    input wire clk, rst_n,
    input wire controller_init_done, controller_busy, refresh_active, writer_busy,
    input wire req_valid,
    output wire req_ready,
    input wire [2:0] req_slot, req_buffer,
    input wire [9:0] req_y,
    input wire [15:0] req_tag,
    input wire cancel,
    output wire busy,
    output reg app_rd_en,
    output reg [20:0] app_rd_addr,
    input wire sdram_rd_valid,
    input wire [31:0] sdram_rd_data,
    output wire row_we,
    output wire [8:0] row_word,
    output wire [31:0] row_data,
    output reg [2:0] row_buffer, row_slot,
    output reg [9:0] row_y,
    output reg [15:0] row_tag,
    output reg row_done, row_cancelled, req_error
);
    `include "../include/resident_image_layout.vh"
    localparam IDLE=0, ADDRESS=1, PLAN=2, WAIT_BUS=3, ISSUE=4, DRAIN=5,
               PLAN_PAGE=6;
    reg [2:0] state;
    reg [21:0] address_wide;
    reg [8:0] remaining, command_words, issued, returned;
    reg [8:0] page_left_q;
    reg [3:0] quiet;
    reg cancelled;
    wire [8:0] page_left = 9'd256 - {1'b0,address_wide[7:0]};
    wire [8:0] planned_words = remaining < page_left_q ? remaining : page_left_q;
    assign req_ready = state == IDLE && controller_init_done && !cancel;
    assign busy = state != IDLE;
    assign row_we = sdram_rd_valid && state != IDLE && !cancelled && !cancel;
    assign row_word = returned;
    assign row_data = sdram_rd_data;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state<=IDLE; address_wide<=0;
            remaining<=0; command_words<=0; issued<=0; returned<=0;
            page_left_q<=0;
            quiet<=0; cancelled<=0; app_rd_en<=0; app_rd_addr<=0;
            row_buffer<=0; row_slot<=0; row_y<=0; row_tag<=0;
            row_done<=0; row_cancelled<=0; req_error<=0;
        end else begin
            app_rd_en<=0; row_done<=0; row_cancelled<=0; req_error<=0;
            if (cancel && busy) cancelled<=1;
            if (sdram_rd_valid && busy) returned<=returned+1'b1;
            if (app_rd_en || sdram_rd_valid) quiet<=0;
            else if (quiet != 15) quiet<=quiet+1'b1;
            case (state)
                IDLE: if (req_valid && req_ready) begin
                    row_buffer<=req_buffer; row_slot<=req_slot;
                    row_y<=req_y; row_tag<=req_tag;
                    cancelled<=0; returned<=0; issued<=0;
                    if (req_y >= RESIDENT_HEIGHT || req_buffer >= 6) req_error<=1;
                    else state<=ADDRESS;
                end
                ADDRESS: begin
                    // Keep the carry bit until all bounds have been checked.
                    address_wide <= {1'b0,resident_slot_base(row_slot)} +
                                    row_y * 22'd480;
                    remaining<=9'd480;
                    state<=PLAN_PAGE;
                end
                PLAN_PAGE: begin
                    page_left_q<=page_left;
                    state<=PLAN;
                end
                PLAN: begin
                    command_words<=planned_words;
                    if (cancelled || cancel) state<=DRAIN;
                    // Valid row IDs and the 480-word invariant keep every
                    // command inside its fixed-size slot.
                    else if (address_wide[1:0] != 0) begin
                        req_error<=1; cancelled<=1; state<=DRAIN;
                    end else state<=WAIT_BUS;
                end
                WAIT_BUS: begin
                    if (cancelled || cancel) state<=DRAIN;
                    else if (!controller_busy && !refresh_active && !writer_busy &&
                             returned == issued && quiet >= 10) state<=ISSUE;
                end
                ISSUE: begin
                    // Once begun, finish this aligned command even if cancelled.
                    app_rd_en<=1;
                    app_rd_addr<=address_wide[20:0];
                    address_wide<=address_wide+1'b1;
                    issued<=issued+1'b1;
                    remaining<=remaining-1'b1;
                    command_words<=command_words-1'b1;
                    if (command_words == 1) state<=DRAIN;
                end
                DRAIN: if (!app_rd_en && returned == issued && quiet >= 10 &&
                           !controller_busy && !refresh_active) begin
                    if (cancelled || cancel) begin row_cancelled<=1; state<=IDLE; end
                    else if (remaining == 0) begin row_done<=1; state<=IDLE; end
                    else state<=PLAN_PAGE;
                end
                default: state<=IDLE;
            endcase
        end
    end
endmodule
