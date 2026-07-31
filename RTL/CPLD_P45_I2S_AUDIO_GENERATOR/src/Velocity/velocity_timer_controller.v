module velocity_timer_controller #(
    parameter CLK_FREQ_HZ = 48_000_000,
    parameter NUM_KEYS    = 90,
    parameter ADDR_WIDTH  = 7,
    parameter TIMEOUT_MS  = 5000,
    parameter K           = 2000,   // velocity = clamp(K / elapsed_ms, 1, 127)
    parameter DIV_WIDTH   = 16
) (
    input  wire                    clk,
    input  wire                    rst,

    // pressed_keys_ram Port B (read)
    output wire                    pkr_enb,
    output wire [ADDR_WIDTH-1:0]   pkr_addrb,
    input  wire [1:0]              pkr_doutb,

    // velocity_ram Port A (write)
    output wire                    vel_wea,
    output wire [ADDR_WIDTH-1:0]   vel_addra,
    output wire [6:0]              vel_dia,

    output wire                    note_on_valid,
    output wire [ADDR_WIDTH-1:0]   note_on_addr
);

    localparam [DIV_WIDTH-1:0] K_DIVIDEND = K;

    wire                   tick_1ms;
    reg  [12:0]            now_ms;

    wire [ADDR_WIDTH-1:0]  scan_addr;
    reg  [ADDR_WIDTH-1:0]  addr_d1;    // scan_addr delayed 1 cycle, aligned with the
                                       // registered doutb of pressed_keys_ram/key_state_ram/key_timer_ram

    wire [2:0]             state_doutb;
    wire [12:0]            timer_doutb;

    wire [1:0]  curr_state    = pkr_doutb;
    wire [1:0]  prev_state    = state_doutb[1:0];
    wire        timing_active = state_doutb[2];
    wire [12:0] start_ts      = timer_doutb;

    wire start_evt, stop_evt, release_evt, timeout_evt;
    wire next_timing_active;

    ms_tick_gen #(
        .CLK_FREQ_HZ (CLK_FREQ_HZ)
    ) u_ms_tick_gen (
        .clk      (clk),
        .rst      (rst),
        .tick_1ms (tick_1ms)
    );

    // Free-running ms counter. 13 bits wraps at 8192ms, which is the wraparound
    // margin key_event_detect's elapsed-time subtraction relies on.
    always @(posedge clk or posedge rst) begin
        if (rst)
            now_ms <= 13'd0;
        else if (tick_1ms)
            now_ms <= now_ms + 1'b1;
    end

    velocity_addr_gen #(
        .NUM_KEYS   (NUM_KEYS),
        .ADDR_WIDTH (ADDR_WIDTH)
    ) u_velocity_addr_gen (
        .clk  (clk),
        .rst  (rst),
        .addr (scan_addr)
    );

    assign pkr_enb   = 1'b1;
    assign pkr_addrb = scan_addr;

    always @(posedge clk or posedge rst) begin
        if (rst)
            addr_d1 <= {ADDR_WIDTH{1'b0}};
        else
            addr_d1 <= scan_addr;
    end

    // Per-key {timing_active, prev_m2, prev_m1}, refreshed every scan pass
    wire [2:0] state_dia = {next_timing_active, curr_state};

    dual_port_ram_dual_clock #(
        .DATA_WIDTH (3),
        .ADDR_WIDTH (ADDR_WIDTH),
        .RAM_DEPTH  (NUM_KEYS)
    ) u_key_state_ram (
        .clka  (clk),
        .wea   (~rst),
        .addra (addr_d1),
        .dia   (state_dia),
        .clkb  (clk),
        .enb   (1'b1),
        .addrb (scan_addr),
        .doutb (state_doutb)
    );

    // Per-key ms timestamp captured when M1 first closed
    dual_port_ram_dual_clock #(
        .DATA_WIDTH (13),
        .ADDR_WIDTH (ADDR_WIDTH),
        .RAM_DEPTH  (NUM_KEYS)
    ) u_key_timer_ram (
        .clka  (clk),
        .wea   (start_evt & ~rst),
        .addra (addr_d1),
        .dia   (now_ms),
        .clkb  (clk),
        .enb   (1'b1),
        .addrb (scan_addr),
        .doutb (timer_doutb)
    );

    key_event_detect #(
        .TIMEOUT_MS (TIMEOUT_MS)
    ) u_key_event_detect (
        .curr_state    (curr_state),
        .prev_state    (prev_state),
        .timing_active (timing_active),
        .now_ms        (now_ms),
        .start_ts      (start_ts),
        .start_evt     (start_evt),
        .stop_evt      (stop_evt),
        .release_evt   (release_evt),
        .timeout_evt   (timeout_evt)
    );

    assign next_timing_active = start_evt ? 1'b1 :
                                 (stop_evt || release_evt || timeout_evt) ? 1'b0 :
                                 timing_active;

    // 13-bit unsigned wraparound subtraction is safe here for the same reason
    // as in key_event_detect: true elapsed time never exceeds TIMEOUT_MS < 8192.
    wire [12:0] elapsed_ms = now_ms - start_ts;

    // Divider target address must be latched at the moment stop_evt fires: by
    // the time the divider finishes (several cycles later), the free-running
    // scan_addr/addr_d1 has already moved on to other keys.
    reg [ADDR_WIDTH-1:0] vel_addr_latched;
    always @(posedge clk or posedge rst) begin
        if (rst)
            vel_addr_latched <= {ADDR_WIDTH{1'b0}};
        else if (stop_evt)
            vel_addr_latched <= addr_d1;
    end

    wire                 vc_busy;
    wire [DIV_WIDTH-1:0] vc_result;
    wire                 vc_done;
    wire [6:0]           vc_velocity;
    wire                 vc_valid;

    velocity_calc #(
        .DIV_WIDTH (DIV_WIDTH)
    ) u_velocity_calc (
        .clk      (clk),
        .rst      (rst),
        .start    (stop_evt),
        .dividend (K_DIVIDEND),
        .divisor  ({{(DIV_WIDTH-13){1'b0}}, elapsed_ms}),
        .busy     (vc_busy),
        .result   (vc_result),
        .done     (vc_done),
        .velocity (vc_velocity),
        .valid    (vc_valid)
    );

    assign vel_wea       = vc_valid;
    assign vel_addra     = vel_addr_latched;
    assign vel_dia       = vc_velocity;

    assign note_on_valid = vc_valid;
    assign note_on_addr  = vel_addr_latched;

endmodule
