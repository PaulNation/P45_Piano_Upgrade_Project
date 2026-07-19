module dual_port_ram_dual_clock #(
    parameter DATA_WIDTH = 2,
    parameter ADDR_WIDTH = 7,
    parameter RAM_DEPTH  = 90
) (
    // Port A: Write Domain
    input wire                      clka,
    input wire                      wea,
    input wire  [ADDR_WIDTH-1:0]    addra,
    input wire  [DATA_WIDTH-1:0]    dia,

    // Port B: Read Domain
    input wire                      clkb,
    input wire                      enb,
    input wire  [ADDR_WIDTH-1:0]    addrb,
    output reg  [DATA_WIDTH-1:0]    doutb
);

    // Declare the RAM variable
    reg [DATA_WIDTH-1:0] ram [0:RAM_DEPTH-1];

    // Port A: Write Operation
    always @(posedge clka) begin
        if (wea) begin
            ram[addra] <= dia;
        end
    end

    // Port B: Read Operation
    always @(posedge clkb) begin
        if (enb) begin
            doutb <= ram[addrb];
        end
    end

endmodule
