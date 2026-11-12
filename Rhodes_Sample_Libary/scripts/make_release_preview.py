#!/usr/bin/env python3
"""
make_release_preview.py
Builds listening previews of what the FPGA will play on a key release:
library sustain (library/sustains, no release) -> note-off -> the same
measured Keyscape fade (extract_releases.FADE_TABLE) + the extracted release sample.

Each preview is cut to the note length of the Keyscape render, and an A/B file
alternates the Keyscape original and the rebuilt version (0.4 s apart), so they
can be compared by ear. The table printed at the end gives the difference.

With --holds, it instead releases the library sustain after each given hold time
(no Keyscape comparison, since only the render's hold exists there), to hear how
the release sounds after the fade at any point in the note:
    venv/bin/python scripts/make_release_preview.py --holds 0.5,1.5,3,6

With --ends, it writes the last 4 s of the sustains that end loudest (bass keys), +18 dB,
to hear how a note stops when its file runs out (4 ms fade).

Usage (from the Rhodes_Sample_Libary folder):
    venv/bin/python scripts/make_release_preview.py                  -> previews/ab_keyscape/
    venv/bin/python scripts/make_release_preview.py --holds 0.5,1.5,3,6   -> previews/holds/
    venv/bin/python scripts/make_release_preview.py --ends           -> previews/ends/
(default render renders/keyscape_release_sampler_with_release.wav, 148 BPM)
"""

import argparse
import json
import os
import sys

import numpy as np
import soundfile as sf

import extract_releases as er

NAMES = ["C", "Cs", "D", "Ds", "E", "F", "Fs", "G", "Gs", "A", "As", "B"]


def db(q: np.ndarray) -> float:
    return 10.0 * np.log10(float(np.mean(q * q)) + 1e-12)


