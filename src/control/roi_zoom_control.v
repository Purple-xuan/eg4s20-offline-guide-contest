`timescale 1ns/1ps

// The supported 16:9 sources divide exactly into a 160 x 90 navigation grid.
// Only the UI uses that grid: every loader request carries original-pixel ROI.
module roi_zoom_control #(
    parameter integer CLK_FREQ_HZ = 100_000_000,
    parameter integer DEBOUNCE_MS = 20,
    parameter integer SETTLE_MS = 40,
    parameter integer PAN_REFRESH_MS = 40,
    parameter integer HOLD_MS = 300,
    parameter integer REPEAT_MS = 60,
    parameter integer PAN_HOLD_MS = 180,
    parameter integer PAN_REPEAT_MS = 40
) (
    input wire clk, rst,
    // bit 0 MODE, 1 CONFIRM, 2 BACK, 3 LEFT, 4 RIGHT, 5 UP, 6 DOWN
    input wire [6:0] keys_n,
    input wire increase_pressed, decrease_pressed,
    input wire available, suspended,
    input wire [2:0] image_index,
    input wire [3:0] source_step,
    input wire load_busy, request_ready,
    output reg [1:0] mode,
    output wire active,
    output wire zoom_requested,
    output reg request_valid,
    output reg [3:0] request_units,
    output reg [7:0] request_grid_x,
    output reg [6:0] request_grid_y,
    output reg [15:0] request_x, request_y, request_width, request_height,
    output reg [7:0] grid_x,
    output reg [6:0] grid_y,
    output reg [3:0] size_units
);
    localparam integer MS_CYCLES = CLK_FREQ_HZ >= 1000 ? CLK_FREQ_HZ / 1000 : 1;
    localparam integer MS_BITS = $clog2(MS_CYCLES + 1);
    // Honor shorter timing overrides while keeping pan timing independent.
    localparam integer PAN_HOLD_EFFECTIVE =
        HOLD_MS < PAN_HOLD_MS ? HOLD_MS : PAN_HOLD_MS;
    localparam integer PAN_REPEAT_EFFECTIVE =
        REPEAT_MS < PAN_REPEAT_MS ? REPEAT_MS : PAN_REPEAT_MS;
    reg [MS_BITS-1:0] ms_count;
    reg ms_tick;
    (* async_reg = "true" *) reg [6:0] key_meta, key_sync;
    reg [6:0] stable_n, press;
    reg [4:0] debounce_count [0:6];
    reg [8:0] hold_count;
    reg [8:0] quiet_count;
    localparam integer REFRESH_BITS = $clog2(PAN_REFRESH_MS + 2);
    reg [REFRESH_BITS-1:0] refresh_count;
    reg [5:0] held_previous;
    reg plus_d, minus_d;
    reg dirty, keys_armed;
    reg [2:0] image_d;
    wire [5:0] held = {decrease_pressed,increase_pressed,~stable_n[6:3]};
    wire direction_held = held == 6'b000001 || held == 6'b000010 ||
                          held == 6'b000100 || held == 6'b001000;
    // Selection editing keeps the original cadence. Only an already zoomed
    // view uses the shorter pan cadence; this leaves MODE/CONFIRM behavior
    // unchanged while making held panning responsive.
    wire pan_held = mode == 3 && direction_held;
    wire repeat_now = ms_tick && hold_count ==
                      (pan_held ? PAN_HOLD_EFFECTIVE : HOLD_MS);
    wire plus_event = keys_armed && ((increase_pressed && !plus_d) ||
                                    (repeat_now && held == 6'b010000));
    wire minus_event = keys_armed && ((decrease_pressed && !minus_d) ||
                                     (repeat_now && held == 6'b100000));
    wire left_event = keys_armed && held == 6'b000001 && (press[3] || repeat_now);
    wire right_event = keys_armed && held == 6'b000010 && (press[4] || repeat_now);
    wire up_event = keys_armed && held == 6'b000100 && (press[5] || repeat_now);
    wire down_event = keys_armed && held == 6'b001000 && (press[6] || repeat_now);
    wire [7:0] grid_width = {size_units,4'b0};
    wire [6:0] grid_height = (size_units << 3) + size_units;
    wire [7:0] max_x = 8'd160 - grid_width;
    wire [6:0] max_y = 7'd90 - grid_height;
    reg [7:0] new_x;
    reg [6:0] new_y;
    reg [3:0] new_size;
    reg [2:0] action;
    wire [3:0] grow_size = size_units + 1'b1;
    wire [7:0] grow_max_x = 8'd160 - {grow_size,4'b0};
    wire [6:0] grow_height = ({3'b0,grow_size} << 3) + grow_size;
    wire [6:0] grow_max_y = 7'd90 - grow_height;
    wire [7:0] grow_x = grid_x >= 8 ? grid_x - 8'd8 : 8'd0;
    wire [6:0] grow_y = grid_y >= 4 ? grid_y - 7'd4 : 7'd0;
    integer i;

    assign active = mode != 0;
    assign zoom_requested = mode == 3;

    always @* begin
        new_x = grid_x;
        new_y = grid_y;
        new_size = size_units;
        case (action)
            1: if (grid_x != 0) new_x = grid_x - 1'b1;
            2: if (grid_x < max_x) new_x = grid_x + 1'b1;
            3: if (grid_y != 0) new_y = grid_y - 1'b1;
            4: if (grid_y < max_y) new_y = grid_y + 1'b1;
            5: if (size_units > 2) begin
                new_size = size_units - 1'b1;
                new_x = grid_x + 8'd8;
                new_y = grid_y + 7'd4;
            end
            6: if (size_units < 10) begin
                new_size = grow_size;
                new_x = grow_x > grow_max_x ? grow_max_x : grow_x;
                new_y = grow_y > grow_max_y ? grow_max_y : grow_y;
            end
            default: begin end
        endcase
    end

    always @(posedge clk or posedge rst) begin
        if (rst) begin
            ms_count <= 0;
            ms_tick <= 0;
            action <= 0;
            key_meta <= 7'h7f;
            key_sync <= 7'h7f;
            stable_n <= 7'h7f;
            press <= 0;
            for (i=0;i<7;i=i+1) debounce_count[i] <= 0;
            mode <= 0;
            grid_x <= 40;
            grid_y <= 22;
            size_units <= 5;
            request_valid <= 0;
            request_units <= 5;
            request_grid_x <= 0;
            request_grid_y <= 0;
            request_x <= 0;
            request_y <= 0;
            request_width <= 0;
            request_height <= 0;
            dirty <= 0;
            keys_armed <= 0;
            hold_count <= 0;
            quiet_count <= 0;
            refresh_count <= 0;
            held_previous <= 0;
            plus_d <= 0;
            minus_d <= 0;
            image_d <= 0;
        end else begin
            key_meta <= keys_n;
            key_sync <= key_meta;
            ms_tick <= ms_count == MS_CYCLES - 1;
            ms_count <= ms_count == MS_CYCLES - 1 ? 0 : ms_count + 1'b1;
            action <= 0;
            if (active && !suspended) begin
                if (plus_event || (mode == 2 && (left_event || down_event))) action <= 5;
                else if (minus_event || (mode == 2 && (right_event || up_event))) action <= 6;
                else if (mode != 2) begin
                    if (left_event) action <= 1;
                    else if (right_event) action <= 2;
                    else if (up_event) action <= 3;
                    else if (down_event) action <= 4;
                end
            end
            press <= 0;
            if (ms_tick) begin
                for (i=0;i<7;i=i+1) begin
                    if (key_sync[i] == stable_n[i]) debounce_count[i] <= 0;
                    else if (debounce_count[i] >= DEBOUNCE_MS-1) begin
                        stable_n[i] <= key_sync[i];
                        press[i] <= !key_sync[i];
                        debounce_count[i] <= 0;
                    end else debounce_count[i] <= debounce_count[i] + 1'b1;
                end
            end
            plus_d <= increase_pressed;
            minus_d <= decrease_pressed;
            image_d <= image_index;
            held_previous <= held;
            if (!active || held == 0 || held != held_previous) hold_count <= 0;
            else if (ms_tick) begin
                if (hold_count == (pan_held ? PAN_HOLD_EFFECTIVE : HOLD_MS))
                    hold_count <= (pan_held ? PAN_HOLD_EFFECTIVE - PAN_REPEAT_EFFECTIVE + 1 :
                                   HOLD_MS - REPEAT_MS + 1);
                else hold_count <= hold_count + 1'b1;
            end
            if (held == 0) keys_armed <= 1;
            if (request_valid && request_ready) request_valid <= 0;
            if (ms_tick && quiet_count < SETTLE_MS) quiet_count <= quiet_count + 1'b1;
            if (held != 0) quiet_count <= 0;
            if (mode != 3) refresh_count <= 0;
            else if (ms_tick && refresh_count < PAN_REFRESH_MS)
                refresh_count <= refresh_count + 1'b1;

            if (active && !suspended && action != 0 &&
                (new_x != grid_x || new_y != grid_y || new_size != size_units)) begin
                grid_x <= new_x;
                grid_y <= new_y;
                size_units <= new_size;
                dirty <= 1;
                quiet_count <= 0;
            end
            // One request may be in flight at a time. While the reader is
            // busy, action updates grid_x/grid_y and leaves dirty asserted;
            // once it becomes free, only the latest position is submitted.
            // This coalesces a held key without queueing stale SD reads.
            if (mode == 3 && dirty && action == 0 && !suspended &&
                ((quiet_count >= SETTLE_MS && held == 0) ||
                 (direction_held && refresh_count >= PAN_REFRESH_MS)) &&
                !request_valid && !load_busy) begin
                request_x <= grid_x * source_step;
                request_y <= grid_y * source_step;
                request_width <= grid_width * source_step;
                request_height <= grid_height * source_step;
                request_units <= size_units;
                request_grid_x <= grid_x;
                request_grid_y <= grid_y;
                request_valid <= 1;
                dirty <= 0;
                refresh_count <= 0;
            end
            if (press[0]) begin
                keys_armed <= 0;
                if (mode == 0 && available && !suspended) begin
                    mode <= 1;
                    grid_x <= 40;
                    grid_y <= 22;
                    size_units <= 5;
                end else if (mode == 1) mode <= 2;
                else if (mode == 2 || mode == 3) begin
                    mode <= 1;
                    request_valid <= 0;
                end
            end
            if (press[1] && (mode == 1 || mode == 2)) begin
                mode <= 3;
                dirty <= 1;
                quiet_count <= SETTLE_MS;
                keys_armed <= 0;
            end
            if (suspended || image_d != image_index || press[2]) begin
                mode <= 0;
                request_valid <= 0;
                dirty <= 0;
                keys_armed <= 0;
            end
        end
    end
endmodule

// Home navigation owns every ordinary key across page changes. Requests use
// the existing media commit path; completion requires the displayed descriptor
// to acknowledge the target after its wipe, rather than just the SD page ID.
module home_menu_control #(
    parameter integer CLK_FREQ_HZ=100_000_000,
    parameter integer DEBOUNCE_MS=20,
    parameter integer MANUAL_IDLE_TIMEOUT_MS=60000,
    parameter integer ENABLE_NAV_EFFECT=0,
    parameter integer ENABLE_INTERACTIVE_ROUTES=0
) (
    input wire clk,rst,
    // MENU, CONFIRM, CANCEL, LEFT, RIGHT, UP, DOWN, NEXT, DIRECT, PREV, ROI, PAUSE.
    input wire [11:0] keys_n,
    input wire available,emergency,adjusting,roi_owns_keys,transition_busy,
    input wire hotspot_enable,
    // Direct touch choices share the FPGA navigation and HDMI OSD state.
    input wire [3:0] touch_menu_command,
    input wire touch_region_valid,
    input wire [1:0] touch_region_index,
    input wire [7:0] resource_mask,
    input wire [7:0] failed_page_mask,
    input wire [2:0] current_page,shown_page,
    input wire shown_valid,shown_emergency,shown_roi,
    input wire select_ready,auto_step,next_event,hotspot_done,hotspot_missing_audio,
    input wire [3:0] nav_ack_epoch,
    input wire nav_complete,nav_failed,
    output reg nav_active,nav_cancel,
    output reg [3:0] nav_epoch,
    output reg [2:0] nav_profile,nav_menu_index,
    output reg [1:0] nav_direction,
    output reg [10:0] nav_anchor_x,
    output reg [9:0] nav_anchor_y,
    output reg [2:0] state,
    output reg [2:0] selected,
    output reg select_valid,
    output reg [2:0] select_page,
    output reg bad_page_notice,
    output wire menu_active,navigation_busy,auto_run,audio_mute,roi_allowed,silent_auto,
    output reg auto_paused,
    // 0=normal, 1=select, 2=detail.
    output reg [1:0] hotspot_mode,
    output reg [2:0] hotspot_page,
    output reg [1:0] hotspot_region,
    output reg hotspot_replay,
    output reg hotspot_target_pending,
    output reg [1:0] route_select,
    output reg [2:0] route_choice,
    output reg [1:0] route_type,
    output reg [1:0] route_interest,
    output reg [2:0] route_station
);
    localparam WELCOME=0,MENU=1,MANUAL=2,AUTO=3,EMERGENCY=4;
    localparam NAV_NONE=0,HOME_MENU=1,MENU_DETAIL=2,DETAIL_MENU=3,DETAIL_HOME=4,MENU_HOME=5;
    localparam integer MS_CYCLES=CLK_FREQ_HZ>=1000 ? CLK_FREQ_HZ/1000 : 1;
    localparam integer MS_BITS=$clog2(MS_CYCLES+1);
    localparam integer DB_BITS=DEBOUNCE_MS>1 ? $clog2(DEBOUNCE_MS+1) : 1;
    localparam integer IDLE_BITS=MANUAL_IDLE_TIMEOUT_MS>1 ? $clog2(MANUAL_IDLE_TIMEOUT_MS+1) : 1;
    reg [MS_BITS-1:0] ms_count;
    wire ms_tick=ms_count==MS_CYCLES-1;
    (* async_reg="true" *) reg [11:0] key_meta,key_sync;
    (* async_reg="true" *) reg hotspot_enable_meta,hotspot_enable_sync;
    reg [11:0] stable_n,press;
    reg hotspot_suppressed;
    reg [DB_BITS-1:0] db [0:11];
    reg armed,inflight;
    reg [IDLE_BITS-1:0] idle_ms;
    reg [2:0] saved_state,saved_page;
    reg saved_pause;
    integer i;
    reg [2:0] next_content,prev_content;
    reg [8:0] hotspot_hold_ms;
    reg [3:0] hotspot_held_d;
    reg skip_pending;
    reg [2:0] skip_target;
    reg [1:0] target_region;
    reg [1:0] route_second;
    reg hotspot_finish_seen;
    wire [3:0] hotspot_held=~stable_n[6:3];
    wire hotspot_repeat=ms_tick && hotspot_hold_ms==9'd300;
    wire hotspot_page_allowed = current_page==3'd2 || current_page==3'd4 || current_page==3'd5;
    wire hotspot_open_allowed = hotspot_page_allowed &&
        state==MANUAL && !navigation_busy &&
        shown_valid && shown_page==current_page && !shown_emergency &&
        !shown_roi && !transition_busy && !adjusting && !roi_owns_keys;
    wire route_waiting = ENABLE_INTERACTIVE_ROUTES && route_type==2 &&
                         route_station==0 && current_page==2;
    wire [2:0] interest_target=route_interest<2 ? 3'd4 : 3'd5;
    wire [2:0] selected_interest_target=hotspot_region<2 ? 3'd4 : 3'd5;
    wire [1:0] first_choice=route_choice<3 ? 2'd0 :
                            route_choice<5 ? 2'd1 : 2'd2;
    wire [1:0] second_choice=route_choice==0 ? 2'd1 :
                             route_choice==1 || route_choice==3 ? 2'd2 : 2'd3;
    wire [2:0] second_page=route_second<2 ? 3'd4 : 3'd5;
    // A five-way priority is confined to the 100 MHz control path.
    function [2:0] following;
        input [2:0] p; input [7:0] mask;
        begin
            if(p<2 && mask[2]) following=2;
            else if(p<3 && mask[3]) following=3;
            else if(p<4 && mask[4]) following=4;
            else if(p<5 && mask[5]) following=5;
            else if(p<7 && mask[7]) following=7;
            else following=1;
        end
    endfunction
    function [2:0] preceding;
        input [2:0] p; input [7:0] mask;
        begin
            if(p>5 && mask[5]) preceding=5;
            else if(p>4 && mask[4]) preceding=4;
            else if(p>3 && mask[3]) preceding=3;
            else if(p>2 && mask[2]) preceding=2;
            else preceding=1;
        end
    endfunction
    wire skipped_next = following(current_page,resource_mask | failed_page_mask)!=next_content;
    wire skipped_prev = preceding(current_page,resource_mask | failed_page_mask)!=prev_content;
    function [2:0] item_page;
        input [2:0] item;
        begin
            case(item)
                0,1:item_page=2; 2:item_page=3;
                3:item_page=4; 4:item_page=5; default:item_page=7;
            endcase
        end
    endfunction
    assign navigation_busy=select_valid || inflight;
    assign menu_active=state==MENU && current_page==1 && !navigation_busy;
    assign auto_run=state==AUTO && (route_type!=2 || route_station==2) &&
                    !auto_paused && !navigation_busy &&
                    !emergency && !roi_owns_keys && hotspot_mode==0;
    assign silent_auto=state==AUTO && route_type==3;
    assign audio_mute=state==MENU || state==EMERGENCY || silent_auto;
    assign roi_allowed=(state==WELCOME || state==MANUAL || state==AUTO) &&
                       !navigation_busy && armed && !emergency && hotspot_mode==0;
    task navigate;
        input [2:0] new_state,page;
        begin
            state<=new_state;select_page<=page;select_valid<=1;
            inflight<=0;armed<=0;idle_ms<=0;auto_paused<=0;
            skip_pending<=0;
            hotspot_mode<=0;hotspot_replay<=0;
            nav_cancel<=ENABLE_NAV_EFFECT && nav_active;
            nav_epoch<=nav_epoch+1'b1;
            nav_active<=ENABLE_NAV_EFFECT && state!=EMERGENCY &&
                ((state==WELCOME && new_state==MENU) ||
                 (state==MENU && (new_state==MANUAL || new_state==AUTO || new_state==WELCOME)) ||
                 ((state==MANUAL || state==AUTO) && (new_state==MENU || new_state==WELCOME)));
            nav_profile<=NAV_NONE;
            nav_direction<=0;
            if(state==WELCOME && new_state==MENU) nav_profile<=HOME_MENU;
            else if(state==MENU && (new_state==MANUAL || new_state==AUTO)) nav_profile<=MENU_DETAIL;
            else if((state==MANUAL || state==AUTO) && new_state==MENU) begin
                nav_profile<=DETAIL_MENU;nav_direction<=1;
            end else if((state==MANUAL || state==AUTO) && new_state==WELCOME) begin
                nav_profile<=DETAIL_HOME;nav_direction<=2;
            end else if(state==MENU && new_state==WELCOME) begin
                nav_profile<=MENU_HOME;nav_direction<=1;
            end
            nav_menu_index<=selected;
            case(selected)
                0,3:nav_anchor_x<=245;
                1,4:nav_anchor_x<=640;
                default:nav_anchor_x<=1035;
            endcase
            nav_anchor_y<=selected<3 ? 310 : 515;
            if(new_state==WELCOME || state==WELCOME) begin
                nav_anchor_x<=640;nav_anchor_y<=360;
            end
        end
    endtask
    always @* begin
        next_content=following(current_page,resource_mask);
        prev_content=preceding(current_page,resource_mask);
    end
    always @(posedge clk or posedge rst) begin
        if(rst) begin
            ms_count<=0;key_meta<=12'hfff;key_sync<=12'hfff;
            hotspot_enable_meta<=0;hotspot_enable_sync<=0;hotspot_suppressed<=0;
            stable_n<=12'hfff;press<=0;armed<=0;
            for(i=0;i<12;i=i+1) db[i]<=0;
            state<=WELCOME;selected<=0;select_page<=0;select_valid<=0;
            bad_page_notice<=0;
            route_select<=0;route_choice<=0;route_type<=0;route_interest<=0;route_station<=0;
            hotspot_target_pending<=0;target_region<=0;route_second<=0;
            hotspot_finish_seen<=0;
            skip_pending<=0;skip_target<=0;
            inflight<=1;idle_ms<=0;auto_paused<=0;
            saved_state<=WELCOME;saved_page<=0;saved_pause<=0;
            hotspot_mode<=0;hotspot_page<=0;hotspot_region<=0;hotspot_replay<=0;
            hotspot_hold_ms<=0;hotspot_held_d<=0;
            nav_active<=0;nav_cancel<=0;nav_epoch<=0;nav_profile<=NAV_NONE;
            nav_menu_index<=0;nav_direction<=0;nav_anchor_x<=640;nav_anchor_y<=360;
        end else begin
            key_meta<=keys_n;key_sync<=key_meta;
            bad_page_notice<=0;
            hotspot_enable_meta<=hotspot_enable;
            hotspot_enable_sync<=hotspot_enable_meta;
            if(!hotspot_enable_sync || hotspot_page!=current_page || state!=MANUAL)
                hotspot_suppressed<=0;
            ms_count<=ms_tick ? 0 : ms_count+1'b1;
            press<=0;
            hotspot_replay<=0;
            if(!hotspot_done && !hotspot_missing_audio)
                hotspot_finish_seen<=0;
            nav_cancel<=0;
            hotspot_held_d<=hotspot_held;
            if(hotspot_mode!=1 || hotspot_held==0 || hotspot_held!=hotspot_held_d)
                hotspot_hold_ms<=0;
            else if(ms_tick)
                hotspot_hold_ms<=hotspot_hold_ms==9'd300 ? 9'd181 :
                                 hotspot_hold_ms+1'b1;
            if(ms_tick) for(i=0;i<12;i=i+1) begin
                if(key_sync[i]==stable_n[i]) db[i]<=0;
                else if(DEBOUNCE_MS<=1 || db[i]>=DEBOUNCE_MS-1) begin
                    stable_n[i]<=key_sync[i];press[i]<=!key_sync[i];db[i]<=0;
                end else db[i]<=db[i]+1'b1;
            end
            if(stable_n==12'hfff && key_sync==12'hfff && press==0) armed<=1;
            if(select_valid && select_ready) begin select_valid<=0;inflight<=1;end
            if(inflight && available && current_page==select_page && shown_valid &&
               shown_page==select_page && !shown_emergency && !shown_roi && !transition_busy &&
               (!nav_active || (nav_ack_epoch==nav_epoch && nav_complete))) begin
                inflight<=0;nav_active<=0;
                if(hotspot_target_pending) begin
                    hotspot_mode<=2;hotspot_page<=select_page;
                    hotspot_region<=target_region;
                    hotspot_target_pending<=0;
                end
            end
            // TF recovery invalidates every queued normal command.
            if(!available && state!=EMERGENCY) begin
                state<=WELCOME;select_valid<=0;select_page<=0;inflight<=1;
                selected<=0;armed<=0;auto_paused<=0;idle_ms<=0;
                hotspot_mode<=0;
                hotspot_target_pending<=0;
                route_select<=0;route_choice<=0;route_type<=0;route_station<=0;route_interest<=0;
                route_second<=0;
                skip_pending<=0;
                nav_active<=0;nav_profile<=NAV_NONE;
                if(nav_active) begin nav_epoch<=nav_epoch+1'b1;nav_cancel<=1;end
            end else if(emergency) begin
                if(state!=EMERGENCY) begin
                    saved_state<=state;saved_page<=navigation_busy ? select_page : current_page;
                    saved_pause<=auto_paused;
                end
                state<=EMERGENCY;select_valid<=0;inflight<=0;armed<=0;idle_ms<=0;
                hotspot_mode<=0;
                nav_active<=0;nav_profile<=NAV_NONE;
                if(nav_active) begin nav_epoch<=nav_epoch+1'b1;nav_cancel<=1;end
            end else if(state==EMERGENCY) begin
                navigate(saved_state,saved_page);auto_paused<=saved_pause;
                if(skip_pending) skip_pending<=1;
            end else if(available) begin
                // A damaged target must not leave the UI stuck on a request.
                if(navigation_busy && !resource_mask[select_page] && !skip_pending) begin
                    if(failed_page_mask[select_page]) bad_page_notice<=1;
                    select_valid<=0;inflight<=0;
                    skip_pending<=1;skip_target<=select_page;
                    select_page<=current_page;
                    state<=route_type!=0 ? AUTO :
                           current_page==0 ? WELCOME : current_page==1 ? MENU : MANUAL;
                    hotspot_mode<=0;
                    hotspot_target_pending<=0;
                    nav_active<=0;nav_profile<=NAV_NONE;
                    if(nav_active) begin nav_epoch<=nav_epoch+1'b1;nav_cancel<=1;end
                end else if(skip_pending && !navigation_busy) begin
                    skip_pending<=0;
                    if(ENABLE_INTERACTIVE_ROUTES && route_type==1) begin
                        if(following(skip_target,resource_mask)!=1)
                            navigate(AUTO,following(skip_target,resource_mask));
                        else begin
                            route_type<=0;route_station<=0;route_interest<=0;
                            if(resource_mask[1]) navigate(MENU,1);
                        end
                    end else if(ENABLE_INTERACTIVE_ROUTES && route_type==2) begin
                        if(route_station==0 && resource_mask[second_page]) begin
                            route_station<=1;target_region<={1'b0,route_second[0]};
                            hotspot_target_pending<=1;navigate(AUTO,second_page);
                        end else if(route_station<2 && resource_mask[7]) begin
                            route_station<=2;navigate(AUTO,7);
                        end else begin
                            route_type<=0;route_station<=0;route_interest<=0;
                            if(resource_mask[1]) navigate(MENU,1);
                        end
                    end
                end
                if(hotspot_mode!=0 && (!hotspot_page_allowed ||
                    hotspot_page!=current_page || roi_owns_keys ||
                    !shown_valid || shown_page!=current_page || shown_emergency ||
                    shown_roi || transition_busy ||
                    (state==MANUAL && hotspot_mode==1 && !hotspot_enable_sync)))
                    hotspot_mode<=0;
                // Allow back to supersede a target that is still loading.
                if(armed && !adjusting && !roi_owns_keys && hotspot_mode!=0 && !navigation_busy &&
                   (state==MANUAL || state==AUTO) &&
                   (press[0] || press[2] || press[10])) begin
                    if(press[0] && resource_mask[1]) begin
                        route_type<=0;route_station<=0;route_interest<=0;
                        navigate(MENU,1);
                    end else if(press[2] && route_type!=0 && resource_mask[1]) begin
                        route_type<=0;route_station<=0;route_interest<=0;
                        navigate(MENU,1);
                    end else if(press[10] || hotspot_mode==1) begin
                        hotspot_mode<=0;
                        hotspot_suppressed<=1;
                    end
                    else hotspot_mode<=1;
                    armed<=0;
                end else if(armed && !adjusting &&
                            ((press[2] && !roi_owns_keys) || press[0]) &&
                            state!=WELCOME) begin
                    if(state==MENU) begin
                        if(route_select!=0) begin route_select<=0;route_choice<=0;armed<=0;end
                        else if(resource_mask[0]) navigate(WELCOME,0);
                    end else if(resource_mask[1]) begin
                        route_type<=0;route_station<=0;route_interest<=0;
                        navigate(MENU,1);
                    end
                end else if(armed && !navigation_busy) begin
                    // ROI's shared keys must not wake MENU.
                    if(state==WELCOME && !adjusting && !roi_owns_keys &&
                       |press[9:0] && stable_n[10] && stable_n[11]) begin
                        if(resource_mask[1]) begin navigate(MENU,1);selected<=0;end
                    end else if(!adjusting && state==MENU) begin
                        if(touch_menu_command==1 && route_select==0) begin
                            selected<=1;
                            if(resource_mask[2]) navigate(MANUAL,3'd2);
                            else if(failed_page_mask[2]) bad_page_notice<=1;
                        end else if(touch_menu_command==2 && route_select==0) begin
                            selected<=0;route_select<=1;route_choice<=0;armed<=0;
                        end else if(route_select==1 && touch_menu_command==12) begin
                            route_choice<=0;
                        end else if(route_select==1 && touch_menu_command==13) begin
                            route_choice<=1;
                        end else if(touch_menu_command>=4 && touch_menu_command<=9 &&
                                    route_select==2) begin
                            route_choice<=touch_menu_command-4'd4;
                        end else if(route_select==1) begin
                            if(|press[6:3]) route_choice<=route_choice==0 ? 3'd1 : 3'd0;
                            else if(press[1]) begin
                                if(route_choice) begin
                                    route_select<=2;route_choice<=0;armed<=0;
                                end else begin route_select<=3;route_choice<=0;armed<=0;end
                            end
                        end else if(route_select==3) begin
                            if(touch_menu_command==10) route_choice<=0;
                            else if(touch_menu_command==11) route_choice<=1;
                            else if(|press[6:3]) route_choice<=route_choice==0 ? 3'd1 : 3'd0;
                            else if(press[1] && following(0,resource_mask)!=1) begin
                                if(following(0,resource_mask | failed_page_mask)!=following(0,resource_mask))
                                    bad_page_notice<=1;
                                route_select<=0;armed<=0;route_station<=0;
                                route_type<=route_choice==0 ? 2'd1 : 2'd3;
                                navigate(AUTO,following(0,resource_mask));
                            end
                        end else if(route_select==2) begin
                            if(press[5] && route_choice!=0) route_choice<=route_choice-1'b1;
                            else if(press[6] && route_choice!=5) route_choice<=route_choice+1'b1;
                            else if(press[1]) begin
                                route_select<=0;armed<=0;
                                route_type<=2;route_station<=0;
                                route_interest<=first_choice;route_second<=second_choice;
                                if(failed_page_mask[first_choice<2 ? 4 : 5]) bad_page_notice<=1;
                                if(!resource_mask[first_choice<2 ? 4 : 5] &&
                                   failed_page_mask[second_choice<2 ? 4 : 5]) bad_page_notice<=1;
                                if(!resource_mask[first_choice<2 ? 4 : 5] &&
                                   !resource_mask[second_choice<2 ? 4 : 5] && failed_page_mask[7])
                                    bad_page_notice<=1;
                                if(resource_mask[first_choice<2 ? 4 : 5]) begin
                                    target_region<={1'b0,first_choice[0]};
                                    hotspot_target_pending<=1;
                                    navigate(AUTO,first_choice<2 ? 3'd4 : 3'd5);
                                end else if(resource_mask[second_choice<2 ? 4 : 5]) begin
                                    route_station<=1;target_region<={1'b0,second_choice[0]};
                                    hotspot_target_pending<=1;
                                    navigate(AUTO,second_choice<2 ? 3'd4 : 3'd5);
                                end else if(resource_mask[7]) begin
                                    route_station<=2;navigate(AUTO,7);
                                end else begin
                                    route_type<=0;
                                end
                            end
                        end else if(press[3] && selected%3!=0) selected<=selected-1'b1;
                        else if(press[4] && selected%3!=2) selected<=selected+1'b1;
                        else if(press[5] && selected>=3) selected<=selected-3;
                        else if(press[6] && selected<3) selected<=selected+3;
                        else if(press[1]) begin
                            if(selected==0 && ENABLE_INTERACTIVE_ROUTES) begin
                                route_select<=1;route_choice<=0;route_interest<=0;armed<=0;
                            end else if(selected==0 && following(0,resource_mask)!=1)
                                navigate(AUTO,following(0,resource_mask));
                            else if(selected!=0 && resource_mask[item_page(selected)])
                                navigate(MANUAL,item_page(selected));
                            else if(selected!=0 && failed_page_mask[item_page(selected)])
                                bad_page_notice<=1;
                        end
                    end else if(!adjusting && !roi_owns_keys && hotspot_mode!=0 &&
                                (state==MANUAL || state==AUTO)) begin
                        if(hotspot_mode==1) begin
                            if(touch_region_valid &&
                               (hotspot_page==2 || touch_region_index<2))
                                hotspot_region<=touch_region_index;
                            else if((press[3] || (hotspot_repeat && hotspot_held==1)) &&
                               hotspot_region!=0) hotspot_region<=hotspot_region-1'b1;
                            else if((press[4] || (hotspot_repeat && hotspot_held==2)) &&
                                    hotspot_region!=(hotspot_page==2 ? 3 : 1))
                                hotspot_region<=hotspot_region+1'b1;
                            else if(hotspot_page==2 &&
                                    (press[5] || (hotspot_repeat && hotspot_held==4)) &&
                                    hotspot_region>=2)
                                hotspot_region<=hotspot_region-2'd2;
                            else if(hotspot_page==2 &&
                                    (press[6] || (hotspot_repeat && hotspot_held==8)) &&
                                    hotspot_region<2)
                                hotspot_region<=hotspot_region+2'd2;
                            else if(press[1]) begin hotspot_mode<=2;armed<=0;end
                        end else if(hotspot_page==2 && press[8] && armed) begin
                            if(resource_mask[selected_interest_target]) begin
                                target_region<={1'b0,hotspot_region[0]};
                                hotspot_target_pending<=1;
                                navigate(state==MANUAL ? MANUAL : AUTO,selected_interest_target);
                            end else if(failed_page_mask[selected_interest_target])
                                bad_page_notice<=1;
                        end else if(press[1]) begin hotspot_replay<=1;armed<=0;end
                        if(state==MANUAL && !roi_owns_keys && next_event && next_content!=1)
                            navigate(MANUAL,next_content);
                        else if(state==MANUAL && !roi_owns_keys && press[9] && resource_mask[prev_content])
                            navigate(prev_content==1 ? MENU : MANUAL,prev_content);
                        else if(state==AUTO && !roi_owns_keys &&
                                next_event && next_content!=1) begin
                            route_type<=0;route_station<=0;
                            navigate(MANUAL,next_content);
                        end else if(state==AUTO && !roi_owns_keys &&
                                    press[9] && resource_mask[prev_content]) begin
                            route_type<=0;route_station<=0;
                            navigate(prev_content==1 ? MENU : MANUAL,prev_content);
                        end else if(state==AUTO && press[11]) auto_paused<=~auto_paused;
                    end else if(!adjusting && hotspot_enable_sync &&
                                !hotspot_suppressed && hotspot_open_allowed) begin
                        hotspot_mode<=1;hotspot_page<=current_page;hotspot_region<=0;armed<=0;
                    end else if(!adjusting && state==MANUAL) begin
                        if(!roi_owns_keys && next_event && next_content!=1)
                            navigate(MANUAL,next_content);
                        else if(!roi_owns_keys && press[9] && resource_mask[prev_content])
                            navigate(prev_content==1 ? MENU : MANUAL,prev_content);
                    end else if(!adjusting && !roi_owns_keys && state==AUTO &&
                                !route_waiting) begin
                        if(next_event && next_content!=1) begin
                            route_type<=0;route_station<=0;
                            navigate(MANUAL,next_content);
                        end else if(press[9] && resource_mask[prev_content]) begin
                            route_type<=0;route_station<=0;
                            navigate(prev_content==1 ? MENU : MANUAL,prev_content);
                        end else if(press[11]) auto_paused<=~auto_paused;
                    end
                end
                if(state==AUTO && route_type==2 && !navigation_busy &&
                   hotspot_mode==2 && (hotspot_done || hotspot_missing_audio) &&
                   !hotspot_finish_seen &&
                   !auto_paused && !roi_owns_keys && !(|press)) begin
                    hotspot_finish_seen<=1;
                    if(route_station==0) begin
                        if(failed_page_mask[second_page] ||
                           (!resource_mask[second_page] && failed_page_mask[7])) bad_page_notice<=1;
                        route_station<=1;
                        if(resource_mask[second_page]) begin
                            if(second_page==current_page) begin
                                hotspot_region<={1'b0,route_second[0]};
                                hotspot_replay<=1;
                            end else begin
                                target_region<={1'b0,route_second[0]};
                                hotspot_target_pending<=1;
                                navigate(AUTO,second_page);
                            end
                        end else if(resource_mask[7]) begin
                            route_station<=2;navigate(AUTO,7);
                        end else if(resource_mask[1]) begin
                            route_type<=0;navigate(MENU,1);
                        end
                    end else if(route_station==1) begin
                        if(failed_page_mask[7]) bad_page_notice<=1;
                        route_station<=2;
                        if(resource_mask[7]) navigate(AUTO,7);
                        else if(resource_mask[1]) begin
                            route_type<=0;navigate(MENU,1);
                        end
                    end
                end
                if(state==AUTO && auto_run && auto_step && !(|press)) begin
                    if(ENABLE_INTERACTIVE_ROUTES && route_type==2) begin
                        if(route_station==2 && resource_mask[1]) begin
                            route_type<=0;route_station<=0;route_interest<=0;navigate(MENU,1);
                        end
                    end else if(next_content==1 && route_type==3) begin
                        if(following(0,resource_mask)!=1)
                            navigate(AUTO,following(0,resource_mask));
                        else begin
                            route_type<=0;route_station<=0;route_interest<=0;
                            if(resource_mask[1]) navigate(MENU,1);
                        end
                    end else if(next_content==1) begin
                        route_type<=0;route_station<=0;route_interest<=0;
                        if(resource_mask[1]) navigate(MENU,1);
                    end else begin
                        if(route_type==1) route_station<=route_station+1'b1;
                        navigate(AUTO,next_content);
                    end
                end
                // Announce skipped files only on a navigation attempt. Missing
                // directory entries are excluded from failed_page_mask.
                if(armed && !navigation_busy && !adjusting && !roi_owns_keys &&
                   !press[0] && !press[2] && (state==MANUAL || state==AUTO) &&
                   !(hotspot_mode==0 && hotspot_enable_sync &&
                     !hotspot_suppressed && hotspot_open_allowed)) begin
                    if(next_event && skipped_next) bad_page_notice<=1;
                    else if(!next_event && press[9] && skipped_prev) bad_page_notice<=1;
                end
                if(state==AUTO && auto_run && auto_step && !(|press) &&
                   route_type!=2 && skipped_next) bad_page_notice<=1;
                if(state==MANUAL) begin
                    if(stable_n!=12'hfff || |press || adjusting) idle_ms<=0;
                    else if(ms_tick && !navigation_busy && !transition_busy) begin
                        if(idle_ms>=MANUAL_IDLE_TIMEOUT_MS-1) begin
                            if(resource_mask[0]) navigate(WELCOME,0);
                        end else idle_ms<=idle_ms+1'b1;
                    end
                end else idle_ms<=0;
                // The video watchdog only counts a missing display commit;
                // READY waiting does not consume the animation budget.
                if(ENABLE_NAV_EFFECT && nav_active && nav_ack_epoch==nav_epoch && nav_failed) begin
                    route_select<=0;route_type<=0;route_station<=0;route_interest<=0;
                    navigate(WELCOME,0);
                    nav_active<=0;nav_profile<=NAV_NONE;
                end
            end
        end
    end
endmodule

// Independent owner of the shared navigation keys while the gallery is open.
module gallery_control #(
    parameter integer CLK_FREQ_HZ = 100_000_000,
    parameter integer DEBOUNCE_MS = 20,
    parameter integer HOLD_MS = 300,
    parameter integer REPEAT_MS = 120
) (
    input wire clk, rst,
    // GALLERY, CONFIRM, BACK, LEFT, RIGHT, UP, DOWN (active low).
    input wire [6:0] keys_n,
    input wire available, suspended,
    input wire [7:0] resource_mask,
    input wire [2:0] current_page,
    input wire select_ready,
    output reg active,
    output reg [2:0] selected,
    output reg select_valid,
    output reg [2:0] select_page
);
    localparam integer MS_CYCLES = CLK_FREQ_HZ >= 1000 ? CLK_FREQ_HZ/1000 : 1;
    localparam integer MS_BITS = $clog2(MS_CYCLES+1);
    reg [MS_BITS-1:0] ms_count;
    (* async_reg="true" *) reg [6:0] key_meta, key_sync;
    reg [6:0] stable_n, press;
    reg [4:0] debounce_count [0:6];
    reg [8:0] hold_count;
    reg [3:0] held_d;
    reg armed;
    wire ms_tick = ms_count == MS_CYCLES-1;
    wire [3:0] held = ~stable_n[6:3];
    wire repeat_now = ms_tick && hold_count == HOLD_MS;
    reg [7:0] resource_mask_q;
    reg [2:0] first_page_q;
    reg search_busy, search_reverse;
    reg [4:0] search_index;
    reg [2:0] search_step;
    integer i;
    reg [2:0] command;

    function [2:0] first_page;
        input [7:0] mask;
        begin
            casez (mask)
                8'b???????1: first_page=0;
                8'b??????10: first_page=1;
                8'b?????100: first_page=2;
                8'b????1000: first_page=3;
                8'b???10000: first_page=4;
                8'b??100000: first_page=5;
                8'b?1000000: first_page=6;
                8'b10000000: first_page=7;
                default: first_page=0;
            endcase
        end
    endfunction

    always @* begin
        command=0;
        if (armed && active && !select_valid && !search_busy) begin
            if (held==1 && (press[3] || repeat_now)) command=1;
            else if (held==2 && (press[4] || repeat_now)) command=2;
            else if (held==4 && (press[5] || repeat_now)) command=3;
            else if (held==8 && (press[6] || repeat_now)) command=4;
        end
    end

    always @(posedge clk or posedge rst) begin
        if (rst) begin
            ms_count<=0;key_meta<=7'h7f;key_sync<=7'h7f;stable_n<=7'h7f;press<=0;
            for(i=0;i<7;i=i+1) debounce_count[i]<=0;
            hold_count<=0;held_d<=0;armed<=0;
            active<=0;selected<=0;select_valid<=0;select_page<=0;
            resource_mask_q<=0;first_page_q<=0;
            search_busy<=0;search_reverse<=0;search_index<=0;search_step<=1;
        end else begin
            resource_mask_q<=resource_mask;
            first_page_q<=first_page(resource_mask);
            key_meta<=keys_n;key_sync<=key_meta;
            ms_count<=ms_tick ? 0 : ms_count+1'b1;
            press<=0;
            if(ms_tick) begin
                for(i=0;i<7;i=i+1) begin
                    if(key_sync[i]==stable_n[i]) debounce_count[i]<=0;
                    else if(debounce_count[i]>=DEBOUNCE_MS-1) begin
                        stable_n[i]<=key_sync[i];press[i]<=!key_sync[i];debounce_count[i]<=0;
                    end else debounce_count[i]<=debounce_count[i]+1'b1;
                end
            end
            held_d<=held;
            if(!active || held==0 || held!=held_d) hold_count<=0;
            else if(ms_tick) hold_count<=hold_count==HOLD_MS ?
                                         HOLD_MS-REPEAT_MS+1 : hold_count+1'b1;
            // Require release of every shared key across mode transitions.
            if(stable_n==7'h7f) armed<=1;
            // Search one file slot per clock instead of a seven-way priority
            // chain. A full sparse-file search takes at most eight clocks.
            if(active && search_busy) begin
                if(search_index>=8) search_busy<=0;
                else if(resource_mask_q[search_index[2:0]]) begin
                    selected<=search_index[2:0];search_busy<=0;
                end else search_index<=search_reverse ?
                    search_index-search_step : search_index+search_step;
            end
            if(active && command!=0) begin
                search_busy<=1;
                search_reverse<=command==1 || command==3;
                search_step<=command>=3 ? 3 : 1;
                search_index<=(command==1 || command==3) ?
                    {2'b0,selected}-(command>=3 ? 5'd3 : 5'd1) :
                    {2'b0,selected}+(command>=3 ? 5'd3 : 5'd1);
            end
            if(press[0]) begin
                armed<=0;search_busy<=0;
                if(active) begin active<=0;select_valid<=0;end
                else if(available && !suspended && resource_mask_q!=0) begin
                    active<=1;selected<=current_page;
                    if(!resource_mask_q[current_page]) selected<=first_page_q;
                end
            end
            if(active && armed && press[1] && !search_busy && resource_mask_q[selected]) begin
                select_page<=selected;select_valid<=1;armed<=0;
            end
            if(select_valid && select_ready) begin
                active<=0;select_valid<=0;armed<=0;search_busy<=0;
            end
            if(suspended || press[2] || (active && resource_mask_q==0)) begin
                active<=0;select_valid<=0;armed<=0;search_busy<=0;
            end
        end
    end
endmodule
