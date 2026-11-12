#!/usr/bin/env python3
"""
make_release_gain_table.py
Builds the release gain table: how much quieter Keyscape plays a key's release the
longer the note was held before note-off, for all 88 keys x the 5 library layers.

Input: the two renders of make_release_midi.py --hold-sweep-wide (release ON and OFF,
same project and tempo). Each release is isolated by the null test (ON - OFF from
note-off) and its energy over 0-700 ms is compared with the 0.811 s hold, the hold
the release samples in library/releases/ were extracted at
(1.0 s at 120 BPM played at 148 BPM). So the table is the gain to apply to those
samples.

Table: gain in dB at the measured holds (0, 0.203, 0.406, 0.811, 1.62, 3.24, 6.49,
12.97 s; each double the last, so the player can index it by the position of the
held-time counter's top bit). Between holds: interpolate in dB; after the last
hold: mute. Measured keys are every 4th key (A0, C#1, ... A7, C8):
  1. per velocity (v048, v112) and hold, a 3-point running median across the
     measured keys removes round-robin variation (~1-3 dB)
  2. linear interpolation across keys fills in the other 65 keys
  3. layers: v016 = v048; v112 measured; v064, v080 interpolated in dB by velocity
Releases quieter than -100 dBFS count as silent (MUTE_DB); ones between -100 and
-75 dBFS (top-key soft releases, quantization noise) are unreliable and are filled
from neighbouring keys, or from the other velocity. From C#6 up only holds up to
3.24 s were rendered: 6.49 s continues the 1.62 -> 3.24 s trend one step and
12.97 s is muted (almost every measured key is <= -50 dB or silent there).

Usage (from the Rhodes_Sample_Libary folder):
    venv/bin/python scripts/make_release_gain_table.py
  = renders/keyscape_release_sampler_holdsweep_wide_{with,without}_release.wav
    --manifest midi/keyscape_release_sampler_holdsweep_wide_manifest.json --tempo-actual 148
writes data/holdsweep_wide_measurements.json and data/release_gain_table.{json,csv}.
With --reuse it skips the renders and rebuilds the table from the saved measurements.
"""

import argparse
import json
import os
import sys

import numpy as np
import soundfile as sf

import extract_releases as er

MUTE_DB = -90.0
LAYERS = (16, 48, 64, 80, 112)
NAMES = ["C", "Cs", "D", "Ds", "E", "F", "Fs", "G", "Gs", "A", "As", "B"]


def db(q: np.ndarray) -> float:
    return 10.0 * np.log10(float(np.mean(q * q)) + 1e-12) - 90.3      # dBFS


def measure(on_wav: str, off_wav: str, manifest: str, scale: float) -> list:
    x, fs = sf.read(on_wav, dtype="float64")
    y, _ = sf.read(off_wav, dtype="float64")
    x, y = x * 32768.0, y * 32768.0
    out = []
    for s in json.load(open(manifest))["slots"]:
        on, off, end = (int(round(s[k] * scale)) for k in ("on_sample", "off_sample", "end_sample"))
        o = er.onset(x, max(0, on - int(0.1 * fs)), on + int(0.25 * fs))
        noff, end = off + (o - on), min(end, len(x))
        fit = slice(noff - int(0.05 * fs), noff - int(0.001 * fs))
        lag = min(range(-32, 33), key=lambda k: float(np.sum((x[fit] - y[fit.start + k:fit.stop + k]) ** 2)))
        r = x[noff:end] - y[noff + lag:end + lag]
        n7 = int(0.7 * fs)
        out.append({"note": s["note"], "velocity": s["velocity"], "hold_s": round(s["hold_s"] * scale, 3),
                    "lag": lag, "sustain_dbfs": round(db(x[noff - int(0.02 * fs):noff]), 1),
                    "release_dbfs": round(db(np.r_[r, np.zeros(n7)][:n7]), 1)})
    return out


