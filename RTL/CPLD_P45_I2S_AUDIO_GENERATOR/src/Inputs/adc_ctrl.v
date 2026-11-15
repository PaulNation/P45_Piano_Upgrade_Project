// adc_ctrl.v — drives the Certus-NX hard ADC (Radiant IP "ADC" / adc_core, instance
// master_volume_pot) to read the master volume pot, and turns it into MIDI CC7 events.
//
// Sequence (ADC User Guide for Nexus, FPGA-TN-02129, Figure 3.7), all on fab_clk_i = clk:
//   RESET      adc_resetn_i = 0, adc_en_i = 0
//   WAIT_EN    resetn = 1, en = 1, wait CAL_DELAY clocks (>= 12 fab_clk and >= 8 adc_clk)
//   WAIT_CAL   adc_cal_i = 1 (kept high from now on) until adc_calrdy_o (~5500 adc_clk)
//   SOC        adc_soc_i = 1 until adc_cog_o = 1
//   WAIT_EOC   until adc_eoc_o: take adc0_o; if it never comes within EOC_TIMEOUT_US, start
//              again (guide section 3.7.5)
//   GAP        adc_cog_o low, then >= 8 fab_clk before the next SOC (guide 3.7.1: the ADC can
//              hang otherwise), and wait for the next sample time (every SAMPLE_US)
// Channel: adc0_ch_sel_i = 4'hB = the dedicated pair ADC_DP0 / ADC_DN0 (wiper / ground);
// unipolar, straight binary: 0 .. 4095 for 0 .. Vref.
//
// Volume: AVG samples are averaged (16 x 1 ms); the new 12-bit value is accepted only when it
// moves more than HYST codes from the last accepted one (pot noise does not flood MIDI), and
// its top 7 bits become the CC7 value. An event is sent whenever that value changes, and once
// after calibration (so MIDI out and the synth know the pot position at power-up).
module adc_ctrl #(
    parameter CAL_DELAY      = 64,       // clocks between enable and calibration
    parameter SAMPLE_US      = 1000,     // one conversion per ms
    parameter EOC_TIMEOUT_US = 100,
    parameter AVG_LOG2       = 4,        // average 16 samples
    parameter HYST           = 40        // 12-bit codes (~1.25 steps of the 7-bit value)
) (
    input  wire        clk,              // = fab_clk_i, <= 40 MHz (control clock, 24 MHz)
    input  wire        rst,
    input  wire        tick_us,

    // to the ADC IP
    output reg         adc_resetn,
    output reg         adc_en,
    output reg         adc_cal,
    output reg         adc_soc,
    output wire        adc_convstop,
    output wire [3:0]  adc0_ch_sel,
    output wire [3:0]  adc1_ch_sel,
    input  wire        adc_calrdy,
    input  wire        adc_cog,
    input  wire        adc_eoc,
    input  wire [11:0] adc0_data,

    // result
    output reg  [11:0] level,            // filtered pot level, 0..4095
    output reg  [6:0]  volume,           // CC7 value
    output reg         cc_valid,         // one clock: send CC7 = volume
    output reg  [15:0] cc_data,          // event word {2'b10, 7'd7, volume}
    output reg         timeout_seen      // sticky: an EOC timeout happened (debug)
);

    assign adc_convstop = 1'b0;
    assign adc0_ch_sel  = 4'hB;
    assign adc1_ch_sel  = 4'hB;           // ADC1 unused

    localparam [2:0] S_RESET = 3'd0, S_WAIT_EN = 3'd1, S_WAIT_CAL = 3'd2, S_SOC = 3'd3,
                     S_WAIT_EOC = 3'd4, S_GAP = 3'd5;

    reg [2:0]  st;
    reg [7:0]  cnt;                       // clock counter (delays, 8-clock gap)
    reg [15:0] us;                        // microsecond counter (sample period, timeout)
    reg [AVG_LOG2-1:0] n;
    reg [11+AVG_LOG2:0] sum;
    reg        first;                     // no value reported yet

    wire [11+AVG_LOG2:0] sum_nx = sum + {{AVG_LOG2{1'b0}}, adc0_data};
    wire [11:0] avg  = sum_nx[11+AVG_LOG2:AVG_LOG2];          // valid with the last sample of a set
    wire [12:0] diff = (avg > level) ? {1'b0, avg} - {1'b0, level} : {1'b0, level} - {1'b0, avg};
    wire        last = (n == {AVG_LOG2{1'b1}});

    always @(posedge clk or posedge rst) begin
        if (rst) begin
            st <= S_RESET; cnt <= 0; us <= 0; n <= 0; sum <= 0; first <= 1'b1;
            adc_resetn <= 1'b0; adc_en <= 1'b0; adc_cal <= 1'b0; adc_soc <= 1'b0;
            level <= 12'd0; volume <= 7'd127; cc_valid <= 1'b0; cc_data <= 16'd0;
            timeout_seen <= 1'b0;
        end else begin
            cc_valid <= 1'b0;
            if (tick_us) us <= us + 16'd1;

            case (st)
                S_RESET: begin
                    adc_resetn <= 1'b1;
                    adc_en     <= 1'b1;
                    cnt        <= 0;
                    st         <= S_WAIT_EN;
                end

                S_WAIT_EN:
                    if (cnt == CAL_DELAY - 1) begin
                        adc_cal <= 1'b1;
                        st      <= S_WAIT_CAL;
                    end else
                        cnt <= cnt + 8'd1;

                S_WAIT_CAL:
                    if (adc_calrdy) begin
                        us <= 0;
                        st <= S_SOC;
                    end

                S_SOC: begin
                    adc_soc <= 1'b1;
                    if (adc_soc && adc_cog) begin   // conversion started
                        adc_soc <= 1'b0;
                        us      <= 0;
                        st      <= S_WAIT_EOC;
                    end
                end

                S_WAIT_EOC:
                    if (adc_eoc) begin
                        n   <= n + 1'b1;
                        sum <= last ? {(12+AVG_LOG2){1'b0}} : sum_nx;
                        if (last && (first || diff > HYST)) begin      // a full set: filter
                            level <= avg;
                            first <= 1'b0;
                            if (first || avg[11:5] != volume) begin
                                volume   <= avg[11:5];
                                cc_valid <= 1'b1;
                                cc_data  <= {2'b10, 7'd7, avg[11:5]};
                            end
                        end
                        cnt <= 0;
                        st  <= S_GAP;
                    end else if (us >= EOC_TIMEOUT_US) begin
                        timeout_seen <= 1'b1;        // no EOC: restart the conversion
                        cnt <= 0;
                        st  <= S_GAP;
                    end

                S_GAP: begin
                    if (adc_cog)
                        cnt <= 0;                    // wait for the conversion to end
                    else if (cnt != 8'd255)
                        cnt <= cnt + 8'd1;
                    if (!adc_cog && cnt >= 8'd8 && us >= SAMPLE_US) begin
                        us <= 0;
                        st <= S_SOC;
                    end
                end

                default: st <= S_RESET;
            endcase
        end
    end

endmodule
