# LPC + Golomb-Rice Flash Packer — Working Notes

Status as of 2026-11-01. Pick-up point for continuing this work.

## Goal

Losslessly compress the Rhodes sample library (16-bit mono 44.1 kHz `.pcm`) into
one `flash_image.bin` for a **64 MB / 32 M-word 16-bit parallel Flash**. The FPGA
must be able to start decoding at any frame boundary, and the decoder must stay
**multiplier-free**. Playback has **no runtime looping** (loops are baked into the full-length
renders by `rhodes_loop_tool.py`), so every voice decodes straight through from sample 0.

## Files

| File | What it is |
|---|---|
| `lpc_rice_flash_packer.py` | The packer (stdlib only). Encoder, reference decoder (`decode_file`), `--verify`. |
| `flash_image.bin` | Current image, format v3 (**61.30 MB, fits with 2.70 MB free**, B2 included). Full bit-exact verify passed. |
| `flash_image.json` | Host-side index: filename → start word address, length in words, samples. |
| `16bit_44.1kHz_Mono_Left_Only/samples/` | Source library, 704 files (88 notes × 8 velocities). **Never modified.** |

`rhodes_sample_codec.py` is an older, separate codec (R16C, byte-addressed). Not used here.

## Decisions made

- **Frame size:** 1024 samples (2026-11-01, was 256), every frame independently decodable. Bigger frames are
  nearly free because there is no looping/mid-sample seeking; 2048 would only save ~0.5 MB more and needs a 2-word header.
- **Predictor:** fixed polynomial, order **1–4 chosen per frame** (smallest output). User confirmed this over order-2-only.
- **Rice k:** 0..8 per frame (exact optimum), raw-frame fallback (`k=0xF`) when Rice doesn't win.
- **Velocity layers kept:** v016, v048, v064, v080, v112 (dropped **v032, v096, v127**).
- **B2 (n047) included** — with 1024-sample frames the full 88 notes × 5 layers fit, so no key remapping needed.

## Image format (version 3)

All fields are 16-bit words; 32-bit values are stored as two words, **high word first**.
All addresses are **word** addresses. Words written little-endian by default (`--big-endian` to flip).

```
Word 0      magic 0x5243 ('RC')
Word 1      version (3)
Word 2      frame size (1024)
Word 3      file count N
Word 4-5    total image length in words
Word 6      sample rate (44100)
Word 7      reserved
Word 8..    file table, N × 6 words: start addr (32b), length words (32b), samples (32b)
then        compressed data, files back to back
```

Frame (word-aligned):
```
Header word: [15:12] k (0..8) or 0xF = RAW
             [11:10] predictor order p - 1 (p = 1..4; 0 for RAW)
             [9:0]   payload length in words - 1 (1..1024), excludes header
Rice frame:  p raw int16 warm-up words, then Rice bitstream (MSB-first, zero padded)
RAW frame:   n raw int16 words
Rice code:   q ones, a 0 terminator, k-bit remainder; value is zig-zag of the residual
Residual:    wrap16(x - P), decode x = wrap16(P + r)  → all FPGA math can be 16-bit, carries dropped
Predictors:  p1 = x1 | p2 = 2x1-x2 | p3 = 3x1-3x2+x3 | p4 = 4x1-6x2+4x3-x4  (shift/add only)
```
Last frame of a file may be short; exact sample count comes from the file table.

## Commands

Current image (B2 included, fits with 2.70 MB free):
```
python3 lpc_rice_flash_packer.py 16bit_44.1kHz_Mono_Left_Only/samples \
  --exclude '*_v032_*' --exclude '*_v096_*' --exclude '*_v127_*' -o flash_image.bin
```
Useful flags: `--verify` (decode + bit-exact compare), `--orders 2` (force one order),
`--quiet-files` (skip per-file table), `--big-endian`, `--jobs N`.

## Results so far (5 velocity layers, 440 files unless noted)

| Config | Image | % of chip |
|---|---|---|
| All 8 layers, order 2, 128-frame | 119.5 MB | 187% |
| 7 layers (no v016), order 2, 128-frame | 109.5 MB | 171% |
| drop v016/v096/v112, order 2, 128-frame | 75.6 MB | 118% |
| drop v016/v096/v112, order 2, 256-frame | 71.57 MB | 112% |
| drop v016/v096/v112, orders 1–4, 256-frame | 65.82 MB | 103% |
| drop v032/v096/v112, orders 1–4, 256-frame | 64.76 MB | 101.2% |
| drop v032/v096/v127, orders 1–4, 256-frame | 64.44 MB | 100.7% |
| … same, 128-frame (estimate) | 68.57 MB | 107.1% |
| … same, 512-frame (estimate) | 62.37 MB | 97.5% |
| **… same, 1024-frame (current, v3)** | **61.30 MB** | **95.8%** |
| … same, 2048-frame (estimate) | 60.76 MB | 94.9% |

