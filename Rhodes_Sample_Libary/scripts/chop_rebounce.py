#!/usr/bin/env python3
"""
chop_rebounce.py
Cuts the sustain bounce (make_rebounce_midi.py) into the 440 library files with the
full attack: each file starts PREROLL samples (2.34 ms) before the first non-zero sample
of the note (the render is digital silence between notes), so it starts at 0 and nothing
of the strike is lost. Length = the original library length (manifest "old_samples") +
59 samples, with a 4 ms linear fade at the end.

Writes library/sustains/<name>_sus.pcm (raw int16 LE, mono) + library/sustains/index.json.

Usage (from the Rhodes_Sample_Libary folder):
    venv/bin/python scripts/chop_rebounce.py
  = renders/keyscape_rebounce_sustains.wav --manifest midi/keyscape_rebounce_sustains_manifest.json
    --tempo-actual 148 -o library/sustains
"""
import argparse
import json
import os
import sys

import numpy as np
import soundfile as sf

SR = 44100
PREROLL = 103                    # 2.34 ms of silence before the first sound (matches a reference
                                 # Keyscape render of a single note)
OLD_PREROLL = 44                 # length = original library length + (PREROLL - 44)
FADE = int(round(0.004 * SR))    # same end fade as slice_to_pcm.py (4 ms, linear)


def main() -> int:
    ap = argparse.ArgumentParser(description="Chop the sustain re-bounce into library files")
    ap.add_argument("bounce", nargs="?", default="renders/keyscape_rebounce_sustains.wav")
    ap.add_argument("--manifest", default="midi/keyscape_rebounce_sustains_manifest.json")
    ap.add_argument("--tempo-actual", type=float, default=148.0)
    ap.add_argument("-o", "--out", default="library/sustains")
    args = ap.parse_args()

    man = json.load(open(args.manifest))
    sc = man["tempo_bpm"] / args.tempo_actual
    x, fs = sf.read(args.bounce, dtype="int16", always_2d=True)
    x = x[:, 0]
    assert fs == SR
    os.makedirs(args.out, exist_ok=True)
    index, problems = [], []

    for s in man["slots"]:
        on = int(round(s["on_sample"] * sc))
        off = int(round(s["off_sample"] * sc))
        win = x[max(0, on - int(0.1 * SR)):on + int(0.25 * SR)]
        nz = np.flatnonzero(win)
        if not nz.size:
            problems.append(f"{s['old_file']}: no sound near note-on")
            continue
        first = max(0, on - int(0.1 * SR)) + int(nz[0])
        start = first - PREROLL
        n = s["old_samples"] + PREROLL - OLD_PREROLL
        if np.any(x[start:first]) or start + n > off:
            problems.append(f"{s['old_file']}: pre-roll not silent or note-off before the end")
        y = x[start:start + n].astype(np.float64)
        y[-FADE:] *= 1.0 - np.arange(1, FADE + 1) / FADE
        pcm = np.round(y).astype("<i2")
        pcm.tofile(os.path.join(args.out, s["old_file"]))
        index.append({"file": s["old_file"], "note": s["note"], "velocity": s["velocity"], "samples": n,
                      "latency_ms": round((first - on) / SR * 1000, 2), "first_sample": int(pcm[0])})

    json.dump({"sample_rate": SR, "preroll_samples": PREROLL, "end_fade_samples": FADE,
               "source": os.path.basename(args.bounce), "files": index, "problems": problems},
              open(os.path.join(args.out, "index.json"), "w"), indent=1)
    lat = np.array([i["latency_ms"] for i in index])
    print(f"wrote {len(index)} files to {args.out}; problems: {len(problems)}")
    for p in problems[:10]:
        print("  " + p)
    print(f"files whose first sample is not 0: {sum(i['first_sample'] != 0 for i in index)}")
    print(f"sound starts {lat.min():.2f}..{lat.max():.2f} ms after the MIDI note-on (median {np.median(lat):.2f})")
    return 0


if __name__ == "__main__":
    sys.exit(main())
