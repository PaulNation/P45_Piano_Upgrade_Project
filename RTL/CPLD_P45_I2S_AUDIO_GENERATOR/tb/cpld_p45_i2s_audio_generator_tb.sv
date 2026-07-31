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
    wire        note_on_valid;
    wire [6:0]  note_on_addr;

    int checks = 0;
    int errors = 0;

    cpld_p45_i2s_audio_generator_top dut (
        .CLK           (clk),
        .RST           (rst),
        .PSWI          (PSWI),
        .PSWO          (PSWO),
        .SUS_PEDAL     (SUS_PEDAL),
        .FUNC_BTN      (FUNC_BTN),
        .ON_LED        (ON_LED),
        .NOTE_ON_VALID (note_on_valid),
        .NOTE_ON_ADDR  (note_on_addr),
        .COL_M1_N      (col_m1_n),
        .COL_M2_N      (col_m2_n),
        .ROW_N         (row_n),
        .I2S_MCLK      (i2s_mclk),
        .I2S_BCLK      (i2s_bclk),
        .I2S_LRCLK     (i2s_lrclk),
        .I2S_DOUT      (i2s_dout)
    );

    always #5 clk = ~clk;  // 100 MHz

    // Speed up the velocity-timer pipeline for simulation: ms_tick_gen's divider
    // is just a clock-cycle counter (independent of the tb's actual 100MHz rate),
    // so overriding it to a small divisor keeps each simulated "ms" short without
    // touching the DUT's real 48MHz default. TIMEOUT_MS is likewise shortened so
    // the M2-never-closes test doesn't have to simulate a full 5000ms.
    localparam int VTC_CLK_FREQ_HZ = 48_000; // -> 48 clk cycles per simulated "tick"
    localparam int VTC_TICK_CYCLES = VTC_CLK_FREQ_HZ / 1000;
    localparam int VTC_TIMEOUT_MS  = 100;    // comfortably above the slow-press gap below
    localparam int VTC_SCAN_CYCLES = 90;     // velocity_addr_gen full sweep period (NUM_KEYS)
    localparam int VTC_DIV_CYCLES  = 16;     // velocity_calc DIV_WIDTH

    defparam dut.velocity_timer.u_ms_tick_gen.CLK_FREQ_HZ = VTC_CLK_FREQ_HZ;
    defparam dut.velocity_timer.TIMEOUT_MS                = VTC_TIMEOUT_MS;

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

    // Same tracking-array trick as `written[]` above, but for velocity_ram: an
    // out-of-range or never-note-on'd address must be provably never written,
    // not just compared against uninitialized (X) RAM contents.
    logic vel_written[0:NUM_KEYS-1];
    integer vi;
    initial
        for (vi = 0; vi < NUM_KEYS; vi = vi + 1)
            vel_written[vi] = 1'b0;

    always @(posedge clk)
        if (dut.vel_wea_int)
            vel_written[dut.vel_addra_int] <= 1'b1;

    // Latches the most recent note_on_valid pulse and counts pulses seen, since
    // note_on_valid/note_on_addr are single-cycle strobes that would otherwise
    // be missed by a task that only samples state after waiting.
    integer note_on_count = 0;
    logic [6:0] last_note_on_addr;

    always @(posedge clk)
        if (note_on_valid) begin
            note_on_count     <= note_on_count + 1;
            last_note_on_addr <= note_on_addr;
        end

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

    // Waits long enough for the velocity_addr_gen scan to revisit a given key's
    // address and for velocity_calc's serial divider to finish, so state written
    // by an event on that pass is guaranteed visible before the next check.
    task automatic wait_vtc_settle();
        repeat (VTC_SCAN_CYCLES + VTC_DIV_CYCLES + 5) @(posedge clk);
    endtask

    // The velocity-timer pipeline reads pressed_keys_ram through its own free-
    // running Port B scan, independent of scan_keys_controller's row/col sweep.
    // COL_M1_N/COL_M2_N are shared across all 15 rows in this testbench's pin
    // model (there is no per-row electrical gating here, unlike a real switch
    // matrix), so holding a column low would make every row on that column
    // appear pressed at once and contend for velocity_calc's one shared
    // divider. To unit-test the velocity pipeline for a single, specific key
    // address in isolation, the velocity tests below force scan_keys_controller's
    // RAM write enable low (Icarus can't force an individual memory word, only
    // plain nets) and then deposit pressed_keys_ram's word for one address
    // directly, instead of driving the physical column pins.

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

        // Velocity-timer pipeline: fast M1->M2 press -> high (clamped) velocity.
        // K/elapsed_ms exceeds 127 for any gap this short, so 127 is deterministic.
        begin : fast_press_velocity_test
            localparam int ADDR = 3*NUM_COLS + 2;
            int cnt_before;
            cnt_before = note_on_count;
            force dut.pressed_keys_ram.ram[ADDR] = 2'b01;   // M1 closes
            wait_vtc_settle();
            repeat (2 * VTC_TICK_CYCLES) @(posedge clk);    // ~2ms M1->M2 gap
            force dut.pressed_keys_ram.ram[ADDR] = 2'b11;   // M2 also closes
            wait_vtc_settle();
            check(vel_written[ADDR] === 1'b1,
                  "fast press: velocity_ram written for a short M1->M2 gap");
            check(dut.velocity_ram.ram[ADDR] === 7'd127,
                  "fast press: short gap clamps to max velocity (127)");
            check(note_on_count === cnt_before + 1,
                  "fast press: note_on_valid pulsed exactly once");
            check(last_note_on_addr === ADDR,
                  "fast press: note_on_addr matches the pressed key");
            force dut.pressed_keys_ram.ram[ADDR] = 2'b00;
            wait_vtc_settle();
            release dut.pressed_keys_ram.ram[ADDR];
        end

        // Velocity-timer pipeline: slow M1->M2 press -> low velocity, well below
        // the fast-press clamp above (K=2000 default / ~60ms gap ~= 30), and well
        // under VTC_TIMEOUT_MS so this key does not time out before M2 closes
        begin : slow_press_velocity_test
            localparam int ADDR = 6*NUM_COLS + 4;
            int cnt_before;
            cnt_before = note_on_count;
            force dut.pressed_keys_ram.ram[ADDR] = 2'b01;   // M1 closes
            wait_vtc_settle();
            repeat (60 * VTC_TICK_CYCLES) @(posedge clk);   // ~60ms M1->M2 gap
            force dut.pressed_keys_ram.ram[ADDR] = 2'b11;   // M2 also closes
            wait_vtc_settle();
            check(vel_written[ADDR] === 1'b1,
                  "slow press: velocity_ram written for a long M1->M2 gap");
            check(dut.velocity_ram.ram[ADDR] < 7'd127,
                  "slow press: long gap does not clamp to max velocity");
            check(dut.velocity_ram.ram[ADDR] > 7'd0,
                  "slow press: velocity floor of 1 respected");
            check(note_on_count === cnt_before + 1,
                  "slow press: note_on_valid pulsed exactly once");
            force dut.pressed_keys_ram.ram[ADDR] = 2'b00;
            wait_vtc_settle();
            release dut.pressed_keys_ram.ram[ADDR];
        end

        // Velocity-timer pipeline: M1 closes but M2 never closes before the
        // (overridden, short) TIMEOUT_MS elapses -> velocity_ram must never be
        // written for that key and note_on_valid must never pulse for it.
        begin : timeout_no_note_on_test
            localparam int ADDR = 10*NUM_COLS + 1;
            int cnt_before;
            cnt_before = note_on_count;
            force dut.pressed_keys_ram.ram[ADDR] = 2'b01;   // M1 closes, M2 never does
            wait_vtc_settle();
            repeat ((VTC_TIMEOUT_MS + 5) * VTC_TICK_CYCLES) @(posedge clk);
            wait_vtc_settle();
            check(vel_written[ADDR] === 1'b0,
                  "timeout: velocity_ram never written when M2 never closes");
            check(note_on_count === cnt_before,
                  "timeout: no note_on_valid pulse when M2 never closes");
            force dut.pressed_keys_ram.ram[ADDR] = 2'b00;
            wait_vtc_settle();
            release dut.pressed_keys_ram.ram[ADDR];
        end

        $display("--------------------------------------------------");
        $display("SIM DONE: %0d checks, %0d errors", checks, errors);
        if (errors == 0)
            $display("RESULT: PASS");
        else
            $display("RESULT: FAIL");
        $stop;
    end

endmodule
