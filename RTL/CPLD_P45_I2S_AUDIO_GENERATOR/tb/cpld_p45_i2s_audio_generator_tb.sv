// cpld_p45_i2s_audio_generator_tb.sv — front-end test of the top level.
//
// A key matrix model answers the row scan like the real switches (15 rows driven low one
// at a time, 6+6 columns pulled up, A0 at row 0 column index 2). Keys are pressed with a
// chosen M1->M2 time; the sustain pedal bounces before it settles. Checked:
//   * events arriving in the audio domain (through the async FIFO, taken where the voice
//     manager pops them; the flash pins read 0, so boot fails and the manager just drains them):
//     note-on with the right key and velocity (curve ROM at the M1->M2 time +- one scan
//     pass), note-off, CC64 for the pedal, nothing extra
//   * MIDI out (31,250 baud): decoded with running status, must match the same events
`timescale 1ns/1ps

module cpld_p45_i2s_audio_generator_tb;

    localparam real SCAN_PASS_US = 15 * (96 + 6 + 1) / 24.0;   // 64.375 us per full scan
    localparam real MIDI_BIT_NS  = 32000.0;

    logic CLK_CTRL = 0, CLK_AUDIO = 0, RST = 1;
    always #20.833 CLK_CTRL  = ~CLK_CTRL;    // 24 MHz
    always #11.072 CLK_AUDIO = ~CLK_AUDIO;   // 45.1584 MHz

    logic        SUS_PEDAL = 1'b1;           // active low, released
    logic        FUNC_BTN  = 1'b1;
    logic [5:0]  COL_M1_N, COL_M2_N;
    wire  [14:0] ROW_N;
    wire         MIDI_TX;

    cpld_p45_i2s_audio_generator_top dut (
        .CLK_CTRL(CLK_CTRL), .CLK_AUDIO(CLK_AUDIO), .RST(RST),
        .PSWI(1'b1), .PSWO(), .SUS_PEDAL(SUS_PEDAL), .FUNC_BTN(FUNC_BTN), .ON_LED(),
        .ADC_DP0(1'b0), .ADC_DN0(1'b0),
        .MIDI_TX(MIDI_TX), .COL_M1_N(COL_M1_N), .COL_M2_N(COL_M2_N), .ROW_N(ROW_N),
        .FLASH_A(), .FLASH_DQ(16'h0000), .FLASH_CE_N(), .FLASH_OE_N(), .FLASH_WE_N(),
        .I2S_MCLK(), .I2S_BCLK(), .I2S_LRCLK(), .I2S_DOUT());

    // ------------------------------------------------------------ key matrix model
    logic m1 [0:87];
    logic m2 [0:87];
    initial for (int k = 0; k < 88; k++) begin m1[k] = 0; m2[k] = 0; end

    always @* begin
        COL_M1_N = 6'h3F;
        COL_M2_N = 6'h3F;
        for (int r = 0; r < 15; r++)
            if (ROW_N[r] == 1'b0)
                for (int c = 0; c < 6; c++) begin
                    int k;
                    k = r * 6 + c - 2;
                    if (k >= 0 && k < 88) begin
                        if (m1[k]) COL_M1_N[c] = 1'b0;
                        if (m2[k]) COL_M2_N[c] = 1'b0;
                    end
                end
    end

    task automatic press(input int key, input real m1_to_m2_ms);
        fork begin
            m1[key] = 1;
            #(m1_to_m2_ms * 1e6);
            m2[key] = 1;
        end join_none
    endtask

    task automatic release_key(input int key);
        fork begin
            m2[key] = 0;
            #1_000_000;                       // M1 opens 1 ms after M2
            m1[key] = 0;
        end join_none
    endtask

    // ------------------------------------------------------------ velocity curve (same ROM)
    logic [6:0] curve [0:511];
    initial $readmemh("../../src/Key_Events/velocity_curve.mem", curve);

    function automatic int vel_of(input real us);
        int t, msb, mant;
        t = (us < 0) ? 0 : int'(us);
        if (t > 131071) t = 131071;
        msb = 0;
        for (int b = 0; b < 17; b++) if (t & (1 << b)) msb = b;
        mant = (msb >= 4) ? ((t >> (msb - 4)) & 15) : ((t << (4 - msb)) & 15);
        return curve[(msb << 4) | mant];
    endfunction

    // ------------------------------------------------------------ expected events
    int exp_typ[$], exp_a[$], exp_vlo[$], exp_vhi[$];

    function automatic void expect_on(input int key, input real ms);
        exp_typ.push_back(1); exp_a.push_back(key);
        exp_vlo.push_back(vel_of(ms * 1000 + SCAN_PASS_US));
        exp_vhi.push_back(vel_of(ms * 1000 - SCAN_PASS_US));
    endfunction
    function automatic void expect_fixed(input int typ, input int a, input int v);
        exp_typ.push_back(typ); exp_a.push_back(a); exp_vlo.push_back(v); exp_vhi.push_back(v);
    endfunction

    // ------------------------------------------------------------ capture
    logic [15:0] got_q[$];
    always @(posedge CLK_AUDIO)
        if (dut.fifo_pop && !dut.fifo_empty) got_q.push_back(dut.fifo_data);

    logic [7:0] midi_q[$];
    initial forever begin
        logic [7:0] b;
        @(negedge MIDI_TX);
        #(MIDI_BIT_NS * 1.5);
        for (int i = 0; i < 8; i++) begin b[i] = MIDI_TX; #(MIDI_BIT_NS); end
        midi_q.push_back(b);
    end

    // ------------------------------------------------------------ stimulus
    initial begin
        #2000 RST = 0;
        #3_000_000;

        press(39, 5.0);    expect_on(39, 5.0);                       // C4, medium
        expect_fixed(2, 7, 2048 >> 5);                               // volume pot after ADC calibration (model: mid-scale)
        #35_000_000;
        release_key(39);   expect_fixed(0, 39, 0);
        #20_000_000;

        press(0, 1.0);     expect_on(0, 1.0);                        // A0, fast
        #3_000_000;
        press(50, 8.0); press(52, 8.0); press(55, 8.0);              // chord
        expect_on(50, 8.0); expect_on(52, 8.0); expect_on(55, 8.0);
        #50_000_000;
        release_key(0); release_key(50); release_key(52); release_key(55);
        expect_fixed(0, 0, 0); expect_fixed(0, 50, 0); expect_fixed(0, 52, 0); expect_fixed(0, 55, 0);
        #20_000_000;

        press(87, 40.0);   expect_on(87, 40.0);                      // C8, soft
        #60_000_000;
        release_key(87);   expect_fixed(0, 87, 0);
        #10_000_000;

        repeat (6) begin SUS_PEDAL = ~SUS_PEDAL; #300_000; end       // bounce, ends released
        SUS_PEDAL = 0;     expect_fixed(2, 64, 127);                 // pedal down
        #20_000_000;
        repeat (4) begin SUS_PEDAL = ~SUS_PEDAL; #200_000; end
        SUS_PEDAL = 1;     expect_fixed(2, 64, 0);                   // pedal up
        #10_000_000;

        press(20, 0.0);    expect_fixed(1, 20, 127);                 // both contacts in one pass
        #20_000_000;
        release_key(20);   expect_fixed(0, 20, 0);
        #10_000_000;

        press(30, 150.0);  expect_fixed(1, 30, 1);                   // M2 after the timeout
        #170_000_000;
        release_key(30);   expect_fixed(0, 30, 0);
        #20_000_000;

        check();
        $finish;
    end

    // ------------------------------------------------------------ checking
    task automatic check();
        int errors = 0;
        logic [7:0] running = 0;
        int mi = 0;
        logic [15:0] midi_evt[$];

        if (got_q.size() != exp_typ.size()) begin
            errors++;
            $display("ERROR: %0d events, expected %0d", got_q.size(), exp_typ.size());
        end
        // Keys pressed in the same scan pass can arrive in any order (the scan wraps around
        // continuously), so each expected event may match any unused event within +-4 places.
        begin
            bit used[$];
            for (int j = 0; j < got_q.size(); j++) used.push_back(0);
            for (int i = 0; i < exp_typ.size(); i++) begin
                int found = -1;
                for (int j = (i > 4 ? i - 4 : 0); j < got_q.size() && j <= i + 4; j++) begin
                    logic [15:0] w;
                    int typ, a, v;
                    w = got_q[j]; typ = w[15:14]; a = w[13:7]; v = w[6:0];
                    if (found < 0 && !used[j] && typ == exp_typ[i] && a == exp_a[i] &&
                        v >= exp_vlo[i] && v <= exp_vhi[i]) found = j;
                end
                if (found < 0) begin
                    errors++;
                    $display("ERROR: no event for expected type %0d key/cc %0d value %0d..%0d",
                             exp_typ[i], exp_a[i], exp_vlo[i], exp_vhi[i]);
                end else begin
                    logic [15:0] w;
                    used[found] = 1;
                    w = got_q[found];
                    $display("  event %2d: %s %3d  value %3d   (expected %0d..%0d)", found,
                             exp_typ[i] == 1 ? "note-on " : exp_typ[i] == 0 ? "note-off" : "CC      ",
                             exp_a[i], w[6:0], exp_vlo[i], exp_vhi[i]);
                end
            end
        end

        // decode MIDI with running status back into event words
        while (mi < midi_q.size()) begin
            logic [7:0] b0, b1, nn;
            b0 = midi_q[mi];
            if (b0[7]) begin running = b0; mi++; end
            if (mi + 1 >= midi_q.size() + 1) break;
            b0 = midi_q[mi]; b1 = midi_q[mi + 1];
            nn = b0 - 8'd21;
            if (running == 8'h90)
                midi_evt.push_back({(b1 == 0) ? 2'b00 : 2'b01, nn[6:0], b1[6:0]});
            else if (running == 8'hB0)
                midi_evt.push_back({2'b10, b0[6:0], b1[6:0]});
            else begin errors++; $display("ERROR: unexpected MIDI status %02h", running); end
            mi += 2;
        end
        if (midi_evt.size() != got_q.size()) begin
            errors++;
            $display("ERROR: MIDI has %0d messages, synth got %0d events", midi_evt.size(), got_q.size());
        end
        for (int i = 0; i < midi_evt.size() && i < got_q.size(); i++)
            if (midi_evt[i] !== got_q[i]) begin
                errors++;
                $display("ERROR: MIDI message %0d = %04h, synth event %04h", i, midi_evt[i], got_q[i]);
            end

        if (errors == 0)
            $display("PASS front end: %0d events through the async FIFO, MIDI out matches (%0d bytes)",
                     got_q.size(), midi_q.size());
        else
            $display("FAIL front end: %0d errors", errors);
    endtask

endmodule
