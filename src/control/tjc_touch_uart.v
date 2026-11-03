// TJC 0x65 touch frames are 65,page,component,press,ff,ff,ff.
// The panel is an input device; the FPGA remains the owner of navigation state.
module tjc_uart_rx #(
    parameter integer CLK_HZ = 50_000_000,
    parameter integer BAUD = 9600
) (
    input wire clk, rst, rx,
    output reg [7:0] data,
    output reg valid
);
    localparam integer BIT_CLKS = CLK_HZ / BAUD;
    localparam integer COUNT_BITS = $clog2(BIT_CLKS + 1);
    reg rx_meta, rx_sync;
    reg [COUNT_BITS-1:0] count;
    reg [3:0] bit_index;
    reg [7:0] shift;
    (* fsm_encoding="sequential" *) reg [1:0] state;
    always @(posedge clk or posedge rst) begin
        if (rst) begin
            rx_meta <= 1; rx_sync <= 1; count <= 0; bit_index <= 0;
            shift <= 0; state <= 0; data <= 0; valid <= 0;
        end else begin
            rx_meta <= rx;
            rx_sync <= rx_meta;
            valid <= 0;
            case (state)
                0: if (!rx_sync) begin count <= BIT_CLKS / 2; state <= 1; end
                1: if (count != 0) count <= count - 1'b1;
                   else if (!rx_sync) begin count <= BIT_CLKS - 1; bit_index <= 0; state <= 2; end
                   else state <= 0;
                2: if (count != 0) count <= count - 1'b1;
                   else begin
                       shift[bit_index] <= rx_sync;
                       count <= BIT_CLKS - 1;
                       if (bit_index == 7) state <= 3;
                       else bit_index <= bit_index + 1'b1;
                   end
                3: if (count != 0) count <= count - 1'b1;
                   else begin
                       if (rx_sync) begin data <= shift; valid <= 1; end
                       state <= 0;
                   end
            endcase
        end
    end
endmodule

