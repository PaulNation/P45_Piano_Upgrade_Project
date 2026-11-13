// sync_fifo.v — single-clock FIFO, show-ahead read (rd_data valid while !empty).
module sync_fifo #(
    parameter DATA_W = 16,
    parameter ADDR_W = 6                       // 64 entries
) (
    input  wire              clk,
    input  wire              rst,
    input  wire              wr_en,
    input  wire [DATA_W-1:0] wr_data,
    output wire              full,
    input  wire              rd_en,
    output wire [DATA_W-1:0] rd_data,
    output wire              empty
);

    reg [DATA_W-1:0] mem [0:(1<<ADDR_W)-1];
    reg [ADDR_W:0]   wr_ptr, rd_ptr;

    assign empty   = (wr_ptr == rd_ptr);
    assign full    = (wr_ptr == {~rd_ptr[ADDR_W], rd_ptr[ADDR_W-1:0]});
    assign rd_data = mem[rd_ptr[ADDR_W-1:0]];

    always @(posedge clk) begin
        if (wr_en && !full)
            mem[wr_ptr[ADDR_W-1:0]] <= wr_data;
    end

    always @(posedge clk or posedge rst) begin
        if (rst) begin
            wr_ptr <= 0;
            rd_ptr <= 0;
        end else begin
            if (wr_en && !full)
                wr_ptr <= wr_ptr + 1'b1;
            if (rd_en && !empty)
                rd_ptr <= rd_ptr + 1'b1;
        end
    end

endmodule
