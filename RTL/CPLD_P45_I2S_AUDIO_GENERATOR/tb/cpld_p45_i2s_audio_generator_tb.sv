// cpld_p45_i2s_audio_generator_tb.sv — Questa Sim testbench for cpld_p45_i2s_audio_generator_top
//
// The DUT is currently a skeleton: only the switch-matrix scan path is wired up
// (scan_keys_controller -> dual_port_ram_dual_clock write port). The I2S output,
// power-latch (PSWO) and ON_LED logic have no drivers yet in the top file, so
// they are only tied to idle inputs here and are not checked. This testbench
// exercises the scan path: row/column addressing, M1/M2 contact encoding,
// key release, and simultaneous key presses, across the full 90-address matrix
// (all 90 addresses are valid: rows 1-14 x 6 cols plus row0 cols 2-5).
`timescale 1ns/1ps

module cpld_p45_i2s_audio_generator_tb;

    // Must track the defaults used by scan_keys_controller inside the DUT
    localparam int NUM_ROWS          = 15;
    localparam int NUM_COLS          = 6;
    localparam int NUM_KEYS          = 90;
    localparam int ROW_SETTLE_CYCLES = 4;
    localparam int CYCLES_PER_ROW    = ROW_SETTLE_CYCLES + NUM_COLS + 1; // settle + scan_col + next_row
    localparam int FULL_SCAN_CYCLES  = 2 * NUM_ROWS * CYCLES_PER_ROW + 5; // 2 full sweeps + pipeline margin

    logic clk = 0;
    logic rst = 1;

    logic PSWI      = 1'b1;
    logic SUS_PEDAL = 1'b0;
    logic FUNC_BTN  = 1'b0;

    logic [5:0] col_m1_n = 6'h3F;   // idle-high: pull-ups, no key pressed
    logic [5:0] col_m2_n = 6'h3F;

    wire        PSWO;
    wire        ON_LED;
    wire [14:0] row_n;
    wire        i2s_mclk, i2s_bclk, i2s_lrclk, i2s_dout;

    int checks = 0;
    int errors = 0;

    cpld_p45_i2s_audio_generator_top dut (
        .clk       (clk),
        .rst       (rst),
        .PSWI      (PSWI),
        .PSWO      (PSWO),
        .SUS_PEDAL (SUS_PEDAL),
        .FUNC_BTN  (FUNC_BTN),
        .ON_LED    (ON_LED),
        .col_m1_n  (col_m1_n),
        .col_m2_n  (col_m2_n),
        .row_n     (row_n),
        .i2s_mclk  (i2s_mclk),
        .i2s_bclk  (i2s_bclk),
        .i2s_lrclk (i2s_lrclk),
        .i2s_dout  (i2s_dout)
    );

    always #5 clk = ~clk;  // 100 MHz

    // Tracks every address the DUT has ever written, so out-of-range addresses
    // (>= NUM_KEYS) can be proven "never written" instead of compared against
    // the real RAM's uninitialized (X) contents.
    logic written[0:NUM_ROWS*NUM_COLS-1];

    integer i;
    initial
        for (i = 0; i < NUM_ROWS*NUM_COLS; i = i + 1)
            written[i] = 1'b0;

    always @(posedge clk)
        if (dut.wea_int)
            written[dut.addra_int] <= 1'b1;

    task automatic press_key(input int col, input bit is_m2);
        if (is_m2) col_m2_n[col] = 1'b0;
        else       col_m1_n[col] = 1'b0;
        repeat (FULL_SCAN_CYCLES) @(posedge clk);
    endtask

    task automatic release_key(input int col, input bit is_m2);
        if (is_m2) col_m2_n[col] = 1'b1;
        else       col_m1_n[col] = 1'b1;
        repeat (FULL_SCAN_CYCLES) @(posedge clk);
    endtask

    task automatic check(input bit cond, input string msg);
        checks = checks + 1;
        if (!cond) begin
            errors = errors + 1;
            $error("FAIL: %s", msg);
        end else begin
            $display("PASS: %s", msg);
        end
    endtask

    task automatic check_key(input int row, input int col, input bit is_m2, input string tag);
        int addr;
        logic [1:0] expected;
        addr     = row*NUM_COLS + col;
        expected = is_m2 ? 2'b10 : 2'b01;

        press_key(col, is_m2);
        if (addr < NUM_KEYS)
            check(dut.pressed_keys_ram.ram[addr] === expected,
                  $sformatf("%s: RAM[%0d] captured pressed key (row=%0d col=%0d m2=%0d)", tag, addr, row, col, is_m2));
        else
            check(written[addr] === 1'b0,
                  $sformatf("%s: out-of-range addr %0d (row=%0d col=%0d) must never be written", tag, addr, row, col));

        release_key(col, is_m2);
        if (addr < NUM_KEYS)
            check(dut.pressed_keys_ram.ram[addr] === 2'b00,
                  $sformatf("%s: RAM[%0d] cleared after release", tag, addr));
        else
            check(written[addr] === 1'b0,
                  $sformatf("%s: out-of-range addr %0d still never written after release", tag, addr));
    endtask

    // Models a real keystroke: M1 makes contact first, then M2 makes contact
    // shortly after while M1 is still held, so the RAM should read 2'b01 then
    // 2'b11 before both contacts release together. This is what a velocity
    // calc downstream would key off of (time between M1 and M2 closing).
    task automatic check_key_velocity(input int row, input int col, input string tag);
        int addr;
        addr = row*NUM_COLS + col;

        col_m1_n[col] = 1'b0;
        repeat (FULL_SCAN_CYCLES) @(posedge clk);
        check(dut.pressed_keys_ram.ram[addr] === 2'b01,
              $sformatf("%s: RAM[%0d] M1 closed first", tag, addr));

        col_m2_n[col] = 1'b0;
        repeat (FULL_SCAN_CYCLES) @(posedge clk);
        check(dut.pressed_keys_ram.ram[addr] === 2'b11,
              $sformatf("%s: RAM[%0d] M2 also closed (full press)", tag, addr));

        col_m1_n[col] = 1'b1;
        col_m2_n[col] = 1'b1;
        repeat (FULL_SCAN_CYCLES) @(posedge clk);
        check(dut.pressed_keys_ram.ram[addr] === 2'b00,
              $sformatf("%s: RAM[%0d] cleared after release", tag, addr));
    endtask

    initial begin
        // Hold reset for a few cycles, confirm the FSM sits in IDLE while rst is asserted
        repeat (5) @(posedge clk);
        check(dut.scan_controller.state === 2'd0, "FSM is IDLE while reset is held");

        rst = 1'b0;

        // With no keys pressed, every valid RAM address should read back 0 after one full sweep
        repeat (FULL_SCAN_CYCLES) @(posedge clk);
        begin : idle_check
            bit all_zero;
            all_zero = 1'b1;
            for (i = 0; i < NUM_KEYS; i = i + 1)
                if (dut.pressed_keys_ram.ram[i] !== 2'b00)
                    all_zero = 1'b0;
            check(all_zero, "idle scan: every valid RAM address reads 2'b00 with no keys pressed");
        end

        // Single M1-contact key, first row/col
        check_key(0, 0, 1'b0, "first key (row0,col0,M1)");

        // Single M2-contact key, mid-matrix
        check_key(7, 3, 1'b1, "mid key (row7,col3,M2)");

        // row14,col3 -> A#6 (addr 87)
        check_key(14, 3, 1'b0, "A#6 (row14,col3)");

        // Last two keys of the matrix: B6 (addr 88) and C7 (addr 89)
        check_key(14, 4, 1'b0, "B6 (row14,col4)");
        check_key(14, 5, 1'b1, "C7 (row14,col5)");

        // Full keystroke: M1 then M2 close in sequence, both held, then released together
        check_key_velocity(5, 2, "D#2 (row5,col2) full press");

        // Two simultaneous keys in different rows
        fork
            press_key(1, 1'b0);
            press_key(5, 1'b1);
        join
        check(dut.pressed_keys_ram.ram[2*NUM_COLS+1] === 2'b01, "simultaneous key A (row2,col1,M1) captured");
        check(dut.pressed_keys_ram.ram[9*NUM_COLS+5] === 2'b10, "simultaneous key B (row9,col5,M2) captured");
        fork
            release_key(1, 1'b0);
            release_key(5, 1'b1);
        join

        $display("--------------------------------------------------");
        $display("SIM DONE: %0d checks, %0d errors", checks, errors);
        if (errors == 0)
            $display("RESULT: PASS");
        else
            $display("RESULT: FAIL");
        $stop;
    end

endmodule