module tjc_uart_tx #(
    parameter integer CLK_HZ = 50_000_000,
    parameter integer BAUD = 9600
) (
    input wire clk, rst,
    input wire [7:0] data,
    input wire start,
    output reg tx,
    output reg busy
);
    localparam integer BIT_CLKS = CLK_HZ / BAUD;
    localparam integer COUNT_BITS = $clog2(BIT_CLKS + 1);
    reg [COUNT_BITS-1:0] count;
    reg [3:0] bit_index;
    reg [9:0] shift;
    always @(posedge clk or posedge rst) begin
        if (rst) begin tx <= 1; busy <= 0; count <= 0; bit_index <= 0; shift <= 0; end
        else if (!busy) begin
            tx <= 1;
            if (start) begin
                shift <= {1'b1, data, 1'b0};
                bit_index <= 0;
                count <= BIT_CLKS - 1;
                busy <= 1;
                tx <= 0;
            end
        end else if (count != 0) count <= count - 1'b1;
        else if (bit_index == 9) begin busy <= 0; tx <= 1; end
        else begin
            bit_index <= bit_index + 1'b1;
            shift <= {1'b1, shift[9:1]};
            tx <= shift[1];
            count <= BIT_CLKS - 1;
        end
    end
endmodule

module tjc_touch_uart #(
    parameter integer CLK_HZ = 50_000_000,
    parameter integer BAUD = 9600
) (
    input wire clk, rst, uart_rx,
    output wire uart_tx,
    input wire [3:0] screen_page,
    input wire [2:0] content_page,
    output reg [11:0] key_n,
    output reg next_n, prev_n, emergency_n,
    output reg hotspot_enable,
    output reg settings_open,
    output reg [1:0] adjust_mode,
    output reg [3:0] menu_command,
    output reg region_valid,
    output reg [1:0] region_index,
    output reg slider_valid,
    output reg [6:0] slider_percent
);
    localparam integer MS_CLKS = CLK_HZ / 1000;
    localparam integer MS_BITS = $clog2(MS_CLKS + 1);
    localparam integer HOLD_MS = 45;
    localparam integer TIMEOUT_MS = 2000;
    localparam integer HOLD_BITS = $clog2(TIMEOUT_MS + 1);
    wire [7:0] rx_data;
    wire rx_valid;
    reg [4:0] frame_index;
    reg [4:0] frame_page, frame_component;
    reg [1:0] frame_edge;
    reg [9:0] touch_x;
    reg [9:0] touch_y;
    reg [9:0] slider_stream_x;
    reg touch_coordinate_valid;
    reg touch_coordinate_pressed;
    reg slider_dragging;
    reg [3:0] action;
    reg action_down;
    reg [HOLD_BITS-1:0] action_age;
    reg [MS_BITS-1:0] ms_count;
    wire ms_tick = ms_count == MS_CLKS-1;
    reg [3:0] sent_page, sending_page;
    reg [2:0] content_page_d;
    reg [3:0] screen_page_d;
    reg [3:0] tx_index;
    (* fsm_encoding="sequential" *) reg [1:0] tx_state;
    reg [7:0] tx_data;
    reg tx_start;
    wire tx_busy;
    reg [3:0] decoded_action;

    tjc_uart_rx #(.CLK_HZ(CLK_HZ), .BAUD(BAUD)) u_rx (
        .clk(clk), .rst(rst), .rx(uart_rx), .data(rx_data), .valid(rx_valid));
    tjc_uart_tx #(.CLK_HZ(CLK_HZ), .BAUD(BAUD)) u_tx (
        .clk(clk), .rst(rst), .data(tx_data), .start(tx_start),
        .tx(uart_tx), .busy(tx_busy));

    // Key indices match home_menu_control's existing active-low key vector.
    localparam [3:0] A_NONE=0, A_CONFIRM=1, A_CANCEL=2, A_LEFT=3,
        A_RIGHT=4, A_UP=5, A_DOWN=6, A_NEXT=7, A_PREV=8,
        A_MENU=9, A_ROI=10, A_DIRECT=11, A_PAUSE=12, A_EMERGENCY=13;
    // Decode while the remaining UART frame bytes arrive. The registered
    // block ROM keeps page/component decode out of the wide control muxes.
    (* ram_style="bram", rom_style="bram" *) reg [15:0] command_rom [0:255];
    reg [15:0] command_q;
    integer command_index;
    initial begin
        for (command_index=0; command_index<256; command_index=command_index+1)
            command_rom[command_index] = 16'd0;
        command_rom[8'h01] = 16'h0001;
        command_rom[8'h11] = 16'h0010;
        command_rom[8'h12] = 16'h0020;
        command_rom[8'h13] = 16'h0003;
        command_rom[8'h14] = 16'h0004;
        command_rom[8'h15] = 16'h0005;
        command_rom[8'h16] = 16'h0006;
        command_rom[8'h17] = 16'h0001;
        command_rom[8'h18] = 16'h0002;
        command_rom[8'h21] = 16'h00c0;
        command_rom[8'h22] = 16'h00d0;
        command_rom[8'h23] = 16'h0001;
        command_rom[8'h24] = 16'h0002;
        command_rom[8'h31] = 16'h0040;
        command_rom[8'h32] = 16'h0050;
        command_rom[8'h33] = 16'h0060;
        command_rom[8'h34] = 16'h0070;
        command_rom[8'h35] = 16'h0080;
        command_rom[8'h36] = 16'h0090;
        command_rom[8'h37] = 16'h0001;
        command_rom[8'h38] = 16'h0002;
        command_rom[8'h39] = 16'h0003;
        command_rom[8'h3a] = 16'h0004;
        command_rom[8'h41] = 16'h0007;
        command_rom[8'h42] = 16'h0008;
        command_rom[8'h43] = 16'h0100;
        command_rom[8'h44] = 16'h000a;
        command_rom[8'h45] = 16'h0009;
        command_rom[8'h46] = 16'h0a00;
        command_rom[8'h51] = 16'h0500;
        command_rom[8'h52] = 16'h0d00;
        command_rom[8'h53] = 16'h1500;
        command_rom[8'h54] = 16'h1d00;
        command_rom[8'h55] = 16'h0001;
        command_rom[8'h56] = 16'h0002;
        command_rom[8'h61] = 16'h000b;
        command_rom[8'h62] = 16'h0001;
        command_rom[8'h63] = 16'h0002;
        command_rom[8'h64] = 16'h0007;
        command_rom[8'h65] = 16'h0008;
        command_rom[8'h66] = 16'h0009;
        command_rom[8'h71] = 16'h000c;
        command_rom[8'h72] = 16'h0007;
        command_rom[8'h73] = 16'h0008;
        command_rom[8'h74] = 16'h0009;
        command_rom[8'h81] = 16'h0003;
        command_rom[8'h82] = 16'h0004;
        command_rom[8'h83] = 16'h0005;
        command_rom[8'h84] = 16'h0006;
        command_rom[8'h85] = 16'h0001;
        command_rom[8'h86] = 16'h0002;
        command_rom[8'h87] = 16'h000a;
        command_rom[8'h88] = 16'h0009;
        command_rom[8'h91] = 16'h000d;
        command_rom[8'ha1] = 16'h0c00;
        command_rom[8'ha2] = 16'h1400;
        command_rom[8'ha3] = 16'h1c00;
        command_rom[8'ha4] = 16'h0000;
        command_rom[8'ha5] = 16'h0300;
        command_rom[8'hb1] = 16'h00a0;
        command_rom[8'hb2] = 16'h00b0;
        command_rom[8'hb3] = 16'h0001;
        command_rom[8'hb4] = 16'h0002;
        command_rom[8'hb5] = 16'h0005;
        command_rom[8'hb6] = 16'h0006;
    end
    always @(posedge clk)
        command_q <= command_rom[{frame_page[3:0],frame_component[3:0]}];
    wire command_address_valid = !frame_page[4] && !frame_component[4];
    always @* decoded_action = command_address_valid ? command_q[3:0] : A_NONE;

    always @* begin
        key_n = 12'hfff;
        next_n = 1; prev_n = 1; emergency_n = 1;
        // Release is delayed by the minimum hold timer for short taps.
        if (action != A_NONE && action_age < TIMEOUT_MS &&
            (action_down || action_age < HOLD_MS)) begin
            case (action)
                A_CONFIRM: key_n[1]=0; A_CANCEL: key_n[2]=0;
                A_LEFT: key_n[3]=0; A_RIGHT: key_n[4]=0;
                A_UP: key_n[5]=0; A_DOWN: key_n[6]=0;
                A_NEXT: next_n=0;
                A_PREV: begin
                    // Media tracks direction through prev_n; home navigation
                    // consumes the debounced PREV key, just like physical KEY2.
                    prev_n=0; key_n[9]=0;
                end
                A_MENU: key_n[0]=0; A_ROI: key_n[10]=0;
                A_DIRECT: key_n[8]=0; A_PAUSE: key_n[11]=0;
                A_EMERGENCY: emergency_n=0;
            endcase
        end
    end

    // Only a complete 0x65 frame for the FPGA's current UI page is accepted.
    // 0x88, when emitted by the panel startup program, requests a resync.
    always @(posedge clk or posedge rst) begin
        if (rst) begin
            frame_index<=0; frame_page<=0; frame_component<=0; frame_edge<=0;
            touch_x<=0; touch_y<=0; slider_stream_x<=0;
            touch_coordinate_valid<=0;
            touch_coordinate_pressed<=0; slider_dragging<=0;
            slider_valid<=0; slider_percent<=0;
            action<=0; action_down<=0; action_age<=0; hotspot_enable<=0;
            settings_open<=0; adjust_mode<=0;
            menu_command<=0; region_valid<=0; region_index<=0;
            ms_count<=0; sent_page<=4'hf;
            content_page_d<=content_page; screen_page_d<=screen_page;
            sending_page<=0; tx_index<=0; tx_state<=0; tx_data<=0;
            tx_start<=0;
        end else begin
            menu_command<=0; region_valid<=0; slider_valid<=0; tx_start<=0;
            content_page_d<=content_page;
            screen_page_d<=screen_page;
            if (ms_tick) ms_count<=0;
            else ms_count<=ms_count+1'b1;
            if (ms_tick && action!=A_NONE) begin
                if (action_age<TIMEOUT_MS) action_age<=action_age+1'b1;
                else begin action<=A_NONE; action_down<=0; end
                if (!action_down && action_age>=HOLD_MS) action<=A_NONE;
            end
            if (content_page!=content_page_d ||
                (screen_page_d==5 && screen_page==4) ||
                (screen_page_d==6 && screen_page==4) ||
                (screen_page!=4 && screen_page!=5 && screen_page!=6))
                hotspot_enable<=0;
            if (screen_page!=4 && screen_page!=10)
                settings_open<=0;
            if (screen_page!=10 || !settings_open)
                slider_dragging<=0;
            if (rx_valid) begin
                if (frame_index==0) begin
                    if (rx_data==8'h65) frame_index<=1;
                    else if (rx_data==8'h67) frame_index<=7;
                    else if (rx_data==8'h68) frame_index<=15;
                    else if (rx_data==8'h88 && screen_page!=0)
                        sent_page<=4'hf;
                end else case (frame_index)
                    1: begin
                        frame_page<=rx_data<16 ? {1'b0,rx_data[3:0]} : 5'd16;
                        frame_index<=2;
                    end
                    2: begin
                        frame_component<=rx_data<16 ? {1'b0,rx_data[3:0]} : 5'd16;
                        frame_index<=3;
                    end
                    3: begin
                        frame_edge<=rx_data==0 ? 2'd0 : rx_data==1 ? 2'd1 : 2'd2;
                        frame_index<=4;
                    end
                    4: frame_index<=rx_data==8'hff ? 5 : 0;
                    5: frame_index<=rx_data==8'hff ? 6 : 0;
                    6: begin
                        frame_index<=0;
                        if (rx_data==8'hff &&
                            (frame_page=={1'b0,screen_page} ||
                             (frame_edge==0 && action==decoded_action)) &&
                            (frame_edge==0 || frame_edge==1)) begin
                            if (frame_edge==1) begin
                                if (command_address_valid) begin
                                    if (command_q[7:4]!=0)
                                        menu_command<=command_q[7:4];
                                    case (command_q[10:8])
                                        1: hotspot_enable<=~hotspot_enable;
                                        2: begin settings_open<=1; adjust_mode<=1; end
                                        3: begin settings_open<=0; adjust_mode<=0; end
                                        4: adjust_mode<=command_q[12:11];
                                        5: begin region_valid<=1; region_index<=command_q[12:11]; end
                                    endcase
                                    if (frame_page==10 && frame_component==4)
                                        slider_dragging<=1;
                                end
                            end
                            if (frame_edge==0 && frame_page==10 && frame_component==4)
                                slider_dragging<=0;
                            if (decoded_action!=A_NONE) begin
                                if (frame_edge==1 && action==A_NONE) begin
                                    action<=decoded_action; action_down<=1; action_age<=0;
                                end else if (frame_edge==0 && action==decoded_action)
                                    action_down<=0;
                            end
                        end
                    end
                    7: begin touch_x[9:8]<=rx_data[1:0]; frame_index<=8; end
                    8: begin touch_x[7:0]<=rx_data; frame_index<=9; end
                    9: begin touch_y[9:8]<=rx_data[1:0]; frame_index<=10; end
                    10: begin touch_y[7:0]<=rx_data; frame_index<=11; end
                    11: begin
                        touch_coordinate_valid<=rx_data<=1;
                        touch_coordinate_pressed<=rx_data==1;
                        frame_index<=12;
                    end
                    12: frame_index<=rx_data==8'hff ? 13 : 0;
                    13: frame_index<=rx_data==8'hff ? 14 : 0;
                    14: begin
                        frame_index<=0;
                        if (rx_data==8'hff && touch_coordinate_valid &&
                            screen_page==10 && settings_open && adjust_mode!=0) begin
                            if (touch_coordinate_pressed &&
                                touch_y>=10'd155 && touch_y<=10'd220)
                                slider_dragging<=1;
                            if (!touch_coordinate_pressed)
                                slider_dragging<=0;
                            // Release coordinates can be stale or zero on this panel.
                            // Keep the last valid drag sample when the finger lifts.
                            if (touch_coordinate_pressed &&
                                touch_y>=10'd155 && touch_y<=10'd220) begin
                                slider_valid<=1;
                                slider_percent<=touch_x<=10'd40 ? 7'd0 :
                                    touch_x>=10'd440 ? 7'd100 : (touch_x-10'd40)>>2;
                            end
                        end
                    end
                    15: begin slider_stream_x[7:0]<=rx_data; frame_index<=16; end
                    16: begin slider_stream_x[9:8]<=rx_data[1:0]; frame_index<=17; end
                    17: frame_index<=18;
                    18: frame_index<=19;
                    19: frame_index<=rx_data==8'hff ? 20 : 0;
                    20: frame_index<=rx_data==8'hff ? 21 : 0;
                    21: begin
                        frame_index<=0;
                        if (rx_data==8'hff && screen_page==10 &&
                            settings_open && adjust_mode!=0 && slider_dragging) begin
                            slider_valid<=1;
                            slider_percent<=slider_stream_x<=10'd40 ? 7'd0 :
                                slider_stream_x>=10'd440 ? 7'd100 :
                                (slider_stream_x-10'd40)>>2;
                        end
                    end
                endcase
            end
            // The TJC command is "page <digit>" followed by three 0xff bytes.
            if (tx_state==0 && sent_page!=screen_page) begin
                sending_page<=screen_page; tx_index<=0; tx_state<=1;
            end else if (tx_state==1 && !tx_busy) begin
                case (tx_index)
                    0: tx_data<=8'h70; 1: tx_data<=8'h61; 2: tx_data<=8'h67;
                    3: tx_data<=8'h65; 4: tx_data<=8'h20;
                    5: tx_data<=sending_page>=10 ? "1" : 8'h30+{4'd0,sending_page};
                    6: tx_data<=sending_page>=10 ? 8'h30+(sending_page-10) : 8'hff;
                    default: tx_data<=8'hff;
                endcase
                tx_start<=1; tx_state<=2;
            end else if (tx_state==2 && tx_busy) tx_state<=3;
            else if (tx_state==3 && !tx_busy) begin
                if (tx_index==(sending_page>=10 ? 9 : 8)) begin
                    sent_page<=sending_page; tx_state<=0;
                end
                else begin tx_index<=tx_index+1'b1; tx_state<=1; end
            end
        end
    end
endmodule
