`timescale 1ns/1ps
module tb_resident_display_engine;
    reg mem_clk=0,pix_clk=0,rst_n=0;
    always #4 mem_clk=~mem_clk;
    always #6.734 pix_clk=~pix_clk;
    reg frame_start=0,pixel_de=0;
    reg [10:0] pixel_x=0;
    reg [9:0] pixel_line_y=0;
    reg [2:0] slot=0;
    reg gallery=0,roi=0,instant=0,wipe_expected=0,reverse=0;
    reg emergency=0;
    reg [1:0] return_kind=0;
    reg [2:0] return_index=0;
    reg [13:0] overview_address=0;
    integer requests=0,n,corner;
    always @(posedge mem_clk)
        if(dut.request_valid && dut.request_ready) requests=requests+1;
    integer wipe_boundary_expected=0,wipe_previous_slot=0;
    reg return_expected=0;
    integer return_frame=0,return_tick,return_linear_ref,return_level_ref,return_ax_ref,return_ay_ref;
    integer return_dx_ref,return_dy_ref,return_test_kind,return_test_index;
    reg [7:0] grid_x=0;
    reg [6:0] grid_y=0;
    reg [3:0] units=5;
    wire init,busy,refresh,valid,app_rd_en;
    wire [20:0] app_rd_addr;
    wire [31:0] data;
    reg load_valid=0,word_valid=0,stream_done=0;
    reg [31:0] word_data=0;
    wire load_ready,word_ready,writer_busy,writer_en,writer_done;
    wire reader_busy,reader_urgent;
    wire [20:0] writer_addr;
    wire [31:0] writer_data;
    wire [7:0] writer_ready_mask;
    wire [23:0] pixel_rgb;
    wire pixel_valid,underflow,overview_ready;
    wire [2:0] overview_slot;
    wire [23:0] overview_rgb;
    reg passed=0;
    integer checks=0,y,x,sy,sx,s,addr,tile_row,tile_col,logical_slot,top_y,left_x,step;
    reg [15:0] expected565;
    reg [23:0] expected_rgb;
    gallery_sdram_memory memory (
        .clk(mem_clk),.rst(!rst_n),.rd_en(app_rd_en),.rd_addr(app_rd_addr),
        .wr_en(writer_en),.wr_addr(writer_addr),.wr_data(writer_data),
        .init(init),.busy(busy),.refresh(refresh),.valid(valid),.data(data)
    );
    resident_slot_writer #(.ROWS(2)) writer (
        .clk(mem_clk),.rst_n(rst_n),.controller_init_done(init),
        .controller_busy(busy),.refresh_active(refresh),
        .reader_busy(reader_busy),.reader_urgent(reader_urgent),
        .load_valid(load_valid),.load_ready(load_ready),.load_slot(3'd7),
        .load_flip(1'b0),.word_valid(word_valid),.word_ready(word_ready),
        .word_data(word_data),.stream_done(stream_done),.stream_error(1'b0),
        .cancel(1'b0),.load_busy(),.load_done(writer_done),
        .load_failed(),.load_cancelled(),.ready_mask(writer_ready_mask),
        .error_mask(),.all_normal_ready(),.emergency_ready(),
        .write_busy(writer_busy),.app_wr_en(writer_en),
        .app_wr_addr(writer_addr),.app_wr_data(writer_data)
    );
    resident_display_engine dut (
        .mem_clk(mem_clk),.mem_rst_n(rst_n),.pix_clk(pix_clk),.pix_rst_n(rst_n),
        .controller_init_done(init),.controller_busy(busy),.refresh_active(refresh),
        .writer_busy(writer_busy),.sdram_rd_valid(valid),.sdram_rd_data(data),
        .app_rd_en(app_rd_en),.app_rd_addr(app_rd_addr),
        .frame_start(frame_start),.mem_frame_tick(),
        .pixel_de(pixel_de),.pixel_x(pixel_x),
        .pixel_line_y(pixel_line_y),.descriptor_valid(1'b1),
        .descriptor_slot(slot),.descriptor_emergency(emergency),
        .descriptor_gallery(gallery),.descriptor_roi(roi),
        .descriptor_grid_x(grid_x),.descriptor_grid_y(grid_y),
        .descriptor_units(units),.descriptor_reverse(reverse),
        .descriptor_instant(instant),.descriptor_ready_mask(8'hff),
        .descriptor_return_kind(return_kind),.descriptor_return_index(return_index),
        .pixel_rgb(pixel_rgb),.pixel_valid(pixel_valid),.underflow(underflow),
        .reader_busy(reader_busy),.reader_urgent(reader_urgent),.transition_active(),
        .overview_read_address(overview_address),.overview_rgb(overview_rgb),
        .overview_ready(overview_ready),.overview_slot(overview_slot)
    );
    function [23:0] expand;
        input [15:0] p;
        begin expand={p[15:11],p[15:13],p[10:5],p[10:9],p[4:0],p[4:2]}; end
    endfunction
    task begin_frame;
        begin
            @(negedge pix_clk);frame_start=1;pixel_de=0;
            @(negedge pix_clk);frame_start=0;
`ifdef NAV_FAST_MEMORY
            // The ordered-reply Icarus model has no SDRAM startup delay.
            // Keep enough blanking time to fill both output row buffers.
            #50000;
