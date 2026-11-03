`timescale 1ns/1ps

// Immutable 320x180 RGB565 pages follow the four full-size frame banks.
// Ordered BEGIN/data/COMMIT tokens cross clocks together. Only complete,
// physically drained four-word bursts may publish a page.
module gallery_sdram_cache #(
    parameter integer BASE_WORD = 1843200
) (
    input wire clk, rst, async_rst, capture_start, capture_commit,
    input wire [2:0] capture_page,
    input wire pixel_valid, pixel_flip,
    input wire [23:0] pixel_rgb,
    output wire pixel_ready,
    output wire [7:0] ready_mask,
    input wire mem_clk, mem_rst,
    input wire init_done, controller_busy, refresh_active,
    input wire reader_busy, reader_urgent, frame_writer_busy,
    output wire write_busy, app_wr_en,
    output wire [20:0] app_wr_addr,
    output wire [31:0] app_wr_data,
    output reg error
);
    localparam [1:0] DATA=0, BEGIN_PAGE=1, COMMIT_PAGE=2;
    (* ram_style="bram" *) reg [11:0] sums_r [0:511];
    (* ram_style="bram" *) reg [11:0] sums_g [0:511];
    (* ram_style="bram" *) reg [11:0] sums_b [0:511];
    reg [11:0] read_r, read_g, read_b;
    reg capturing, begin_pending, commit_pending, complete, flip, first_sample;
    reg [2:0] page;
    reg [8:0] column;
    reg [7:0] row;
    reg [1:0] sub_x, sub_y;
    reg [9:0] horizontal_r, horizontal_g, horizontal_b;
    reg [20:0] row_base;
    reg group_valid, group_first, group_last;
    reg [8:0] group_column;
    reg [20:0] group_address;
    reg [9:0] group_r, group_g, group_b;
    reg average_valid;
    reg [8:0] average_column;
    reg [20:0] average_address;
    reg [15:0] average_pixel, first_pixel;
    reg half_valid;
    wire [11:0] total_r=group_first ? {2'b0,group_r} : read_r+group_r;
    wire [11:0] total_g=group_first ? {2'b0,group_g} : read_g+group_g;
    wire [11:0] total_b=group_first ? {2'b0,group_b} : read_b+group_b;
    wire fifo_full, fifo_afull, fifo_empty, fifo_valid;
    reg fifo_throttle;
    reg fifo_we;
    reg [63:0] fifo_input;
    wire fifo_re;
    wire [63:0] fifo_output;
    reg [7:0] ready_mem;
    genvar bit_index;
    generate for(bit_index=0;bit_index<8;bit_index=bit_index+1) begin : g_ready
        sync_2ff ready_sync(.clk(clk),.rst_n(!rst),
            .async_in(ready_mem[bit_index]),.sync_out(ready_mask[bit_index]));
    end endgenerate
    // Almost-full reserves 15 tokens; the extra cycle and capture pipeline
    // can produce at most three more before all accepted pixels drain.
    always @(posedge clk or posedge rst) begin
        if (rst) fifo_throttle <= 1;
        else fifo_throttle <= fifo_afull;
    end
    assign pixel_ready=!capturing || (!begin_pending && !fifo_throttle);
    wire accept=pixel_valid && capturing && !complete && pixel_ready;
    wire block_end=accept && sub_x==3;

    function [20:0] page_base;
        input [2:0] id;
        begin
            case(id)
                0:page_base=BASE_WORD;
                1:page_base=BASE_WORD+28800;
                2:page_base=BASE_WORD+57600;
                3:page_base=BASE_WORD+86400;
                4:page_base=BASE_WORD+115200;
                5:page_base=BASE_WORD+144000;
                6:page_base=BASE_WORD+172800;
                7:page_base=BASE_WORD+201600;
            endcase
        end
    endfunction

    always @(posedge clk) begin
        if(block_end) begin
            read_r<=sums_r[column];
            read_g<=sums_g[column];
            read_b<=sums_b[column];
        end
        if(group_valid && !group_last) begin
            sums_r[group_column]<=total_r;
            sums_g[group_column]<=total_g;
            sums_b[group_column]<=total_b;
        end
    end

    always @(posedge clk or posedge rst) begin
        if(rst) begin
            capturing<=0;begin_pending<=0;commit_pending<=0;complete<=0;flip<=0;first_sample<=0;
            page<=0;column<=0;row<=0;sub_x<=0;sub_y<=0;row_base<=0;
            horizontal_r<=0;horizontal_g<=0;horizontal_b<=0;
            group_valid<=0;group_first<=0;group_last<=0;group_column<=0;
            group_address<=0;group_r<=0;group_g<=0;group_b<=0;
            average_valid<=0;average_column<=0;average_address<=0;
            average_pixel<=0;first_pixel<=0;half_valid<=0;fifo_we<=0;fifo_input<=0;
        end else begin
            fifo_we<=0;
            group_valid<=block_end;
            average_valid<=group_valid && group_last;
            if(capture_commit && capturing) commit_pending<=1;
            if(block_end) begin
                group_column<=column;
                group_address<=row_base+{12'd0,column[8:1]};
                group_first<=sub_y==0;
                group_last<=sub_y==3;
                group_r<=horizontal_r+pixel_rgb[23:16];
                group_g<=horizontal_g+pixel_rgb[15:8];
                group_b<=horizontal_b+pixel_rgb[7:0];
            end
            if(group_valid && group_last) begin
                average_column<=group_column;
                average_address<=group_address;
                // Divide a complete 4x4 sum by 16, then quantize to RGB565.
                average_pixel<={total_r[11:7],total_g[11:6],total_b[11:7]};
            end
            if(average_valid) begin
                half_valid<=!average_column[0];
                if(!average_column[0]) first_pixel<=average_pixel;
                else begin
                    fifo_we<=1;
                    fifo_input<={6'd0,DATA,page,average_address,average_pixel,first_pixel};
                end
            end
            if(begin_pending && !fifo_afull) begin
                begin_pending<=0;
                fifo_we<=1;
                fifo_input<={6'd0,BEGIN_PAGE,page,21'd0,32'd0};
            end else if(capturing && complete && commit_pending && !group_valid &&
                        !average_valid && !fifo_we && !half_valid && !fifo_afull) begin
                fifo_we<=1;
                fifo_input<={6'd0,COMMIT_PAGE,page,21'd0,32'd0};
                capturing<=0;
                commit_pending<=0;
            end
            if(accept) begin
                // BMP orientation becomes valid after capture_start, when its
                // header has been read. No group is emitted on this first beat.
                if(first_sample) begin
                    first_sample<=0;
                    flip<=pixel_flip;
                    row_base<=page_base(page)+(pixel_flip ? 21'd28640 : 21'd0);
                end
                if(sub_x==0) begin
                    horizontal_r<=pixel_rgb[23:16];
                    horizontal_g<=pixel_rgb[15:8];
                    horizontal_b<=pixel_rgb[7:0];
                end else begin
                    horizontal_r<=horizontal_r+pixel_rgb[23:16];
                    horizontal_g<=horizontal_g+pixel_rgb[15:8];
                    horizontal_b<=horizontal_b+pixel_rgb[7:0];
                end
                sub_x<=sub_x+1'b1;
                if(sub_x==3) begin
                    if(column==319) begin
                        column<=0;
                        sub_y<=sub_y+1'b1;
                        if(sub_y==3) begin
                            row<=row+1'b1;
                            row_base<=flip ? row_base-21'd160 : row_base+21'd160;
                            if(row==179) complete<=1;
                        end
                    end else column<=column+1'b1;
                end
            end
            if(capture_start) begin
                capturing<=!ready_mask[capture_page];
                begin_pending<=!ready_mask[capture_page];
                commit_pending<=0;complete<=0;flip<=pixel_flip;page<=capture_page;
                first_sample<=1;
                column<=0;row<=0;sub_x<=0;sub_y<=0;
                row_base<=page_base(capture_page)+(pixel_flip ? 21'd28640 : 21'd0);
                group_valid<=0;average_valid<=0;half_valid<=0;
            end
        end
    end

    rfifo_32_32_512 #(.DATA_WIDTH_W(64),.DATA_WIDTH_R(64),
        .AL_FULL_NUM(496)) tokens(
        // The FIFO synchronizes release in each domain internally.
        .rst(async_rst),.clkw(clk),.clkr(mem_clk),
        .we(fifo_we),.di(fifo_input),.re(fifo_re),.dout(fifo_output),.valid(fifo_valid),
        .full_flag(fifo_full),.afull(fifo_afull),.empty_flag(fifo_empty),
        .aempty(),.wrusedw(),.rdusedw());

    localparam FETCH=0, WAIT_SLOT=1, WRITE=2, DRAIN=3;
    reg [1:0] state, staged_count, write_index;
    reg read_pending, bad_page;
    reg [2:0] mem_page;
    reg [15:0] written_words;
    reg [20:0] staged_address;
    reg [31:0] staged_data [0:3];
    reg [4:0] cooldown;
    reg token_valid;
    reg [63:0] token_word;
    reg [7:0] publish_mask;
    wire [1:0] token_type=token_word[57:56];
    wire [2:0] token_page=token_word[55:53];
    wire [20:0] token_address=token_word[52:32];
    assign fifo_re=state==FETCH && !read_pending && !fifo_empty;
    assign write_busy=state==WRITE || state==DRAIN;
    assign app_wr_en=state==WRITE;
    assign app_wr_addr=staged_address+write_index;
    assign app_wr_data=staged_data[write_index];
    always @(posedge mem_clk or posedge mem_rst) begin
        if(mem_rst) begin
            state<=FETCH;staged_count<=0;write_index<=0;read_pending<=0;
            mem_page<=0;bad_page<=0;written_words<=0;staged_address<=0;
            cooldown<=0;ready_mem<=0;error<=0;token_valid<=0;token_word<=0;publish_mask<=0;
        end else begin
            // Separate the BRAM output from token decoding and burst staging.
            token_valid<=fifo_valid;
            if(fifo_valid) token_word<=fifo_output;
            // Publish a checked page separately from token validation.
            ready_mem<=ready_mem | publish_mask;
            publish_mask<=0;
            if(fifo_re) read_pending<=1;
            if(token_valid) begin
                read_pending<=0;
                case(token_type)
                    BEGIN_PAGE: begin
                        mem_page<=token_page;staged_count<=0;written_words<=0;bad_page<=0;
                    end
                    COMMIT_PAGE: begin
                        if(token_page==mem_page && !bad_page && staged_count==0 &&
                           written_words==28800) publish_mask<=8'b1<<token_page;
                        else error<=1;
                    end
                    DATA: if(!ready_mem[token_page]) begin
                        if(token_page!=mem_page ||
                           (staged_count==0 && token_address[1:0]!=0) ||
                           (staged_count!=0 && token_address!=staged_address+staged_count)) begin
                            bad_page<=1;error<=1;
                        end
                        if(staged_count==0) staged_address<=token_address;
                        staged_data[staged_count]<=token_word[31:0];
                        staged_count<=staged_count+1'b1;
                        if(staged_count==3) state<=WAIT_SLOT;
                    end
                endcase
            end
            case(state)
                WAIT_SLOT: if(init_done && !controller_busy && !refresh_active &&
                              !reader_busy && !reader_urgent && !frame_writer_busy) begin
                    state<=WRITE;write_index<=0;
                end
                WRITE: begin
                    write_index<=write_index+1'b1;
                    if(write_index==3) begin state<=DRAIN;cooldown<=16;end
                end
                DRAIN: begin
                    if(cooldown!=0) cooldown<=cooldown-1'b1;
                    else if(!controller_busy) begin
                        written_words<=written_words+16'd4;
                        state<=FETCH;
                    end
                end
            endcase
        end
    end
endmodule
