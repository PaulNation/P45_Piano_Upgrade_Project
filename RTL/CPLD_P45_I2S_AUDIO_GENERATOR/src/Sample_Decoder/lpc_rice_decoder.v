// lpc_rice_decoder.v — single-voice streaming decoder for the LPC + Golomb-Rice
// flash image (format v3) built by Rhodes_Sample_Libary/lpc_rice_flash_packer.py.
//
// The caller looks up a file in the image's file table (start word address and
// sample count), streams the file's words in order starting at its first frame
// header, and pulses start with num_samples. The decoder consumes exactly the
// file's words (every payload word, including padding) and emits num_samples
// signed 16-bit samples. Frames are independent, so a stream may also start at
// any frame header with num_samples = a multiple of FRAME_SAMPLES.
//
// Frame format (all words 16-bit):
//   header [15:12] k (0..8) or 4'hF = RAW frame
//          [11:10] predictor order - 1 (order 1..4, ignored for RAW)
//          [9:0]   payload length in words - 1 (1..1024)
//   RAW  : n plain samples
//   Rice : `order` plain warm-up samples, then Rice codes for the remaining
//          samples, MSB-first per word, zero-padded to the end of the payload.
//   code : q ones, a 0, then k remainder bits; u = (q << k) | rem
//   value: r = unzigzag(u); x = P + r (mod 2^16), P from the fixed polynomial
//          p1 = x1, p2 = 2x1-x2, p3 = 3x1-3x2+x3, p4 = 4x1-6x2+4x3-x4
//
// Throughput: one sample per clock while codes fit in the bit buffer; longer
// unary runs take one extra clock per buffer refill.
module lpc_rice_decoder #(
    parameter FRAME_SAMPLES = 1024,
    parameter NSAMP_W       = 24
) (
    input  wire               clk,
    input  wire               rst,

    // Control
    input  wire               start,        // one-clock pulse, only accepted when !busy
    input  wire [NSAMP_W-1:0] num_samples,  // samples in this file (from the file table)
    output wire               busy,
    output reg                done,         // one-clock pulse after the last sample is accepted
    output reg                err,          // sticky: bad header or stream ran out mid-code

    // Compressed word stream (flash / prefetch FIFO side)
    input  wire               in_valid,
    input  wire [15:0]        in_data,
    output reg                in_ready,

    // Decoded samples
    output reg                out_valid,
    output reg  [15:0]        out_data,     // signed 16-bit PCM
    input  wire               out_ready
);

    localparam [2:0] S_IDLE = 3'd0,
                     S_HDR  = 3'd1,
                     S_RAW  = 3'd2,
                     S_WARM = 3'd3,
                     S_RICE = 3'd4,
                     S_FEND = 3'd5,
                     S_LAST = 3'd6;

    localparam [3:0]  K_RAW   = 4'hF;
    localparam [10:0]        FRAME_N  = FRAME_SAMPLES;
    localparam [NSAMP_W-1:0] FRAME_NW = FRAME_SAMPLES;

    reg  [2:0]          state;
    reg  [NSAMP_W-1:0]  samples_left;   // samples still to emit for the file
    reg  [10:0]         frame_left;     // samples still to emit for this frame
    reg  [10:0]         words_left;     // payload words not yet taken from the stream
    reg  [2:0]          warm_left;      // warm-up words still to read
    reg  [3:0]          k;
    reg  [2:0]          order;          // 1..4

    reg  [15:0]         x1, x2, x3, x4; // predictor history, x1 = newest

    reg  [31:0]         bitbuf;         // MSB-aligned; bits below the valid ones are always 0
    reg  [5:0]          nbits;          // valid bits in bitbuf, 0..32
    reg  [15:0]         q_acc;          // unary ones already consumed for the current code

    assign busy = (state != S_IDLE);

    wire out_free = !out_valid || out_ready;
    wire take     = in_valid && in_ready;

    // 1. Header fields
    wire [3:0]  hdr_k     = in_data[15:12];
    wire [2:0]  hdr_order = {1'b0, in_data[11:10]} + 3'd1;
    wire [10:0] hdr_len   = {1'b0, in_data[9:0]} + 11'd1;
    wire [10:0] hdr_n     = (samples_left >= FRAME_NW) ? FRAME_N : samples_left[10:0];

    // 2. Predictor (all arithmetic mod 2^16, carries dropped)
    wire [15:0] d    = x1 - x2;
    wire [15:0] p2   = x1 + d;
    wire [15:0] p3   = x3 + (d << 1) + d;
    wire [15:0] p4   = ((x1 + x3) << 2) - (x2 << 2) - (x2 << 1) - x4;
    reg  [15:0] pred;
    always @(*) begin
        case (order)
            3'd1:    pred = x1;
            3'd2:    pred = p2;
            3'd3:    pred = p3;
            default: pred = p4;
        endcase
    end

    // 3. Count leading ones of the bit buffer (0..32). Invalid bits are 0, so the
    //    count never runs past nbits. Scanning LSB->MSB, the last zero found is
    //    the highest one, i.e. the end of the unary run.
    reg [5:0] lo;
    integer   i;
    always @(*) begin
        lo = 6'd32;
        for (i = 0; i < 32; i = i + 1)
            if (!bitbuf[i])
                lo = 6'd31 - i[5:0];
    end

    // 4. Rice code: complete this clock if the terminator and all k remainder
    //    bits are in the buffer; otherwise consume the leading ones and wait.
    wire [6:0]  need      = {1'b0, lo} + 7'd1 + {3'b0, k};
    wire        code_done = (lo < nbits) && (need <= {1'b0, nbits});
    /* verilator lint_off UNUSED */
    wire [31:0] after_q   = bitbuf << (lo + 6'd1);   // only the top k bits are used
    /* verilator lint_on UNUSED */
    wire [7:0]  rem       = after_q[31:24] >> (4'd8 - k);
    wire [15:0] q_total   = q_acc + {10'd0, lo};
    wire [15:0] u         = (q_total << k) | {8'd0, rem};
    wire [15:0] r         = {1'b0, u[15:1]} ^ {16{u[0]}};
    wire [15:0] x_rice    = pred + r;

    wire        rice_go   = (state == S_RICE) && (frame_left != 0) && out_free;
    wire [5:0]  shamt     = !rice_go  ? 6'd0 :
                            code_done ? need[5:0] : lo;

    // 5. Bit buffer refill: room for a word whenever <= 16 bits are valid
    wire        rice_want = (state == S_RICE) && (nbits <= 6'd16) && (words_left != 0);
    wire [31:0] buf_sh    = (shamt == 6'd32) ? 32'd0 : (bitbuf << shamt);
    wire [5:0]  nb_sh     = nbits - shamt;

    // 6. Stream handshake
    always @(*) begin
        case (state)
            S_HDR:   in_ready = 1'b1;
            S_RAW:   in_ready = out_free && (frame_left != 0);
            S_WARM:  in_ready = out_free;
            S_RICE:  in_ready = rice_want;
            S_FEND:  in_ready = (words_left != 0);
            default: in_ready = 1'b0;
        endcase
    end

    // 7. Main sequencer
    always @(posedge clk or posedge rst) begin
        if (rst) begin
            state        <= S_IDLE;
            samples_left <= {NSAMP_W{1'b0}};
            frame_left   <= 11'd0;
            words_left   <= 11'd0;
            warm_left    <= 3'd0;
            k            <= 4'd0;
            order        <= 3'd1;
            x1 <= 16'd0; x2 <= 16'd0; x3 <= 16'd0; x4 <= 16'd0;
            bitbuf       <= 32'd0;
            nbits        <= 6'd0;
            q_acc        <= 16'd0;
            out_valid    <= 1'b0;
            out_data     <= 16'd0;
            done         <= 1'b0;
            err          <= 1'b0;
        end else begin
            done <= 1'b0;
            if (out_valid && out_ready)
                out_valid <= 1'b0;

            case (state)
                S_IDLE: begin
                    if (start) begin
                        samples_left <= num_samples;
                        state        <= (num_samples == 0) ? S_IDLE : S_HDR;
                        done         <= (num_samples == 0);
                    end
                end

                S_HDR: begin
                    if (take) begin
                        k          <= hdr_k;
                        order      <= hdr_order;
                        frame_left <= hdr_n;
                        words_left <= hdr_len;
                        warm_left  <= hdr_order;
                        bitbuf     <= 32'd0;
                        nbits      <= 6'd0;
                        q_acc      <= 16'd0;
                        if (hdr_k == K_RAW)
                            state <= S_RAW;
                        else begin
                            state <= S_WARM;
                            if (hdr_k > 4'd8)
                                err <= 1'b1;
                        end
                    end
                end

                S_RAW: begin
                    if (take) begin
                        out_valid    <= 1'b1;
                        out_data     <= in_data;
                        words_left   <= words_left - 11'd1;
                        frame_left   <= frame_left - 11'd1;
                        samples_left <= samples_left - 1'b1;
                        if (frame_left == 11'd1)
                            state <= S_FEND;
                    end
                end

                S_WARM: begin
                    if (take) begin
                        out_valid    <= 1'b1;
                        out_data     <= in_data;
                        x4 <= x3; x3 <= x2; x2 <= x1; x1 <= in_data;
                        words_left   <= words_left - 11'd1;
                        frame_left   <= frame_left - 11'd1;
                        samples_left <= samples_left - 1'b1;
                        warm_left    <= warm_left - 3'd1;
                        if (warm_left == 3'd1)
                            state <= S_RICE;
                    end
                end

                S_RICE: begin
                    // Consume decoded bits and append a refill word in the same clock
                    if (take) begin
                        bitbuf     <= buf_sh | ({in_data, 16'd0} >> nb_sh);
                        nbits      <= nb_sh + 6'd16;
                        words_left <= words_left - 11'd1;
                    end else begin
                        bitbuf     <= buf_sh;
                        nbits      <= nb_sh;
                    end

                    if (rice_go) begin
                        if (code_done) begin
                            q_acc        <= 16'd0;
                            out_valid    <= 1'b1;
                            out_data     <= x_rice;
                            x4 <= x3; x3 <= x2; x2 <= x1; x1 <= x_rice;
                            frame_left   <= frame_left - 11'd1;
                            samples_left <= samples_left - 1'b1;
                            if (frame_left == 11'd1)
                                state <= S_FEND;
                        end else begin
                            q_acc <= q_total;
                            // Out of payload with a code still open: malformed stream
                            if (words_left == 0 && lo == 6'd0)
                                err <= 1'b1;
                        end
                    end
                end

                S_FEND: begin
                    // Drop any padding words the bitstream did not need
                    if (take)
                        words_left <= words_left - 11'd1;
                    if (words_left == 11'd0 || (take && words_left == 11'd1)) begin
                        if (samples_left == 0)
                            state <= S_LAST;
                        else
                            state <= S_HDR;
                    end
                end

                S_LAST: begin
                    // Hold done until the last sample has left the output register
                    if (out_free) begin
                        state <= S_IDLE;
                        done  <= 1'b1;
                    end
                end

                default: state <= S_IDLE;
            endcase
        end
    end

endmodule
