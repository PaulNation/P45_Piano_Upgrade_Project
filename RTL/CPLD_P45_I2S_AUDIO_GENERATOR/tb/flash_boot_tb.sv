// flash_boot_tb.sv — flash_reader + flash_boot against a flash model holding the real image
// header and file table (tools/gen_flash_boot_vectors.py). The model drives X until tACC has
// passed after an address/OE change, so a read sampled too early fails the compare.
`timescale 1ns/1ps
`ifndef ACC
`define ACC 6
`endif
module flash_boot_tb;
    localparam real T_ACC_NS = 100.0;
    logic clk = 0, rst = 1;
    always #11.072 clk = ~clk;                 // 45.1584 MHz

    // ---------------- flash model
    logic [15:0] head [0:8191];
    wire  [24:0] A;
    wire         CE_N, OE_N, WE_N;
    logic [15:0] DQ;
    initial $readmemh("../../tb/vectors/flash_head.hex", head);
    always @(A or CE_N or OE_N) begin
        DQ = 16'hxxxx;
        if (!CE_N && !OE_N) begin
            #(T_ACC_NS);
            if (!CE_N && !OE_N) DQ = (A < 8192) ? head[A[12:0]] : 16'hFFFF;
        end
    end

    // ---------------- DUT
    wire        req, busy, rvalid;
    wire [24:0] addr;
    wire [15:0] rdata;
    flash_reader #(.ACCESS_CLKS(`ACC)) u_rd (.clk(clk), .rst(rst), .req(req), .addr(addr), .busy(busy), .rvalid(rvalid),
                       .rdata(rdata), .FLASH_A(A), .FLASH_DQ(DQ), .FLASH_CE_N(CE_N),
                       .FLASH_OE_N(OE_N), .FLASH_WE_N(WE_N));
    logic [9:0]  tab_addr = 0;
    wire  [24:0] tab_start;
    wire  [23:0] tab_samples;
    wire         done, err;
    wire  [15:0] nfiles, rbase;
    flash_boot u_boot (.clk(clk), .rst(rst), .rd_req(req), .rd_addr(addr), .rd_busy(busy),
                       .rd_valid(rvalid), .rd_data(rdata), .boot_done(done), .boot_err(err),
                       .file_count(nfiles), .release_base(rbase), .tab_addr(tab_addr),
                       .tab_start(tab_start), .tab_samples(tab_samples));

    logic [48:0] expected [0:1023];
    initial $readmemh("../../tb/vectors/flash_table_expected.hex", expected);

    int errors = 0;
    realtime t0;
    initial begin
        #100 rst = 0;
        t0 = $realtime;
        fork
            wait (done || err);
            begin #5_000_000; end                // 5 ms: a good boot takes ~1 ms
        join_any
        disable fork;
        if (err)   begin $display("FAIL flash_boot: boot_err"); $finish; end
        if (!done) begin $display("FAIL flash_boot: boot did not finish (bad reads?)"); $finish; end
        $display("boot done after %0.1f us: %0d files, release base %0d", ($realtime - t0) / 1000.0, nfiles, rbase);
        for (int i = 0; i < nfiles; i++) begin
            @(posedge clk) tab_addr <= i[9:0];
            @(posedge clk); @(posedge clk);
            if ({tab_start, tab_samples} !== expected[i]) begin
                errors++;
                if (errors < 5) $display("ERROR file %0d: start %0d samples %0d, expected %013h",
                                         i, tab_start, tab_samples, expected[i]);
            end
        end
        if (errors == 0 && nfiles == 880 && rbase == 440)
            $display("PASS flash_boot: header OK, all %0d file-table entries match flash_image.json", nfiles);
        else
            $display("FAIL flash_boot: %0d errors", errors);
        $finish;
    end
endmodule
