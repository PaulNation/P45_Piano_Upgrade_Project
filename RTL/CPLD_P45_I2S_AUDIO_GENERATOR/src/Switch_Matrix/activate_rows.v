module activate_rows #(
    parameter NUM_ROWS = 15
) (
    input  wire                          clk,
    input  wire                          rst,
    input  wire                          next_row,   // pulse: advance to the next row
    output reg  [$clog2(NUM_ROWS)-1:0]   row_index,
    output wire [NUM_ROWS-1:0]           row_en      // one-hot, active-high row enable
);

    // Row counter: wraps 0 .. NUM_ROWS-1
    always @(posedge clk or posedge rst) begin
        if (rst)
            row_index <= {$clog2(NUM_ROWS){1'b0}};
        else if (next_row) begin
            if (row_index == NUM_ROWS-1)
                row_index <= {$clog2(NUM_ROWS){1'b0}};
            else
                row_index <= row_index + 1'b1;
        end
    end

    // One-hot decode of the current row
    assign row_en = {{(NUM_ROWS-1){1'b0}}, 1'b1} << row_index;

endmodule
