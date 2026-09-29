// Separate ROM transfers from auxiliary MRA payloads.  MiSTer sends arcade
// DIP switches as an ioctl download at index 254; that transfer must not clear
// ROM-loaded state or reset the emulated board.
//
// [AI-8] Also decides which game was loaded (game_ainferno); see
// docs/air-inferno-changes.md.
module tas_download_control #(
    // [AI-8] Fletcher checksum ({sum1, sum2}, both mod 2^16) of Air
    // Inferno's 8 KB C25 program as streamed at index 1 (the same in all
    // three sets)
    parameter [31:0] AINFERNO_DSP_SUM = 32'h18b5bd99
) (
    input              clk,
    input              reset_hw,
    input              reset_sys,
    input              ioctl_download,
    input      [15:0]  ioctl_index,
    input              ioctl_wr,        // [AI-8]
    input      [26:0]  ioctl_addr,      // [AI-8]
    input      [7:0]   ioctl_dout,      // [AI-8]
    output             rom_download,
    output reg         rom_loaded,
    output             board_reset,
    output reg         game_ainferno    // [AI-8] 0 Top Landing, 1 Air Inferno
);

// [AI-8] Which game the MRA loaded. Air Inferno's MRAs carry a one-byte ROM entry at
// index 2 (1 = Air Inferno, 0 = Top Landing). MRAs without it are recognised
// by the C25 program they stream at index 1. The index 2 byte follows index 1
// in the MRAs, so it has the last word when present; the main ROM (index 0)
// comes first and starts every load out as Top Landing.
// The selection only changes with a ROM load (not with a reset).
reg [15:0] dsp_sum1 = 16'd0;
reg [15:0] dsp_sum2 = 16'd0;
reg dsp_download_d = 1'b0;
initial game_ainferno = 1'b0;
wire [15:0] dsp_sum1_next = dsp_sum1 + {8'd0, ioctl_dout};
always @(posedge clk) begin
    dsp_download_d <= ioctl_download && ioctl_index == 16'd1;
    if (ioctl_download && ioctl_index == 16'd0) begin
        game_ainferno <= 1'b0;
    end else if (ioctl_download && ioctl_index == 16'd1) begin
        if (!dsp_download_d) begin
            dsp_sum1 <= 16'd0;
            dsp_sum2 <= 16'd0;
        end else if (ioctl_wr) begin
            dsp_sum1 <= dsp_sum1_next;
            dsp_sum2 <= dsp_sum2 + dsp_sum1_next;
        end
    end else if (dsp_download_d) begin
        game_ainferno <= {dsp_sum1, dsp_sum2} == AINFERNO_DSP_SUM;
    end else if (ioctl_wr && ioctl_download && ioctl_index == 16'd2 &&
                 ioctl_addr == 27'd0) begin
        game_ainferno <= ioctl_dout == 8'd1;
    end
end

// Index 0 is the DDR image, 1 the C25 program and 2 the game-select byte
// ([AI-8]; a ROM entry, so it holds the board in reset like the others).
assign rom_download = ioctl_download &&
    ((ioctl_index == 16'd0) || (ioctl_index == 16'd1) || (ioctl_index == 16'd2));

reg old_rom_download;
always @(posedge clk) begin
    if (reset_hw) begin
        old_rom_download <= 1'b0;
        rom_loaded <= 1'b0;
    end else begin
        old_rom_download <= rom_download;
        if (rom_download)
            rom_loaded <= 1'b0;
        else if (old_rom_download)
            rom_loaded <= 1'b1;
    end
end

assign board_reset = reset_sys | !rom_loaded | rom_download;

endmodule
