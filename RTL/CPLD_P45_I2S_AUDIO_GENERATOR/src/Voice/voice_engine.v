// voice_engine.v — time-shared playback of all voices: sequencer + decoder + refill + mixer.
//
// Every sample period (PERIOD clocks, 1024 at 45.1584 MHz = 44.1 kHz) the sequencer walks the
// voice slots 0..NV-1:
//   idle slot (not alive, nothing pending)     1 clock
//   voice RAM changed (manager wrote it)       re-read the record; new gen -> restart from the
//                                              start of its file (file table lookup)
//   alive voice                                load its decoder context, decode ONE sample,
//                                              store the context, send the sample to the mixer
// The decoder logic is lpc_rice_decoder.v's, with its registers loaded from / stored to a
// per-voice context RAM, and its input words read from the voice's 64-word buffer.
//
// Refill (runs all the time, in parallel): for each voice whose buffer has >= 16 free words,
// reads 16 words from flash (flash_reader) at the voice's next flash address. A restart first
// resets the voice's buffer and flash address to the file start.
//
// Mixer: y = ((s * gain) >>> 14) * fade >>> 15  (gain Q2.14 from the voice record, fade Q1.15 from
// fade.mem while the voice is fading, else 32768); the sum of all voices (>>> MIX_SHIFT) times the
// master volume (master_gain, Q2.14) is saturated to 16 bits at the end of the period.
//
// Status flags (sticky): underrun = a voice's buffer ran dry mid-sample (that voice skipped one
// sample); overrun = the voice walk did not finish within the period.
`ifndef TABLES_DIR
`define TABLES_DIR "../../src/Sample_Decoder/tables/"
`endif

module voice_engine #(
    parameter NV          = 208,
    parameter PERIOD      = 1024,
    parameter MIX_SHIFT   = 0,
    parameter STEP_LIMIT  = 24          // decode clocks per voice per sample before giving up
) (
    input  wire        clk,
    input  wire        rst,
    input  wire        enable,          // boot done
    input  wire [15:0] master_gain,     // Q2.14, applied to the mix before the 16-bit saturation

    output reg         sample_tick,     // one clock at the start of every period
    output reg  [15:0] mix_out,         // mix of the previous period, signed 16 bit
    output reg         mix_valid,       // one clock when mix_out updates

    // voice manager: voice RAM read port + "slot written" strobe
    output reg  [7:0]  vb_addr,
    input  wire [29:0] vb_data,
    input  wire        vw_strobe,
    input  wire [7:0]  vw_addr,

    // file table (flash_boot)
    output reg  [9:0]  tab_addr,
    input  wire [24:0] tab_start,
    input  wire [23:0] tab_samples,

    // flash_reader
    output reg         fr_req,
    output reg  [24:0] fr_addr,
    input  wire        fr_busy,
    input  wire        fr_valid,
    input  wire [15:0] fr_data,

    output reg         underrun,
    output reg         overrun,
    output wire        seq_idle         // waiting for the next period (for tests)
);

    // ================================================================ period timer
    localparam PW = $clog2(PERIOD);
    localparam integer  PLAST_I = PERIOD - 1;
    localparam [PW-1:0] PLAST   = PLAST_I[PW-1:0];
    reg [PW-1:0] pcnt;
    always @(posedge clk or posedge rst) begin
        if (rst) begin
            pcnt        <= 0;
            sample_tick <= 1'b0;
        end else begin
            pcnt        <= (pcnt == PLAST) ? {PW{1'b0}} : pcnt + 1'b1;
            sample_tick <= (pcnt == PLAST);
        end
    end

    // ================================================================ per-voice state
    reg       alive    [0:NV-1];        // voice is playing (sequencer)
    reg       pending  [0:NV-1];        // voice RAM written since last read (manager sets)
    reg       rst_req  [0:NV-1];        // restart waiting for the refill (seq sets, refill clears)
    reg [6:0] rd_ptr   [0:NV-1];        // buffer read pointer (sequencer), with wrap bit
    reg [6:0] wr_ptr   [0:NV-1];        // buffer write pointer (refill), with wrap bit

    // ---- context RAM
    // {state 3, samples 24, frame 11, words 11, warm 3, k 4, order 3, x1..x4 64, bitbuf 32,
    //  nbits 6, q 16, gen 2, fpos 10}  = 189 bits
    localparam CW = 189;
    reg [CW-1:0] ctx_ram [0:NV-1];
    reg [CW-1:0] ctx_q;
    reg [7:0]    ctx_raddr, ctx_waddr;
    reg          ctx_we;
    reg [CW-1:0] ctx_wdata;
    always @(posedge clk) begin
        if (ctx_we) ctx_ram[ctx_waddr] <= ctx_wdata;
        ctx_q <= ctx_ram[ctx_raddr];
    end

    // ---- sample buffers: 64 words per voice, address {voice, index}
    // Read address is combinational (show-ahead: buf_q always holds the word at the voice's read
    // pointer); a write to the word being read in the same clock is forwarded (write-first).
    reg [15:0] buf_ram [0:16383];
    reg [13:0] buf_waddr;
    wire [13:0] buf_raddr;
    reg        buf_we;
    reg [15:0] buf_wdata, buf_q;
    always @(posedge clk) begin
        if (buf_we) buf_ram[buf_waddr] <= buf_wdata;
        buf_q <= (buf_we && buf_waddr == buf_raddr) ? buf_wdata : buf_ram[buf_raddr];
    end

    // ---- restart address (seq writes) and next flash address (refill) per voice
    reg [24:0] raddr_ram [0:NV-1];
    reg [24:0] fetch_ram [0:NV-1];
    reg [24:0] raddr_q, fetch_q;
    reg [7:0]  ra_raddr, fa_raddr, fa_waddr, ra_waddr;
    reg        ra_we, fa_we;
    reg [24:0] ra_wdata, fa_wdata;
    always @(posedge clk) begin
        if (ra_we) raddr_ram[ra_waddr] <= ra_wdata;
        if (fa_we) fetch_ram[fa_waddr] <= fa_wdata;
        raddr_q <= raddr_ram[ra_raddr];
        fetch_q <= fetch_ram[fa_raddr];
    end

    reg [15:0] fade_rom [0:511];
    integer ii;
    initial begin
        for (ii = 0; ii < NV; ii = ii + 1) ctx_ram[ii] = {CW{1'b0}};
        $readmemh({`TABLES_DIR, "fade.mem"}, fade_rom);
    end

    // ================================================================ decoder (one voice)
    localparam [2:0] S_HDR = 3'd1, S_RAW = 3'd2, S_WARM = 3'd3, S_RICE = 3'd4, S_FEND = 3'd5;
    localparam [3:0] K_RAW = 4'hF;

    reg  [2:0]  c_state;
    reg  [23:0] c_samples;
    reg  [10:0] c_frame, c_words;
    reg  [2:0]  c_warm, c_order;
    reg  [3:0]  c_k;
    reg  [15:0] c_x1, c_x2, c_x3, c_x4;
    reg  [31:0] c_buf;
    reg  [5:0]  c_nbits;
    reg  [15:0] c_q;
    reg  [1:0]  c_gen;
    reg  [9:0]  c_fpos;
    reg  [6:0]  c_rd;
    reg  [29:0] vrec;
    reg  [7:0]  v;

    wire [6:0]  avail    = wr_ptr[v] - c_rd;
    wire        in_valid = (avail != 7'd0) && !rst_req[v];
    wire [15:0] in_data  = buf_q;

    wire [3:0]  hdr_k     = in_data[15:12];
    wire [2:0]  hdr_order = {1'b0, in_data[11:10]} + 3'd1;
    wire [10:0] hdr_len   = {1'b0, in_data[9:0]} + 11'd1;
    wire [10:0] hdr_n     = (c_samples >= 24'd1024) ? 11'd1024 : c_samples[10:0];

    wire [15:0] d  = c_x1 - c_x2;
    wire [15:0] p2 = c_x1 + d;
    wire [15:0] p3 = c_x3 + (d << 1) + d;
    wire [15:0] p4 = ((c_x1 + c_x3) << 2) - (c_x2 << 2) - (c_x2 << 1) - c_x4;
    reg  [15:0] pred;
    always @(*) begin
        case (c_order)
            3'd1:    pred = c_x1;
            3'd2:    pred = p2;
            3'd3:    pred = p3;
            default: pred = p4;
        endcase
    end

    reg [5:0] lo;
    integer   bi;
    always @(*) begin
        lo = 6'd32;
        for (bi = 0; bi < 32; bi = bi + 1)
            if (!c_buf[bi]) lo = 6'd31 - bi[5:0];
    end

    wire [6:0]  need      = {1'b0, lo} + 7'd1 + {3'b0, c_k};
    wire        code_done = (lo < c_nbits) && (need <= {1'b0, c_nbits});
    wire [31:0] after_q   = c_buf << (lo + 6'd1);
    wire [7:0]  rem       = after_q[31:24] >> (4'd8 - c_k);
    wire [15:0] q_total   = c_q + {10'd0, lo};
    wire [15:0] u         = (q_total << c_k) | {8'd0, rem};
    wire [15:0] r         = {1'b0, u[15:1]} ^ {16{u[0]}};
    wire [15:0] x_rice    = pred + r;

    wire        rice_go   = (c_state == S_RICE) && (c_frame != 0);
    wire [5:0]  shamt     = !rice_go ? 6'd0 : code_done ? need[5:0] : lo;
    wire        rice_want = (c_state == S_RICE) && (c_nbits <= 6'd16) && (c_words != 0);
    wire [31:0] buf_sh    = (shamt == 6'd32) ? 32'd0 : (c_buf << shamt);
    wire [5:0]  nb_sh     = c_nbits - shamt;

    reg in_ready;
    always @(*) begin
        case (c_state)
            S_HDR:   in_ready = 1'b1;
            S_RAW:   in_ready = (c_frame != 0);
            S_WARM:  in_ready = 1'b1;
            S_RICE:  in_ready = rice_want;
            S_FEND:  in_ready = (c_words != 0);
            default: in_ready = 1'b0;
        endcase
    end
    wire take = in_valid && in_ready;

    // ================================================================ sequencer
    localparam [3:0] Q_WAIT = 4'd0, Q_SCAN = 4'd1, Q_LOAD = 4'd2, Q_EVAL = 4'd3, Q_TAB = 4'd4,
                     Q_RESTART = 4'd5, Q_RUN = 4'd6, Q_STORE = 4'd7, Q_FIN1 = 4'd8, Q_FIN2 = 4'd9,
                     Q_FIN3 = 4'd10, Q_TAB2 = 4'd11, Q_FIN4 = 4'd12;
    reg [3:0] q;
    reg [4:0] steps;
    reg       v_done;                    // voice finished with this sample
    reg       store_rd;                  // write c_rd back at Q_STORE

    assign seq_idle = (q == Q_WAIT);
    assign buf_raddr = (q == Q_SCAN) ? {v, rd_ptr[v][5:0]} :
                       (q == Q_RUN && take) ? {v, c_rd[5:0] + 6'd1} : {v, c_rd[5:0]};

    // mixer pipeline
    reg               m_valid, m2_valid;
    reg signed [15:0] m_s;
    reg        [15:0] m_g, m_f;
    reg signed [18:0] m_y1;
    reg        [15:0] m2_f;
    reg signed [27:0] acc;

    wire signed [32:0] prod1 = m_s * $signed({1'b0, m_g});
    wire signed [35:0] prod2 = m_y1 * $signed({1'b0, m2_f});
    wire signed [32:0] y1_full = prod1 >>> 14;
    wire signed [35:0] y2_full = prod2 >>> 15;
    wire signed [27:0] acc_sh  = acc >>> MIX_SHIFT;
    reg  signed [44:0] vol_prod;
    wire signed [44:0] vol_sh  = vol_prod >>> 14;

    // does this decoder step produce a sample (Q_RUN)?
    reg        emit;
    reg [15:0] emit_val;
    always @(*) begin
        emit     = 1'b0;
        emit_val = 16'd0;
        case (c_state)
            S_RAW, S_WARM: if (take) begin emit = 1'b1; emit_val = in_data; end
            S_RICE:        if (rice_go && code_done) begin emit = 1'b1; emit_val = x_rice; end
            default: ;
        endcase
    end

    // manager "slot written" strobes and refill restart acks (single writers per clock below)
    reg       rf_rst_clr;
    reg [7:0] rf_rst_v;

    integer vi;
    always @(posedge clk or posedge rst) begin
        if (rst) begin
            for (vi = 0; vi < NV; vi = vi + 1) begin
                alive[vi] <= 1'b0; pending[vi] <= 1'b0; rst_req[vi] <= 1'b0; rd_ptr[vi] <= 7'd0;
            end
            q <= Q_WAIT; v <= 8'd0; steps <= 0; v_done <= 1'b0; store_rd <= 1'b0;
            ctx_we <= 1'b0; ctx_raddr <= 0; ctx_waddr <= 0; ctx_wdata <= 0;
            vb_addr <= 0; tab_addr <= 0;
            ra_we <= 1'b0; ra_waddr <= 0; ra_wdata <= 0;
            c_state <= 0; c_samples <= 0; c_frame <= 0; c_words <= 0; c_warm <= 0; c_order <= 3'd1;
            c_k <= 0; c_x1 <= 0; c_x2 <= 0; c_x3 <= 0; c_x4 <= 0; c_buf <= 0; c_nbits <= 0;
            c_q <= 0; c_gen <= 0; c_fpos <= 0; c_rd <= 0; vrec <= 0;
            m_valid <= 1'b0; m2_valid <= 1'b0; m_s <= 0; m_g <= 0; m_f <= 0; m_y1 <= 0; m2_f <= 0;
            acc <= 0; vol_prod <= 0; mix_out <= 0; mix_valid <= 1'b0; underrun <= 1'b0; overrun <= 1'b0;
        end else begin
            ctx_we    <= 1'b0;
            ra_we     <= 1'b0;
            m_valid   <= 1'b0;
            mix_valid <= 1'b0;

            // pending: manager sets (wins), sequencer clears in Q_EVAL
            if (q == Q_EVAL) pending[v] <= 1'b0;
            if (vw_strobe)   pending[vw_addr] <= 1'b1;
            // restart request: sequencer sets in Q_RESTART, refill clears
            if (rf_rst_clr)  rst_req[rf_rst_v] <= 1'b0;

            // ---- mixer pipeline (runs alongside the voice walk)
            m2_valid <= m_valid;
            if (m_valid) begin
                m_y1 <= y1_full[18:0];
                m2_f <= m_f;
            end
            if (m2_valid)
                acc <= acc + y2_full[27:0];

            if (sample_tick && q != Q_WAIT)
                overrun <= 1'b1;

            case (q)
                Q_WAIT:
                    if (sample_tick && enable) begin
                        acc <= 0;
                        v   <= 8'd0;
                        q   <= Q_SCAN;
                    end

                Q_SCAN:
                    if (v == NV) q <= Q_FIN1;
                    else if (alive[v] || pending[v]) begin
                        ctx_raddr <= v;
                        vb_addr   <= v;
                        c_rd      <= rd_ptr[v];
                        q         <= Q_LOAD;
                    end else
                        v <= v + 1'b1;

                Q_LOAD: q <= Q_EVAL;

                Q_EVAL: begin
                    {c_state, c_samples, c_frame, c_words, c_warm, c_k, c_order,
                     c_x1, c_x2, c_x3, c_x4, c_buf, c_nbits, c_q, c_gen, c_fpos} <= ctx_q;
                    vrec   <= vb_data;
                    steps  <= 0;
                    v_done <= 1'b0;
                    if (!vb_data[29]) begin                      // slot not in use
                        alive[v] <= 1'b0;
                        v <= v + 1'b1; q <= Q_SCAN;
                    end else if (vb_data[28:27] != ctx_q[11:10]) begin   // new note: restart
                        tab_addr <= vb_data[25:16];
                        q        <= Q_TAB;
                    end else if (!alive[v] || rst_req[v]) begin  // finished, or no data yet
                        v <= v + 1'b1; q <= Q_SCAN;
                    end else
                        q <= Q_RUN;
                end

                Q_TAB:  q <= Q_TAB2;
                Q_TAB2: q <= Q_RESTART;

                Q_RESTART: begin
                    c_state <= S_HDR; c_samples <= tab_samples; c_frame <= 0; c_words <= 0;
                    c_warm <= 0; c_k <= 0; c_order <= 3'd1; c_x1 <= 0; c_x2 <= 0; c_x3 <= 0; c_x4 <= 0;
                    c_buf <= 0; c_nbits <= 0; c_q <= 0; c_gen <= vrec[28:27]; c_fpos <= 0;
                    alive[v]   <= (tab_samples != 0);
                    rst_req[v] <= 1'b1;
                    ra_we      <= 1'b1; ra_waddr <= v; ra_wdata <= tab_start;
                    store_rd   <= 1'b0;
                    q          <= Q_STORE;
                end

                Q_RUN: begin
                    steps <= steps + 1'b1;
                    if (take) c_rd <= c_rd + 7'd1;

                    case (c_state)
                        S_HDR: if (take) begin
                            c_k <= hdr_k; c_order <= hdr_order; c_frame <= hdr_n; c_words <= hdr_len;
                            c_warm <= hdr_order; c_buf <= 32'd0; c_nbits <= 6'd0; c_q <= 16'd0;
                            c_state <= (hdr_k == K_RAW) ? S_RAW : S_WARM;
                        end
                        S_RAW: if (take) begin
                            c_words <= c_words - 11'd1; c_frame <= c_frame - 11'd1;
                            c_samples <= c_samples - 24'd1;
                            if (c_frame == 11'd1) c_state <= S_FEND;
                        end
                        S_WARM: if (take) begin
                            c_x4 <= c_x3; c_x3 <= c_x2; c_x2 <= c_x1; c_x1 <= in_data;
                            c_words <= c_words - 11'd1; c_frame <= c_frame - 11'd1;
                            c_samples <= c_samples - 24'd1; c_warm <= c_warm - 3'd1;
                            if (c_warm == 3'd1) c_state <= S_RICE;
                            if (c_frame == 11'd1) c_state <= S_FEND;
                        end
                        S_RICE: begin
                            if (take) begin
                                c_buf   <= buf_sh | ({in_data, 16'd0} >> nb_sh);
                                c_nbits <= nb_sh + 6'd16;
                                c_words <= c_words - 11'd1;
                            end else begin
                                c_buf   <= buf_sh;
                                c_nbits <= nb_sh;
                            end
                            if (rice_go) begin
                                if (code_done) begin
                                    c_q <= 16'd0;
                                    c_x4 <= c_x3; c_x3 <= c_x2; c_x2 <= c_x1; c_x1 <= x_rice;
                                    c_frame <= c_frame - 11'd1; c_samples <= c_samples - 24'd1;
                                    if (c_frame == 11'd1) c_state <= S_FEND;
                                end else
                                    c_q <= q_total;
                            end
                        end
                        S_FEND: begin
                            if (take) c_words <= c_words - 11'd1;
                            if (c_words == 11'd0 || (take && c_words == 11'd1))
                                c_state <= S_HDR;
                        end
                        default: ;
                    endcase

                    // progress: a word taken, or rice bits consumed / a code finished
                    if (emit) begin
                        m_valid <= 1'b1;
                        m_s     <= emit_val;
                        m_g     <= vrec[15:0];
                        m_f     <= vrec[26] ? fade_rom[c_fpos[8:0]] : 16'd32768;
                        if (vrec[26]) c_fpos <= c_fpos + 10'd1;
                        v_done  <= (c_samples == 24'd1) || (vrec[26] && c_fpos == 10'd511);
                        store_rd <= 1'b1;
                        q       <= Q_STORE;
                    end else if (!(take || (rice_go && (lo != 0 || code_done)) ||
                                   (c_state == S_FEND && c_words == 0)) || steps == STEP_LIMIT - 1) begin
                        underrun <= 1'b1;                        // buffer ran dry: skip this sample
                        store_rd <= 1'b1;
                        q        <= Q_STORE;
                    end
                end

                Q_STORE: begin
                    ctx_we    <= 1'b1;
                    ctx_waddr <= v;
                    ctx_wdata <= {c_state, c_samples, c_frame, c_words, c_warm, c_k, c_order,
                                  c_x1, c_x2, c_x3, c_x4, c_buf, c_nbits, c_q, c_gen, c_fpos};
                    if (store_rd) rd_ptr[v] <= c_rd;
                    if (v_done) alive[v] <= 1'b0;
                    v_done <= 1'b0;
                    v <= v + 1'b1;
                    q <= Q_SCAN;
                end

                Q_FIN1: q <= Q_FIN2;                             // let the mixer pipeline drain
                Q_FIN2: q <= Q_FIN3;
                Q_FIN3: begin                                    // master volume
                    vol_prod <= acc_sh * $signed({1'b0, master_gain});
                    q        <= Q_FIN4;
                end
                Q_FIN4: begin
                    mix_out   <= (vol_sh > 45'sd32767)  ? 16'h7FFF :
                                 (vol_sh < -45'sd32768) ? 16'h8000 : vol_sh[15:0];
                    mix_valid <= 1'b1;
                    q         <= Q_WAIT;
                end

                default: q <= Q_WAIT;
            endcase
        end
    end

    // ================================================================ refill
    localparam [2:0] F_SCAN = 3'd0, F_RST = 3'd1, F_RST2 = 3'd2, F_FADDR = 3'd3, F_FADDR2 = 3'd4,
                     F_BURST = 3'd5, F_END = 3'd6;
    reg [2:0]  f;
    reg [7:0]  rv;
    reg [24:0] faddr;
    reg [4:0]  fcount;
    reg        fwait;

    wire [6:0] rv_avail = wr_ptr[rv] - rd_ptr[rv];

    always @(posedge clk or posedge rst) begin
        if (rst) begin
            for (vi = 0; vi < NV; vi = vi + 1) wr_ptr[vi] <= 7'd0;
            f <= F_SCAN; rv <= 8'd0; faddr <= 0; fcount <= 0; fwait <= 1'b0;
            fr_req <= 1'b0; fr_addr <= 0;
            buf_we <= 1'b0; buf_waddr <= 0; buf_wdata <= 0;
            fa_we <= 1'b0; fa_waddr <= 0; fa_wdata <= 0; fa_raddr <= 0; ra_raddr <= 0;
            rf_rst_clr <= 1'b0; rf_rst_v <= 0;
        end else begin
            fr_req     <= 1'b0;
            buf_we     <= 1'b0;
            fa_we      <= 1'b0;
            rf_rst_clr <= 1'b0;
            if (buf_we) wr_ptr[buf_waddr[13:6]] <= wr_ptr[buf_waddr[13:6]] + 7'd1;

            case (f)
                F_SCAN:
                    if (enable) begin
                        if (rst_req[rv] && !rf_rst_clr) begin
                            ra_raddr <= rv;
                            f        <= F_RST;
                        end else if (alive[rv] && !rst_req[rv] && rv_avail <= 7'd48) begin
                            fa_raddr <= rv;
                            f        <= F_FADDR;
                        end else
                            rv <= (rv == NV - 1) ? 8'd0 : rv + 1'b1;
                    end

                F_RST: f <= F_RST2;
                F_RST2: begin                                    // empty buffer, file start
                    wr_ptr[rv] <= rd_ptr[rv];
                    faddr      <= raddr_q;
                    fcount     <= 5'd16;
                    fwait      <= 1'b0;
                    rf_rst_clr <= 1'b1;
                    rf_rst_v   <= rv;
                    f          <= F_BURST;                       // fill it right away
                end

                F_FADDR:  f <= F_FADDR2;
                F_FADDR2: begin
                    faddr  <= fetch_q;
                    fcount <= 5'd16;
                    fwait  <= 1'b0;
                    f      <= F_BURST;
                end

                F_BURST: begin
                    if (!fwait && !fr_busy && !fr_req && fcount != 0) begin
                        fr_req  <= 1'b1;
                        fr_addr <= faddr;
                        fwait   <= 1'b1;
                    end
                    if (fr_valid && fwait) begin
                        fwait      <= 1'b0;
                        buf_we     <= 1'b1;
                        buf_waddr  <= {rv, wr_ptr[rv][5:0]};
                        buf_wdata  <= fr_data;      // written next clock; wr_ptr moves with it
                        faddr      <= faddr + 25'd1;
                        fcount     <= fcount - 5'd1;
                        if (fcount == 5'd1) f <= F_END;
                    end
                end

                F_END: begin
                    fa_we    <= 1'b1;
                    fa_waddr <= rv;
                    fa_wdata <= faddr;
                    rv       <= (rv == NV - 1) ? 8'd0 : rv + 1'b1;
                    f        <= F_SCAN;
                end

                default: f <= F_SCAN;
            endcase
        end
    end

endmodule
