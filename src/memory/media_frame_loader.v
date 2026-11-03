`timescale 1ns/1ps

// Two RGB565 pixels are packed into each 32-bit SDRAM word so four 1280x720
// frames fit in the controller's 21-bit word address space.
module media_frame_loader #(
    parameter integer ADDR_BITS       = 21,
    parameter integer MEM_DATA_BITS   = 32,
    parameter integer BURST_BITS      = 9,
    parameter integer BURST_SIZE      = 256,
    parameter integer IMAGE_WORDS     = 460800,
    parameter integer FRAME_WIDTH     = 1280,
    parameter integer FRAME_HEIGHT    = 720,
    parameter integer WRITE_V_FLIP    = 1,
    parameter integer DYNAMIC_WRITE_V_FLIP = 0
) (
    input  wire                         mem_clk,
    input  wire                         rst,
    input  wire                         sdram_init_done,
    input  wire                         refresh_active,
    input  wire                         controller_busy,
    input  wire                         read_command_busy,

    input  wire                         src_clk,
    input  wire                         write_req,
    output wire                         write_req_ack,
    output wire                         write_finish,
    input  wire                         write_abort_toggle,
    output reg                          write_abort_ack_toggle,
    input  wire [1:0]                   image_index,
    input  wire                         write_v_flip,
    input  wire                         pixel_valid,
    output wire                         pixel_ready,
    input  wire [23:0]                  pixel_rgb,

    output wire                         app_wr_en,
    output wire [ADDR_BITS-1:0]         app_wr_addr,
    output wire [MEM_DATA_BITS-1:0]     app_wr_data,
    output wire [3:0]                   app_wr_mask,
    output wire                         write_engine_busy
);
    localparam [ADDR_BITS-1:0] BANK0_BASE = 0;
    localparam [ADDR_BITS-1:0] BANK1_BASE = IMAGE_WORDS;
    localparam [ADDR_BITS-1:0] BANK2_BASE = IMAGE_WORDS * 2;
    localparam [ADDR_BITS-1:0] BANK3_BASE = IMAGE_WORDS * 3;
    localparam integer FRAME_WORD_WIDTH = FRAME_WIDTH / 2;

    wire [BURST_BITS-1:0] fifo_rdusedw_fifo;
    wire [9:0] fifo_rdusedw = {{(10-BURST_BITS){1'b0}}, fifo_rdusedw_fifo};
    localparam [ADDR_BITS-1:0] IMAGE_WORDS_ADDR = IMAGE_WORDS;
    wire fifo_reset;
    reg [2:0] abort_sync;
    wire abort_pulse = abort_sync[2] ^ abort_sync[1];
    reg pack_half;
    reg [15:0] first_pixel_rgb565;
    wire fifo_full;
    wire [15:0] pixel_rgb565 = {
        pixel_rgb[23:19], pixel_rgb[15:10], pixel_rgb[7:3]
    };
    assign pixel_ready = !pack_half || !fifo_full;
    wire pixel_accept = pixel_valid && pixel_ready;
    wire packed_valid = pixel_accept && pack_half;
    wire [31:0] packed_data = {pixel_rgb565, first_pixel_rgb565};

    always @(posedge src_clk or posedge fifo_reset) begin
        if (fifo_reset) begin
            pack_half <= 1'b0;
            first_pixel_rgb565 <= 16'd0;
        end else if (pixel_accept) begin
            if (!pack_half)
                first_pixel_rgb565 <= pixel_rgb565;
            pack_half <= ~pack_half;
        end
    end

    always @(posedge mem_clk or posedge rst) begin
        if (rst) begin
            abort_sync <= 3'b000;
            write_abort_ack_toggle <= 1'b0;
        end else begin
            abort_sync <= {abort_sync[1:0], write_abort_toggle};
            if (abort_pulse)
                write_abort_ack_toggle <= abort_sync[1];
        end
    end

    assign app_wr_mask = 4'b0000;

    wfifo_32_32_512 u_write_fifo (
        .clkr(mem_clk),
        .clkw(src_clk),
        .rst(fifo_reset),
        .we(packed_valid),
        .re(app_wr_en),
        .di(packed_data),
        .valid(),
        .empty_flag(),
        .full_flag(fifo_full),
        .afull(),
        .aempty(),
        .wrusedw(),
        .rdusedw(fifo_rdusedw_fifo),
        .dout(app_wr_data)
    );

    frame_fifo_write #(
        .MEM_DATA_BITS(MEM_DATA_BITS),
        .ADDR_BITS(ADDR_BITS),
        .BURST_BITS(BURST_BITS),
        .BURST_SIZE(BURST_SIZE),
        .WRITE_V_FLIP(WRITE_V_FLIP),
        .DYNAMIC_WRITE_V_FLIP(DYNAMIC_WRITE_V_FLIP),
        .FRAME_WIDTH(FRAME_WORD_WIDTH),
        .FRAME_HEIGHT(FRAME_HEIGHT)
    ) u_writer (
        .rst(rst),
        .mem_clk(mem_clk),
        .Sdr_init_done(sdram_init_done),
        .Sdr_init_ref_vld(refresh_active),
        .Sdr_busy(controller_busy),
        .App_rd_busy(read_command_busy),
        .O_wr_busy(write_engine_busy),
        .App_wr_en(app_wr_en),
        .App_wr_addr(app_wr_addr),
        .write_req(write_req),
        .write_abort(abort_pulse),
        .write_v_flip(write_v_flip),
        .write_req_ack(write_req_ack),
        .write_finish(write_finish),
        .write_addr_0(BANK0_BASE),
        .write_addr_1(BANK1_BASE),
        .write_addr_2(BANK2_BASE),
        .write_addr_3(BANK3_BASE),
        .write_addr_index(image_index),
        .write_len(IMAGE_WORDS_ADDR),
        .fifo_aclr(fifo_reset),
        .rdusedw(fifo_rdusedw)
    );
endmodule
