#!/usr/bin/env python3
"""
make_release_midi.py
Generates the MIDI clip for rendering Keyscape release samples, plus a manifest
describing where every note lands in the bounce, for extract_releases.py.

Every slot is: [note-on] hold [note-off] tail [gap]. Note-on AND note-off use the
library layer's velocity, so whichever one Keyscape uses to pick its release
sample, the release matches the library layer (v016/v048/v064/v080/v112).

Render settings: same Keyscape patch/settings as the sustain library, release ON,
transition mode OFF, effects off, 44.1 kHz. Drop the clip at 1.1.1 and bounce from
time zero.

Usage (from the Rhodes_Sample_Libary folder; files go to midi/):
    python3 scripts/make_release_midi.py              # full set: 88 keys x 5 layers
    python3 scripts/make_release_midi.py --check              # 5 keys x 1 layer, for a quick test
    python3 scripts/make_release_midi.py --velocities 16,48   # split the render into parts
    python3 scripts/make_release_midi.py --hold-sweep         # A0/C2/C4/C6 x v048/v112 released after
                                                      # 0.25..16 s, to measure how the release
                                                      # level follows the decaying note
    python3 scripts/make_release_midi.py --hold-sweep-wide    # every 4th key + C8 (23 keys) x v048/v112,
                                                      # same holds (<= 4 s from C6 up)
    python3 scripts/make_release_midi.py --pedal-test         # release on pedal-up? (null test)
    python3 scripts/make_release_midi.py --long-hold          # 7 bass keys x v080/v112 held 16..40 s,
                                                      # before and past the end of the samples
"""

import argparse
import json
import struct

SR = 44100
PPQ = 480
TEMPO_BPM = 120.0                       # 1 beat = 0.5 s -> 960 ticks per second
TICKS_PER_SEC = PPQ * TEMPO_BPM / 60.0
LIBRARY_VELOCITIES = "16,48,64,80,112"  # layers kept in the flash image
NOTE_NAMES = ["C", "Cs", "D", "Ds", "E", "F", "Fs", "G", "Gs", "A", "As", "B"]


def note_name(n: int) -> str:
    # Convention: MIDI 60 = C4 (same as make_sampler_midi.py)
    return f"{NOTE_NAMES[n % 12]}{n // 12 - 1}"


def sec_to_ticks(s: float) -> int:
    return int(round(s * TICKS_PER_SEC))


def vlq(v: int) -> bytes:
    out = [v & 0x7F]
    v >>= 7
    while v:
        out.append(0x80 | (v & 0x7F))
        v >>= 7
    return bytes(reversed(out))


def write_midi(path: str, events: list, end_tick: int) -> None:
    """events: (abs_tick, order, status, data1, data2), written as a type-0 file."""
    trk = bytearray()
    tempo = int(round(60e6 / TEMPO_BPM))
    trk += vlq(0) + b"\xff\x51\x03" + tempo.to_bytes(3, "big")
    name = b"Keyscape release sampler"
    trk += vlq(0) + b"\xff\x03" + vlq(len(name)) + name
    prev = 0
    for tick, _, st, d1, d2 in sorted(events):
        trk += vlq(tick - prev) + bytes((st, d1, d2))
        prev = tick
    trk += vlq(max(0, end_tick - prev)) + b"\xff\x2f\x00"
    with open(path, "wb") as f:
        f.write(b"MThd" + struct.pack(">IHHH", 6, 0, 1, PPQ))
        f.write(b"MTrk" + struct.pack(">I", len(trk)) + trk)


