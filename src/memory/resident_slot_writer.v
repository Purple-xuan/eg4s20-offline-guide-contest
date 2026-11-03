`timescale 1ns/1ps

// Memory-clock writer for one immutable resident slot at a time. The caller
// transfers RGB565 word/valid/ready and holds stream_done after the final word.
// A CDC FIFO and BMP scaler are upstream; this block owns the controller write
// port from the first beat of a command through its physical drain.
module resident_slot_writer #(
    parameter integer FIRST_ROW=0,
    parameter integer ROWS=540
) (
    input wire clk, rst_n,
    input wire controller_init_done, controller_busy, refresh_active,
    input wire reader_busy, reader_urgent,
    input wire load_valid,
    output wire load_ready,
    input wire [2:0] load_slot,
    input wire load_flip,
    input wire word_valid,
    output wire word_ready,
    input wire [31:0] word_data,
    input wire stream_done, stream_error, cancel,
    output wire load_busy,
    output reg load_done, load_failed, load_cancelled,
    output reg [7:0] ready_mask, error_mask,
    output wire all_normal_ready, emergency_ready,
    output wire write_busy, app_wr_en,
    output wire [20:0] app_wr_addr,
    output wire [31:0] app_wr_data
);
    `include "../include/resident_image_layout.vh"
    localparam integer FRAME_WORDS=RESIDENT_ROW_WORDS*ROWS;
    localparam integer FIRST_OFFSET=FIRST_ROW*RESIDENT_ROW_WORDS;
    localparam integer FLIPPED_OFFSET=(FIRST_ROW+ROWS-1)*RESIDENT_ROW_WORDS;
    localparam IDLE=0, FILL=1, WAIT_BUS=2, WRITE=3, DRAIN=4, WAIT_END=5;
    reg [2:0] state;
    reg [2:0] slot;
    reg flip;
    reg [21:0] row_base, slot_begin, slot_end, staged_address;
    reg [8:0] column;
    reg [18:0] received;
    reg [2:0] staged_count;
    reg [1:0] write_index;
    reg [31:0] staged_data[0:3];
    reg [4:0] cooldown;
    reg fail_pending, cancel_pending;
    wire [21:0] next_address=row_base+{13'd0,column};
    assign load_ready=state==IDLE && controller_init_done && !ready_mask[load_slot];
    assign load_busy=state!=IDLE;
    assign word_ready=state==FILL && staged_count<4 && !stream_done &&
                      !stream_error && !cancel && !fail_pending && !cancel_pending;
    assign write_busy=state==WRITE || state==DRAIN;
    assign app_wr_en=state==WRITE;
    assign app_wr_addr=staged_address[20:0]+write_index;
    assign app_wr_data=staged_data[write_index];
    assign all_normal_ready=&ready_mask[6:0];
    assign emergency_ready=ready_mask[7];

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state<=IDLE; slot<=0; flip<=0; row_base<=0; slot_begin<=0; slot_end<=0;
            staged_address<=0; column<=0; received<=0;
            staged_count<=0; write_index<=0; cooldown<=0;
            fail_pending<=0; cancel_pending<=0;
            load_done<=0; load_failed<=0; load_cancelled<=0;
            ready_mask<=0; error_mask<=0;
        end else begin
            load_done<=0; load_failed<=0; load_cancelled<=0;
            if (state!=IDLE) begin
                if (stream_error) fail_pending<=1;
                if (cancel) cancel_pending<=1;
            end
            case (state)
                IDLE: if (load_valid && load_ready) begin
                    slot<=load_slot; flip<=load_flip;
                    row_base<={1'b0,resident_slot_base(load_slot)}+
                              (load_flip ? FLIPPED_OFFSET : FIRST_OFFSET);
                    slot_begin<={1'b0,resident_slot_base(load_slot)};
                    slot_end<={1'b0,resident_slot_base(load_slot)}+22'd259200;
                    column<=0; received<=0;
                    staged_count<=0; fail_pending<=0; cancel_pending<=0;
                    error_mask[load_slot]<=0;
                    state<=FILL;
                end
                FILL: begin
                    if (fail_pending || stream_error ||
                        (stream_done && received!=FRAME_WORDS)) begin
                        error_mask[slot]<=1; load_failed<=1; state<=IDLE;
                    end else if (cancel_pending || cancel) begin
                        load_cancelled<=1; state<=IDLE;
                    end else if (word_valid && word_ready) begin
                        // The wide slot check runs on staged_address in
                        // WAIT_BUS, after the address adder has registered.
                        if (received>=FRAME_WORDS ||
                            (staged_count==3 && next_address[7:0]==0)) begin
                            error_mask[slot]<=1; load_failed<=1; state<=IDLE;
                        end else begin
                            staged_data[staged_count[1:0]]<=word_data;
                            if (staged_count==0) staged_address<=next_address;
                            staged_count<=staged_count+1'b1;
                            received<=received+1'b1;
                            if (column==RESIDENT_ROW_WORDS-1) begin
                                column<=0;
                                row_base<=flip ? row_base-22'd480 : row_base+22'd480;
                            end else column<=column+1'b1;
                            if (staged_count==3) state<=WAIT_BUS;
                        end
                    end
                end
                WAIT_BUS: begin
                    // Aborts before a command starts discard its staged words.
                    // All row and slot limits are four-word aligned. For an
                    // aligned command, checking the start against the exclusive
                    // limit also bounds its remaining three words. Keep the
                    // extra address bit until after this check (no wraparound).
                    if (fail_pending || stream_error ||
                        FIRST_ROW<0 || ROWS<1 || FIRST_ROW+ROWS>540 ||
                        staged_address<slot_begin || staged_address>=slot_end ||
                        staged_address>=RESIDENT_END || staged_address[1:0]!=0) begin
                        error_mask[slot]<=1; load_failed<=1; state<=IDLE;
                    end else if (cancel_pending || cancel) begin
                        load_cancelled<=1; state<=IDLE;
                    end else if (controller_init_done && !controller_busy &&
                                 !refresh_active && !reader_busy && !reader_urgent) begin
                        write_index<=0; state<=WRITE;
                    end
                end
                WRITE: begin
                    write_index<=write_index+1'b1;
                    if (write_index==3) begin
                        state<=DRAIN; cooldown<=16;
                    end
                end
                DRAIN: begin
                    if (cooldown!=0) cooldown<=cooldown-1'b1;
                    else if (!controller_busy && !refresh_active) begin
                        staged_count<=0;
                        if (fail_pending || stream_error) begin
                            error_mask[slot]<=1; load_failed<=1; state<=IDLE;
                        end else if (cancel_pending || cancel) begin
                            load_cancelled<=1; state<=IDLE;
                        end else if (received==FRAME_WORDS) state<=WAIT_END;
                        else state<=FILL;
                    end
                end
                WAIT_END: begin
                    if (fail_pending || stream_error || word_valid) begin
                        error_mask[slot]<=1; load_failed<=1; state<=IDLE;
                    end else if (cancel_pending || cancel) begin
                        load_cancelled<=1; state<=IDLE;
                    end else if (stream_done) begin
                        ready_mask[slot]<=1;
                        load_done<=1; state<=IDLE;
                    end
                end
                default: state<=IDLE;
            endcase
        end
    end
endmodule
