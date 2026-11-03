`timescale 1ns/1ps

// The memory-domain load handshake starts one source-domain RGB888 stream.
// The FIFO preserves packed-word order across clocks. Completion is reported
// only after the source has finished AND the FIFO has been consumed.
module resident_upload_bridge #(
    parameter integer FRAME_HEIGHT=540
) (
    input wire src_clk, src_rst_n,
    input wire mem_clk, mem_rst_n,
    input wire load_accept, load_busy,
    output wire load_allowed,
    input wire pixel_valid, pixel_last,
    output wire pixel_ready,
    input wire [23:0] pixel_rgb,
    input wire source_error,
    output wire word_valid,
    input wire word_ready,
    output wire [31:0] word_data,
    output wire stream_done, stream_error
);
    reg start_toggle_mem;
    (* async_reg="true" *) reg [1:0] start_sync_src;
    reg start_seen_src, start_ack_src, idle_ack_src;
    reg source_session_live, session_started_src;
    (* async_reg="true" *) reg [4:0] ack_sync_mem;
    wire packer_start=start_sync_src[1]!=start_seen_src;
    wire session_active=ack_sync_mem[4]==start_toggle_mem && load_busy;
    wire packed_valid,packed_ready,packed_done,packed_error,packer_pixel_ready;
    wire [31:0] packed_word;
    wire fifo_full,fifo_empty;
    wire [31:0] fifo_word;
    reg [31:0] buffered_word;
    reg buffer_valid;
    wire fifo_take=session_active && !fifo_empty &&
                   (!buffer_valid || word_ready);
    // load_busy is held low through the memory-domain reset. The vendor FIFO
    // synchronizes this shared reset release independently in both clocks.
    wire fifo_reset=!load_busy;
    // Completion follows the FIFO write pointer CDC (registered Gray code,
    // two synchronizers and binary decode). A session toggle also prevents
    // the previous frame's sticky packed_done from ending a new upload.
    reg done_toggle_src, done_sent_src, done_seen_mem;
    (* async_reg="true" *) reg [5:0] done_sync_mem;
    (* async_reg="true" *) reg [2:0] error_sync_mem;
    (* async_reg="true" *) reg [1:0] active_sync_src;
    (* async_reg="true" *) reg [1:0] idle_ack_sync_mem;
    wire source_fault=packed_error || source_error;

    always @(posedge mem_clk or negedge mem_rst_n) begin
        if(!mem_rst_n) begin
            start_toggle_mem<=0; ack_sync_mem<=0;
            done_sync_mem<=0; done_seen_mem<=0;
            error_sync_mem<=0; idle_ack_sync_mem<=0;
        end else begin
            if(load_accept) start_toggle_mem<=~start_toggle_mem;
            ack_sync_mem<={ack_sync_mem[3:0],start_ack_src};
            if(load_accept) done_seen_mem<=done_sync_mem[5];
            done_sync_mem<={done_sync_mem[4:0],done_toggle_src};
            error_sync_mem<={error_sync_mem[1:0],source_fault};
            idle_ack_sync_mem<={idle_ack_sync_mem[0],idle_ack_src};
        end
    end
    always @(posedge src_clk or negedge src_rst_n) begin
        if(!src_rst_n) begin
            start_sync_src<=0; start_seen_src<=0; start_ack_src<=0;
            idle_ack_src<=0; source_session_live<=0; session_started_src<=0;
            active_sync_src<=0;
            done_toggle_src<=0;done_sent_src<=0;
        end else begin
            start_sync_src<={start_sync_src[0],start_toggle_mem};
            active_sync_src<={active_sync_src[0],load_busy};
            if(packer_start) begin
                done_sent_src<=0;
                start_seen_src<=start_sync_src[1];
                start_ack_src<=start_sync_src[1];
                session_started_src<=1;
                source_session_live<=1;
            end else if(session_started_src && !active_sync_src[1]) begin
                idle_ack_src<=start_seen_src;
                session_started_src<=0;
                source_session_live<=0;
            end
            if(!packer_start && source_session_live && packed_done && !done_sent_src) begin
                done_toggle_src<=~done_toggle_src;
                done_sent_src<=1;
            end
        end
    end
    resident_pixel_packer #(.FRAME_HEIGHT(FRAME_HEIGHT)) packer(
        .clk(src_clk),.rst_n(src_rst_n),.start(packer_start),
        .pixel_valid(pixel_valid && source_session_live),.pixel_last(pixel_last),
        .pixel_ready(packer_pixel_ready),
        .pixel_rgb(pixel_rgb),.word_valid(packed_valid),.word_ready(packed_ready),
        .word_data(packed_word),.stream_done(packed_done),.stream_error(packed_error)
    );
    assign load_allowed=idle_ack_sync_mem[1]==start_toggle_mem && !load_busy;
    assign pixel_ready=packer_pixel_ready && source_session_live;
    assign packed_ready=!fifo_full && source_session_live;
    always @(posedge mem_clk or negedge mem_rst_n) begin
        if(!mem_rst_n) begin
            buffered_word<=0;
            buffer_valid<=0;
        end else if(!load_busy) buffer_valid<=0;
        else if(fifo_take) begin
            buffered_word<=fifo_word;
            buffer_valid<=1;
        end else if(word_valid && word_ready) buffer_valid<=0;
    end
    wfifo_32_32_512 #(.REGISTER_EMPTY_FLAG(1'b1)) fifo(
        .rst(fifo_reset),.clkw(src_clk),.clkr(mem_clk),
        .we(packed_valid && packed_ready),.di(packed_word),
        .re(fifo_take),.dout(fifo_word),.valid(),
        .full_flag(fifo_full),.empty_flag(fifo_empty),
        .afull(),.aempty(),.wrusedw(),.rdusedw()
    );
    assign word_valid=session_active && buffer_valid;
    assign word_data=buffered_word;
    assign stream_done=session_active && (done_sync_mem[5]!=done_seen_mem) &&
                       fifo_empty && !buffer_valid;
    assign stream_error=session_active && error_sync_mem[2];
endmodule