def main() -> int:
    ap = argparse.ArgumentParser(description="Release gain vs time held, for all keys and layers")
    ap.add_argument("with_release", nargs="?",
                    default="renders/keyscape_release_sampler_holdsweep_wide_with_release.wav",
                    help="hold-sweep-wide render, release ON")
    ap.add_argument("without_release", nargs="?",
                    default="renders/keyscape_release_sampler_holdsweep_wide_without_release.wav",
                    help="hold-sweep-wide render, release OFF")
    ap.add_argument("--manifest", default="midi/keyscape_release_sampler_holdsweep_wide_manifest.json")
    ap.add_argument("--tempo-actual", type=float, default=148.0)
    ap.add_argument("--out", default="data")
    ap.add_argument("--reuse", action="store_true", help="use the saved measurements, not the renders")
    args = ap.parse_args()

    os.makedirs(args.out, exist_ok=True)
    mpath = os.path.join(args.out, "holdsweep_wide_measurements.json")
    man = json.load(open(args.manifest))
    scale = man.get("tempo_bpm", 120.0) / args.tempo_actual if args.tempo_actual else 1.0
    if not args.reuse:
        meas = measure(args.with_release, args.without_release, args.manifest, scale)
        json.dump(meas, open(mpath, "w"), indent=0)
    else:
        meas = json.load(open(mpath))

    ref_hold = round(1.0 * scale, 3)
    holds = sorted({m["hold_s"] for m in meas})
    keys = sorted({m["note"] for m in meas})
    lv = {(m["note"], m["velocity"], m["hold_s"]): m["release_dbfs"] for m in meas}

    # 1. Measured gain vs the reference hold, per velocity: [key, hold]; NaN = unreliable
    meas_tab = {}
    for v in (48, 112):
        t = np.full((len(keys), len(holds)), np.nan)
        for i, n in enumerate(keys):
            ref = lv[(n, v, ref_hold)]
            for j, h in enumerate(holds):
                if (n, v, h) not in lv or ref < -75:
                    continue
                if lv[(n, v, h)] < -100:
                    t[i, j] = MUTE_DB
                elif lv[(n, v, h)] >= -75:
                    t[i, j] = max(MUTE_DB, lv[(n, v, h)] - ref)
        meas_tab[v] = t
    for v, other in ((48, 112), (112, 48)):          # last resort: the other velocity
        t = meas_tab[v]
        for i in range(len(keys)):
            for j in range(len(holds)):
                if np.isnan(t[i, j]) and not np.all(np.isnan(t[max(0, i - 1):i + 2, j])):
                    continue                          # neighbours will fill it
                if np.isnan(t[i, j]) and holds[j] <= 3.3:
                    t[i, j] = meas_tab[other][i, j]

    # 2. Running median across neighbouring measured keys, then interpolate to all 88 keys
    full = {}
    j_last = holds.index(max(h for h in holds if h <= 3.3))
    for v, t in meas_tab.items():
        sm = np.array([[np.nanmedian(t[max(0, i - 1):i + 2, j]) if not np.all(np.isnan(t[max(0, i - 1):i + 2, j]))
                        else np.nan for j in range(len(holds))] for i in range(len(keys))])
        for i in range(len(keys)):                    # top keys: holds that were not rendered
            for j in range(j_last + 1, len(holds)):
                if np.isnan(sm[i, j]):
                    sm[i, j] = (max(MUTE_DB, 2 * sm[i, j_last] - sm[i, j_last - 1])
                                if j == j_last + 1 else MUTE_DB)
        for j in range(len(holds)):                   # gaps left: interpolate across keys
            ok = ~np.isnan(sm[:, j])
            sm[~ok, j] = np.interp(np.array(keys)[~ok], np.array(keys)[ok], sm[ok, j])
        sm[:, holds.index(ref_hold)] = 0.0
        full[v] = np.array([[np.interp(n, keys, sm[:, j]) for j in range(len(holds))]
                            for n in range(21, 109)])

    # 3. Layers
    def layer(v):
        if v <= 48:
            return full[48]
        a = (v - 48) / (112 - 48)
        return (1 - a) * full[48] + a * full[112]

    grid = [0.0] + holds                      # hold 0 = same gain as the shortest measured hold
    table = {}
    for v in LAYERS:
        g = layer(v)
        table[f"v{v:03d}"] = [[round(float(c) * 2) / 2 for c in np.r_[row[0], row]] for row in g]

    # Fit check on the measured keys (smoothed table vs raw measurement)
    err = []
    for v in (48, 112):
        for i, n in enumerate(keys):
            for j, h in enumerate(holds):
                raw = meas_tab[v][i, j]
                if not np.isnan(raw) and raw > -60 and (n, v, h) in lv and lv[(n, v, h)] > -75:
                    err.append(table[f"v{v:03d}"][n - 21][j + 1] - raw)

    res = {"description": "release gain (dB) vs time held before note-off, relative to the "
                          "0.811 s hold the release samples were extracted at; interpolate in dB "
                          "between holds, mute after the last hold",
           "hold_s": grid, "mute_db": MUTE_DB, "measured_keys": keys,
           "fit_rms_db_on_measured_keys": round(float(np.sqrt(np.mean(np.square(err)))), 2),
           "layers": table}
    json.dump(res, open(os.path.join(args.out, "release_gain_table.json"), "w"), indent=1)
    with open(os.path.join(args.out, "release_gain_table.csv"), "w") as f:
        f.write("note,name,layer," + ",".join(f"{h:g}s" for h in grid) + "\n")
        for v in LAYERS:
            for i, row in enumerate(table[f"v{v:03d}"]):
                n = 21 + i
                f.write(f"{n},{NAMES[n % 12]}{n // 12 - 1},v{v:03d}," + ",".join(f"{c:g}" for c in row) + "\n")

    print(f"{len(meas)} measurements, holds {grid} s (reference {ref_hold} s)")
    print(f"table: 88 keys x {len(LAYERS)} layers x {len(grid)} holds; fit on measured keys "
          f"rms {res['fit_rms_db_on_measured_keys']} dB")
    for n in (21, 36, 48, 60, 72, 84, 96, 108):
        for v in (16, 64, 112):
            print(f"  {NAMES[n % 12]}{n // 12 - 1:<2} v{v:03d}: " +
                  " ".join(f"{c:6.1f}" for c in table[f"v{v:03d}"][n - 21]))
    return 0


if __name__ == "__main__":
    sys.exit(main())
