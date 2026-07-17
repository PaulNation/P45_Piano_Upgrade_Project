module scan_controller_master #(
    parameter DATA_WIDTH = 2,
    parameter ADDR_WIDTH = 7
) (
    input  wire                      clk,
    input  wire                      rst_n,
    //

    //Write to RAM ports
    output  reg                      clka,
    output  reg                      wea,
    output  reg  [ADDR_WIDTH-1:0]    addra,
    output  reg  [DATA_WIDTH-1:0]    dia
);

    // State Encoding
    localparam STATE_IDLE       = 2'b000;
    localparam ACTIVATE_ROW     = 2'b001;
    localparam SCAN_COLS        = 2'b010;
    localparam LOAD_ADDR_DATA   = 3'b011;
    localparam RAM_WRITE_ENABLE = 3'b101;

    reg [2:0] current_state, next_state;

    // 1. Sequential State Register
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n)
            current_state <= STATE_IDLE;
        else
            current_state <= next_state;
    end

    // 2. Next State Combinational Logic
    always @(*) begin
        case (current_state)
            STATE_IDLE: begin
                next_state = ACTIVATE_ROW;
            end
            ACTIVATE_ROW: begin
                next_state = SCAN_COLS;
            end
            SCAN_COLS: begin
                
            end
            default: next_state = STATE_IDLE;
        endcase
    end

    // 3. Registered Output/Data Logic
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            slave_ack  <= 1'b0;
            rx_storage <= 8'h00;
        end else begin
            case (next_state)
                STATE_IDLE: begin
                    slave_ack <= 1'b0;
                end
                STATE_PROCESSING: begin
                    slave_ack  <= 1'b0;
                    rx_storage <= bus_data; // Capture data safely from bus
                end
                STATE_ACK: begin
                    slave_ack <= 1'b1;      // Drive response high
                end
            end
        end
    end
endmodule
