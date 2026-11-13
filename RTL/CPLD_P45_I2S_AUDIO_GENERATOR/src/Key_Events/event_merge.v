// event_merge.v — merges the key events and controller events (sustain pedal, later the
// volume pot) into one event stream. Key events have priority; a controller event waits
// in a one-entry holding register until a clock without a key event (key events are
// at most one per scanned key, so it never waits long).
//
// Event format (16 bit), shared by the synth (async FIFO) and MIDI out:
//   [15:14] 2'b00 note-off   [13:7] key 0..87   [6:0] 0
//           2'b01 note-on    [13:7] key 0..87   [6:0] velocity 1..127
//           2'b10 controller [13:7] CC number   [6:0] value  (64 = sustain pedal, 7 = volume)
module event_merge (
    input  wire        clk,
    input  wire        rst,
    input  wire        key_valid,
    input  wire [15:0] key_data,
    input  wire        cc_valid,
    input  wire [15:0] cc_data,
    output reg         evt_valid,
    output reg  [15:0] evt_data
);

    reg        cc_pend;
    reg [15:0] cc_hold;

    always @(posedge clk or posedge rst) begin
        if (rst) begin
            cc_pend   <= 1'b0;
            cc_hold   <= 16'd0;
            evt_valid <= 1'b0;
            evt_data  <= 16'd0;
        end else begin
            evt_valid <= 1'b0;
            if (key_valid) begin
                evt_valid <= 1'b1;
                evt_data  <= key_data;
            end else if (cc_pend) begin
                evt_valid <= 1'b1;
                evt_data  <= cc_hold;
                cc_pend   <= 1'b0;
            end
            if (cc_valid) begin                  // newest value wins if two arrive
                cc_pend <= 1'b1;
                cc_hold <= cc_data;
            end
        end
    end

endmodule
