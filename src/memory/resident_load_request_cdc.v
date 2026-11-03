`timescale 1ns/1ps

// A BMP descriptor becomes available only after its header has been parsed.
// Keep slot and row direction together until the memory writer accepts them.
module resident_load_request_cdc (
    input wire src_clk, src_rst_n,
    input wire src_valid,
    input wire [2:0] src_slot,
    input wire src_flip,
    output reg src_accepted,
    output wire src_busy,
    input wire mem_clk, mem_rst_n,
    output wire mem_valid,
    input wire mem_ready,
    output wire [2:0] mem_slot,
    output wire mem_flip
);
    reg request_toggle, acknowledge_toggle;
    reg [3:0] held_descriptor;
    reg pending, wait_release;
    (* async_reg="true" *) reg [2:0] ack_sync, request_sync;
    (* async_reg="true" *) reg [3:0] payload_sync1, payload_sync2;
    assign src_busy = pending || wait_release;
    assign mem_valid = request_sync[2] != acknowledge_toggle;
    assign {mem_flip,mem_slot} = payload_sync2;

    always @(posedge src_clk or negedge src_rst_n) begin
        if (!src_rst_n) begin
            request_toggle<=0; held_descriptor<=0;
            pending<=0; wait_release<=0; ack_sync<=0; src_accepted<=0;
        end else begin
            ack_sync<={ack_sync[1:0],acknowledge_toggle};
            src_accepted<=0;
            if (!pending && !wait_release && src_valid) begin
                held_descriptor<={src_flip,src_slot};
                request_toggle<=~request_toggle;
                pending<=1;
            end else if (pending && ack_sync[2]==request_toggle) begin
                pending<=0;
                wait_release<=1;
                src_accepted<=1;
            end else if (wait_release && !src_valid) begin
                wait_release<=0;
            end
        end
    end

    always @(posedge mem_clk or negedge mem_rst_n) begin
        if (!mem_rst_n) begin
            acknowledge_toggle<=0; request_sync<=0;
            payload_sync1<=0; payload_sync2<=0;
        end else begin
            request_sync<={request_sync[1:0],request_toggle};
            payload_sync1<=held_descriptor;
            payload_sync2<=payload_sync1;
            if (mem_valid && mem_ready)
                acknowledge_toggle<=request_sync[2];
        end
    end
endmodule
