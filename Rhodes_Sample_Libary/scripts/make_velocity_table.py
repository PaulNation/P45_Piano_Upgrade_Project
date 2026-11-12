#!/usr/bin/env python3
"""
make_velocity_table.py
Velocity -> (layer, gain) table for the FPGA, so every MIDI velocity 1..127 plays at
the loudness Keyscape gives it, using only the 5 layers kept in flash (v016 v048 v064
v080 v112, library/sustains).

Target curve: the attack level of every key at Keyscape's 8 velocity layers (v016 v032
v048 v064 v080 v096 v112 v127), saved in data/velocity_levels_8layer.json (measured from
the original 8-layer library, since deleted). To measure it again from Keyscape:
    python3 scripts/make_release_midi.py --velocities 16,32,48,64,80,96,112,127 \
        --out midi/keyscape_velocity_levels       (render at 148 BPM, release OFF)
    venv/bin/python scripts/make_velocity_table.py --measure renders/keyscape_velocity_levels.wav

Loudness of a file = RMS of the first 200 ms from the onset (the attack, which is what
the ear compares between strikes). Per key, the 8 measured levels are the target curve;
velocities between them are interpolated in dB, below v016 the 16->32 slope continues.
v096, v112 and v127 are the same recording in the library (Keyscape's top layer), so
the curve is flat from v096 up, as in Keyscape.

Layer for velocity v = the kept layer nearest to v (ties go down), gain = target level
- that layer's level, so the timbre stays closest and the gains stay small. Where that
would need more than +6 dB (keys whose recorded layers jump 10+ dB), the next layer up
is used with attenuation instead.

Output (FPGA, $readmemh), address = key * 128 + velocity, key = MIDI note - 21:
  velocity_layer.mem   11264 x 16 bit
                       bits 10:8  layer index 0..4 (v016 v048 v064 v080 v112)
                       bits  7:0  gain code, same format as release_gain.mem:
                                  gain_dB = 6 - code/2, 255 = mute (velocity 0)
The player adds the two codes at note-off for the release:
  code = vel_code + hold_code - 12, clamped to 0..254 (255 if either is 255)
and looks up db_to_lin.mem once; sustain gain = db_to_lin[vel_code].

Also writes data/velocity_table.{json,csv} and, for listening,
previews/velocity/*.wav (velocity 8, 16, ... 127 in a row, each note-off with the
player's fade).

Usage (from the Rhodes_Sample_Libary folder):
    venv/bin/python scripts/make_velocity_table.py
"""

import argparse
import glob
import json
import os
import sys

import numpy as np
import soundfile as sf

from extract_releases import onset, fade_curve
from make_fpga_tables import gain_code, code_db, MUTE_CODE

SR = 44100
ALL_V = (16, 32, 48, 64, 80, 96, 112, 127)
KEPT_V = (16, 48, 64, 80, 112)
NAMES = ["C", "Cs", "D", "Ds", "E", "F", "Fs", "G", "Gs", "A", "As", "B"]


def load(lib: str, n: int, v: int) -> np.ndarray:
    return np.fromfile(glob.glob(f"{lib}/rhodes_*_n{n:03d}_v{v:03d}_sus.pcm")[0], "<i2").astype(np.float64)


def level_db(x: np.ndarray) -> float:
    o = onset(x, 0, min(len(x), int(0.3 * SR)))
    s = x[o:o + int(0.2 * SR)]
    return 10.0 * np.log10(float(np.mean(s * s)) + 1e-9) - 90.3


