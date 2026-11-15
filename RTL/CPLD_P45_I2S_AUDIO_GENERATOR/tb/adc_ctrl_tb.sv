// adc_ctrl_tb.sv — adc_ctrl against the ADC IP model (tb/models/master_volume_pot.v).
// Checks: no protocol violations (calibration delay, SOC after calibration, 8-clock gap),
// CC7 = pot position after power-up, a new CC7 when the pot moves, none for small noise
// (hysteresis), mute at 0 and 127 at full scale.
`timescale 1ns/1ps
module adc_ctrl_tb;
    logic clk = 0, rst = 1;
    always #20.833 clk = ~clk;                // 24 MHz control clock (also the ADC clock here)
    wire tick_us;
    tick_gen #(.DIV(24)) u_tick (.clk(clk), .rst(rst), .tick(tick_us));

    wire        resetn, en, cal, soc, convstop, calrdy, cog, eoc, cc_valid, tmo;
    wire [3:0]  s0, s1;
    wire [11:0] d0, d1, level;
    wire [6:0]  volume;
    wire [15:0] cc_data;

    master_volume_pot adc (.adc_en_i(en), .adc_resetn_i(resetn), .adc_clk_i(clk), .fab_clk_i(clk),
        .adc_cal_i(cal), .adc_soc_i(soc), .adc_calrdy_o(calrdy), .adc0_ch_sel_i(s0), .adc1_ch_sel_i(s1),
        .adc_cog_o(cog), .adc_eoc_o(eoc), .adc_convstop_i(convstop), .adc0_o(d0), .adc1_o(d1),
        .ADC_DN0(1'b0), .ADC_DP0(1'b0), .ADC_DN1(1'b0), .ADC_DP1(1'b0));
    adc_ctrl dut (.clk(clk), .rst(rst), .tick_us(tick_us),
        .adc_resetn(resetn), .adc_en(en), .adc_cal(cal), .adc_soc(soc), .adc_convstop(convstop),
        .adc0_ch_sel(s0), .adc1_ch_sel(s1), .adc_calrdy(calrdy), .adc_cog(cog), .adc_eoc(eoc),
        .adc0_data(d0), .level(level), .volume(volume), .cc_valid(cc_valid), .cc_data(cc_data),
        .timeout_seen(tmo));

    int ccs[$];
    always @(posedge clk) if (cc_valid) ccs.push_back(cc_data[6:0]);

    int errors = 0;
    // n_min: at least this many events so far (a move that lands mid-average can add one
    // intermediate value); exact = no new event allowed (noise inside the hysteresis band)
    int last_n = 0;
    task automatic expect_cc(input int n_min, input int v, input bit exact, input string what);
        if (ccs.size() < n_min || (exact && ccs.size() != last_n) || ccs[ccs.size()-1] != v) begin
            errors++;
            $display("ERROR %s: %0d CC7 events, last %0d, expected %s%0d events, last %0d", what,
                     ccs.size(), ccs.size() ? ccs[ccs.size()-1] : -1, exact ? "" : ">= ", n_min, v);
        end else $display("  %-34s CC7 events %0d, value %0d", what, ccs.size(), ccs[ccs.size()-1]);
        last_n = ccs.size();
    endtask

    initial begin
        adc.pot_code = 12'd3000;
        #1000 rst = 0;
        #40_000_000;                               // calibration (~0.5 ms) + 16 samples
        expect_cc(1, 3000 >> 5, 0, "power-up: pot at 3000");
        adc.pot_code = 12'd3020;                   // small move (< hysteresis): no event
        #40_000_000;
        expect_cc(1, 3000 >> 5, 1, "noise +20 codes: no event");
        adc.pot_code = 12'd1000;                   // big move
        #40_000_000;
        expect_cc(last_n + 1, 1000 >> 5, 0, "moved to 1000");
        adc.pot_code = 12'd0;
        #40_000_000;
        expect_cc(last_n + 1, 0, 0, "pot at 0: mute");
        adc.pot_code = 12'd4095;
        #40_000_000;
        expect_cc(last_n + 1, 127, 0, "pot at full scale");
        if (adc.violations != 0) begin errors++; $display("ERROR: %0d ADC protocol violations", adc.violations); end
        if (tmo) begin errors++; $display("ERROR: EOC timeout"); end
        if (errors == 0) $display("PASS adc_ctrl: calibration + %0d conversions, protocol OK, CC7 on moves, hysteresis OK",
                                  adc.conversions);
        else $display("FAIL adc_ctrl: %0d errors", errors);
        $finish;
    end
endmodule
