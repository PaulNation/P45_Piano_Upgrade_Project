// master_volume_pot.v — SIMULATION MODEL of the Radiant "ADC" IP instance (Certus-NX hard ADC),
// same ports as the generated wrapper. Not for synthesis: Radiant generates the real module.
// Behaviour per FPGA-TN-02129 (all handshake signals on fab_clk_i):
//   calibration: adc_calrdy_o rises CAL_CYCLES adc_clk_i cycles after adc_cal_i
//   conversion : adc_soc_i high -> adc_cog_o high after 3 clocks; COG_CLKS later adc0_o updates
//                and adc_eoc_o pulses for one clock, adc_cog_o falls
//   analog in  : the testbench sets `pot_code` (0..4095) hierarchically
// Protocol checks (counted in `violations`, printed): calibration started < 12 fab_clk after
// reset/enable, SOC before calibration is done, SOC < 8 fab_clk after COG fell (the real ADC can
// hang), adc0_ch_sel_i not the dedicated pair (4'hB).
module master_volume_pot #(
    parameter CAL_CYCLES = 5500,
    parameter COG_CLKS   = 40
) (
    input  wire        adc_en_i,
    input  wire        adc_resetn_i,
    input  wire        adc_clk_i,
    input  wire        fab_clk_i,
    input  wire        adc_cal_i,
    input  wire        adc_soc_i,
    output reg         adc_calrdy_o,
    input  wire [3:0]  adc0_ch_sel_i,
    input  wire [3:0]  adc1_ch_sel_i,
    output reg         adc_cog_o,
    output reg         adc_eoc_o,
    input  wire        adc_convstop_i,
    output reg  [11:0] adc0_o,
    output reg  [11:0] adc1_o,
    input  wire        ADC_DN0,
    input  wire        ADC_DP0,
    input  wire        ADC_DN1,
    input  wire        ADC_DP1
);
    reg  [11:0] pot_code = 12'd2048;
    integer     violations = 0;
    integer     conversions = 0;

    // calibration (adc_clk domain counter)
    integer cal_cnt = 0;
    always @(posedge adc_clk_i or negedge adc_resetn_i) begin
        if (!adc_resetn_i) begin cal_cnt <= 0; end
        else if (adc_en_i && adc_cal_i && cal_cnt < CAL_CYCLES) cal_cnt <= cal_cnt + 1;
    end

    integer since_en = 0, cog_cnt = 0, since_cog = 100;
    reg     cal_prev = 0, started = 0;
    always @(posedge fab_clk_i or negedge adc_resetn_i) begin
        if (!adc_resetn_i) begin
            adc_calrdy_o <= 0; adc_cog_o <= 0; adc_eoc_o <= 0; adc0_o <= 0; adc1_o <= 0;
            since_en <= 0; cog_cnt <= 0; since_cog <= 100; cal_prev <= 0; started <= 0;
        end else begin
            adc_eoc_o <= 0;
            if (adc_en_i && since_en < 1000) since_en <= since_en + 1;
            cal_prev <= adc_cal_i;
            if (adc_cal_i && !cal_prev && since_en < 12) begin
                violations = violations + 1; $display("ADC MODEL: calibration started %0d clocks after enable", since_en);
            end
            adc_calrdy_o <= (cal_cnt >= CAL_CYCLES);
            if (!adc_cog_o && since_cog < 100) since_cog <= since_cog + 1;

            if (adc_soc_i && !adc_cog_o && !started) begin
                if (!adc_calrdy_o) begin violations = violations + 1; $display("ADC MODEL: SOC before calibration"); end
                if (since_cog < 8) begin violations = violations + 1; $display("ADC MODEL: SOC %0d clocks after COG fell", since_cog); end
                if (adc0_ch_sel_i != 4'hB) begin violations = violations + 1; $display("ADC MODEL: channel %h", adc0_ch_sel_i); end
                started <= 1; cog_cnt <= 0;
            end
            if (started && !adc_cog_o) begin
                cog_cnt <= cog_cnt + 1;
                if (cog_cnt == 2) begin adc_cog_o <= 1; cog_cnt <= 0; end
            end
            if (adc_cog_o) begin
                cog_cnt <= cog_cnt + 1;
                if (cog_cnt == COG_CLKS) begin
                    adc_cog_o <= 0; adc_eoc_o <= 1; adc0_o <= pot_code; started <= 0;
                    since_cog <= 0; conversions = conversions + 1;
                end
            end
        end
    end
endmodule