def main() -> int:
    ap = argparse.ArgumentParser(description="Velocity -> (layer, gain) ROM from the 8-layer library")
    ap.add_argument("--levels", default="data/velocity_levels_8layer.json",
                    help="8-layer attack levels: the target loudness curve")
    ap.add_argument("--measure", default=None, metavar="WAV",
                    help="re-measure the 8-layer levels from this render (writes --levels)")
    ap.add_argument("--measure-manifest", default="midi/keyscape_velocity_levels_manifest.json")
    ap.add_argument("--kept-library", default="library/sustains",
                    help="the 5 layers that go into flash (gains are relative to these files)")
    ap.add_argument("-o", "--out", default="../RTL/CPLD_P45_I2S_AUDIO_GENERATOR/src/Sample_Decoder/tables")
    ap.add_argument("--preview-notes", default="28,45,60,72,88", help="MIDI notes for the velocity sweep WAVs")
    args = ap.parse_args()

    if args.measure:
        man = json.load(open(args.measure_manifest))
        x, fs = sf.read(args.measure, dtype="float64", always_2d=True)
        x, sc = x[:, 0] * 32768.0, man["tempo_bpm"] / 148.0
        meas = {}
        for s in man["slots"]:
            on = int(round(s["on_sample"] * sc))
            meas[(s["note"], s["velocity"])] = level_db(x[on - int(0.1 * SR):on + int(0.6 * SR)])
        json.dump({"description": f"attack loudness (RMS of the first 200 ms after onset, dBFS), "
                                  f"keys 21..108, measured from {os.path.basename(args.measure)}",
                   "levels_dbfs": {f"v{v:03d}": [round(meas[(n, v)], 2) for n in range(21, 109)] for v in ALL_V}},
                  open(args.levels, "w"), indent=1)
    saved = json.load(open(args.levels))["levels_dbfs"]
    lv = np.array([[saved[f"v{v:03d}"][n - 21] for v in ALL_V] for n in range(21, 109)])
    kept = [{v: level_db(load(args.kept_library, n, v)) for v in KEPT_V} for n in range(21, 109)]
    vel = np.arange(128)
    words, rows, gains = [], [], []
    for k in range(88):
        L = lv[k]
        slope = (L[1] - L[0]) / (ALL_V[1] - ALL_V[0])
        target = np.interp(vel, ALL_V, L)
        target[:16] = L[0] - slope * (16 - vel[:16])
        lay_db = kept[k]
        row = []
        for v in vel:
            if v == 0:
                words.append(MUTE_CODE)
                row.append((0, None))
                continue
            li = min(range(len(KEPT_V)), key=lambda i: (abs(KEPT_V[i] - v), KEPT_V[i]))
            g = float(target[v] - lay_db[KEPT_V[li]])
            if g > 6.0 and li + 1 < len(KEPT_V):          # boost past the code range: use the
                li += 1                                   # layer above and attenuate instead
                g = float(target[v] - lay_db[KEPT_V[li]])
            c = gain_code(g)
            words.append((li << 8) | c)
            row.append((li, code_db(c)))
            gains.append(g)
        rows.append(row)

    os.makedirs(args.out, exist_ok=True)
    with open(os.path.join(args.out, "velocity_layer.mem"), "w") as f:
        f.write("".join(f"{w:04X}\n" for w in words))

    os.makedirs("data", exist_ok=True)
    json.dump({"description": "per key (MIDI 21..108) and velocity 0..127: [layer index, gain dB]; "
                              "layers " + ", ".join(f"v{v:03d}" for v in KEPT_V),
               "measured_levels_dbfs": {f"v{v:03d}": [round(float(x), 2) for x in lv[:, i]]
                                        for i, v in enumerate(ALL_V)},
               "table": rows}, open("data/velocity_table.json", "w"))
    with open("data/velocity_table.csv", "w") as f:
        f.write("note,name,velocity,layer,gain_db\n")
        for k, row in enumerate(rows):
            n = k + 21
            for v, (li, g) in enumerate(row):
                if v:
                    f.write(f"{n},{NAMES[n % 12]}{n // 12 - 1},{v},v{KEPT_V[li]:03d},{g:g}\n")

    # Listening check: each preview note at velocity 8, 16, ... 127, 0.7 s apart
    pdir = "previews/velocity"
    os.makedirs(pdir, exist_ok=True)
    for n in (int(x) for x in args.preview_notes.split(",")):
        seq = []
        for v in list(range(8, 128, 8)) + [127]:
            li, gdb = rows[n - 21][v]
            x = load(args.kept_library, n, KEPT_V[li])[:int(0.7 * SR)] * 10 ** (gdb / 20)
            off = len(x) - int(0.012 * SR)                                   # note-off: player's fade
            x[off:] *= fade_curve(len(x) - off, 0.0, SR)
            seq.append(np.r_[x, np.zeros(int(0.7 * SR) - len(x))])
        sf.write(f"{pdir}/velocity_sweep_{NAMES[n % 12]}{n // 12 - 1}_n{n:03d}.wav",
                 np.clip(np.round(np.concatenate(seq)), -32768, 32767).astype("<i2"), SR, subtype="PCM_16")

    g = np.array(gains)
    print(f"wrote {args.out}/velocity_layer.mem (11264 x 16 bit), data/velocity_table.json/.csv, "
          f"previews in {pdir}")
    print(f"gains: min {g.min():+.1f} dB, max {g.max():+.1f} dB"
          + ("  (clamped at +6 dB)" if g.max() > 6 else ""))
    print("measured attack level, dBFS (rows: keys; columns: " + " ".join(f"v{v:03d}" for v in ALL_V) + ")")
    for n in range(21, 109, 12):
        print(f"  {NAMES[n % 12]}{n // 12 - 1:<2} " + " ".join(f"{x:6.1f}" for x in lv[n - 21]))
    k = 60 - 21
    print("C4 by velocity (layer, gain dB): " + ", ".join(
        f"{v}:v{KEPT_V[rows[k][v][0]]:03d}{rows[k][v][1]:+.1f}" for v in (1, 16, 24, 40, 56, 72, 88, 100, 127)))
    return 0


if __name__ == "__main__":
    sys.exit(main())
