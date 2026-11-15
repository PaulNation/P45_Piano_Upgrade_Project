# LPC + Golomb-Rice Flash Packer — Working Notes

> **Folder reorganized 2026-11-11** (see README.md for the current layout and commands).
> Older entries below use the old paths: `16bit_44.1kHz_Mono_Left_Only/samples_rebounce` → `library/sustains`,
> `.../releases` → `library/releases`, `release_extract/*` → `data/` and `previews/`, scripts → `scripts/`,
> renders → `renders/` (the "keysacpe_..._render.wav" names were fixed). The original 8-layer library
> (`16bit_44.1kHz_Mono_Left_Only/samples`), `make_sampler_midi.py`, `slice_to_pcm.py` and the old v3
> image were **deleted at the user's request**; what they provided is frozen in
> `data/velocity_levels_8layer.json` and `data/sustain_lengths.json`.
> Releases are now extracted against `library/sustains` (not the old library); velocity_layer.mem
> changed in 32 of 11264 entries by one 0.5 dB step (levels saved rounded to 0.01 dB).


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

## Image format (version 4; v3 was identical except word 7 and file order)

All fields are 16-bit words; 32-bit values are stored as two words, **high word first**.
All addresses are **word** addresses. Words written little-endian by default (`--big-endian` to flip).

```
Word 0      magic 0x5243 ('RC')
Word 1      version (4)
Word 2      frame size (1024)
Word 3      file count N
Word 4-5    total image length in words
Word 6      sample rate (44100)
Word 7      release base S (entry i+S = release of sustain i; 0 = no releases)
Word 8..    file table, N × 6 words: start addr (32b), length words (32b), samples (32b)
then        compressed data, files back to back
```
File order (v4): sorted by (note, velocity) → sustain idx = (note−21)·5 + layer (0..439),
release idx = 440 + the same. Zero-length entry = no file.

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

Current image (v4, 2026-11-11: re-bounced sustains + 440 releases):
```
venv/bin/python lpc_rice_flash_packer.py 16bit_44.1kHz_Mono_Left_Only/samples_rebounce \
  --releases 16bit_44.1kHz_Mono_Left_Only/releases --verify
```
Old v3 image (original sustains only, alphabetical) kept as `flash_image_v3_old.bin/.json`:
`python3 lpc_rice_flash_packer.py 16bit_44.1kHz_Mono_Left_Only/samples --exclude '*_v032_*'
--exclude '*_v096_*' --exclude '*_v127_*' -o flash_image.bin`
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
3. ~~Write the FPGA decoder~~ **Single-voice RTL done 2026-11-02:**
   `RTL/CPLD_P45_I2S_AUDIO_GENERATOR/src/Sample_Decoder/lpc_rice_decoder.v` (valid/ready word in,
   valid/ready sample out, ~1 clk/sample). Testbench `tb/lpc_rice_decoder_tb.sv` + vectors from
   `tb/gen_lpc_rice_vectors.py` (real frames from flash_image.bin + synthetic edge cases); passes
   bit-exact in Icarus incl. random stalls. Next: 88-voice time-multiplexing (state in RAM), file-table
   lookup + flash read controller.
4. FPGA part: **LFD2NX-28 chosen (2026-11-02)**. The Radiant project setup still targets the MachXO3D
   (`project.meta`) on purpose — leave it until Radiant is installed. Still to do: confirm the pin plan
   against the Lattice pinout file (exact PLL-ref / PCLK / ADC ball names).
5. **88-voice engine** — see "88-voice top-level plan" below. Next coding step: refactor
   `lpc_rice_decoder.v` so its state lives in a per-voice context RAM, then the voice sequencer,
   tested with 2–3 voices against the existing vectors.