def main() -> int:
    ap = argparse.ArgumentParser(description="Rebuild sustain + fade + release previews")
    ap.add_argument("bounce", nargs="?", default="renders/keyscape_release_sampler_with_release.wav",
                    help="the Keyscape render the releases were extracted from")
    ap.add_argument("--ends", action="store_true", help="last 4 s of the loudest-ending sustains")
    ap.add_argument("--holds", default=None,
                    help="comma-separated seconds from note-on to note-off; skips the Keyscape A/B")
    ap.add_argument("--manifest", default="midi/keyscape_release_sampler_manifest.json")
    ap.add_argument("--tempo-actual", type=float, default=148.0)
    ap.add_argument("--notes", default="21,36,60,84,93", help="MIDI notes (default A0,C2,C4,C6,A6)")
    ap.add_argument("--velocities", default="16,48,64,80,112")
    ap.add_argument("--gain-table", default="data/release_gain_table.json",
                    help="with --holds: scale each release by its gain for that hold time")
    ap.add_argument("--no-gain-table", action="store_true", help="with --holds: play releases at full level")
    ap.add_argument("--library", default="library/sustains")
    ap.add_argument("--releases", default="library/releases")
    ap.add_argument("-o", "--out", default=None,
                    help="default previews/ab_keyscape, previews/holds or previews/ends")
    args = ap.parse_args()

    if args.ends:
        args.out = args.out or "previews/ends"
        return ends_mode(args)
    if args.holds:
        args.out = args.out or "previews/holds"
        return holds_mode(args)
    args.out = args.out or "previews/ab_keyscape"
    man = json.load(open(args.manifest))
    sc = man.get("tempo_bpm", 120.0) / args.tempo_actual if args.tempo_actual else 1.0
    slots = {(s["note"], s["velocity"]): s for s in man["slots"]}
    x, fs = sf.read(args.bounce, dtype="float64", always_2d=True)
    x = x[:, 0] * 32768.0
    os.makedirs(args.out, exist_ok=True)
    pre, pad = int(0.005 * fs), 3000
    ab, rows = [], []

    for n in (int(v) for v in args.notes.split(",")):
        name = f"{NAMES[n % 12]}{n // 12 - 1}"
        for v in (int(v) for v in args.velocities.split(",")):
            base = f"rhodes_{name}_n{n:03d}_v{v:03d}"
            s = slots[(n, v)]
            on, off, end = (int(round(s[k] * sc)) for k in ("on_sample", "off_sample", "end_sample"))
            o = er.onset(x, max(0, on - int(0.1 * fs)), on + int(0.25 * fs))
            hold = off - on
            orig = x[o - pre:min(end, len(x))]

            # Line the library sustain up with the render (same audio), so note-off lands
            # exactly where Keyscape had it
            raw = np.fromfile(os.path.join(args.library, base + "_sus.pcm"), "<i2").astype(np.float64)
            L = np.r_[np.zeros(pad), raw, np.zeros(pad)]
            a0, a1 = pre + int(0.1 * fs), pre + hold - 441
            A = orig[a0:a1]
            st0 = pad + er.onset(raw, 0, int(0.3 * fs)) - pre
            def cor(st):
                B = L[st + a0:st + a1]
                return float(np.dot(A, B) / np.sqrt(np.dot(A, A) * np.dot(B, B) + 1e-9))
            st = max(range(max(0, st0 - 1500), st0 + 1501), key=cor)
            d = min(np.arange(-1.0, 1.001, 0.05), key=lambda d: float(np.sum(
                (A - er.frac_shift(L[st + a0 - 64:st + a1 + 64], d)[64:64 + len(A)]) ** 2)))

            # sustain x fade + release, starting together at note-off
            n_off = pre + hold
            rf = os.path.join(args.releases, base + "_rel.pcm")
            R = np.fromfile(rf, "<i2").astype(np.float64) if os.path.exists(rf) else np.zeros(0)
            tot = n_off + max(len(R), int(0.03 * fs))
            sus = er.frac_shift(np.r_[L[st:st + tot + 128], np.zeros(tot + 128)][:tot + 128], d)[:tot]
            g = np.ones(tot)
            g[n_off:] = er.fade_curve(tot - n_off, er.FADE_DELAY_MS, fs)
            out = sus * g
            out[n_off:n_off + len(R)] += R
            pcm = np.clip(np.round(out), -32768, 32767).astype("<i2")
            sf.write(os.path.join(args.out, base + "_rebuilt.wav"), pcm, fs, subtype="PCM_16")

            y = np.r_[out, np.zeros(len(orig))][:len(orig)]
            def diff(a, b):
                return db(orig[a:b] - y[a:b]) - db(orig[a:b])
            rows.append((base, "yes" if len(R) else "none (quiet)", cor(st),
                         diff(pre + int(0.05 * fs), n_off - 441), diff(n_off, n_off + int(0.012 * fs)),
                         diff(n_off + int(0.012 * fs), n_off + int(0.3 * fs))))
            ab += [orig, np.zeros(int(0.4 * fs)), y, np.zeros(int(0.9 * fs))]

    sf.write(os.path.join(args.out, "AB_keyscape_then_rebuilt.wav"),
             np.clip(np.round(np.concatenate(ab)), -32768, 32767).astype("<i2"), fs, subtype="PCM_16")
    print("rebuilt vs Keyscape render, difference in dB (lower = closer):")
    print(f"{'file':22s} {'release':13s} {'lib corr':>8s} {'sustain':>8s} {'0-12 ms':>8s} {'12-300 ms':>10s}")
    for r in rows:
        print(f"{r[0]:22s} {r[1]:13s} {r[2]:8.4f} {r[3]:8.1f} {r[4]:8.1f} {r[5]:10.1f}")
    print(f"wrote {len(rows)} previews + AB_keyscape_then_rebuilt.wav "
          f"({sum(map(len, ab)) / fs:.0f} s) to {args.out}")
    return 0