`else
            #400000;
`endif
        end
    endtask
    task scan_line;
        input integer line;
        integer k;
        begin
            @(negedge pix_clk);pixel_line_y=line;pixel_x=0;pixel_de=0;
            for(k=0;k<1280;k=k+1) begin
                @(negedge pix_clk);
                pixel_x=k;pixel_de=1;
                @(posedge pix_clk);
                if (!pixel_valid) $fatal(1,"line underflow y=%0d x=%0d",line,k);
                s=slot;sy=(line*3)/4;sx=(k*3)/4;
                if(gallery) begin
                    expected_rgb=0;
                    tile_row=line>=496 ? 2 : (line>=264 ? 1 : 0);
                    tile_col=k>=880 ? 2 : (k>=480 ? 1 : 0);
                    top_y=32+232*tile_row;
                    left_x=80+400*tile_col;
                    logical_slot=tile_row*3+tile_col;
                    if(line>=top_y && line<top_y+180 &&
                       k>=left_x && k<left_x+320 &&
                       logical_slot<8 && logical_slot!=6) begin
                        s=logical_slot==7 ? 6 : logical_slot;
                        sx=(k-left_x)*3;
                        sy=(line-top_y)*3;
                        addr=s*259200+sy*480+sx/2;
                        expected565=(sx[0] ? 16'h07e0 : 16'hf800) ^ (addr*2+sx[0]);
                        expected_rgb=expand(expected565);
                    end
                end else begin
                    if(wipe_expected)
                        s=(reverse ? k>=1280-wipe_boundary_expected :
                                     k<wipe_boundary_expected) ? slot : wipe_previous_slot;
                    if(return_expected) begin
                        return_linear_ref=64-return_frame;
                        return_level_ref=return_linear_ref<32 ?
                            return_linear_ref*3/2 : 48+(return_linear_ref-32)/2;
                        return_ax_ref=return_kind==1 ? 640 :
                            (return_index%3==0 ? 245 : return_index%3==1 ? 640 : 1035);
                        return_ay_ref=return_kind==1 ? 360 : return_index<3 ? 310 : 515;
                        return_dx_ref=k>return_ax_ref ? k-return_ax_ref : return_ax_ref-k;
                        return_dy_ref=line>return_ay_ref ? line-return_ay_ref : return_ay_ref-line;
                        if(return_kind==1 ? return_dx_ref+return_dy_ref<=return_level_ref*16 :
                           return_dx_ref<=(return_ax_ref==640 ? return_linear_ref*10 :
                               return_linear_ref*16+return_linear_ref/4) &&
                           return_dy_ref<=(return_ay_ref==515 ? return_linear_ref*8+return_linear_ref/8 :
                               return_linear_ref*6+return_linear_ref/2))
                            s=wipe_previous_slot;
                    end
                    if(roi) begin
                        sy=grid_y*6+(line*units*3)/40;
                        sx=grid_x*6+(k*units*3)/40;
                    end
                    addr=s*259200+sy*480+sx/2;
                    expected565=(sx[0] ? 16'h07e0 : 16'hf800) ^ (addr*2+sx[0]);
                    expected_rgb=expand(expected565);
                end
                if (pixel_rgb !== expected_rgb)
                    $fatal(1,"pixel mismatch y=%0d x=%0d got=%h expected=%h",line,k,pixel_rgb,expected_rgb);
                checks=checks+1;
            end
            @(negedge pix_clk);pixel_de=0;
            #4950;
        end
    endtask
    task concurrent_upload;
        integer w;
        begin
            #600000;
            @(negedge mem_clk);
            while(!load_ready) @(negedge mem_clk);
            load_valid=1;
            @(negedge mem_clk);load_valid=0;
            for(w=0;w<960;w=w+1) begin
                word_data=32'h90000000+w;
                word_valid=1;
                while(!word_ready) @(negedge mem_clk);
                @(negedge mem_clk);
            end
            word_valid=0;stream_done=1;
            wait(writer_done);
            @(negedge mem_clk);stream_done=0;
        end
    endtask
    task check_overview;
        input integer page;
        integer a,px,py,wa;
        reg [15:0] p;
        reg [8:0] c;
        reg [23:0] expected;
        begin
            if(!overview_ready || overview_slot!=page)
                $fatal(1,"overview identity expected=%0d got=%0d ready=%b",page,overview_slot,overview_ready);
            for(a=0;a<14400;a=a+1) begin
                px=(a%160)*6;py=(a/160)*6;
                wa=page*259200+py*480+px/2;
                p=16'hf800 ^ (wa*2);
                c={p[15:13],p[10:8],p[4:2]};
                expected={c[8:6],c[8:6],c[8:7],c[5:3],c[5:3],c[5:4],c[2:0],c[2:0],c[2:1]};
                @(negedge pix_clk);overview_address=a;
                @(posedge pix_clk);#1;
                if(overview_rgb!==expected)
                    $fatal(1,"overview pixel slot=%0d addr=%0d got=%h expected=%h",page,a,overview_rgb,expected);
            end
            @(negedge pix_clk);overview_address=0;
            repeat(2) @(negedge pix_clk);
        end
    endtask