def main():
    ap = argparse.ArgumentParser(description="MIDI clip + manifest for rendering Keyscape release samples")
    ap.add_argument("--lo", type=int, default=21, help="lowest MIDI note (default 21 = A0)")
    ap.add_argument("--hi", type=int, default=108, help="highest MIDI note (default 108 = C8)")
    ap.add_argument("--velocities", default=LIBRARY_VELOCITIES,
                    help=f"comma-separated layers (default {LIBRARY_VELOCITIES})")
    ap.add_argument("--hold", type=float, default=1.0, help="seconds from note-on to note-off")
    ap.add_argument("--tail", type=float, default=1.5,
                    help="seconds recorded after note-off (Keyscape releases are <= 0.8 s)")
    ap.add_argument("--gap", type=float, default=0.3, help="extra silence between slots")
    ap.add_argument("--check", action="store_true",
                    help="quick test: keys A0, C2, C4, C6, C8 at velocity 64 only")
    ap.add_argument("--hold-sweep", action="store_true",
                    help="each of A0, C2, C4, C6 at v048/v112, released after 0.25/0.5/1/2/4/8/16 s")
    ap.add_argument("--hold-sweep-wide", action="store_true",
                    help="every 4th key from A0 plus C8 at v048/v112, same holds; keys from C6 up "
                         "stop at 4 s (silent by then)")
    ap.add_argument("--long-hold", action="store_true",
                    help="bass keys that end loudest (D#1, G#1-D2) at v080/v112, held 16, 20 ... 40 s "
                         "(13-32.4 s at 148 BPM), before and past the end of their samples, to "
                         "check for a release there")
    ap.add_argument("--pedal-test", action="store_true",
                    help="does Keyscape play release samples when the sustain pedal lifts? "
                         "C2/C4/C6 at v080: plain release, pedal-held single note, pedal-held chord, "
                         "pedal lifted while the key is still down; each at 1 s and 4 s")
    ap.add_argument("--out", default="midi/keyscape_release_sampler",
                    help="output basename (writes <out>.mid and <out>_manifest.json)")
    args = ap.parse_args()

    velocities = sorted({max(1, min(127, int(v))) for v in args.velocities.split(",")})
    notes = list(range(args.lo, args.hi + 1))
    if args.check:
        notes, velocities = [21, 36, 60, 84, 108], [64]
        args.out += "_check"

    holds = [args.hold]
    if args.hold_sweep:
        notes, velocities, holds = [21, 36, 60, 84], [48, 112], [0.25, 0.5, 1.0, 2.0, 4.0, 8.0, 16.0]
        args.out += "_holdsweep"

    sweep_holds = [0.25, 0.5, 1.0, 2.0, 4.0, 8.0, 16.0]
    combos = [(n, v, h) for n in notes for v in velocities for h in holds]
    if args.hold_sweep_wide:
        notes = list(range(21, 108, 4)) + [108]
        combos = [(n, v, h) for n in notes for v in (48, 112)
                  for h in sweep_holds if n < 84 or h <= 4.0]
        args.out += "_holdsweep_wide"

    if args.long_hold:
        combos = [(n, v, h) for n in (27, 32, 33, 34, 35, 36, 38) for v in (80, 112)
                  for h in (16.0, 20.0, 24.0, 28.0, 32.0, 36.0, 40.0)]
        args.out += "_longhold"

    if args.pedal_test:
        return pedal_test(args)

    events, slots = [], []
    t = 0.5                                  # lead-in of silence
    for n, v, hold in combos:
            on_s, off_s = t, t + hold
            end_s = off_s + args.tail
            events.append((sec_to_ticks(on_s), 1, 0x90, n, v))
            events.append((sec_to_ticks(off_s), 0, 0x80, n, v))   # note-off velocity = layer
            slots.append({"note": n, "name": note_name(n), "velocity": v, "hold_s": hold,
                          "on_sample": round(on_s * SR), "off_sample": round(off_s * SR),
                          "end_sample": round(end_s * SR)})
            t = end_s + args.gap

    total = t + 1.0
    write_midi(f"{args.out}.mid", events, sec_to_ticks(total))
    manifest = {"sample_rate": SR, "tempo_bpm": TEMPO_BPM, "hold_s": args.hold,
                "tail_s": args.tail, "velocity_layers": velocities,
                "total_seconds": round(total, 3), "slots": slots}
    with open(f"{args.out}_manifest.json", "w") as f:
        json.dump(manifest, f, indent=1)

    print(f"Wrote {args.out}.mid and {args.out}_manifest.json")
    print(f"{len(slots)} slots ({len(set(x['note'] for x in slots))} notes), "
          f"bounce length {total:.0f} s = {total / 60:.1f} min")


def pedal_test(args):
    """Each slot ends with the sound released at `off_s` (key-up or pedal-up), so the null
    test (release ON - OFF render) shows whether a release sample starts there.
      case plain      key down 0 .. hold, no pedal (reference: release plays)
      case pedal1     pedal down, key down 0 .. 0.3, pedal up at hold (one note)
      case chord      pedal down, 3 keys (n, n+4, n+7) down 0 .. 0.3, pedal up at hold
      case pedal_key  pedal down, key down 0 .. hold, pedal up at hold/2 (key still down:
                      the release comes from the key, not the pedal)"""
    events, slots = [], []
    t = 0.5
    for n in (36, 60, 84):
        for hold in (1.0, 4.0):
            for case in ("plain", "pedal1", "chord", "pedal_key"):
                v = 80
                keys = [n, n + 4, n + 7] if case == "chord" else [n]
                on_s, off_s = t + 0.2, t + 0.2 + hold
                if case != "plain":
                    events.append((sec_to_ticks(t), 2, 0xB0, 64, 127))          # pedal down
                for k in keys:
                    events.append((sec_to_ticks(on_s), 1, 0x90, k, v))
                key_up = on_s + (0.3 if case in ("pedal1", "chord") else hold)
                for k in keys:
                    events.append((sec_to_ticks(key_up), 0, 0x80, k, v))
                if case == "pedal_key":
                    events.append((sec_to_ticks(on_s + hold / 2), 2, 0xB0, 64, 0))
                elif case != "plain":
                    events.append((sec_to_ticks(off_s), 2, 0xB0, 64, 0))         # pedal up
                end_s = off_s + args.tail
                slots.append({"note": n, "name": note_name(n), "velocity": v, "hold_s": hold,
                              "case": case, "keys": keys,
                              "on_sample": round(on_s * SR), "off_sample": round(off_s * SR),
                              "end_sample": round(end_s * SR)})
                t = end_s + args.gap
    total = t + 1.0
    out = args.out + "_pedal"
    write_midi(f"{out}.mid", events, sec_to_ticks(total))
    with open(f"{out}_manifest.json", "w") as f:
        json.dump({"sample_rate": SR, "tempo_bpm": TEMPO_BPM, "tail_s": args.tail,
                   "total_seconds": round(total, 3), "slots": slots}, f, indent=1)
    print(f"Wrote {out}.mid and {out}_manifest.json: {len(slots)} slots, "
          f"{total:.0f} s = {total / 60:.1f} min at 120 BPM ({total * 120 / 148 / 60:.1f} min at 148)")


if __name__ == "__main__":
    main()
