// Instruction-level TMS320C25 implementation for the Taito Air System DSP.
//
// [AI-1] [AI-3] This file replaces the core's original multi-cycle C25 for
// Air Inferno (docs/air-inferno-changes.md): it adds the instructions Air
// Inferno uses ([AI-1]; the list is in docs/air-inferno.md) and runs them
// quickly enough, paced to MAME's C25 ([AI-3]). tests/ref/tas_tms320c25_ref.sv
// is the original core with only the [AI-1] changes, marked there;
// `make test-c25-diff` checks that the two agree instruction by instruction.
//
// An architectural core rather than a pin/cycle replica: instruction results,
// addressing side effects and repeat sequencing follow the C2x user's guide
// and MAME's tms32025 (the reference the Taito Air games are checked
// against). Instruction timing is this core's own and quicker than the
// original, so that with the board's external wait states the DSP still
// finishes each frame's 3D work (Air Inferno runs about 130,000 instructions
// a frame, which MAME's 9 MIPS C25 just manages).
//
// Timing
//   * The program ROM has one clock of latency and prog_addr is driven
//     combinationally with the address of the word needed next, so a
//     sequential instruction's word is already on prog_data when the core
//     reaches S_DECODE: there are no fetch states.
//   * The C25's on-chip data RAM (0000-03FF: registers, B2, B0, B1 and the
//     reserved gaps, all plain RAM here) is inside the core in an M10K. Its
//     address comes from the instruction being decoded, so a read completes
//     on the next clock and a write at once.
//   * 0400 and above go over the data_req/data_ack bus to the board
//     (tas_dsp): line RAM, shared RAM and the custom peripherals.
//   Clocks per instruction: register-only and on-chip writes 1, on-chip
//   reads 2, two-word instructions 2, external accesses 1 + the bus latency
//   (3 with tas_dsp). Repeated instructions (RPT/RPTK) re-execute from the
//   instruction register without refetching.
//   With `throttle` set, instructions start no faster than a C25 clocked at
//   36 MHz (9 M machine cycles/s, as MAME's taitoair) would run them, using
//   MAME's tms32025 cycle counts: a credit of 9 per 32 MHz clock, 32 per
//   machine cycle spent, decode stalled while the credit is negative.
//
// Not implemented (the Taito Air programs do not use them; counted in
// debug_illegal): interrupts, IN/OUT, LST/LST1/SST/SST1, DMOV, TBLR/TBLW,
// MAC/MACD, BLKP, BC/BNC, NORM, CNFP and the serial-port/XF controls.
module tas_tms320c25 (
    input               clk,
    input               reset,
    input               hold,
    input               throttle,        // [AI-3] pace instructions like a 36 MHz C25

    output     [11:0]   prog_addr,
    input      [15:0]   prog_data,

    // external data space (0400-FFFF): level request held until data_ack
    output reg          data_req,
    output reg          data_we,
    output reg [15:0]   data_addr,
    output reg [15:0]   data_wdata,
    input               data_ack,
    input      [15:0]   data_rdata,

    output reg [15:0]   debug_pc,
    output reg [15:0]   debug_ir,
    output reg [31:0]   debug_instructions,
    output reg [15:0]   debug_illegal,
    output reg          debug_write,
    output reg          retire           // one clock per completed instruction
);

localparam [3:0]
    S_START   = 4'd0,
    S_DECODE  = 4'd1,
    S_EXEC    = 4'd2,     // on-chip read data arrives
    S_IMM     = 4'd3,     // second instruction word on prog_data
    S_EXT     = 4'd4,     // external access in flight
    S_LTD     = 4'd5,     // LTD's DMOV write
    S_BLKD_W  = 4'd6,     // BLKD source word in hand: write the destination
    S_BLKD_RX = 4'd7,     // BLKD external source read in flight
    S_BLKD_WX = 4'd8;     // BLKD external destination write in flight