`ifdef NAV_RETURN_ONLY
    initial begin
        #100;rst_n=1;wait(init);instant=1;
        for(return_test_kind=1;return_test_kind<=2;return_test_kind=return_test_kind+1) begin
            for(return_test_index=0;return_test_index<(return_test_kind==1?1:6);return_test_index=return_test_index+1) begin
                return_kind=0;return_expected=0;slot=return_test_kind==1?0:2;
                begin_frame();scan_line(0);
                wipe_previous_slot=slot;slot=1;
                return_kind=return_test_kind;return_index=return_test_index;return_expected=1;
                for(return_tick=0;return_tick<(return_kind==1?32:48);return_tick=return_tick+1) begin
                    return_frame=return_kind==1 ? return_tick*2 : return_tick*4/3;
                    begin_frame();
                    if(!dut.transition_active || dut.wipe_step!=return_frame)
                        $fatal(1,"return duration kind=%0d frame=%0d",return_kind,return_frame);
                    // Every menu card must expose an edge on the second
                    // frame, rather than spending half the return off-screen.
                    if(return_kind==2 && return_frame==1 &&
                       dut.return_radius_x>=(return_index%3==1 ? 640 : 1035))
                        $fatal(1,"return has an invisible initial interval card=%0d",return_index);
                    if(return_frame==0 || return_frame==1 || return_frame==24 || return_frame==62)
                        for(y=0;y<12;y=y+1) scan_line(y);
                    // Exercise each anchor and its vertical boundary at mid-return.
                    if(return_frame==48)
                        for(y=0;y<(return_kind==1?362:return_index<3?312:517);y=y+1) scan_line(y);
                end
                return_expected=0;begin_frame();scan_line(0);
                if(dut.transition_active) $fatal(1,"return did not finish kind=%0d",return_kind);
                $display("RETURN_PAIR_PASS kind=%0d card=%0d",return_kind,return_index);
            end
        end
        return_kind=0;slot=0;begin_frame();scan_line(0);
        return_kind=1;slot=1;return_expected=1;wipe_previous_slot=0;return_frame=0;
        begin_frame();scan_line(0);
        emergency=1;slot=7;return_expected=0;
        begin_frame();scan_line(0);
        if(dut.transition_active) $fatal(1,"emergency did not cancel return");
        emergency=0;return_kind=0;slot=2;begin_frame();scan_line(0);
        return_kind=2;slot=1;return_expected=1;wipe_previous_slot=2;return_frame=0;
        begin_frame();scan_line(0);
        return_kind=0;return_expected=0;
        begin_frame();scan_line(0);
        if(dut.transition_active || underflow) $fatal(1,"return cancel/underflow");
        passed=1;$display("RESIDENT_RETURN_PASS checks=%0d",checks);$finish;
    end
`else
    initial begin
        #80;rst_n=1;
        wait(init);
        begin_frame();
        fork
            begin for(y=0;y<720;y=y+1) scan_line(y); end
            concurrent_upload();
        join
        if(requests!=540) $fatal(1,"full frame did not reuse rows: %0d",requests);
        if(!writer_ready_mask[7] || memory.physical_writes<960)
            $fatal(1,"concurrent upload did not complete");
        slot=1;wipe_expected=1;wipe_previous_slot=0;wipe_boundary_expected=16;
        begin_frame();
        if(!overview_ready || overview_slot!=0 || overview_rgb!==24'hff0000)
            $fatal(1,"full overview did not commit atomically");
        check_overview(0);
        scan_line(0);
        for(step=3;step<=79;step=step+2) begin
            wipe_boundary_expected=step*16;
            begin_frame();
            if(!dut.transition_active) $fatal(1,"forward wipe ended at step %0d",step);
            scan_line(0);
        end
        wipe_expected=0;
        begin_frame();
        if(dut.transition_active) $fatal(1,"forward wipe exceeded 40 frames");
        scan_line(0);
        slot=0;reverse=1;wipe_expected=1;wipe_previous_slot=1;
        for(step=1;step<=79;step=step+2) begin
            wipe_boundary_expected=step*16;
            begin_frame();
            if(!dut.transition_active) $fatal(1,"reverse wipe ended at step %0d",step);
            scan_line(0);
        end
        wipe_expected=0;
        begin_frame();
        if(dut.transition_active) $fatal(1,"reverse wipe exceeded 40 frames");
`ifdef NORMAL_WIPE_ONLY
        if(underflow) $fatal(1,"ordinary wipe underflow");
        passed=1;$display("RESIDENT_NORMAL_WIPE_PASS checks=%0d",checks);$finish;
`endif
        reverse=0;
        for(y=0;y<720;y=y+1) scan_line(y);
        // The frame descriptor may change direction during an active wipe.
        // Check that the registered boundary uses the new descriptor, not
        // the previous frame's reverse value.
        slot=1;wipe_expected=1;wipe_previous_slot=0;
        for(step=1;step<=5;step=step+2) begin
            reverse=(step==3);
            wipe_boundary_expected=step*16;
            begin_frame();
            scan_line(0);
        end
        wipe_expected=0;slot=0;instant=1;
        begin_frame();
        scan_line(0);
        slot=1;instant=1;
        begin_frame();
        for(y=0;y<720;y=y+1) scan_line(y);
        begin_frame();
        if(!overview_ready || overview_slot!=1)
            $fatal(1,"overview page change did not commit");
        check_overview(1);
        scan_line(0);
        wipe_expected=0;slot=7;instant=1;
        begin_frame();
        for(y=0;y<12;y=y+1) scan_line(y);
        // Every ROI size and all four legal corners, including bottom/right
        // source boundaries. Page 2 has never built a full-screen overview.
        slot=2;
        for(n=2;n<=10;n=n+1) begin
            units=n;
            for(corner=0;corner<4;corner=corner+1) begin
                grid_x=corner[0] ? 160-16*n : 0;
                grid_y=corner[1] ? 90-9*n : 0;
                begin_frame();
                for(y=0;y<720;y=y+1) scan_line(y);
                if(n==2 && corner==0) begin
                    #1200000;
                    begin_frame();
                    check_overview(2);
                    for(y=0;y<720;y=y+1) scan_line(y);
                end
            end
        end
        // Emergency cancels each display mode at the next frame boundary.
        roi=0;instant=0;slot=3;
        wipe_expected=1;wipe_previous_slot=2;wipe_boundary_expected=16;
        begin_frame();scan_line(0);
        if(!dut.transition_active) $fatal(1,"preemption setup has no wipe");
        emergency=1;slot=7;
        wipe_expected=0;
        begin_frame();scan_line(0);
        if(dut.transition_active) $fatal(1,"emergency waited for wipe");
        emergency=0;roi=1;slot=2;units=5;grid_x=10;grid_y=10;
        begin_frame();scan_line(0);
        emergency=1;roi=0;slot=7;
        begin_frame();scan_line(0);
        emergency=0;gallery=1;
        begin_frame();scan_line(0);
        emergency=1;gallery=0;slot=7;
        begin_frame();scan_line(0);
        gallery=1;instant=1;
        begin_frame();
        for(y=0;y<720;y=y+1) scan_line(y);
        gallery=0;roi=1;slot=0;grid_x=20;grid_y=10;units=5;
        begin_frame();
        for(y=0;y<12;y=y+1) scan_line(y);
        if (underflow) $fatal(1,"underflow flag set");
        passed=1;
        $display("RESIDENT_DISPLAY_PASS checks=%0d",checks);
        $finish;
    end
`endif
    initial begin #2000000000;$fatal(1,"display timeout");end
endmodule
