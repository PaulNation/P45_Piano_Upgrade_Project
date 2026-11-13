// async_fifo_tb.sv — 12 MHz writer, 45.1584 MHz reader, random enables on both sides.
// Checks: every word arrives once, in order, nothing written while full is lost silently.
`timescale 1ns/1ps
module async_fifo_tb;
    localparam int N = 3000;
    logic wclk = 0, rclk = 0, rst = 1;
    always #41.667 wclk = ~wclk;              // 12 MHz
    always #11.072 rclk = ~rclk;              // 45.1584 MHz

    logic wr_rst, rd_rst;
    reset_sync u_rw (.clk(wclk), .rst_in(rst), .rst_out(wr_rst));
    reset_sync u_rr (.clk(rclk), .rst_in(rst), .rst_out(rd_rst));

    logic        wr_en = 0, rd_en = 0, full, empty;
    logic [15:0] wr_data = 0, rd_data;
    async_fifo #(.DATA_W(16), .ADDR_W(4)) dut (
        .wr_clk(wclk), .wr_rst(wr_rst), .wr_en(wr_en), .wr_data(wr_data), .wr_full(full),
        .rd_clk(rclk), .rd_rst(rd_rst), .rd_en(rd_en), .rd_data(rd_data), .rd_empty(empty));

    int sent = 0, got = 0, errors = 0, phase = 0, saw_full = 0;

    // writer: bursts (fills the FIFO) in phase 0, random afterwards
    always @(posedge wclk) begin
        if (!wr_rst) begin
            if (wr_en && !full) begin sent++; wr_data <= wr_data + 1; end
            wr_en <= (sent + (wr_en && !full) < N) && ((phase == 0) ? 1'b1 : ($urandom % 3 == 0));
            if (full) saw_full = 1;
        end
    end
    // reader: slow in phase 0 (so the FIFO fills), fast and random afterwards
    always @(posedge rclk) begin
        if (!rd_rst) begin
            if (rd_en && !empty) begin
                if (rd_data !== got[15:0]) begin
                    errors++;
                    if (errors < 5) $display("ERROR: got %0d expected %0d", rd_data, got[15:0]);
                end
                got++;
            end
            rd_en <= (phase == 0) ? ($urandom % 40 == 0) : ($urandom % 2 == 0);
        end
    end

    initial begin
        #500 rst = 0;
        #200000 phase = 1;
        wait (got == N);
        #1000;
        if (errors == 0 && saw_full && sent == N && got == N)
            $display("PASS async_fifo: %0d words in order across clock domains (FIFO filled up and recovered)", got);
        else
            $display("FAIL async_fifo: %0d errors, saw_full=%0d", errors, saw_full);
        $finish;
    end
    initial begin #20_000_000 $display("FAIL async_fifo: timeout (got %0d)", got); $finish; end
endmodule