6. **Release samples — pipeline built 2026-11-04, waiting on the user's render:**
   - **MIDI:** `make_release_midi.py` writes `keyscape_release_sampler.mid` + its manifest:
     - 88 keys × the 5 library layers; hold 1.0 s, tail 1.5 s, gap 0.3 s; 20.6 min bounce
     - note-on **and** note-off velocity = the layer, so it doesn't matter which one Keyscape uses
     - `--check` gives a 16 s test clip (A0, C2, C4, C6, C8 at v64)
   - **Render:** same patch/settings as the sustain library (the library was rendered with
     **mechanical noise ON**, so keep it on), release ON, transition mode OFF, 44.1 kHz, clip at 1.1.1.
   - **Output folder confirmed by the user:** `16bit_44.1kHz_Mono_Left_Only/releases/`.
   - **Extraction:** `venv/bin/python extract_releases.py bounce.wav keyscape_release_sampler_manifest.json`
     → `16bit_44.1kHz_Mono_Left_Only/releases/*_rel.pcm` + `index.json` (`-w DIR` adds .wav copies).
     Per slot:
     1. extrapolate the sustain past note-off with a Burg AR model (order picked by a held-out test)
     2. subtract it × the 6.4 ms quadratic fade (delay fitted per slot, ~1–2.3 ms)
     3. level-match to the library `_sus.pcm` of the same key/velocity (sustain RMS from 50 ms to
        hold−100 ms)
     4. trim at digital silence, 4 ms end fade
   - **Validated on C4** (`release_extract/rhodes_C4_n060_v064_rel.*`, from Pattern 3): run on the
     release-OFF render (Pattern 3_4), only −35…−41 dB of sustain is left in the first 8 ms and
     nothing after, i.e. 25–30 dB under the release. The two-render subtraction alternative failed:
     renders differ (start jitter, round-robin key noise), so they cancel only 3.6 dB.
   - **Mapping:** `release_extract/keyscape_release_map.json` (from Keyscape XML metadata). **v064 and
     v080 share the same release on every key; v016 and v048 also share it on the top 25 keys**, so
     the 5 layers need only **327 distinct releases**, not 440. The packer could alias them in the
     file table.
   - **Check render** (`release test.wav`, rendered at 148 BPM → `--tempo-actual 148`; 2026-11-04):
     - The render matches the library sustains sample-for-sample (correlation 0.9999, level within
       0.01 dB), so the user's Keyscape settings equal the library's.
     - The extractor now also uses the **library `_sus.pcm` as a reference** for the sustain past
       note-off, and picks per slot whichever of library and AR (orders up to 1600, single-pass
       Burg) predicts better. Low keys pick the library (A0 −32 dB, C2 −42 dB); C4/C6 pick AR 400
       (−38/−45 dB).
     - The fade is fixed at 6.4 ms quadratic, with its delay searched only within ±1 ms of 1.6 ms.
       A wider search on low keys absorbed the release's own tone (fits up to 25 ms). The true
       fade on keys other than C4 is unmeasured; a release-OFF render of the check clip would
       measure it.
     - **Top keys barely have a release** (no dampers on a real Rhodes; Keyscape also trims them
       down from C6 up). Release peaks: A0 −24, C2 −15, C4 −22, C6 −36, C8 −56 dBFS.
       `--min-peak-dbfs` (default −50) skips inaudible releases, listed in `index.json` under
       `skipped_quiet`.
   - **NULL-TEST SET (current, 2026-11-11) — replaces the single-render set:**
     - The user's idea: render the clip twice in the same project at 148 BPM, release ON
       (`keysacpe_release_sampler_with_release_render.wav`) and release OFF
       (`keysacpe_release_sampler_without_release_render.wav`). Both are 998.9 s and line up at
       **lag 0 on all 440 slots**; the sustain cancels at a median of −55.9 dB before note-off.
       What was left at the start of the user's C3 test was key-down mechanical noise
       (4 round-robins, differs per render), not pedal noise; it lies before note-off and is
       dropped.
     - **Keyscape fade measured on every key** (from the release-OFF render), gain per ms after
       note-off + latency: 1, 1, 1, 0.81, 0.56, 0.37, 0.20, 0.05, 0.01, 0. That is a ~2–3 ms hold,
       then a ~5 ms near-linear ramp. Mid/top keys agree within ±1 ms; low keys read 1–3 ms later
       but are noisier. Now `extract_releases.FADE_TABLE`, and **the FPGA should use this table**
       (it replaces the 6.4 ms quadratic).
     - The release-OFF render also has a **low-frequency output tail (~15–20 Hz, −41…−54 dBFS,
       up to ~90 ms) after the fade on low keys**, probably Keyscape's amp/EQ filter ringing. The
       player has no such filter, so a pure ON−OFF subtraction would lose it.
     - **Final method:** release = release-ON render − (library sustain aligned to the render ×
       FADE_TABLE), where the library sustain matches the render at −35 dB or better (379 slots);
       otherwise release = ON − OFF (25 slots). Then library sustain × FADE_TABLE + release
       reproduces Keyscape to −45…−81 dB in the first 12 ms after note-off and ≤ −44 dB after
       (`make_release_preview.py` A/B).
     - Command: `venv/bin/python extract_releases.py keysacpe_release_sampler_with_release_render.wav
       keyscape_release_sampler_manifest.json --release-off
       keysacpe_release_sampler_without_release_render.wav --tempo-actual 148
       -o 16bit_44.1kHz_Mono_Left_Only/releases -w release_extract/wav` (~2 min)
     - **404 releases** in `16bit_44.1kHz_Mono_Left_Only/releases/`, 36 skipped (< −50 dBFS); level
       match ±0.2 dB; **2.37 MB compressed → image 66.65 MB of 67.11 MB (99.3%)**.
     - The old single-render set is in `release_extract/releases_single_render_method/` (it came
       from a different, deleted render: other round-robin takes, so ~4–6 dB different).
     - Alignment searches now use least leftover / normalized correlation (max raw correlation
       locked onto neighbouring periods on ~90 slots).
   - **Full render done 2026-11-04** (`release full render.wav`, 148 BPM, 998.9 s):
     - Command: `venv/bin/python extract_releases.py "release full render.wav"
       keyscape_release_sampler_manifest.json --tempo-actual 148 -o 16bit_44.1kHz_Mono_Left_Only/releases
       -w release_extract/wav` (60 s; log in `release_extract/extract_log.txt`)
     - **404 releases written; 36 skipped** under −50 dBFS (C#6 and up, mostly v016/v048).
       Per-key peak levels: `release_extract/release_levels.csv`.
     - Level match to the library: within ±0.2 dB everywhere.
     - Sustain models: 308 AR, 96 library reference.
     - Leftover sustain vs the release (first 12 ms only): ≤ −20 dB for all, ≤ −30 dB for 380.
       Weakest: C1 v080 (−21), A#1 v112, A0 v112, C1 v112, G#2 v080 (−22…−25 dB).
     - **v080 releases are ~5 dB louder than v064** (median +5.2, 10–90%: +1.7…+8.3) despite sharing
       a Keyscape zone, so Keyscape scales the release level by velocity. Sharing would need a
       per-voice gain.
     - **Flash:** 404 releases = 10.9 M samples (247 s); the packer's encoder gives **2.37 MB** (9.2:1,
       incl. table entries). Image 64.28 MB + 2.37 = **66.65 MB of 67.11 MB (99.3%)**, so **all
       releases fit**. (Earlier "61.30 MB" figures are MiB = the same 64.28 MB.)
     - **Re-extracted with a fixed fade** (delay 1.6 ms, 6.4 ms quadratic, the same as playback):
       405 releases, 35 skipped. Any fade-model error now sits inside the release, so library
       sustain × fade + release ≈ the Keyscape render.
   - **Previews** (`make_release_preview.py`):
     - `release_extract/preview/AB_keyscape_then_rebuilt.wav` (A0/C2/C4/C6/A6 × 5 layers; rebuilt vs
       Keyscape: sustain −28…−58 dB, first 12 ms after note-off −33…−65 dB)
     - `--holds 0.5,2,5` → `release_extract/preview_holds/` (library sustain released at chosen times)
     - The library `samples/` are full sustains with no release. Top-key files are only 1.8–2.3 s
       long (trimmed tails).
   - **Release level vs time held — measured 2026-11-04** (`keyscape_release_sampler_holdsweep.mid`
     → `holdsweep full render.wav`, 148 BPM; A0/C2/C4/C6 × v048/v112; holds 0.25–16 s; per-hold
     extractions in `release_extract/holdsweep/hold*/`):
     - The user is right: the release gets quieter as the note dies away. It is ~flat up to ~2 s,
       then falls; at 16 s it is −20…−60 dB or silent.
       vs 1 s hold (v048/v112): A0 4 s −8/−14, 16 s −28/−37 · C2 4 s −8/−9, 16 s −21/−22 ·
       C4 4 s −12/−15, 16 s −41/−58 · C6 4 s −11/−28, 8 s −20/−36, 16 s silent
     - "Release follows the sustain dB 1:1" fits badly (5.8 dB rms). The best slope per key/velocity
       ranges 0.36–2.4.
     - A **per-key table of release gain vs time held**, shared by all velocities, fits to **~3 dB
       rms** (round-robin variation alone is ~1–3 dB).
     - **Plan:** at note-off, look up the key's table (~8 points, 0.25–16 s, interpolated) from the
       voice's held-time counter; that gain scales the release via the per-voice multiplier. The
       extracted releases (0.81 s hold) are the full-level versions.
     - **The hold-sweep audio was deleted by the user (2026-11-11).** The numbers above are all
       that remain; re-render the hold sweep if the table is needed.
     - **RESOLVED 2026-11-11 by a wide sweep** (user chose option 2):
       - `make_release_midi.py --hold-sweep-wide`: every 4th key from A0 plus C8 (23 keys) ×
         v048/v112 × holds 0.25…16 s (MIDI; ≤ 4 s from C#6 up), 294 slots.
       - Rendered release ON and OFF at 148 BPM: `keyscape_release_sampler_holdsweep_wide_{with,without}_release_render.wav`.
         Lag 0 on 286/294; cancellation median −68 dB.
       - Real holds at 148 BPM: 0.203, 0.405, **0.811 (reference = the hold the release set was
         extracted at)**, 1.62, 3.24, 6.49, 12.97 s.
       - **`make_release_gain_table.py`** → `release_extract/release_gain_table.{json,csv}`
         (raw data: `release_extract/holdsweep_wide/measurements.json`):
         - gain in dB for 88 keys × 5 layers × holds [0, 0.203 … 12.97 s] (0.5 dB steps)
         - interpolate in dB between holds; mute after 12.97 s
         - 3-point median across measured keys, linear across keys
         - v016 = v048; v064/v080 interpolated by velocity between v048 and v112
         - measurements below −75 dBFS are treated as unreliable; top keys extend the
           1.6→3.2 s trend to 6.5 s
         - fit on measured keys: 2.1 dB rms (round-robin variation alone is ~1–3 dB)
       - Behaviour: flat (+0…+3 dB) up to 0.81 s. At 1.62 s, v048 is ~0 while v112 is −1…−10 dB
         on low/mid keys and −12…−21 dB on top keys. At 3.24 s −8…−17 (v048) / −9…−33 (v112);
         at 6.49 s −13…−25 / −25…−41; at 12.97 s ≤ −50 or silent (muted).
       - **The fade does not depend on the hold** (0.2–3.2 s all match FADE_TABLE within ±0.05).
       - The hold holds double each step, so the FPGA can index the table by the held-time
         counter's top bit (8 entries per key/layer; 88×5×8 = 3520 entries).
       - `make_release_preview.py --holds ...` now applies the table
         (`release_extract/preview_holds/all_holds.wav`, holds 0.5/1.5/3/6 s).
     - **Decided 2026-11-11: the gain, fade and dB→linear tables live in the FPGA** (block RAM / LUT
       ROM initialised at synthesis), not in the sample flash. Reasons: no flash reads at
       note-off, simpler image format, they fit easily, and they update with the bitstream.
       - **`make_fpga_tables.py`** writes `$readmemh` files to
         `RTL/CPLD_P45_I2S_AUDIO_GENERATOR/src/Sample_Decoder/tables/`:
         - `release_gain.mem`: 3520 × 8 bit; address ((key·5)+layer)·8+slot; slot k = held
           time 2^(13+k) samples (0.186…23.8 s, power-of-two so the slot is the counter's
           top bit − 13 and the fraction is the bits below it); code = attenuation in 0.5 dB
           steps from +6 dB, 255 = mute
         - `db_to_lin.mem`: 256 × 16 bit, Q2.14
         - `fade.mem`: 512 × 16 bit, one entry per sample, Q1.15 (9.0 ms non-zero)
       - Player lookup vs the JSON table: 1.6 dB rms, max 5.5 dB on steep segments; 16 slots
         per row would reduce that if wanted.
     - **Flash image with releases (planned packer change):** header (file count 880) + file
       table of 880 entries: 0–439 sustains as now, **440–879 releases in the same key/layer
       order (release of entry i = i + 440)**, length 0 = no release + sustain audio
       + release audio. Only audio goes in the .bin.
     - **2026-11-11: all 440 releases kept** (user: "include all the release notes"). Re-extracted
       with `--min-peak-dbfs -1000` (same command as above plus that flag); the 36 quiet top-key
       ones (−49…−90 dBFS peak) are now included. Compressed 2.48 MB → image **66.76 MB =
       63.67 MiB of 64 MiB (99.5%), 0.33 MiB free**. No "length 0" entries are needed.
     - (old) OPEN DECISION, kept for history:
       1. interpolate across keys from these 4 measured keys, or
       2. render one more sweep: every 4th key (22 keys) at v064 × the same 7 holds (~16 min at
          120 BPM), to measure the table everywhere. MIDI not generated yet (would be a new
          option in make_release_midi.py).
     - Then: add releases + gain tables to the packer/image (file-table entries, "no release" flag),
       then the FPGA release voice.
   Analysis (item 7) shows they can be extracted from note-on/note-off renders by subtracting the
   sustain fade. Until then, key release = a ~6 ms fade (item 7).
7. **Re-strike behaviour — analysed 2026-11-03** from Keyscape recordings of one key, struck at 0 s,
   re-struck at 1.519 s while ringing, released at ~3.035 s, pedal off.
   **Use `Pattern 2_2.wav` (dry, dual-mono)**. `Pattern 2.wav` had auto-pan on and is superseded.
   The key is MIDI 60, 261.8 Hz; Keyscape calls it "C5", and it is our library's C4. The Keyscape
   render does **not** match our library's samples sample-for-sample (correlation ≈ 0), so it is a
   different patch or settings.
   - **New note:** the same sample at the same gain as the first strike (gain 0.9999; difference
     −63 dB after 500 ms). It starts at full level instantly, with no fade-in and no gap before it.
   - **Old note:** keeps full level right up to the new attack, then is choked (not stacked). The
     audible switchover is done in **~10 ms**: the old note's leftover is −14 dB under the new note at
     10 ms and −21 dB at 15 ms. The best-fitting fade is exponential with τ ≈ 13 ms, but it beats a hard
     cut by only ~5 dB; most of the leftover is small attack differences, and the new attack masks
     the tail.
   - **Release (key up, pedal off):** this is a damper behaviour, not a plain fade:
     - the tone drops to ~0.3 (−10 dB) within ~4 ms
     - it holds ~0.3 for ~20 ms
     - it is gone (< −30 dB) by ~32 ms after key-up
     - over that time there is extra non-tonal "damper" sound at −8 to −15 dB
     - then a faint tail at −25 to −55 dB for ~0.5 s

     Release samples would capture the damper sound and the tail. Until then, a ~30 ms fade, or the
     two-stage drop above, is the approximation.
   - **Mechanism (joint fit, 3 ms windows):** a re-strike looks like key-up + key-down at the same
     instant. The old note gets the same **two-stage damper curve** as a release, and the new note
     starts on top of it:
     - **Re-strike:** old gain unmeasurable for 0–5 ms (masked by the new attack), plateau ~0.5 at
       6–14 ms, through 0.2 at 16–22 ms, gone by ~24 ms. Extra noise −12 to −17 dB.
     - **Release:** drop to ~0.35 in ~3 ms, plateau ~0.3 for ~20 ms, gone ~23 ms after the drop.
       Extra damper noise −8 to −10 dB.
     - **Confirmed from `untitled.mid`** (the pattern that made the recording; ppq 96, 79 BPM):
       note 60, velocity 64. Note-on at 0 s; at 1.519 s (tick 192) a note-off and then a note-on;
       note-off at 3.030 s (tick 383). This matches the audio exactly. So the "re-strike" is just
       Keyscape's **normal release** on the old voice plus a new voice starting at the same instant,
       not a special re-strike mode. The 0.5 vs 0.3 plateau difference is likely masking or fit error
       from the new attack.
   - **Update 2026-11-03 (`Pattern 3.wav` + `untitled2.mid`):** one note, C4 velocity 64, note-on at
     0 s, note-off at 0.4054 s (148 BPM, ppq 96). Comparing its release with `Pattern 2_2.wav`'s
     release **revises the model above**. Keyscape's release is a **release sample**, not a gain envelope:
     - **Sustain voice:** fades in ~6–8 ms after note-off. Tone gain is 0.9 at 1 ms, 0.5 at 3 ms,
       0.3 at 5 ms and ~0.1 at 6 ms. The earlier "0.3 plateau" was the release sample's own tone.
     - **Release sample:** starts at note-off and lasts **~0.70–0.72 s**, then exact digital zero in
       both files. Its content:
       - 0–33 ms: the tine being damped, still tonal but **pitch-bending** (262 → ~285 → ~250 Hz).
         This can't come from a gain change on the sustain sample.
       - then a level cliff at ~34–36 ms
       - then a low-frequency mechanical thump (60–180 Hz), −35…−60 dB, until ~0.7 s
     - **Same release audio in both recordings:** tail correlation 0.53–0.80, damping section 0.69.
     - **Same absolute level in both** (within 1.5 dB), even though the notes had decayed differently
       (held 0.4 s vs 1.5 s). So the release level is fixed per velocity, not scaled to the current
       note level. It is not bit-identical: possibly round-robins or variation.
     - The P3 sustain differs from P2_2's first strike (correlation −0.43), so Keyscape probably uses
       round-robins on note-on too.
   - **Keyscape library structure** (from the user's local copy: `.zmap`/XML mapping files and FLAC
     STREAMINFO headers only; the audio frames are still encrypted and were not decoded):
     - **Main sound "Classic Rhodes":** 19 velocity layers, 1 round-robin, 24-bit mono, ~30 s per note
       for C4.
     - **"Release Combo"** (tonal damping release):
       - per note: 5 recorded velocities (43/68/96/118/127) × 4 round-robins, in two sets,
         `CLRRelMr3` (0.500 s) and `CLR RelF` (0.794 s)
       - spread over 10 velocity zones with per-zone trims of −6…+4 dB
       - C4 at velocity 64 → `CLRRelMr3_60-96` +3 dB
     - **"Mechanical Noise Release":** 3 velocity zones (≤57, 58–100, 101–127) × 4 round-robins,
       0.794 s, trims 0/−7/−7 dB. This is most likely the 60–180 Hz thump tail seen in the renders
       (which ends ~0.72 s after note-off).
     - So Keyscape's release = a tonal damping sample + a mechanical noise sample, each with 4
       round-robins, picked by velocity. Not yet known: note-on vs note-off velocity (both were 64
       in the test MIDI).
   - **Normal sustain fade with no release sample** (`Pattern 3_4.wav`, release off, transition mode off):
     - the fade begins ~2 ms after note-off + latency (~0.4100 s); gain is 0.77 at +1 ms, 0.54 at
       +2 ms, 0.30 at +3 ms, 0.05 at +5 ms, < 0.003 at +6 ms; digital zero at 0.418 s
     - **~6 ms fade**; the shape can't be told apart at this length (best fit: quadratic over 6.4 ms)
     - It matches the sustain drop seen in Pattern 3 *with* the release sample, so Keyscape's normal
       note-off is a ~6 ms fade whether or not a release sample plays.
   - **"Transition mode" fade** (`Pattern 3_3.wav`; the user had a Keyscape transition mode on, which
     lengthens the release; same
     148 BPM pattern, note-off at 0.4054 s; `untitled3.mid` was exported without note events):
     - fade starts at 0.4085 s (note-off + ~3 ms render latency) and reaches exact digital zero at 0.502 s
     - **gain = (1 − t/95 ms)^2.1**, within 0.2 dB; a plain square (1 − t/T)² is within 0.8 dB;
       linear is off by 8 dB and cosine by 11 dB
     - natural decay before note-off: −11.6 dB/s
     - The renders' sustains match each other at correlation 0.77 once shifted 3.5–4.3 ms (start-time
       jitter between renders, not different samples).
     - **Add-only hardware:** g = (1 − n/N)² has a constant second difference. On note-off: g = 1,
       d = 2/N − 1/N², c = 2/N², with N = 4190 samples (95 ms). Each sample: g -= d; d -= c; the voice
       is free when g ≤ 0. Two ~32-bit values per voice in the context RAM; no multiplier.
   - **Plan (revised):**
     - **Now (no release samples):** note-off starts a **~6 ms fade** (normal Keyscape). The same add-only
       quadratic generator works with N ≈ 280 samples. Optionally offer N = 4190 (95 ms) as a
       "transition mode" setting.
     - **Later (with release samples):** note-off fades the voice in ~6–8 ms and **starts that key's
       release sample** (~0.5–0.8 s, fixed level per velocity) on its own voice.
     - **Re-strike:** the same thing, plus the new note's voice. So re-strikes and releases both need
       spare voices: release voices last ~0.7 s, though most of that is quiet.
     - **Getting release samples:** they can be **extracted** from renders like these. Hold a note,
       release it, take the audio from note-off on, and subtract the extrapolated sustain fading over
       the first ~8 ms. After ~8 ms the audio is the pure release sample.

     On a re-strike, the old voice moves to a fade-out slot and gets the damp event, while the key's
     main voice restarts. 8 fade-out slots → 96 voice slots. Release samples, if added later, play
     alongside this.

