`timescale 1ns/1ps

module fat32_volume_scanner #(
    parameter integer MAX_ROOT_CLUSTERS = 4096
) (
    input  wire        clk,
    input  wire        rst_n,
    input  wire        scan_start,
    output wire        scan_busy,
    output reg         scan_done,
    output reg  [7:0]  fs_error,
    output reg  [31:0] partition_lba,
    output reg  [7:0]  sectors_per_cluster,
    output reg  [31:0] fat_start_lba,
    output reg  [31:0] data_start_lba,
    output reg  [31:0] max_cluster,
    output reg  [7:0]  resource_valid,
    output reg  [31:0] resource0_cluster,
    output reg  [31:0] resource1_cluster,
    output reg  [31:0] resource2_cluster,
    output reg  [31:0] resource3_cluster,
    output reg  [31:0] resource4_cluster,
    output reg  [31:0] resource5_cluster,
    output reg  [31:0] resource6_cluster,
    output reg  [31:0] resource7_cluster,
    output reg  [31:0] resource0_size,
    output reg  [31:0] resource1_size,
    output reg  [31:0] resource2_size,
    output reg  [31:0] resource3_size,
    output reg  [31:0] resource4_size,
    output reg  [31:0] resource5_size,
    output reg  [31:0] resource6_size,
    output reg  [31:0] resource7_size,
    output reg  [7:0]  audio_valid,
    // Index 0..7 selects AUD1..AUD8; 8..15 selects MAP01..HS04.
    input  wire [3:0]  audio_query_index,
    output reg  [31:0] audio_query_cluster,
    output reg  [31:0] audio_query_size,
    output reg  [7:0]  hotspot_audio_valid,
    output reg         emergency_bmp_valid,
    output reg  [31:0] emergency_bmp_cluster,
    output reg  [31:0] emergency_bmp_size,
    output reg         emergency_wav_valid,
    output reg  [31:0] emergency_wav_cluster,
    output reg  [31:0] emergency_wav_size,
    output reg         bgm_valid,
    output reg  [31:0] bgm_cluster,
    output reg  [31:0] bgm_size,
    output reg  [23:0] boot_debug,
    output wire        sector_req,
    output reg  [31:0] sector_lba,
    input  wire        sector_busy,
    input  wire        sector_valid,
    input  wire [7:0]  sector_byte,
    input  wire [8:0]  sector_byte_index,
    input  wire        sector_done,
    input  wire [7:0]  sector_error
);
    localparam ERR_NONE             = 8'h00;
    localparam ERR_SECTOR           = 8'h10;
    localparam ERR_BOOT_SIGNATURE   = 8'h20;
    localparam ERR_UNSUPPORTED_BPB  = 8'h21;
    localparam ERR_RESOURCE_MISSING = 8'h22;
    localparam ERR_ROOT_CHAIN       = 8'h27;

    localparam ST_IDLE          = 4'd0;
    localparam ST_READ0_REQ     = 4'd1;
    localparam ST_READ0_WAIT    = 4'd2;
    localparam ST_BOOT_REQ      = 4'd3;
    localparam ST_BOOT_WAIT     = 4'd4;
    localparam ST_BOOT_PARSE    = 4'd5;
    localparam ST_LAYOUT        = 4'd6;
    localparam ST_ROOT_REQ      = 4'd7;
    localparam ST_ROOT_WAIT     = 4'd8;
    localparam ST_ROOT_FAT_REQ  = 4'd9;
    localparam ST_ROOT_FAT_WAIT = 4'd10;
    localparam ST_ROOT_FAT_PARSE= 4'd11;
    localparam ST_FINISH        = 4'd12;
    localparam ST_ROOT_PREP     = 4'd13;
    localparam ST_READ0_CLASSIFY= 4'd14;
    localparam ST_ROOT_CHECK    = 4'd15;
    localparam ST_ROOT_NEXT_ADDR= 5'd16;
    localparam ST_ROOT_FAT_ADDR = 5'd17;

    localparam integer ROOT_COUNT_WIDTH = $clog2(MAX_ROOT_CLUSTERS + 1);

    (* fsm_encoding="sequential" *) reg [4:0] state;
    reg boot_bpb_valid;
    reg [3:0] boot_partition_valid;
    reg [7:0] sector_buffer [0:511];
    reg [31:0] total_sectors;
    reg [31:0] fat_sectors;
    reg [31:0] fat_span;
    reg [31:0] data_sector_count;
    reg [7:0] fat_count;
    reg [15:0] reserved_sectors;
    reg [31:0] root_cluster;
    reg [31:0] root_cluster_offset;
    reg [2:0] sectors_per_cluster_shift;
    reg [31:0] current_root_cluster;
    reg [7:0] root_sector_index;
    reg [ROOT_COUNT_WIDTH-1:0] root_cluster_count;
    reg root_end_marker;

    reg [7:0] dir_name0, dir_name1, dir_name2, dir_name3;
    reg [7:0] dir_name4, dir_name5, dir_name6, dir_name7;
    reg [7:0] dir_name8, dir_name9, dir_name10;
    reg dir_entry_match;
    reg [2:0] dir_resource_kind;
    reg [2:0] dir_resource_index;
    reg [15:0] dir_cluster_high;
    reg [15:0] dir_cluster_low;
    reg dir_cluster_valid;
    reg [31:0] dir_file_size;
    reg dir_size_low_nonzero;
    reg scan_start_q;
    // File metadata is committed one clock after the final directory byte.
    // This keeps the directory-state decode and the wide resource mux off the
    // same 100 MHz path while preserving the scanner's external results.
    reg dir_commit_pending;
    (* ram_style="bram" *) reg [63:0] audio_metadata [0:15];
    always @(posedge clk) begin
        if (rst_n && dir_commit_pending &&
            (dir_resource_kind == 3'd1 || dir_resource_kind == 3'd5))
            audio_metadata[{dir_resource_kind == 3'd5,dir_resource_index}] <=
                {dir_file_size, dir_cluster_high, dir_cluster_low};
        {audio_query_size, audio_query_cluster} <=
            audio_metadata[audio_query_index];
    end

    reg [8:0] root_fat_offset;
    reg [7:0] root_fat_byte0, root_fat_byte1;
    reg [7:0] root_fat_byte2, root_fat_byte3;
    wire [27:0] parsed_root_fat =
        {root_fat_byte3[3:0], root_fat_byte2,
         root_fat_byte1, root_fat_byte0};

    assign scan_busy = (state != ST_IDLE);
    assign sector_req = state == ST_READ0_REQ || state == ST_BOOT_REQ ||
                        state == ST_ROOT_REQ || state == ST_ROOT_FAT_REQ;

    function [15:0] le16;
        input integer offset;
        begin
            le16 = {sector_buffer[offset+1], sector_buffer[offset]};
        end
    endfunction

    function [31:0] le32;
        input integer offset;
        begin
            le32 = {sector_buffer[offset+3], sector_buffer[offset+2],
                    sector_buffer[offset+1], sector_buffer[offset]};
        end
    endfunction

    function valid_spc;
        input [7:0] value;
        begin
            valid_spc = value != 0 && ((value & (value - 1'b1)) == 0);
        end
    endfunction

    function valid_fat32_partition_type;
        input [7:0] value;
        begin
            valid_fat32_partition_type =
                value == 8'h0b || value == 8'h0c ||
                value == 8'h1b || value == 8'h1c;
        end
    endfunction

    function valid_fat32_bpb;
        input unused;
        begin
            valid_fat32_bpb =
                le16(11) == 16'd512 && valid_spc(sector_buffer[13]) &&
                le16(14) != 0 &&
                (sector_buffer[16] == 1 || sector_buffer[16] == 2) &&
                le16(17) == 0 && le16(22) == 0 &&
                le32(32) != 0 && le32(36) != 0 && le32(44) >= 2;
        end
    endfunction

    function [2:0] spc_shift;
        input [7:0] value;
        begin
            case (value)
                8'd2:   spc_shift = 3'd1;
                8'd4:   spc_shift = 3'd2;
                8'd8:   spc_shift = 3'd3;
                8'd16:  spc_shift = 3'd4;
                8'd32:  spc_shift = 3'd5;
                8'd64:  spc_shift = 3'd6;
                8'd128: spc_shift = 3'd7;
                default: spc_shift = 3'd0;
            endcase
        end
    endfunction

    function [31:0] cluster_lba;
        input [31:0] cluster_number;
        begin
            cluster_lba = data_start_lba
                          + ((cluster_number - 2)
                             << sectors_per_cluster_shift);
        end
    endfunction

    task finish_with_error;
        input [7:0] code;
        begin
            fs_error <= code;
            state <= ST_FINISH;
        end
    endtask

    task finish_directory_scan;
        begin
            if (resource_valid == 8'hff)
                fs_error <= ERR_NONE;
            else
                fs_error <= ERR_RESOURCE_MISSING;
            state <= ST_FINISH;
        end
    endtask

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state <= ST_IDLE;
            boot_bpb_valid <= 0;
            boot_partition_valid <= 0;
            scan_done <= 1'b0;
            fs_error <= ERR_NONE;
            partition_lba <= 32'd0;
            sectors_per_cluster <= 8'd0;
            fat_start_lba <= 32'd0;
            data_start_lba <= 32'd0;
            max_cluster <= 32'd0;
            resource_valid <= 8'd0;
            resource0_cluster <= 32'd0;
            resource1_cluster <= 32'd0;
            resource2_cluster <= 32'd0;
            resource3_cluster <= 32'd0;
            resource4_cluster <= 32'd0;
            resource5_cluster <= 32'd0;
            resource6_cluster <= 32'd0;
            resource7_cluster <= 32'd0;
            resource0_size <= 32'd0;
            resource1_size <= 32'd0;
            resource2_size <= 32'd0;
            resource3_size <= 32'd0;
            resource4_size <= 32'd0;
            resource5_size <= 32'd0;
            resource6_size <= 32'd0;
            resource7_size <= 32'd0;
            audio_valid <= 8'd0;
            hotspot_audio_valid <= 0;
            emergency_bmp_valid <= 1'b0;
            emergency_bmp_cluster <= 32'd0;
            emergency_bmp_size <= 32'd0;
            emergency_wav_valid <= 1'b0;
            emergency_wav_cluster <= 32'd0;
            emergency_wav_size <= 32'd0;
            bgm_valid <= 1'b0;
            bgm_cluster <= 32'd0;
            bgm_size <= 32'd0;
            boot_debug <= 24'd0;
            sector_lba <= 32'd0;
            total_sectors <= 32'd0;
            fat_sectors <= 32'd0;
            fat_span <= 32'd0;
            data_sector_count <= 32'd0;
            fat_count <= 8'd0;
            reserved_sectors <= 16'd0;
            root_cluster <= 32'd0;
            root_cluster_offset <= 32'd0;
            sectors_per_cluster_shift <= 3'd0;
            current_root_cluster <= 32'd0;
            root_sector_index <= 8'd0;
            root_cluster_count <= 0;
            root_end_marker <= 1'b0;
            dir_name0 <= 8'd0;
            dir_name1 <= 8'd0;
            dir_name2 <= 8'd0;
            dir_name3 <= 8'd0;
            dir_name4 <= 8'd0;
            dir_name5 <= 8'd0;
            dir_name6 <= 8'd0;
            dir_name7 <= 8'd0;
            dir_name8 <= 8'd0;
            dir_name9 <= 8'd0;
            dir_name10 <= 8'd0;
            dir_entry_match <= 1'b0;
            dir_resource_kind <= 2'd0;
            dir_resource_index <= 3'd0;
            dir_cluster_high <= 16'd0;
            dir_cluster_low <= 16'd0;
            dir_cluster_valid <= 1'b0;
            dir_file_size <= 32'd0;
            dir_size_low_nonzero <= 1'b0;
            dir_commit_pending <= 1'b0;
            root_fat_offset <= 9'd0;
            root_fat_byte0 <= 8'd0;
            root_fat_byte1 <= 8'd0;
            root_fat_byte2 <= 8'd0;
            root_fat_byte3 <= 8'd0;
            scan_start_q <= 1'b0;
        end else begin
            scan_done <= 1'b0;
            // Register the external scan request before it reaches the
            // scanner state/output muxes. This removes the controller-to-
            // metadata path while adding only one idle-cycle latency.
            scan_start_q <= scan_start;
            dir_commit_pending <= 1'b0;

            // Apply the previous entry's metadata independently of the
            // directory FSM. The extra cycle is hidden while the next sector
            // state is prepared and does not change scan_done contents.
            if (dir_commit_pending) begin
                // The directory fields remain unchanged until the next entry
                // begins, so they double as the one-cycle commit registers.
                case (dir_resource_kind)
                    3'd0: begin
                        case (dir_resource_index)
                            3'd0: begin resource0_cluster <= {dir_cluster_high, dir_cluster_low}; resource0_size <= dir_file_size; resource_valid[0] <= 1'b1; end
                            3'd1: begin resource1_cluster <= {dir_cluster_high, dir_cluster_low}; resource1_size <= dir_file_size; resource_valid[1] <= 1'b1; end
                            3'd2: begin resource2_cluster <= {dir_cluster_high, dir_cluster_low}; resource2_size <= dir_file_size; resource_valid[2] <= 1'b1; end
                            3'd3: begin resource3_cluster <= {dir_cluster_high, dir_cluster_low}; resource3_size <= dir_file_size; resource_valid[3] <= 1'b1; end
                            3'd4: begin resource4_cluster <= {dir_cluster_high, dir_cluster_low}; resource4_size <= dir_file_size; resource_valid[4] <= 1'b1; end
                            3'd5: begin resource5_cluster <= {dir_cluster_high, dir_cluster_low}; resource5_size <= dir_file_size; resource_valid[5] <= 1'b1; end
                            3'd6: begin resource6_cluster <= {dir_cluster_high, dir_cluster_low}; resource6_size <= dir_file_size; resource_valid[6] <= 1'b1; end
                            default: begin resource7_cluster <= {dir_cluster_high, dir_cluster_low}; resource7_size <= dir_file_size; resource_valid[7] <= 1'b1; end
                        endcase
                    end
                    3'd1: begin
                        audio_valid[dir_resource_index] <= 1'b1;
                    end
                    3'd2: begin emergency_bmp_cluster <= {dir_cluster_high, dir_cluster_low}; emergency_bmp_size <= dir_file_size; emergency_bmp_valid <= 1'b1; end
                    3'd3: begin emergency_wav_cluster <= {dir_cluster_high, dir_cluster_low}; emergency_wav_size <= dir_file_size; emergency_wav_valid <= 1'b1; end
                    3'd4: begin bgm_cluster <= {dir_cluster_high, dir_cluster_low}; bgm_size <= dir_file_size; bgm_valid <= 1'b1; end
                    3'd5: begin
                        hotspot_audio_valid[dir_resource_index] <= 1'b1;
                    end
                endcase
            end
            if (sector_valid &&
                (state == ST_READ0_WAIT || state == ST_BOOT_WAIT))
                sector_buffer[sector_byte_index] <= sector_byte;

            if (sector_valid && state == ST_ROOT_WAIT) begin
                case (sector_byte_index[4:0])
                    5'd0: begin
                        dir_name0 <= sector_byte;
                        dir_entry_match <= 1'b0;
                        dir_resource_kind <= 3'd0;
                        dir_cluster_high <= 16'd0;
                        dir_cluster_low <= 16'd0;
                        dir_cluster_valid <= 1'b0;
                        dir_file_size <= 32'd0;
                        dir_size_low_nonzero <= 1'b0;
                        if (sector_byte == 8'h00)
                            root_end_marker <= 1'b1;
                    end
                    5'd1:  dir_name1 <= sector_byte;
                    5'd2:  dir_name2 <= sector_byte;
                    5'd3:  dir_name3 <= sector_byte;
                    5'd4:  dir_name4 <= sector_byte;
                    5'd5:  dir_name5 <= sector_byte;
                    5'd6:  dir_name6 <= sector_byte;
                    5'd7:  dir_name7 <= sector_byte;
                    5'd8:  dir_name8 <= sector_byte;
                    5'd9:  dir_name9 <= sector_byte;
                    5'd10: dir_name10 <= sector_byte;
                    5'd11: begin
                        if (dir_name0 != 8'h00 && dir_name0 != 8'he5 &&
                            (sector_byte & 8'h18) == 0 &&
                            dir_name0 == "P" && dir_name1 == "I" &&
                            dir_name2 == "C" && dir_name3 >= "1" &&
                             dir_name3 <= "8" && dir_name4 == " " &&
                            dir_name5 == " " && dir_name6 == " " &&
                            dir_name7 == " " && dir_name8 == "B" &&
                            dir_name9 == "M" && dir_name10 == "P") begin
                            dir_entry_match <= 1'b1;
                            dir_resource_kind <= 2'd0;
                            dir_resource_index <= dir_name3 - "1";
                        end else if (dir_name0 != 8'h00 && dir_name0 != 8'he5 &&
                            (sector_byte & 8'h18) == 0 &&
                            dir_name0 == "A" && dir_name1 == "U" &&
                            dir_name2 == "D" && dir_name3 >= "1" &&
                            dir_name3 <= "8" && dir_name4 == " " &&
                            dir_name5 == " " && dir_name6 == " " &&
                            dir_name7 == " " && dir_name8 == "W" &&
                            dir_name9 == "A" && dir_name10 == "V") begin
                            dir_entry_match <= 1'b1;
                            dir_resource_kind <= 3'd1;
                            dir_resource_index <= dir_name3 - "1";
                        end else if (dir_name0 != 8'h00 && dir_name0 != 8'he5 &&
                            (sector_byte & 8'h18) == 0 &&
                            dir_name0 == "E" && dir_name1 == "M" &&
                            dir_name2 == "E" && dir_name3 == "R" &&
                            dir_name4 == "G" && dir_name5 == " " &&
                            dir_name6 == " " && dir_name7 == " " &&
                            dir_name8 == "B" && dir_name9 == "M" &&
                            dir_name10 == "P") begin
                            dir_entry_match <= 1'b1;
                            dir_resource_kind <= 2'd2;
                        end else if (dir_name0 != 8'h00 && dir_name0 != 8'he5 &&
                            (sector_byte & 8'h18) == 0 &&
                            dir_name0 == "E" && dir_name1 == "M" &&
                            dir_name2 == "E" && dir_name3 == "R" &&
                            dir_name4 == "G" && dir_name5 == " " &&
                            dir_name6 == " " && dir_name7 == " " &&
                            dir_name8 == "W" && dir_name9 == "A" &&
                            dir_name10 == "V") begin
                            dir_entry_match <= 1'b1;
                            dir_resource_kind <= 2'd3;
                        end else if (dir_name0 == "M" && dir_name1 == "A" &&
                            dir_name2 == "P" && dir_name3 == "0" &&
                            dir_name4 >= "1" && dir_name4 <= "4" &&
                            dir_name5 == " " && dir_name6 == " " && dir_name7 == " " &&
                            dir_name8 == "W" && dir_name9 == "A" && dir_name10 == "V" &&
                            (sector_byte & 8'h18) == 0) begin
                            dir_entry_match <= 1'b1;
                            dir_resource_kind <= 3'd5;
                            dir_resource_index <= dir_name4 - "1";
                        end else if (dir_name0 == "H" && dir_name1 == "S" &&
                            dir_name2 == "0" && dir_name3 >= "1" && dir_name3 <= "4" &&
                            dir_name4 == " " && dir_name5 == " " &&
                            dir_name6 == " " && dir_name7 == " " &&
                            dir_name8 == "W" && dir_name9 == "A" && dir_name10 == "V" &&
                            (sector_byte & 8'h18) == 0) begin
                            dir_entry_match <= 1'b1;
                            dir_resource_kind <= 3'd5;
                            dir_resource_index <= dir_name3 - "1" + 3'd4;
                        end else if (dir_name0 == "B" && dir_name1 == "G" &&
                            dir_name2 == "M" && dir_name3 == " " &&
                            dir_name4 == " " && dir_name5 == " " &&
                            dir_name6 == " " && dir_name7 == " " &&
                            dir_name8 == "W" && dir_name9 == "A" &&
                            dir_name10 == "V" && (sector_byte & 8'h18) == 0) begin
                            dir_entry_match <= 1'b1;
                            dir_resource_kind <= 3'd4;
                        end
                    end
                    5'd20: dir_cluster_high[7:0] <= sector_byte;
                    5'd21: dir_cluster_high[15:8] <= sector_byte;
                    5'd26: dir_cluster_low[7:0] <= sector_byte;
                    5'd27: begin
                        dir_cluster_low[15:8] <= sector_byte;
                        // Unsigned cluster >= 2: compute before the size bytes,
                        // so resource write enables do not contain a carry chain.
                        dir_cluster_valid <= |{dir_cluster_high, sector_byte,
                                               dir_cluster_low[7:1]};
                    end
                    5'd28: dir_file_size[7:0] <= sector_byte;
                    5'd29: dir_file_size[15:8] <= sector_byte;
                    5'd30: begin
                        dir_file_size[23:16] <= sector_byte;
                        dir_size_low_nonzero <= |{sector_byte, dir_file_size[15:0]};
                    end
                    5'd31: begin
                        dir_file_size[31:24] <= sector_byte;
                        if (dir_entry_match && dir_cluster_valid &&
                            (dir_size_low_nonzero || sector_byte != 0)) begin
                            dir_commit_pending <= 1'b1;
                        end
                    end
                    default: begin end
                endcase
            end

            if (sector_valid && state == ST_ROOT_FAT_WAIT) begin
                if (sector_byte_index == root_fat_offset)
                    root_fat_byte0 <= sector_byte;
                else if (sector_byte_index == root_fat_offset + 1'b1)
                    root_fat_byte1 <= sector_byte;
                else if (sector_byte_index == root_fat_offset + 2'd2)
                    root_fat_byte2 <= sector_byte;
                else if (sector_byte_index == root_fat_offset + 2'd3)
                    root_fat_byte3 <= sector_byte;
            end

            case (state)
                ST_IDLE: if (scan_start_q) begin
                    fs_error <= ERR_NONE;
                    partition_lba <= 32'd0;
                    sector_lba <= 32'd0;
                    resource_valid <= 8'd0;
                    resource0_cluster <= 32'd0;
                    resource1_cluster <= 32'd0;
                    resource2_cluster <= 32'd0;
                    resource3_cluster <= 32'd0;
                    resource4_cluster <= 32'd0;
                    resource5_cluster <= 32'd0;
                    resource6_cluster <= 32'd0;
                    resource7_cluster <= 32'd0;
                    resource0_size <= 32'd0;
                    resource1_size <= 32'd0;
                    resource2_size <= 32'd0;
                    resource3_size <= 32'd0;
                    resource4_size <= 32'd0;
                    resource5_size <= 32'd0;
                    resource6_size <= 32'd0;
                    resource7_size <= 32'd0;
                    audio_valid <= 8'd0;
                    hotspot_audio_valid <= 0;
                    emergency_bmp_valid <= 1'b0;
                    emergency_bmp_cluster <= 32'd0;
                    emergency_bmp_size <= 32'd0;
                    emergency_wav_valid <= 1'b0;
                    emergency_wav_cluster <= 32'd0;
                    emergency_wav_size <= 32'd0;
                    bgm_valid <= 1'b0;
                    bgm_cluster <= 32'd0;
                    bgm_size <= 32'd0;
                    root_end_marker <= 1'b0;
                    state <= ST_READ0_REQ;
                end

                ST_READ0_REQ: if (!sector_busy) begin
                    state <= ST_READ0_WAIT;
                end

                ST_READ0_WAIT: if (sector_done) begin
                    boot_debug <= {sector_buffer[0], sector_buffer[510],
                                   sector_buffer[511]};
                    if (sector_error != 0)
                        finish_with_error(ERR_SECTOR);
                    else begin
                        // Separate validation from the four-way LBA priority
                        // mux. No sector request occurs until classification.
                        boot_bpb_valid <= valid_fat32_bpb(1'b0);
                        boot_partition_valid[0] <= valid_fat32_partition_type(sector_buffer[450]) && le32(454) != 0;
                        boot_partition_valid[1] <= valid_fat32_partition_type(sector_buffer[466]) && le32(470) != 0;
                        boot_partition_valid[2] <= valid_fat32_partition_type(sector_buffer[482]) && le32(486) != 0;
                        boot_partition_valid[3] <= valid_fat32_partition_type(sector_buffer[498]) && le32(502) != 0;
                        state <= ST_READ0_CLASSIFY;
                    end
                end

                ST_READ0_CLASSIFY: begin
                    // An MBR can also start with EB/E9 boot code.  Only treat
                    // LBA0 as a superfloppy when its complete FAT32 BPB is valid.
                    if (boot_bpb_valid) begin
                        partition_lba <= 32'd0;
                        state <= ST_BOOT_PARSE;
                    end else if (boot_partition_valid[0]) begin
                        partition_lba <= le32(454);
                        sector_lba <= le32(454);
                        state <= ST_BOOT_REQ;
                    end else if (boot_partition_valid[1]) begin
                        partition_lba <= le32(470);
                        sector_lba <= le32(470);
                        state <= ST_BOOT_REQ;
                    end else if (boot_partition_valid[2]) begin
                        partition_lba <= le32(486);
                        sector_lba <= le32(486);
                        state <= ST_BOOT_REQ;
                    end else if (boot_partition_valid[3]) begin
                        partition_lba <= le32(502);
                        sector_lba <= le32(502);
                        state <= ST_BOOT_REQ;
                    end else if (sector_buffer[510] != 8'h55 ||
                                 sector_buffer[511] != 8'haa) begin
                        finish_with_error(ERR_BOOT_SIGNATURE);
                    end else begin
                        finish_with_error(ERR_UNSUPPORTED_BPB);
                    end
                end

                ST_BOOT_REQ: if (!sector_busy) begin
                    state <= ST_BOOT_WAIT;
                end

                ST_BOOT_WAIT: if (sector_done) begin
                    if (sector_error != 0)
                        finish_with_error(ERR_SECTOR);
                    // Accept a complete, self-consistent BPB when the trailing
                    // signature is unreliable on the current card/read path.
                    else if (valid_fat32_bpb(1'b0))
                        state <= ST_BOOT_PARSE;
                    else if (sector_buffer[510] != 8'h55 ||
                             sector_buffer[511] != 8'haa)
                        finish_with_error(ERR_BOOT_SIGNATURE);
                    else
                        finish_with_error(ERR_UNSUPPORTED_BPB);
                end

                ST_BOOT_PARSE: begin
                    if (!valid_fat32_bpb(1'b0)) begin
                        finish_with_error(ERR_UNSUPPORTED_BPB);
                    end else begin
                        sectors_per_cluster <= sector_buffer[13];
                        sectors_per_cluster_shift <= spc_shift(sector_buffer[13]);
                        reserved_sectors <= le16(14);
                        fat_count <= sector_buffer[16];
                        total_sectors <= le32(32);
                        fat_sectors <= le32(36);
                        fat_span <= (sector_buffer[16] == 2) ?
                                    (le32(36) << 1) : le32(36);
                        root_cluster <= le32(44);
                        fat_start_lba <= partition_lba + le16(14);
                        state <= ST_LAYOUT;
                    end
                end

                ST_LAYOUT: begin
                    data_start_lba <= partition_lba + reserved_sectors
                                      + fat_span;
                    data_sector_count <= total_sectors - reserved_sectors
                                         - fat_span;
                    current_root_cluster <= root_cluster;
                    root_cluster_offset <= (root_cluster - 2)
                                           << sectors_per_cluster_shift;
                    root_sector_index <= 8'd0;
                    root_cluster_count <= 1;
                    state <= ST_ROOT_PREP;
                end

                ST_ROOT_PREP: begin
                    max_cluster <= (data_sector_count
                                    >> sectors_per_cluster_shift) + 1'b1;
                    sector_lba <= data_start_lba + root_cluster_offset;
                    state <= ST_ROOT_REQ;
                end

                ST_ROOT_REQ: if (!sector_busy) begin
                    state <= ST_ROOT_WAIT;
                end

                ST_ROOT_WAIT: if (sector_done) begin
                    if (sector_error != 0) begin
                        finish_with_error(ERR_SECTOR);
                    end else state <= ST_ROOT_CHECK;
                end

                // Commit a last-entry file before checking the discovery mask,
                // including adapters that deliver byte 511 with sector_done.
                ST_ROOT_CHECK: begin
                    if (dir_commit_pending) begin
                        // Byte 511 may arrive with sector_done. Wait until its
                        // registered metadata is visible to completion checks.
                        state <= ST_ROOT_CHECK;
                    end else if (root_end_marker) begin
                        finish_directory_scan;
                    end else if (root_sector_index + 1'b1 < sectors_per_cluster) begin
                        root_sector_index <= root_sector_index + 1'b1;
                        state <= ST_ROOT_NEXT_ADDR;
                    end else begin
                        root_sector_index <= 8'd0;
                        root_fat_offset <= {current_root_cluster[6:0], 2'b00};
                        root_fat_byte0 <= 8'd0;
                        root_fat_byte1 <= 8'd0;
                        root_fat_byte2 <= 8'd0;
                        root_fat_byte3 <= 8'd0;
                        state <= ST_ROOT_FAT_ADDR;
                    end
                end

                ST_ROOT_NEXT_ADDR: begin
                    sector_lba <= sector_lba + 1'b1;
                    state <= ST_ROOT_REQ;
                end

                ST_ROOT_FAT_ADDR: begin
                    sector_lba <= fat_start_lba + (current_root_cluster >> 7);
                    state <= ST_ROOT_FAT_REQ;
                end

                ST_ROOT_FAT_REQ: if (!sector_busy) begin
                    state <= ST_ROOT_FAT_WAIT;
                end

                ST_ROOT_FAT_WAIT: if (sector_done) begin
                    if (sector_error != 0)
                        finish_with_error(ERR_SECTOR);
                    else
                        state <= ST_ROOT_FAT_PARSE;
                end

                ST_ROOT_FAT_PARSE: begin
                    if (parsed_root_fat >= 28'hffffff8) begin
                        finish_directory_scan;
                    end else if ({4'd0, parsed_root_fat} < 2 ||
                                 {4'd0, parsed_root_fat} > max_cluster ||
                                 {4'd0, parsed_root_fat} == current_root_cluster ||
                                 root_cluster_count >= MAX_ROOT_CLUSTERS) begin
                        finish_with_error(ERR_ROOT_CHAIN);
                    end else begin
                        current_root_cluster <= {4'd0, parsed_root_fat};
                        root_cluster_count <= root_cluster_count + 1'b1;
                        root_cluster_offset <= ({4'd0, parsed_root_fat} - 32'd2)
                                               << sectors_per_cluster_shift;
                        state <= ST_ROOT_PREP;
                    end
                end

                ST_FINISH: begin
                    scan_done <= 1'b1;
                    state <= ST_IDLE;
                end

                default: state <= ST_IDLE;
            endcase
        end
    end
endmodule
