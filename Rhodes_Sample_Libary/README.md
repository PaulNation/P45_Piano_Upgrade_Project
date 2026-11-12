# Rhodes Sample Library

Builds the Rhodes sample set for the P45 FPGA piano from Keyscape renders:

- **`flash_image.bin`**: everything that goes into the 64 MiB parallel NOR flash. It holds 440 sustains (88 keys × 5 velocity layers) plus 440 release samples, compressed losslessly with LPC + Golomb-Rice.
- **FPGA ROM tables**: release gain vs time held, velocity → layer + gain, dB → linear, and the note-off fade. They are written as `$readmemh` files to `../RTL/CPLD_P45_I2S_AUDIO_GENERATOR/src/Sample_Decoder/tables/`.

`NOTES.md` has the design history, the measurements and the reasoning behind every number used here. Its older entries use the folder names from before this layout.

## Folder layout

```
Rhodes_Sample_Libary/
├── README.md, NOTES.md
├── scripts/            all Python scripts (run them from this folder: venv/bin/python scripts/<x>.py)
├── midi/               MIDI clips to render in Keyscape + manifests (where each note is in the render)
├── renders/            the Keyscape bounces (git-ignored, ~1.4 GB)
├── library/
│   ├── sustains/       440 × rhodes_<Note>_n<MIDI>_v<vel>_sus.pcm   (raw int16 LE, mono, 44.1 kHz)
│   └── releases/       440 × rhodes_<Note>_n<MIDI>_v<vel>_rel.pcm
├── data/               measured tables (release gain, velocity, Keyscape level data)
├── previews/           listening WAVs (git-ignored, regenerate below)
├── flash_image.bin     the flash image   (+ flash_image.json: file name → word address, host-side only)
└── venv/               Python with numpy + soundfile
```

Layers kept in flash: **v016, v048, v064, v080, v112**. File order in the image: sustain index = (note − 21) × 5 + layer, and the release is that index + 440.

## Quick rebuild (renders already in `renders/`)

Everything below runs with no arguments; the defaults point at the files in this layout. Total time is about 5 minutes.

```bash
cd Rhodes_Sample_Libary
venv/bin/python scripts/chop_rebounce.py            # renders → library/sustains
venv/bin/python scripts/extract_releases.py         # renders → library/releases
venv/bin/python scripts/make_release_gain_table.py  # renders → data/release_gain_table.json
venv/bin/python scripts/make_velocity_table.py      # data + sustains → velocity_layer.mem, previews/velocity
venv/bin/python scripts/make_fpga_tables.py         # → release_gain.mem, db_to_lin.mem, fade.mem
venv/bin/python scripts/lpc_rice_flash_packer.py --verify   # → flash_image.bin, bit-exact check
```

The scripts must run in this order, because each step reads the previous step's output.

## From scratch

### 0. Setup

```bash
python3 -m venv venv && venv/bin/pip install numpy soundfile
```

### Keyscape render settings (all renders)

- The same Rhodes patch for every render. Effects off, **transition mode OFF**, mechanical noise on.
- Project at **148 BPM**. The MIDI files are written at 120 BPM and the scripts scale the times by 120/148 (`--tempo-actual 148`, the default).
- Drop the clip at bar **1.1.1** and bounce **from time zero**.
- **44.1 kHz, 16-bit, mono** (or stereo; the left channel is used).
- "Release ON/OFF" means Keyscape's release-sample switch. The two renders of a pair must be identical in every other setting.

### 1. Sustains

```bash
venv/bin/python scripts/make_rebounce_midi.py        # → midi/keyscape_rebounce_sustains.mid (78.9 min)
```

Render it with **release OFF** and save as `renders/keyscape_rebounce_sustains.wav`. Then:

```bash
venv/bin/python scripts/chop_rebounce.py
```

- Each file starts **103 samples (2.34 ms)** before the first non-zero sample, so the whole attack is kept and every file starts at 0.
- Each file ends with a 4 ms fade.
- Note lengths come from `data/sustain_lengths.json`.
- When a held note reaches the end of its file, it stops with that 4 ms fade. That was decided by ear; Keyscape keeps ringing longer.

### 2. Releases

```bash
venv/bin/python scripts/make_release_midi.py         # → midi/keyscape_release_sampler.mid (each note held 1 s)
```

Render it twice, as `renders/keyscape_release_sampler_with_release.wav` (release ON) and `..._without_release.wav` (release OFF). Then:

```bash
venv/bin/python scripts/extract_releases.py
```

- **Release = (release-ON render) − (the sustain from `library/sustains` × the note-off fade)**, from note-off on.
- When the sustain file doesn't match the render to −35 dB, it falls back to ON − OFF.
- Every release is level-matched to its sustain.
- All 440 are kept, including the very quiet top keys.

### 3. Release gain vs time held

Keyscape plays the release quieter the longer the key was held.

```bash
venv/bin/python scripts/make_release_midi.py --hold-sweep-wide   # 23 keys × v048/v112 × 7 holds
```

Render it twice, as `renders/keyscape_release_sampler_holdsweep_wide_{with,without}_release.wav`. Then:

```bash
venv/bin/python scripts/make_release_gain_table.py   # --reuse: rebuild from data/holdsweep_wide_measurements.json
```

