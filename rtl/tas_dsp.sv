// Taito Air TMS320C25 subsystem: the CPU (with its on-chip data RAM) and the
// board-specific external data-space peripherals. Shared and line RAM are true dual-port
// memories owned by tas_main; this block drives their DSP-side ports.
//
// Air Inferno changes (docs/air-inferno-changes.md): [AI-2] the (A*B)/C
// unit is signed and has two channels, [AI-3] the C25's on-chip RAM moved
// into the (faster) core, which is paced by `throttle`, [AI-5] line RAM
// guard.
module tas_dsp (
    input               clk,
    input               reset,
    input               hold,
    input               throttle,       // [AI-3] C25 at the original (MAME) pace
    input               line_busy,      // [AI-5] the renderer is reading line RAM
    input      [14:0]   line_guard,     // [AI-5] ... and has read above this address

    output     [11:0]   prog_addr,
    input      [15:0]   prog_data,

    output              line_cs,
    output              line_we,
    output     [13:0]   line_addr,
    output     [15:0]   line_wdata,
    input      [15:0]   line_rdata,

    output              shared_cs,
    output              shared_we,
    output     [14:0]   shared_addr,
    output     [15:0]   shared_wdata,
    input               shared_grant,
    input      [15:0]   shared_rdata,

    output     [15:0]   debug_pc,
    output     [15:0]   debug_ir,
    output     [31:0]   debug_instructions,
    output     [15:0]   debug_illegal,
    output reg [15:0]   debug_last_addr,
    output reg [15:0]   debug_last_data,
    output reg [2:0]    debug_flags,
    output reg [2:0]    flag_strobe
);

wire core_req;
wire core_we;
wire [15:0] core_addr;
wire [15:0] core_wdata;
reg core_ack;
reg [15:0] core_rdata;
wire core_debug_write;

tas_tms320c25 cpu (
    .clk(clk), .reset(reset), .hold(hold), .throttle(throttle),    // [AI-3]
    .prog_addr(prog_addr), .prog_data(prog_data),
    .data_req(core_req), .data_we(core_we), .data_addr(core_addr),
    .data_wdata(core_wdata), .data_ack(core_ack), .data_rdata(core_rdata),
    .debug_pc(debug_pc), .debug_ir(debug_ir),
    .debug_instructions(debug_instructions), .debug_illegal(debug_illegal),
    .debug_write(core_debug_write), .retire()
);

localparam SEL_OTHER  = 3'd0;
localparam SEL_LINE   = 3'd2;
localparam SEL_SHARED = 3'd3;

