#!/usr/bin/env python3
"""
make_sampler_midi.py
Generates a MIDI file for auto-sampling a Keyscape Rhodes patch, plus a
manifest.json describing exactly where every note lands in the bounced audio
(in samples @ the configured sample rate), so slice_to_pcm.py can cut the
bounce deterministically.

Usage examples:
    python3 make_sampler_midi.py                          # full library (defaults)
    python3 make_sampler_midi.py --quick                  # short test pass
    python3 make_sampler_midi.py --single-note            # one pitch class (C) across all octaves, full velocities/hold/tail -- for tuning slicer params without a full bounce
    python3 make_sampler_midi.py --single-note --note-class Fs
    python3 make_sampler_midi.py --note-step 2 --velocities 24,48,72,96,120
    python3 make_sampler_midi.py --lo 28 --hi 100 --hold-lo 14 --hold-hi 5

Notes:
  * MIDI 21 = A1, MIDI 108 = C8 -> the 88-key piano range.
  * Hold time is interpolated per note (low tines ring much longer).
  * Timing model per slot: [note-on] hold [note-off] tail [gap] ...
  * The bounce MUST start at time zero of the MIDI clip (drop the clip at 1.1.1
    and render from the very start).
"""

import argparse
import json
import math
import sys

import mido

SR = 44100            # target sample rate of your bounce
BITS = 16             # target bit depth of your bounce
CHANNELS = 1          # target channel count of your bounce (1=mono, 2=stereo) -- Rhodes source is mono
PPQ = 480             # ticks per quarter note
TEMPO_BPM = 120.0     # fixed tempo -> 1 beat = 0.5 s -> 960 ticks per second
TICKS_PER_SEC = PPQ * TEMPO_BPM / 60.0  # 960

NOTE_NAMES = ["C", "Cs", "D", "Ds", "E", "F", "Fs", "G", "Gs", "A", "As", "B"]


def note_name(n: int) -> str:
    # Convention: MIDI 60 = C4
    return f"{NOTE_NAMES[n % 12]}{n // 12 - 1}"


def sec_to_ticks(s: float) -> int:
    return int(round(s * TICKS_PER_SEC))


