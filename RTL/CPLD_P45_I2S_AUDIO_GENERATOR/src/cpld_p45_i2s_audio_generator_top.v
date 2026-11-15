// cpld_p45_i2s_audio_generator_top.v — P45 Rhodes synth top level
//
// Two clock domains:
//   CLK_CTRL  24.000 MHz   control: key matrix scan, velocity, pedal/button, MIDI out, ADC
//                          handshakes (fab_clk_i). Also the reference of the lower-right PLL
//                          (pll0), whose CLKOS4 (24 MHz) is the ADC clock.
//   CLK_AUDIO 45.1584 MHz  audio:   voice engine, flash, mixer, I2S (1024 clocks per 44.1 kHz
//                          sample). For now a pin; later the PLL output (22.5792 MHz x 2).
// Events cross from control to audio through an async FIFO (Gray-coded pointers).
//
// Event word (16 bit), the same for the synth and MIDI out:
//   [15:14] 00 note-off / 01 note-on / 10 controller
//   [13:7]  key 0..87 (MIDI note = key + 21) or controller number (64 = sustain pedal)
//   [6:0]   velocity 1..127 (note-on), 0 (note-off) or controller value (0 / 127)
//
// Audio domain: flash_boot loads the file table at reset, voice_manager turns events into
// voice records (208 slots), voice_engine decodes and mixes all active voices every
// 1024 clocks, i2s_tx sends the mix (same sample on L and R).

