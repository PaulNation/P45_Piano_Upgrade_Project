// debounce.v — synchronizes a switch input and accepts a new level only after it has been
// stable for STABLE_US microseconds. Emits a one-clock pulse on every accepted change.
// ACTIVE_LOW = 1 when the switch pulls the pin low when pressed (check the pedal jack:
// a normally-closed pedal reads the other way round, then flip ACTIVE_LOW).
module debounce #(
    parameter STABLE_US  = 5000,
    parameter ACTIVE_LOW = 1
) (
    input  wire clk,
    input  wire rst,
    input  wire tick_us,
    input  wire pin,
    output reg  pressed,        // debounced level, 1 = pressed
    output reg  changed         // one-clock pulse when pressed changes
);

    localparam CNT_W = $clog2(STABLE_US + 1);

    reg             meta, sync;
    reg [CNT_W-1:0] cnt;
    wire            raw = ACTIVE_LOW ? ~sync : sync;

    always @(posedge clk or posedge rst) begin
        if (rst) begin
            meta    <= ACTIVE_LOW ? 1'b1 : 1'b0;
            sync    <= ACTIVE_LOW ? 1'b1 : 1'b0;
            cnt     <= 0;
            pressed <= 1'b0;
            changed <= 1'b0;
        end else begin
            meta    <= pin;
            sync    <= meta;
            changed <= 1'b0;
            if (raw == pressed)
                cnt <= 0;
            else if (tick_us) begin
                if (cnt == STABLE_US - 1) begin
                    pressed <= raw;
                    changed <= 1'b1;
                    cnt     <= 0;
                end else
                    cnt <= cnt + 1'b1;
            end
        end
    end

endmodule