Writes `data/release_gain_table.{json,csv}`, the gain in dB for each of 88 keys × 5 layers × 8 hold times.

### 4. Velocity table

```bash
venv/bin/python scripts/make_velocity_table.py
```

- **Target curve:** each key's attack level at Keyscape's 8 velocity layers, saved in `data/velocity_levels_8layer.json`. Velocities between layers are interpolated in dB, and v096 through v127 are the same recording, so the curve is flat there.
- **Each velocity 1..127** plays the nearest kept layer plus a gain (−15 to +6 dB).
- **To measure the target curve again from Keyscape:**
  1. Run `scripts/make_release_midi.py --velocities 16,32,48,64,80,96,112,127 --out midi/keyscape_velocity_levels`.
  2. Render it with release OFF as `renders/keyscape_velocity_levels.wav`.
  3. Run `scripts/make_velocity_table.py --measure renders/keyscape_velocity_levels.wav`.

### 5. FPGA tables

```bash
venv/bin/python scripts/make_fpga_tables.py
```

Writes to `../RTL/CPLD_P45_I2S_AUDIO_GENERATOR/src/Sample_Decoder/tables/`:

| File | Size | Contents |
|---|---|---|
| `release_gain.mem` | 3520 × 8 bit | release gain code. Address ((key·5)+layer)·8+slot. Slot k = held 2^(13+k) samples. Code = (6 − dB)·2, 255 = mute |
| `velocity_layer.mem` | 11264 × 16 bit | address key·128+velocity. Bits 10:8 = layer 0..4, bits 7:0 = gain code (same format) |
| `db_to_lin.mem` | 256 × 16 bit | gain code → linear, Q2.14 |
| `fade.mem` | 512 × 16 bit | sustain gain after note-off, per sample, Q1.15 (9 ms) |

At note-off, the release gain code is velocity code + hold code − 12, followed by one `db_to_lin` lookup.

### 6. Flash image

```bash
venv/bin/python scripts/lpc_rice_flash_packer.py --verify
```

- Packs `library/sustains` + `library/releases` into `flash_image.bin`. Words are 16-bit and little-endian; use `--big-endian` to flip that.
- `--verify` decodes every file back out of the image and compares it bit-exact.
- The image format (version 4) is described at the top of `scripts/lpc_rice_flash_packer.py` and in `NOTES.md`.
- Current size: **63.75 MiB of 64 MiB (99.6%)**.

## Listening previews

These go in `previews/`, which is git-ignored. They are rebuilt any time with:

```bash
venv/bin/python scripts/make_velocity_table.py                       # previews/velocity/: v8, v16 … v127 per key
venv/bin/python scripts/make_release_preview.py                      # previews/ab_keyscape/: Keyscape vs rebuilt (A/B)
venv/bin/python scripts/make_release_preview.py --holds 0.5,1.5,3,6  # previews/holds/: release after each hold time
venv/bin/python scripts/make_release_preview.py --ends               # previews/ends/: loudest file endings, +18 dB
venv/bin/python scripts/render_midi.py "midi/Test midi.mid" --gain-db -1   # previews/midi/: any MIDI file through the engine model
```

`render_midi.py` plays a MIDI file the way the FPGA engine is planned to:

- velocity → layer + gain;
- re-strike = note-off + note-on;
- at note-off, a 9 ms fade plus the release sample scaled by the time held;
- sustain pedal defers note-offs.

It uses only the library files and the FPGA `.mem` tables. The output is 16-bit stereo with the same signal on both channels. The script prints the mix peak; use `--gain-db` if anything clips.

Options: `--notes 21,36,60` and `--velocities 48,112` choose what the release previews play. `make_velocity_table.py --preview-notes 28,45,60` does the same for the velocity sweeps.

## Extra checks (not part of the build)

- **Long holds:** `make_release_midi.py --long-hold` (7 bass keys held 13–32 s), rendered with release ON and OFF (`renders/keyscape_release_sampler_longhold_*`).
  - Keyscape plays no release after about 13 s.
  - Results are in `data/longhold_measurements.json`.
- **`data/keyscape_release_map.json`:** Keyscape's release zones per key and layer, read from the patch's mapping metadata. Kept for reference only.

## Renders

| File | MIDI | Release | Used by |
|---|---|---|---|
| `keyscape_rebounce_sustains.wav` | `keyscape_rebounce_sustains.mid` | OFF | `chop_rebounce.py` |
| `keyscape_release_sampler_with_release.wav` | `keyscape_release_sampler.mid` | ON | `extract_releases.py`, previews |
| `keyscape_release_sampler_without_release.wav` | `keyscape_release_sampler.mid` | OFF | `extract_releases.py` |
| `keyscape_release_sampler_holdsweep_wide_with_release.wav` | `..._holdsweep_wide.mid` | ON | `make_release_gain_table.py` |
| `keyscape_release_sampler_holdsweep_wide_without_release.wav` | `..._holdsweep_wide.mid` | OFF | `make_release_gain_table.py` |
| `keyscape_release_sampler_longhold_{with,without}_release.wav` | `..._longhold.mid` | ON / OFF | long-hold check only |

All renders are at 148 BPM.