8. **Velocity gain curve — done 2026-11-11** (`make_velocity_table.py`, from the full 8-layer
   library, no renders):
   - Loudness = RMS of the first 200 ms after onset. v096, v112 and v127 are the **same recording**
     (correlation 1.0000, 0.0 dB), so Keyscape is flat from v096 up.
   - Per key: target level interpolated in dB between the 8 measured velocities (slope 16→32
     continued below v016). Layer = nearest kept layer (ties down); gain = target − layer level;
     if that is > +6 dB (some keys jump 10–13 dB between recorded layers) the next layer up is
     used with attenuation. Gains −15…+6 dB.
   - `tables/velocity_layer.mem`: 11264 × 16 bit, address key·128 + velocity; bits 10:8 layer
     0..4, bits 7:0 gain code (same 0.5 dB / +6 dB format as release_gain.mem, 255 = mute for
     velocity 0). Release gain at note-off: code = vel_code + hold_code − 12 → one db_to_lin lookup.
   - Also `release_extract/velocity_table.{json,csv}` and sweeps (v8…v127) in
     `release_extract/preview_velocity/`.
9. **Sustain pedal sounds:** nice to have, **not a requirement** (user, 2026-11-11).
10. **Long-note endings:** library files stop at their end with a 4 ms fade. Most end at −55…−60
   dBFS, but bass keys G#1–D2 (v048–v112) end at **−34…−39 dBFS rms**, an audible cut if held
   ~20 s. Preview: `release_extract/preview_ends/bass_endings_asis_then_1p5s_fade_+18dB.wav`
   (as-is, then with a 1.5 s fade baked in; +18 dB to hear it). Proposed fix: the packer bakes a
   longer fade into the last 1–2 s of loud-ending files (source library untouched). Waiting on
   the user's listen.
   - **User 2026-11-11:** the 4 ms cut is fine (Keyscape does the same). Open question: does
     Keyscape play a release at the end of a long sustain? Check with the null test:
     `keyscape_release_sampler_longhold.mid` (`make_release_midi.py --long-hold`; D#1, G#1–D2 ×
     v080/v112 × holds 16, 20 … 40 s at 120 BPM = 13.0, 16.2, 19.5, 22.7, 25.9, 29.2, 32.4 s at 148;
     98 slots, 48.7 min at 120 BPM / ~39.5 min at 148). Sample ends: v080 22.1–24.0 s, v112
     25.1–27.2 s. Render release ON and OFF at 148 BPM.
   - **Result (2026-11-11, renders `keyscape_release_sampler_longhold_{with,without}_release_render.wav`,
     measurements `release_extract/longhold_measurements.json`):**
     - **No release after long holds:** null residual −89…−102 dBFS at 13.0 s (≈ 1 LSB) and exactly
       zero from 16.2 s on, on all 14 key/velocity pairs. Matches the gain table (muted after
       12.97 s); nothing to add.
     - **Keyscape does not stop the note where our files end:** the held note keeps decaying
       smoothly (no jump) to −46…−54 dBFS at 32.4 s. Our files are shorter because
       make_sampler_midi.py's hold (30 s lowest key at max velocity, less for softer/higher)
       plus slice_to_pcm's −50 dB-below-peak trim set their length, not Keyscape.
     - Options: bake a 1–2 s fade-out into the loud-ending files (free), or append the missing
       tail from this render (~46 files ≥ −45 dBFS at their end; several MB, does not fit in the
       0.33 MiB left).
     - **Decided (user, 2026-11-11): keep the files as they are** — the existing 4 ms end fade is
       fine and a shorter note than Keyscape's is acceptable. No end fade-out in the packer.
       Item 10 is closed.
