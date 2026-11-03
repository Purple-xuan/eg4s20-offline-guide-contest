`timescale 1ns/1ps

module sd_sector_arbiter_2 (
    input  wire        clk,
    input  wire        rst,
    input  wire        c0_req,
    input  wire [31:0] c0_lba,
    output wire        c0_busy,
    output wire        c0_valid,
    output wire [7:0]  c0_byte,
    output wire [8:0]  c0_byte_index,
    output wire        c0_done,
    output wire [7:0]  c0_error,
    input  wire        c1_req,
    input  wire [31:0] c1_lba,
    output wire        c1_busy,
    output wire        c1_valid,
    output wire [7:0]  c1_byte,
    output wire [8:0]  c1_byte_index,
    output wire        c1_done,
    output wire [7:0]  c1_error,
    output wire        sector_req,
    output wire [31:0] sector_lba,
    input  wire        sector_busy,
    input  wire        sector_valid,
    input  wire [7:0]  sector_byte,
    input  wire [8:0]  sector_byte_index,
    input  wire        sector_done,
    input  wire [7:0]  sector_error
);
    reg owner_valid;
    reg owner;
    reg last_grant;
    reg offer_valid;
    reg offer_owner;
    reg [31:0] offer_lba;

    wire select_c1 = c1_req && (!c0_req || last_grant == 1'b0);
    wire selected_req = select_c1 ? c1_req : c0_req;
    wire selected_owner = select_c1;

    wire offered_req = offer_owner ? c1_req : c0_req;
    assign sector_req = !owner_valid && offer_valid && offered_req;
    assign sector_lba = offer_lba;

    // A client may start a new request only after the previous ownership has
    // been retired. sector_busy drops in the cycle before owner_valid clears;
    // exposing that gap to the owner would make an abort/restart request look
    // accepted even though sector_req is still blocked by owner_valid.
    assign c0_busy = owner_valid || !offer_valid || offer_owner || !c0_req ?
                     1'b1 : sector_busy;
    assign c1_busy = owner_valid || !offer_valid || !offer_owner || !c1_req ?
                     1'b1 : sector_busy;

    assign c0_valid = owner_valid && !owner && sector_valid;
    assign c1_valid = owner_valid && owner && sector_valid;
    assign c0_done = owner_valid && !owner && sector_done;
    assign c1_done = owner_valid && owner && sector_done;
    assign c0_byte = sector_byte;
    assign c1_byte = sector_byte;
    assign c0_byte_index = sector_byte_index;
    assign c1_byte_index = sector_byte_index;
    assign c0_error = c0_done ? sector_error : 8'd0;
    assign c1_error = c1_done ? sector_error : 8'd0;

    always @(posedge clk or posedge rst) begin
        if (rst) begin
            owner_valid <= 1'b0;
            owner <= 1'b0;
            last_grant <= 1'b1;
            offer_valid <= 1'b0;
            offer_owner <= 1'b0;
            offer_lba <= 32'd0;
        end else begin
            if (owner_valid && sector_done) begin
                owner_valid <= 1'b0;
            end else if (!owner_valid && offer_valid) begin
                if (!offered_req) offer_valid <= 1'b0;
                else if (!sector_busy) begin
                    owner_valid <= 1'b1;
                    owner <= offer_owner;
                    last_grant <= offer_owner;
                    offer_valid <= 1'b0;
                end
            end else if (!owner_valid && selected_req) begin
                offer_valid <= 1'b1;
                offer_owner <= selected_owner;
                offer_lba <= select_c1 ? c1_lba : c0_lba;
            end
        end
    end
endmodule