// $readmemh paths are relative to the tool's working directory: sim/out and syn/out are
// both two levels below the project folder.
`ifndef VELOCITY_CURVE_FILE
`define VELOCITY_CURVE_FILE "../../src/Key_Events/velocity_curve.mem"
`endif

module cpld_p45_i2s_audio_generator_top (
    // System
    input  wire        CLK_CTRL,      // 24.000 MHz oscillator (PLL input >= 18 MHz)
    input  wire        CLK_AUDIO,     // 45.1584 MHz (PLL from a 22.5792 MHz oscillator)
    input  wire        RST,           // active high, asynchronous

    // Soft-latching power circuit
    input  wire        PSWI,
    output wire        PSWO,

    // Piano interface buttons / status LED
    input  wire        SUS_PEDAL,     // on/off switch; polarity set by PEDAL_ACTIVE_LOW below
    input  wire        FUNC_BTN,      // synchronized, not used yet
    output wire        ON_LED,

    // Master volume pot on the hard ADC: wiper -> ADC_DP0, ADC_DN0 -> analog ground,
    // ADC_REFP0 = external 1.8 V reference (board)
    input  wire        ADC_DP0,
    input  wire        ADC_DN0,

    // MIDI out (UART TX, 31,250 baud)
    output wire        MIDI_TX,

    // Switch matrix - piano keys
    input  wire [5:0]  COL_M1_N,      // external pull-ups: high when no key is pressed
    input  wire [5:0]  COL_M2_N,
    output wire [14:0] ROW_N,         // one row driven low at a time

    // Parallel NOR flash (sample image), 16-bit words, read only
    output wire [24:0] FLASH_A,
    input  wire [15:0] FLASH_DQ,
    output wire        FLASH_CE_N,
    output wire        FLASH_OE_N,
    output wire        FLASH_WE_N,

    // I2S - digital audio amplifier / DAC
    output wire        I2S_MCLK,
    output wire        I2S_BCLK,
    output wire        I2S_LRCLK,
    output wire        I2S_DOUT
);

    localparam CTRL_HZ          = 24_000_000;
    localparam PEDAL_ACTIVE_LOW = 1;          // TODO: confirm with the pedal measurement

    // ------------------------------------------------------------------ resets
    wire rst_ctrl, rst_audio;
    reset_sync u_rst_ctrl  (.clk(CLK_CTRL),  .rst_in(RST), .rst_out(rst_ctrl));
    reset_sync u_rst_audio (.clk(CLK_AUDIO), .rst_in(RST), .rst_out(rst_audio));

    // ================================================================== CONTROL DOMAIN
    wire tick_us;
    tick_gen #(.DIV(CTRL_HZ / 1_000_000)) u_tick_us (.clk(CLK_CTRL), .rst(rst_ctrl), .tick(tick_us));

    // ---- lower-right PLL (Radiant IP, module pll0): 24 MHz in, CLKOS4 = 24 MHz ADC clock.
    // CLKOP (50 MHz) is not used. The ADC side is held in reset until the PLL locks.
    wire pll_clkop, adc_clk, pll_lock, rst_adc;
    pll0 pll (
        .clki_i   (CLK_CTRL),
        .rstn_i   (~RST),
        .clkop_o  (pll_clkop),               // 50 MHz, unused
        .clkos4_o (adc_clk),                 // 24 MHz -> adc_clk_i (<= 25 MHz, ADC divide = 1)
        .lock_o   (pll_lock)
    );
    
    reset_sync u_rst_adc (.clk(CLK_CTRL), .rst_in(RST | ~pll_lock), .rst_out(rst_adc));

    // ---- master volume pot: hard ADC (Radiant IP "ADC", module master_volume_pot) + controller
    // IP settings: ADC clock divide 1 (24 MHz <= 25 MHz), straight binary, ADC0 external
    // reference 1.8 V, unipolar. adc_clk_i comes from the lower-right PLL's CLKOS4 (guide Table 2.1).
    wire        adc_resetn, adc_en, adc_cal, adc_soc, adc_convstop;
    wire [3:0]  adc0_ch_sel, adc1_ch_sel;
    wire        adc_calrdy, adc_cog, adc_eoc;
    wire [11:0] adc0_data, adc1_data;
    wire        vol_valid, adc_timeout;
    wire [15:0] vol_data;
    wire [11:0] vol_level;
    wire [6:0]  vol_cc;

    /* verilator lint_off PINCONNECTEMPTY */   // ADC1 pins left open on purpose
    master_volume_pot adc (
        .adc_en_i       (adc_en),
        .adc_resetn_i   (adc_resetn),
        .adc_clk_i      (adc_clk),
        .fab_clk_i      (CLK_CTRL),          // <= 40 MHz
        .adc_cal_i      (adc_cal),
        .adc_soc_i      (adc_soc),
        .adc_calrdy_o   (adc_calrdy),
        .adc0_ch_sel_i  (adc0_ch_sel),
        .adc1_ch_sel_i  (adc1_ch_sel),
        .adc_cog_o      (adc_cog),
        .adc_eoc_o      (adc_eoc),
        .adc_convstop_i (adc_convstop),
        .adc0_o         (adc0_data),
        .adc1_o         (adc1_data),
        .ADC_DN0        (ADC_DN0),
        .ADC_DP0        (ADC_DP0)
        //.ADC_DN1        (),                  // ADC1 unused
        //.ADC_DP1        ()
    );
    /* verilator lint_on PINCONNECTEMPTY */

    adc_ctrl u_adc_ctrl (
        .clk(CLK_CTRL), .rst(rst_adc), .tick_us(tick_us),
        .adc_resetn(adc_resetn), .adc_en(adc_en), .adc_cal(adc_cal), .adc_soc(adc_soc),
        .adc_convstop(adc_convstop), .adc0_ch_sel(adc0_ch_sel), .adc1_ch_sel(adc1_ch_sel),
        .adc_calrdy(adc_calrdy), .adc_cog(adc_cog), .adc_eoc(adc_eoc), .adc0_data(adc0_data),
        .level(vol_level), .volume(vol_cc), .cc_valid(vol_valid), .cc_data(vol_data),
        .timeout_seen(adc_timeout)
    );

    // ---- key matrix scan (pins are active low)
    wire [14:0] row_en;
    wire        key_valid;
    wire [6:0]  key_idx;
    wire [1:0]  key_contacts;

    assign ROW_N = ~row_en;

    scan_keys_controller #(.ROW_SETTLE_CYCLES(96)) u_scan (     // 96 clocks = 4 us at 24 MHz
        .clk       (CLK_CTRL),
        .rst       (rst_ctrl),
        .row_en    (row_en),
        .col_in_m1 (~COL_M1_N),
        .col_in_m2 (~COL_M2_N),
        .wea       (key_valid),
        .addra     (key_idx),
        .dia       (key_contacts)
    );

    // ---- contacts -> note-on (with velocity) / note-off
    wire        kev_valid;
    wire [15:0] kev_data;

    key_event_gen #(.CURVE_FILE(`VELOCITY_CURVE_FILE)) u_key_events (
        .clk          (CLK_CTRL),
        .rst          (rst_ctrl),
        .tick_us      (tick_us),
        .key_valid    (key_valid),
        .key_idx      (key_idx),
        .key_contacts (key_contacts),
        .evt_valid    (kev_valid),
        .evt_data     (kev_data)
    );

    // ---- sustain pedal -> CC64, function button (unused)
    wire pedal_down, pedal_chg;
    debounce #(.STABLE_US(5000), .ACTIVE_LOW(PEDAL_ACTIVE_LOW)) u_pedal (
        .clk(CLK_CTRL), .rst(rst_ctrl), .tick_us(tick_us),
        .pin(SUS_PEDAL), .pressed(pedal_down), .changed(pedal_chg)
    );

    wire func_pressed, func_chg;              // available for later use
    debounce #(.STABLE_US(10000), .ACTIVE_LOW(1)) u_func (
        .clk(CLK_CTRL), .rst(rst_ctrl), .tick_us(tick_us),
        .pin(FUNC_BTN), .pressed(func_pressed), .changed(func_chg)
    );

    // ---- one event stream
    wire        evt_valid;
    wire [15:0] evt_data;

    event_merge u_merge (
        .clk       (CLK_CTRL),
        .rst       (rst_ctrl),
        .key_valid (kev_valid),
        .key_data  (kev_data),
        .cc_valid  (pedal_chg),
        .cc_data   ({2'b10, 7'd64, pedal_down ? 7'd127 : 7'd0}),
        .cc2_valid (vol_valid),
        .cc2_data  (vol_data),
        .evt_valid (evt_valid),
        .evt_data  (evt_data)
    );

    // ---- MIDI out
    wire midi_dropped;
    midi_tx #(.CLK_HZ(CTRL_HZ)) u_midi (
        .clk       (CLK_CTRL),
        .rst       (rst_ctrl),
        .tick_us   (tick_us),
        .evt_valid (evt_valid),
        .evt_data  (evt_data),
        .midi_out  (MIDI_TX),
        .dropped   (midi_dropped)
    );

    // ---- to the audio domain
    wire        fifo_full;
    reg         fifo_overflow;                // sticky, control domain (debug)
    wire        fifo_empty;
    wire [15:0] fifo_data;
    wire        fifo_pop;

    always @(posedge CLK_CTRL or posedge rst_ctrl) begin
        if (rst_ctrl)
            fifo_overflow <= 1'b0;
        else if (evt_valid && fifo_full)
            fifo_overflow <= 1'b1;
    end

    async_fifo #(.DATA_W(16), .ADDR_W(4)) u_evt_fifo (
        .wr_clk   (CLK_CTRL),
        .wr_rst   (rst_ctrl),
        .wr_en    (evt_valid),
        .wr_data  (evt_data),
        .wr_full  (fifo_full),
        .rd_clk   (CLK_AUDIO),
        .rd_rst   (rst_audio),
        .rd_en    (fifo_pop),
        .rd_data  (fifo_data),
        .rd_empty (fifo_empty)
    );

    // ================================================================== AUDIO DOMAIN
    wire boot_done, boot_err, underrun, overrun;      // status (LED / debug later)

    audio_core u_audio (
        .CLK_AUDIO(CLK_AUDIO), .rst_audio(rst_audio),
        .fifo_empty(fifo_empty), .fifo_data(fifo_data), .fifo_pop(fifo_pop),
        .FLASH_A(FLASH_A), .FLASH_DQ(FLASH_DQ), .FLASH_CE_N(FLASH_CE_N),
        .FLASH_OE_N(FLASH_OE_N), .FLASH_WE_N(FLASH_WE_N),
        .I2S_MCLK(I2S_MCLK), .I2S_BCLK(I2S_BCLK), .I2S_LRCLK(I2S_LRCLK), .I2S_DOUT(I2S_DOUT),
        .boot_done(boot_done), .boot_err(boot_err), .underrun(underrun), .overrun(overrun)
    );

    // Not driven yet: power latch, LED
    assign PSWO   = 1'b1;                     // TODO: soft-power logic; 1 = keep power on
    assign ON_LED = 1'b1;

endmodule
