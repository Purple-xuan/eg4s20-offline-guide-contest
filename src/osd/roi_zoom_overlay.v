`timescale 1ns/1ps

module roi_zoom_overlay #(
    parameter integer PIPELINED = 0
) (
    input wire pclk, rst_n, frame_start,
    input wire [1:0] mode,
    input wire [7:0] grid_x,
    input wire [6:0] grid_y,
    input wire [3:0] size_units, display_units,
    input wire display_zoom, busy, hidden,
    input wire thumbnail_ready,
    input wire [23:0] thumbnail_rgb,
    input wire in_de,
    input wire [11:0] pixel_x, pixel_y,
    output wire hit,
    output wire [23:0] color
);
    reg [10:0] x0, x1, y0, y1;
    reg enabled, show_box, resizing, loading;
    reg show_overview;
    reg [7:0] view_x0, view_x1;
    reg [6:0] view_y0, view_y1;
    reg [34:0] hundreds, tens, ones;
    reg [11:0] percent_bcd;
    wire [3:0] units = display_zoom ? display_units : size_units;
    always @* begin
        case (units)
            2: percent_bcd = 12'h500;
            3: percent_bcd = 12'h333;
            4: percent_bcd = 12'h250;
            5: percent_bcd = 12'h200;
            6: percent_bcd = 12'h167;
            7: percent_bcd = 12'h143;
            8: percent_bcd = 12'h125;
            9: percent_bcd = 12'h111;
            default: percent_bcd = 12'h100;
        endcase
    end
    function [34:0] digit;
        input [3:0] n;
        begin
            case (n)
                0: digit=35'b01110_10001_10011_10101_11001_10001_01110;
                1: digit=35'b00100_01100_00100_00100_00100_00100_01110;
                2: digit=35'b01110_10001_00001_00010_00100_01000_11111;
                3: digit=35'b11110_00001_00001_01110_00001_00001_11110;
                4: digit=35'b00010_00110_01010_10010_11111_00010_00010;
                5: digit=35'b11111_10000_10000_11110_00001_00001_11110;
                6: digit=35'b01110_10000_10000_11110_10001_10001_01110;
                7: digit=35'b11111_00001_00010_00100_01000_01000_01000;
                8: digit=35'b01110_10001_10001_01110_10001_10001_01110;
                default: digit=35'b01110_10001_10001_01111_00001_00001_01110;
            endcase
        end
    endfunction
    always @(posedge pclk or negedge rst_n) begin
        if (!rst_n) begin
            x0<=0; x1<=0; y0<=0; y1<=0;
            enabled<=0; show_box<=0; resizing<=0; loading<=0;
            show_overview<=0;
            view_x0<=0; view_x1<=0; view_y0<=0; view_y1<=0;
            hundreds<=0; tens<=0; ones<=0;
        end else if (frame_start) begin
            x0 <= {grid_x,3'b0};
            y0 <= {1'b0,grid_y,3'b0};
            x1 <= {grid_x,3'b0} + {size_units,7'b0};
            y1 <= {1'b0,grid_y,3'b0} + (({7'b0,size_units} << 6) + ({7'b0,size_units} << 3));
            enabled <= (mode != 0 || display_zoom) && !hidden;
            show_box <= mode != 0 && !display_zoom;
            resizing <= mode == 2;
            loading <= busy;
            // The navigation grid is exactly a 160 x 90 map of the source.
            show_overview <= display_zoom && thumbnail_ready;
            view_x0 <= grid_x;
            view_x1 <= grid_x + {display_units,4'b0};
            view_y0 <= grid_y;
            view_y1 <= grid_y + ({3'b0,display_units} << 3) + display_units;
            hundreds <= digit(percent_bcd[11:8]);
            tens <= digit(percent_bcd[7:4]);
            ones <= digit(percent_bcd[3:0]);
        end
    end
    wire rectangle = show_box && pixel_x >= x0 && pixel_x < x1 &&
        pixel_y >= y0 && pixel_y < y1 &&
        (pixel_x < x0+11'd3 || pixel_x >= x1-11'd3 ||
         pixel_y < y0+11'd3 || pixel_y >= y1-11'd3);
    wire panel = pixel_x >= 592 && pixel_x < 688 && pixel_y >= 12 && pixel_y < 40;
    wire [7:0] dx = pixel_x[7:0] - 8'd104;
    wire [4:0] dy = pixel_y[4:0] - 5'd18;
    wire [5:0] cell_x = dx[7:1];
    wire [2:0] row = dy[3:1];
    function glyph_pixel;
        input [34:0] bits;
        input [2:0] r;
        input [2:0] c;
        reg [4:0] row_bits;
        begin
            case (r)
                0: row_bits=bits[34:30];
                1: row_bits=bits[29:25];
                2: row_bits=bits[24:20];
                3: row_bits=bits[19:15];
                4: row_bits=bits[14:10];
                5: row_bits=bits[9:5];
                6: row_bits=bits[4:0];
                default: row_bits=0;
            endcase
            case (c)
                0: glyph_pixel=row_bits[4];
                1: glyph_pixel=row_bits[3];
                2: glyph_pixel=row_bits[2];
                3: glyph_pixel=row_bits[1];
                4: glyph_pixel=row_bits[0];
                default: glyph_pixel=0;
            endcase
        end
    endfunction
    wire [5:0] draw_cell_x;
    wire [2:0] draw_row;
    wire [8:0] draw_flags;
    wire [2:0] col1=draw_cell_x-6, col2=draw_cell_x-12, col3=draw_cell_x-18;
    wire text_ink =
        (draw_cell_x < 6 && glyph_pixel(hundreds,draw_row,draw_cell_x[2:0])) ||
        (draw_cell_x >= 6 && draw_cell_x < 12 && glyph_pixel(tens,draw_row,col1)) ||
        (draw_cell_x >= 12 && draw_cell_x < 18 && glyph_pixel(ones,draw_row,col2)) ||
        (draw_cell_x >= 18 && draw_cell_x < 24 &&
         glyph_pixel(35'b11001_11010_00100_01000_10110_00110_00000,draw_row,col3));
    wire text_bounds = pixel_x >= 616 && pixel_x < 664 &&
        pixel_y >= 18 && pixel_y < 32;
    wire text_pixel = draw_flags[5] && text_ink;
    wire busy_pixel = loading && pixel_x >= 674 && pixel_x < 680 &&
        pixel_y >= 22 && pixel_y < 28;
    // Four-pixel padding around the 160 x 90 full-image thumbnail.
    wire overview = show_overview && pixel_x >= 1096 && pixel_x < 1264 &&
        pixel_y >= 12 && pixel_y < 110;
    wire map_area = pixel_x >= 1100 && pixel_x < 1260 &&
        pixel_y >= 16 && pixel_y < 106;
    wire [7:0] map_x = pixel_x[7:0] - 8'd76;
    wire [6:0] map_y = pixel_y[6:0] - 7'd16;
    wire map_border = map_area && (map_x == 0 || map_x == 159 ||
        map_y == 0 || map_y == 89);
    wire viewport = map_area && map_x >= view_x0 && map_x < view_x1 &&
        map_y >= view_y0 && map_y < view_y1;
    wire viewport_border = viewport && (map_x < view_x0+8'd2 ||
        map_x >= view_x1-8'd2 || map_y < view_y0+7'd2 || map_y >= view_y1-7'd2);
    generate if(PIPELINED) begin : g_render_pipeline
        reg [8:0] flags_q;
        reg [5:0] cell_q;
        reg [2:0] row_q;
        always @(posedge pclk or negedge rst_n) begin
            if(!rst_n) begin flags_q<=0;cell_q<=0;row_q<=0;end
            else begin
                flags_q<={in_de,rectangle,panel,text_bounds,busy_pixel,
                          overview,viewport_border,map_border,map_area};
                cell_q<=cell_x;row_q<=row;
            end
        end
        assign draw_flags=flags_q;
        assign draw_cell_x=cell_q;
        assign draw_row=row_q;
    end else begin : g_render_direct
        assign draw_flags={in_de,rectangle,panel,text_bounds,busy_pixel,
                           overview,viewport_border,map_border,map_area};
        assign draw_cell_x=cell_x;
        assign draw_row=row;
    end endgenerate
    wire [23:0] overview_color = draw_flags[2] ? 24'h38f0cf :
        (draw_flags[1] ? 24'hd4dce0 : (draw_flags[0] ? thumbnail_rgb : 24'h172025));
    assign hit = draw_flags[8] && enabled && (draw_flags[7] || draw_flags[6] || draw_flags[3]);
    assign color = draw_flags[3] ? overview_color :
                   draw_flags[6] ? (text_pixel ? 24'hffffff : (draw_flags[4] ? 24'hffc23d : 24'h172025)) :
                   (resizing ? 24'hffc23d : 24'h38f0cf);
endmodule

// Seven 128x72 RGB333 thumbnails, averaged from complete 10x10 source areas.
// Slot 6 (the former PIC7) is intentionally unused; slot 7 still stores PIC8.
module gallery_thumbnail_cache (
    input wire clk, rst, capture_start, capture_commit,
    input wire [2:0] capture_page,
    input wire pixel_valid, pixel_flip,
    input wire [23:0] pixel_rgb,
    output reg [7:0] ready_mask,
    input wire pclk,
    input wire [2:0] lookup_page,
    input wire [6:0] lookup_x,
    input wire [6:0] lookup_y,
    output wire [23:0] rgb
);
    // Six pages use 32K RAM: eight low bits plus a packed high-bit plane.
    // The remaining page (slot 7/PIC8) uses one complete 9K RAM bank group.
    (* ram_style="bram" *) reg [14:0] vertical_sums [0:383];
    wire [111:0] low_bank_rgb;
    wire [80:0] upper_bank_rgb;
    reg [13:0] low_bank_select;
    reg [8:0] upper_bank_select;
    wire [7:0] read_high_byte;
    reg [2:0] read_high_bit;
    wire read_high=read_high_byte[read_high_bit];
    reg [8:0] read_upper;
    reg read_lower_bank, read_valid;
    reg [7:0] read_low;
    wire [8:0] read_pixel=read_valid ?
        (read_lower_bank ? {read_high,read_low} : read_upper) : 9'd0;
    reg capturing, complete, commit_pending;
    reg [2:0] page;
    reg [6:0] column, row;
    reg [3:0] sub_x, sub_y;
    reg [13:0] samples;
    reg [11:0] horizontal_r, horizontal_g, horizontal_b;
    reg block_valid, block_first_row, block_last_row;
    reg [6:0] block_column;
    reg [13:0] block_offset;
    reg [11:0] block_r, block_g, block_b;
    reg vertical_read_valid;
    reg [1:0] vertical_read_channel, vertical_write_phase;
    reg [14:0] vertical_read_data, vertical_r, vertical_g, vertical_b;
    reg [14:0] total_r, total_g, total_b;
    reg [6:0] vertical_write_column;
    reg sum_valid, sum_lower_bank;
    reg [15:0] sum_address;
    wire accept_pixel=pixel_valid && capturing;
    wire block_end=accept_pixel && sub_x==9;
    wire [14:0] next_total_r=block_first_row ? {3'd0,block_r} : vertical_r+block_r;
    wire [14:0] next_total_g=block_first_row ? {3'd0,block_g} : vertical_g+block_g;
    wire [14:0] next_total_b=block_first_row ? {3'd0,block_b} : vertical_b+block_b;
    function [15:0] bank_base;
        input [2:0] id;
        begin
            case(id)
                0: bank_base=16'd0;
                1: bank_base=16'd9216;
                2: bank_base=16'd18432;
                3: bank_base=16'd27648;
                4: bank_base=16'd36864;
                5: bank_base=16'd46080;
                // Slot 7 is the retained original PIC8. Reuse the one
                // upper-page bank group formerly occupied by slot 6.
                7: bank_base=16'd0;
                default: bank_base=16'd0;
            endcase
        end
    endfunction
    // Nearest RGB333 level after averaging 100 RGB888 pixels. Thresholds
    // are the midpoints of the actual expanded levels, avoiding division.
    function [2:0] quantize_sum;
        input [14:0] value;
        begin
            if(value<12750)
                quantize_sum=value<5450 ? (value<1800 ? 0 : 1) : (value<9100 ? 2 : 3);
            else
                quantize_sum=value<20050 ? (value<16400 ? 4 : 5) : (value<23700 ? 6 : 7);
        end
    endfunction
    reg [2:0] lookup_page_q;
    reg [6:0] lookup_x_q;
    reg [6:0] lookup_y_q;
    always @(posedge pclk) begin
        lookup_page_q<=lookup_page;lookup_x_q<=lookup_x;lookup_y_q<=lookup_y;
    end
    wire lookup_valid=lookup_y_q<72 && lookup_page_q!=3'd6;
    wire [15:0] read_address=bank_base(lookup_page_q)+{lookup_y_q,lookup_x_q};
    wire [15:0] read_addr=lookup_valid ? read_address : 16'd0;
    reg write_enable_q, write_lower_bank_q;
    reg [15:0] write_addr_q;
    reg [8:0] write_rgb_q;
    reg [7:0] packed_high;
    reg high_write_enable;
    reg [12:0] high_write_addr;
    // Each row contains a multiple of eight pixels. Assemble complete
    // high-bit bytes so the 32K RAM's native eight-bit port stays efficient.
    always @(posedge clk or posedge rst) begin
        if(rst) begin packed_high<=0;high_write_enable<=0;high_write_addr<=0;end
        else begin
            high_write_enable<=0;
            if(write_enable_q && write_lower_bank_q) begin
                packed_high[write_addr_q[2:0]]<=write_rgb_q[8];
                if(write_addr_q[2:0]==7) begin
                    high_write_enable<=1;
                    high_write_addr<=write_addr_q[15:3];
                end
            end
        end
    end
    always @(posedge clk or posedge rst) begin
        if(rst) begin
            write_enable_q<=0;write_lower_bank_q<=0;write_addr_q<=0;write_rgb_q<=0;
        end else if(capture_start) begin
            write_enable_q<=0;
        end else begin
            write_enable_q<=sum_valid;
            if(sum_valid) begin
                write_addr_q<=sum_address;
                write_lower_bank_q<=sum_lower_bank;
                write_rgb_q<={quantize_sum(total_r),quantize_sum(total_g),quantize_sum(total_b)};
            end
        end
    end
    EG_LOGIC_BRAM #(
        .DATA_WIDTH_A(8),.DATA_WIDTH_B(8),.ADDR_WIDTH_A(13),.ADDR_WIDTH_B(13),
        .DATA_DEPTH_A(8192),.DATA_DEPTH_B(8192),.MODE("DP"),
        .REGMODE_A("NOREG"),.REGMODE_B("NOREG"),
        .WRITEMODE_A("NORMAL"),.WRITEMODE_B("NORMAL"),
        .RESETMODE("SYNC"),.BYTE_ENABLE(0),.BYTE_A(1),.BYTE_B(1),
        .IMPLEMENT("32K")
    ) u_thumbnail_high (
        .doa(),.dob(read_high_byte),
        .dia(packed_high),.dib(8'd0),
        .cea(1'b1),.ocea(1'b1),.clka(clk),.wea(high_write_enable),.rsta(1'b0),
        .ceb(1'b1),.oceb(1'b1),.clkb(pclk),.web(1'b0),.rstb(1'b0),
        .bea(1'b1),.beb(1'b1),.addra(high_write_addr),.addrb(read_addr[15:3])
    );
    // Explicit native-sized banks prevent TD from rounding each large array
    // to a power of two and spilling the remaining image storage into LUTs.
    genvar low_bank, upper_bank;
    generate for(low_bank=0;low_bank<14;low_bank=low_bank+1) begin : g_low_bank
        always @(posedge pclk)
            low_bank_select[low_bank]<=read_addr[15:12]==low_bank;
        EG_LOGIC_BRAM #(
            .DATA_WIDTH_A(8),.DATA_WIDTH_B(8),.ADDR_WIDTH_A(12),.ADDR_WIDTH_B(12),
            .DATA_DEPTH_A(4096),.DATA_DEPTH_B(4096),.MODE("DP"),
            .REGMODE_A("NOREG"),.REGMODE_B("NOREG"),
            .WRITEMODE_A("NORMAL"),.WRITEMODE_B("NORMAL"),
            .RESETMODE("SYNC"),.BYTE_ENABLE(0),.BYTE_A(1),.BYTE_B(1),.IMPLEMENT("32K")
        ) storage (
            .doa(),.dob(low_bank_rgb[low_bank*8+:8]),
            .dia(write_rgb_q[7:0]),.dib(8'd0),
            .cea(1'b1),.ocea(1'b1),.clka(clk),
            .wea(write_enable_q && write_lower_bank_q && write_addr_q[15:12]==low_bank),.rsta(1'b0),
            .ceb(1'b1),.oceb(1'b1),.clkb(pclk),.web(1'b0),.rstb(1'b0),
            .bea(1'b1),.beb(1'b1),.addra(write_addr_q[11:0]),.addrb(read_addr[11:0])
        );
    end
    for(upper_bank=0;upper_bank<9;upper_bank=upper_bank+1) begin : g_upper_bank
        always @(posedge pclk)
            upper_bank_select[upper_bank]<=read_addr[15:10]==upper_bank;
        EG_LOGIC_BRAM #(
            .DATA_WIDTH_A(9),.DATA_WIDTH_B(9),.ADDR_WIDTH_A(10),.ADDR_WIDTH_B(10),
            .DATA_DEPTH_A(1024),.DATA_DEPTH_B(1024),.MODE("DP"),
            .REGMODE_A("NOREG"),.REGMODE_B("NOREG"),
            .WRITEMODE_A("NORMAL"),.WRITEMODE_B("NORMAL"),
            .RESETMODE("SYNC"),.BYTE_ENABLE(0),.BYTE_A(1),.BYTE_B(1),.IMPLEMENT("9K")
        ) storage (
            .doa(),.dob(upper_bank_rgb[upper_bank*9+:9]),
            .dia(write_rgb_q),.dib(9'd0),
            .cea(1'b1),.ocea(1'b1),.clka(clk),
            .wea(write_enable_q && !write_lower_bank_q && write_addr_q[15:10]==upper_bank),.rsta(1'b0),
            .ceb(1'b1),.oceb(1'b1),.clkb(pclk),.web(1'b0),.rstb(1'b0),
            .bea(1'b1),.beb(1'b1),.addra(write_addr_q[9:0]),.addrb(read_addr[9:0])
        );
    end endgenerate
    integer bank_index;
    always @* begin
        read_low=0;read_upper=0;
        for(bank_index=0;bank_index<14;bank_index=bank_index+1)
            read_low=read_low | (low_bank_rgb[bank_index*8+:8] & {8{low_bank_select[bank_index]}});
        for(bank_index=0;bank_index<9;bank_index=bank_index+1)
            read_upper=read_upper | (upper_bank_rgb[bank_index*9+:9] & {9{upper_bank_select[bank_index]}});
    end
    always @(posedge clk) begin
        // A single narrow line RAM is time-multiplexed over the ten source
        // clocks per column. Reads and writes continue safely through stalls.
        if(accept_pixel && sub_x<3)
            vertical_read_data<=vertical_sums[{sub_x[1:0],column}];
        case(vertical_write_phase)
            3: vertical_sums[{2'd0,vertical_write_column}]<=total_r;
            2: vertical_sums[{2'd1,vertical_write_column}]<=total_g;
            1: vertical_sums[{2'd2,vertical_write_column}]<=total_b;
            default: begin end
        endcase
    end
    always @(posedge pclk) begin
        read_high_bit<=read_addr[2:0];
        read_lower_bank<=lookup_page_q<6;
        read_valid<=lookup_valid;
    end
    assign rgb={read_pixel[8:6],read_pixel[8:6],read_pixel[8:7],
                read_pixel[5:3],read_pixel[5:3],read_pixel[5:4],
                read_pixel[2:0],read_pixel[2:0],read_pixel[2:1]};
    always @(posedge clk or posedge rst) begin
        if(rst) begin
            ready_mask<=0;capturing<=0;complete<=0;commit_pending<=0;page<=0;
            column<=0;row<=0;sub_x<=0;sub_y<=0;samples<=0;
            horizontal_r<=0;horizontal_g<=0;horizontal_b<=0;
            block_valid<=0;block_first_row<=0;block_last_row<=0;
            block_column<=0;block_offset<=0;block_r<=0;block_g<=0;block_b<=0;
            vertical_read_valid<=0;vertical_read_channel<=0;
            vertical_r<=0;vertical_g<=0;vertical_b<=0;
            total_r<=0;total_g<=0;total_b<=0;
            vertical_write_phase<=0;vertical_write_column<=0;
            sum_valid<=0;sum_address<=0;sum_lower_bank<=0;
        end else begin
            block_valid<=block_end;
            sum_valid<=block_valid && block_last_row;
            vertical_read_valid<=accept_pixel && sub_x<3;
            if(accept_pixel && sub_x<3) vertical_read_channel<=sub_x[1:0];
            if(vertical_read_valid) begin
                case(vertical_read_channel)
                    0: vertical_r<=vertical_read_data;
                    1: vertical_g<=vertical_read_data;
                    2: vertical_b<=vertical_read_data;
                    default: begin end
                endcase
            end
            if(vertical_write_phase!=0) vertical_write_phase<=vertical_write_phase-1'b1;
            if(block_valid) begin
                total_r<=next_total_r;total_g<=next_total_g;total_b<=next_total_b;
                vertical_write_column<=block_column;
                vertical_write_phase<=3;
                sum_address<=bank_base(page)+block_offset;
                sum_lower_bank<=page<6;
            end
            if(capture_start) begin
                capturing<=capture_page!=3'd6 && !ready_mask[capture_page];
                complete<=0;commit_pending<=0;
                page<=capture_page;column<=0;row<=0;sub_x<=0;sub_y<=0;samples<=0;
                horizontal_r<=0;horizontal_g<=0;horizontal_b<=0;
                block_valid<=0;sum_valid<=0;vertical_read_valid<=0;vertical_write_phase<=0;
            end else begin
                if(accept_pixel) begin
                    if(sub_x==9) begin
                        block_r<=horizontal_r+pixel_rgb[23:16];
                        block_g<=horizontal_g+pixel_rgb[15:8];
                        block_b<=horizontal_b+pixel_rgb[7:0];
                        block_first_row<=sub_y==0;block_last_row<=sub_y==9;
                        block_column<=column;
                        block_offset<={pixel_flip ? 7'd71-row : row,column};
                        horizontal_r<=0;horizontal_g<=0;horizontal_b<=0;sub_x<=0;
                        if(sub_y==9) samples<=samples+1'b1;
                        if(column==127) begin
                            column<=0;
                            if(sub_y==9) begin
                                sub_y<=0;
                                if(row==71) begin capturing<=0;complete<=1;end
                                else row<=row+1'b1;
                            end else sub_y<=sub_y+1'b1;
                        end else column<=column+1'b1;
                    end else begin
                        horizontal_r<=horizontal_r+pixel_rgb[23:16];
                        horizontal_g<=horizontal_g+pixel_rgb[15:8];
                        horizontal_b<=horizontal_b+pixel_rgb[7:0];
                        sub_x<=sub_x+1'b1;
                    end
                end
                if(capture_commit && !ready_mask[page]) commit_pending<=1;
                // Publish only after validation and the final averaged pixel
                // have both reached RAM, even for an immediate final commit.
                if((capture_commit || commit_pending) && !ready_mask[page] &&
                   !accept_pixel && !block_valid && !sum_valid && !write_enable_q &&
                   !high_write_enable && vertical_write_phase==0) begin
                    ready_mask[page]<=complete && samples==9216;
                    complete<=0;capturing<=0;commit_pending<=0;
                end
            end
        end
    end
endmodule

module gallery_layout (
    input wire [11:0] x,y,
    output wire tile, image_area,
    output wire [3:0] slot,
    output wire [8:0] local_x,
    output wire [7:0] local_y,
    output wire [6:0] thumb_x,
    output wire [6:0] thumb_y
);
    wire [1:0] col=x>=840 ? 2 : (x>=440 ? 1 : 0);
    wire [1:0] row=y>=484 ? 2 : (y>=252 ? 1 : 0);
    wire [11:0] left=col==0 ? 64 : (col==1 ? 464 : 864);
    wire [11:0] top=row==0 ? 20 : (row==1 ? 252 : 484);
    wire [11:0] dx=x-left,dy=y-top;
    assign local_x=dx[8:0];
    assign local_y=dy[7:0];
    assign slot={2'd0,row}+({2'd0,row}<<1)+col;
    assign tile=dx<352 && dy<220;
    assign image_area=tile && dx>=16 && dx<336 && dy>=12 && dy<192;
    wire [8:0] image_x=dx[8:0]-9'd16;
    wire [7:0] image_y=dy[7:0]-8'd12;
    // floor(2*u/5), exact for this 320x180 display area.
    wire [16:0] mapped_x=image_x*8'd205;
    wire [15:0] mapped_y=image_y*8'd205;
    assign thumb_x=mapped_x[15:9];
    assign thumb_y=mapped_y[15:9];
endmodule

// PIC2 is the authored menu image. Only a rectangular selection outline is
// generated here. Bounds are ceil(source_coordinate*4/3), with exclusive ends.
module home_menu_overlay (
    input wire pclk,rst_n,active,in_de,
    input wire [2:0] selected,
    input wire [7:0] resource_mask,
    input wire [11:0] pixel_x,pixel_y,
    output reg hit,
    output reg [23:0] color
);
    reg [11:0] left_edge,right_edge,top_edge,bottom_edge;
    reg present;
    always @* begin
        case(selected)
            0,3:begin left_edge=64;right_edge=427;end
            1,4:begin left_edge=459;right_edge=822;end
            default:begin left_edge=854;right_edge=1216;end
        endcase
        top_edge=selected<3 ? 222 : 427;
        bottom_edge=selected<3 ? 398 : 603;
        case(selected)
            0:present=|(resource_mask & 8'hbc);
            1:present=resource_mask[2];2:present=resource_mask[3];
            3:present=resource_mask[4];4:present=resource_mask[5];
            5:present=resource_mask[7];default:present=0;
        endcase
    end
    always @(posedge pclk or negedge rst_n) begin
        if(!rst_n) begin hit<=0;color<=0;end
        else begin
            hit<=active && selected<6 && in_de &&
                pixel_x>=left_edge && pixel_x<right_edge &&
                pixel_y>=top_edge && pixel_y<bottom_edge &&
                (pixel_x<left_edge+6 || pixel_x>=right_edge-6 ||
                 pixel_y<top_edge+6 || pixel_y>=bottom_edge-6);
            color<=present ? 24'hffe0a0 : 24'he85d5d;
        end
    end
endmodule

module gallery_overlay (
    input wire pclk,rst_n,
    input wire active, in_de,
    input wire [2:0] selected,current_page,
    input wire [7:0] resource_mask,ready_mask,
    input wire [11:0] pixel_x,pixel_y,
    input wire [23:0] thumbnail_rgb,
    output wire hit,
    output wire [23:0] color
);
    wire tile_w,image_w;
    wire [3:0] slot_w;
    wire [8:0] dx_w;
    wire [7:0] dy_w;
    reg tile,image_area,in_de_q,checker_q;
    reg [3:0] slot;
    reg [8:0] dx;
    reg [7:0] dy;
    reg [2:0] glyph_row,glyph_bit;
    gallery_layout layout(.x(pixel_x),.y(pixel_y),.tile(tile_w),.image_area(image_w),
        .slot(slot_w),.local_x(dx_w),.local_y(dy_w),.thumb_x(),.thumb_y());
    always @(posedge pclk or negedge rst_n) begin
        if(!rst_n) begin
            tile<=0;image_area<=0;in_de_q<=0;checker_q<=0;
            slot<=8;dx<=0;dy<=0;glyph_row<=0;glyph_bit<=0;
        end else begin
            tile<=tile_w;image_area<=image_w;in_de_q<=in_de;
            slot<=slot_w;dx<=dx_w;dy<=dy_w;
            checker_q<=pixel_x[4]^pixel_y[4];
            glyph_row<=pixel_y[3:1]-(pixel_y[8] ? 3'd1 : 3'd5);
            glyph_bit<=3'd1-pixel_x[3:1];
        end
    end
    wire present=slot<8 && resource_mask[slot[2:0]];
    wire chosen=slot=={1'b0,selected};
    wire border=dx<3 || dx>=349 || dy<3 || dy>=217;
    wire current=slot=={1'b0,current_page} && dx>=24 && dx<32 && dy>=201 && dy<209;
    function [34:0] digit;
        input [3:0] n;
        begin
            case(n)
                1:digit=35'b00100_01100_00100_00100_00100_00100_01110;
                2:digit=35'b01110_10001_00001_00010_00100_01000_11111;
                3:digit=35'b11110_00001_00001_01110_00001_00001_11110;
                4:digit=35'b00010_00110_01010_10010_11111_00010_00010;
                5:digit=35'b11111_10000_10000_11110_00001_00001_11110;
                6:digit=35'b01110_10000_10000_11110_10001_10001_01110;
                7:digit=35'b11111_00001_00010_00100_01000_01000_01000;
                default:digit=35'b01110_10001_10001_01110_10001_10001_01110;
            endcase
        end
    endfunction
    function [4:0] digit_row;
        input [3:0] n;
        input [2:0] r;
        reg [34:0] bitmap;
        begin
            bitmap=digit(n);
            case(r)
                0:digit_row=bitmap[34:30];
                1:digit_row=bitmap[29:25];
                2:digit_row=bitmap[24:20];
                3:digit_row=bitmap[19:15];
                4:digit_row=bitmap[14:10];
                5:digit_row=bitmap[9:5];
                6:digit_row=bitmap[4:0];
                default:digit_row=0;
            endcase
        end
    endfunction
    function [3:0] page_display_number;
        input [2:0] index;
        begin
            case (index)
                3'd0: page_display_number=4'd1;
                3'd1: page_display_number=4'd2;
                3'd2: page_display_number=4'd3;
                3'd3: page_display_number=4'd4;
                3'd4: page_display_number=4'd5;
                3'd5: page_display_number=4'd6;
                3'd7: page_display_number=4'd7;
                default: page_display_number=4'd0;
            endcase
        end
    endfunction
    // Label origins share low coordinate bits; use a small row/column
    // lookup instead of a multiply and a 35-bit variable bit selection.
    wire [3:0] slot_number=page_display_number(slot[2:0]);
    wire [4:0] glyph_bits=digit_row(slot_number,glyph_row);
    wire ink=present && slot_number!=0 && dx>=170 && dx<180 && dy>=198 && dy<212 && glyph_bits[glyph_bit];
    wire [23:0] placeholder=checker_q ? 24'hd6dade : 24'he1e5e8;
    assign hit=active && in_de_q;
    assign color=!(tile && present) ? 24'hf0f2f4 :
        (chosen && border) ? 24'h008eaf :
        image_area ? (ready_mask[slot[2:0]] ? thumbnail_rgb : placeholder) :
        current ? 24'h238650 : ink ? 24'h20272e : 24'hffffff;
endmodule

// Capture the clean full-image raster before OSD and freeze it during zoom.
// Read coordinates lead the OSD coordinates by one clock for synchronous RAM.
module roi_thumbnail_cache (
    input wire pclk, rst_n, frame_start,
    input wire capture_enable,
    input wire [3:0] page_id,
    input wire in_de, pixel_valid,
    input wire [11:0] pixel_x, pixel_y,
    input wire [23:0] pixel_rgb,
    input wire [11:0] lookup_x, lookup_y,
    output wire ready,
    output wire [3:0] cached_page,
    output wire [23:0] rgb
);
    (* ram_style = "bram" *) reg [8:0] pixels [0:3599];
    reg [8:0] read_pixel;
    reg valid, capturing, bad_frame;
    reg [3:0] stored_page, capture_page;
    reg [11:0] write_addr;
    wire select_pixel = in_de && pixel_x < 1280 && pixel_y < 720 &&
        pixel_x[3:0] == 0 && pixel_y[3:0] == 0;
    wire write_pixel = capturing && capture_enable && page_id == capture_page &&
        select_pixel && pixel_valid && write_addr < 3600;
    wire lookup_active = lookup_x >= 1100 && lookup_x < 1260 &&
                         lookup_y >= 16 && lookup_y < 106;
    wire [7:0] map_col = lookup_x[7:0] - 8'd76;
    wire [6:0] map_row = lookup_y[6:0] - 7'd16;
    // Expand each cached 80 x 45 pixel into a 2 x 2 display pixel block.
    wire [6:0] lookup_col = map_col[7:1];
    wire [5:0] lookup_row = map_row[6:1];
    wire [11:0] row_address = ({6'd0,lookup_row} << 6) +
                             ({6'd0,lookup_row} << 4);
    wire [11:0] read_addr = lookup_active ? row_address + lookup_col : 12'd0;
    assign ready = valid && page_id == stored_page;
    assign cached_page = stored_page;
    assign rgb = {read_pixel[8:6],read_pixel[8:6],read_pixel[8:7],
                  read_pixel[5:3],read_pixel[5:3],read_pixel[5:4],
                  read_pixel[2:0],read_pixel[2:0],read_pixel[2:1]};

    always @(posedge pclk) begin
        if (write_pixel)
            pixels[write_addr] <= {pixel_rgb[23:21],pixel_rgb[15:13],pixel_rgb[7:5]};
        read_pixel <= pixels[read_addr];
    end

    always @(posedge pclk or negedge rst_n) begin
        if (!rst_n) begin
            valid <= 0;
            capturing <= 0;
            bad_frame <= 0;
            stored_page <= 0;
            capture_page <= 0;
            write_addr <= 0;
        end else begin
            if (page_id != stored_page) valid <= 0;
            if (capturing && (!capture_enable || page_id != capture_page))
                capturing <= 0;
            if (frame_start) begin
                capturing <= capture_enable && !ready;
                capture_page <= page_id;
                bad_frame <= 0;
                write_addr <= 0;
            end else if (capturing && capture_enable && page_id == capture_page && select_pixel) begin
                if (!pixel_valid) bad_frame <= 1;
                write_addr <= write_addr + 1'b1;
                if (pixel_x == 1264 && pixel_y == 704) begin
                    capturing <= 0;
                    valid <= !bad_frame && pixel_valid && write_addr == 3599;
                    stored_page <= capture_page;
                end
            end
        end
    end
endmodule
