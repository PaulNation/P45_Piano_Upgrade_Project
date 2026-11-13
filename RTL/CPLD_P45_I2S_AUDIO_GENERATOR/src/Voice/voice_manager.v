// voice_manager.v — turns events (note-on/off, sustain pedal) into voice commands.
//
// Voice slots (208):
//   0..175    sustain voices, two per key (slot = key*2 + p): a re-struck key starts its new
//             note in the other slot while the old one fades out (re-strike = note-off +
//             note-on, as Keyscape does)
//   176..207  release voices, used as a ring: each release takes the next one (the oldest)
//
// Voice record (voice RAM, written here, read by the voice sequencer on port B):
//   [29]    active   voice plays
//   [28:27] gen      +1 on every new note in this slot: the sequencer (re)starts the voice
//                    from the beginning of its file when gen differs from its own copy
//   [26]    fading   sustain released: the sequencer applies fade.mem (512 samples), then stops
//   [25:16] file     flash file index (sustain key*5+layer, release + RELEASE_BASE)
//   [15:0]  gain     linear gain, Q2.14 (16384 = 1.0), from db_to_lin.mem
// A voice also stops by itself when its file ends.
//
// Behaviour:
//   note-on   key still sounding -> release it first; layer + gain code from
//             velocity_layer.mem; sustain gain = db_to_lin[vel_code]
//   note-off  pedal down: key marked sustained (released at pedal up); else release
//   release   sustain voice: fading = 1; release voice: file = release of the same key/layer,
//             gain = db_to_lin[vel_code + hold_code - 12], hold_code from release_gain.mem at
//             the samples held since note-on (power-of-two slots, interpolated in dB)
//   pedal up  releases every sustained key that is no longer held
//
// The table files are the ones make_fpga_tables.py / make_velocity_table.py write.
`ifndef TABLES_DIR
`define TABLES_DIR "../../src/Sample_Decoder/tables/"
`endif

module voice_manager #(
    parameter RELEASE_BASE = 440,
    parameter NUM_REL      = 32
) (
    input  wire        clk,
    input  wire        rst,
    input  wire        enable,          // boot_done: tables in flash are valid
    input  wire [31:0] now_samples,     // 44.1 kHz sample counter

    // event FIFO (show-ahead)
    input  wire        evt_empty,
    input  wire [15:0] evt_data,
    output reg         evt_pop,

    // voice RAM read port for the sequencer
    input  wire [7:0]  vb_addr,
    output reg  [29:0] vb_data,

    output wire        vw_strobe,       // a voice record was written (tells the engine to re-read it)
    output wire [7:0]  vw_addr,
    output wire        busy             // processing an event (for tests)
);

    localparam NUM_VOICES = 176 + NUM_REL;
    localparam MUTE       = 8'd255;

    // ------------------------------------------------------------------ memories
    reg [29:0] voice_ram [0:NUM_VOICES-1];
    reg [15:0] vel_rom   [0:11263];     // key*128 + velocity -> {layer[10:8], code[7:0]}
    reg [7:0]  rel_rom   [0:3519];      // ((key*5)+layer)*8 + slot -> hold code
    reg [15:0] lin_rom   [0:255];       // code -> Q2.14
    // key state: {held, sustained, p, layer[2:0], vcode[7:0], start[31:0]}
    reg [45:0] key_ram   [0:87];

    integer i;
    initial begin
        for (i = 0; i < NUM_VOICES; i = i + 1) voice_ram[i] = 30'd0;
        for (i = 0; i < 88; i = i + 1)         key_ram[i]   = 46'd0;
        $readmemh({`TABLES_DIR, "velocity_layer.mem"}, vel_rom);
        $readmemh({`TABLES_DIR, "release_gain.mem"},   rel_rom);
        $readmemh({`TABLES_DIR, "db_to_lin.mem"},      lin_rom);
    end

    // port B: sequencer
    always @(posedge clk) vb_data <= voice_ram[vb_addr];

    // port A: this FSM (synchronous read, write)
    reg        va_we;
    reg [7:0]  va_addr;
    reg [29:0] va_wdata, va_rdata;
    always @(posedge clk) begin
        if (va_we) voice_ram[va_addr] <= va_wdata;
        va_rdata <= voice_ram[va_addr];
    end

    reg        k_we;
    reg [6:0]  k_addr;
    reg [45:0] k_wdata, k_rdata;
    always @(posedge clk) begin
        if (k_we) key_ram[k_addr] <= k_wdata;
        k_rdata <= key_ram[k_addr];
    end

    reg [13:0] vel_addr;  reg [15:0] vel_q;
    reg [11:0] rel_addr;  reg [7:0]  rel_q;
    reg [7:0]  lin_addr;  reg [15:0] lin_q;
    always @(posedge clk) begin
        vel_q <= vel_rom[vel_addr];
        rel_q <= rel_rom[rel_addr];
        lin_q <= lin_rom[lin_addr];
    end

    // ------------------------------------------------------------------ FSM
    localparam
        S_IDLE      = 5'd0,
        S_EVT       = 5'd1,
        S_ON_CHK    = 5'd3,
        S_ON_START  = 5'd4,
        S_ON_WR     = 5'd6,
        S_OFF_CHK   = 5'd8,
        S_PED_RD    = 5'd9,
        S_PED_CHK   = 5'd10,
        S_PED_NEXT  = 5'd11,
        S_R_VRD     = 5'd12,
        S_R_FADE    = 5'd13,
        S_R_C0      = 5'd14,
        S_R_C1      = 5'd15,
        S_R_INTERP  = 5'd16,
        S_R_LIN     = 5'd17,
        S_R_VRD2    = 5'd18,
        S_R_WR      = 5'd19,
        S_R_KEYCLR  = 5'd20,
        S_WAIT      = 5'd21;

    reg [4:0]  st, ret_st, wait_nx;
    reg [6:0]  key;
    reg [6:0]  vel;
    reg        pedal;
    reg [4:0]  ring;                    // next release voice (oldest)
    reg [45:0] krec;                    // key record being worked on
    reg [10:0] vl;                      // {layer, vcode} for a note-on
    reg [8:0]  fidx;                    // key*5 + layer
    reg [31:0] held;
    reg [4:0]  top;                     // top set bit of held
    reg [7:0]  c0;
    reg [7:0]  hcode;
    reg [7:0]  code;

    assign busy      = (st != S_IDLE) || !evt_empty;
    assign vw_strobe = va_we;
    assign vw_addr   = va_addr;

    wire        k_held  = krec[45];
    wire        k_sus   = krec[44];
    wire        k_p     = krec[43];
    wire [2:0]  k_layer = krec[42:40];
    wire [7:0]  k_vcode = krec[39:32];
    wire [31:0] k_start = krec[31:0];

    // top set bit of the held time
    reg [4:0] msb;
    integer b;
    always @(*) begin
        msb = 5'd0;
        for (b = 0; b < 32; b = b + 1)
            if (held[b]) msb = b[4:0];
    end

    // hold-code interpolation: c0 + round(frac8 * (c1 - c0) / 256), all clamped below MUTE
    wire [31:0] below   = held - (32'd1 << top);
    wire [31:0] frac32  = (below << 8) >> top;
    wire [7:0]  frac8   = frac32[7:0];                      // floor(frac * 256)
    wire signed [9:0]  diff = $signed({2'b00, rel_q > 8'd254 ? 8'd254 : rel_q}) - $signed({2'b00, c0});
    wire signed [18:0] prod = $signed({1'b0, frac8}) * diff;
    wire signed [18:0] interp19 = $signed({11'd0, c0}) + ((prod + 19'sd128) >>> 8);
    wire [7:0]         interp   = interp19[7:0];

    // total release code
    wire [9:0] sum = {2'b00, k_vcode} + {2'b00, hcode};
    wire [9:0] sum12 = sum - 10'd12;
    wire [7:0] code_total = (k_vcode == MUTE || hcode == MUTE) ? MUTE :
                            (sum < 10'd12)      ? 8'd0 :
                            (sum12 > 10'd254)   ? 8'd254 : sum12[7:0];

    // event type of the word popped in S_IDLE
    reg [1:0] evt_type;
    reg       pedal_scan;                 // the release came from the pedal-up scan
    always @(posedge clk or posedge rst) begin
        if (rst) begin
            evt_type   <= 2'b11;
            pedal_scan <= 1'b0;
        end else begin
            if (st == S_IDLE && enable && !evt_empty) evt_type <= evt_data[15:14];
            if (st == S_EVT) pedal_scan <= (evt_type == 2'b10);
        end
    end

    // slot 7 interpolates toward mute (254), as make_fpga_tables.py's player
    wire signed [9:0]  diff_last = $signed(10'd254) - $signed({2'b00, c0});
    wire signed [18:0] prod_last = $signed({1'b0, frac8}) * diff_last;
    wire signed [18:0] interp_last19 = $signed({11'd0, c0}) + ((prod_last + 19'sd128) >>> 8);
    wire [7:0]         interp_last   = interp_last19[7:0];


    always @(posedge clk or posedge rst) begin
        if (rst) begin
            st      <= S_IDLE;
            ret_st  <= S_IDLE;
            wait_nx <= S_IDLE;
            evt_pop <= 1'b0;
            va_we   <= 1'b0;
            k_we    <= 1'b0;
            pedal   <= 1'b0;
            ring    <= 5'd0;
            key <= 0; vel <= 0; krec <= 0; vl <= 0; fidx <= 0; held <= 0; top <= 0;
            c0 <= 0; hcode <= 0; code <= 0;
            va_addr <= 0; va_wdata <= 0; k_addr <= 0; k_wdata <= 0;
            vel_addr <= 0; rel_addr <= 0; lin_addr <= 0;
        end else begin
            evt_pop <= 1'b0;
            va_we   <= 1'b0;
            k_we    <= 1'b0;

            case (st)
                // ------------------------------------------------ events
                S_IDLE:
                    if (!enable && !evt_empty)
                        evt_pop <= 1'b1;                 // tables not loaded yet: drop the event
                    else if (enable && !evt_empty) begin
                        evt_pop <= 1'b1;
                        key     <= evt_data[13:7];
                        vel     <= evt_data[6:0];
                        st      <= S_EVT;
                    end

                S_EVT: begin
                    // evt_data was latched in S_IDLE (key/vel); decode the type from the popped word
                    case (evt_type)
                        2'b01: if (key < 7'd88) begin
                                   k_addr   <= key;
                                   vel_addr <= {key, vel};          // key*128 + velocity
                                   wait_nx  <= S_ON_CHK;
                                   st       <= S_WAIT;
                               end else st <= S_IDLE;
                        2'b00: if (key < 7'd88) begin
                                   k_addr  <= key;
                                   wait_nx <= S_OFF_CHK;
                                   st      <= S_WAIT;
                               end else st <= S_IDLE;
                        2'b10: if (key == 7'd64) begin                // CC64: sustain pedal
                                   if (vel >= 7'd64) begin
                                       pedal <= 1'b1;
                                       st    <= S_IDLE;
                                   end else begin
                                       pedal <= 1'b0;
                                       key   <= 7'd0;
                                       st    <= S_PED_RD;
                                   end
                               end else st <= S_IDLE;
                        default: st <= S_IDLE;
                    endcase
                end

                S_WAIT: st <= wait_nx;          // one clock for a synchronous RAM/ROM read

                // ------------------------------------------------ note-on
                S_ON_CHK: begin
                    krec <= k_rdata;
                    vl   <= vel_q[10:0];
                    if (k_rdata[45] || k_rdata[44]) begin            // still sounding: release first
                        ret_st <= S_ON_START;
                        st     <= S_R_VRD;
                        // the release path reads krec next clock
                    end else
                        st <= S_ON_START;
                end

                S_ON_START: begin
                    fidx     <= {2'b00, key} * 9'd5 + {6'd0, vl[10:8]};
                    va_addr  <= {key, ~k_p};                         // the other slot of the pair
                    lin_addr <= vl[7:0];
                    wait_nx  <= S_ON_WR;
                    st       <= S_WAIT;
                end

                S_ON_WR: begin
                    va_we    <= 1'b1;
                    va_wdata <= {1'b1, va_rdata[28:27] + 2'd1, 1'b0, {1'b0, fidx}, lin_q};
                    k_we     <= 1'b1;
                    k_addr   <= key;
                    k_wdata  <= {1'b1, 1'b0, ~k_p, vl[10:8], vl[7:0], now_samples};
                    st       <= S_IDLE;
                end

                // ------------------------------------------------ note-off
                S_OFF_CHK: begin
                    krec <= k_rdata;
                    if (!k_rdata[45])
                        st <= S_IDLE;                                // not held: nothing to do
                    else if (pedal) begin
                        k_we    <= 1'b1;
                        k_wdata <= {1'b0, 1'b1, k_rdata[43:0]};      // sustained by the pedal
                        st      <= S_IDLE;
                    end else begin
                        ret_st <= S_R_KEYCLR;
                        st     <= S_R_VRD;
                    end
                end

                // ------------------------------------------------ pedal up: scan all keys
                S_PED_RD: begin
                    k_addr  <= key;
                    wait_nx <= S_PED_CHK;
                    st      <= S_WAIT;
                end
                S_PED_CHK: begin
                    krec <= k_rdata;
                    if (k_rdata[44] && !k_rdata[45]) begin
                        ret_st <= S_R_KEYCLR;
                        st     <= S_R_VRD;
                    end else
                        st <= S_PED_NEXT;
                end
                S_PED_NEXT:
                    if (key == 7'd87) st <= S_IDLE;
                    else begin
                        key <= key + 1'b1;
                        st  <= S_PED_RD;
                    end

                // ------------------------------------------------ release of key `key` (krec)
                S_R_VRD: begin                                       // read the sustain voice
                    va_addr <= {key, k_p};
                    held    <= now_samples - k_start;
                    fidx    <= {2'b00, key} * 9'd5 + {6'd0, k_layer};
                    wait_nx <= S_R_FADE;
                    st      <= S_WAIT;
                end
                S_R_FADE: begin
                    if (va_rdata[29]) begin                          // fade the sustain voice
                        va_we    <= 1'b1;
                        va_wdata <= {va_rdata[29:27], 1'b1, va_rdata[25:0]};
                    end
                    top <= msb;
                    if (held < 32'd8192) begin                       // first slot, no interpolation
                        rel_addr <= {fidx, 3'd0};
                        wait_nx  <= S_R_C0;
                        st       <= S_WAIT;
                    end else if (msb >= 5'd21) begin                 // past the last slot: mute
                        hcode <= MUTE;
                        st    <= S_R_LIN;
                    end else begin
                        rel_addr <= {fidx, msb[2:0] - 3'd5};         // slot = msb - 13
                        wait_nx  <= S_R_C0;
                        st       <= S_WAIT;
                    end
                end
                S_R_C0: begin
                    c0 <= (rel_q > 8'd254) ? 8'd254 : rel_q;
                    if (held < 32'd8192) begin
                        hcode <= rel_q;
                        st    <= S_R_LIN;
                    end else if (top == 5'd20) begin                 // slot 7: next point is mute
                        st <= S_R_C1;                                // rel_q unused below; c1 = 254
                    end else begin
                        rel_addr <= rel_addr + 1'b1;
                        wait_nx  <= S_R_C1;
                        st       <= S_WAIT;
                    end
                end
                S_R_C1:
                    st <= S_R_INTERP;
                S_R_INTERP: begin
                    // c1 = rel_q (slots 0..6) or 254 (slot 7, ramp to mute)
                    hcode <= (top == 5'd20) ? interp_last : interp;
                    st    <= S_R_LIN;
                end
                S_R_LIN: begin
                    code     <= code_total;
                    lin_addr <= code_total;
                    wait_nx  <= S_R_VRD2;
                    st       <= S_WAIT;
                end
                S_R_VRD2: begin
                    if (code == MUTE)
                        st <= ret_st;                                // silent: no release voice
                    else begin
                        va_addr <= 8'd176 + {3'd0, ring};
                        wait_nx <= S_R_WR;
                        st      <= S_WAIT;
                    end
                end
                S_R_WR: begin
                    va_we    <= 1'b1;
                    va_wdata <= {1'b1, va_rdata[28:27] + 2'd1, 1'b0,
                                 fidx + RELEASE_BASE[9:0], lin_q};
                    ring     <= (ring == NUM_REL[4:0] - 5'd1) ? 5'd0 : ring + 5'd1;
                    st       <= ret_st;
                end
                S_R_KEYCLR: begin                                    // key fully released
                    k_we    <= 1'b1;
                    k_addr  <= key;
                    k_wdata <= {1'b0, 1'b0, krec[43:0]};
                    st      <= (pedal_scan) ? S_PED_NEXT : S_IDLE;
                end

                default: st <= S_IDLE;
            endcase
        end
    end

endmodule