def sec_to_samples(s: float) -> int:
    return int(round(s * SR))


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--lo", type=int, default=21, help="lowest MIDI note (default 21 = A1)")
    ap.add_argument("--hi", type=int, default=108, help="highest MIDI note (default 108 = C8)")
    ap.add_argument("--note-step", type=int, default=1, help="semitone step between sampled notes")
    ap.add_argument("--velocities", type=str, default="16,32,48,64,80,96,112,127",
                    help="comma-separated velocity layers")
    ap.add_argument("--hold-lo", type=float, default=30.0,
                    help="hold time in seconds for the LOWEST note at max velocity")
    ap.add_argument("--hold-hi", type=float, default=12.0,
                    help="hold time in seconds for the HIGHEST note at max velocity")
    ap.add_argument("--vel-hold-min", type=float, default=0.55,
                    help="hold-time multiplier at velocity 1 (quiet notes decay to "
                         "the noise floor sooner; 1.0 disables velocity scaling)")
    ap.add_argument("--tail", type=float, default=3.0,
                    help="seconds recorded after note-off (release sample)")
    ap.add_argument("--gap", type=float, default=0.75,
                    help="seconds of silence between slots")
    ap.add_argument("--off-velocity", type=int, default=64,
                    help="note-off velocity (Keyscape largely ignores this; here for completeness)")
    ap.add_argument("--channels", type=int, default=CHANNELS, choices=(1, 2),
                    help="channel count of the bounce (1=mono, 2=stereo; default 1, since the "
                         "Rhodes source is mono)")
    ap.add_argument("--prefix", type=str, default="rhodes", help="filename prefix used by the slicer")
    ap.add_argument("--out", type=str, default="keyscape_rhodes_sampler",
                    help="output basename (writes <out>.mid and <out>_manifest.json)")
    ap.add_argument("--quick", action="store_true",
                    help="quick test: one note per octave, 4 velocities, short holds")
    ap.add_argument("--single-note", action="store_true",
                    help="param-tuning test: sample only one pitch class (--note-class) across "
                         "every octave in range, but keep full velocities/hold/tail so decay "
                         "behavior stays representative. Bounces much faster than the full library "
                         "since only ~7-8 notes are rendered instead of the whole keyboard.")
    ap.add_argument("--note-class", type=str, default="C",
                    help="pitch class used with --single-note, e.g. C, Cs, Fs, A (default C)")
    args = ap.parse_args()

    if args.quick:
        args.note_step = 12
        args.velocities = "32,64,96,127"
        args.hold_lo, args.hold_hi = 30.0, 12.0  # keep full decay even in quick mode
        args.tail = 2.0
        args.out = args.out + "_quicktest"

    velocities = sorted({max(1, min(127, int(v))) for v in args.velocities.split(",")})

    if args.single_note:
        cls = args.note_class.strip().capitalize()
        if cls not in NOTE_NAMES:
            sys.exit(f"--note-class {args.note_class!r} not recognized; use one of {NOTE_NAMES}")
        idx = NOTE_NAMES.index(cls)
        notes = [n for n in range(args.lo, args.hi + 1) if n % 12 == idx]
        if not notes:
            sys.exit(f"No {cls} notes fall within --lo {args.lo} / --hi {args.hi}.")
        args.out = args.out + f"_singlenote_{cls}"
    else:
        notes = list(range(args.lo, args.hi + 1, args.note_step))
        if notes[-1] != args.hi:
            notes.append(args.hi)  # always include the top note

    mid = mido.MidiFile(type=0, ticks_per_beat=PPQ)
    track = mido.MidiTrack()
    mid.tracks.append(track)
    track.append(mido.MetaMessage("set_tempo", tempo=mido.bpm2tempo(TEMPO_BPM), time=0))
    track.append(mido.MetaMessage("track_name", name="Keyscape auto-sampler", time=0))

    # Build absolute-time event list, then convert to delta times.
    events = []   # (abs_ticks, order, mido.Message)
    slots = []    # manifest entries
    t = 0.5       # small lead-in of silence before the first note (seconds)

    span = max(1, args.hi - args.lo)
    for n in notes:
        frac = (n - args.lo) / span
        note_hold = args.hold_lo + (args.hold_hi - args.hold_lo) * frac
        for v in velocities:
            vf = args.vel_hold_min + (1.0 - args.vel_hold_min) * (v / 127.0)
            hold = note_hold * vf
            on_s = t
            off_s = t + hold
            end_s = off_s + args.tail
            events.append((sec_to_ticks(on_s), 0,
                           mido.Message("note_on", note=n, velocity=v)))
            events.append((sec_to_ticks(off_s), 1,
                           mido.Message("note_off", note=n, velocity=args.off_velocity)))
            slots.append({
                "note": n,
                "name": note_name(n),
                "velocity": v,
                "on_sample": sec_to_samples(on_s),
                "off_sample": sec_to_samples(off_s),
                "end_sample": sec_to_samples(end_s),
            })
            t = end_s + args.gap

    events.sort(key=lambda e: (e[0], e[1]))
    prev = 0
    for abs_ticks, _, msg in events:
        msg.time = abs_ticks - prev
        track.append(msg)
        prev = abs_ticks
    track.append(mido.MetaMessage("end_of_track", time=sec_to_ticks(t + 1.0) - prev))

    midi_path = f"{args.out}.mid"
    manifest_path = f"{args.out}_manifest.json"
    mid.save(midi_path)

    manifest = {
        "sample_rate": SR,
        "bits_per_sample": BITS,
        "channels": args.channels,
        "prefix": args.prefix,
        "total_seconds": round(t + 1.0, 3),
        "note_count": len(notes),
        "velocity_layers": velocities,
        "slots": slots,
    }
    with open(manifest_path, "w") as f:
        json.dump(manifest, f, indent=1)

    total = t + 1.0
    bytes_per_frame = args.channels * (BITS // 8)
    chan_label = {1: "mono", 2: "stereo"}[args.channels]
    print(f"Wrote {midi_path} and {manifest_path}")
    print(f"{len(slots)} samples ({len(notes)} notes x {len(velocities)} velocities)")
    print(f"Bounce length needed: {total:.0f} s = {total/60:.1f} min "
          f"(~{total * SR * bytes_per_frame / 1e9:.2f} GB at {SR/1000:.1f}k/{BITS}-bit {chan_label})")


if __name__ == "__main__":
    main()
