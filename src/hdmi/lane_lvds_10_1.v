


module lane_lvds_10_1 #(
    parameter DEVICE = "EG"
    )(
    input wire      I_pixel_clk,
    input wire      I_serial_clk,
    input wire      I_pixel_rst,
    input wire      I_serial_rst,

    input wire      I_load_en,

    input wire[9:0] I_data_in,

    output wire     O_serial_out
);

    reg[9:0] S_data_hold;
    reg[9:0] S_shift_data;   
    reg[1:0] S_oddr_data;    

    // Release reset locally in each lane. The 371 MHz reset previously drove
    // every serializer register through one long recovery path. Preserve the
    // local stages so synthesis cannot merge the four reset trees again.
    (* async_reg = "true", keep = "true" *) reg s1, s2;
    always @(posedge I_serial_clk or posedge I_serial_rst) begin
        if (I_serial_rst) begin
            s1 <= 1'b1;
            s2 <= 1'b1;
        end else begin
            s1 <= 1'b0;
            s2 <= s1;
        end
    end


    always @(posedge I_pixel_clk or posedge I_pixel_rst) begin
        if(I_pixel_rst) begin
            S_data_hold <= 10'd0;
        end else begin
            S_data_hold <= I_data_in;
        end
    end

    always @(posedge I_serial_clk or posedge s2) begin
        if(s2)
            S_shift_data <= 'd0;
        else
            if(I_load_en)
                S_shift_data <= S_data_hold;
            else 
                S_shift_data <= S_shift_data << 2;
    end

    always @(posedge I_serial_clk or posedge s2) begin
        if(s2)
            S_oddr_data <= 2'b00;
        else
            S_oddr_data <= S_shift_data[9:8];
    end

    // The serial data register supplies zero while reset is asserted. Leaving the
    // pad ODDR reset inactive avoids a high-fanout 371.25 MHz recovery path.
    generate
        if(DEVICE == "EF2")
            begin
                EF2_LOGIC_ODDR U_EG4_ODDR(
                    .clk   ( I_serial_clk   ),
                    .rst   ( 1'b0           ),

                    .d1    ( S_oddr_data[0] ),
                    .d0    ( S_oddr_data[1] ),

                    .q     ( O_serial_out   )
                );
            end
        else if(DEVICE == "EF3")
            begin
                EF3_LOGIC_ODDR U_EG4_ODDR(
                    .clk   ( I_serial_clk   ),
                    .rst   ( 1'b0           ),

                    .d1    ( S_oddr_data[0] ),
                    .d0    ( S_oddr_data[1] ),

                    .q     ( O_serial_out   )
                );
            end
        else if(DEVICE == "EF4")
            begin
                EF4_LOGIC_ODDR U_EG4_ODDR(
                    .clk   ( I_serial_clk   ),
                    .rst   ( 1'b0           ),

                    .d1    ( S_oddr_data[0] ),
                    .d0    ( S_oddr_data[1] ),

                    .q     ( O_serial_out   )
                );
            end
        else if(DEVICE == "SF1")
            begin
                SF1_LOGIC_ODDR U_EG4_ODDR(
                    .clk   ( I_serial_clk   ),
                    .rst   ( 1'b0           ),

                    .d1    ( S_oddr_data[0] ),
                    .d0    ( S_oddr_data[1] ),

                    .q     ( O_serial_out   )
                );
            end
        else if(DEVICE == "EG")
            begin
                EG_LOGIC_ODDR U_EG4_ODDR(
                    .clk   ( I_serial_clk   ),
                    .rst   ( 1'b0           ),

                    .d1    ( S_oddr_data[0] ),
                    .d0    ( S_oddr_data[1] ),

                    .q     ( O_serial_out   )
                );
            end
        else if(DEVICE == "PH1A")
            begin
                PH1_LOGIC_ODDR U_EG4_ODDR(
                    .clk   ( I_serial_clk   ),
                    .rst   ( 1'b0           ),

                    .d1    ( S_oddr_data[0] ),
                    .d0    ( S_oddr_data[1] ),

                    .q     ( O_serial_out   )
                );
            end
        else if(DEVICE == "PH1P")
            begin
                PH1P_LOGIC_ODDR U_EG4_ODDR(
                    .clk   ( I_serial_clk   ),
                    .rst   ( 1'b0           ),

                    .d1    ( S_oddr_data[0] ),
                    .d0    ( S_oddr_data[1] ),

                    .q     ( O_serial_out   )
                );
            end
        else if(DEVICE == "DR1")
            begin
                DR1_LOGIC_ODDR U_EG4_ODDR(
                    .clk   ( I_serial_clk   ),
                    .rst   ( 1'b0           ),

                    .d1    ( S_oddr_data[0] ),
                    .d0    ( S_oddr_data[1] ),

                    .q     ( O_serial_out   )
                );
            end
    endgenerate
    
endmodule
