`timescale 1ns/1ps

// Headless whole-board simulation: the 68000/C25 main board and the video
// board (TC0080VCO layers, gradient ROZ, polygon renderer, mixer) running a
// ROM image, with the sound CPU replaced by the boot stub as in tb_main.
// Frames are written as binary PPM from the RGB output.
//
//   +ROM=<image>          linear ROM image (tools/build_rom.py layout)
//   +CYCLES=<n>           system clocks to run
//   +FRAME_EVERY=<n>      write every n-th frame ...
//   +FRAME_FROM=<n>       ... from frame n on (default 0)
//   +FRAME_PREFIX=<path>  output path prefix (default frame_)
//   +POLY_DUMP=<file>     polygon lists at every C25 0x3001/0x3002 write
//   +COIN_AT=<frame> +START_AT=<frame>   coin / start presses (10 frames);
//                         +START2_AT, +START3_AT for further start presses
//   +STICK_X=<v> +STICK_FROM=<frame> +STICK_TO=<frame>   hold the yoke X
//                         counter at v (as the MAME scripts' read tap)
module tb_system;
reg clk = 0;
always #15.625 clk = ~clk;      // 32 MHz, as the MiSTer core

reg reset = 1;
wire vblank;
wire hblank;
wire ce_pix;
wire hsync, vsync;
wire [7:0] red, green, blue;

integer frame = 0;
integer coin_at = -1;
integer start_at = -1;
integer start2_at = -1;
integer start3_at = -1;
wire coin_pulse = coin_at >= 0 && frame >= coin_at && frame < coin_at + 10;
wire start_pulse = (start_at >= 0 && frame >= start_at && frame < start_at + 10) ||
                   (start2_at >= 0 && frame >= start2_at && frame < start2_at + 10) ||
                   (start3_at >= 0 && frame >= start3_at && frame < start3_at + 10);
wire [31:0] controls = (coin_pulse ? 32'h00000020 : 32'd0) |
                       (start_pulse ? 32'h00000010 : 32'd0);

wire rom_req;
wire [23:0] rom_addr;
reg rom_ack = 0;
reg [15:0] rom_data = 16'hffff;
wire [11:0] dsp_prog_addr;
reg [15:0] dsp_prog_data = 16'hffff;

wire [16:0] video_vco_addr;
wire [15:0] video_vco_data;
wire [11:0] video_palette_addr;
wire [15:0] video_palette_data;
wire [12:0] video_gradient_addr;
wire [15:0] video_gradient_low, video_gradient_high;
wire [127:0] video_grw_regs;
wire video_gradbank;
wire [9:0] bg0_scrollx, bg0_scrolly, bg1_scrollx, bg1_scrolly;
wire [15:0] bg0_zoom, bg1_zoom;
wire video_line_req;
wire [13:0] video_line_addr;
wire video_line_ack;
wire [15:0] video_line_data;
wire video_polygon_hold;
wire [14:0] video_polygon_line_guard;
wire [2:0] dsp_flag_strobe;
wire dma_fb_erase_strobe, dma_fb_copy_strobe;
wire gfx_req;
wire [19:0] gfx_addr;
reg gfx_ack = 0;
reg [63:0] gfx_data = 0;
reg gfx_pending = 0;
reg [2:0] gfx_delay = 0;
reg [19:0] gfx_latched_addr = 0;

wire sound_main_cs, sound_main_wr, sound_main_port;
wire [3:0] sound_main_din, sound_main_dout;
wire sound_reset_n, sound_stub_cs, sound_stub_wr, sound_stub_port;
wire [3:0] sound_stub_din, sound_status;

wire [15:0] debug_dsp_illegal;
wire [31:0] debug_dsp_instructions;
wire [23:0] debug_fetch_addr;

reg [7:0] rom [0:24'h2cffff];

// +DSP_FAST lets the C25 run flat out (default: the original pace)
reg dsp_original_speed = 1'b1;
initial if ($test$plusargs("DSP_FAST")) dsp_original_speed = 1'b0;
// +TOPLAND runs the board as Top Landing (default Air Inferno)
reg game_ainferno = 1'b1;
initial if ($test$plusargs("TOPLAND")) game_ainferno = 1'b0;

wire vco_wr;
wire [16:0] vco_wr_addr;
wire [15:0] vco_wr_data;
wire [1:0] vco_wr_be;
tas_main main_board (
    .game_ainferno(game_ainferno),
    .video_vco_wr(vco_wr), .video_vco_wr_addr(vco_wr_addr),
    .video_vco_wr_data(vco_wr_data), .video_vco_wr_be(vco_wr_be),
    .clk(clk), .reset(reset), .vblank(vblank),
    .controls(controls),
    .joystick_l_analog(16'd0), .joystick_r_analog(16'd0),
    .throttle_mode(2'd0),
    .dsp_original_speed(dsp_original_speed),
    .dswa(8'hff), .dswb(8'hff),
    .flight_throttle_counter(), .flight_stick_x_counter(),
    .flight_stick_y_counter(),
    .sound_main_cs(sound_main_cs), .sound_main_wr(sound_main_wr),
    .sound_main_port(sound_main_port), .sound_main_din(sound_main_din),
    .sound_main_dout(sound_main_dout),
    .video_vco_addr(video_vco_addr), .video_vco_data(video_vco_data),
    .video_palette_addr(video_palette_addr),
    .video_palette_data(video_palette_data),
    .video_gradient_addr(video_gradient_addr),
    .video_gradient_low(video_gradient_low),
    .video_gradient_high(video_gradient_high),
    .video_grw_regs(video_grw_regs), .video_gradbank(video_gradbank),
    .video_bg0_scrollx(bg0_scrollx), .video_bg0_scrolly(bg0_scrolly),
    .video_bg0_zoom(bg0_zoom),
    .video_bg1_scrollx(bg1_scrollx), .video_bg1_scrolly(bg1_scrolly),
    .video_bg1_zoom(bg1_zoom),
    .video_line_req(video_line_req), .video_line_addr(video_line_addr),
    .video_line_ack(video_line_ack), .video_line_data(video_line_data),
    .video_polygon_hold(video_polygon_hold),
    .video_polygon_line_guard(video_polygon_line_guard),
    .dsp_prog_addr(dsp_prog_addr), .dsp_prog_data(dsp_prog_data),
    .rom_req(rom_req), .rom_addr(rom_addr),
    .rom_ack(rom_ack), .rom_data(rom_data),
    .debug_addr(), .debug_fetch_addr(debug_fetch_addr), .debug_cycles(),
    .debug_sysctrl(), .debug_irq(), .debug_halted(), .debug_fault(),
    .debug_fault_addr(), .debug_fault_cycles(),
    .debug_hist0(), .debug_hist1(), .debug_hist2(), .debug_hist3(),
    .debug_hist4(), .debug_hist5(), .debug_hist6(), .debug_hist7(),
    .debug_dsp_pc(), .debug_dsp_ir(),
    .debug_dsp_instructions(debug_dsp_instructions),
    .debug_dsp_illegal(debug_dsp_illegal),
    .debug_dsp_addr(), .debug_dsp_data(), .debug_dsp_flags(),
    .dsp_flag_strobe(dsp_flag_strobe),
    .dma_fb_erase_strobe(dma_fb_erase_strobe),
    .dma_fb_copy_strobe(dma_fb_copy_strobe)
);

tas_video game_video (
    .game_ainferno(game_ainferno),
    .vco_wr(vco_wr), .vco_wr_addr(vco_wr_addr),
    .vco_wr_data(vco_wr_data), .vco_wr_be(vco_wr_be),
    .clk(clk), .reset(reset), .rom_loaded(1'b1), .download_active(1'b0),
    .throttle_overlay_enable(1'b0), .throttle_counter(12'd0),
    .stick_x_counter(12'd0), .stick_y_counter(12'd0),
    .vco_addr(video_vco_addr), .vco_data(video_vco_data),
    .palette_addr(video_palette_addr), .palette_data(video_palette_data),
    .gradient_addr(video_gradient_addr),
    .gradient_low(video_gradient_low), .gradient_high(video_gradient_high),
    .grw_regs(video_grw_regs), .gradbank(video_gradbank),
    .bg0_scrollx(bg0_scrollx), .bg0_scrolly(bg0_scrolly), .bg0_zoom(bg0_zoom),
    .bg1_scrollx(bg1_scrollx), .bg1_scrolly(bg1_scrolly), .bg1_zoom(bg1_zoom),
    .dsp_flag_strobe(dsp_flag_strobe),
    .dma_fb_erase_strobe(dma_fb_erase_strobe),
    .dma_fb_copy_strobe(dma_fb_copy_strobe),
    .line_req(video_line_req), .line_addr(video_line_addr),
    .line_ack(video_line_ack), .line_data(video_line_data),
    .gfx_req(gfx_req), .gfx_addr(gfx_addr),
    .gfx_ack(gfx_ack), .gfx_data(gfx_data),
    .ce_pix(ce_pix), .hblank(hblank), .vblank(vblank),
    .hsync(hsync), .vsync(vsync), .red(red), .green(green), .blue(blue),
    .debug_gradient(), .debug_timing(), .ddr_background_safe(),
    .polygon_hold(video_polygon_hold),
    .polygon_line_guard(video_polygon_line_guard)
);

tas_tc0140syt sound_comm (
    .clk(clk), .reset(reset),
    .main_cs(sound_main_cs), .main_wr(sound_main_wr),
    .main_port(sound_main_port), .main_din(sound_main_din),
    .main_dout(sound_main_dout),
    .sound_cs(sound_stub_cs), .sound_wr(sound_stub_wr),
    .sound_port(sound_stub_port), .sound_din(sound_stub_din),
    .sound_dout(), .sound_reset_n(sound_reset_n), .sound_nmi_n(),
    .status(sound_status)
);
tas_sound_boot_stub sound_stub (
    .clk(clk), .reset(reset), .sound_reset_n(sound_reset_n),
    .status(sound_status), .sound_cs(sound_stub_cs),
    .sound_wr(sound_stub_wr), .sound_port(sound_stub_port),
    .sound_din(sound_stub_din)
);

// ---- yoke override
integer stick_x = 0, stick_from = -1, stick_to = -1;
reg stick_forced = 0;
initial begin
    void'($value$plusargs("STICK_X=%d", stick_x));
    void'($value$plusargs("STICK_FROM=%d", stick_from));
    void'($value$plusargs("STICK_TO=%d", stick_to));
end
always @(posedge clk) begin
    if (!stick_forced && stick_from >= 0 && frame >= stick_from && frame < stick_to) begin
        force main_board.flight_controls.stick_x_value = stick_x[11:0];
        stick_forced = 1;
    end else if (stick_forced && frame >= stick_to) begin
        release main_board.flight_controls.stick_x_value;
        stick_forced = 0;
    end
end

// ---- memories -----------------------------------------------------------
always @(posedge clk)
    dsp_prog_data <= {rom[24'h0d0000 + {dsp_prog_addr, 1'b0}],
                      rom[24'h0d0000 + {dsp_prog_addr, 1'b1}]};

reg rom_busy = 0;
always @(posedge clk) begin
    rom_ack <= 1'b0;
    if (!rom_req) rom_busy <= 1'b0;
    else if (!rom_busy) begin
        rom_busy <= 1'b1;
        rom_data <= {rom[{rom_addr[23:1], 1'b0}], rom[{rom_addr[23:1], 1'b1}]};
        rom_ack <= 1'b1;
    end
end

// Graphics ROM: take a request when idle, answer with a one-clock ack two
// clocks later, then ignore req for the clock in which the renderer reacts
// to the ack (it drops req then, and may raise it again for a new address
// on the following clock).
always @(posedge clk) begin
    gfx_ack <= 1'b0;
    if (!gfx_pending) begin
        if (gfx_req && !gfx_ack) begin
            gfx_pending <= 1'b1;
            gfx_delay <= 3'd2;
            gfx_latched_addr <= gfx_addr;
        end
    end else if (gfx_delay != 0) begin
        gfx_delay <= gfx_delay - 1'd1;
    end else begin
        gfx_data <= {
            rom[24'h100000 + gfx_latched_addr + 7], rom[24'h100000 + gfx_latched_addr + 6],
            rom[24'h100000 + gfx_latched_addr + 5], rom[24'h100000 + gfx_latched_addr + 4],
            rom[24'h100000 + gfx_latched_addr + 3], rom[24'h100000 + gfx_latched_addr + 2],
            rom[24'h100000 + gfx_latched_addr + 1], rom[24'h100000 + gfx_latched_addr]
        };
        gfx_ack <= 1'b1;
        gfx_pending <= 1'b0;
    end
end

// ---- frame capture ------------------------------------------------------
integer frame_every = 0;
integer frame_from = 0;
string frame_prefix;
reg [23:0] pixels [0:640*480-1];
integer px = 0, py = 0, width = 0, height = 0;
reg hblank_d = 0, vblank_d = 0;
integer fh, i;
task automatic write_frame(input integer n);
begin
    fh = $fopen($sformatf("%s%05d.ppm", frame_prefix, n), "wb");
    $fwrite(fh, "P6\n%0d %0d\n255\n", width, height);
    for (i = 0; i < width * height; i = i + 1)
        $fwrite(fh, "%c%c%c", pixels[(i / width) * 640 + (i % width)][23:16],
                pixels[(i / width) * 640 + (i % width)][15:8],
                pixels[(i / width) * 640 + (i % width)][7:0]);
    $fclose(fh);
end
endtask

always @(posedge clk) begin
    vblank_d <= vblank;
    if (ce_pix) begin
        hblank_d <= hblank;
        if (!hblank && !vblank) begin
            if (px < 640 && py < 480) pixels[py * 640 + px] <= {red, green, blue};
            px <= px + 1;
        end
        if (hblank && !hblank_d && !vblank) begin
            if (px > width) width <= px;
            px <= 0;
            py <= py + 1;
        end
    end
    if (vblank && !vblank_d) begin
        if (py > height) height <= py;
        if (frame_every > 0 && frame >= frame_from && (frame % frame_every) == 0 && height > 0)
        begin
            write_frame(frame);
            if (pen_dump) write_pens(frame);
        end
        frame <= frame + 1;
        py <= 0;
        px <= 0;
        if (frame % 50 == 0)
            $display("frame %0d fetch=%06h dsp_instr=%0d illegal=%0d", frame,
                     debug_fetch_addr, debug_dsp_instructions, debug_dsp_illegal);
    end
end

// ---- left-edge probe: the sources of the first three pixels of line 10 in
// the first dumped frame
always @(posedge clk) if (frame == frame_from && game_video.ce_pix &&
                          game_video.vcount == 10'd10 && game_video.hcount < 10'd3)
    $display("PROBE x=%0d tile_fg=%0d display_pixel=%03h line_valid=%0d poly_valid=%0d poly=%04h",
             game_video.hcount, game_video.tile_foreground, game_video.display_pixel,
             game_video.display_line_valid, game_video.polygon_pixel_valid,
             game_video.polygon_pixel);

// ---- DSP headroom: clocks the C25 spends in its wait-for-68000 loop (0D31)
longint spin_clocks = 0, spin_frame = 0;
always @(posedge clk) begin
    if (main_board.dsp_subsystem.cpu.pc == 16'h0d31 || main_board.dsp_subsystem.cpu.pc == 16'h0d32)
        spin_clocks <= spin_clocks + 1;
    if (vblank && !vblank_d) begin
        if (frame % 10 == 0 && frame >= 300)
            $display("frame %0d DSP idle %0d%% of the last 10 frames", frame,
                     (spin_clocks - spin_frame) * 100 / (10 * 591360));
        if (frame % 10 == 0) spin_frame <= spin_clocks;
    end
end

// ---- C25 time per list (+LIST_TIMING): at each 0x3001 write, where in the
// frame it came and how the C25's clocks since the previous one were spent
reg list_timing = 0;
initial list_timing = $test$plusargs("LIST_TIMING");
longint lt_clocks = 0, lt_blocked = 0, lt_held = 0, lt_spin = 0, lt_busy = 0;
always @(posedge clk) if (list_timing) begin
    lt_clocks <= lt_clocks + 1;
    if (main_board.dsp_subsystem.core_req && main_board.dsp_subsystem.line_blocked &&
        !main_board.dsp_subsystem.busy)
        lt_blocked <= lt_blocked + 1;
    if (main_board.dsp_subsystem.hold) lt_held <= lt_held + 1;
    if (video_polygon_hold) lt_busy <= lt_busy + 1;
    if (main_board.dsp_subsystem.cpu.pc == 16'h0d31 || main_board.dsp_subsystem.cpu.pc == 16'h0d32)
        lt_spin <= lt_spin + 1;
    if (dsp_flag_strobe[1]) begin
        $display("LIST f%0d v%0d clocks %0d blocked %0d held %0d spin %0d renderer_busy %0d",
                 frame, game_video.vcount, lt_clocks, lt_blocked, lt_held, lt_spin, lt_busy);
        lt_clocks <= 0; lt_blocked <= 0; lt_held <= 0; lt_spin <= 0; lt_busy <= 0;
    end
end

// ---- polygon layer pens (+PEN_DUMP): 512x400 little-endian u16 per written
// frame, 0 = transparent, else the renderer's 14-bit pen
reg pen_dump = 0;
reg [15:0] pens [0:512*400-1];
always @(posedge clk) if (pen_dump && game_video.ce_pix &&
                          game_video.hcount < 512 && game_video.vcount < 400)
    pens[game_video.vcount * 512 + game_video.hcount] <=
        game_video.polygon_pixel_valid ? {2'b00, game_video.polygon_pixel} : 16'd0;
task automatic write_pens(input integer n);
integer ph, k;
begin
    ph = $fopen($sformatf("%s%05d.pen", frame_prefix, n), "wb");
    for (k = 0; k < 512 * 400; k = k + 1) $fwrite(ph, "%c%c", pens[k][7:0], pens[k][15:8]);
    $fclose(ph);
end
endtask

// ---- polygon list dump (same format as the MAME Lua capture) ------------
integer poly_dump_file = 0;
integer poly_events = 0;
string poly_dump_path;
function automatic [15:0] lram(input integer a);
    lram = main_board.line_ram.g_dual.mem[a[13:0]];
endfunction
task automatic dump_polys(input integer flag);
integer adr, pc, n;
reg [15:0] hdr;
string line, pts;
begin
    n = 0;
    poly_events = poly_events + 1;
    $fwrite(poly_dump_file, "E %0d f%0d flag%0d\n", poly_events, frame, flag);
    if (lram(16'h3fff) != 0) begin
        adr = 16'h3fff;
        while (adr >= 0 && lram(adr) != 0 && lram(adr) != 16'h4000) begin
            hdr = lram(adr); adr = adr - 1;
            pts = ""; pc = 0;
            while (pc < 16 && adr >= 1 && (lram(adr) & 16'hc000) == 0) begin
                pts = {pts, $sformatf("%s%0d,%0d", pc ? " " : "", lram(adr - 1), lram(adr))};
                adr = adr - 2; pc = pc + 1;
            end
            adr = adr - 1;
            line = "";
            if ((lram(adr) & 16'h8000) == 0) begin
                line = " S";
                while (adr >= 0 && (lram(adr) & 16'hc000) == 0) adr = adr - 1;
            end
            $fwrite(poly_dump_file, "  %04h%s:%s\n", hdr, line, pts);
            n = n + 1;
        end
    end
    $fwrite(poly_dump_file, "N %0d\n", n);
    $fflush(poly_dump_file);
end
endtask
// Which polygon list event is on screen: a copy publishes the list built
// since the previous one and starts building the newest.
integer building_event = 0, displayed_event = 0;
reg active_bank_d = 0;
always @(posedge clk) begin
    active_bank_d <= game_video.polygon_renderer.active_bank;
    if (game_video.polygon_renderer.active_bank != active_bank_d) begin
        displayed_event <= building_event;
        building_event <= poly_events;
    end
end
always @(posedge clk) if (vblank && !vblank_d && poly_dump_file) begin
    $fwrite(poly_dump_file, "FRAME %0d shows %0d\n", frame, displayed_event);
end

always @(posedge clk) begin
    if (poly_dump_file && dsp_flag_strobe[1]) dump_polys(1);
    if (poly_dump_file && dsp_flag_strobe[2]) dump_polys(2);
end

string rom_path;
integer rom_file, rom_bytes;
longint cycles = 200000000;
initial begin
    if (!$value$plusargs("ROM=%s", rom_path)) rom_path = "roms/ainferno.rom";
    void'($value$plusargs("CYCLES=%d", cycles));
    void'($value$plusargs("FRAME_EVERY=%d", frame_every));
    void'($value$plusargs("FRAME_FROM=%d", frame_from));
    void'($value$plusargs("COIN_AT=%d", coin_at));
    void'($value$plusargs("START_AT=%d", start_at));
    void'($value$plusargs("START2_AT=%d", start2_at));
    void'($value$plusargs("START3_AT=%d", start3_at));
    if (!$value$plusargs("FRAME_PREFIX=%s", frame_prefix)) frame_prefix = "frame_";
    pen_dump = $test$plusargs("PEN_DUMP");
    if ($value$plusargs("POLY_DUMP=%s", poly_dump_path))
        poly_dump_file = $fopen(poly_dump_path, "w");
    for (i = 0; i <= 24'h2cffff; i = i + 1) rom[i] = 8'hff;
    rom_file = $fopen(rom_path, "rb");
    if (!rom_file) $fatal(1, "cannot open ROM image %s", rom_path);
    rom_bytes = $fread(rom, rom_file);
    $fclose(rom_file);
    $display("ROM %s: %0d bytes", rom_path, rom_bytes);
    repeat (8) @(negedge clk);
    reset = 0;
    repeat (cycles) @(negedge clk);
    $display("END frame=%0d dsp_instr=%0d illegal=%0d", frame,
             debug_dsp_instructions, debug_dsp_illegal);
    $finish;
end

endmodule
