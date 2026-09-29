// Optional 512x400 control overlay for the yoke and set-and-hold throttle.
// It is deliberately transparent outside the compact right-edge instruments
// and is disabled by default at the MiSTer menu boundary.
//
// [AI-9] Scaled to Air Inferno's control ranges when game_ainferno is set
// (docs/air-inferno-changes.md).
module tas_throttle_overlay (
    input              enable,
    input              game_ainferno,   // [AI-9]
    input      [9:0]   x,
    input      [9:0]   y,
    input      [11:0]  throttle_counter,
    input      [11:0]  stick_x_counter,
    input      [11:0]  stick_y_counter,
    output reg         draw,
    output reg [7:0]   red,
    output reg [7:0]   green,
    output reg [7:0]   blue
);

// Top Landing's program reaches its normalized limits at the much smaller
// physical counter ranges -39..+40 (throttle), -47..+48 (X), and -32..+32
// (Y). Scale those calibrated endpoints across the complete overlay rails.
// Shift/add scaling avoids divider and DSP hardware while preserving every
// intermediate counter position and both exact end pixels.
wire signed [12:0] throttle_offset =
    $signed({throttle_counter[11], throttle_counter}) + 13'sd39;
wire [10:0] throttle_level_product =
    ({4'd0, throttle_offset[6:0]} << 3) +
    ({4'd0, throttle_offset[6:0]} << 2) +
    {4'd0, throttle_offset[6:0]};
// Top Landing's levels (the *_tl names are [AI-9]'s; see below)
wire [6:0] throttle_level_tl = throttle_offset <= 0 ? 7'd0 :
                               throttle_offset >= 13'sd79 ? 7'd127 :
                               throttle_level_product[9:3];
wire signed [12:0] stick_x_offset =
    $signed({stick_x_counter[11], stick_x_counter}) + 13'sd47;
wire [12:0] stick_x_level_product =
    ({6'd0, stick_x_offset[6:0]} << 5) +
    ({6'd0, stick_x_offset[6:0]} << 3) +
    ({6'd0, stick_x_offset[6:0]} << 1) +
    {6'd0, stick_x_offset[6:0]};
wire [5:0] stick_x_level_tl = stick_x_offset <= 0 ? 6'd0 :
                              stick_x_offset >= 13'sd95 ? 6'd63 :
                              stick_x_level_product[11:6];
wire signed [12:0] stick_y_offset =
    $signed({stick_y_counter[11], stick_y_counter}) + 13'sd32;
wire [5:0] stick_y_level_tl = stick_y_offset <= 0 ? 6'd0 :
                              stick_y_offset >= 13'sd64 ? 6'd63 :
                              stick_y_offset[5:0];

// [AI-9] Air Inferno's ranges (see tas_flight_controls): throttle -56..+56 scaled
// by 9/8 onto the 127-step rail, yoke -27..+27 scaled by 75/64 onto 63.
wire signed [12:0] ai_throttle_offset =
    $signed({throttle_counter[11], throttle_counter}) + 13'sd56;
wire [10:0] ai_throttle_product =
    ({4'd0, ai_throttle_offset[6:0]} << 3) + {4'd0, ai_throttle_offset[6:0]};
wire [6:0] throttle_level_ai = ai_throttle_offset <= 0 ? 7'd0 :
                               ai_throttle_offset >= 13'sd112 ? 7'd127 :
                               ai_throttle_product[9:3];
function automatic [5:0] ai_yoke_level(input [11:0] counter);
    reg signed [12:0] offset;
    reg [12:0] product;
begin
    offset = $signed({counter[11], counter}) + 13'sd27;
    product = ({6'd0, offset[6:0]} << 6) + ({6'd0, offset[6:0]} << 3) +
              ({6'd0, offset[6:0]} << 1) + {6'd0, offset[6:0]};
    ai_yoke_level = offset <= 0 ? 6'd0 :
                    offset >= 13'sd54 ? 6'd63 : product[11:6];
end
endfunction

// [AI-9] per-game levels (the *_tl levels are the original Top Landing ones)
wire [6:0] throttle_level = game_ainferno ? throttle_level_ai : throttle_level_tl;
wire [9:0] marker_y = 10'd130 + {3'd0, throttle_level};
wire [5:0] stick_x_level = game_ainferno ? ai_yoke_level(stick_x_counter) : stick_x_level_tl;
wire [5:0] stick_y_level = game_ainferno ? ai_yoke_level(stick_y_counter) : stick_y_level_tl;
wire [9:0] yoke_marker_x = 10'd422 + {4'd0, stick_x_level};
wire [9:0] yoke_marker_y = 10'd163 + {4'd0, stick_y_level};

wire label_pixel =
    ((y >= 10'd112 && y <= 10'd115) && x >= 10'd494 && x <= 10'd505) ||
    ((y >= 10'd116 && y <= 10'd123) && x >= 10'd498 && x <= 10'd501);
wire border_pixel =
    ((x == 10'd492 || x == 10'd507) && y >= 10'd128 && y <= 10'd259) ||
    ((y == 10'd128 || y == 10'd259) && x >= 10'd492 && x <= 10'd507);
wire center_tick = y == 10'd194 &&
    ((x >= 10'd490 && x <= 10'd492) ||
     (x >= 10'd507 && x <= 10'd509));
wire fill_pixel = x >= 10'd496 && x <= 10'd503 &&
                  y >= marker_y && y <= 10'd257;
wire marker_pixel = x >= 10'd490 && x <= 10'd509 &&
                    y >= marker_y && y <= marker_y + 1'd1;
wire yoke_label_pixel =
    ((y >= 10'd144 && y <= 10'd147) &&
     ((x >= 10'd444 && x <= 10'd447) ||
      (x >= 10'd456 && x <= 10'd459))) ||
    ((y >= 10'd148 && y <= 10'd151) && x >= 10'd448 && x <= 10'd455) ||
    ((y >= 10'd152 && y <= 10'd159) && x >= 10'd450 && x <= 10'd453);
wire yoke_border_pixel =
    ((x == 10'd420 || x == 10'd487) && y >= 10'd161 && y <= 10'd228) ||
    ((y == 10'd161 || y == 10'd228) && x >= 10'd420 && x <= 10'd487);
wire yoke_center_tick =
    ((y == 10'd195) &&
     ((x >= 10'd421 && x <= 10'd425) ||
      (x >= 10'd482 && x <= 10'd486))) ||
    ((x == 10'd454) &&
     ((y >= 10'd162 && y <= 10'd166) ||
      (y >= 10'd223 && y <= 10'd227)));
wire yoke_marker_pixel =
    x + 1'd1 >= yoke_marker_x && x <= yoke_marker_x + 1'd1 &&
    y + 1'd1 >= yoke_marker_y && y <= yoke_marker_y + 1'd1;

always @* begin
    draw = enable &&
           (label_pixel || border_pixel || center_tick ||
            fill_pixel || marker_pixel || yoke_label_pixel ||
            yoke_border_pixel || yoke_center_tick || yoke_marker_pixel);
    red = 8'h00;
    green = 8'h00;
    blue = 8'h00;

    if (fill_pixel) begin
        red = 8'h20;
        green = 8'hc0;
        blue = 8'h40;
    end
    if (center_tick) begin
        red = 8'ha0;
        green = 8'ha0;
        blue = 8'ha0;
    end
    if (border_pixel) begin
        red = 8'he0;
        green = 8'he0;
        blue = 8'he0;
    end
    if (label_pixel) begin
        red = 8'h20;
        green = 8'hd8;
        blue = 8'hff;
    end
    if (yoke_label_pixel) begin
        red = 8'h20;
        green = 8'hd8;
        blue = 8'hff;
    end
    if (yoke_center_tick) begin
        red = 8'ha0;
        green = 8'ha0;
        blue = 8'ha0;
    end
    if (yoke_border_pixel) begin
        red = 8'he0;
        green = 8'he0;
        blue = 8'he0;
    end
    if (marker_pixel || yoke_marker_pixel) begin
        red = 8'hff;
        green = 8'hc0;
        blue = 8'h00;
    end
end

endmodule