reg [3:0]  state;
reg [15:0] pc;            // address of the instruction being decoded
reg [15:0] ir;
reg [31:0] acc;
reg [31:0] preg;
reg [15:0] treg;
reg [15:0] ar [0:7];
reg [15:0] stack [0:7];
reg [2:0]  arp;
reg [2:0]  arb;
reg [8:0]  dp;
reg ov, ovm, intm, sxm, carry, tc;
reg [1:0]  pm;
reg [7:0]  rptc;
reg        repeat_armed;  // an RPT/RPTK has armed repetition of the next instruction
reg        rep_pending;   // re-execute ir (a repetition) instead of prog_data
reg [15:0] pfc;           // BLKD source pointer
reg [15:0] ea_q;          // effective address of the instruction in progress
reg [15:0] blkd_data;
reg        ext_is_blkd_src;
reg [15:0] next_pc;       // temporary in the register-only path
integer i;

// ---- on-chip data RAM --------------------------------------------------
(* ramstyle = "M10K, no_rw_check" *) reg [15:0] local_ram [0:1023];
reg  [15:0] local_q;
reg  [9:0]  lr_addr;
reg         lr_we;
reg  [15:0] lr_wdata;
always @(posedge clk) begin
    if (lr_we) local_ram[lr_addr] <= lr_wdata;
    local_q <= local_ram[lr_addr];
end