11. **Clicks at note start:** 188 of the 440 kept sustains start mid-waveform (first sample up to
   4586, e.g. D#6 v080), so the voice jumps from 0 = click. Fix: the packer bakes a 1 ms
   (44-sample) sin² fade-in into the flash copy (source untouched). The velocity previews also
   had a hard cut at 0.7 s; they now use the player's note-off fade.
   - Measured 2026-11-11 against the release renders: the slicer cut at the MIDI note-on time,
     so these files miss the first **~1.5 ms (median), up to ~2.3 ms** of the attack. Splicing it
     back from the release renders does not work (library vs render match only −31 dB median over
     the first 100 ms: different key-noise round-robin).
   - User offered to re-bounce. **`make_rebounce_midi.py`** → `keyscape_rebounce_sustains.mid` +
     manifest: 5 kept layers, 440 notes, each held for its old file length + 0.6 s (timed for a
     148 BPM project), 78.9 min. Plan for the chop: cut at the detected onset minus a pre-roll
     (start in silence), cut to the old file length with the same 4 ms end fade (same flash size),
     write to a NEW folder (original library untouched), then re-run make_velocity_table.py
     (gains vs the new files' levels). Releases stay valid (standalone).
   - **Re-bounce done 2026-11-11** (`keyscape_rebounce_sustains_without_release_sample.wav`, 148 BPM):
     `venv/bin/python chop_rebounce.py keyscape_rebounce_sustains_without_release_sample.wav
     --tempo-actual 148` → **`16bit_44.1kHz_Mono_Left_Only/samples_rebounce/`** (440 files, same
     names and lengths as the old ones, + index.json). Cut 1 ms (44 samples) before the first
     non-zero sample (render is digital silence between notes), 4 ms linear end fade. Result:
     0 problems, **all 440 start at 0** (old: 188 didn't), full attack build-up present, body level
     vs old take +0.00 dB median (−0.10…+0.22). Compressed 64.34 MB (old 64.28) → with releases
     **~63.73 MiB of 64 MiB, ~0.27 MiB free**. No fade-in needed.
     - **Re-cut 2026-11-11 with 103 samples (2.34 ms) of silence** before the first non-zero
       sample, to match the user's `test sample.wav` render; files are the old length + 59
       samples (note keeps its full length). Compressed 64.36 MB → with releases **66.84 MB =
       63.74 MiB of 64 MiB (99.6%), ~0.26 MiB free**.
   - make_velocity_table.py now takes the layer levels from `samples_rebounce` (`--kept-library`);
     the 8-layer target curve still comes from the original library. Re-run done.
   - **Image v4 built and verified 2026-11-11:** `flash_image.bin` = 880 entries (440 re-bounced
     sustains + 440 releases, sorted by note/velocity, release base 440 in word 7), 33,421,373
     words = 66,842,746 bytes = **63.75 MiB, 99.60% of the chip, 259.9 KB free**; ratio 5.84:1;
     **verify PASS bit-exact** on all 880. Log: `pack_log.txt`. Old image: `flash_image_v3_old.*`.
     The RTL vector generator (`tb/gen_lpc_rice_vectors.py`) reads the new image by file name;
     vectors not regenerated yet.
   - **The packer must use `samples_rebounce/` for the sustains.** The original `samples/` stays as
     the untouched source (and the only copy of v032/v096/v127).

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
| 6 (left, WRIO) | 28 | 3.3 V | Key matrix: ROW_N[14:0] (out, one low at a time), COL_M1_N[5:0], COL_M2_N[5:0] (in, pulled up) | 27 |
| 7 (left, WRIO) | 22 | 3.3 V | PSWI, PSWO, Headphone_in, MIDI UART TX, power LED, sustain pedal, reset | 7 |
| 2 (right, WRIO) | 28 | 3.3 V | spare | 0 |
| 1 (right, WRIO) | 21 | 3.3 V | JTAG (+ hard I2C if the DAC needs control) | 4 |
| 0 (top, WRIO) | 12 | 3.3 V | Config SPI flash, PROGRAMN/INITN/DONE | ~10 |
| ADC (dedicated) | — | 1.8 V ext. ref | Master volume pot: wiper → ADC_DP0, ADC_DN0 → GND, ADC_REFP0 = 1.8 V ref | — |

Parallel flash runs with V_IO = 1.8 V (HPIO banks can't exceed 1.8 V). If it is only ever programmed
off-board, WE#/WP#/BYTE#/RY-BY# can be strapped on the PCB to free 4 pins.

### Key matrix (88 keys, dual-contact velocity)
- 15 rows × 6 columns × 2 contact sets (M1/M2) = 180 contacts, 3.3 V, no level shifting.
- **Confirmed by the user 2026-11-12: the FPGA drives the 15 ROW_N lines (one low at a time) and reads
  the 6+6 COL lines** (COL_M1_N / COL_M2_N inputs, LVCMOS33, **external 4.7–10 kΩ pull-ups to 3.3 V**).
- Slot = row·6 + column index; A0 is row 0, **column index 2 (the 3rd column)**, C8 row 14 col 5
  (only that start gives 88 keys). `FIRST_KEY_SLOT` parameter in scan_keys_controller.v.
- Scan at 24 MHz (changed 2026-11-14): 96-clock (4 µs) row settle + 6 column reads → one full pass
  = 64.375 µs = the velocity timing resolution.

### Other I/O notes
- Power LED on 3.3 V bank (red LED Vf ≈ 1.8–2 V won't light from 1.8 V).
- Sustain pedal: pull-up, debounce in logic, ESD protection on the jack.
- PSWO (soft-power hold) needs a pull resistor so it's in a safe state before configuration completes.
- **MIDI OUT** (corrected 2026-11-12: there is no MIDI in): UART **TX** at 31,250 baud, channel 1,
  note-off sent as note-on velocity 0 with running status, sustain pedal = CC64, volume pot = CC7.
- User reset is a GPIO; PROGRAMN reconfigures the FPGA (not a logic reset).
- The ADC clock is hardwired to the lower-right PLL CLKOS4, so that PLL must be used.

## Clocks / oscillators to buy (decided 2026-11-12)

| # | Frequency | Feeds | Spec |
|---|---|---|---|
| OSC1 | **45.1584 MHz** | audio domain directly: voice engine, flash, mixer, I2S (MCLK = /4 = 11.2896 MHz, BCLK = /16 = 2.8224 MHz, LRCLK = 44.1 kHz) | CMOS (LVCMOS) output, ±50 ppm or better, low jitter (audio grade). Output voltage = VCCIO of the bank its pin is on (1.8 V on bank 3/4/5, 3.3 V on a WRIO bank) |
| OSC2 | **24.000 MHz** (changed from 12 MHz 2026-11-14: the PLL input minimum is 18 MHz) | control domain: key scan, velocity timer (24 clocks = 1 µs), debounce, MIDI out (24 MHz / 31,250 = 768 exactly), ADC fab_clk_i; also the reference of the lower-right PLL that makes the ADC clock | CMOS, 3.3 V (or match its bank), ±50 ppm |

- Both must land on **clock-capable pins** (PCLK / PLL reference inputs) — check the LFD2NX-28 caBGA256
  pinout in Radiant before the PCB is fixed.
- Alternative for OSC1: **22.5792 MHz** (more common) × 2 in a PLL = 45.1584 MHz. Using 45.1584 MHz
  directly keeps PLL jitter out of the I2S clocks, so it is the first choice.
- **PLL (Radiant IP `pll0`, lower-right PLL, generated by the user 2026-11-14):** clki_i = CLK_CTRL
  24 MHz, rstn_i = ~RST; **CLKOS4 = 24 MHz → ADC adc_clk_i** (ADC divide 1; 25 MHz was rejected as
  exactly at the limit); CLKOP = 50 MHz, unused; lock_o holds the ADC controller in reset
  (`rst_adc`). The control logic runs on the oscillator pin itself. `tb/models/pll0.v` = sim model.
- A programmable oscillator family (any frequency, 1.8/2.5/3.3 V) covers both if a fixed part is hard to find.

## Front end RTL (done 2026-11-12) — `RTL/CPLD_P45_I2S_AUDIO_GENERATOR`

```
 CLK_CTRL 24 MHz                                                         │ CLK_AUDIO 45.1584 MHz
 ROW_N/COL ─► scan_keys_controller ─► key_event_gen ──┐                   │
              (key 0..87, {M2,M1})    (µs timer,      ├► event_merge ─┬─► async_fifo ─┼─► (voice_manager; now EVT_* debug pins)
 SUS_PEDAL ─► debounce (5 ms) ─► CC64 ───────────────┘               └─► midi_tx ─► MIDI_TX
 FUNC_BTN  ─► debounce (synchronized, unused)
```
- **Event word (16 bit):** `[15:14]` 00 note-off / 01 note-on / 10 controller; `[13:7]` key 0..87
  (MIDI note = key + 21) or CC number; `[6:0]` velocity / value.
- **key_event_gen:** per-key RAM {note_on, timing, M2/M1 prev, t_start (17-bit µs)}. M1 closes → start
  timing; M2 closes → note-on with velocity = curve(M1→M2 time); M1 and M2 in the same pass → 127;
  M2 after the 100 ms timeout → 1; M1 opens → note-off.
- **Velocity curve:** `src/Key_Events/velocity_curve.mem` (512 × 7 bit, log-time index, 16 steps per
  doubling) from `tools/make_velocity_curve.py --fast-ms --slow-ms --gamma`. **Current values are
  placeholders (127 at ≤ 1.5 ms, 1 at ≥ 60 ms) until the user measures the P45 action.**
- **MIDI out:** sync FIFO (64 events) → 9n kk vv / Bn cc vv, running status, status resent after 300 ms idle.
- **Removed:** Velocity/ (velocity_timer_controller, velocity_calc, key_event_detect, ms_tick_gen,
  velocity_addr_gen; `git rm`, restorable) and the pressed_keys/velocity RAMs.
- **Tests:** `tb/run_tests.sh` — async_fifo (12 → 45 MHz, fills and recovers), midi_tx (bytes, running
  status, resend), front end (matrix model: 18 events incl. chord, fast/slow/timeout, pedal bounce;
  MIDI out decoded and matched). All PASS. yosys synth_nexus: ~340 LUT4, ~290 FF, 1 EBR.
- **Open:** pedal polarity (`PEDAL_ACTIVE_LOW` in the top, default active low) and PSWO polarity
  (tied 1 = "keep power on" as a placeholder) need the user's measurements; CC7 waits for the ADC.

### Measuring the key action (for the velocity curve) — Analog Discovery
- P45 key bed disconnected from its original controller and unpowered.
- Pick one key: tie its **row** line to GND; pull its **M1 column** and **M2 column** lines up to 3.3 V
  (AD supply V+) through **~10 kΩ resistors each** — never 3.3 V straight onto a column: pressing the
  key would short the supply to the grounded row.
- Scope CH1 = M1 column, CH2 = M2 column; trigger on CH1 falling edge, single shot.
- M1→M2 time = CH1 fall to CH2 fall. Record ~10 of the hardest strikes and ~10 of the softest that
  still sound, plus a few medium. If nothing falls, the matrix diodes face the other way: swap
  (pull the row up, ground through the column) and tell me.
- Sustain pedal: meter across the jack contacts, pressed vs released (open or closed when pressed).

## Audio engine — voice manager + flash boot (2026-11-12)
- **Voices: 208 slots, chosen by the user** (over an 88-voice pool): 2 sustain slots per key
  (key*2+p, ping-pong so a re-struck key's old note fades while the new one starts) + a ring of 32
  release voices (dense jazz test peak: 16 sustains + 16 releases). No stealing; only active voices
  cost decode time.
- `src/Flash/flash_reader.v` (async NOR read, ACCESS_CLKS=6 = 133 ns at 45.1584 MHz, 1 recovery clock),
  `src/Flash/flash_boot.v` (header check magic/version 4, file table → 1024×49-bit RAM, ~1 ms boot),
  `src/Voice/voice_manager.v` (events → voice RAM records {active, gen, fading, file, gain Q2.14};
  velocity_layer / release_gain / db_to_lin ROMs; pedal; re-strike = off+on).
- Tests: `tb/flash_boot_tb.sv` (real image header/table, 100 ns tACC model; PASS, and FAILS with
  ACCESS_CLKS=4 as it should), `tb/voice_manager_tb.sv` vs `tools/voice_manager_ref.py` (707 events,
  991 voice-RAM writes bit-exact; all hold slots, mute, pedal releases, re-strikes, ring wraps 9×).
- `render_midi.py` hold-code math changed to the same integer formula (previews = hardware).
- **Voice engine done 2026-11-12** (`src/Voice/voice_engine.v`, `i2s_tx.v`, `audio_core.v` = whole audio domain):
  - Sequencer: every 1024 clocks walks 208 slots (idle 1 clock; active: load context + voice record,
    decode ONE sample with lpc_rice_decoder's logic on per-voice state from a 189-bit context RAM,
    store); restart on a new gen (file table lookup); fade.mem while fading; voice stops at file end
    or fade end.
  - Refill: 64-word buffer per voice (16384×16 RAM), 16-word flash bursts when ≥ 16 free;
    restart resets the buffer to the file start. Write-first bypass on the buffer RAM.
  - Mixer: y = ((s·gain) >>> 14)·fade >>> 15, summed, saturated to 16 bit (MIX_SHIFT = 0).
  - I2S: MCLK clk/4, BCLK clk/16, LRCLK clk/1024, Philips format, 16-bit in 32-bit slots, L = R.
  - Tests (`tb/audio_core_tb.sv` + `tools/engine_ref.py`): real flash image, every decoded sample vs the
    library files, gains, fade steps, mix and I2S frames bit-exact; normal 0.6 s performance PASS;
    **stress** (pedal + all 88 keys at v127 + 32 re-strikes: 152 voices at once) PASS, longest walk
    **830 / 1024 clocks**, no underrun/overrun. `tb/run_tests.sh --stress` runs all 7 tests (~25 s).
  - yosys synth_nexus (whole chip): ~11k LUT4 + 1.7k WIDEFN9, 5.1k FF, **42 of 58 EBR**, 3 multipliers,
    LRAM unused. (Lesson: a RAM written inside an async-reset always block becomes flip-flops —
    flash_boot's table RAM did, 50k FFs, fixed.)
  - Open: master volume (ADC) + limiter before I2S; the 88-keys-at-v127 stress clips (peak 32768);
    208 slots all active would exceed 1024 clocks (~5 per voice) — not reachable in practice.
- **Master volume pot done 2026-11-14** (user instantiated the Radiant ADC IP as `master_volume_pot`):
  - `src/Inputs/adc_ctrl.v` on CLK_CTRL (= fab_clk_i, 24 MHz since 2026-11-14): reset → enable → 64 clocks →
    adc_cal_i = 1 → calrdy → per 1 ms: SOC until COG, EOC → sample, ≥ 8 clocks after COG falls
    before the next SOC, 100 µs EOC timeout (FPGA-TN-02129 Fig. 3.7, §3.7.1, §3.7.5). Channel 0xB
    (ADC_DP0/DN0), unipolar, straight binary. 16-sample average, 40-code hysteresis, top 7 bits =
    **CC7**, sent on change and once at power-up → event_merge (2nd CC input) → MIDI out + async
    FIFO → voice_manager.volume → `src/Voice/volume_curve.mem` (tools/make_volume_curve.py:
    0 = mute, 1..127 = −60..0 dB) → gain ramp 32/sample (Q2.14) → applied to the mix before the
    16-bit saturation (voice_engine Q_FIN3/4).
  - **Radiant IP settings to use:** ADC clock divide so adc_clk_i/div ≤ 25 MHz; straight binary;
    ADC0 external reference 1.8 V; unipolar. **adc_clk_i = lower-right PLL CLKOS4, 24 MHz**
    (wired 2026-11-14, ADC divide 1). ADC_DP0/ADC_DN0 are top
    ports; ADC1 pins left open.
  - `tb/models/master_volume_pot.v` = simulation model of the IP (with protocol checks);
    `tb/adc_ctrl_tb.sv` PASS (200 conversions, no violations, CC7 on moves, none for noise).
    Front-end test now expects the power-up CC7; audio_core test checks mix × master gain and the
    ramp (CC7 100/127/64/0/127). All 8 tests PASS.
- **Pedal-up plays the releases** (user confirmed 2026-11-12: Keyscape does too), each scaled by the
  hold table for the time since its note-on. The engine already does this. (`make_release_midi.py
  --pedal-test` remains for a null test if ever needed; its MIDI was not rendered.)

## 88-voice top-level plan (discussed 2026-11-02, not yet coded)

### Decisions
| Topic | Decision |
|---|---|
| Device | LFD2NX-28 (project files stay MachXO3D until Radiant is installed) |
| Clock | **Decided 2026-11-12: two oscillators, two clock domains** (see "Clocks / oscillators to buy"): 45.1584 MHz audio (1024 clocks per 44.1 kHz sample, MCLK = clk/4 = 11.2896 MHz) and 24.000 MHz control (was 12 MHz until 2026-11-14). Events cross through an async FIFO |
| Voices | One voice per key (voice = key 0–87); no voice stealing |
| Re-strike | Match Keyscape (analysed 2026-11-03): new note starts at once; note-off fades the sustain voice in ~6–8 ms and starts a ~0.7 s release sample; the re-strike adds the new voice on top. Needs spare voices for release samples (see open item 7) |
| Key release | Envelope fade for now (length/curve TBD, ~100–300 ms); real release samples later |
| Velocity | 5 layers (v016/048/064/080/112) **plus a gain curve inside each layer** so all 127 velocities step smoothly |
| Output | 16-bit PCM I2S, same signal on left and right |
| File index | **Done (v4):** `idx = key*5 + layer`; release = idx + 440 (header word 7) |

### Block diagram
```
 KEYS ─► scan_keys_controller ─► velocity_timer_controller ─┐ (existing modules)
 SUS_PEDAL ─► debounce ──────────────────────────────────────┤
                                                             ▼
                                   event_fifo ─► voice_manager ◄─ file_table_ram (440×48 b, loaded from flash at boot)
                                                     │ key→voice, velocity→layer+gain, start/release
                 ┌───────────────────────────────────▼──────────────────────────────┐
  PARALLEL ◄──►  │ flash_ctrl ◄─ refill_scheduler ◄─ FIFO fill levels               │
  NOR FLASH      │     ▼                                                            │
                 │ prefetch_fifo_ram (88 × 256 words, LRAM, 360 kb)                 │
                 │     ▼                                                            │
                 │ voice_sequencer ─► context_ram (88 × ~200 b, EBR) load/store     │
                 │     ▼                                                            │
                 │ lpc_rice_decoder_core (state external) ─► gain_env (1 DSP mult)  │
                 │     ▼                                                            │
                 │ mix_accumulator (24–28 bit)                                      │
                 └─────┬────────────────────────────────────────────────────────────┘
 ADC pot ─► master_volume (×) ─► limiter/soft clip ─► i2s_tx (16-bit, L=R) ─► DAC/amp
 PSWI/PSWO, ON_LED, Headphone_in ─► power_ctrl / misc_io
```

### Blocks
- **Existing scan + velocity:** emits key address + 7-bit velocity; needs a matrix-address → key 0–87 map and key-release events.
- **voice_manager:** on press: layer from velocity, idx = key*5+layer, read start addr/num_samples from file_table_ram, reset the voice context, set gain. On release (pedal up): start fade. Pedal release fades all non-held keys.
- **flash_ctrl / refill_scheduler:** serves the emptiest active voice FIFO with a burst; ~0.7 M words/s average, 4.1 M worst case; flash ~100 ns random read.
- **voice_sequencer:** each 1024-clock sample period, walk active voices: load context → decode one sample → gain → accumulate → store context. Voices go in order (not fixed slots) so a slow code borrows slack.
- **context_ram per voice:** flash address, samples_left, frame_left, words_left, k, order, warm_left, x1..x4, bitbuf(32), nbits, q_acc, state, envelope, gain (~200 b).
- **gain_env:** sample × (velocity fine gain × envelope), 16×18 multiply, one time-shared DSP (~3.9 M mult/s).
- **Budget per sample period:** 88 × ~4–5 clocks ≈ 350–450 of 1024 clocks; the rest is slack.
