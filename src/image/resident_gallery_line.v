`timescale 1ns/1ps

// Feasibility-path compositor. Same-clock row ownership is supplied by the
// scheduler; no source row may change until done. Fetch and composition run
// concurrently on opposite RAM ports. Pixel-domain ownership is upstream.
// Existing 3-column image bounds: x=80,480,880; width=320. Blank areas are black.
module resident_gallery_line (
    input wire clk, rst_n, start,
    input wire buffer_half,
    input wire [2:0] present_columns,
    input wire [5:0] source_ready,
    output reg busy,
    output reg done,
    output wire [2:0] source_read_buffer,
    output wire [9:0] source_read_x,
    input wire [15:0] source_pixel,
    output wire output_we, output_write_buffer,
    output wire [10:0] output_write_x,
    output wire [15:0] output_write_data
);
    reg half_q;
    reg [2:0] present_q;
    reg [10:0] x;
    wire [1:0] column = x>=880 ? 2 : (x>=480 ? 1 : 0);
    wire [10:0] left_x = column==2 ? 880 : (column==1 ? 480 : 80);
    wire in_image = x>=left_x && x<left_x+320 && present_q[column];
    wire launch = busy && x<1280 && (!in_image || source_ready[source_read_buffer]);
    reg valid_q, blank_q;
    reg [10:0] output_x_q;
    reg valid_data_q, blank_data_q;
    reg [10:0] output_x_data_q;
    assign source_read_buffer=column+(half_q ? 3 : 0);
    assign source_read_x=(x-left_x)*3;
    assign output_we=valid_data_q;
    assign output_write_buffer=half_q;
    assign output_write_x=output_x_data_q;
    assign output_write_data=blank_data_q ? 16'd0 : source_pixel;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            half_q<=0; present_q<=0; x<=0; busy<=0; done<=0;
            valid_q<=0; blank_q<=0; output_x_q<=0;
            valid_data_q<=0; blank_data_q<=0; output_x_data_q<=0;
        end else begin
            done<=0; valid_q<=launch;
            valid_data_q<=valid_q;
            if (valid_q) begin
                blank_data_q<=blank_q;
                output_x_data_q<=output_x_q;
            end
            if (start && !busy) begin
                half_q<=buffer_half; present_q<=present_columns;
                x<=0; busy<=1;
            end
            if (launch) begin
                output_x_q<=x; blank_q<=!in_image; x<=x+1'b1;
            end
            // Last pixel is written into output RAM at this edge.
            if (valid_data_q && output_x_data_q==1279) begin busy<=0; done<=1; end
        end
    end
endmodule
