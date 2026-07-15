module scan_keys (
    //Switch Matrix Ports - Piano Keys - Scan the matrix to detect which key is pressed and the state of the key's two switches which get saved to a block ram 128x2 (depth x width)
    input wire clk,
    input wire rst_n,
    input reg [5:0] col_m1_n, //Columns have a external pull-up resistor, so they are high when no key is pressed
    input reg [5:0] col_m2_n, //Columns have a external pull-up resistor, so they are high when no key is pressed
    output reg [14:0] row_n,  //A row is driven to low with a Push Pull IO for scanning the columns of that row, when a key is pressed, the corresponding column will be pulled low
);
    reg [6:0] current_col; // Current column being scanned
    // State of the keys (pressed or not pressed)
    reg [1:0] key_state [0:6]; // key_state[i] = 2'b00: switches not pressed, 2'b01: m1 switch pressed, 2'b10: m2 switch pressed, 2'b11: both switches pressed
    
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            row_n <= 15'b111111111111111; // All rows inactive (high)
            key_state <= '{default: 2'b00}; // Reset all key states to not pressed
        end else begin
            // Logic to scan the switch matrix and update row_n based on col_m1_n and col_m2_n
            // This is a placeholder for the actual scanning logic
            if (row_n == 15'b111111111111111) begin
                row_n <= 15'b011111111111111; // Activate the first row
            end else begin
                row_n <= {1'b1, row_n[14:1]}; // Shift the active row to the next one
                for (int i = 0; i < 6; i++) begin
                    key_state[current_col+i] <= {col_m1_n[i], col_m2_n[i]}; // Update key state based on the current column values
                end
                // Key and the state of its two switches is captured in key_state[current_col+i] for the current column being scanned
            end
        end
    end

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            // Reset logic for any internal state if needed
            current_col <= 7'h00; // Reset to the first column
        end else begin
            // Additional logic for handling key presses, debouncing, etc.
            if (current_col == 7'h53) begin
                current_col <= 7'h00; // Wrap around to the first column after the last column
            end
            else begin
                current_col <= current_col + 6; // Move to the next column
            end
        end
    end

endmodule