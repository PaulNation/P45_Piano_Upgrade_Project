// cpld_p45_i2s_audio_generator_top.v — P45 Rhodes synth top level
//
// Two clock domains:
//   CLK_CTRL  12.000 MHz   control: key matrix scan, velocity, pedal/button, MIDI out
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
    input  wire        CLK_CTRL,      // 12.000 MHz oscillator
    input  wire        CLK_AUDIO,     // 45.1584 MHz (PLL from a 22.5792 MHz oscillator)
    input  wire        RST,           // active high, asynchronous

    // Soft-latching power circuit
    input  wire        PSWI,
    output wire        PSWO,

    // Piano interface buttons / status LED
    input  wire        SUS_PEDAL,     // on/off switch; polarity set by PEDAL_ACTIVE_LOW below
    input  wire        FUNC_BTN,      // synchronized, not used yet
    output wire        ON_LED,
    // ... ADC interface for the volume pot (CC7) comes later

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

    localparam CTRL_HZ          = 12_000_000;
    localparam PEDAL_ACTIVE_LOW = 1;          // TODO: confirm with the pedal measurement

    // ------------------------------------------------------------------ resets
    wire rst_ctrl, rst_audio;
    reset_sync u_rst_ctrl  (.clk(CLK_CTRL),  .rst_in(RST), .rst_out(rst_ctrl));
    reset_sync u_rst_audio (.clk(CLK_AUDIO), .rst_in(RST), .rst_out(rst_audio));

    // ================================================================== CONTROL DOMAIN
    wire tick_us;
    tick_gen #(.DIV(CTRL_HZ / 1_000_000)) u_tick_us (.clk(CLK_CTRL), .rst(rst_ctrl), .tick(tick_us));

    // ---- key matrix scan (pins are active low)
    wire [14:0] row_en;
    wire        key_valid;
    wire [6:0]  key_idx;
    wire [1:0]  key_contacts;

    assign ROW_N = ~row_en;

    scan_keys_controller u_scan (
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
