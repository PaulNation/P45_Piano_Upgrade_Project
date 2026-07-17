module top (
    //System Ports
    input wire clk,
    input wire rst,

    //Soft Latching Power Circuit ports
    input wire PSWI,
    output wire PSWO,

    //Piano Interface Buttons/ Status LEDs
    input wire SUS_PEDAL,
    input wire FUNC_BTN,
    output wire ON_LED,
    //...Need ADC interface for Volume Control but leave it out for now
    
    //Memory Interface Ports TBD

    //Switch Matrix Ports - Piano Keys
    input wire [5:0] col_m1,
    input wire [5:0] col_m2,
    output wire [14:0] row,

    //I2S Ports - Digital Audio Amplifier
    output wire i2s_mclk,
    output wire i2s_bclk,
    output wire i2s_lrclk,
    output wire i2s_dout
);



scan_keys_controller scan_controller_slave(
    .clk(),
    .rst(),
    .row_en_n(row),
    .col_in_m1(),
    .col_in_m2(),

    .wea(),
    .addra(),
    .dia(),
);

pressed_keys_ram dual_port_ram_dual_clock(
    //Port A: Write Domain
    .clka(),
    .wea(),
    .addra(),
    .dia(),
    //Port B: Read Domain
    .clkb(),
    .enb(),
    .addrb(),
    .doutb()
);
    
endmodule
