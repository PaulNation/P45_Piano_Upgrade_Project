module velocity_addr_gen #(
    parameter NUM_KEYS   = 90,
    parameter ADDR_WIDTH = 7
) (
    input  wire                    clk,
    input  wire                    rst,
    output reg  [ADDR_WIDTH-1:0]   addr
);

    // Free-running scan counter: wraps 0 .. NUM_KEYS-1, advancing every clock.
    // No row-settle wait is needed here (unlike activate_rows) since this just
    // drives RAM read addresses rather than physical matrix row drivers.
    always @(posedge clk or posedge rst) begin
        if (rst)
            addr <= {ADDR_WIDTH{1'b0}};
        else if (addr == NUM_KEYS-1)
            addr <= {ADDR_WIDTH{1'b0}};
        else
            addr <= addr + 1'b1;
    end

endmodule