reg busy;
reg [2:0] pending_sel;
wire new_request = core_req && !busy;
// [AI-3] The C25's on-chip RAM (0000-03FF) is inside tas_tms320c25, which
// only requests 0400 and above here (it used to be a RAM in this block).
wire line_select = core_addr >= 16'h4000 && core_addr <= 16'h7fff;
wire shared_select = core_addr[15];
// [AI-5] While the polygon renderer reads a published list, the list flags
// (3000-3002) and the line RAM it has not read yet wait; the renderer reads
// downwards from 3FFF, so line RAM above line_guard is free again. Between a
// 3001/3002 write and the renderer taking the list (line_busy, two clocks
// later), all of line RAM waits.
reg [2:0] list_flag_written;
wire line_free = $signed({1'b0, core_addr[13:0]}) > $signed(line_guard) &&
                 list_flag_written == 3'd0;
wire line_blocked = (line_select && !line_free) ||
    (line_busy && core_addr >= 16'h3000 && core_addr <= 16'h3002);
wire request_accepted = new_request && (!shared_select || shared_grant) &&
                        !line_blocked;

assign line_cs = new_request && line_select && line_free;     // [AI-5]
assign line_we = core_we;
assign line_addr = core_addr[13:0];
assign line_wdata = core_wdata;
// Shared RAM is time-multiplexed with the 68000.  Keep the C25 request live
// until tas_main grants the single physical RAM port; only then start the
// normal one-cycle response sequence.
assign shared_cs = new_request && shared_select && shared_grant;
assign shared_we = core_we;
assign shared_addr = core_addr[14:0];
assign shared_wdata = core_wdata;

reg [15:0] mul_a1, mul_b1;
reg [15:0] mul_a2, mul_b2;
reg signed [15:0] clip_x, clip_y, clip_z;
reg [3:0] clip_or;
reg [3:0] clip_and;
reg [3:0] clip_point;

// [AI-2] The board's custom block has two independent (A*B)/C channels: A at
// 3404/3408, B at 3405/3409, writing C at 3406/340A starts that channel and
// 3407/340B read its result. Air Inferno starts both before reading either,
// so each channel needs its own unit. The operands are SIGNED 16-bit (as
// MAME's taitoair driver has them; Air Inferno's perspective divides feed
// negative coordinates, e.g. (-200*-83)/523 = 31) and the result is the low
// 16 bits of the quotient, truncated towards zero; C = 0 reads FFFF. Each
// unsigned sequential unit divides the magnitudes and the sign is applied
// to its result. A sequential unit is preferable here: the C25 data bus
// naturally waits on the result read, while a combinational 32/16 divide
// cannot close the MiSTer clock.
function automatic [15:0] magnitude16(input [15:0] value);
    magnitude16 = value[15] ? (16'd0 - value) : value;
endfunction

reg  [1:0]  muldiv_start;
reg  [15:0] muldiv_a [0:1];
reg  [15:0] muldiv_b [0:1];
reg  [15:0] muldiv_divisor [0:1];
reg  [1:0]  muldiv_zero;
reg  [1:0]  muldiv_negate;
wire [31:0] muldiv_result [0:1];
wire [1:0]  muldiv_busy;

genvar mdc;
generate for (mdc = 0; mdc < 2; mdc = mdc + 1) begin : g_muldiv
    sys_umuldiv #(.NB_MUL1(16), .NB_MUL2(16), .NB_DIV(16)) math_unit (
        .clk(clk), .start(muldiv_start[mdc]), .busy(muldiv_busy[mdc]),
        .mul1(muldiv_a[mdc]), .mul2(muldiv_b[mdc]), .div(muldiv_divisor[mdc]),
        .result(muldiv_result[mdc]), .remainder()
    );
end endgenerate

function automatic [15:0] muldiv_value(input integer ch);
    muldiv_value = muldiv_zero[ch]   ? 16'hffff :
                   muldiv_negate[ch] ? (16'd0 - muldiv_result[ch][15:0]) :
                                       muldiv_result[ch][15:0];
endfunction

function automatic [3:0] classify_point(
    input signed [15:0] x,
    input signed [15:0] y,
    input signed [15:0] z
);
begin
    classify_point[0] = x < -z;
    classify_point[1] = x >  z;
    classify_point[2] = y < -z;
    classify_point[3] = y >  z;
end
endfunction

function automatic [15:0] peripheral_value(input [15:0] address);
begin
    case (address)
        16'h2003: peripheral_value = 16'h0000;
        16'h3407: peripheral_value = muldiv_value(0);    // [AI-2]
        16'h340b: peripheral_value = muldiv_value(1);    // [AI-2]
        16'h341b: peripheral_value = {12'd0, clip_point};
        16'h341c: peripheral_value = {12'd0, clip_and};
        16'h341d: peripheral_value = {12'd0, clip_or};
        default: peripheral_value = 16'hffff;
    endcase
end
endfunction

