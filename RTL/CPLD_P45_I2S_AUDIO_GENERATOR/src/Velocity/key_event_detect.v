module key_event_detect #(
    parameter TIMEOUT_MS = 5000
) (
    input  wire [1:0]  curr_state,     // {M2,M1} sampled this pass
    input  wire [1:0]  prev_state,     // {M2,M1} sampled the previous pass
    input  wire        timing_active,
    input  wire [12:0] now_ms,
    input  wire [12:0] start_ts,

    output wire         start_evt,     // M1 rising: press begins
    output wire         stop_evt,      // M2 rising while M1 held and timer running: velocity capture point
    output wire         release_evt,   // both contacts open: key fully released
    output wire         timeout_evt    // M2 never closed within TIMEOUT_MS of M1
);

    assign start_evt   = (prev_state == 2'b00) && curr_state[0];
    assign stop_evt    = timing_active && (prev_state == 2'b01) && (curr_state == 2'b11);
    assign release_evt = (curr_state == 2'b00) && (prev_state != 2'b00);

    // 13-bit unsigned wraparound subtraction is safe here: true elapsed time is
    // always < 8192ms (bounded by TIMEOUT_MS <= 5000), even though now_ms itself
    // free-runs and wraps at 8192, so (now_ms - start_ts) lands on the correct
    // elapsed value regardless of which side of a wrap the two samples fall on.
    assign timeout_evt = timing_active && ((now_ms - start_ts) >= TIMEOUT_MS);

endmodule
