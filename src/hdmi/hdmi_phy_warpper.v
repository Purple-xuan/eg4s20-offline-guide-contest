

module hdmi_phy_wrapper#(
    parameter DEVICE = "EG"
    )(
    input wire      I_pixel_clk,
    input wire      I_serial_clk,
    input wire      I_pixel_rst,
    input wire      I_serial_rst,

    input wire[9:0] I_tmds_channel_0,
    input wire[9:0] I_tmds_channel_1,
    input wire[9:0] I_tmds_channel_2,
    input wire[9:0] I_tmds_channel_clk,
    
    output wire     O_tmds_ch0_p,
    output wire     O_tmds_ch1_p,
    output wire     O_tmds_ch2_p,
    output wire     O_tmds_clk_p
);
    
    wire[9:0] S_tmds_data_ch0;
    wire[9:0] S_tmds_data_ch1;
    wire[9:0] S_tmds_data_ch2;
    wire[9:0] S_tmds_data_clk;

    reg S_load_toggle;
    (* async_reg = "true" *) reg S_load_toggle_1d;
    (* async_reg = "true" *) reg S_load_toggle_2d;
    reg S_load_en;
    reg S_serial_started;
    reg [4:0] S_load_phase;
    // Register the predicted next load pulse locally.  Driving the four lanes
    // directly from S_load_phase[4] created a high-fanout 371 MHz path.
    reg S_load_en_serial;
    wire S_load_en_2d = S_serial_started ? S_load_en_serial : S_load_en;

    // All four TMDS lanes must load on the same serial-clock edge. Separate
    // synchronizers can resolve one cycle apart and permanently misalign lanes.
    always @(posedge I_pixel_clk or posedge I_pixel_rst) begin
        if (I_pixel_rst)
            S_load_toggle <= 1'b0;
        else
            S_load_toggle <= ~S_load_toggle;
    end

    always @(posedge I_serial_clk or posedge I_serial_rst) begin
        if (I_serial_rst) begin
            S_load_toggle_1d <= 1'b0;
            S_load_toggle_2d <= 1'b0;
            S_load_en <= 1'b0;
        end else begin
            S_load_toggle_1d <= S_load_toggle;
            S_load_toggle_2d <= S_load_toggle_1d;
            S_load_en <= S_load_toggle_1d ^ S_load_toggle_2d;
        end
    end

    // Pixel and serial clocks come from the same PLL with an exact 1:5 ratio.
    // Use the synchronized toggle only to acquire the initial symbol phase.
    // Thereafter rotate a shared five-cycle strobe: synchronizer resolution
    // must never stretch or shorten an active TMDS symbol. The first load uses
    // S_load_en directly, while the pixel holding registers are stable, rather
    // than delaying it two cycles into the next pixel's data transition.
    always @(posedge I_serial_clk or posedge I_serial_rst) begin
        if (I_serial_rst) begin
            S_serial_started <= 1'b0;
            S_load_phase <= 5'b00000;
            S_load_en_serial <= 1'b0;
        end else if (!S_serial_started) begin
            S_load_en_serial <= 1'b0;
            if (S_load_en) begin
                S_serial_started <= 1'b1;
                S_load_phase <= 5'b00001;
            end
        end else begin
            // phase[3] is high one cycle before the ring reaches phase[4].
            // Registering it here makes the lane input high for the next
            // edge, preserving the original five-cycle cadence.
            S_load_en_serial <= S_load_phase[3];
            S_load_phase <= {S_load_phase[3:0], S_load_phase[4]};
        end
    end

    assign S_tmds_data_ch0 = {I_tmds_channel_0[0],
                              I_tmds_channel_0[1],
                              I_tmds_channel_0[2],
                              I_tmds_channel_0[3],
                              I_tmds_channel_0[4],
                              I_tmds_channel_0[5],
                              I_tmds_channel_0[6],
                              I_tmds_channel_0[7],
                              I_tmds_channel_0[8],
                              I_tmds_channel_0[9]};

    assign S_tmds_data_ch1 = {I_tmds_channel_1[0],
                              I_tmds_channel_1[1],
                              I_tmds_channel_1[2],
                              I_tmds_channel_1[3],
                              I_tmds_channel_1[4],
                              I_tmds_channel_1[5],
                              I_tmds_channel_1[6],
                              I_tmds_channel_1[7],
                              I_tmds_channel_1[8],
                              I_tmds_channel_1[9]};

    assign S_tmds_data_ch2 = {I_tmds_channel_2[0],
                              I_tmds_channel_2[1],
                              I_tmds_channel_2[2],
                              I_tmds_channel_2[3],
                              I_tmds_channel_2[4],
                              I_tmds_channel_2[5],
                              I_tmds_channel_2[6],
                              I_tmds_channel_2[7],
                              I_tmds_channel_2[8],
                              I_tmds_channel_2[9]};

    assign S_tmds_data_clk = {I_tmds_channel_clk[0],
                              I_tmds_channel_clk[1],
                              I_tmds_channel_clk[2],
                              I_tmds_channel_clk[3],
                              I_tmds_channel_clk[4],
                              I_tmds_channel_clk[5],
                              I_tmds_channel_clk[6],
                              I_tmds_channel_clk[7],
                              I_tmds_channel_clk[8],
                              I_tmds_channel_clk[9]};


    lane_lvds_10_1 #(
        .DEVICE ( DEVICE )    
    )u0_lane_lvds_8_1(
        .I_pixel_clk  ( I_pixel_clk     ),
        .I_serial_clk ( I_serial_clk    ),
        .I_pixel_rst  ( I_pixel_rst     ),
        .I_serial_rst ( I_serial_rst    ),

        .I_load_en    ( S_load_en_2d    ),

        .I_data_in    ( S_tmds_data_ch0 ),
        .O_serial_out ( O_tmds_ch0_p    )
    );


    lane_lvds_10_1 #(
        .DEVICE ( DEVICE )    
    )u1_lane_lvds_8_1(
        .I_pixel_clk  ( I_pixel_clk     ),
        .I_serial_clk ( I_serial_clk    ),
        .I_pixel_rst  ( I_pixel_rst     ),
        .I_serial_rst ( I_serial_rst    ),

        .I_load_en    ( S_load_en_2d    ),
        
        .I_data_in    ( S_tmds_data_ch1 ),
        .O_serial_out ( O_tmds_ch1_p    )
    );


    lane_lvds_10_1 #(
        .DEVICE ( DEVICE )    
    )u2_lane_lvds_8_1(
        .I_pixel_clk  ( I_pixel_clk     ),
        .I_serial_clk ( I_serial_clk    ),
        .I_pixel_rst  ( I_pixel_rst     ),
        .I_serial_rst ( I_serial_rst    ),

        .I_load_en    ( S_load_en_2d    ),
        
        .I_data_in    ( S_tmds_data_ch2 ),
        .O_serial_out ( O_tmds_ch2_p    )
    );


    lane_lvds_10_1 #(
        .DEVICE ( DEVICE )    
    )u3_lane_lvds_8_1(
        .I_pixel_clk  ( I_pixel_clk     ),
        .I_serial_clk ( I_serial_clk    ),
        .I_pixel_rst  ( I_pixel_rst     ),
        .I_serial_rst ( I_serial_rst    ),

        .I_load_en    ( S_load_en_2d    ),
        
        .I_data_in    ( S_tmds_data_clk ),
        .O_serial_out ( O_tmds_clk_p    )
    );


endmodule





