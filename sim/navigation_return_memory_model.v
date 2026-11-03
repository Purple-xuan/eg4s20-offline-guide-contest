`timescale 1ns/1ps
// Icarus-only storage models for functional row-composition checks.
// These model synchronous ports and ordered memory replies, not vendor
// SDRAM electrical timing, refresh, placement or FPGA primitive internals.
module gallery_sdram_memory #(
    parameter USE_STORED_WORDS=0
)(
    input clk,rst,rd_en,wr_en,
    input [20:0] rd_addr,wr_addr,
    input [31:0] wr_data,
    output init,busy,refresh,
    output reg valid=0,
    output reg [31:0] data=0
);
    reg [31:0] words[0:2097151];
    reg [4:0] valid_pipe=0;
    reg [20:0] address_pipe[0:4];
    integer k,physical_writes=0,physical_reads=0;
    reg [15:0] low_pixel,high_pixel;
    assign init=!rst;
    assign busy=0;
    assign refresh=0;
    always @(posedge clk) begin
        if(rst) begin valid_pipe<=0;valid<=0;data<=0;end
        else begin
            valid_pipe<={valid_pipe[3:0],rd_en};
            address_pipe[0]<=rd_addr;
            for(k=1;k<5;k=k+1) address_pipe[k]<=address_pipe[k-1];
            valid<=valid_pipe[4];
            if(valid_pipe[4]) begin
                low_pixel=16'hf800^(address_pipe[4]*2);
                high_pixel=16'h07e0^(address_pipe[4]*2+1);
                data<=!USE_STORED_WORDS && address_pipe[4]<1843200 ?
                    {high_pixel,low_pixel} : words[address_pipe[4]];
                physical_reads<=physical_reads+1;
            end
            if(wr_en) begin words[wr_addr]<=wr_data;physical_writes<=physical_writes+1;end
        end
    end
endmodule

// Only the DP/NOREG/NORMAL, equal-width mode used by resident_line_buffers.
module EG_LOGIC_BRAM #(
    parameter DATA_WIDTH_A=16,DATA_WIDTH_B=16,
    parameter ADDR_WIDTH_A=9,ADDR_WIDTH_B=9,
    parameter DATA_DEPTH_A=512,DATA_DEPTH_B=512,
    parameter MODE="DP",REGMODE_A="NOREG",REGMODE_B="NOREG",
    parameter WRITEMODE_A="NORMAL",WRITEMODE_B="NORMAL",RESETMODE="SYNC",
    parameter BYTE_ENABLE=0,BYTE_A=1,BYTE_B=1,IMPLEMENT="9K"
)(
    output reg [DATA_WIDTH_A-1:0] doa,
    output reg [DATA_WIDTH_B-1:0] dob,
    input [DATA_WIDTH_A-1:0] dia,
    input [DATA_WIDTH_B-1:0] dib,
    input cea,ocea,clka,wea,rsta,ceb,oceb,clkb,web,rstb,bea,beb,
    input [ADDR_WIDTH_A-1:0] addra,
    input [ADDR_WIDTH_B-1:0] addrb
);
    reg [DATA_WIDTH_A-1:0] memory[0:DATA_DEPTH_A-1];
    always @(posedge clka) if(cea) begin
        if(wea) memory[addra]<=dia;
        if(rsta) doa<=0;else if(ocea) doa<=memory[addra];
    end
    always @(posedge clkb) if(ceb) begin
        if(web) memory[addrb]<=dib;
        if(rstb) dob<=0;else if(oceb) dob<=memory[addrb];
    end
endmodule