// ---- helpers -------------------------------------------------------------
function automatic [31:0] memory_operand(input [15:0] word, input [3:0] shift);
reg [31:0] extended;
begin
    extended = sxm ? {{16{word[15]}}, word} : {16'd0, word};
    memory_operand = extended << shift;
end
endfunction

function automatic [31:0] shifted_product;
begin
    case (pm)
        2'd0: shifted_product = preg;
        2'd1: shifted_product = preg << 1;
        2'd2: shifted_product = preg << 4;
        default: shifted_product = $signed(preg) >>> 6;
    endcase
end
endfunction

// Bit-reversed (FFT) addressing: the carry runs from bit 15 towards bit 0.
// Reversing the operands and the sum keeps it on an ordinary carry chain.
function automatic [15:0] bit_reverse16(input [15:0] value);
integer bit_index;
begin
    for (bit_index = 0; bit_index < 16; bit_index = bit_index + 1)
        bit_reverse16[bit_index] = value[15 - bit_index];
end
endfunction

function automatic [15:0] reverse_carry_add(input [15:0] left, input [15:0] right);
begin
    reverse_carry_add = bit_reverse16(bit_reverse16(left) + bit_reverse16(right));
end
endfunction

// Next value of AR(ARP) for an indirect access's address modification.
function automatic [15:0] modified_ar(input [7:0] low);
begin
    case (low[6:4])
        3'b001: modified_ar = ar[arp] - 1'd1;
        3'b010: modified_ar = ar[arp] + 1'd1;
        3'b100: modified_ar = reverse_carry_add(ar[arp], -ar[0]);
        3'b101: modified_ar = ar[arp] - ar[0];
        3'b110: modified_ar = ar[arp] + ar[0];
        3'b111: modified_ar = reverse_carry_add(ar[arp], ar[0]);
        default: modified_ar = ar[arp];
    endcase
end
endfunction

task automatic modify_indirect(input [7:0] low);
begin
    ar[arp] <= modified_ar(low);
    if (low[3]) begin
        arb <= arp;
        arp <= low[2:0];
    end
end
endtask

task automatic push_stack(input [15:0] value);
integer s;
begin
    for (s = 0; s < 7; s = s + 1) stack[s] <= stack[s + 1];
    stack[7] <= value;
end
endtask

task automatic pop_stack_discard;
integer s;
begin
    for (s = 7; s > 0; s = s - 1) stack[s] <= stack[s - 1];
end
endtask

task automatic add_to_acc(input [31:0] value);
reg [31:0] old_value;
reg [31:0] result;
begin
    old_value = acc;
    result = old_value + value;
    carry <= (old_value > result);
    if ((~(old_value[31] ^ value[31])) && (result[31] ^ old_value[31])) begin
        ov <= 1'b1;
        if (ovm) result = old_value[31] ? 32'h80000000 : 32'h7fffffff;
    end
    acc <= result;
end
endtask

task automatic sub_from_acc(input [31:0] value);
reg [31:0] old_value;
reg [31:0] result;
begin
    old_value = acc;
    result = old_value - value;
    carry <= (old_value >= value);
    if ((old_value[31] ^ value[31]) && (result[31] ^ old_value[31])) begin
        ov <= 1'b1;
        if (ovm) result = old_value[31] ? 32'h80000000 : 32'h7fffffff;
    end
    acc <= result;
end
endtask

// ADDH / SUBH: 16-bit operation on the high accumulator word. The carry is
// only ever set by ADDH and only ever cleared by SUBH (as MAME's tms32025).
task automatic add_high(input [15:0] value);
reg [15:0] old_high;
reg [15:0] new_high;
begin
    old_high = acc[31:16];
    new_high = old_high + value;
    if (new_high < old_high) carry <= 1'b1;
    if ((new_high[15] ^ value[15]) && (new_high[15] ^ old_high[15])) begin
        ov <= 1'b1;
        if (ovm) new_high = old_high[15] ? 16'h8000 : 16'h7fff;
    end
    acc[31:16] <= new_high;
end
endtask

task automatic sub_high(input [15:0] value);
reg [15:0] old_high;
reg [15:0] new_high;
begin
    old_high = acc[31:16];
    new_high = old_high - value;
    if (old_high < new_high) carry <= 1'b0;
    if ((old_high[15] ^ value[15]) && (old_high[15] ^ new_high[15])) begin
        ov <= 1'b1;
        if (ovm) new_high = old_high[15] ? 16'h8000 : 16'h7fff;
    end
    acc[31:16] <= new_high;
end
endtask

// ADDC / SUBB: the carry (borrow) takes part, and is left alone when the
// result equals the old accumulator.
task automatic add_with_carry(input [31:0] value);
reg [31:0] old_value;
reg [31:0] result;
begin
    old_value = acc;
    result = old_value + value + {31'd0, carry};
    if (result != old_value) carry <= (old_value > result);
    if ((~(old_value[31] ^ value[31])) && (result[31] ^ old_value[31])) begin
        ov <= 1'b1;
        if (ovm) result = old_value[31] ? 32'h80000000 : 32'h7fffffff;
    end
    acc <= result;
end
endtask

task automatic sub_with_borrow(input [31:0] value);
reg [31:0] old_value;
reg [31:0] result;
begin
    old_value = acc;
    result = old_value - value - {31'd0, ~carry};
    if (result != old_value) carry <= !(old_value < result);
    if ((old_value[31] ^ value[31]) && (result[31] ^ old_value[31])) begin
        ov <= 1'b1;
        if (ovm) result = old_value[31] ? 32'h80000000 : 32'h7fffffff;
    end
    acc <= result;
end
endtask

// ---- decode of the word in S_DECODE ---------------------------------------
wire [15:0] w = rep_pending ? ir : prog_data;
wire [7:0]  op = w[15:8];
wire [15:0] ea = w[7] ? ar[arp] : {dp, w[6:0]};
wire        ea_local = ea[15:10] == 6'd0;

// memory-read instructions (the operand is read, then the operation applies)
wire [15:0] exec_operand;
wire is_read =
    (op[7:6] == 2'b00) ||                                   // 00-3F
    (op[7:4] == 4'h4) ||                                    // 40-4F
    op == 8'h52 || op == 8'h53 || op == 8'h54 ||            // LDP LPH PSHD
    op == 8'h57 || op == 8'h5a || op == 8'h5b ||            // BITT SQRS LTS
    op == 8'h7b ||                                          // ZALR
    (op[7:4] == 4'h9) ||                                    // BIT
    op == 8'hcf;                                            // MPYU
// memory-write instructions (the value comes from registers)
wire is_write =
    (op[7:4] == 4'h6) ||                                    // SACL SACH
    (op[7:3] == 5'b01110) ||                                // SAR
    op == 8'h7a || op == 8'h7c || op == 8'h7d;              // POPD SPL SPH
// two-word instructions
wire is_imm =
    (op[7:4] == 4'hd && w[2:0] != 3'd7) ||                  // LRLK LALK ADLK SBLK ANDK ORK XORK
    (op[7:4] == 4'hf && op != 8'hfc);                       // branches, BLKD, CALL, B

reg [15:0] write_value;
always @* begin
    casez (op)
        8'b01100???: write_value = acc << op[2:0];                        // SACL
        8'b01101???: write_value = (acc << op[2:0]) >> 16;                // SACH
        8'b01110???: write_value = ar[op[2:0]];                           // SAR
        8'h7a:       write_value = stack[7];                              // POPD
        8'h7c:       write_value = shifted_product();                     // SPL
        default:     write_value = shifted_product() >> 16;               // SPH
    endcase
end

// flow change of a one-word instruction completing in S_DECODE
wire dec_bacc = op == 8'hce && (w[7:0] == 8'h25 || w[7:0] == 8'h24);     // BACC CALA
wire dec_ret  = op == 8'hce && w[7:0] == 8'h26;
wire dec_trap = op == 8'hce && w[7:0] == 8'h1e;

// ---- speed limit -----------------------------------------------------------
// Machine cycles of the instruction being decoded (MAME tms32025 table):
// branches, CALL, BLKD's base, two-word immediates, CALA/BACC/RET and TRAP
// take 2, BLKD 3, everything else here 1. Under RPT/RPTK the repeated
// instruction costs one more for its fetch, then 1 per execution (BLKD 2).
function automatic [1:0] machine_cycles(input [15:0] word, input first_repeat,
                                        input repetition);
reg [1:0] table_cycles;
begin
    if (word[15:8] == 8'hfd) table_cycles = 2'd3;                        // BLKD
    else if (word[15:12] == 4'hf) table_cycles = 2'd2;                   // branches
    else if (word[15:12] == 4'hd && word[2:0] != 3'd7) table_cycles = 2'd2;
    else if (word[15:8] == 8'hce &&
             (word[7:0] == 8'h1e || word[7:0] == 8'h24 ||
              word[7:0] == 8'h25 || word[7:0] == 8'h26)) table_cycles = 2'd2;
    else table_cycles = 2'd1;
    if (repetition) machine_cycles = word[15:8] == 8'hfd ? 2'd2 : 2'd1;
    else if (first_repeat) machine_cycles = word[15:8] == 8'hfd ? 2'd3 : 2'd2;
    else machine_cycles = table_cycles;
end
endfunction

// Up to 64 cycles (7 us) can be banked, so that the core catches up after
// the few instructions it runs slower than a real C25 (a board access takes
// 4 clocks here against 3.6 per machine cycle) and after short HOLDs,
// keeping the average rate at the original's.
localparam signed [12:0] CREDIT_CAP = 13'sd2048;
reg signed [12:0] credit;
wire stall = hold || (throttle && credit < 0);
wire [1:0] decode_cycles = machine_cycles(w,
    repeat_armed && !rep_pending && op != 8'hcb && op != 8'h4b, rep_pending);
reg signed [12:0] credit_next;
always @* begin
    credit_next = credit + 13'sd9;
    if (state == S_DECODE && !stall)
        credit_next = credit_next - $signed({6'd0, decode_cycles, 5'd0});
    if (credit_next > CREDIT_CAP) credit_next = CREDIT_CAP;
end
always @(posedge clk) begin
    if (reset || !throttle) credit <= 13'sd0;
    else credit <= credit_next;
end

// branch decision on the second word (S_IMM, ir holds the first)
reg branch_taken;
always @* begin
    case (ir[15:8])
        8'hf0: branch_taken = ov;
        8'hf1: branch_taken = $signed(acc) > 0;
        8'hf2: branch_taken = $signed(acc) <= 0;
        8'hf3: branch_taken = $signed(acc) < 0;
        8'hf4: branch_taken = $signed(acc) >= 0;
        8'hf5: branch_taken = acc != 0;
        8'hf6: branch_taken = acc == 0;
        8'hf7: branch_taken = !ov;
        8'hf8: branch_taken = !tc;
        8'hf9: branch_taken = tc;
        8'hfa: branch_taken = 1'b0;          // BIOZ: BIO is held inactive
        8'hfb: branch_taken = ar[arp] != 0;
        8'hfe, 8'hff: branch_taken = 1'b1;   // CALL, B
        default: branch_taken = 1'b0;
    endcase
end

// Program address: the word wanted on prog_data next clock.
reg [15:0] fetch_addr;
always @* begin
    case (state)
        S_START: fetch_addr = pc;
        S_DECODE: begin
            if (stall) fetch_addr = pc;
            else if (dec_bacc) fetch_addr = acc[15:0];
            else if (dec_ret) fetch_addr = stack[7];
            else if (dec_trap) fetch_addr = 16'h001e;
            else fetch_addr = pc + 16'd1;
        end
        S_IMM: begin
            if (ir[15:12] == 4'hf && ir[15:8] != 8'hfd && branch_taken)
                fetch_addr = prog_data;
            else fetch_addr = pc + 16'd2;
        end
        S_LTD, S_EXEC, S_EXT: fetch_addr = pc + 16'd1;
        default: fetch_addr = pc + 16'd2;   // BLKD states
    endcase
end
assign prog_addr = fetch_addr[11:0];

// On-chip RAM port. Outside S_DECODE the address is held on the instruction's
// own operand so local_q keeps its value (LTD's DMOV writes it back).
always @* begin
    lr_addr = ea_q[9:0];
    lr_we = 1'b0;
    lr_wdata = write_value;
    case (state)
        S_DECODE: begin
            if (rep_pending && op == 8'hfd) lr_addr = pfc[9:0];      // repeated BLKD source
            else lr_addr = ea[9:0];
            lr_we = !stall && is_write && ea_local;
        end
        S_IMM: lr_addr = prog_data[9:0];                            // BLKD source
        S_LTD: begin
            lr_addr = ea_q[9:0] + 10'd1;
            lr_wdata = local_q;
            lr_we = 1'b1;
        end
        S_BLKD_W: begin
            lr_addr = ea_q[9:0];
            lr_wdata = ext_is_blkd_src ? blkd_data : local_q;
            lr_we = ea_q[15:10] == 6'd0;
        end
        default: begin end
    endcase
end

assign exec_operand = state == S_EXT ? data_rdata : local_q;

// ---- instruction completion ---------------------------------------------
task automatic complete(input [15:0] target, input is_rpt);
begin
    retire <= 1'b1;
    debug_instructions <= debug_instructions + 1'd1;
    state <= S_DECODE;
    if (!is_rpt && repeat_armed) begin
        if (rptc != 0) begin
            rptc <= rptc - 1'd1;
            rep_pending <= 1'b1;             // pc stays on the repeated instruction
        end else begin
            repeat_armed <= 1'b0;
            rep_pending <= 1'b0;
            pc <= target;
        end
    end else begin
        rep_pending <= 1'b0;
        pc <= target;
    end
end
endtask

// operations of the memory-read instructions, given the operand
task automatic exec_read(input [15:0] d);
begin
    casez (ir[15:8])
        8'h0?: add_to_acc(memory_operand(d, ir[11:8]));                   // ADD
        8'h1?: sub_from_acc(memory_operand(d, ir[11:8]));                 // SUB
        8'h2?: acc <= memory_operand(d, ir[11:8]);                         // LAC
        8'b00110???: ar[ir[10:8]] <= d;                                    // LAR (the load wins)
        8'h38: preg <= $signed(d) * $signed(treg);                         // MPY
        8'h39: begin add_to_acc(shifted_product()); treg <= d;             // SQRA
                     preg <= $signed(d) * $signed(d); end
        8'h3a: begin add_to_acc(shifted_product());                        // MPYA
                     preg <= $signed(d) * $signed(treg); end
        8'h3b: begin sub_from_acc(shifted_product());                      // MPYS
                     preg <= $signed(d) * $signed(treg); end
        8'h3c: treg <= d;                                                  // LT
        8'h3d: begin treg <= d; add_to_acc(shifted_product()); end         // LTA
        8'h3e: begin treg <= d; acc <= shifted_product(); end              // LTP
        8'h3f: begin treg <= d; add_to_acc(shifted_product()); end         // LTD
        8'h40: acc <= {d, 16'd0};                                          // ZALH
        8'h41: acc <= {16'd0, d};                                          // ZALS
        8'h42: acc <= memory_operand(d, treg[3:0]);                        // LACT
        8'h43: add_with_carry({16'd0, d});                                 // ADDC
        8'h44: sub_high(d);                                                // SUBH
        8'h45: sub_from_acc({16'd0, d});                                   // SUBS
        8'h46: sub_from_acc(memory_operand(d, treg[3:0]));                 // SUBT
        8'h47: begin                                                       // SUBC
            if (acc >= memory_operand(d, 4'd15))
                acc <= ((acc - memory_operand(d, 4'd15)) << 1) | 32'd1;
            else acc <= acc << 1;
            carry <= (acc >= memory_operand(d, 4'd15));
        end
        8'h48: add_high(d);                                                // ADDH
        8'h49: add_to_acc({16'd0, d});                                     // ADDS
        8'h4a: add_to_acc(memory_operand(d, treg[3:0]));                   // ADDT
        8'h4b: begin rptc <= d[7:0]; repeat_armed <= 1'b1; end             // RPT
        8'h4c: acc[15:0] <= acc[15:0] ^ d;                                 // XOR
        8'h4d: acc[15:0] <= acc[15:0] | d;                                 // OR
        8'h4e: acc <= acc & {16'd0, d};                                    // AND
        8'h4f: sub_with_borrow({16'd0, d});                                // SUBB
        8'h52: dp <= d[8:0];                                               // LDP
        8'h53: preg[31:16] <= d;                                           // LPH
        8'h54: push_stack(d);                                              // PSHD
        8'h57: tc <= |(d & (16'h8000 >> treg[3:0]));                       // BITT
        8'h5a: begin sub_from_acc(shifted_product()); treg <= d;           // SQRS
                     preg <= $signed(d) * $signed(d); end
        8'h5b: begin treg <= d; sub_from_acc(shifted_product()); end       // LTS
        8'h7b: acc <= {d, 16'h8000};                                       // ZALR
        8'h9?: tc <= |(d & (16'h8000 >> ir[11:8]));                        // BIT
        8'hcf: preg <= {16'd0, d} * {16'd0, treg};                         // MPYU
        default: begin end
    endcase
end
endtask

always @(posedge clk) begin
    debug_write <= 1'b0;
    retire <= 1'b0;

    if (reset) begin
        state <= S_START;
        pc <= 16'd0;
        ir <= 16'd0;
        acc <= 32'd0;
        preg <= 32'd0;
        treg <= 16'd0;
        arp <= 3'd0;
        arb <= 3'd0;
        dp <= 9'd0;
        ov <= 1'b0;
        ovm <= 1'b0;
        intm <= 1'b1;
        sxm <= 1'b1;
        carry <= 1'b1;
        tc <= 1'b0;
        pm <= 2'd0;
        rptc <= 8'd0;
        repeat_armed <= 1'b0;
        rep_pending <= 1'b0;
        pfc <= 16'd0;
        ea_q <= 16'd0;
        blkd_data <= 16'd0;
        ext_is_blkd_src <= 1'b0;
        data_req <= 1'b0;
        data_we <= 1'b0;
        data_addr <= 16'd0;
        data_wdata <= 16'd0;
        debug_pc <= 16'd0;
        debug_ir <= 16'd0;
        debug_instructions <= 32'd0;
        debug_illegal <= 16'd0;
        for (i = 0; i < 8; i = i + 1) begin
            ar[i] <= 16'd0;
            stack[i] <= 16'd0;
        end
    end else begin
        case (state)
            S_START: state <= S_DECODE;

            S_DECODE: if (!stall) begin
                ir <= w;
                debug_pc <= pc;
                debug_ir <= w;
                ea_q <= ea;
                if (rep_pending && op == 8'hfd) begin
                    // repeated BLKD: no operand word, the source is PFC
                    if (pfc[15:10] == 6'd0) begin
                        ext_is_blkd_src <= 1'b0;
                        state <= S_BLKD_W;
                    end else begin
                        data_addr <= pfc;
                        data_we <= 1'b0;
                        data_req <= 1'b1;
                        state <= S_BLKD_RX;
                    end
                end else if (is_read) begin
                    if (w[7]) modify_indirect(w[7:0]);
                    if (ea_local) state <= S_EXEC;
                    else begin
                        data_addr <= ea;
                        data_we <= 1'b0;
                        data_req <= 1'b1;
                        state <= S_EXT;
                    end
                end else if (is_write) begin
                    if (w[7]) modify_indirect(w[7:0]);
                    if (op == 8'h7a) pop_stack_discard();                  // POPD
                    debug_write <= 1'b1;
                    if (ea_local) complete(pc + 16'd1, 1'b0);
                    else begin
                        data_addr <= ea;
                        data_wdata <= write_value;
                        data_we <= 1'b1;
                        data_req <= 1'b1;
                        state <= S_EXT;
                    end
                end else if (is_imm) begin
                    state <= S_IMM;
                end else begin
                    // register-only instructions
                    next_pc = pc + 16'd1;
                    casez (op)
                        8'h55: if (w[7]) modify_indirect(w[7:0]);          // MAR LARP NOP
                        8'h7e: ar[arp] <= ar[arp] + {8'd0, w[7:0]};        // ADRK
                        8'h7f: ar[arp] <= ar[arp] - {8'd0, w[7:0]};        // SBRK
                        8'b101?????: preg <= $signed(treg) *               // MPYK
                                             $signed({{3{w[12]}}, w[12:0]});
                        8'b11000???: ar[op[2:0]] <= {8'd0, w[7:0]};        // LARK
                        8'hc8, 8'hc9: dp <= w[8:0];                        // LDPK
                        8'hca: acc <= {24'd0, w[7:0]};                     // LACK ZAC
                        8'hcb: begin rptc <= w[7:0]; repeat_armed <= 1'b1; end // RPTK
                        8'hcc: add_to_acc({24'd0, w[7:0]});                // ADDK
                        8'hcd: sub_from_acc({24'd0, w[7:0]});              // SUBK
                        8'hce: case (w[7:0])
                            8'h00: intm <= 1'b0;                           // EINT
                            8'h01: intm <= 1'b1;                           // DINT
                            8'h02: ovm <= 1'b0;                            // ROVM
                            8'h03: ovm <= 1'b1;                            // SOVM
                            8'h04: begin end                               // CNFD
                            8'h06: sxm <= 1'b0;                            // RSXM
                            8'h07: sxm <= 1'b1;                            // SSXM
                            8'h08, 8'h09, 8'h0a, 8'h0b: pm <= w[1:0];      // SPM
                            8'h14: acc <= shifted_product();               // PAC
                            8'h15: add_to_acc(shifted_product());          // APAC
                            8'h16: sub_from_acc(shifted_product());        // SPAC
                            8'h18: begin carry <= acc[31]; acc <= acc << 1; end // SFL
                            8'h19: begin carry <= acc[0];                  // SFR
                                   acc <= sxm ? $signed(acc) >>> 1 : acc >> 1; end
                            8'h1b: begin                                   // ABS
                                if (acc[31]) begin
                                    if (acc == 32'h80000000) begin
                                        ov <= 1'b1;
                                        acc <= ovm ? 32'h7fffffff : acc;
                                    end else acc <= -$signed(acc);
                                end
                                carry <= 1'b0;
                            end
                            8'h1c: push_stack(acc[15:0]);                  // PUSH
                            8'h1d: begin acc <= {16'd0, stack[7]}; pop_stack_discard(); end // POP
                            8'h1e: begin push_stack(pc + 16'd1); next_pc = 16'h001e; end // TRAP
                            8'h23: begin                                   // NEG
                                if (acc == 32'h80000000) begin
                                    ov <= 1'b1;
                                    acc <= ovm ? 32'h7fffffff : acc;
                                end else acc <= -$signed(acc);
                                carry <= (acc == 0);
                            end
                            8'h24: begin push_stack(pc + 16'd1); next_pc = acc[15:0]; end // CALA
                            8'h25: next_pc = acc[15:0];                    // BACC
                            8'h26: begin next_pc = stack[7]; pop_stack_discard(); end // RET
                            8'h27: acc <= ~acc;                            // CMPL
                            8'h30: carry <= 1'b0;                          // RC
                            8'h31: carry <= 1'b1;                          // SC
                            8'h32: tc <= 1'b0;                             // RTC
                            8'h33: tc <= 1'b1;                             // STC
                            8'h34: begin acc <= {acc[30:0], carry}; carry <= acc[31]; end // ROL
                            8'h35: begin acc <= {carry, acc[31:1]}; carry <= acc[0]; end  // ROR
                            8'h50: tc <= (ar[arp] == ar[0]);               // CMPR
                            8'h51: tc <= (ar[arp] <  ar[0]);
                            8'h52: tc <= (ar[arp] >  ar[0]);
                            8'h53: tc <= (ar[arp] != ar[0]);
                            default: debug_illegal <= debug_illegal + 1'd1;
                        endcase
                        default: debug_illegal <= debug_illegal + 1'd1;
                    endcase
                    complete(next_pc, op == 8'hcb);
                end
            end

            // Memory-read instructions complete here with the operand from
            // on-chip RAM (S_EXEC) or the board (S_EXT); one shared datapath.
            S_EXEC, S_EXT: if (state == S_EXEC || data_ack) begin
                if (state == S_EXT) data_req <= 1'b0;
                if (state == S_EXEC || !data_we) exec_read(exec_operand);
                // LTD's DMOV only moves within on-chip RAM
                if (state == S_EXEC && ir[15:8] == 8'h3f) state <= S_LTD;
                else complete(pc + 16'd1, ir[15:8] == 8'h4b);
            end

            S_LTD: complete(pc + 16'd1, 1'b0);

            S_IMM: begin
                casez (ir[15:8])
                    8'hd?: begin
                        case (ir[2:0])
                            3'd0: ar[ir[10:8]] <= prog_data;                                   // LRLK
                            3'd1: acc <= (sxm ? {{16{prog_data[15]}}, prog_data}               // LALK
                                              : {16'd0, prog_data}) << ir[11:8];
                            3'd2: add_to_acc((sxm ? {{16{prog_data[15]}}, prog_data}           // ADLK
                                                  : {16'd0, prog_data}) << ir[11:8]);
                            3'd3: sub_from_acc((sxm ? {{16{prog_data[15]}}, prog_data}         // SBLK
                                                    : {16'd0, prog_data}) << ir[11:8]);
                            3'd4: acc <= acc & ({16'd0, prog_data} << ir[11:8]);               // ANDK
                            3'd5: acc <= acc | ({16'd0, prog_data} << ir[11:8]);               // ORK
                            default: acc <= acc ^ ({16'd0, prog_data} << ir[11:8]);            // XORK
                        endcase
                        complete(pc + 16'd2, 1'b0);
                    end
                    8'hfd: begin                                           // BLKD
                        pfc <= prog_data;
                        if (prog_data[15:10] == 6'd0) begin
                            ext_is_blkd_src <= 1'b0;
                            state <= S_BLKD_W;
                        end else begin
                            data_addr <= prog_data;
                            data_we <= 1'b0;
                            data_req <= 1'b1;
                            state <= S_BLKD_RX;
                        end
                    end
                    default: begin                                         // branches, CALL, B
                        if (ir[15:8] == 8'hfe) push_stack(pc + 16'd2);
                        if (ir[15:8] == 8'hf0 && ov) ov <= 1'b0;           // BV taken clears OV
                        if (ir[15:8] == 8'hf7 && ov) ov <= 1'b0;           // BNV not taken clears OV
                        if (ir[7]) modify_indirect(ir[7:0]);
                        complete(branch_taken ? prog_data : pc + 16'd2, 1'b0);
                    end
                endcase
            end

            S_BLKD_RX: if (data_ack) begin
                data_req <= 1'b0;
                blkd_data <= data_rdata;
                ext_is_blkd_src <= 1'b1;
                state <= S_BLKD_W;
            end

            // The destination is the instruction's own direct/indirect
            // address, taken at decode (ea_q); nothing changes AR or DP
            // between decode and here.
            S_BLKD_W: begin
                debug_write <= 1'b1;
                if (ea_q[15:10] == 6'd0) begin
                    pfc <= pfc + 16'd1;
                    if (ir[7]) modify_indirect(ir[7:0]);
                    complete(pc + 16'd2, 1'b0);
                end else begin
                    data_addr <= ea_q;
                    data_wdata <= ext_is_blkd_src ? blkd_data : local_q;
                    data_we <= 1'b1;
                    data_req <= 1'b1;
                    state <= S_BLKD_WX;
                end
            end

            S_BLKD_WX: if (data_ack) begin
                data_req <= 1'b0;
                pfc <= pfc + 16'd1;
                if (ir[7]) modify_indirect(ir[7:0]);
                complete(pc + 16'd2, 1'b0);
            end

            default: state <= S_DECODE;
        endcase
    end
end

endmodule