always @(posedge clk) begin
    core_ack <= 1'b0;

    if (reset) begin
        busy <= 1'b0;
        list_flag_written <= 3'd0;      // [AI-5]
        pending_sel <= SEL_OTHER;
        core_rdata <= 16'hffff;
        mul_a1 <= 16'd0;
        mul_b1 <= 16'd0;
        mul_a2 <= 16'd0;
        mul_b2 <= 16'd0;
        muldiv_start <= 2'b00;          // [AI-2] two channels
        muldiv_a[0] <= 16'd0;  muldiv_a[1] <= 16'd0;
        muldiv_b[0] <= 16'd0;  muldiv_b[1] <= 16'd0;
        muldiv_divisor[0] <= 16'd1;  muldiv_divisor[1] <= 16'd1;
        clip_x <= 16'sd0;
        clip_y <= 16'sd0;
        clip_z <= 16'sd0;
        clip_or <= 4'd0;
        clip_and <= 4'hf;
        clip_point <= 4'd0;
        muldiv_zero <= 2'b00;           // [AI-2]
        muldiv_negate <= 2'b00;         // [AI-2]
        debug_last_addr <= 16'd0;
        debug_last_data <= 16'd0;
        debug_flags <= 3'd0;
        flag_strobe <= 3'd0;
    end else begin
        muldiv_start <= 2'b00;          // [AI-2]
        flag_strobe <= 3'd0;
        if (!core_req) busy <= 1'b0;
        if (line_busy) list_flag_written <= 3'd0;              // [AI-5]
        else if (list_flag_written != 3'd0)
            list_flag_written <= list_flag_written - 1'd1;

        if (request_accepted) begin
            busy <= 1'b1;
            if (line_select) pending_sel <= SEL_LINE;
            else if (shared_select) pending_sel <= SEL_SHARED;
            else pending_sel <= SEL_OTHER;

            debug_last_addr <= core_addr;
            if (core_we) debug_last_data <= core_wdata;

            if (core_we) begin
                case (core_addr)
                    16'h3000: begin
                        debug_flags[0] <= ~debug_flags[0];
                        flag_strobe[0] <= 1'b1;
                    end
                    16'h3001: begin
                        debug_flags[1] <= ~debug_flags[1];
                        flag_strobe[1] <= 1'b1;
                        list_flag_written <= 3'd7;      // [AI-5]
                    end
                    16'h3002: begin
                        debug_flags[2] <= ~debug_flags[2];
                        flag_strobe[2] <= 1'b1;
                        list_flag_written <= 3'd7;      // [AI-5]
                    end
                    16'h3404: mul_a1 <= core_wdata;
                    16'h3405: mul_b1 <= core_wdata;
                    16'h3408: mul_a2 <= core_wdata;
                    16'h3409: mul_b2 <= core_wdata;
                    16'h3418: clip_x <= core_wdata;
                    16'h3419: clip_y <= core_wdata;
                    16'h341a: clip_z <= core_wdata;
                    16'h341b: begin
                        clip_or <= 4'd0;
                        clip_and <= 4'hf;
                    end
                    default: begin end
                endcase
                // [AI-2] each channel starts on its own C write, with the
                // operands' magnitudes and the sign of the result
                if (core_addr == 16'h3406) begin
                    muldiv_zero[0] <= core_wdata == 0;
                    muldiv_a[0] <= magnitude16(mul_a1);
                    muldiv_b[0] <= magnitude16(mul_b1);
                    muldiv_divisor[0] <= magnitude16(core_wdata);
                    muldiv_negate[0] <= mul_a1[15] ^ mul_b1[15] ^ core_wdata[15];
                    muldiv_start[0] <= core_wdata != 0;
                end
                if (core_addr == 16'h340a) begin
                    muldiv_zero[1] <= core_wdata == 0;
                    muldiv_a[1] <= magnitude16(mul_a2);
                    muldiv_b[1] <= magnitude16(mul_b2);
                    muldiv_divisor[1] <= magnitude16(core_wdata);
                    muldiv_negate[1] <= mul_a2[15] ^ mul_b2[15] ^ core_wdata[15];
                    muldiv_start[1] <= core_wdata != 0;
                end
            end else if (core_addr == 16'h341b) begin
                clip_point <= classify_point(clip_x, clip_y, clip_z);
                clip_or <= clip_or | classify_point(clip_x, clip_y, clip_z);
                clip_and <= clip_and & classify_point(clip_x, clip_y, clip_z);
            end
        end

        // [AI-2] A result read waits while its channel is still working,
        // including the clock between the start write and the unit raising
        // busy.
        if (busy && core_req &&
            !(core_addr == 16'h3407 && !muldiv_zero[0] &&
              (muldiv_busy[0] || muldiv_start[0])) &&
            !(core_addr == 16'h340b && !muldiv_zero[1] &&
              (muldiv_busy[1] || muldiv_start[1]))) begin
            core_ack <= 1'b1;
            // ([AI-3] no on-chip RAM case: that RAM is inside the core)
            case (pending_sel)
                SEL_LINE: core_rdata <= line_rdata;
                SEL_SHARED: core_rdata <= shared_rdata;
                default: core_rdata <= peripheral_value(core_addr);
            endcase
        end
    end
end

endmodule
