`timescale 1ns/1ps

// The descriptor inputs are stable in the memory clock domain at frame_tick.
// Two groups of source rows allow the next row to be fetched while the other
// group is composed. A completed output row is owned by the pixel clock until
// the last pixel has been consumed.
module resident_display_engine (
    input wire mem_clk, mem_rst_n, pix_clk, pix_rst_n,
    input wire controller_init_done, controller_busy, refresh_active, writer_busy,
    input wire sdram_rd_valid,
    input wire [31:0] sdram_rd_data,
    output wire app_rd_en,
    output wire [20:0] app_rd_addr,
    input wire frame_start,
    output wire mem_frame_tick,
    input wire pixel_de,
    input wire [10:0] pixel_x,
    input wire [9:0] pixel_line_y,
    input wire descriptor_valid,
    input wire [2:0] descriptor_slot,
    input wire descriptor_emergency, descriptor_gallery, descriptor_roi,
    input wire [7:0] descriptor_grid_x,
    input wire [6:0] descriptor_grid_y,
    input wire [3:0] descriptor_units,
    input wire descriptor_reverse, descriptor_instant,
    // 1: welcome contracts to centre; 2: detail contracts to its menu card.
    input wire [1:0] descriptor_return_kind,
    input wire [2:0] descriptor_return_index,
    input wire [7:0] descriptor_ready_mask,
    output wire [23:0] pixel_rgb,
    output wire pixel_valid,
    output reg underflow,
    output wire reader_busy,
    output wire reader_urgent,
    output wire transition_active,
    output wire [2:0] displayed_slot,
    output wire displayed_valid, displayed_emergency, displayed_roi,
    input wire [13:0] overview_read_address,
    output wire [23:0] overview_rgb,
    output wire overview_ready,
    output wire [2:0] overview_slot
);
    // Advance two 16-pixel blocks per frame for a 40-frame page wipe.
    localparam integer WIPE_LAST_STEP = 79;
    reg video_frame_toggle;
    (* async_reg="true" *) reg [2:0] frame_sync;
    wire frame_tick=frame_sync[2]^frame_sync[1];
    reg frame_apply;
    assign mem_frame_tick=frame_tick;
    always @(posedge pix_clk or negedge pix_rst_n)
        if (!pix_rst_n) video_frame_toggle<=0;
        else if (frame_start) video_frame_toggle<=~video_frame_toggle;
    always @(posedge mem_clk or negedge mem_rst_n)
        if (!mem_rst_n) begin frame_sync<=0;frame_apply<=0;end
        else begin
            frame_sync<={frame_sync[1:0],video_frame_toggle};
            frame_apply<=frame_tick;
        end

    reg [2:0] page_slot, previous_slot;
    reg page_valid, emergency, gallery, roi, reverse;
    reg [7:0] grid_x;
    reg [6:0] grid_y;
    reg [3:0] units;
    reg [5:0] roi_fetch_step;
    reg [7:0] ready_mask;
    reg wiping;
    reg [6:0] wipe_step;
    reg [6:0] wipe_boundary_block;
    reg [1:0] return_kind;
    reg [10:0] return_anchor_x;
    reg [9:0] return_anchor_y;
    wire [6:0] return_linear=7'd64-wipe_step;
    wire [6:0] return_level=return_linear<32 ?
        return_linear+(return_linear>>1) : 7'd48+((return_linear-7'd32)>>1);
    reg [10:0] return_radius_x, return_diamond_radius;
    reg [9:0] return_radius_y;
    always @(posedge mem_clk) begin
        // Fit the starting rectangle to its farthest screen edge. Oversized
        // radii made the first half of the old return look like a frozen page.
        // Constant shift/add scales keep this off the pixel selection path.
        return_radius_x<=return_anchor_x==640 ?
            (return_linear<<3)+(return_linear<<1) :
            (return_linear<<4)+(return_linear>>2);
        return_radius_y<=return_anchor_y==515 ?
            (return_linear<<3)+(return_linear>>3) :
            (return_linear<<2)+(return_linear<<1)+(return_linear>>1);
        return_diamond_radius<=return_level<<4;
    end
    reg frame_epoch, frame_live;
    assign transition_active=wiping;
    assign displayed_slot=page_slot;
    assign displayed_valid=page_valid;
    assign displayed_emergency=emergency;
    assign displayed_roi=roi;

    reg [9:0] fetch_y, compose_y;
    reg [9:0] fetch_source_y;
    reg [9:0] gallery_source_y;
    reg [5:0] fetch_remainder;
    reg [1:0] fetch_column, fetch_columns;
    reg [2:0] fetch_slot0, fetch_slot1, fetch_slot2;
    reg [2:0] fetch_present;
    reg [9:0] fetch_row;
    // Keep the SDRAM request row on a dedicated register bank.  fetch_row is
    // also used by the cache compare path; separating the consumers avoids a
    // device-specific packed-resource collision between unrelated row bits.
    (* keep = "true" *) reg [9:0] row_req_y;
    reg [1:0] fetch_state;
    localparam F_IDLE=0, F_REQ=1, F_WAIT=2, F_ADVANCE=3;
    reg [1:0] source_ready;
    reg [1:0] source_half, cached_valid;
    reg [9:0] cached_y0,cached_y1;
    reg fetch_storage_half,compose_storage_half;
    wire fetch_cache_hit=!gallery && cached_valid[fetch_storage_half] &&
        (fetch_storage_half ? cached_y1 : cached_y0)==fetch_row;
    wire fetch_half=fetch_y[0];
    wire [2:0] request_slot=fetch_column==0 ? fetch_slot0 :
                            fetch_column==1 ? fetch_slot1 : fetch_slot2;
    wire request_valid=fetch_state==F_REQ && fetch_present[fetch_column] && !fetch_cache_hit;
    localparam B_IDLE=0,B_REQ=1,B_WAIT=2,B_SAMPLE=3,B_DRAIN=4;
    reg [2:0] background_state,background_slot;
    reg [6:0] background_row;
    reg [7:0] background_x;
    reg [9:0] background_source_x;
    reg [13:0] background_base,background_addr;
    reg background_pipe;
    wire background_request=background_state==B_REQ;
    wire request_ready, row_busy, row_we, row_done, row_cancelled, row_error;
    wire [8:0] row_word;
    wire [31:0] row_data;
    wire [2:0] row_buffer, row_slot;
    wire [9:0] row_y;
    wire [15:0] row_tag;
    wire row_cancel=frame_tick;
    resident_row_reader row_reader (
        .clk(mem_clk),.rst_n(mem_rst_n),
        .controller_init_done(controller_init_done),
        .controller_busy(controller_busy),.refresh_active(refresh_active),
        .writer_busy(writer_busy),.req_valid(request_valid || background_request),.req_ready(request_ready),
        .req_slot(background_request ? background_slot : request_slot),
        .req_buffer(background_request ? 3'd2 :
                    {1'b0,fetch_column}+ (fetch_storage_half ? 3'd3 : 3'd0)),
        .req_y(background_request ? background_row*10'd6 : row_req_y),
        .req_tag({15'd0,frame_epoch}),.cancel(row_cancel),
        .busy(row_busy),.app_rd_en(app_rd_en),.app_rd_addr(app_rd_addr),
        .sdram_rd_valid(sdram_rd_valid),.sdram_rd_data(sdram_rd_data),
        .row_we(row_we),.row_word(row_word),.row_data(row_data),
        .row_buffer(row_buffer),.row_slot(row_slot),.row_y(row_y),.row_tag(row_tag),
        .row_done(row_done),.row_cancelled(row_cancelled),.req_error(row_error)
    );
    assign reader_busy=row_busy;
    assign reader_urgent=frame_live && !source_ready[compose_y[0]] &&
                          fetch_state!=F_IDLE;

    // Gallery uses the original 3x3 layout. Logical slot 6 is intentionally
    // blank; logical slot 7 is packed into physical slot 6.
    function [2:0] gallery_physical;
        input [3:0] logical_slot;
        begin gallery_physical=logical_slot==7 ? 3'd6 : logical_slot[2:0]; end
    endfunction
    wire gallery_image_row=(fetch_y>=32 && fetch_y<212) ||
                           (fetch_y>=264 && fetch_y<444) ||
                           (fetch_y>=496 && fetch_y<676);
    wire [1:0] gallery_tile_row=fetch_y>=496 ? 2 : (fetch_y>=264 ? 1 : 0);
    wire [9:0] gallery_top=gallery_tile_row==2 ? 496 :
                           (gallery_tile_row==1 ? 264 : 32);
    wire [3:0] gallery_first={2'd0,gallery_tile_row}*3;
    wire [2:0] gallery_slot0=gallery_physical(gallery_first);
    wire [2:0] gallery_slot1=gallery_physical(gallery_first+1'b1);
    wire [2:0] gallery_slot2=gallery_physical(gallery_first+2'd2);
    wire [2:0] gallery_present=gallery_image_row ?
        {gallery_first+2'd2<8 && gallery_first+2'd2!=6 && ready_mask[gallery_slot2],
         gallery_first+1'b1<8 && gallery_first+1'b1!=6 && ready_mask[gallery_slot1],
         gallery_first<8 && gallery_first!=6 && ready_mask[gallery_slot0]} : 3'b000;
    wire compose_gallery_image_row=(compose_y>=32 && compose_y<212) ||
                                   (compose_y>=264 && compose_y<444) ||
                                   (compose_y>=496 && compose_y<676);
    wire [3:0] compose_gallery_first=compose_y>=496 ? 4'd6 :
                                      (compose_y>=264 ? 4'd3 : 4'd0);
    wire [2:0] compose_gallery_present=compose_gallery_image_row ?
        {compose_gallery_first+2'd2<8 && compose_gallery_first+2'd2!=6 &&
             ready_mask[gallery_physical(compose_gallery_first+2'd2)],
         compose_gallery_first+1'b1<8 && compose_gallery_first+1'b1!=6 &&
             ready_mask[gallery_physical(compose_gallery_first+1'b1)],
         compose_gallery_first<8 && compose_gallery_first!=6 &&
             ready_mask[gallery_physical(compose_gallery_first)]} : 3'b000;

    reg compose_busy, compose_pipe_valid, compose_pipe_blank;
    reg [10:0] compose_x, compose_pipe_x;
    reg compose_data_valid, compose_data_blank, compose_data_half;
    reg [10:0] compose_data_x;
    reg compose_data_overview_bank;
    reg [13:0] compose_data_overview_addr;
    reg [9:0] compose_source_y;
    reg [2:0] compose_slot0, compose_slot1, compose_slot2;
    reg [2:0] compose_present;
    reg [9:0] compose_ram_x;
    reg [5:0] compose_x_remainder;
    reg [9:0] compose_gallery_top;
    reg [2:0] compose_mode;
    reg compose_half;
    reg compose_overview;
    reg compose_overview_bank;
    reg [13:0] overview_row_base, overview_addr_q;
    reg overview_valid_pipe, overview_bank_pipe;
    reg [13:0] overview_addr_pipe;
    reg [8:0] overview_data_pipe;
    localparam MODE_FULL=0,MODE_WIPE=1,MODE_GALLERY=2,MODE_ROI=3,MODE_BLANK=4;
    wire [1:0] compose_column=compose_x>=880 ? 2 :
                               (compose_x>=480 ? 1 : 0);
    wire [10:0] compose_left=compose_column==2 ? 880 :
                              (compose_column==1 ? 480 : 80);
    wire compose_gallery_hit=compose_x>=compose_left && compose_x<compose_left+320 &&
                             compose_present[compose_column];
    // Wipe boundaries are aligned to 16 pixels. Resolve direction and the
    // 80-block screen complement once per frame, outside the RAM CE path.
    reg [10:0] return_left;
    reg [11:0] return_right;
    reg return_row_outside;
    // While composing a row, prepare the geometry for the row that follows.
    // The frame parameters settle before its first source row becomes ready.
    wire [9:0] return_plan_y=compose_busy ? compose_y+10'd1 : compose_y;
    reg [9:0] return_dy_a;
    reg [10:0] return_halfwidth_b;
    reg return_row_outside_b;
    reg [10:0] return_left_c;
    reg [11:0] return_right_c;
    reg return_row_outside_c;
    always @(posedge mem_clk) begin
        return_dy_a<=return_plan_y>return_anchor_y ?
            return_plan_y-return_anchor_y : return_anchor_y-return_plan_y;
        return_halfwidth_b<=return_kind==1 ?
            (return_diamond_radius>return_dy_a ?
                return_diamond_radius-return_dy_a : 11'd0) : return_radius_x;
        return_row_outside_b<=return_kind==1 ?
            return_dy_a>return_diamond_radius : return_dy_a>return_radius_y;
        return_left_c<=return_anchor_x>return_halfwidth_b ?
            return_anchor_x-return_halfwidth_b : 11'd0;
        return_right_c<={1'b0,return_anchor_x}+{1'b0,return_halfwidth_b};
        return_row_outside_c<=return_row_outside_b;
    end
    // Keep the current pixel's source decision in step with compose_x.
    reg wipe_new_q;
    wire [10:0] compose_x_next=compose_x+11'd1;
    wire wipe_new_next=return_kind!=0 ?
        (return_row_outside || compose_x_next<return_left ||
         {1'b0,compose_x_next}>return_right) :
        ((compose_x_next[10:4]<wipe_boundary_block) ^ reverse);
    wire wipe_new_first=return_kind!=0 ?
        (return_row_outside_c || return_left_c!=11'd0) :
        ((wipe_boundary_block!=7'd0) ^ reverse);
    reg overview_front_bank, overview_back_bank;
    reg [1:0] overview_status_sync1,overview_status_sync2;
    reg overview_front_valid, overview_back_complete;
    reg [2:0] overview_front_slot, overview_back_slot;
    wire [15:0] source_pixel, output_pixel;
    wire [8:0] overview_pixel;
    reg output_data_valid, output_data_half;
    reg [10:0] output_data_x;
    reg [15:0] output_data_pixel;
    wire output_we=output_data_valid;
    wire overview_sample=compose_pipe_valid && compose_overview &&
        compose_pipe_x[2:0]==0 && compose_y[2:0]==0;
    reg overview_sample_q;
    reg background_pipe_q;
    reg [13:0] background_addr_q;
    wire [13:0] overview_write_address=overview_addr_pipe;
    wire [8:0] overview_write_data=overview_data_pipe;
    wire [10:0] output_read_x=pixel_de ? pixel_x+1'b1 : 11'd0;
    wire output_read_buffer=pixel_line_y[0];
    wire [2:0] compose_source_buffer=compose_storage_half ?
        (compose_mode==MODE_GALLERY ? 3'd3+compose_column :
         compose_mode==MODE_WIPE && wipe_new_q ? 3'd4 : 3'd3) :
        (compose_mode==MODE_GALLERY ? {1'b0,compose_column} :
         compose_mode==MODE_WIPE && wipe_new_q ? 3'd1 : 3'd0);
    wire source_background_read=background_state==B_SAMPLE || background_state==B_DRAIN;
    wire [2:0] source_read_buffer=source_background_read ? 3'd2 :
                                    compose_source_buffer;
    resident_line_buffers #(.OUTPUT_WRITE_BOUNDED(1)) buffers (
        .mem_clk(mem_clk),.pix_clk(pix_clk),
        .source_we(row_we),.source_write_buffer(row_buffer),
        .source_write_word(row_word),.source_write_data(row_data),
        .source_read_enable((compose_busy && compose_x<1280) || background_state==B_SAMPLE),
        .source_read_buffer(source_read_buffer),
        .source_read_x(background_state==B_SAMPLE ? background_source_x : compose_ram_x),
        .source_pixel(source_pixel),
        .output_we(output_we),.output_write_buffer(output_data_half),
        .output_write_x(output_data_x),.output_write_data(output_data_pixel),
        .output_read_buffer(output_read_buffer),.output_read_x(output_read_x),
        .output_pixel(output_pixel),
        .overview_we(overview_valid_pipe),.overview_write_buffer(overview_bank_pipe),
        .overview_write_address(overview_write_address),
        .overview_write_data(overview_write_data),
        .overview_read_buffer(overview_status_sync2[0]),
        .overview_read_address(overview_read_address),
        .overview_pixel(overview_pixel)
    );

    reg [1:0] output_ready_toggle, output_consume_sync1, output_consume_sync2;
    reg [9:0] output_y0, output_y1;
    reg output_epoch0, output_epoch1;
    reg [1:0] output_ready_sync1, output_ready_sync2;
    reg [1:0] output_consume_toggle;
    reg pix_epoch, pix_line_accepted;
    (* async_reg="true" *) reg [1:0] expected_sync;
    wire pix_bank=pixel_line_y[0];
    wire pix_row_ready=(output_ready_sync2[pix_bank]!=output_consume_toggle[pix_bank]) &&
        (pix_bank ? output_y1==pixel_line_y : output_y0==pixel_line_y) &&
        (pix_bank ? output_epoch1==pix_epoch : output_epoch0==pix_epoch);
    assign pixel_valid=pixel_de && (pixel_x==0 ? pix_row_ready : pix_line_accepted);
    assign pixel_rgb={output_pixel[15:11],output_pixel[15:13],
                      output_pixel[10:5],output_pixel[10:9],
                      output_pixel[4:0],output_pixel[4:2]};
    always @(posedge pix_clk or negedge pix_rst_n) begin
        if (!pix_rst_n) begin
            output_ready_sync1<=0;output_ready_sync2<=0;
            output_consume_toggle<=0;pix_epoch<=0;
            pix_line_accepted<=0;underflow<=0;expected_sync<=0;
        end else begin
            expected_sync<={expected_sync[0],descriptor_valid};
            output_ready_sync1<=output_ready_toggle;
            output_ready_sync2<=output_ready_sync1;
            if (frame_start) begin
                pix_epoch<=~pix_epoch;
                pix_line_accepted<=0;
                output_consume_toggle<=output_ready_sync2;
            end
            if (pixel_de && pixel_x==0) begin
                pix_line_accepted<=pix_row_ready;
                if (!pix_row_ready && expected_sync[1]) underflow<=1;
            end
            if (pixel_de && pixel_x==1279 && pix_line_accepted)
                output_consume_toggle[pix_bank]<=~output_consume_toggle[pix_bank];
        end
    end
    always @(posedge mem_clk or negedge mem_rst_n) begin
        if (!mem_rst_n) begin
            output_consume_sync1<=0;output_consume_sync2<=0;
        end else begin
            output_consume_sync1<=output_consume_toggle;
            output_consume_sync2<=output_consume_sync1;
        end
    end

    reg [2:0] overview_slot_sync1,overview_slot_sync2;
    assign overview_ready=overview_status_sync2[1];
    assign overview_slot=overview_slot_sync2;
    assign overview_rgb={overview_pixel[8:6],overview_pixel[8:6],overview_pixel[8:7],
                         overview_pixel[5:3],overview_pixel[5:3],overview_pixel[5:4],
                         overview_pixel[2:0],overview_pixel[2:0],overview_pixel[2:1]};
    always @(posedge pix_clk or negedge pix_rst_n) begin
        if (!pix_rst_n) begin
            overview_status_sync1<=0;overview_status_sync2<=0;
            overview_slot_sync1<=0;overview_slot_sync2<=0;
        end else begin
            overview_status_sync1<={overview_front_valid,overview_front_bank};
            overview_status_sync2<=overview_status_sync1;
            overview_slot_sync1<=overview_front_slot;
            overview_slot_sync2<=overview_slot_sync1;
        end
    end

    always @(posedge mem_clk or negedge mem_rst_n) begin
        if (!mem_rst_n) begin
            page_slot<=0;previous_slot<=0;page_valid<=0;
            emergency<=0;gallery<=0;roi<=0;reverse<=0;
            grid_x<=0;grid_y<=0;units<=5;roi_fetch_step<=15;ready_mask<=0;
            wiping<=0;wipe_step<=0;wipe_boundary_block<=0;frame_epoch<=0;frame_live<=0;
            return_kind<=0;return_anchor_x<=640;return_anchor_y<=360;
            return_left<=0;return_right<=1280;return_row_outside<=0;wipe_new_q<=0;
            fetch_y<=0;compose_y<=0;fetch_source_y<=0;
            gallery_source_y<=0;fetch_remainder<=0;
            fetch_column<=0;fetch_columns<=0;
            fetch_slot0<=0;fetch_slot1<=0;fetch_slot2<=0;
            fetch_present<=0;fetch_row<=0;row_req_y<=0;fetch_state<=F_IDLE;
            source_ready<=0;compose_busy<=0;compose_pipe_valid<=0;
            source_half<=0;cached_valid<=0;cached_y0<=0;cached_y1<=0;
            fetch_storage_half<=0;compose_storage_half<=0;
            background_state<=B_IDLE;background_slot<=0;background_row<=0;
            background_x<=0;background_source_x<=0;background_base<=0;
            background_addr<=0;background_pipe<=0;
            compose_pipe_blank<=0;compose_x<=0;compose_pipe_x<=0;
            compose_data_valid<=0;compose_data_blank<=0;compose_data_half<=0;
            compose_data_x<=0;
            compose_data_overview_bank<=0;compose_data_overview_addr<=0;
            overview_sample_q<=0;background_pipe_q<=0;background_addr_q<=0;
            compose_source_y<=0;compose_slot0<=0;compose_slot1<=0;compose_slot2<=0;
            compose_present<=0;compose_ram_x<=0;
            compose_x_remainder<=0;
            compose_gallery_top<=0;compose_mode<=MODE_BLANK;compose_half<=0;
            compose_overview<=0;compose_overview_bank<=0;
            output_data_valid<=0;output_data_half<=0;
            output_data_x<=0;output_data_pixel<=0;
            overview_row_base<=0;overview_addr_q<=0;
            overview_valid_pipe<=0;overview_bank_pipe<=0;
            overview_addr_pipe<=0;overview_data_pipe<=0;
            output_ready_toggle<=0;output_y0<=0;output_y1<=0;
            output_epoch0<=0;output_epoch1<=0;
            overview_front_bank<=0;overview_back_bank<=1;
            overview_front_valid<=0;overview_back_complete<=0;
            overview_front_slot<=0;overview_back_slot<=0;
        end else if (frame_apply) begin
            frame_epoch<=~frame_epoch;
            frame_live<=descriptor_valid;
            page_valid<=descriptor_valid;
            emergency<=descriptor_emergency;
            gallery<=descriptor_gallery;
            roi<=descriptor_roi;
            grid_x<=descriptor_grid_x;grid_y<=descriptor_grid_y;
            units<=descriptor_units;reverse<=descriptor_reverse;
            roi_fetch_step<={2'b0,descriptor_units} + ({2'b0,descriptor_units}<<1);
            ready_mask<=descriptor_ready_mask;
            fetch_y<=0;compose_y<=0;source_ready<=0;
            cached_valid<=0;background_state<=B_IDLE;background_pipe<=0;
            if(descriptor_slot!=background_slot) begin
                background_row<=0;background_base<=0;
                background_slot<=descriptor_slot;
            end
            overview_row_base<=0;
            overview_valid_pipe<=0;
            fetch_state<=F_IDLE;compose_busy<=0;compose_pipe_valid<=0;
            compose_data_valid<=0;overview_sample_q<=0;background_pipe_q<=0;
            output_data_valid<=0;
            fetch_source_y<=descriptor_roi ? descriptor_grid_y*6 : 0;
            gallery_source_y<=0;
            fetch_remainder<=0;
            if (overview_back_complete) begin
                overview_front_bank<=overview_back_bank;
                overview_front_slot<=overview_back_slot;
                overview_front_valid<=1;
                overview_back_bank<=~overview_back_bank;
                overview_back_complete<=0;
            end
            if (descriptor_slot!=page_slot && descriptor_valid) begin
                previous_slot<=page_slot;
                page_slot<=descriptor_slot;
                wiping<=page_valid && (!descriptor_instant || descriptor_return_kind!=0) && !descriptor_emergency &&
                        !descriptor_gallery && !descriptor_roi;
                return_kind<=descriptor_return_kind;
                return_anchor_x<=descriptor_return_kind==1 ? 11'd640 :
                    (descriptor_return_index==0 || descriptor_return_index==3 ? 11'd245 :
                     descriptor_return_index==1 || descriptor_return_index==4 ? 11'd640 : 11'd1035);
                return_anchor_y<=descriptor_return_kind==1 ? 10'd360 :
                    (descriptor_return_index<3 ? 10'd310 : 10'd515);
                wipe_step<=descriptor_return_kind!=0 ? 7'd0 : 7'd1;
                wipe_boundary_block<=descriptor_reverse ? 7'd79 : 7'd1;
            end else if (descriptor_emergency || (descriptor_instant && descriptor_return_kind==0) ||
                         descriptor_gallery || descriptor_roi) begin
                wiping<=0;wipe_step<=0;
                return_kind<=0;
                wipe_boundary_block<=0;
            end else if (wiping && return_kind!=0) begin
                // Welcome closes in 32 frames. Detail advances 1,1,2 steps
                // per three frames: 48 frames versus the 64-frame entry.
                // Reuse the low progress bits instead of another phase counter.
                if(wipe_step<62)
                    wipe_step<=wipe_step+((return_kind==1 || wipe_step[1:0]==2) ? 7'd2 : 7'd1);
                else begin wiping<=0;return_kind<=0;end
            end else if (wiping && wipe_step<WIPE_LAST_STEP) begin
                wipe_step<=wipe_step+7'd2;
                wipe_boundary_block<=descriptor_reverse ? 7'd78-wipe_step : wipe_step+7'd2;
            end
            else if (wiping) wiping<=0;
        end else begin
            compose_data_valid<=compose_pipe_valid;
            if (compose_pipe_valid) begin
                compose_data_half<=compose_half;
                compose_data_x<=compose_pipe_x;
                compose_data_blank<=compose_pipe_blank;
            end
            output_data_valid<=compose_data_valid;
            if (compose_data_valid) begin
                output_data_half<=compose_data_half;
                output_data_x<=compose_data_x;
                output_data_pixel<=compose_data_blank ? 16'd0 : source_pixel;
            end
            overview_sample_q<=overview_sample;
            if (overview_sample) begin
                compose_data_overview_bank<=compose_overview_bank;
                compose_data_overview_addr<=overview_addr_q;
            end
            overview_valid_pipe<=overview_sample_q;
            if (overview_sample_q) begin
                overview_bank_pipe<=compose_data_overview_bank;
                overview_addr_pipe<=compose_data_overview_addr;
                overview_data_pipe<={source_pixel[15:13],source_pixel[10:8],source_pixel[4:2]};
            end
            // Spare source row 2 and the read port are free after active
            // composition. Build missing full-page overviews in vertical
            // blanking, including when the first displayed frame is ROI.
            background_pipe<=background_state==B_SAMPLE;
            background_pipe_q<=background_pipe;
            background_addr_q<=background_addr;
            if(background_pipe_q) begin
                overview_valid_pipe<=1;
                overview_bank_pipe<=overview_back_bank;
                overview_addr_pipe<=background_addr_q;
                overview_data_pipe<={source_pixel[15:13],source_pixel[10:8],source_pixel[4:2]};
            end
            case(background_state)
                B_IDLE: if(frame_live && compose_y==720 && !gallery && !wiping &&
                           !emergency && !overview_back_complete &&
                           (!overview_front_valid || overview_front_slot!=page_slot)) begin
                    background_state<=B_REQ;
                    overview_back_slot<=page_slot;
                end
                B_REQ: if(request_ready) background_state<=B_WAIT;
                B_WAIT: if(row_done) begin
                    background_x<=0;background_source_x<=0;
                    // First B_SAMPLE edge advances to the row base. Address
                    // and RAM data retain the established two-stage pairing.
                    background_addr<=background_base-14'd1;
                    background_state<=B_SAMPLE;
                end else if(row_error || row_cancelled) background_state<=B_IDLE;
                B_SAMPLE: begin
                    background_addr<=background_addr+14'd1;
                    background_x<=background_x+1'b1;
                    background_source_x<=background_source_x+10'd6;
                    if(background_x==159) background_state<=B_DRAIN;
                end
                B_DRAIN: if(!background_pipe && !background_pipe_q &&
                             !overview_valid_pipe) begin
                    if(background_row==89) begin
                        overview_back_complete<=1;
                        background_row<=0;background_base<=0;
                    end else begin
                        background_row<=background_row+1'b1;
                        background_base<=background_base+14'd160;
                    end
                    background_state<=B_IDLE;
                end
                default: background_state<=B_IDLE;
            endcase
            if (frame_live && fetch_y<720 && fetch_state==F_IDLE &&
                !source_ready[fetch_half]) begin
                fetch_slot0<=gallery ? gallery_slot0 : (wiping ? previous_slot : page_slot);
                fetch_slot1<=gallery ? gallery_slot1 : page_slot;
                fetch_slot2<=gallery_slot2;
                fetch_present<=gallery ? gallery_present :
                    (wiping ? 3'b011 : 3'b001);
                fetch_columns<=gallery ? 3 : (wiping ? 2 : 1);
                fetch_row<=gallery ? gallery_source_y : fetch_source_y;
                row_req_y<=gallery ? gallery_source_y : fetch_source_y;
                fetch_storage_half<=gallery ? fetch_half : fetch_source_y[0];
                source_half[fetch_half]<=gallery ? fetch_half : fetch_source_y[0];
                fetch_column<=0;
                fetch_state<=F_REQ;
            end else if (fetch_state==F_REQ) begin
                if (!fetch_present[fetch_column] || fetch_cache_hit) begin
                    if (fetch_column+1'b1==fetch_columns) begin
                        fetch_state<=F_ADVANCE;
                    end else fetch_column<=fetch_column+1'b1;
                end else if (request_ready) fetch_state<=F_WAIT;
            end else if (fetch_state==F_WAIT) begin
                if (row_done || row_error || row_cancelled) begin
                    if (row_error || row_cancelled) frame_live<=0;
                    if (fetch_column+1'b1==fetch_columns) begin
                        if(!gallery && row_done) begin
                            cached_valid[fetch_storage_half]<=1;
                            if(fetch_storage_half) cached_y1<=fetch_row;
                            else cached_y0<=fetch_row;
                        end
                        fetch_state<=F_ADVANCE;
                    end else begin
                        fetch_column<=fetch_column+1'b1;
                        fetch_state<=F_REQ;
                    end
                end
            end else if (fetch_state==F_ADVANCE) begin
                source_ready[fetch_half]<=1;
                fetch_y<=fetch_y+1'b1;
                fetch_state<=F_IDLE;
                if (gallery) begin
                    if (fetch_y==31 || fetch_y==263 || fetch_y==495)
                        gallery_source_y<=0;
                    else if (gallery_image_row)
                        gallery_source_y<=gallery_source_y+10'd3;
                end
                if (roi) begin
                    if (fetch_remainder+roi_fetch_step>=40) begin
                        fetch_source_y<=fetch_source_y+1'b1;
                        fetch_remainder<=fetch_remainder+roi_fetch_step-40;
                    end else fetch_remainder<=fetch_remainder+roi_fetch_step;
                end else if (fetch_remainder+3>=4) begin
                    fetch_source_y<=fetch_source_y+1'b1;
                    fetch_remainder<=fetch_remainder+3-4;
                end else fetch_remainder<=fetch_remainder+3;
            end

            compose_pipe_valid<=compose_busy && compose_x<1280;
            if (!compose_busy && frame_live && compose_y<720 &&
                source_ready[compose_y[0]] &&
                output_ready_toggle[compose_y[0]]==output_consume_sync2[compose_y[0]]) begin
                compose_busy<=1;compose_x<=0;
                wipe_new_q<=wipe_new_first;
                return_left<=return_left_c;
                return_right<=return_right_c;
                return_row_outside<=return_row_outside_c;
                compose_half<=compose_y[0];
                compose_storage_half<=source_half[compose_y[0]];
                compose_mode<=gallery ? MODE_GALLERY :
                    (wiping ? MODE_WIPE : (roi ? MODE_ROI : MODE_FULL));
                compose_ram_x<=gallery ? 0 : (roi ? grid_x*6 : 0);
                compose_x_remainder<=0;
                compose_gallery_top<=compose_y>=496 ? 496 : (compose_y>=264 ? 264 : 32);
                compose_present<=gallery ? compose_gallery_present : 3'b000;
                compose_overview<=!gallery && !roi && !wiping && !emergency &&
                    (!overview_front_valid || overview_front_slot!=page_slot);
                compose_overview_bank<=overview_back_bank;
                overview_back_slot<=page_slot;
            end else if (compose_busy && compose_x<1280) begin
                compose_pipe_x<=compose_x;
                overview_addr_q<=overview_row_base+{7'd0,compose_x[10:3]};
                compose_pipe_blank<=compose_mode==MODE_GALLERY && !compose_gallery_hit;
                compose_x<=compose_x+1'b1;
                wipe_new_q<=wipe_new_next;
                if (compose_mode==MODE_GALLERY) begin
                    if (compose_x==79 || compose_x==479 || compose_x==879)
                        compose_ram_x<=0;
                    else if (compose_gallery_hit)
                        compose_ram_x<=compose_ram_x+10'd3;
                end else if (compose_mode==MODE_ROI) begin
                    if (compose_x_remainder+units*3>=40) begin
                        compose_ram_x<=compose_ram_x+1'b1;
                        compose_x_remainder<=compose_x_remainder+units*3-40;
                    end else compose_x_remainder<=compose_x_remainder+units*3;
                end else if (compose_x_remainder+3>=4) begin
                    compose_ram_x<=compose_ram_x+1'b1;
                    compose_x_remainder<=compose_x_remainder+3-4;
                end else compose_x_remainder<=compose_x_remainder+3;
            end else if (compose_busy && output_data_valid && output_data_x==1279) begin
                compose_busy<=0;
                source_ready[compose_half]<=0;
                if (compose_half) begin output_y1<=compose_y;output_epoch1<=frame_epoch;end
                else begin output_y0<=compose_y;output_epoch0<=frame_epoch;end
                output_ready_toggle[compose_half]<=~output_ready_toggle[compose_half];
                if (compose_y==719 && compose_overview)
                    overview_back_complete<=1;
                if (compose_y[2:0]==7)
                    overview_row_base<=overview_row_base+14'd160;
                compose_y<=compose_y+1'b1;
            end
        end
    end
endmodule