Compression ratio of current image: **5.71:1**. Order usage: p1 2.5%, p2 78.9%, p3 14.4%, p4 4.2%.
Biggest notes (all 5 layers ≈1.6–1.75 MB each): B2, Cs1, G1, Gs1, E1, F1 …

## Experiments already tried (don't repeat)

- Fixed order 3 or 4 alone is **worse** than order 2.
- Carrying predictor state across frames saves ~2.5–5 MB but breaks arbitrary-frame decode → **rejected**.
- Rice-coding the warm-up samples (only x0 raw) was **worse** — large residual + small k blows up the unary code.
- Shift-only "resonator" predictors `2x1 - x2 - (x1>>s)`: only ~1–1.5 MB gain even with a big bank → not adopted.
- Real LPC (measured with 256-sample frames; per-frame quantized coefs, orders 2–16, 12/15-bit, best-of with fixed 1–4), estimated
  2026-11-01 on the current 5-layer set: **63.17 MB vs 64.44 MB** — fits *with* B2 (~0.8 MB spare) but
  only saves 1.3 MB. Reason: many frames sit at the Rice 1-bit/sample floor on ±1–2 LSB noise that no
  predictor removes. Needs MACs (~45–62 M MAC/s at 88 voices, 16 taps). Not implemented in the packer;
  still "last resort". Estimate script was in the session scratchpad (not kept).

## Untested ideas (if more space is ever needed)

- **Escape code** for long unary runs (e.g. ≥16 ones → 16-bit raw value). Likely helps attacks; was about to test.
- **Several k values per frame** (e.g. split 1024 into 4×256 partitions, +4 bits each) — likely worth more now that frames are long.
- Allow k up to 15 (fits the 4-bit field; 0 RAW frames today, so minor).

## Open items / next steps

1. ~~Decide on the key mapping~~ **Resolved:** 1024-sample frames fit all 88 notes (B2 kept); no remapping.
2. ~~Run full-image verify~~ **Done 2026-11-01:** decoded all 440 files (183,453,908 samples)
   straight from `flash_image.bin` on disk, using the image's own header/file table → 0 mismatches
   (v2/256-frame image, and again on the v3/1024-frame image).
   (Parallel check took ~9 s; the built-in `--verify` is single-core and slower.)
3. Write the FPGA decoder to mirror `decode_file()`; dump decoded samples as testbench vectors.
   Per-voice state: x1..x4, bit position, k, order. See the FPGA notes below.
4. Pick the FPGA part (leaning **LFD2NX-28-8BG256C**, see below) and confirm the pin plan against the
   Lattice pinout file (exact PLL-ref / PCLK / ADC ball names).

## FPGA decoder notes

- State machine: READ_HDR → WARMUP (`order` raw words into history) → RICE loop → next frame. RAW frame = copy n words.
- Compute all four predictions every cycle and mux by `order` (or a single selected one). ~3 adder levels, 16-bit wide.
- With `d = x1 - x2`: p2 = x1 + d; p3 = x3 + (d<<1) + d; p4 = ((x1+x3)<<2) - (x2<<2) - (x2<<1) - x4.
- The length field lets the decoder hop header→header to reach a frame without parsing its bitstream.

## Decoder throughput budget (88 voices × 44.1 kHz = 3.88 M samples/s)

- At a 50 MHz decoder clock: **12.9 cycles per voice-sample**. (A GPLL could run it at 100 MHz → 25.8.)
- Fixed order 1–4: ~1–2 cycles/sample (Rice bit-reader with a 1-cycle leading-ones counter + predictor) → ~10–15%, no multipliers.
- Real LPC: 16 taps on 1 multiplier = 16 cycles → does **not** fit at 50 MHz; needs a sysDSP slice in
  dual-MAC mode (2 × 18×18 per cycle → 8 cycles) or a full block (4 multipliers → 4 cycles). 8 taps on 1 multiplier = 8 cycles.
