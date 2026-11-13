// voice_manager_tb.sv — plays tb/vectors/vm_events.hex (made by tools/voice_manager_ref.py gen)
// into voice_manager and logs every voice-RAM write to vm_writes.txt; the reference model
// then checks it bit-exactly:  python3 tools/voice_manager_ref.py check sim/verilator/vm_writes.txt
`timescale 1ns/1ps
module voice_manager_tb;
    logic clk = 0, rst = 1;
    always #11.072 clk = ~clk;

    logic [47:0] events [0:4095];
    int          n_events;
    logic [31:0] now = 0;
    logic        evt_empty = 1, evt_pop;
    logic [15:0] evt_data = 0;
    logic [29:0] vb_data;
    logic        busy;

    voice_manager dut (
        .clk(clk), .rst(rst), .enable(1'b1), .now_samples(now),
        .evt_empty(evt_empty), .evt_data(evt_data), .evt_pop(evt_pop),
        .vb_addr(8'd0), .vb_data(vb_data), .busy(busy));

    int fd;
    always @(posedge clk)
        if (dut.va_we) $fwrite(fd, "%02X %08X\n", dut.va_addr, dut.va_wdata);

    initial begin
        for (int i = 0; i < 4096; i++) events[i] = 48'hFFFF_FFFF_FFFF;
        $readmemh("../../tb/vectors/vm_events.hex", events);
        n_events = 0;
        while (n_events < 4096 && events[n_events] !== 48'hFFFF_FFFF_FFFF) n_events++;
        fd = $fopen("vm_writes.txt", "w");
        repeat (5) @(posedge clk);
        rst = 0;
        for (int i = 0; i < n_events; i++) begin
            @(posedge clk);
            while (busy) @(posedge clk);
            now       <= events[i][47:16];
            evt_data  <= events[i][15:0];
            evt_empty <= 0;
            @(posedge clk);
            while (!evt_pop) @(posedge clk);
            evt_empty <= 1;
            @(posedge clk);
        end
        while (busy) @(posedge clk);
        repeat (10) @(posedge clk);
        $fclose(fd);
        $display("voice_manager_tb: %0d events played", n_events);
        $finish;
    end
endmodule
