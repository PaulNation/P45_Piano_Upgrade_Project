// audio_core.v — everything in the audio clock domain (45.1584 MHz):
//   flash_reader + flash_boot   file table loaded at reset, then sample words on demand
//   voice_manager               events -> voice records (208 slots)
//   voice_engine                decode + mix all active voices, 1024 clocks per sample
//   i2s_tx                      the mix on I2S, same sample on L and R
//   master volume               CC7 (volume pot) -> volume_curve.mem -> gain ramp -> mix
`ifndef VOLUME_CURVE_FILE
`define VOLUME_CURVE_FILE "../../src/Voice/volume_curve.mem"
`endif
module audio_core #(
    parameter VOL_RAMP = 32               // Q2.14 gain step per sample: 0 -> 0 dB in ~11.6 ms
) (
    input  wire        CLK_AUDIO,
    input  wire        rst_audio,

    // event FIFO (show-ahead) from the control domain
    input  wire        fifo_empty,
    input  wire [15:0] fifo_data,
    output wire        fifo_pop,

    output wire [24:0] FLASH_A,
    input  wire [15:0] FLASH_DQ,
    output wire        FLASH_CE_N,
    output wire        FLASH_OE_N,
    output wire        FLASH_WE_N,

    output wire        I2S_MCLK,
    output wire        I2S_BCLK,
    output wire        I2S_LRCLK,
    output wire        I2S_DOUT,

    output wire        boot_done,
    output wire        boot_err,
    output wire        underrun,
    output wire        overrun
);

    reg  [31:0] now_samples;                      // 44.1 kHz sample counter

    // ---- flash: boot loader first, then the voice engine's refill
    wire [15:0] file_count, release_base;
    wire        bt_req, eg_req, fr_busy, fr_valid;
    wire [24:0] bt_addr, eg_addr;
    wire [15:0] fr_data;
    wire [9:0]  tab_addr;
    wire [24:0] tab_start;
    wire [23:0] tab_samples;

    flash_reader u_flash (
        .clk(CLK_AUDIO), .rst(rst_audio),
        .req(boot_done ? eg_req : bt_req), .addr(boot_done ? eg_addr : bt_addr),
        .busy(fr_busy), .rvalid(fr_valid), .rdata(fr_data),
        .FLASH_A(FLASH_A), .FLASH_DQ(FLASH_DQ), .FLASH_CE_N(FLASH_CE_N),
        .FLASH_OE_N(FLASH_OE_N), .FLASH_WE_N(FLASH_WE_N)
    );

    flash_boot u_boot (
        .clk(CLK_AUDIO), .rst(rst_audio),
        .rd_req(bt_req), .rd_addr(bt_addr), .rd_busy(fr_busy),
        .rd_valid(fr_valid && !boot_done), .rd_data(fr_data),
        .boot_done(boot_done), .boot_err(boot_err),
        .file_count(file_count), .release_base(release_base),
        .tab_addr(tab_addr), .tab_start(tab_start), .tab_samples(tab_samples)
    );

    // ---- events -> voice records
    wire [7:0]  vb_addr, vw_addr;
    wire [29:0] vb_data;
    wire        vw_strobe, vm_busy;
    wire [6:0]  volume;

    voice_manager u_vm (
        .clk(CLK_AUDIO), .rst(rst_audio), .enable(boot_done), .now_samples(now_samples),
        .evt_empty(fifo_empty), .evt_data(fifo_data), .evt_pop(fifo_pop),
        .vb_addr(vb_addr), .vb_data(vb_data), .volume(volume),
        .vw_strobe(vw_strobe), .vw_addr(vw_addr), .busy(vm_busy)
    );

    // ---- master volume: curve lookup, then ramp the gain one step per sample (no zipper noise)
    reg [15:0] vol_rom [0:127];
    initial $readmemh(`VOLUME_CURVE_FILE, vol_rom);
    reg  [15:0] vol_target, master_gain;
    always @(posedge CLK_AUDIO) vol_target <= vol_rom[volume];
    always @(posedge CLK_AUDIO or posedge rst_audio) begin
        if (rst_audio)
            master_gain <= 16'd16384;                     // 0 dB until the pot is read
        else if (sample_tick) begin
            if (master_gain + VOL_RAMP < vol_target)       master_gain <= master_gain + VOL_RAMP;
            else if (master_gain > vol_target + VOL_RAMP)  master_gain <= master_gain - VOL_RAMP;
            else                                           master_gain <= vol_target;
        end
    end

    // ---- decode + mix
    wire        sample_tick, mix_valid, seq_idle;
    wire [15:0] mix_out;

    always @(posedge CLK_AUDIO or posedge rst_audio) begin
        if (rst_audio)        now_samples <= 32'd0;
        else if (sample_tick) now_samples <= now_samples + 32'd1;
    end

    voice_engine u_engine (
        .clk(CLK_AUDIO), .rst(rst_audio), .enable(boot_done), .master_gain(master_gain),
        .sample_tick(sample_tick), .mix_out(mix_out), .mix_valid(mix_valid),
        .vb_addr(vb_addr), .vb_data(vb_data), .vw_strobe(vw_strobe), .vw_addr(vw_addr),
        .tab_addr(tab_addr), .tab_start(tab_start), .tab_samples(tab_samples),
        .fr_req(eg_req), .fr_addr(eg_addr), .fr_busy(fr_busy), .fr_valid(fr_valid && boot_done),
        .fr_data(fr_data), .underrun(underrun), .overrun(overrun), .seq_idle(seq_idle)
    );

    // ---- I2S out (master volume / limiter go here later)
    i2s_tx u_i2s (
        .clk(CLK_AUDIO), .rst(rst_audio), .sample_tick(sample_tick), .sample(mix_out),
        .MCLK(I2S_MCLK), .BCLK(I2S_BCLK), .LRCLK(I2S_LRCLK), .DOUT(I2S_DOUT)
    );

endmodule
