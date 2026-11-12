// lpc_rice_decoder_tb.sv — self-checking testbench for lpc_rice_decoder
//
// Vectors come from tb/gen_lpc_rice_vectors.py (real frames copied out of
// Rhodes_Sample_Libary/flash_image.bin plus synthetic edge cases). Each test is
// streamed into the decoder through a flash-like valid/ready word port and every
// decoded sample is compared against the packer's reference decoder.
//
// Every test runs twice:
//   pass 0 - no stalls (also reports clocks per sample)
//   pass 1 - random input stalls and output backpressure (handshake stress)
//
// Per test it checks: all samples bit-exact, exact sample count, the decoder
// consumed exactly the test's stream words (no more, no less), done pulsed,
// err stayed low, and no stray output after done.
//
// Test 0 is one complete sample file. Its decoded output (pass 0) is copied to
// audio_out (view it as an analog waveform) and written to WAV_FILE, a 16-bit
// mono 44.1 kHz .wav you can play and compare against the original sample. The
// testbench also writes lpc_rice_zoom.do (zooms the wave window onto that test).
//
// Plusargs:
//   +VEC_DIR=<path/>   vector folder, default ../../tb/vectors/ (Questa runs in sim/out)
//   +WAV_FILE=<name>   default lpc_rice_whole_file.wav (written to the run folder)
//   +STALL_PCT=<n>     stall/backpressure probability for pass 1, default 30
//   +SEED=<n>          random seed, default 1
`timescale 1ns/1ps

module lpc_rice_decoder_tb;

    localparam int STREAM_DEPTH   = 1 << 18;
    localparam int EXPECTED_DEPTH = 1 << 20;
    localparam int MAX_TESTS      = 64;
    localparam int TIMEOUT_CYCLES = 200;   // per sample, generous for long unary runs

    logic clk = 0;
    logic rst = 1;

    always #10 clk = ~clk;  // 50 MHz

    // DUT ports
    logic        start = 1'b0;
    logic [23:0] num_samples = '0;
    wire         busy, done, err;
    logic        in_valid;
    logic [15:0] in_data;
    wire         in_ready;
    wire         out_valid;
    wire  [15:0] out_data;
    logic        out_ready;

    lpc_rice_decoder dut (
        .clk         (clk),
        .rst         (rst),
        .start       (start),
        .num_samples (num_samples),
        .busy        (busy),
        .done        (done),
        .err         (err),
        .in_valid    (in_valid),
        .in_data     (in_data),
        .in_ready    (in_ready),
        .out_valid   (out_valid),
        .out_data    (out_data),
        .out_ready   (out_ready)
    );

    // Vector memories
    logic [15:0] stream_mem   [0:STREAM_DEPTH-1];
    logic [15:0] expected_mem [0:EXPECTED_DEPTH-1];
    logic [31:0] tests_mem    [0:4*MAX_TESTS+1];

    string vec_dir;
    string wav_file;
    int    stall_pct;
    int    seed;

    int checks = 0;
    int errors = 0;

    task automatic check(input bit cond, input string msg);
        checks++;
        if (!cond) begin
            errors++;
            $display("  ERROR: %s", msg);
        end
    endtask

    // 1. Flash-side word source: streams stream_mem[rd_ptr .. rd_end-1]
    int  rd_ptr = 0;
    int  rd_end = 0;
    bit  stall_en = 0;
    bit  in_stall = 0;
    bit  out_stall = 0;

    assign in_valid  = (rd_ptr < rd_end) && !in_stall;
    assign in_data   = in_valid ? stream_mem[rd_ptr] : 16'hXXXX;
    assign out_ready = !out_stall;

    always @(posedge clk) begin
        if (in_valid && in_ready)
            rd_ptr <= rd_ptr + 1;
        in_stall  <= stall_en && (($urandom % 100) < stall_pct);
        out_stall <= stall_en && (($urandom % 100) < stall_pct);
    end

    // 2. Output checker: compares every accepted sample with expected_mem
    int  exp_ptr = 0;
    int  exp_end = 0;
    int  got = 0;
    int  mismatches = 0;
    bit  checking = 0;
    bit  after_done = 0;
    int  stray = 0;

    always @(posedge clk) begin
        if (out_valid && out_ready) begin
            if (after_done)
                stray++;
            else if (checking) begin
                if (exp_ptr >= exp_end) begin
                    mismatches++;
                    if (mismatches <= 5)
                        $display("  extra sample %0d: got %04h", got, out_data);
                end else if (out_data !== expected_mem[exp_ptr]) begin
                    mismatches++;
                    if (mismatches <= 5)
                        $display("  sample %0d mismatch: got %04h expected %04h",
                                 got, out_data, expected_mem[exp_ptr]);
                end
                exp_ptr <= exp_ptr + 1;
                got     <= got + 1;
            end
        end
    end

    // 3. Whole-file capture: analog view + .wav
    logic signed [15:0] audio_out = '0;   // last sample of the whole-file test, for the wave window
    bit     dumping  = 0;
    integer wav_fd   = 0;
    int     dump_idx = 0;                 // from lpc_rice_tests.hex line 1
    real    dump_t0  = 0, dump_t1 = 0;    // sim time span of the whole-file test

    task automatic wav_le(input int value, input int nbytes);
        for (int b = 0; b < nbytes; b++)
            $fwrite(wav_fd, "%c", (value >> (8*b)) & 8'hFF);
    endtask

    task automatic wav_open(input int nsamp);
        wav_fd = $fopen(wav_file, "wb");
        if (wav_fd == 0) begin
            $display("  WARNING: could not open %s, no .wav written", wav_file);
            return;
        end
        $fwrite(wav_fd, "RIFF");  wav_le(36 + 2*nsamp, 4);
        $fwrite(wav_fd, "WAVEfmt ");
        wav_le(16, 4);            // fmt chunk size
        wav_le(1, 2);             // PCM
        wav_le(1, 2);             // mono
        wav_le(44100, 4);         // sample rate
        wav_le(88200, 4);         // byte rate
        wav_le(2, 2);             // block align
        wav_le(16, 2);            // bits per sample
        $fwrite(wav_fd, "data");  wav_le(2*nsamp, 4);
    endtask

    always @(posedge clk) begin
        if (dumping && checking && !after_done && out_valid && out_ready) begin
            audio_out <= out_data;
            if (wav_fd != 0) begin
                $fwrite(wav_fd, "%c%c", out_data[7:0], out_data[15:8]);
            end
        end
    end

    // 4. Run one test
    task automatic run_test(input int idx, input int pass);
        int start_word, words, nsamp, exp_off;
        int cycles, limit;
        bit timed_out;
        string tag;

        start_word = tests_mem[2 + 4*idx];
        words      = tests_mem[3 + 4*idx];
        nsamp      = tests_mem[4 + 4*idx];
        exp_off    = tests_mem[5 + 4*idx];
        tag        = $sformatf("test %0d pass %0d", idx, pass);

        // Reset between tests so a sticky err from one test can't hide in the next
        rst = 1'b1;
        repeat (2) @(posedge clk);
        rst = 1'b0;

        @(negedge clk);
        rd_ptr     = start_word;
        rd_end     = start_word + words;
        exp_ptr    = exp_off;
        exp_end    = exp_off + nsamp;
        got        = 0;
        mismatches = 0;
        stray      = 0;
        after_done = 0;
        checking   = 1;
        stall_en   = (pass == 1);
        dumping    = (pass == 0) && (idx == dump_idx);
        if (dumping) begin
            wav_open(nsamp);
            dump_t0 = $realtime;
        end

        num_samples = nsamp[23:0];
        start       = 1'b1;
        @(negedge clk);
        start       = 1'b0;

        cycles    = 0;
        limit     = TIMEOUT_CYCLES * (nsamp + 16);
        timed_out = 0;
        while (!done && !timed_out) begin
            @(posedge clk);
            #1;
            cycles++;
            if (cycles > limit)
                timed_out = 1;
        end

        @(negedge clk);
        after_done = 1;
        stall_en   = 0;
        if (dumping) begin
            dumping = 0;
            dump_t1 = $realtime;
            if (wav_fd != 0) begin
                $fclose(wav_fd);
                wav_fd = 0;
                $display("  test %0d decoded output written to %s (%0d samples, %0.2f s of audio)",
                         idx, wav_file, nsamp, nsamp / 44100.0);
            end
        end
        repeat (20) @(posedge clk);
        checking   = 0;
        after_done = 0;

        check(!timed_out,              $sformatf("%s: timed out after %0d clocks", tag, cycles));
        check(mismatches == 0,         $sformatf("%s: %0d sample mismatches", tag, mismatches));
        check(got == nsamp,            $sformatf("%s: got %0d samples, expected %0d", tag, got, nsamp));
        check(rd_ptr == rd_end,        $sformatf("%s: consumed %0d of %0d stream words",
                                                 tag, rd_ptr - start_word, words));
        check(!err,                    $sformatf("%s: err asserted", tag));
        check(!busy,                   $sformatf("%s: still busy after done", tag));
        check(stray == 0,              $sformatf("%s: %0d stray samples after done", tag, stray));

        if (pass == 0)
            $display("  test %2d: %6d samples, %6d words, %7d clocks (%0.2f clk/sample)%s",
                     idx, nsamp, words, cycles, real'(cycles) / nsamp,
                     (mismatches == 0 && got == nsamp && !timed_out) ? "" : "  <-- FAIL");
    endtask

    // 5. Main sequence
    initial begin
        int ntests;
        int total_samples;

        if (!$value$plusargs("VEC_DIR=%s", vec_dir))     vec_dir   = "../../tb/vectors/";
        if (!$value$plusargs("STALL_PCT=%d", stall_pct)) stall_pct = 30;
        if (!$value$plusargs("SEED=%d", seed))           seed      = 1;
        if (!$value$plusargs("WAV_FILE=%s", wav_file))   wav_file  = "lpc_rice_whole_file.wav";
        void'($urandom(seed));

        $readmemh({vec_dir, "lpc_rice_stream.hex"},   stream_mem);
        $readmemh({vec_dir, "lpc_rice_expected.hex"}, expected_mem);
        $readmemh({vec_dir, "lpc_rice_tests.hex"},    tests_mem);
        ntests   = tests_mem[0];
        dump_idx = tests_mem[1];
        if (ntests == 0 || ntests > MAX_TESTS) begin
            $display("ERROR: bad test count %0d - check +VEC_DIR (%s)", ntests, vec_dir);
            $stop;
        end

        $display("lpc_rice_decoder_tb: %0d tests from %s (names in lpc_rice_tests.txt)",
                 ntests, vec_dir);
        total_samples = 0;
        for (int t = 0; t < ntests; t++)
            total_samples += tests_mem[4 + 4*t];

        $display("Pass 0: no stalls");
        for (int t = 0; t < ntests; t++)
            run_test(t, 0);

        // Zoom script for the GUI: frames the whole-file test in the wave window
        begin : write_zoom
            integer zfd;
            zfd = $fopen("lpc_rice_zoom.do", "w");
            if (zfd != 0) begin
                $fwrite(zfd, "wave zoom range %0.0fns %0.0fns\n", dump_t0, dump_t1);
                $fclose(zfd);
            end
            $display("  whole-file test %0d spans %0.3f ms .. %0.3f ms of sim time",
                     dump_idx, dump_t0 / 1.0e6, dump_t1 / 1.0e6);
        end

        $display("Pass 1: random stalls/backpressure (%0d%%)", stall_pct);
        for (int t = 0; t < ntests; t++)
            run_test(t, 1);

        // num_samples = 0 must finish immediately without touching the stream
        begin : zero_length_test
            rst = 1'b1;
            repeat (2) @(posedge clk);
            rst = 1'b0;
            @(negedge clk);
            rd_ptr = 0;
            rd_end = 0;
            num_samples = 24'd0;
            start = 1'b1;
            @(posedge clk);
            #1;
            check(done, "zero-length file: done pulses on the start clock");
            @(negedge clk);
            start = 1'b0;
            check(!busy, "zero-length file: not busy");
        end

        $display("--------------------------------------------------");
        $display("%0d samples decoded per pass", total_samples);
        $display("SIM DONE: %0d checks, %0d errors", checks, errors);
        if (errors == 0)
            $display("RESULT: PASS");
        else
            $display("RESULT: FAIL");
        $stop;
    end

endmodule
