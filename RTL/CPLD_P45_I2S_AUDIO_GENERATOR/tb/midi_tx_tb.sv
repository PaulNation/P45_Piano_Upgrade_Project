// midi_tx_tb.sv — sends note-on, note-off, CC64 and a burst through midi_tx and decodes
// the 31,250 baud line. Checks the bytes, including running status and the status
// resend after the idle time.
`timescale 1ns/1ps
module midi_tx_tb;
    localparam real BIT_NS = 32000.0;          // 1 / 31,250 baud
    logic clk = 0, rst = 1;
    always #20.833 clk = ~clk;

    logic tick_us;
    tick_gen #(.DIV(24)) u_tick (.clk(clk), .rst(rst), .tick(tick_us));

    logic        evt_valid = 0;
    logic [15:0] evt_data = 0;
    logic        tx, dropped;
    midi_tx #(.CLK_HZ(24_000_000), .RESEND_MS(2)) dut (
        .clk(clk), .rst(rst), .tick_us(tick_us), .evt_valid(evt_valid), .evt_data(evt_data),
        .midi_out(tx), .dropped(dropped));

    // UART receiver model
    byte rx_bytes[$];
    initial begin
        forever begin
            @(negedge tx);
            #(BIT_NS * 1.5);
            begin
                byte b;
                for (int i = 0; i < 8; i++) begin b[i] = tx; #(BIT_NS); end
                if (tx !== 1'b1) $display("ERROR: bad stop bit");
                rx_bytes.push_back(b);
            end
        end
    end

    task automatic send(input [1:0] typ, input [6:0] a, input [6:0] b);
        @(posedge clk); evt_valid <= 1; evt_data <= {typ, a, b};
        @(posedge clk); evt_valid <= 0;
    endtask

    byte exp_bytes[$];
    int errors = 0;
    initial begin
        #1000 rst = 0;
        #1000;
        send(2'b01, 7'd39, 7'd100);            // C4 on  -> 90 3C 64
        send(2'b01, 7'd43, 7'd80);             // E4 on  ->    40 50 (running status)
        send(2'b00, 7'd39, 7'd0);              // C4 off ->    3C 00
        send(2'b10, 7'd64, 7'd127);            // pedal  -> B0 40 7F
        send(2'b01, 7'd0,  7'd1);              // A0 on  -> 90 15 01
        #10_000_000;                           // 4.2 ms of bytes + > RESEND_MS idle -> status sent again
        send(2'b00, 7'd0,  7'd0);              // A0 off -> 90 15 00
        send(2'b01, 7'd87, 7'd127);            // C8 on  ->    6C 7F
        #3_000_000;
        exp_bytes = '{8'h90,8'h3C,8'h64, 8'h40,8'h50, 8'h3C,8'h00, 8'hB0,8'h40,8'h7F,
                      8'h90,8'h15,8'h01, 8'h90,8'h15,8'h00, 8'h6C,8'h7F};
        if (rx_bytes.size() != exp_bytes.size()) begin
            errors++; $display("ERROR: %0d bytes received, expected %0d", rx_bytes.size(), exp_bytes.size());
        end
        for (int i = 0; i < rx_bytes.size() && i < exp_bytes.size(); i++)
            if (rx_bytes[i] !== exp_bytes[i]) begin
                errors++; $display("ERROR: byte %0d = %02h, expected %02h", i, rx_bytes[i], exp_bytes[i]);
            end
        if (errors == 0 && !dropped) $display("PASS midi_tx: %0d bytes, running status + resend OK", rx_bytes.size());
        else $display("FAIL midi_tx: %0d errors", errors);
        $finish;
    end
endmodule
