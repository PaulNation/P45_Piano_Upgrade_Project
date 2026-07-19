module scan_keys_controller #(
    parameter NUM_ROWS          = 15,
    parameter NUM_COLS          = 6,
    parameter NUM_KEYS          = 90, // The matrix has NUM_ROWS*NUM_COLS = 90 addressable slots but there are actually only 88 keys,
                                      // so this gates the RAM write guard to valid addresses 0..87. The first key is in row = 0 and col_in_m1[2] and col_in_m2[2]
                                      // No switches: row = 0 and col_in_m1[1:0] and col_in_m2[1:0] are not being used.
                                      // The first key is A-1 (the dash is minus 1) -> row = 0 and col_in_m1[2] and col_in_m2[2], then A#-1, then B-1, then C0 -> row = 0 and col_in_m1[5] and col_in_m2[5]
                                      // Then C#0 -> row = 1 and col_in_m1[0] and col_in_m2[0]
    parameter ADDR_WIDTH        = 7,
    parameter ROW_SETTLE_CYCLES = 4   // >= 2 (2FF sync latency) + margin for row driver settle
) (
    input  wire                    clk,
    input  wire                    rst,

    // Switch matrix
    output wire [NUM_ROWS-1:0]     row_en,     // one-hot, active-high
    input  wire [NUM_COLS-1:0]     col_in_m1,
    input  wire [NUM_COLS-1:0]     col_in_m2,

    // RAM write port
    output reg                     wea,
    output reg  [ADDR_WIDTH-1:0]   addra,
    output reg  [1:0]              dia
);

    localparam ROW_IDX_W = $clog2(NUM_ROWS);
    localparam COL_IDX_W = $clog2(NUM_COLS);

    // FSM states
    localparam STATE_IDLE       = 2'd0;
    localparam STATE_ROW_SETTLE = 2'd1;
    localparam STATE_SCAN_COL   = 2'd2;
    localparam STATE_NEXT_ROW   = 2'd3;

    reg [1:0] state, next_state;
    reg [$clog2(ROW_SETTLE_CYCLES+1)-1:0] settle_cnt;
    reg [COL_IDX_W-1:0] col_index;
    reg next_row_pulse;

    wire [ROW_IDX_W-1:0]   row_index;
    wire                   col_m1_bit, col_m2_bit;
    wire [ADDR_WIDTH-1:0]  key_addr;
    wire [1:0]             key_data;

    activate_rows #(
        .NUM_ROWS (NUM_ROWS)
    ) u_activate_rows (
        .clk       (clk),
        .rst       (rst),
        .next_row  (next_row_pulse),
        .row_index (row_index),
        .row_en    (row_en)
    );

    scan_columns #(
        .NUM_COLS (NUM_COLS)
    ) u_scan_columns (
        .clk        (clk),
        .rst        (rst),
        .col_in_m1  (col_in_m1),
        .col_in_m2  (col_in_m2),
        .col_index  (col_index),
        .col_m1_bit (col_m1_bit),
        .col_m2_bit (col_m2_bit)
    );

    key_address_encoder #(
        .NUM_COLS   (NUM_COLS),
        .ADDR_WIDTH (ADDR_WIDTH)
    ) u_key_address_encoder (
        .row_index  (row_index),
        .col_index  (col_index),
        .col_m1_bit (col_m1_bit),
        .col_m2_bit (col_m2_bit),
        .addr       (key_addr),
        .key_data   (key_data)
    );

    // 1. State register
    always @(posedge clk or posedge rst) begin
        if (rst)
            state <= STATE_IDLE;
        else
            state <= next_state;
    end

    // 2. Next state logic
    always @(*) begin
        next_state = state;
        case (state)
            STATE_IDLE:
                next_state = STATE_ROW_SETTLE;
            STATE_ROW_SETTLE:
                if (settle_cnt == ROW_SETTLE_CYCLES-1)
                    next_state = STATE_SCAN_COL;
            STATE_SCAN_COL:
                if (col_index == NUM_COLS-1)
                    next_state = STATE_NEXT_ROW;
            STATE_NEXT_ROW:
                next_state = STATE_ROW_SETTLE;
            default:
                next_state = STATE_IDLE;
        endcase
    end

    // 3. Row-settle wait counter
    always @(posedge clk or posedge rst) begin
        if (rst)
            settle_cnt <= 0;
        else if (state == STATE_ROW_SETTLE)
            settle_cnt <= settle_cnt + 1'b1;
        else
            settle_cnt <= 0;
    end

    // 4. Column index counter
    always @(posedge clk or posedge rst) begin
        if (rst)
            col_index <= 0;
        else if (state == STATE_SCAN_COL)
            col_index <= col_index + 1'b1;
        else
            col_index <= 0;
    end

    // 5. Pulse activate_rows once per row, on the way back to ROW_SETTLE
    always @(*) begin
        next_row_pulse = (state == STATE_NEXT_ROW);
    end

    // 6. Registered RAM write outputs
    always @(posedge clk or posedge rst) begin
        if (rst) begin
            wea   <= 1'b0;
            addra <= {ADDR_WIDTH{1'b0}};
            dia   <= 2'b00;
        end else begin
            addra <= key_addr;
            dia   <= key_data;
            // Guard against the unused row*col intersections beyond NUM_KEYS
            wea   <= (state == STATE_SCAN_COL) && (key_addr < NUM_KEYS);
        end
    end

endmodule
