# lpc_rice_decoder_tb.do — Questa script for the LPC/Rice decoder testbench.
# `make sim` runs the top-level testbench (first entry in tb_files.f); use this
# script to run the decoder testbench on its own.
#
# From the project folder:
#   cd sim/out && vsim -c -do ../../tb/lpc_rice_decoder_tb.do     (console)
#   cd sim/out && vsim -do ../../tb/lpc_rice_decoder_tb.do        (GUI, waveforms)
# Optional plusargs on the vsim line below: +STALL_PCT=<0..99> +SEED=<n> +WAV_FILE=<name>
#
# Outputs in sim/out:
#   lpc_rice_whole_file.wav   decoded test 0 (one complete sample file), 16-bit mono 44.1 kHz
#   lpc_rice_zoom.do          wave-window zoom onto test 0 (used below in GUI mode)
#
# Regenerate vectors after rebuilding flash_image.bin:
#   python3 tb/gen_lpc_rice_vectors.py [--whole-file rhodes_C4_n060_v080_sus.pcm]

onbreak {resume}

vlib lpc_work
vlog -work lpc_work ../../src/Sample_Decoder/lpc_rice_decoder.v
vlog -sv -work lpc_work ../../tb/lpc_rice_decoder_tb.sv
vsim -voptargs=+acc lpc_work.lpc_rice_decoder_tb +VEC_DIR=../../tb/vectors/

if {[batch_mode]} {
    run -all
    quit -f
} else {
    add wave -noupdate -divider "Whole sample file (test 0)"
    add wave -noupdate -format analog-step -height 250 -radix decimal \
        -min -32768 -max 32767 /lpc_rice_decoder_tb/audio_out
    add wave -noupdate -divider "Decoder output"
    add wave -noupdate /lpc_rice_decoder_tb/out_valid /lpc_rice_decoder_tb/out_ready
    add wave -noupdate -radix decimal /lpc_rice_decoder_tb/out_data
    add wave -noupdate -divider "Decoder internals"
    add wave -noupdate -radix unsigned /lpc_rice_decoder_tb/dut/state \
        /lpc_rice_decoder_tb/dut/k /lpc_rice_decoder_tb/dut/order \
        /lpc_rice_decoder_tb/dut/frame_left /lpc_rice_decoder_tb/dut/samples_left \
        /lpc_rice_decoder_tb/dut/nbits /lpc_rice_decoder_tb/dut/lo
    add wave -noupdate -radix hexadecimal /lpc_rice_decoder_tb/dut/bitbuf \
        /lpc_rice_decoder_tb/in_valid /lpc_rice_decoder_tb/in_ready /lpc_rice_decoder_tb/in_data
    add wave -noupdate -radix decimal /lpc_rice_decoder_tb/dut/x1 /lpc_rice_decoder_tb/dut/x2
    run -all
    if {[file exists lpc_rice_zoom.do]} { do lpc_rice_zoom.do }
}
