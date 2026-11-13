// reset_sync.v — asynchronous assert, synchronous de-assert reset for one clock domain.
// rst_in may come from any domain (or a pin); rst_out is safe to use as the async
// reset of every flop clocked by clk (it releases on a clk edge).
module reset_sync #(
    parameter STAGES = 2
) (
    input  wire clk,
    input  wire rst_in,     // active high, asynchronous
    output wire rst_out     // active high, de-asserts synchronously to clk
);

    /* verilator lint_off SYNCASYNCNET */   // intended: this is the reset synchronizer
    reg [STAGES-1:0] sr;
    /* verilator lint_on SYNCASYNCNET */

    always @(posedge clk or posedge rst_in) begin
        if (rst_in)
            sr <= {STAGES{1'b1}};
        else
            sr <= {sr[STAGES-2:0], 1'b0};
    end

    assign rst_out = sr[STAGES-1];

endmodule
