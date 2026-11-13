// flash_reader.v — word reads from the parallel NOR flash (asynchronous read, 16-bit words,
// 25-bit word address, read-only: WE# held high).
//
// One read: drive A and assert CE#/OE#, wait ACCESS_CLKS clocks, sample DQ, then de-assert
// for RECOVER_CLKS clocks (output disable time) before the next address.
// ACCESS_CLKS must cover the flash's tACC (address -> data) plus pin/board delays:
// 6 clocks at 45.1584 MHz = 133 ns, enough for a 100-110 ns part. Throughput =
// 1 word per (ACCESS_CLKS + RECOVER_CLKS) clocks = ~6.5 M words/s with the defaults.
// (Page-mode bursts can be added later if more bandwidth is needed.)
module flash_reader #(
    parameter ACCESS_CLKS  = 6,
    parameter RECOVER_CLKS = 1
) (
    input  wire        clk,
    input  wire        rst,

    // request port
    input  wire        req,          // start a read when !busy
    input  wire [24:0] addr,
    output wire        busy,
    output reg         rvalid,       // one-clock pulse with rdata
    output reg  [15:0] rdata,

    // flash pins
    output reg  [24:0] FLASH_A,
    input  wire [15:0] FLASH_DQ,
    output reg         FLASH_CE_N,
    output reg         FLASH_OE_N,
    output wire        FLASH_WE_N
);

    localparam CNT_W = $clog2(ACCESS_CLKS + RECOVER_CLKS + 1);
    localparam S_IDLE = 2'd0, S_ACCESS = 2'd1, S_RECOVER = 2'd2;

    reg [1:0]       st;
    reg [CNT_W-1:0] cnt;

    assign FLASH_WE_N = 1'b1;
    assign busy       = (st != S_IDLE);

    always @(posedge clk or posedge rst) begin
        if (rst) begin
            st         <= S_IDLE;
            cnt        <= 0;
            rvalid     <= 1'b0;
            rdata      <= 16'h0000;
            FLASH_A    <= 25'd0;
            FLASH_CE_N <= 1'b1;
            FLASH_OE_N <= 1'b1;
        end else begin
            rvalid <= 1'b0;
            case (st)
                S_IDLE:
                    if (req) begin
                        FLASH_A    <= addr;
                        FLASH_CE_N <= 1'b0;
                        FLASH_OE_N <= 1'b0;
                        cnt        <= ACCESS_CLKS - 1;
                        st         <= S_ACCESS;
                    end
                S_ACCESS:
                    if (cnt == 0) begin
                        rdata      <= FLASH_DQ;          // stable: tACC has passed
                        rvalid     <= 1'b1;
                        FLASH_CE_N <= 1'b1;
                        FLASH_OE_N <= 1'b1;
                        cnt        <= RECOVER_CLKS - 1;
                        st         <= (RECOVER_CLKS == 0) ? S_IDLE : S_RECOVER;
                    end else
                        cnt <= cnt - 1'b1;
                S_RECOVER:
                    if (cnt == 0)
                        st <= S_IDLE;
                    else
                        cnt <= cnt - 1'b1;
                default:
                    st <= S_IDLE;
            endcase
        end
    end

endmodule
