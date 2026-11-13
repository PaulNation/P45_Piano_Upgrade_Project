// tick_gen.v — one-clock pulse every DIV clocks (e.g. 1 us ticks from the control clock).
module tick_gen #(
    parameter DIV = 12                         // 12 MHz / 12 = 1 MHz -> 1 us
) (
    input  wire clk,
    input  wire rst,
    output reg  tick
);

    localparam CNT_W = (DIV > 1) ? $clog2(DIV) : 1;
    reg [CNT_W-1:0] cnt;

    always @(posedge clk or posedge rst) begin
        if (rst) begin
            cnt  <= 0;
            tick <= 1'b0;
        end else begin
            tick <= (cnt == DIV-1);
            cnt  <= (cnt == DIV-1) ? {CNT_W{1'b0}} : cnt + 1'b1;
        end
    end

endmodule
