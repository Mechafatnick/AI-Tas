`timescale 1ns/1ps

// Polygon lists with LINE items (Air Inferno): a colour word with bit 15
// clear followed by y1, x1, y2, x2. The list below starts with lines, mixes
// them with polygons in both orders and clips them at the screen edges; the
// frame the renderer paints is compared pixel for pixel with a model
// (rectangles and the same Bresenham walk, painted in list order).
//
// While the renderer reads the list the second time, a producer writes the
// next list behind the renderer's line_guard, as fast as it allows; the
// frame shows that second reading, so a guard that let the producer
// overtake the parser would change it.
//
// +LIST=<hex> +REF=<hex> run a captured line RAM image instead and compare
// with a reference frame (400 x 512 pens).
module tb_polygon_lines;
reg clk = 1'b0;
always #5 clk = ~clk;

reg reset = 1'b1;
reg [2:0] flag_strobe = 3'd0;
wire line_req;
wire [13:0] line_addr;
reg line_ack = 1'b0;
reg [15:0] line_data = 16'd0;
reg [15:0] line_memory [0:16383];
reg [9:0] hcount = 10'd0;
reg [9:0] vcount = 10'd0;
reg pixel_div = 1'b0;
reg display_buffer = 1'b0;
wire [13:0] pixel;
wire pixel_valid;
wire debug_busy;
wire [14:0] line_guard;
wire [12:0] debug_span_count;
wire debug_overflow;
wire [12:0] debug_missed_lines;

tas_polygon dut (
    .clk(clk), .reset(reset), .flag_strobe(flag_strobe),
    .dma_erase_strobe(1'b0), .dma_copy_strobe(1'b0),
    .line_req(line_req), .line_addr(line_addr),
    .line_ack(line_ack), .line_data(line_data),
    .hcount(hcount), .vcount(vcount), .display_buffer(display_buffer),
    .terrain_flags(256'd0), .line_items(1'b1),
    .pixel(pixel), .pixel_valid(pixel_valid),
    .debug_busy(debug_busy), .line_guard(line_guard),
    .debug_span_count(debug_span_count),
    .debug_overflow(debug_overflow),
    .debug_missed_lines(debug_missed_lines)
);

// The board's raster: 32 MHz clock, a pixel every second clock, 640 x 462.
always @(posedge clk) begin
    line_ack <= line_req;
    if (line_req) line_data <= line_memory[line_addr];
    pixel_div <= ~pixel_div;
    if (reset) begin
        hcount <= 10'd0;
        vcount <= 10'd0;
        display_buffer <= 1'b0;
    end else if (pixel_div) begin
        if (hcount == 10'd639) begin
            hcount <= 10'd0;
            display_buffer <= ~display_buffer;
            vcount <= vcount == 10'd461 ? 10'd0 : vcount + 1'd1;
        end else hcount <= hcount + 1'd1;
    end
end

reg [13:0] expected [0:204799];
integer pointer;

task automatic put(input [15:0] word);
begin
    line_memory[pointer] = word;
    pointer = pointer - 1;
end
endtask

task automatic model_rect(input [7:0] colour, input integer x1, input integer y1,
                          input integer x2, input integer y2);
    integer x, y;
begin
    // (x1,y1)-(x2,y1)-(x2,y2)-(x1,y2): MAME fills rows y1..y2-1, x1..x2
    put(16'h8000 | colour);
    put(y1); put(x1); put(y1); put(x2); put(y2); put(x2); put(y2); put(x1);
    put(16'h8000);
    for (y = y1; y < y2; y = y + 1)
        for (x = x1; x <= x2; x = x + 1)
            if (x >= 0 && x < 512 && y >= 0 && y < 400)
                expected[y * 512 + x] = 14'h0300 + colour;
end
endtask

task automatic model_line(input [7:0] colour, input integer x1, input integer y1,
                          input integer x2, input integer y2);
    integer x, y, dx, dy, sx, sy, err, k;
begin
    put({8'h00, colour}); put(y1); put(x1); put(y2); put(x2);
    begin
        dx = x2 >= x1 ? x2 - x1 : x1 - x2;
        dy = y2 >= y1 ? y2 - y1 : y1 - y2;
        sx = x2 < x1 ? -1 : 1;
        sy = y2 < y1 ? -1 : 1;
        x = x1; y = y1;
        if (dx >= dy) begin
            err = dx / 2;
            for (k = 0; k <= dx; k = k + 1) begin
                if (x >= 0 && x < 512 && y >= 0 && y < 400)
                    expected[y * 512 + x] = 14'h0300 + colour;
                err = err - dy;
                if (err < 0) begin y = y + sy; err = err + dx; end
                x = x + sx;
            end
        end else begin
            err = dy / 2;
            for (k = 0; k <= dy; k = k + 1) begin
                if (x >= 0 && x < 512 && y >= 0 && y < 400)
                    expected[y * 512 + x] = 14'h0300 + colour;
                err = err - dx;
                if (err < 0) begin x = x + sx; err = err + dy; end
                y = y + sy;
            end
        end
    end
end
endtask

task automatic pulse_copy;
begin
    @(posedge clk);
    flag_strobe <= 3'b010;
    @(posedge clk);
    flag_strobe <= 3'b000;
end
endtask

// parse time of each list: from the publication to the end of the list
integer parse_clocks = 0, parse_max = 0;
reg parsing = 0;
always @(posedge clk) begin
    if (dut.raster_state == dut.R_CLEAR && dut.clear_then_fill) begin
        parsing <= 1'b1;
        parse_clocks <= 0;
    end else if (parsing) begin
        parse_clocks <= parse_clocks + 1;
        if (dut.raster_state == dut.R_IDLE) begin
            parsing <= 1'b0;
            if (parse_clocks > parse_max) parse_max = parse_clocks;
        end
    end
end

// The next list's producer: a full-screen rectangle, written downwards from
// 3FFF one word per clock whenever the guard allows.
reg producing = 0;
integer produced = 0;
integer guard_waits = 0;
function automatic [15:0] next_list_word(input integer k);
    case (k)
        0: next_list_word = 16'h8055;
        1: next_list_word = 16'd0;   2: next_list_word = 16'd0;
        3: next_list_word = 16'd0;   4: next_list_word = 16'd511;
        5: next_list_word = 16'd400; 6: next_list_word = 16'd511;
        7: next_list_word = 16'd400; 8: next_list_word = 16'd0;
        9: next_list_word = 16'h8000;
        default: next_list_word = 16'h4000;
    endcase
endfunction
always @(posedge clk) if (producing && produced < 16384) begin
    if ($signed({1'b0, 14'h3fff - produced[13:0]}) > $signed(line_guard)) begin
        line_memory[14'h3fff - produced[13:0]] <= produced < 11 ? next_list_word(produced) : 16'h4000;
        produced <= produced + 1;
    end else guard_waits <= guard_waits + 1;
end
// the parser must never read what the producer may already have written
always @(posedge clk) if (line_req && $signed({1'b0, line_addr}) > $signed(line_guard))
    $fatal(1, "parser reads %04x above the guard %04x", line_addr, line_guard);

// the pixel registered from the hcount of the previous edge
reg [9:0] h_q, v_q;
reg capturing = 0;
integer errors = 0, lit = 0;
always @(posedge clk) begin
    h_q <= hcount;
    v_q <= vcount;
end
always @(negedge clk) if (capturing && !pixel_div && h_q < 512 && v_q < 400) begin
    if ((pixel_valid ? pixel : 14'd0) !== expected[v_q * 512 + h_q]) begin
        if (errors < 12)
            $display("x=%0d y=%0d pen %03x, expected %03x", h_q, v_q,
                     pixel_valid ? pixel : 14'd0, expected[v_q * 512 + h_q]);
        errors = errors + 1;
    end
    if (pixel_valid) lit = lit + 1;
end

string list_path, ref_path;
integer k;
initial begin
    for (k = 0; k < 16384; k = k + 1) line_memory[k] = 16'd0;
    for (k = 0; k < 204800; k = k + 1) expected[k] = 14'd0;
    if ($value$plusargs("LIST=%s", list_path)) begin
        if (!$value$plusargs("REF=%s", ref_path)) $fatal(1, "+LIST needs +REF");
        $readmemh(list_path, line_memory);
        $readmemh(ref_path, expected);
    end else begin
        pointer = 16383;
        // a list that starts with lines
        model_line(8'h11, 10, 5, 40, 5);          // horizontal
        model_line(8'h12, 60, 7, 30, 7);          // horizontal, right to left
        model_line(8'h13, 100, 10, 100, 50);      // vertical
        model_line(8'h14, 104, 50, 104, 10);      // vertical, upwards
        model_line(8'h15, 0, 100, 50, 120);       // x-major
        model_line(8'h16, 250, 140, 200, 100);    // x-major, both negative
        model_line(8'h17, 200, 100, 210, 180);    // y-major
        model_line(8'h18, 230, 180, 220, 100);    // y-major, both negative
        model_line(8'h19, 300, 60, 340, 20);      // diagonal
        model_line(8'h1a, 330, 30, 330, 30);      // a point
        model_line(8'h1b, 500, 300, 530, 310);    // off the right edge
        model_line(8'h1c, 450, 390, 460, 420);    // off the bottom
        model_line(8'h1d, 600, 10, 700, 20);      // wholly off screen
        model_line(8'h1e, 10, 450, 20, 460);      // wholly below
        // a polygon, lines over it, a polygon over those
        model_rect(8'h40, 120, 200, 300, 260);
        model_line(8'h21, 110, 210, 310, 250);
        model_line(8'h22, 110, 230, 310, 230);
        model_line(8'h21, 180, 190, 190, 270);
        model_line(8'h22, 0, 0, 511, 399);        // corner to corner
        model_line(8'h23, 511, 0, 0, 399);
        model_rect(8'h41, 200, 220, 240, 240);
        // many touching and overlapping short lines on one row (sea)
        for (k = 0; k < 120; k = k + 1)
            model_line(k[0] ? 8'h03 : 8'h04, 20 + k * 3 + (k % 5),
                       330, 22 + k * 3 + (k % 7), 330);
        model_rect(8'h42, 400, 350, 480, 360);
        line_memory[pointer] = 16'h4000;
    end
    repeat (4) @(posedge clk);
    reset = 1'b0;
    // The first copy parses into the build bank; the second publishes it and
    // parses the list again, with the next list's producer racing behind
    // the renderer; the third publishes that second reading.
    pulse_copy();
    wait (debug_busy);
    wait (!debug_busy);
    pulse_copy();
    producing = 1;
    wait (debug_busy);
    wait (!debug_busy);
    wait (produced == 16384);
    producing = 0;
    pulse_copy();
    wait (debug_busy);
    wait (dut.raster_state != dut.R_IDLE);
    wait (vcount == 10'd461);
    wait (vcount == 10'd0);
    capturing = 1;
    wait (vcount == 10'd400);
    capturing = 0;
    $display("parse %0d clocks (%0d%% of a frame), spans %0d, missed lines %0d, overflow %0d, lit %0d, producer waited %0d clocks",
             parse_max, parse_max * 100 / (1280 * 462), debug_span_count,
             debug_missed_lines, debug_overflow, lit, guard_waits);
    if (errors) $fatal(1, "%0d pixels differ", errors);
    if (debug_missed_lines) $fatal(1, "the painter missed %0d lines", debug_missed_lines);
    if (debug_overflow) $fatal(1, "span store overflow");
    $display("PASS tb_polygon_lines");
    $finish;
end

initial begin
    repeat (8000000) @(posedge clk);
    $fatal(1, "timeout: state %0d busy %0d", dut.raster_state, debug_busy);
end

endmodule
