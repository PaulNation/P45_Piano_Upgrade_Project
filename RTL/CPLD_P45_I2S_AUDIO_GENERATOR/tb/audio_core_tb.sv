// audio_core_tb.sv — the whole audio domain (flash boot, voice manager, voice engine, mixer,
// I2S) against a flash model holding the real image (sparse: header, file table and the start
// of every file the test can use; tools/engine_ref.py gen). Events from
// tb/vectors/engine_events.hex are fed into the event FIFO input at their sample times.
// Everything is logged and checked bit-exactly by
//   python3 tools/engine_ref.py check sim/verilator/engine_log.txt
// Plusargs: +events=<hex> +flashbin=<big-endian image, whole flash> +end=<sample> +log=<file>
// (tools/engine_ref.py stress writes the stress vectors and the full image).
`timescale 1ns/1ps
module audio_core_tb;
    int END_SAMPLE = 26000;
    string ev_file = "../../tb/vectors/engine_events.hex", flash_bin = "", log_file = "engine_log.txt";
    localparam real T_ACC_NS  = 100.0;

    logic clk = 0, rst = 1;
    always #11.072 clk = ~clk;                 // 45.1584 MHz

    // ---------------- flash model (64 MB)
    logic [15:0] flash [0:33554431];
    wire  [24:0] A;
    wire         CE_N, OE_N, WE_N;
    logic [15:0] DQ;
    initial begin
        int fh, nread;
        if ($value$plusargs("flashbin=%s", flash_bin)) begin
            fh = $fopen(flash_bin, "rb");
            nread = $fread(flash, fh);
            $fclose(fh);
            $display("flash: %0d bytes from %s", nread, flash_bin);
        end else
            $readmemh("../../tb/vectors/engine_flash.hex", flash);
    end
    always @(A or CE_N or OE_N) begin
        DQ = 16'hxxxx;
        if (!CE_N && !OE_N) begin
            #(T_ACC_NS);
            if (!CE_N && !OE_N) DQ = flash[A];
        end
    end

    // ---------------- event FIFO model (show-ahead)
    logic [15:0] evq[$];
    wire         fifo_pop;
    wire         fifo_empty = (evq.size() == 0);
    wire  [15:0] fifo_data  = fifo_empty ? 16'h0000 : evq[0];
    always @(posedge clk) if (fifo_pop && !fifo_empty) void'(evq.pop_front());

    wire MCLK, BCLK, LRCLK, DOUT, boot_done, boot_err, underrun, overrun;
    audio_core dut (
        .CLK_AUDIO(clk), .rst_audio(rst),
        .fifo_empty(fifo_empty), .fifo_data(fifo_data), .fifo_pop(fifo_pop),
        .FLASH_A(A), .FLASH_DQ(DQ), .FLASH_CE_N(CE_N), .FLASH_OE_N(OE_N), .FLASH_WE_N(WE_N),
        .I2S_MCLK(MCLK), .I2S_BCLK(BCLK), .I2S_LRCLK(LRCLK), .I2S_DOUT(DOUT),
        .boot_done(boot_done), .boot_err(boot_err), .underrun(underrun), .overrun(overrun));

    wire [31:0] now = dut.now_samples;

    // ---------------- logging
    int fd;
    int max_walk = 0;
    always @(posedge clk) begin
        if (dut.u_engine.mix_valid && dut.u_engine.pcnt > max_walk) max_walk = dut.u_engine.pcnt;
        if (dut.u_engine.q == 4'd5)            // Q_RESTART
            $fwrite(fd, "R %0d %0d %0d %0d\n", now, dut.u_engine.v,
                    dut.u_engine.vrec[25:16], dut.u_engine.vrec[15:0]);
        if (dut.u_engine.m_valid)
            $fwrite(fd, "S %0d %0d %0d %0d %0d %0d\n", now, dut.u_engine.v,
                    dut.u_engine.m_s, dut.u_engine.m_g, dut.u_engine.m_f, dut.u_engine.vrec[26]);
        if (dut.u_engine.mix_valid)
            $fwrite(fd, "M %0d %0d\n", now, dut.u_engine.mix_out);
    end

    // ---------------- I2S receiver: MSB one BCLK after each LRCLK edge, 16 bits
    logic        lr_prev = 0;
    int          bitn = 99;
    logic [15:0] shl, shr;
    int          lr_mismatch = 0;
    logic [15:0] left_word;
    always @(posedge BCLK) begin
        if (LRCLK != lr_prev) bitn = 0; else bitn = bitn + 1;
        lr_prev = LRCLK;
        if (bitn >= 1 && bitn <= 16) begin
            if (!LRCLK) shl = {shl[14:0], DOUT}; else shr = {shr[14:0], DOUT};
            if (bitn == 16) begin
                if (!LRCLK) begin left_word = shl; $fwrite(fd, "I %0d\n", shl); end
                else if (shr != left_word) lr_mismatch++;
            end
        end
    end

    // ---------------- stimulus
    logic [47:0] events [0:1023];
    int          n_events;
    initial begin
        for (int i = 0; i < 1024; i++) events[i] = 48'hFFFF_FFFF_FFFF;
        void'($value$plusargs("events=%s", ev_file));
        void'($value$plusargs("end=%d", END_SAMPLE));
        void'($value$plusargs("log=%s", log_file));
        $readmemh(ev_file, events);
        n_events = 0;
        while (events[n_events] !== 48'hFFFF_FFFF_FFFF) n_events++;
        fd = $fopen(log_file, "w");
        #200 rst = 0;
        wait (boot_done || boot_err);
        $display("boot %s at sample %0d", boot_err ? "ERROR" : "done", now);
        for (int i = 0; i < n_events; i++) begin
            while (now < events[i][47:16]) @(posedge clk);
            evq.push_back(events[i][15:0]);
        end
        while (now < END_SAMPLE) @(posedge clk);
        $fwrite(fd, "F %0d %0d %0d\n", underrun, overrun, lr_mismatch);
        $fwrite(fd, "W %0d\n", max_walk);
        $fclose(fd);
        $display("audio_core_tb: ran to sample %0d, underrun=%0d overrun=%0d", now, underrun, overrun);
        $finish;
    end
endmodule
