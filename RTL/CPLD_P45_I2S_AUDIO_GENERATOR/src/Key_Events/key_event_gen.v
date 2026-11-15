// key_event_gen.v — turns the scanned {M2, M1} contacts of every key into note events.
//
// Input: the scan stream from scan_keys_controller (one key per clock while a row is read,
// every key once per scan pass, ~64 us at 24 MHz). Per key it keeps
//     {note_on, timing, M2_prev, M1_prev, t_start[16:0]}
// in a small RAM (read one clock ahead, written back the next clock).
//
// Per key, each pass:
//   M1 closes (key starts down)        -> start timing: t_start = now_us
//   M2 closes while timing             -> NOTE-ON, velocity = curve(now_us - t_start)
//   M2 closes after a timeout          -> NOTE-ON, velocity 1 (very slow press)
//   M1 and M2 close in the same pass   -> NOTE-ON, velocity 127 (faster than one pass)
//   timing longer than TIMEOUT_US      -> stop timing (no note yet)
//   M1 opens (key back up) with note on-> NOTE-OFF
//   M1 opens without a note            -> reset (aborted press)
//
// Velocity: the elapsed time in us is turned into a log index
//     idx = {position of the top bit (5 b), next 4 bits below it}
// (16 steps per octave of time) and looked up in velocity_curve.mem (512 x 7 bit,
// made by tools/make_velocity_curve.py). Timing resolution = one scan pass.
//
// Output event (16 bit, registered one-clock pulse):
//     [15:14] 2'b01 note-on / 2'b00 note-off
//     [13:7]  key 0..87 (MIDI note = key + 21)
//     [6:0]   velocity 1..127 (0 for note-off)
module key_event_gen #(
    parameter NUM_KEYS   = 88,
    parameter ADDR_WIDTH = 7,
    parameter TIMEOUT_US = 100_000,            // < 2^17 us (timer wrap, 131 ms)
    parameter CURVE_FILE = "velocity_curve.mem"
) (
    input  wire                  clk,
    input  wire                  rst,
    input  wire                  tick_us,      // 1 us pulse

    // scan stream
    input  wire                  key_valid,
    input  wire [ADDR_WIDTH-1:0] key_idx,
    input  wire [1:0]            key_contacts, // {M2, M1}, 1 = closed

    // events
    output reg                   evt_valid,
    output reg  [15:0]           evt_data
);

    localparam TS_W  = 17;
    localparam ST_W  = 4 + TS_W;               // {note_on, timing, m2, m1, t_start}

    // ---------------- free-running microsecond timer (wraps every 131 ms)
    reg [TS_W-1:0] now_us;
    always @(posedge clk or posedge rst) begin
        if (rst)
            now_us <= 0;
        else if (tick_us)
            now_us <= now_us + 1'b1;
    end

    // ---------------- per-key state RAM (zero at power-up)
    reg [ST_W-1:0] state_ram [0:NUM_KEYS-1];
    integer i;
    initial begin
        for (i = 0; i < NUM_KEYS; i = i + 1)
            state_ram[i] = {ST_W{1'b0}};
    end

    // ---------------- velocity curve ROM
    reg [6:0] curve [0:511];
    initial $readmemh(CURVE_FILE, curve);

    // ---------------- stage 0: read the key's state while its contacts arrive
    reg                  s1_valid;
    reg [ADDR_WIDTH-1:0] s1_idx;
    reg [1:0]            s1_cur;
    reg [ST_W-1:0]       s1_state;

    always @(posedge clk) begin
        s1_state <= state_ram[key_idx];
    end

    always @(posedge clk or posedge rst) begin
        if (rst) begin
            s1_valid <= 1'b0;
            s1_idx   <= 0;
            s1_cur   <= 2'b00;
        end else begin
            s1_valid <= key_valid;
            s1_idx   <= key_idx;
            s1_cur   <= key_contacts;
        end
    end

    // ---------------- stage 1: decide, write back, emit
    wire            note_on  = s1_state[ST_W-1];
    wire            timing   = s1_state[ST_W-2];
    wire [1:0]      prev     = s1_state[ST_W-3:ST_W-4];
    wire [TS_W-1:0] t_start  = s1_state[TS_W-1:0];
    wire            m1       = s1_cur[0];
    wire            m2       = s1_cur[1];
    wire [TS_W-1:0] elapsed  = now_us - t_start;     // modulo 2^17, valid while < 131 ms

    // log index of the elapsed time: top bit position + 4 bits below it
    reg  [4:0] msb;
    integer b;
    always @(*) begin
        msb = 5'd0;
        for (b = 0; b < TS_W; b = b + 1)
            if (elapsed[b])
                msb = b[4:0];
    end
    wire [TS_W-1:0] norm = (msb >= 5'd4) ? (elapsed >> (msb - 5'd4)) : (elapsed << (5'd4 - msb));
    wire [3:0]      mant = norm[3:0];                  // the 4 bits below the top bit
    wire [8:0] vidx = {msb, mant};
    wire [6:0] vel  = curve[vidx];

    wire start_t   = m1 && !prev[0] && !note_on;                  // M1 just closed
    wire hit       = m2 && !prev[1] && !note_on && m1;            // M2 just closed, key down
    wire timeout   = timing && (elapsed >= TIMEOUT_US);
    wire key_up    = !m1 && prev[0];                              // M1 just opened

    reg            nx_note_on, nx_timing;
    reg [TS_W-1:0] nx_t;
    reg            emit;
    reg [15:0]     emit_data;

    always @(*) begin
        nx_note_on = note_on;
        nx_timing  = timing;
        nx_t       = t_start;
        emit       = 1'b0;
        emit_data  = 16'd0;
        if (key_up) begin
            nx_timing = 1'b0;
            if (note_on) begin
                nx_note_on = 1'b0;
                emit       = 1'b1;
                emit_data  = {2'b00, s1_idx, 7'd0};
            end
        end else if (hit) begin
            nx_note_on = 1'b1;
            nx_timing  = 1'b0;
            emit       = 1'b1;
            // timing: curve; M1 and M2 closed in the same pass (< 1 pass): fastest; else slow
            emit_data  = {2'b01, s1_idx, (timing && !timeout) ? vel :
                                         (!timing && !prev[0]) ? 7'd127 : 7'd1};
        end else if (start_t) begin
            nx_timing  = 1'b1;
            nx_t       = now_us;
        end else if (timeout) begin
            nx_timing  = 1'b0;
        end
    end

    always @(posedge clk) begin
        if (s1_valid)
            state_ram[s1_idx] <= {nx_note_on, nx_timing, s1_cur, nx_t};
    end

    always @(posedge clk or posedge rst) begin
        if (rst) begin
            evt_valid <= 1'b0;
            evt_data  <= 16'd0;
        end else begin
            evt_valid <= s1_valid && emit;
            evt_data  <= emit_data;
        end
    end

endmodule
