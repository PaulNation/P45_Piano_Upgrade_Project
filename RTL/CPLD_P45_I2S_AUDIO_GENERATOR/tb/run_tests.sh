#!/usr/bin/env bash
# Runs all testbenches with the open-source tools (iverilog + Verilator, oss-cad-suite),
# from the project folder:   tb/run_tests.sh          (add --stress for the 150-voice test)
# Questa: `make sim` runs the first file in tb/tb_files.f.
set -e
cd "$(dirname "$0")/.."
SRC=$(grep -v '^#' src/sources.f | sed 's|^|../../|')
AUDIO=$(echo "$SRC" | tr ' ' '\n' | grep -E "Flash|Voice")
W="-Wno-fatal -Wno-WIDTH -Wno-DECLFILENAME -Wno-UNUSEDSIGNAL -Wno-UNUSEDPARAM -Wno-INITIALDLY -Wno-BLKSEQ"
python3 tools/voice_manager_ref.py gen   > /dev/null
python3 tools/gen_flash_boot_vectors.py  > /dev/null
python3 tools/engine_ref.py gen          > /dev/null

mkdir -p sim/iverilog sim/verilator
cd sim/iverilog
iverilog -g2012 -o fifo.vvp ../../tb/async_fifo_tb.sv ../../src/Common/reset_sync.v ../../src/Common/async_fifo.v
vvp -n fifo.vvp | grep -E "PASS|FAIL"
iverilog -g2012 -o midi.vvp ../../tb/midi_tx_tb.sv ../../src/Common/tick_gen.v ../../src/Common/sync_fifo.v \
    ../../src/MIDI/uart_tx.v ../../src/MIDI/midi_tx.v
vvp -n midi.vvp | grep -E "PASS|FAIL"
iverilog -g2012 -o boot.vvp ../../tb/flash_boot_tb.sv ../../src/Flash/flash_reader.v ../../src/Flash/flash_boot.v
vvp -n boot.vvp | grep -E "PASS|FAIL"
iverilog -g2012 -o adc.vvp ../../tb/adc_ctrl_tb.sv ../../tb/models/master_volume_pot.v ../../src/Inputs/adc_ctrl.v \
    ../../src/Common/tick_gen.v
vvp -n adc.vvp | grep -E "PASS|FAIL"

cd ../verilator
verilator --binary --timing -j 8 $W --top-module cpld_p45_i2s_audio_generator_tb -o top_tb \
    ../../tb/cpld_p45_i2s_audio_generator_tb.sv ../../tb/models/master_volume_pot.v ../../tb/models/pll0.v $SRC > build_top.log 2>&1
./obj_dir/top_tb | grep -E "PASS|FAIL|ERROR"
verilator --binary --timing -j 8 $W --top-module voice_manager_tb -o vm_tb \
    ../../tb/voice_manager_tb.sv ../../src/Voice/voice_manager.v > build_vm.log 2>&1
./obj_dir/vm_tb > /dev/null && python3 ../../tools/voice_manager_ref.py check vm_writes.txt
verilator --binary --timing -j 8 $W --top-module audio_core_tb -o ac_tb \
    ../../tb/audio_core_tb.sv $AUDIO > build_ac.log 2>&1
./obj_dir/ac_tb > /dev/null && python3 ../../tools/engine_ref.py check engine_log.txt
if [ "$1" = "--stress" ]; then
    python3 ../../tools/engine_ref.py stress > /dev/null
    ./obj_dir/ac_tb +events=../../tb/vectors/engine_stress_events.hex +flashbin=flash_image_be.bin \
        +end=9000 +log=stress_log.txt > /dev/null && python3 ../../tools/engine_ref.py check stress_log.txt ../../tb/vectors/engine_stress_events.hex
fi
