# RTL source files — one path per line, relative to project root
# Common
src/Common/reset_sync.v
src/Common/tick_gen.v
src/Common/sync_fifo.v
src/Common/async_fifo.v
# Control domain: key matrix, key events, inputs, MIDI out
src/Switch_Matrix/sync_2ff.v
src/Switch_Matrix/scan_columns.v
src/Switch_Matrix/activate_rows.v
src/Switch_Matrix/key_address_encoder.v
src/Switch_Matrix/scan_keys_controller.v
src/Key_Events/key_event_gen.v
src/Key_Events/event_merge.v
src/Inputs/debounce.v
src/Inputs/adc_ctrl.v
src/MIDI/uart_tx.v
src/MIDI/midi_tx.v
# Audio domain: flash, voices, I2S
src/Flash/flash_reader.v
src/Flash/flash_boot.v
src/Voice/voice_manager.v
src/Voice/voice_engine.v
src/Voice/i2s_tx.v
src/Voice/audio_core.v
src/Sample_Decoder/lpc_rice_decoder.v
# Top
src/cpld_p45_i2s_audio_generator_top.v
