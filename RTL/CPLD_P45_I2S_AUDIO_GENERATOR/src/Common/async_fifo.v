// async_fifo.v — dual-clock FIFO with Gray-coded pointers (Cummings style).
// Carries key/pedal events from the control clock domain to the audio clock domain.
//   * DEPTH = 2^ADDR_W words; pointers are ADDR_W+1 bits (extra wrap bit).
//   * Each side sees the other side's pointer through a 2-flop synchronizer, so
//     wr_full and rd_empty are pessimistic (never wrong, may be late by 2-3 clocks).
//   * Show-ahead read: rd_data is valid whenever rd_empty is low; rd_en pops it.
module async_fifo #(
    parameter DATA_W = 16,
    parameter ADDR_W = 4                       // 16 entries
) (
    // write side (control domain)
    input  wire              wr_clk,
    input  wire              wr_rst,           // synchronous to wr_clk (from reset_sync)
    input  wire              wr_en,
    input  wire [DATA_W-1:0] wr_data,
    output reg               wr_full,

    // read side (audio domain)
    input  wire              rd_clk,
    input  wire              rd_rst,           // synchronous to rd_clk (from reset_sync)
    input  wire              rd_en,
    output wire [DATA_W-1:0] rd_data,
    output reg               rd_empty
);

    localparam DEPTH = 1 << ADDR_W;

    reg [DATA_W-1:0] mem [0:DEPTH-1];

    reg [ADDR_W:0] wr_bin, wr_gray, rd_bin, rd_gray;
    reg [ADDR_W:0] rd_gray_w1, rd_gray_w2;     // read pointer in the write domain
    reg [ADDR_W:0] wr_gray_r1, wr_gray_r2;     // write pointer in the read domain

    // ---------------- write domain
    wire              wr_do       = wr_en & ~wr_full;
    wire [ADDR_W:0]   wr_bin_nxt  = wr_bin + wr_do;
    wire [ADDR_W:0]   wr_gray_nxt = (wr_bin_nxt >> 1) ^ wr_bin_nxt;
    // full: next write pointer equals the read pointer with the two MSBs inverted
    wire              full_nxt    = (wr_gray_nxt == {~rd_gray_w2[ADDR_W:ADDR_W-1], rd_gray_w2[ADDR_W-2:0]});

    always @(posedge wr_clk) begin
        if (wr_do)
            mem[wr_bin[ADDR_W-1:0]] <= wr_data;
    end

    always @(posedge wr_clk or posedge wr_rst) begin
        if (wr_rst) begin
            wr_bin     <= 0;
            wr_gray    <= 0;
            wr_full    <= 1'b0;
            rd_gray_w1 <= 0;
            rd_gray_w2 <= 0;
        end else begin
            wr_bin     <= wr_bin_nxt;
            wr_gray    <= wr_gray_nxt;
            wr_full    <= full_nxt;
            rd_gray_w1 <= rd_gray;
            rd_gray_w2 <= rd_gray_w1;
        end
    end

    // ---------------- read domain
    wire              rd_do       = rd_en & ~rd_empty;
    wire [ADDR_W:0]   rd_bin_nxt  = rd_bin + rd_do;
    wire [ADDR_W:0]   rd_gray_nxt = (rd_bin_nxt >> 1) ^ rd_bin_nxt;
    wire              empty_nxt   = (rd_gray_nxt == wr_gray_r2);

    assign rd_data = mem[rd_bin[ADDR_W-1:0]];

    always @(posedge rd_clk or posedge rd_rst) begin
        if (rd_rst) begin
            rd_bin     <= 0;
            rd_gray    <= 0;
            rd_empty   <= 1'b1;
            wr_gray_r1 <= 0;
            wr_gray_r2 <= 0;
        end else begin
            rd_bin     <= rd_bin_nxt;
            rd_gray    <= rd_gray_nxt;
            rd_empty   <= empty_nxt;
            wr_gray_r1 <= wr_gray;
            wr_gray_r2 <= wr_gray_r1;
        end
    end

endmodule
