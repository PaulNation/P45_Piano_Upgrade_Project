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

## Fast iteration loop

While dialing in trim/fade/offset settings:

1. `python make_sampler_midi.py --single-note` (or `--quick`) for a short MIDI clip.
2. Bounce just that clip.
3. `python slice_to_pcm.py <bounce> <manifest> -o test_pcm/ -w test_wav/`
4. Listen to `test_wav/` in your DAW, adjust flags, repeat.

Once parameters look right, regenerate the full-range MIDI (no `--quick`/`--single-note`)
and redo the real bounce + slice.
