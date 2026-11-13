// uart_tx.v — 8N1 UART transmitter (MIDI: 31,250 baud). Line idles high.
module uart_tx #(
    parameter CLKS_PER_BIT = 384               // 12 MHz / 31,250 baud
) (
    input  wire       clk,
    input  wire       rst,
    input  wire       start,                   // load data when !busy
    input  wire [7:0] data,
    output reg        tx,
    output wire       busy
);

    localparam CNT_W = $clog2(CLKS_PER_BIT);

    reg [9:0]       shreg;                     // {stop, data[7:0], start}
    reg [3:0]       bits_left;
    reg [CNT_W-1:0] cnt;

    assign busy = (bits_left != 0);

    always @(posedge clk or posedge rst) begin
        if (rst) begin
            tx        <= 1'b1;
            shreg     <= 10'h3FF;
            bits_left <= 4'd0;
            cnt       <= 0;
        end else if (!busy) begin
            tx <= 1'b1;
            if (start) begin
                shreg     <= {1'b1, data, 1'b0};
                bits_left <= 4'd10;
                cnt       <= 0;
                tx        <= 1'b0;               // start bit goes out now
            end
        end else if (cnt == CLKS_PER_BIT - 1) begin
            cnt       <= 0;
            shreg     <= {1'b1, shreg[9:1]};
            bits_left <= bits_left - 1'b1;
            tx        <= (bits_left == 4'd1) ? 1'b1 : shreg[1];
        end else begin
            cnt <= cnt + 1'b1;
        end
    end

endmodule
