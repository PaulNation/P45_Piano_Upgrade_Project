module key_address_encoder #(
    parameter NUM_COLS   = 6,
    parameter ADDR_WIDTH = 7
) (
    input  wire [3:0]            row_index,
    input  wire [2:0]            col_index,
    input  wire                  col_m1_bit,
    input  wire                  col_m2_bit,

    output wire [ADDR_WIDTH-1:0] addr,       // 0 -> A0, sequential row-major
    output wire [1:0]            key_data    // {M2 contact, M1 contact}
);

    assign addr     = row_index * NUM_COLS + {{(ADDR_WIDTH-3){1'b0}}, col_index};
    assign key_data = {col_m2_bit, col_m1_bit};

endmodule
