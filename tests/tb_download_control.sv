`timescale 1ns/1ps

module tb_download_control;
reg clk = 0;
always #5 clk = ~clk;

reg reset_hw = 1;
reg reset_sys = 1;
reg ioctl_download = 0;
reg [15:0] ioctl_index = 0;
reg ioctl_wr = 0;
reg [26:0] ioctl_addr = 0;
reg [7:0] ioctl_dout = 0;
wire rom_download;
wire rom_loaded;
wire board_reset;
wire game_ainferno;

// A stand-in "Air Inferno" DSP program; the DUT is given its checksum.
function automatic [7:0] ai_byte(input integer k);
    ai_byte = (k * 37 + 5) ^ (k >> 8);
endfunction
function automatic [31:0] ai_sum;
    reg [15:0] s1, s2;
    integer k;
begin
    s1 = 0; s2 = 0;
    for (k = 0; k < 8192; k = k + 1) begin
        s1 = s1 + ai_byte(k);
        s2 = s2 + s1;
    end
    ai_sum = {s1, s2};
end
endfunction

tas_download_control #(.AINFERNO_DSP_SUM(ai_sum())) dut (
    .clk(clk),
    .reset_hw(reset_hw),
    .reset_sys(reset_sys),
    .ioctl_download(ioctl_download),
    .ioctl_index(ioctl_index),
    .ioctl_wr(ioctl_wr),
    .ioctl_addr(ioctl_addr),
    .ioctl_dout(ioctl_dout),
    .rom_download(rom_download),
    .rom_loaded(rom_loaded),
    .board_reset(board_reset),
    .game_ainferno(game_ainferno)
);

// One ROM entry as hps_io delivers it: download raised, bytes written one at
// a time from address 0, download dropped. kind 0: an empty (DDR-direct)
// transfer, 1: the stand-in AI program, 2: the same with one bit changed, 3/4: the
// single game-select byte 00/01.
task automatic send(input [15:0] index, input integer kind);
    integer k, n;
begin
    @(negedge clk);
    ioctl_index = index;
    ioctl_download = 1;
    repeat (3) @(negedge clk);
    n = kind == 0 ? 0 : kind >= 3 ? 1 : 8192;
    for (k = 0; k < n; k = k + 1) begin
        ioctl_addr = k;
        ioctl_dout = kind == 1 ? ai_byte(k) : kind == 2 ? ai_byte(k) ^ (k == 4000) :
                     kind == 3 ? 8'h00 : 8'h01;
        ioctl_wr = 1;
        @(negedge clk);
        ioctl_wr = 0;
        @(negedge clk);
    end
    ioctl_download = 0;
    repeat (3) @(negedge clk);
end
endtask

task automatic expect_game(input want, input [8*40-1:0] what);
begin
    if (game_ainferno !== want)
        $fatal(1, "%0s: game_ainferno %0d, expected %0d", what, game_ainferno, want);
end
endtask

task tick;
begin
    @(posedge clk);
    #1;
end
endtask

initial begin
    tick();
    if (rom_loaded || !board_reset)
        $fatal(1, "reset must start with ROM absent and board held");

    reset_hw = 0;
    reset_sys = 0;
    ioctl_index = 16'd1;
    ioctl_download = 1;
    #1;
    if (!rom_download || !board_reset)
        $fatal(1, "DSP ROM transfer must be a board-resetting ROM download");
    tick();
    ioctl_download = 0;
    tick();
    if (!rom_loaded || board_reset)
        $fatal(1, "board must run after the ROM transfer completes");

    ioctl_index = 16'd2;
    ioctl_download = 1;
    #1;
    if (!rom_download || !board_reset)
        $fatal(1, "game-select byte must be part of the ROM download");
    tick();
    ioctl_download = 0;
    tick();
    if (!rom_loaded || board_reset)
        $fatal(1, "board must run after the game-select byte");

    ioctl_index = 16'd254;
    ioctl_download = 1;
    #1;
    if (rom_download || !rom_loaded || board_reset)
        $fatal(1, "DIP upload must not disturb the running board");
    tick();
    ioctl_download = 0;
    tick();
    if (!rom_loaded || board_reset)
        $fatal(1, "board must remain running after DIP upload");

    reset_sys = 1;
    #1;
    if (!board_reset || !rom_loaded)
        $fatal(1, "user reset must hold the board without forgetting ROM");
    tick();
    reset_sys = 0;
    tick();
    if (board_reset || !rom_loaded)
        $fatal(1, "board must resume after user reset");

    ioctl_index = 16'd0;
    ioctl_download = 1;
    #1;
    if (!rom_download || !board_reset)
        $fatal(1, "main ROM transfer must still reset the board");

    // A hardware reset in the middle of a transfer forgets the partial ROM.
    reset_hw = 1;
    tick();
    if (rom_loaded || !board_reset)
        $fatal(1, "hardware reset did not discard a partial ROM transfer");
    reset_hw = 0;
    tick();
    ioctl_download = 0;
    tick();
    if (!rom_loaded || board_reset)
        $fatal(1, "clean transfer completion after hardware reset failed");

    // Game selection.
    expect_game(0, "power-up");
    send(0, 0); send(1, 1); send(2, 4);
    expect_game(1, "Air Inferno MRA");
    send(254, 0);
    reset_sys = 1; tick(); reset_sys = 0; tick();
    expect_game(1, "DIP upload and reset");
    send(0, 0); send(1, 2); send(2, 3);
    expect_game(0, "Top Landing MRA");
    send(0, 0); send(1, 1);
    expect_game(1, "Air Inferno MRA without the select byte");
    send(0, 0); send(1, 2);
    expect_game(0, "other MRA without the select byte");
    send(0, 0); send(1, 1); send(2, 3);
    expect_game(0, "select byte 00 overrides the program");

    $display("PASS tb_download_control");
    $finish;
end
endmodule
