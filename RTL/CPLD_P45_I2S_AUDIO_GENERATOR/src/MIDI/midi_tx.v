// midi_tx.v — sends the event stream out as MIDI on one channel (31,250 baud, 8N1).
//   note-on  -> 9n kk vv        (kk = key + 21)
//   note-off -> 9n kk 00        (note-on with velocity 0, so running status applies)
//   CC       -> Bn cc vv        (64 = sustain pedal, 7 = volume)
// Running status: the status byte is only sent when it changes, or when nothing was sent
// for RESEND_MS (so a device plugged in mid-performance resyncs).
// Events are queued in a FIFO (MIDI needs ~0.64 ms per 2-byte message); if it ever
// overflows, events are dropped from MIDI out only (the synth path is separate).
module midi_tx #(
    parameter CLK_HZ     = 12_000_000,
    parameter BAUD       = 31_250,
    parameter CHANNEL    = 0,                  // 0 = MIDI channel 1
    parameter RESEND_MS  = 300,
    parameter FIFO_ADDR_W = 6                  // 64 events
) (
    input  wire        clk,
    input  wire        rst,
    input  wire        tick_us,
    input  wire        evt_valid,
    input  wire [15:0] evt_data,
    output wire        midi_out,               // UART TX line, idle high
    output reg         dropped                 // sticky: an event did not fit in the FIFO
);

    wire        f_full, f_empty;
    wire [15:0] f_data;
    reg         f_pop;

    sync_fifo #(.DATA_W(16), .ADDR_W(FIFO_ADDR_W)) u_fifo (
        .clk(clk), .rst(rst),
        .wr_en(evt_valid), .wr_data(evt_data), .full(f_full),
        .rd_en(f_pop), .rd_data(f_data), .empty(f_empty)
    );

    always @(posedge clk or posedge rst) begin
        if (rst)
            dropped <= 1'b0;
        else if (evt_valid && f_full)
            dropped <= 1'b1;
    end

    reg        u_start;
    reg  [7:0] u_data;
    wire       u_busy;

    uart_tx #(.CLKS_PER_BIT(CLK_HZ / BAUD)) u_uart (
        .clk(clk), .rst(rst), .start(u_start), .data(u_data), .tx(midi_out), .busy(u_busy)
    );

    // idle timer for the running-status refresh
    localparam IDLE_W = $clog2(RESEND_MS * 1000 + 1);
    reg [IDLE_W-1:0] idle_us;
    reg [7:0]        last_status;              // 0 = none (resend next time)

    // byte sequencer
    localparam S_IDLE = 2'd0, S_STATUS = 2'd1, S_D1 = 2'd2, S_D2 = 2'd3;
    reg [1:0] st;
    reg [7:0] status, d1, d2;

    wire [1:0] typ = f_data[15:14];
    wire [7:0] ev_status = (typ == 2'b10) ? (8'hB0 | CHANNEL) : (8'h90 | CHANNEL);
    wire [7:0] ev_d1     = (typ == 2'b10) ? {1'b0, f_data[13:7]} : ({1'b0, f_data[13:7]} + 8'd21);
    wire [7:0] ev_d2     = (typ == 2'b00) ? 8'h00 : {1'b0, f_data[6:0]};

    always @(posedge clk or posedge rst) begin
        if (rst) begin
            st          <= S_IDLE;
            f_pop       <= 1'b0;
            u_start     <= 1'b0;
            u_data      <= 8'h00;
            status      <= 8'h00;
            d1          <= 8'h00;
            d2          <= 8'h00;
            last_status <= 8'h00;
            idle_us     <= 0;
        end else begin
            f_pop   <= 1'b0;
            u_start <= 1'b0;

            if (st != S_IDLE || u_busy)
                idle_us <= 0;
            else if (tick_us) begin
                if (idle_us == RESEND_MS * 1000)
                    last_status <= 8'h00;         // force a fresh status byte next time
                else
                    idle_us <= idle_us + 1'b1;
            end

            case (st)
                S_IDLE:
                    if (!f_empty && !f_pop && typ != 2'b11) begin
                        status <= ev_status;
                        d1     <= ev_d1;
                        d2     <= ev_d2;
                        f_pop  <= 1'b1;
                        st     <= (ev_status == last_status) ? S_D1 : S_STATUS;
                    end else if (!f_empty && !f_pop) begin
                        f_pop  <= 1'b1;            // reserved type: discard
                    end
                S_STATUS:
                    if (!u_busy && !u_start) begin
                        u_data      <= status;
                        u_start     <= 1'b1;
                        last_status <= status;
                        st          <= S_D1;
                    end
                S_D1:
                    if (!u_busy && !u_start) begin
                        u_data  <= d1;
                        u_start <= 1'b1;
                        st      <= S_D2;
                    end
                S_D2:
                    if (!u_busy && !u_start) begin
                        u_data  <= d2;
                        u_start <= 1'b1;
                        st      <= S_IDLE;
                    end
            endcase
        end
    end

endmodule
