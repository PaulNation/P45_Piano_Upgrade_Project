module scan_columns #(
    parameter NUM_COLS = 6
) (
    input  wire                          clk,
    input  wire                          rst,

    // Raw switch matrix column inputs (asynchronous to clk)
    input  wire [NUM_COLS-1:0]           col_in_m1,
    input  wire [NUM_COLS-1:0]           col_in_m2,

    // Which column the FSM currently wants read out
    input  wire [$clog2(NUM_COLS)-1:0]   col_index,

    // Synchronized bit for the selected column
    output wire                          col_m1_bit,
    output wire                          col_m2_bit
);

    wire [NUM_COLS-1:0] synced_m1;
    wire [NUM_COLS-1:0] synced_m2;

    sync_2ff #(
        .WIDTH (NUM_COLS)
    ) sync_m1_inst (
        .clk  (clk),
        .rst  (rst),
        .din  (col_in_m1),
        .dout (synced_m1)
    );

    sync_2ff #(
        .WIDTH (NUM_COLS)
    ) sync_m2_inst (
        .clk  (clk),
        .rst  (rst),
        .din  (col_in_m2),
        .dout (synced_m2)
    );

    assign col_m1_bit = synced_m1[col_index];
    assign col_m2_bit = synced_m2[col_index];

endmodule
