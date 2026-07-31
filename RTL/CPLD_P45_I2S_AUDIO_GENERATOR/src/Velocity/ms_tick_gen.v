module ms_tick_gen #(
    parameter CLK_FREQ_HZ = 48_000_000
) (
    input  wire clk,
    input  wire rst,
    output reg  tick_1ms
);

    localparam DIV_MAX = CLK_FREQ_HZ / 1000;
    localparam CNT_W    = $clog2(DIV_MAX);

    reg [CNT_W-1:0] cnt;

    // 1. Free-running divide-by-DIV_MAX counter
    always @(posedge clk or posedge rst) begin
        if (rst)
            cnt <= {CNT_W{1'b0}};
        else if (cnt == DIV_MAX-1)
            cnt <= {CNT_W{1'b0}};
        else
            cnt <= cnt + 1'b1;
    end

    // 2. Single-cycle tick pulse, one clock after the counter wraps
    always @(posedge clk or posedge rst) begin
        if (rst)
            tick_1ms <= 1'b0;
        else
            tick_1ms <= (cnt == DIV_MAX-1);
    end

endmodule
