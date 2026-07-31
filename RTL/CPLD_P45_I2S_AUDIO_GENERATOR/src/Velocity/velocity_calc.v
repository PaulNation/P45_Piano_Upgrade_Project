module velocity_calc #(
    parameter DIV_WIDTH = 16
) (
    input  wire                 clk,
    input  wire                 rst,

    // Request/done divider interface, shared across all 90 keys since scanning
    // is serial and only one division is ever in flight at a time. Caller
    // drives dividend=K (velocity = clamp(K / elapsed_ms, 1, 127)).
    input  wire                 start,
    input  wire [DIV_WIDTH-1:0] dividend,
    input  wire [DIV_WIDTH-1:0] divisor,
    output wire                 busy,
    output reg  [DIV_WIDTH-1:0] result,
    output reg                  done,

    // Clamped, registered velocity result
    output reg  [6:0]           velocity,
    output reg                  valid
);

    // Sequential shift-subtract restoring divider, one bit per clock: this CPLD
    // has no DSP/multiplier blocks, so a combinational '/' would infer a large
    // subtractor tree for a value only needed once per keystroke.
    localparam CNT_W = $clog2(DIV_WIDTH);
    localparam [CNT_W-1:0] BIT_CNT_INIT = DIV_WIDTH-1;

    reg                   running;
    reg  [DIV_WIDTH-1:0]  divisor_r;
    reg  [DIV_WIDTH-1:0]  divd_shreg;
    reg  [DIV_WIDTH-2:0]  quot;      // top bit of a DIV_WIDTH-wide quotient is only
                                     // ever complete on the final (wire) iteration,
                                     // so the register only needs to hold DIV_WIDTH-1
    reg  [DIV_WIDTH-1:0]  rem;
    reg  [CNT_W-1:0]      bit_cnt;

    wire [DIV_WIDTH:0]   rem_shift    = {rem, divd_shreg[DIV_WIDTH-1]};
    wire                 fits         = rem_shift >= {1'b0, divisor_r};
    wire [DIV_WIDTH:0]   rem_subbed   = rem_shift - {1'b0, divisor_r};
    wire [DIV_WIDTH-1:0] quot_next    = {quot, fits};

    assign busy = running;

    // 1. Divider FSM: latch inputs on start, shift one dividend bit per cycle
    always @(posedge clk or posedge rst) begin
        if (rst) begin
            running <= 1'b0;
            done    <= 1'b0;
        end else begin
            done <= 1'b0;

            if (!running) begin
                if (start) begin
                    running    <= 1'b1;
                    divisor_r  <= divisor;
                    divd_shreg <= dividend;
                    rem        <= {DIV_WIDTH{1'b0}};
                    bit_cnt    <= BIT_CNT_INIT;
                end
            end else begin
                rem        <= fits ? rem_subbed[DIV_WIDTH-1:0] : rem_shift[DIV_WIDTH-1:0];
                divd_shreg <= {divd_shreg[DIV_WIDTH-2:0], 1'b0};
                quot       <= quot_next[DIV_WIDTH-2:0];

                if (bit_cnt == 0) begin
                    running <= 1'b0;
                    done    <= 1'b1;
                    result  <= quot_next;
                end else begin
                    bit_cnt <= bit_cnt - 1'b1;
                end
            end
        end
    end

    // 2. Clamp to [1,127] and register the final velocity, same cycle as done
    always @(posedge clk or posedge rst) begin
        if (rst) begin
            velocity <= 7'd0;
            valid    <= 1'b0;
        end else begin
            valid <= 1'b0;
            if (running && (bit_cnt == 0)) begin
                valid    <= 1'b1;
                velocity <= (quot_next == {DIV_WIDTH{1'b0}}) ? 7'd1    :
                            (quot_next > {{(DIV_WIDTH-7){1'b0}}, 7'd127}) ? 7'd127 :
                            quot_next[6:0];
            end
        end
    end

endmodule