def ends_mode(args) -> int:
    """The last 4 s of the 6 sustains whose ending is loudest, +18 dB, 1.5 s apart."""
    import glob
    fs = 44100
    ends = []
    for f in glob.glob(os.path.join(args.library, "*_sus.pcm")):
        x = np.fromfile(f, "<i2").astype(np.float64)
        ends.append((db(x[-617:-176]), f))
    os.makedirs(args.out, exist_ok=True)
    seq = []
    for lvl, f in sorted(ends, reverse=True)[:6]:
        x = np.fromfile(f, "<i2").astype(np.float64)
        seq += [x[-4 * fs:] * 8.0, np.zeros(int(1.5 * fs))]
        print(f"{os.path.basename(f)}: last 10 ms at {lvl - 90.3:.1f} dBFS")
    path = os.path.join(args.out, "loudest_endings_+18dB.wav")
    sf.write(path, np.clip(np.round(np.concatenate(seq)), -32768, 32767).astype("<i2"), fs, subtype="PCM_16")
    print(f"wrote {path}")
    return 0


def holds_mode(args) -> int:
    """sustain x fade + release with the note-off at each hold time, per note/velocity."""
    fs = 44100
    holds = [float(h) for h in args.holds.split(",")]
    os.makedirs(args.out, exist_ok=True)
    gt = None                                  # release gain vs time held (make_release_gain_table.py)
    if os.path.exists(args.gain_table) and not args.no_gain_table:
        gt = json.load(open(args.gain_table))
    allseq = []
    for n in (int(v) for v in args.notes.split(",")):
        name = f"{NAMES[n % 12]}{n // 12 - 1}"
        for v in (int(v) for v in args.velocities.split(",")):
            base = f"rhodes_{name}_n{n:03d}_v{v:03d}"
            L = np.fromfile(os.path.join(args.library, base + "_sus.pcm"), "<i2").astype(np.float64)
            lo = er.onset(L, 0, int(0.3 * fs))
            rf = os.path.join(args.releases, base + "_rel.pcm")
            R = np.fromfile(rf, "<i2").astype(np.float64) if os.path.exists(rf) else np.zeros(0)
            seq = []
            row = gt["layers"][f"v{v:03d}"][n - 21] if gt else None
            for h in holds:
                n_off = lo + int(round(h * fs))
                if n_off >= len(L):
                    print(f"{base}: sustain is only {len(L) / fs:.1f} s, hold {h} s skipped")
                    continue
                tot = n_off + max(len(R), int(0.03 * fs))
                sus = np.r_[L[:tot], np.zeros(max(0, tot - len(L)))]
                g = np.ones(tot)
                g[n_off:] = er.fade_curve(tot - n_off, er.FADE_DELAY_MS, fs)
                out = sus * g
                rg = 1.0
                if row is not None:
                    gdb = gt["mute_db"] if h > gt["hold_s"][-1] else float(np.interp(h, gt["hold_s"], row))
                    rg = 10.0 ** (gdb / 20.0)
                out[n_off:n_off + len(R)] += R * rg
                pcm = np.clip(np.round(out), -32768, 32767).astype("<i2")
                sf.write(os.path.join(args.out, f"{base}_hold{h:g}s.wav"), pcm, fs, subtype="PCM_16")
                seq += [pcm.astype(np.float64), np.zeros(int(0.6 * fs))]
                print(f"{base} hold {h:g} s: sustain {db(L[n_off - 441:n_off]) - 90.3:6.1f} dBFS at note-off, "
                      f"release {'peak %.1f dBFS x gain %.1f dB' % (20 * np.log10(np.abs(R).max() / 32768), 20 * np.log10(rg)) if len(R) else 'none (quiet key)'}")
            allseq += seq + [np.zeros(int(0.6 * fs))]
    path = os.path.join(args.out, "all_holds.wav")
    sf.write(path, np.clip(np.round(np.concatenate(allseq)), -32768, 32767).astype("<i2"), fs, subtype="PCM_16")
    print(f"wrote {path} ({sum(map(len, allseq)) / fs:.0f} s) and one file per note/velocity/hold")
    return 0


if __name__ == "__main__":
    sys.exit(main())
