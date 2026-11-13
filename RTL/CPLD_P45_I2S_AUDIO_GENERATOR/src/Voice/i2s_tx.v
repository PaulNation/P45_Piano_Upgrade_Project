// i2s_tx.v — I2S (Philips) output, 16-bit samples in 32-bit slots, same sample on L and R.
// Clocked by the audio clock (45.1584 MHz), locked to voice_engine's 1024-clock period:
//   MCLK  = clk / 4   = 11.2896 MHz (256 fs)
//   BCLK  = clk / 16  =  2.8224 MHz (64 fs)
//   LRCLK = clk / 1024 = 44.1 kHz (low = left)
// Data changes on the BCLK falling edge, MSB one BCLK after each LRCLK edge (I2S standard).
// `sample` is taken at sample_tick (the start of the frame).
module i2s_tx (
    input  wire        clk,
    input  wire        rst,
    input  wire        sample_tick,      // from voice_engine: clock 0 of the period
    input  wire [15:0] sample,
    output wire        MCLK,
    output reg         BCLK,
    output reg         LRCLK,
    output reg         DOUT
);

    reg [9:0]  cnt;                      // 0..1023 within the frame, 0 = sample_tick
    reg [15:0] word;
    reg [1:0]  mdiv;

    assign MCLK = mdiv[1];

    wire [5:0] slot = cnt[9:4];          // BCLK cycle 0..63

    wire        bclk_nx = (cnt[3:0] >= 4'd7) && (cnt[3:0] != 4'd15);   // bit 3 of cnt+1
    // next BCLK slot (starts at a falling edge of BCLK) and the bit it carries
    wire [5:0]  ns   = sample_tick ? 6'd0 : slot + 6'd1;
    wire [4:0]  np   = ns[4:0];
    wire [15:0] src  = sample_tick ? sample : word;
    wire [3:0]  bidx = 4'd15 - (np[3:0] - 4'd1);     // np 1..16 -> bit 15..0
    wire        nbit = (np >= 5'd1 && np <= 5'd16) ? src[bidx] : 1'b0;

    always @(posedge clk or posedge rst) begin
        if (rst) begin
            cnt <= 0; word <= 0; mdiv <= 0; BCLK <= 1'b0; LRCLK <= 1'b0; DOUT <= 1'b0;
        end else begin
            mdiv <= mdiv + 2'd1;
            cnt  <= sample_tick ? 10'd1 : cnt + 10'd1;
            if (sample_tick) word <= sample;
            BCLK <= sample_tick ? 1'b0 : bclk_nx;          // low for clocks 0..7 of each slot
            if (sample_tick || cnt[3:0] == 4'd15) begin
                LRCLK <= ns[5];
                DOUT  <= nbit;
            end
        end
    end

endmodule
