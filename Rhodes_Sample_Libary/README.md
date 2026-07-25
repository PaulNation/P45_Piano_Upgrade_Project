# Rhodes Sample Library — workflow

Two scripts turn a Keyscape Rhodes patch into a set of sliced, per-note/velocity
samples: `make_sampler_midi.py` builds the MIDI clip to bounce, `slice_to_pcm.py`
cuts the resulting bounce into individual samples.

## 1. Generate the MIDI + manifest

```
python make_sampler_midi.py
```

Writes `keyscape_rhodes_sampler.mid` and `keyscape_rhodes_sampler_manifest.json`.
Each note/velocity combo becomes one timed slot in the manifest (in samples @ 48 kHz),
which `slice_to_pcm.py` later uses to cut the bounce.

Useful variants:

- `--quick` — one note per octave, 4 velocities, short holds. Good for a fast
  end-to-end sanity check of the whole pipeline.
- `--single-note` — samples just one pitch class (default `C`) across every
  octave, but keeps full velocities/hold/tail so decay behavior stays
  representative. Use this while tuning `slice_to_pcm.py` parameters (trim,
  fade, offset) so you don't have to bounce the entire 88-key library every
  time. Pick a different pitch class with `--note-class`, e.g. `--note-class Fs`.
- `--note-step`, `--velocities`, `--lo`/`--hi`, `--hold-lo`/`--hold-hi`, `--tail`,
  `--gap` — control note spacing, velocity layers, key range, and timing for a
  custom pass. Run `python make_sampler_midi.py -h` for the full list.

## 2. Bounce it

Drop the `.mid` clip at the very start of the timeline (1.1.1) on the Keyscape
track and render/bounce to **48 kHz / 24-bit / stereo WAV**. The bounce must
start at time zero — the manifest's sample positions assume no lead-in beyond
what's already baked into the MIDI.

## 3. Slice the bounce into samples

```
python slice_to_pcm.py bounce.wav keyscape_rhodes_sampler_manifest.json -o samples/ -w samples_wav/
```

This writes two output folders:

- `samples/` — headerless raw PCM (24-bit signed LE, stereo, 48 kHz), bit-perfect
  cuts from the bounce, plus an `index.json` describing every file.
- `samples_wav/` — the same slices wrapped in a standard WAV header, so you can
  drag them straight into a DAW to check the cuts by ear. Skip this folder with
  `--no-wav` if you only want the raw PCM.

By default only the **sustain** slice (`_sus.pcm`) is written per note/velocity.
Add `--with-release` if you also want the release tail (`_rel.pcm`) — that's not
needed yet.

Other options worth knowing:

- `--offset-ms N` — shift all cut points if the bounce doesn't start exactly at 0.
- `--trim-db -50` / `--no-trim` — trims trailing near-silence off each slice
  (default -50 dBFS); `--no-trim` keeps full slice lengths.
- `--fade-ms 4` — short fade-out at each slice end to avoid clicks (0 disables).
- `--tempo-actual T` — rescales manifest positions if the bounce rendered at a
  constant tempo other than 120 BPM.

Run `python slice_to_pcm.py -h` for the full list.

## 4. Find loop points and build the instrument

```
python rhodes_loop_tool.py analyse 16bit_44.1kHz_Mono_Left_Only/samples --raw-rate 44100
```

Dry run — measures f0, T60 (decay time), and touches nothing. Worth running
once on a new batch of slices before `process`, just to sanity-check the
numbers look like a Rhodes (T60 of tens of seconds on bass notes, a few
seconds up top).

```
python rhodes_loop_tool.py process 16bit_44.1kHz_Mono_Left_Only/samples sample_optimization \
    --raw-rate 44100 --format pcm --preview-dir sample_optimization_preview \
    --sfz rhodes_sample_optimization.sfz --report sample_optimization/report.json
```

For each sample, this finds a short loop point (a handful to a few dozen
pitch periods, cut precisely on matching zero crossings so it repeats with no
click and no crossfade needed) and writes two different things:

- **`sample_optimization/`** (the `OUT_DIR` argument) — the actual deployable
  files, cut short at `loop_end`. This is what a playback engine (or the
  FPGA) uses: it plays the file through once, then loops `loop_start:loop_end`
  and shapes the continuing decay itself. `--format pcm` writes headerless raw
  PCM (`--raw-bits` controls depth) for consumers that don't parse WAV/FLAC
  headers; use `flac`/`wav` instead if the consumer does.
- **`sample_optimization_preview/`** (`--preview-dir`, optional) — full-length
  "held note" renders for auditioning by ear: the same loop, duplicated out to
  the original recording's own duration with a volume ramp baked in, so it
  sounds like a complete note when played directly in a DAW or media player.
  Always written in a directly-playable format (`--preview-format`, default
  `wav`) regardless of `--format`, and only produced for samples that actually
  got a loop.
- **`rhodes_sample_optimization.sfz`** (`--sfz`) — documents every loop point
  (`loop_start`/`loop_end`/`ampeg_decay`) against the files in `OUT_DIR`, note
  by note. Also loadable directly in an SFZ-compatible sampler (sfizz, ARIA,
  etc.) if you want to audition through an actual engine instead of (or in
  addition to) the preview renders.
- **`report.json`** (`--report`, written inside `OUT_DIR` above) — the same
  per-file measurements as `analyse`, plus the loop points and output
  filenames, as JSON.

Samples that don't have enough content to find a good loop (very short/quiet
takes, usually the top register) come out as `NO LOOP` — kept as their full
natural recording in `OUT_DIR`, no loop opcodes in the SFZ.

Other options worth knowing:

- `--loop-start N` — earliest allowed loop point, seconds (default 1.0s).
  Lower this if a whole register is coming back `NO LOOP`.
- `--min-loop`/`--max-loop` — loop length search range, seconds (default
  5ms-300ms, i.e. a handful to a few dozen pitch periods).
- `--min-score` — reject loops below this correlation (default 0.5; in
  practice good loops score 0.99+).
- `--hold` — preview render length, seconds (default: match the original
  recording's own duration).

Run `python rhodes_loop_tool.py -h` for the full list.

## Fast iteration loop

While dialing in trim/fade/offset settings:

1. `python make_sampler_midi.py --single-note` (or `--quick`) for a short MIDI clip.
2. Bounce just that clip.
3. `python slice_to_pcm.py <bounce> <manifest> -o test_pcm/ -w test_wav/`
4. Listen to `test_wav/` in your DAW, adjust flags, repeat.

Once parameters look right, regenerate the full-range MIDI (no `--quick`/`--single-note`)
and redo the real bounce + slice.
