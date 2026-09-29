`timescale 1ns/1ps

// Differential test of tas_tms320c25 against tests/ref/tas_tms320c25_ref.sv
// (the earlier multi-cycle core, whose results were checked against MAME with
// Air Inferno's polygon lists). Both run the same program on identical but
// separate data memories with random bus latency and random HOLD; after every
// retired instruction the architectural state must match, and so must every
// data write and the final memory.
//
//   +PROG=<hex words>  +DATA=<hex words, 64K>  +COUNT=<instructions>  +SEED=<n>
// Programs come from tests/gen_c25_program.py.
module tb_c25_diff;
reg clk = 0;
always #5 clk = ~clk;
reg reset = 1;

reg [15:0] program_rom [0:4095];
reg [15:0] mem_ref [0:65535];
reg [15:0] mem_new [0:65535];
integer seed = 1;
integer count = 20000;
string prog_path, data_path;

// ---- reference core ----
wire [11:0] ref_paddr;
reg  [15:0] ref_pdata = 0;
wire ref_req, ref_we;
wire [15:0] ref_addr, ref_wdata;
reg ref_ack = 0;
reg [15:0] ref_rdata = 0;
wire [31:0] ref_instructions;
wire [15:0] ref_illegal;
wire ref_hold;
tas_tms320c25_ref ref_core (
    .clk(clk), .reset(reset), .hold(ref_hold),
    .prog_addr(ref_paddr), .prog_data(ref_pdata),
    .data_req(ref_req), .data_we(ref_we), .data_addr(ref_addr),
    .data_wdata(ref_wdata), .data_ack(ref_ack), .data_rdata(ref_rdata),
    .debug_pc(), .debug_ir(), .debug_instructions(ref_instructions),
    .debug_illegal(ref_illegal), .debug_write()
);

// ---- new core ----
wire [11:0] new_paddr;
reg  [15:0] new_pdata = 0;
wire new_req, new_we;
wire [15:0] new_addr, new_wdata;
reg new_ack = 0;
reg [15:0] new_rdata = 0;
wire [31:0] new_instructions;
wire [15:0] new_illegal;
wire new_retire;
wire new_hold;
reg new_throttle = 0;   // +THROTTLE: pace the new core (results must not change)
tas_tms320c25 new_core (
    .clk(clk), .reset(reset), .hold(new_hold), .throttle(new_throttle),
    .prog_addr(new_paddr), .prog_data(new_pdata),
    .data_req(new_req), .data_we(new_we), .data_addr(new_addr),
    .data_wdata(new_wdata), .data_ack(new_ack), .data_rdata(new_rdata),
    .debug_pc(), .debug_ir(), .debug_instructions(new_instructions),
    .debug_illegal(new_illegal), .debug_write(), .retire(new_retire)
);

always @(posedge clk) begin
    ref_pdata <= program_rom[ref_paddr];
    new_pdata <= program_rom[new_paddr];
end

// ---- buses: accept a request, ack after 1..4 clocks, ignore req the clock after
// Randomness comes from per-stream xorshift generators seeded from +SEED.
function automatic [31:0] xorshift(input [31:0] x);
    reg [31:0] y;
begin
    y = x ^ (x << 13);
    y = y ^ (y >> 17);
    xorshift = y ^ (y << 5);
end
endfunction
reg [31:0] rs_ref_bus = 32'h1, rs_new_bus = 32'h2, rs_ref_hold = 32'h3, rs_new_hold = 32'h4;

integer ref_wait = -1, new_wait = -1;
reg ref_busy = 0, new_busy = 0;
// write logs, compared in order
reg [31:0] ref_wlog [0:1048575];
reg [31:0] new_wlog [0:1048575];
integer ref_wn = 0, new_wn = 0;
always @(posedge clk) begin
    rs_ref_bus <= xorshift(rs_ref_bus);
    rs_new_bus <= xorshift(rs_new_bus);

    ref_ack <= 1'b0;
    ref_busy <= 1'b0;   // the clock after an ack the core is still reacting to it
    if (ref_req && !ref_busy && ref_wait < 0) ref_wait <= rs_ref_bus[1:0];
    if (ref_wait == 0) begin
        ref_wait <= -1;
        ref_busy <= 1'b1;
        ref_ack <= 1'b1;
        if (ref_we) begin
            mem_ref[ref_addr] <= ref_wdata;
            ref_wlog[ref_wn] <= {ref_addr, ref_wdata};
            ref_wn <= ref_wn + 1;
        end else ref_rdata <= mem_ref[ref_addr];
    end else if (ref_wait > 0) ref_wait <= ref_wait - 1;

    new_ack <= 1'b0;
    new_busy <= 1'b0;
    if (new_req && !new_busy && new_wait < 0) new_wait <= rs_new_bus[1:0];
    if (new_wait == 0) begin
        new_wait <= -1;
        new_busy <= 1'b1;
        new_ack <= 1'b1;
        if (new_we) begin
            mem_new[new_addr] <= new_wdata;
            new_wlog[new_wn] <= {new_addr, new_wdata};
            new_wn <= new_wn + 1;
        end else new_rdata <= mem_new[new_addr];
    end else if (new_wait > 0) new_wait <= new_wait - 1;
    // the new core's on-chip RAM writes, logged in order too (never in the
    // same clock as a bus write: the core is waiting in S_EXT then)
    if (new_core.lr_we) begin
        if (new_wait == 0 && new_we) $fatal(1, "on-chip and bus write in one clock");
        new_wlog[new_wn] <= {6'd0, new_core.lr_addr, new_core.lr_wdata};
        new_wn <= new_wn + 1;
    end
    if (new_req && new_addr < 16'h0400)
        $fatal(1, "new core put an on-chip address %04h on the bus", new_addr);
end

// random HOLD, independently for each core; a core that has retired COUNT
// instructions is held for good (combinationally, so it stops at once)
always @(posedge clk) begin
    rs_ref_hold <= xorshift(rs_ref_hold);
    rs_new_hold <= xorshift(rs_new_hold);
    ref_hold_r <= !no_hold && rs_ref_hold[2:0] == 3'd0;
    new_hold_r <= !no_hold && rs_new_hold[2:0] == 3'd0;
end
reg ref_hold_r = 0, new_hold_r = 0;
reg no_hold = 0;
// +END=<hex>: the program's final branch-to-self; a core reaching it stops
reg [15:0] end_pc = 16'hffff;
wire ref_at_end = ref_core.state == 4'd0 && ref_core.pc == end_pc;
wire new_at_end = new_core.state == 4'd1 && new_core.pc == end_pc && !new_core.rep_pending;
assign ref_hold = ref_hold_r || ref_instructions >= count || ref_at_end;
assign new_hold = new_hold_r || new_instructions >= count || new_at_end;

// ---- architectural state after each retired instruction ----
typedef struct packed {
    logic [15:0] pc;
    logic [31:0] acc, preg;
    logic [15:0] treg;
    logic [127:0] ars;
    logic [127:0] stack;
    logic [2:0] arp;
    logic [8:0] dp;
    logic ov, ovm, sxm, carry, tc;
    logic [1:0] pm;
} state_t;
state_t ref_q [$];
state_t new_q [$];

function automatic state_t ref_state();
    state_t s;
    s.pc = ref_core.pc; s.acc = ref_core.acc; s.preg = ref_core.preg; s.treg = ref_core.treg;
    for (int k = 0; k < 8; k++) begin
        s.ars[k*16 +: 16] = ref_core.ar[k];
        s.stack[k*16 +: 16] = ref_core.stack[k];
    end
    s.arp = ref_core.arp; s.dp = ref_core.dp; s.ov = ref_core.ov; s.ovm = ref_core.ovm;
    s.sxm = ref_core.sxm; s.carry = ref_core.carry; s.tc = ref_core.tc; s.pm = ref_core.pm;
    return s;
endfunction
function automatic state_t new_state();
    state_t s;
    s.pc = new_core.pc; s.acc = new_core.acc; s.preg = new_core.preg; s.treg = new_core.treg;
    for (int k = 0; k < 8; k++) begin
        s.ars[k*16 +: 16] = new_core.ar[k];
        s.stack[k*16 +: 16] = new_core.stack[k];
    end
    s.arp = new_core.arp; s.dp = new_core.dp; s.ov = new_core.ov; s.ovm = new_core.ovm;
    s.sxm = new_core.sxm; s.carry = new_core.carry; s.tc = new_core.tc; s.pm = new_core.pm;
    return s;
endfunction

reg [31:0] ref_seen = 0;
integer compared = 0;
longint ref_clocks = 0, new_clocks = 0;
reg ref_done = 0, new_done = 0;
always @(posedge clk) if (!reset) begin
    if (ref_instructions != ref_seen) begin
        ref_seen <= ref_instructions;
        // the reference retires when its register writes have landed
        if (ref_q.size() < 1000000) ref_q.push_back(ref_state());
    end
    if (new_retire) new_q.push_back(new_state());
    if (!ref_done) ref_clocks <= ref_clocks + 1;
    if (!new_done) new_clocks <= new_clocks + 1;
    if (ref_q.size() > 0 && new_q.size() > 0) begin
        state_t a, b;
        a = ref_q.pop_front(); b = new_q.pop_front();
        if (a !== b) begin
            $display("MISMATCH after instruction %0d", compared + 1);
            $display("  ref pc=%04h acc=%08h p=%08h t=%04h ar=%032h arp=%0d dp=%03h ov%0d ovm%0d sxm%0d c%0d tc%0d pm%0d stack=%032h",
                     a.pc, a.acc, a.preg, a.treg, a.ars, a.arp, a.dp, a.ov, a.ovm, a.sxm, a.carry, a.tc, a.pm, a.stack);
            $display("  new pc=%04h acc=%08h p=%08h t=%04h ar=%032h arp=%0d dp=%03h ov%0d ovm%0d sxm%0d c%0d tc%0d pm%0d stack=%032h",
                     b.pc, b.acc, b.preg, b.treg, b.ars, b.arp, b.dp, b.ov, b.ovm, b.sxm, b.carry, b.tc, b.pm, b.stack);
            $fatal(1, "state mismatch");
        end
        compared <= compared + 1;
    end
    if (ref_clocks + new_clocks > 64'd200 * count) begin
        $display("TIMEOUT ref: instr=%0d state=%0d pc=%04h ir=%04h req=%0d busy=%0d wait=%0d | new: instr=%0d state=%0d pc=%04h ir=%04h req=%0d busy=%0d wait=%0d",
                 ref_instructions, ref_core.state, ref_core.pc, ref_core.ir, ref_req, ref_busy, ref_wait,
                 new_instructions, new_core.state, new_core.pc, new_core.ir, new_req, new_busy, new_wait);
        $fatal(1, "timeout");
    end
    if (ref_instructions >= count || ref_at_end) ref_done <= 1'b1;
    if (new_instructions >= count || new_at_end) new_done <= 1'b1;
end

integer f, k, mismatches;
initial begin
    void'($value$plusargs("SEED=%d", seed));
    void'($value$plusargs("COUNT=%d", count));
    no_hold = $test$plusargs("NOHOLD");
    new_throttle = $test$plusargs("THROTTLE");
    void'($value$plusargs("END=%h", end_pc));
    if (!$value$plusargs("PROG=%s", prog_path)) $fatal(1, "+PROG missing");
    if (!$value$plusargs("DATA=%s", data_path)) $fatal(1, "+DATA missing");
    rs_ref_bus = 32'h9e3779b9 ^ seed; rs_new_bus = 32'h85ebca6b ^ (seed * 3);
    rs_ref_hold = 32'hc2b2ae35 ^ (seed * 5); rs_new_hold = 32'h27d4eb2f ^ (seed * 7);
    for (k = 0; k < 4096; k++) program_rom[k] = 16'h0000;
    $readmemh(prog_path, program_rom);
    $readmemh(data_path, mem_ref);
    $readmemh(data_path, mem_new);
    for (k = 0; k < 1024; k++) new_core.local_ram[k] = mem_new[k];
    repeat (4) @(negedge clk);
    reset = 0;
    wait (ref_done && new_done);
    repeat (20) @(negedge clk);
    // on-chip RAM of the new core is the low 1K of its memory
    for (k = 0; k < 1024; k++) mem_new[k] = new_core.local_ram[k];
    mismatches = 0;
    for (k = 0; k < 65536; k++) if (mem_ref[k] !== mem_new[k]) begin
        if (mismatches < 8) $display("memory %04h: ref %04h new %04h", k, mem_ref[k], mem_new[k]);
        mismatches++;
    end
    if (ref_instructions != new_instructions)
        $fatal(1, "instruction counts differ: ref %0d new %0d", ref_instructions, new_instructions);
    if (mismatches) $fatal(1, "%0d memory words differ", mismatches);
    if (ref_wn != new_wn) $fatal(1, "write counts differ: ref %0d new %0d", ref_wn, new_wn);
    for (k = 0; k < ref_wn; k++) if (ref_wlog[k] !== new_wlog[k])
        $fatal(1, "write %0d differs: ref %08h new %08h", k, ref_wlog[k], new_wlog[k]);
    $display("PASS tb_c25_diff seed=%0d instructions=%0d compared=%0d writes=%0d illegal=%0d/%0d clocks ref=%0d new=%0d (%.2fx)",
             seed, ref_instructions, compared, ref_wn, ref_illegal, new_illegal, ref_clocks, new_clocks,
             real'(ref_clocks) / real'(new_clocks));
    $finish;
end

endmodule
