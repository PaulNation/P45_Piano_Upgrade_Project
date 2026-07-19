module sync_2ff #(
    parameter WIDTH = 6
) (
    input  wire             clk,
    input  wire             rst,
    input  wire [WIDTH-1:0] din,
    output reg  [WIDTH-1:0] dout
);

    reg [WIDTH-1:0] meta;

    // Two flip-flop synchronizer for the asynchronous column inputs
    always @(posedge clk or posedge rst) begin
        if (rst) begin
            meta <= {WIDTH{1'b0}};
            dout <= {WIDTH{1'b0}};
        end else begin
            meta <= din;
            dout <= meta;
        end
    end

endmodule
