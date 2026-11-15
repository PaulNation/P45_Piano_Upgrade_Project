// pll0.v — SIMULATION MODEL of the Radiant PLL IP instance (lower-right PLL), same ports as the
// generated module. Not for synthesis: Radiant generates the real one.
// Generated settings: clki_i 24 MHz -> clkop_o 50 MHz, clkos4_o 24 MHz. The model passes
// clki_i through as clkos4_o, makes a free-running 50 MHz clkop_o, and raises lock_o
// LOCK_CYCLES input clocks after rstn_i goes high (outputs are low until then).
`timescale 1ns/1ps
module pll0 #(
    parameter LOCK_CYCLES = 240                 // 10 us at 24 MHz
) (
    input  wire clki_i,
    input  wire rstn_i,
    output wire clkop_o,
    output wire clkos4_o,
    output reg  lock_o
);
    reg op = 1'b0;
    always #10 op = ~op;                        // 50 MHz
    assign clkop_o  = lock_o & op;
    assign clkos4_o = lock_o & clki_i;

    integer n = 0;
    always @(posedge clki_i or negedge rstn_i)
        if (!rstn_i) begin n <= 0; lock_o <= 1'b0; end
        else if (n < LOCK_CYCLES) n <= n + 1;
        else lock_o <= 1'b1;
    initial lock_o = 1'b0;
endmodule
