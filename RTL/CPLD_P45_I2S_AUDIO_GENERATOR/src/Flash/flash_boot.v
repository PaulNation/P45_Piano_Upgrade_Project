// flash_boot.v — after reset, reads the image header and the file table out of the flash
// into block RAM, so the engine never has to read the table during playback.
//
// Image (Rhodes_Sample_Libary/scripts/lpc_rice_flash_packer.py, version 4), 16-bit words,
// 32-bit values high word first:
//   word 0 magic 0x5243, 1 version 4, 2 frame size, 3 file count N, 4-5 total words,
//   6 sample rate, 7 release base (440)
//   word 8 + 6*i: start word address (2 words), length in words (2), samples (2)
// File index: sustain = key*5 + layer (0..439), release = sustain + release_base.
//
// Table RAM per file: {start[24:0], samples[23:0]} (49 bit x 1024). Read port for the
// voice engine: tab_addr -> tab_start/tab_samples one clock later.
module flash_boot #(
    parameter MAX_FILES = 1024
) (
    input  wire        clk,
    input  wire        rst,

    // to flash_reader
    output reg         rd_req,
    output reg  [24:0] rd_addr,
    input  wire        rd_busy,
    input  wire        rd_valid,
    input  wire [15:0] rd_data,

    // status
    output reg         boot_done,      // table loaded, header valid
    output reg         boot_err,       // bad magic / version / file count (engine stays silent)
    output reg  [15:0] file_count,
    output reg  [15:0] release_base,

    // table read port (voice engine)
    input  wire [9:0]  tab_addr,
    output reg  [24:0] tab_start,
    output reg  [23:0] tab_samples
);

    localparam MAGIC = 16'h5243, VERSION = 16'd4;
    localparam S_HDR = 2'd0, S_TAB = 2'd1, S_DONE = 2'd2, S_ERR = 2'd3;

    // Table RAM: written from registered signals in a plain clocked block (no reset) so it maps
    // onto block RAM.
    reg [48:0] table_ram [0:MAX_FILES-1];
    reg        t_we;
    reg [9:0]  t_waddr;
    reg [48:0] t_wdata;

    always @(posedge clk) begin
        if (t_we) table_ram[t_waddr] <= t_wdata;
        {tab_start, tab_samples} <= table_ram[tab_addr];
    end

    reg [1:0]  st;
    reg        waiting;                     // a read is in flight
    reg [2:0]  word;                        // header word 0..7, or table word 0..5
    reg [9:0]  file;
    reg [15:0] w0, w1, w4;                  // table entry words kept until the entry is complete

    always @(posedge clk or posedge rst) begin
        if (rst) begin
            st           <= S_HDR;
            waiting      <= 1'b0;
            word         <= 3'd0;
            file         <= 10'd0;
            rd_req       <= 1'b0;
            rd_addr      <= 25'd0;
            boot_done    <= 1'b0;
            boot_err     <= 1'b0;
            file_count   <= 16'd0;
            release_base <= 16'd0;
            w0 <= 16'd0; w1 <= 16'd0; w4 <= 16'd0;
            t_we <= 1'b0; t_waddr <= 10'd0; t_wdata <= 49'd0;
        end else begin
            rd_req <= 1'b0;
            t_we   <= 1'b0;

            // issue the next read
            if (!waiting && !rd_busy && !rd_req && (st == S_HDR || st == S_TAB)) begin
                rd_req  <= 1'b1;
                rd_addr <= (st == S_HDR) ? {22'd0, word} : (25'd8 + {15'd0, file} * 25'd6 + {22'd0, word});
                waiting <= 1'b1;
            end

            if (rd_valid && waiting) begin
                waiting <= 1'b0;
                if (st == S_HDR) begin
                    case (word)
                        3'd0: if (rd_data != MAGIC)   st <= S_ERR;
                        3'd1: if (rd_data != VERSION) st <= S_ERR;
                        3'd3: begin
                                  file_count <= rd_data;
                                  if (rd_data == 16'd0 || rd_data > MAX_FILES) st <= S_ERR;
                              end
                        3'd7: release_base <= rd_data;
                        default: ;
                    endcase
                    word <= word + 1'b1;
                    if (word == 3'd7 && st == S_HDR) begin
                        st   <= S_TAB;
                        word <= 3'd0;
                    end
                end else begin
                    case (word)
                        3'd0: w0 <= rd_data;
                        3'd1: w1 <= rd_data;
                        3'd4: w4 <= rd_data;
                        3'd5: begin
                                  t_we    <= 1'b1;
                                  t_waddr <= file;
                                  t_wdata <= {w0[8:0], w1, w4[7:0], rd_data};
                              end
                        default: ;
                    endcase
                    if (word == 3'd5) begin
                        word <= 3'd0;
                        if ({6'd0, file} == file_count - 16'd1)
                            st <= S_DONE;
                        else
                            file <= file + 1'b1;
                    end else
                        word <= word + 1'b1;
                end
            end

            if (st == S_DONE) boot_done <= 1'b1;
            if (st == S_ERR)  boot_err  <= 1'b1;
        end
    end

endmodule