- Flash: ~0.72 M words/s average, ~4.1 M words/s worst case (all voices on attack frames) vs ~10 M words/s at 100 ns/read.
- Per-voice prefetch FIFO ~256 words (88 × 256 × 16 b ≈ 360 kb) absorbs bursts and long unary codes.
- Polyphony note: 88 keys can need >88 voices (re-strikes while ringing); budgets scale linearly.

## FPGA selection (Lattice Certus-NX, datasheet FPGA-DS-02078-2.6)

- **LFD2NX-9 rejected:** only 71 user I/O (bottom HPIO banks 3/4/5 = 48 pins, max 1.8 V; banks 0/1 are
  mostly config/JTAG). Full design needs ~98 pins.
- **Chosen direction: LFD2NX-28-8BG256C** (caBGA256, 0.8 mm pitch, Production): 185 user I/O
  (HPIO banks 3/4/5 = 74 @ ≤1.8 V; WRIO banks 0/1/2/6/7 = 111 @ ≤3.3 V), 40 × 18×18 multipliers,
  1,044 kb EBR + 1,024 kb LRAM, 3 GPLLs, 2 dedicated ADC pairs. LFD2NX-40 is pin-compatible (56 DSP, 1,512 kb EBR) if more is needed.
- Speed grade **-8 or -9** required (ADC only exists in -8/-9 C/I).
- Avoid the I/O-optimized LFD2NX-15/25 in caBGA256 ("Advance" status).
- -28 has SERDES supply pins (VCCSD0, VCCPLLSD0, VCCAUXSD) — connect per hardware checklist FPGA-TN-02151 even if unused.

## Pin plan (LFD2NX-28, caBGA256) — ~102 used, ~83 spare

| Bank | Pins | VCCIO | Assignment | Used |
|---|---|---|---|---|
| 3 (bottom, HPIO) | 32 | 1.8 V | Flash A[24:0] + 50 MHz clock on a GPLL ref pin (LRC_GPLL) | 26 |
| 4 (bottom, HPIO) | 32 | 1.8 V | Flash DQ[15:0] + 6 control + DAC/audio amp (6, DVDD = 1.8 V) | 28 |
| 5 (bottom, HPIO) | 10 | 1.8 V | spare | 0 |
| 6 (left, WRIO) | 28 | 3.3 V | Key matrix: COL_M1_N[5:0], COL_M2_N[5:0] (open-drain out), ROW_N[14:0] (in) | 27 |
| 7 (left, WRIO) | 22 | 3.3 V | PSWI, PSWO, Headphone_in, MIDI UART TX, power LED, sustain pedal, reset | 7 |
| 2 (right, WRIO) | 28 | 3.3 V | spare | 0 |
| 1 (right, WRIO) | 21 | 3.3 V | JTAG (+ hard I2C if the DAC needs control) | 4 |
| 0 (top, WRIO) | 12 | 3.3 V | Config SPI flash, PROGRAMN/INITN/DONE | ~10 |
| ADC (dedicated) | — | 1.8 V ext. ref | Master volume pot: wiper → ADC_DP0, ADC_DN0 → GND, ADC_REFP0 = 1.8 V ref | — |

Parallel flash runs with V_IO = 1.8 V (HPIO banks can't exceed 1.8 V). If it is only ever programmed
off-board, WE#/WP#/BYTE#/RY-BY# can be strapped on the PCB to free 4 pins.

### Key matrix (88 keys, dual-contact velocity)
- 15 rows × 6 columns × 2 contact sets (M1/M2) = 180 contacts. Open-drain, 3.3 V, no level shifting.
- COL_M1_N / COL_M2_N: FPGA open-drain outputs (`assign col = drive ? 1'b0 : 1'bz;`), one low at a time; optional ~10 kΩ pull-ups.
- ROW_N[14:0]: FPGA inputs, LVCMOS33 with hysteresis, **external 4.7–10 kΩ pull-ups to 3.3 V**.
- Scan: ~3–5 µs settle per column → full scan ≈ 60 µs; velocity = M1→M2 close time (fast strikes ≈ 1 ms).

### Other I/O notes
- Power LED on 3.3 V bank (red LED Vf ≈ 1.8–2 V won't light from 1.8 V).
- Sustain pedal: pull-up, debounce in logic, ESD protection on the jack.
- PSWO (soft-power hold) needs a pull resistor so it's in a safe state before configuration completes.
- MIDI: opto output pulled up to 3.3 V, UART RX at 31,250 baud.
- User reset is a GPIO; PROGRAMN reconfigures the FPGA (not a logic reset).
- The ADC clock is hardwired to the lower-right PLL CLKOS4, so that PLL must be used.
