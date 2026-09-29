`timescale 1ns/1ps

// TC0080VCO FG0 text layer (tas_fg0 in rtl/tas_video.sv): characters and map
// written through the 68000 snoop bus, one frame scanned out and compared
// pixel for pixel with a model of the layout (see the module's notes).
module tb_fg0;
reg clk = 0;
always #5 clk = ~clk;

reg pixel_div = 0;
wire ce_pix = ~pixel_div;
reg [9:0] hcount = 10'd600;
reg [9:0] vcount = 10'd461;
reg wr = 0;
reg [16:0] wr_addr = 0;
reg [15:0] wr_data = 0;
reg [1:0] wr_be = 0;
reg enable = 0;
wire [2:0] pixel;

tas_fg0 dut (
    .clk(clk), .enable(enable), .ce_pix(ce_pix),
    .hcount(hcount), .vcount(vcount),
    .wr(wr), .wr_addr(wr_addr), .wr_data(wr_data), .wr_be(wr_be),
    .pixel(pixel)
);

// the model's copy of the three VCO areas
reg [15:0] chr [0:2047];     // words 0000-07FF
reg [15:0] map [0:2047];     // words 0800-0FFF
reg [7:0]  p0  [0:2047];     // words 8000-87FF, low byte

task automatic vco_write(input [16:0] addr, input [15:0] data, input [1:0] be);
begin
    @(negedge clk);
    wr = 1; wr_addr = addr; wr_data = data; wr_be = be;
    @(negedge clk);
    wr = 0;
end
endtask

function automatic [2:0] model(input integer x, input integer y);
    reg [7:0] code;
    reg [15:0] word;
    reg [7:0] plane0;
    integer cell_index;
begin
    cell_index = (y / 8) * 64 + x / 8;
    word = map[cell_index >> 1];
    code = cell_index[0] ? word[7:0] : word[15:8];
    word = chr[{code, y[2:0]}];
    plane0 = p0[{code, y[2:0]}];
    model = {plane0[7 - x % 8], word[15 - x % 8], word[7 - x % 8]};
end
endfunction

integer k, x, y, errors = 0, lit = 0;
reg [15:0] rnd;
reg [9:0] h_q, v_q;
reg checking = 0;

// raster: two clocks per pixel, 640 x 462
always @(posedge clk) begin
    pixel_div <= ~pixel_div;
    if (ce_pix) begin
        if (hcount == 10'd639) begin
            hcount <= 10'd0;
            vcount <= vcount == 10'd461 ? 10'd0 : vcount + 1'd1;
        end else hcount <= hcount + 1'd1;
    end
    h_q <= hcount;
    v_q <= vcount;
end
// `pixel` is registered from the same hcount as h_q
always @(negedge clk) if (checking && h_q < 512 && v_q < 400) begin
    if (pixel !== model(h_q, v_q)) begin
        if (errors < 10) $display("x=%0d y=%0d pixel %0d, expected %0d", h_q, v_q, pixel, model(h_q, v_q));
        errors = errors + 1;
    end
    if (pixel != 0) lit = lit + 1;
end

initial begin
    for (k = 0; k < 2048; k = k + 1) begin
        chr[k] = 0; map[k] = 0; p0[k] = 0;
    end
    // shadow RAMs start cleared as the model does
    for (k = 0; k < 2048; k = k + 1) begin
        dut.map_hi[k] = 0; dut.map_lo[k] = 0;
        dut.plane0[k] = 0; dut.plane1[k] = 0; dut.plane2[k] = 0;
    end
    rnd = 16'hace1;
    // characters 1..255: pseudo-random planes, written as words, then plane 0
    for (k = 8; k < 2048; k = k + 1) begin
        rnd = {rnd[14:0], rnd[15] ^ rnd[13] ^ rnd[12] ^ rnd[10]};
        chr[k] = rnd;
        vco_write(k, rnd, 2'b11);
        p0[k] = rnd[7:0] ^ rnd[15:8];
        vco_write(17'h08000 + k, {8'hee, p0[k]}, 2'b11);
    end
    // the map: every visible cell_index, in byte writes (upper then lower)
    for (k = 0; k < 1600; k = k + 1) begin
        rnd = {rnd[14:0], rnd[15] ^ rnd[13] ^ rnd[12] ^ rnd[10]};
        map[k] = rnd;
        vco_write(17'h00800 + k, {rnd[15:8], 8'h55}, 2'b10);
        vco_write(17'h00800 + k, {8'haa, rnd[7:0]}, 2'b01);
    end
    // writes to the neighbouring areas must not reach the layer
    for (k = 0; k < 64; k = k + 1) begin
        vco_write(17'h10000 + k, 16'hffff, 2'b11);   // scroll/sprite RAM
        vco_write(17'h01000 + k, 16'hffff, 2'b11);   // chain RAM
        vco_write(17'h08800 + k, 16'hffff, 2'b11);
    end
    enable = 1;
    // start checking at the top of the next frame
    wait (vcount == 10'd461);
    wait (vcount == 10'd0);
    checking = 1;
    wait (vcount == 10'd400);
    checking = 0;
    if (errors) $fatal(1, "%0d FG0 pixels differ", errors);
    if (lit < 10000) $fatal(1, "too few lit FG0 pixels: %0d", lit);
    // disabled: transparent
    enable = 0;
    repeat (4000) @(posedge clk);
    if (pixel !== 0) $fatal(1, "disabled FG0 is not transparent");
    $display("PASS tb_fg0 (%0d lit pixels)", lit);
    $finish;
end

endmodule
