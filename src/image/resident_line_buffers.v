`timescale 1ns/1ps

// Raw dual-port storage, not a CDC ownership protocol. Producers/consumers
// must exchange complete-row/image ownership before accessing opposite ports.
// Source rows: mem/mem. Output rows and overview: mem/pixel.
module resident_line_buffers #(
    parameter OUTPUT_WRITE_BOUNDED=0
) (
    input wire mem_clk, pix_clk,
    input wire source_we,
    input wire [2:0] source_write_buffer,
    input wire [8:0] source_write_word,
    input wire [31:0] source_write_data,
    input wire source_read_enable,
    input wire [2:0] source_read_buffer,
    input wire [9:0] source_read_x,
    output wire [15:0] source_pixel,
    input wire output_we, output_write_buffer,
    input wire [10:0] output_write_x,
    input wire [15:0] output_write_data,
    input wire output_read_buffer,
    input wire [10:0] output_read_x,
    output wire [15:0] output_pixel,
    input wire overview_we, overview_write_buffer,
    input wire [13:0] overview_write_address,
    input wire [8:0] overview_write_data,
    input wire overview_read_buffer,
    input wire [13:0] overview_read_address,
    output wire [8:0] overview_pixel
);
    wire [31:0] source_words[0:5];
    reg [2:0] source_select_q;
    reg source_half_q, source_valid_q;
    always @(posedge mem_clk) begin
        source_select_q<=source_read_buffer;
        source_half_q<=source_read_x[0];
        source_valid_q<=source_read_buffer<6 && source_read_x<960;
    end
    reg [15:0] source_pixel_q;
    always @(posedge mem_clk)
        source_pixel_q <= !source_valid_q ? 16'd0 :
            source_half_q ? source_words[source_select_q][31:16] :
                            source_words[source_select_q][15:0];
    assign source_pixel = source_pixel_q;
    genvar i,j;
    generate for (i=0;i<6;i=i+1) begin : source_row
        for (j=0;j<2;j=j+1) begin : half_word
            resident_native_ram #(.WIDTH(16),.AW(9),.DEPTH(512),.KIND("9K")) ram (
                .wclk(mem_clk),.we(source_we && source_write_buffer==i && source_write_word<480),
                .wa(source_write_word),.wd(source_write_data[j*16+:16]),
                .rclk(mem_clk),.re(source_read_enable && source_read_x<960 && source_read_buffer==i),
                .ra(source_read_x[9:1]),.rd(source_words[i][j*16+:16])
            );
        end
    end endgenerate
    wire [15:0] output_pixels[0:1];
    reg output_select_q, output_valid_q;
    always @(posedge pix_clk) begin
        output_select_q<=output_read_buffer;
        output_valid_q<=output_read_x<1280;
    end
    assign output_pixel=output_valid_q ? output_pixels[output_select_q] : 16'd0;
    generate for (i=0;i<2;i=i+1) begin : output_row
        resident_native_ram #(.WIDTH(16),.AW(11),.DEPTH(2048),.KIND("32K")) ram (
            .wclk(mem_clk),.we(output_we && output_write_buffer==i &&
                              (OUTPUT_WRITE_BOUNDED || output_write_x<1280)),
            .wa(output_write_x),.wd(output_write_data),
            .rclk(pix_clk),.re(1'b1),
            .ra(output_read_x),.rd(output_pixels[i])
        );
    end endgenerate
    // EG4 32K RAM has no native 4096x9 mode. Store the low byte in four
    // 4096x8 banks and pack eight ninth bits into each byte of a fifth bank.
    // Each overview producer writes addresses 0..14399 in order. A partial
    // byte is never published; the image is committed only after its last pixel.
    wire [7:0] overview_pixels[0:7];
    wire [7:0] overview_high[0:1];
    reg [7:0] packed_high[0:1];
    reg [2:0] overview_bit_q;
    reg [2:0] overview_select_q;
    reg overview_valid_q;
    always @(posedge pix_clk) begin
        overview_select_q<={overview_read_buffer,overview_read_address[13:12]};
        overview_bit_q<=overview_read_address[2:0];
        overview_valid_q<=overview_read_address<14400;
    end
    assign overview_pixel=overview_valid_q ?
        {overview_high[overview_select_q[2]][overview_bit_q],overview_pixels[overview_select_q]} : 9'd0;
    generate for (i=0;i<8;i=i+1) begin : overview_bank
        resident_native_ram #(.WIDTH(8),.AW(12),.DEPTH(4096),.KIND("32K")) ram (
            .wclk(mem_clk),.we(overview_we && overview_write_address<14400 &&
                             {overview_write_buffer,overview_write_address[13:12]}==i),
            .wa(overview_write_address[11:0]),.wd(overview_write_data[7:0]),
            .rclk(pix_clk),.re(1'b1),
            .ra(overview_read_address[11:0]),.rd(overview_pixels[i])
        );
    end
    for (i=0;i<2;i=i+1) begin : overview_high_bank
        always @(posedge mem_clk)
            if (overview_we && overview_write_buffer==i && overview_write_address<14400)
                packed_high[i][overview_write_address[2:0]]<=overview_write_data[8];
        resident_native_ram #(.WIDTH(8),.AW(11),.DEPTH(2048),.KIND("32K")) ram (
            .wclk(mem_clk),.we(overview_we && overview_write_address<14400 &&
                              overview_write_buffer==i && overview_write_address[2:0]==7),
            .wa(overview_write_address[13:3]),.wd({overview_write_data[8],packed_high[i][6:0]}),
            .rclk(pix_clk),.re(1'b1),
            .ra(overview_read_address[13:3]),.rd(overview_high[i])
        );
    end endgenerate
endmodule

module resident_native_ram #(
    parameter WIDTH=16, AW=10, DEPTH=1024, KIND="32K"
) (
    input wire wclk, we,
    input wire [AW-1:0] wa,
    input wire [WIDTH-1:0] wd,
    input wire rclk, re,
    input wire [AW-1:0] ra,
    output wire [WIDTH-1:0] rd
);
    EG_LOGIC_BRAM #(
        .DATA_WIDTH_A(WIDTH),.DATA_WIDTH_B(WIDTH),
        .ADDR_WIDTH_A(AW),.ADDR_WIDTH_B(AW),.DATA_DEPTH_A(DEPTH),.DATA_DEPTH_B(DEPTH),
        .MODE("DP"),.REGMODE_A("NOREG"),.REGMODE_B("NOREG"),
        .WRITEMODE_A("NORMAL"),.WRITEMODE_B("NORMAL"),.RESETMODE("SYNC"),
        .BYTE_ENABLE(0),.BYTE_A(1),.BYTE_B(1),.IMPLEMENT(KIND)
    ) storage (
        .doa(),.dob(rd),.dia(wd),.dib({WIDTH{1'b0}}),
        .cea(1'b1),.ocea(1'b1),.clka(wclk),.wea(we),.rsta(1'b0),
        .ceb(re),.oceb(1'b1),.clkb(rclk),.web(1'b0),.rstb(1'b0),
        .bea(1'b1),.beb(1'b1),.addra(wa),.addrb(ra)
    );
endmodule
