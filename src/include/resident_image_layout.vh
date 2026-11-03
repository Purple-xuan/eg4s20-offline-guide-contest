// Include inside a module: shared 32-bit WORD addresses, never byte addresses.
// No include guard: Verilog functions must be declared in each module scope.
localparam integer RESIDENT_WIDTH = 960;
localparam integer RESIDENT_HEIGHT = 540;
localparam integer RESIDENT_ROW_WORDS = 480;
localparam integer RESIDENT_SLOT_WORDS = 259200;
localparam [21:0] RESIDENT_END = 22'h1fa400; // exclusive; tail stays unallocated

function [20:0] resident_slot_base;
    input [2:0] slot;
    begin
        case (slot)
            0: resident_slot_base = 21'h000000;
            1: resident_slot_base = 21'h03f480;
            2: resident_slot_base = 21'h07e900;
            3: resident_slot_base = 21'h0bdd80;
            4: resident_slot_base = 21'h0fd200;
            5: resident_slot_base = 21'h13c680;
            6: resident_slot_base = 21'h17bb00;
            7: resident_slot_base = 21'h1baf80;
        endcase
    end
endfunction

// Logical ID 6 is disabled. Check normal_id_valid before using this result.
function normal_id_valid;
    input [2:0] id;
    begin normal_id_valid = id != 3'd6; end
endfunction
function [2:0] normal_id_to_slot;
    input [2:0] id;
    begin normal_id_to_slot = id == 3'd7 ? 3'd6 : id; end
endfunction
function [2:0] resident_slot_to_normal_id;
    input [2:0] slot;
    begin resident_slot_to_normal_id = slot == 3'd6 ? 3'd7 : slot; end
endfunction
