#!/usr/bin/env python3
"""
extract_releases.py
Cuts release samples out of a Keyscape bounce of make_release_midi.py's clip.

Keyscape's note-off does two things at once (measured, see NOTES.md
item 6/7): the sustain holds ~2-3 ms then fades out over ~5 ms (FADE_TABLE) and a
release sample starts. So from ~8 ms after note-off the bounce holds only the
release. For the first ~8 ms, the sustain is extrapolated past note-off with a Burg
AR model (trained on the audio just before note-off), multiplied by the fade, and
subtracted.

Each release is then scaled so the render's sustain matches the library's sustain
for the same key/velocity (the library may have been rendered at a slightly
different level), trimmed at its end, and written as raw 16-bit mono PCM like the
library's _sus.pcm files.

Null-test mode (--release-off): with a second render of the same clip made with
Keyscape's release turned OFF (same project, tempo and start), the sustain is
removed exactly instead of predicted: release = (release on - release off) from
note-off on. The part before note-off (key-down noise that differs between renders)
is dropped. The release-off render also gives Keyscape's exact sustain fade per key,
saved in index.json as fade_gain_1ms.

Usage (from the Rhodes_Sample_Libary folder; the defaults are the current renders/paths):
    venv/bin/python scripts/extract_releases.py
  = renders/keyscape_release_sampler_with_release.wav midi/keyscape_release_sampler_manifest.json
    --release-off renders/keyscape_release_sampler_without_release.wav --tempo-actual 148
    --library library/sustains -o library/releases   (all releases kept: --min-peak-dbfs -1000)

The sustain library is only read, never written.
"""

import argparse
import json
import math
import os
import sys

import numpy as np
import soundfile as sf

# Keyscape's sustain fade after note-off (+ render latency): gain at 0, 1, 2, ... ms,
# median over all 405 null-test releases (2026-11-11). Nearly the same on every key.
FADE_TABLE = (1.0, 1.0, 1.0, 0.81, 0.56, 0.37, 0.20, 0.05, 0.01, 0.0)
FADE_DELAY_MS = 0.0     # extra shift of the table (kept for the single-render search)
FADE_LEN_MS = float(len(FADE_TABLE))
ORDERS = (32, 64, 128, 200, 400, 800, 1600)   # low keys need high orders (dense harmonics)


def burg(x: np.ndarray, orders) -> dict:
    """AR coefficients a[0..p] (a[0] = 1) for every p in orders, by Burg's method in one
    pass (it is order-recursive); x[n] ~ -sum a[i] x[n-i]."""
    f = x.astype(np.float64).copy()
    b = f.copy()
    a = np.array([1.0])
    out = {}
    for m in range(1, max(orders) + 1):
        ff, bb = f[1:], b[:-1]
        den = np.dot(ff, ff) + np.dot(bb, bb)
        k = -2.0 * np.dot(ff, bb) / den if den > 0 else 0.0
        a = np.r_[a, 0.0] + k * np.r_[a, 0.0][::-1]
        f, b = ff + k * bb, bb + k * ff
        if m in orders:
            out[m] = a.copy()
    return out


def extrapolate(hist: np.ndarray, a: np.ndarray, n: int) -> np.ndarray:
    p = len(a) - 1
    buf = np.r_[hist[-p:], np.zeros(n)]
    c = -a[1:][::-1]                      # c . buf[i:i+p] predicts buf[i+p]
    for i in range(n):
        buf[p + i] = np.dot(c, buf[i:i + p])
    return buf[p:]


def db(x: np.ndarray) -> float:
    return 10.0 * math.log10(float(np.mean(x * x)) + 1e-12)


def frac_shift(v: np.ndarray, d: float) -> np.ndarray:
    k = np.fft.rfftfreq(len(v))
    return np.fft.irfft(np.fft.rfft(v) * np.exp(-2j * np.pi * k * d), len(v))


def library_reference(x: np.ndarray, L: np.ndarray, on: int, noff: int, sr: int, n: int):
    """The library sustain aligned (sub-sample) and gain-matched to the render just before
    note-off. The render and the library are the same Keyscape audio, so this continues the
    sustain past note-off exactly, apart from round-robin key noise."""
    fit = slice(noff - int(0.3 * sr), noff - int(0.001 * sr))
    pad = int(0.05 * sr)
    lo, hi = noff - int(0.35 * sr), noff + n + pad      # render span the reference must cover
    def place(k):
        y = np.zeros(hi - lo)
        a = lo - (on + k)                                # library index at render index lo
        src = L[max(0, a):max(0, a) + len(y) - max(0, -a)]
        y[max(0, -a):max(0, -a) + len(src)] = src
        return y
    r0 = slice(fit.start - lo, fit.stop - lo)
    def score(k):                       # normalized correlation = least leftover after gain match
        b = place(k)[r0]
        return float(np.dot(x[fit], b)) / math.sqrt(float(np.dot(b, b)) + 1e-9)
    lag = max(range(-pad, pad + 1), key=score)
    base = place(lag)
    d = min(np.arange(-1.0, 1.001, 0.05), key=lambda d: float(np.sum((x[fit] - frac_shift(base, d)[r0]) ** 2)))
    ref = frac_shift(base, d)
    den = float(np.dot(ref[r0], ref[r0]))
    if den <= 0:
        return None, None
    ref *= float(np.dot(x[fit], ref[r0])) / den
    val = int(0.012 * sr)
    err = db(x[noff - val:noff] - ref[noff - val - lo:noff - lo]) - db(x[noff - val:noff])
    return ref[noff - lo:noff - lo + n], err


def predict_sustain(x: np.ndarray, noff: int, f0: float, sr: int, n: int, lib_ref=None):
    """Best continuation of the sustain past noff: AR extrapolations of several orders,
    chosen by a held-out prediction test, or the library reference if it does better."""
    win = int(min(0.4, max(0.06, 12.0 / f0)) * sr)
    val = int(0.012 * sr)
    start = max(0, noff - win)
    orders = [p for p in ORDERS if p * 4 <= win - val] or [ORDERS[0]]
    hist = x[start:noff - val]
    models = burg(hist, orders)
    best = None
    for p, a in models.items():
        err = db(x[noff - val:noff] - extrapolate(hist, a, val)) - db(x[noff - val:noff])
        if best is None or err < best[0]:
            best = (err, p)
    err, p = best
    if lib_ref is not None and lib_ref[0] is not None and lib_ref[1] < err:
        return lib_ref[0], "library", lib_ref[1]
    # Refit on the whole window, up to note-off
    a = burg(x[start:noff], [p])[p]
    return extrapolate(x[start:noff], a, n), f"AR {p}", err


def fade_curve(n: int, delay: float, sr: int) -> np.ndarray:
    t_ms = np.arange(n) / sr * 1000.0 - delay
    return np.interp(t_ms, np.arange(len(FADE_TABLE)), FADE_TABLE, left=1.0, right=0.0)


def onset(x: np.ndarray, lo: int, hi: int) -> int:
    seg = np.abs(x[lo:hi])
    thr = 0.005 * seg.max() if seg.size and seg.max() > 0 else 1.0
    return lo + int(np.argmax(seg > thr))


def main() -> int:
    ap = argparse.ArgumentParser(description="Extract release samples from a Keyscape bounce")
    ap.add_argument("bounce", nargs="?", default="renders/keyscape_release_sampler_with_release.wav", help="rendered WAV (44.1 kHz; 16/24-bit; mono or stereo, left channel is used)")
    ap.add_argument("manifest", nargs="?", default="midi/keyscape_release_sampler_manifest.json", help="manifest JSON written by make_release_midi.py")
    ap.add_argument("-o", "--out", default="library/releases",
                    help="folder for the raw 16-bit .pcm releases")
    ap.add_argument("-w", "--wav-dir", default=None, help="also write .wav copies here, for listening")
    ap.add_argument("--library", default="library/sustains",
                    help="sustain library used for level matching (read only)")
    ap.add_argument("--release-off", default="renders/keyscape_release_sampler_without_release.wav",
                    help="render of the same clip with Keyscape's release OFF: null-test extraction")
    ap.add_argument("--no-level-match", action="store_true", help="keep Keyscape's render level")
    ap.add_argument("--offset-ms", type=float, default=0.0, help="shift all slots if the bounce has a lead-in")
    ap.add_argument("--tempo-actual", type=float, default=148.0,
                    help="BPM the DAW actually played the clip at, if not the manifest's tempo")
    ap.add_argument("--min-peak-dbfs", type=float, default=-1000.0,
                    help="skip releases quieter than this (top keys have almost no release)")
    ap.add_argument("--prefix", default="rhodes")
    args = ap.parse_args()

    man = json.load(open(args.manifest))
    x, sr = sf.read(args.bounce, dtype="float64", always_2d=True)
    if sr != man["sample_rate"]:
        sys.exit(f"bounce is {sr} Hz, manifest expects {man['sample_rate']} Hz")
    x = x[:, 0] * 32768.0
    y = None
    if args.release_off:
        y, sr2 = sf.read(args.release_off, dtype="float64", always_2d=True)
        if sr2 != sr:
            sys.exit(f"{args.release_off} is {sr2} Hz, {args.bounce} is {sr} Hz")
        y = y[:, 0] * 32768.0
        y = np.r_[y, np.zeros(max(0, len(x) - len(y)))][:len(x)]
    shift = int(round(args.offset_ms * sr / 1000.0))
    scale = man.get("tempo_bpm", 120.0) / args.tempo_actual if args.tempo_actual else 1.0
    os.makedirs(args.out, exist_ok=True)
    if args.wav_dir:
        os.makedirs(args.wav_dir, exist_ok=True)

    index, worst, skipped = [], [], []
    sub_len = int((FADE_DELAY_MS + FADE_LEN_MS + 6.0) / 1000.0 * sr)   # how long the sustain is subtracted
    for s in man["slots"]:
        on, off, end = (int(round(s[k] * scale)) + shift for k in ("on_sample", "off_sample", "end_sample"))
        if off + int(0.3 * sr) > len(x):
            print(f"{s['name']} v{s['velocity']:03d}: bounce ends before this release, skipped")
            continue
        if end > len(x):
            print(f"{s['name']} v{s['velocity']:03d}: bounce ends {(end - len(x)) / sr:.2f} s early, using what is there")
            end = len(x)
        f0 = 440.0 * 2.0 ** ((s["note"] - 69) / 12.0)
        o = onset(x, max(0, on - int(0.1 * sr)), on + int(0.25 * sr))
        noff = off + (o - on)                 # note-off in audio time, with the render latency

        lib = os.path.join(args.library, f"{args.prefix}_{s['name']}_n{s['note']:03d}_v{s['velocity']:03d}_sus.pcm")
        L = np.fromfile(lib, "<i2").astype(np.float64) if os.path.exists(lib) else None
        lo = onset(L, 0, min(len(L), int(0.3 * sr))) if L is not None else 0

        fade_gain = None
        if y is not None:
            # 1. Null test: subtract the release-off render (after a small alignment check)
            fit = slice(noff - int(0.05 * sr), noff - int(0.001 * sr))   # after the key-down noise
            # least leftover, not max correlation: correlation can lock onto a neighbouring period
            lag = min(range(-32, 33), key=lambda k: float(np.sum((x[fit] - y[fit.start + k:fit.stop + k]) ** 2)))
            yy = np.roll(y, -lag)
            model, best = f"null (lag {lag})", 0.0
            err = db(x[fit] - yy[fit]) - db(x[fit])          # how well the sustain cancels before note-off
            # The release is what the player must add to (library sustain x FADE_TABLE) to get the
            # Keyscape render back. Subtracting the release-off render directly would also remove
            # Keyscape's low-frequency output tail after the fade (up to ~90 ms on low keys), which
            # the player does not produce, so the library sustain is subtracted instead when it
            # matches the render well; the release-off render is the fallback.
            rel = x[noff:end] - yy[noff:end]
            lib_ref = library_reference(x, L, o - lo, noff, sr, sub_len) if L is not None else None
            if lib_ref is not None and lib_ref[0] is not None and lib_ref[1] < -35.0:
                rel = x[noff:end].copy()
                rel[:sub_len] -= lib_ref[0] * fade_curve(sub_len, FADE_DELAY_MS, sr)
                model = f"library x fade (null check {err:.0f} dB)"
                err = lib_ref[1]
            # Keyscape's own sustain fade, from the release-off render vs its AR continuation
            hist = yy[noff - int(min(0.4, max(0.06, 12.0 / f0)) * sr):noff]
            p = max(q for q in ORDERS if q * 4 <= len(hist))
            cont = extrapolate(hist, burg(hist, [p])[p], int(0.015 * sr))
            w = int(0.001 * sr)
            fade_gain = [round(float(np.dot(yy[noff + k:noff + k + w], cont[k:k + w]) /
                                     max(1e-9, np.dot(cont[k:k + w], cont[k:k + w]))), 3)
                         for k in range(0, len(cont) - w + 1, w)]
        else:
            # 1. Remove the fading sustain: pick the fade delay that leaves the least energy
            lib_ref = library_reference(x, L, o - lo, noff, sr, sub_len) if L is not None else None
            pred, model, err = predict_sustain(x, noff, f0, sr, sub_len, lib_ref)
            # The fade is the same fixed curve the player uses (not fitted per note), so any
            # mismatch with Keyscape's real fade ends up inside the release sample and
            # sustain x fade + release adds back up to the render.
            best = FADE_DELAY_MS
            rel = x[noff:end].copy()
            rel[:sub_len] -= pred * fade_curve(sub_len, best, sr)

        # 2. Level match against the library sustain of the same key/velocity
        gain_db = 0.0
        if not args.no_level_match and L is not None:
            a0, a1 = int(0.05 * sr), (off - on) - int(0.1 * sr)
            if a1 > a0 and lo + a1 <= len(L):
                gain_db = db(L[lo + a0:lo + a1]) - db(x[o + a0:o + a1])
        rel *= 10.0 ** (gain_db / 20.0)

        # 3. Trim after the last non-zero sample (Keyscape ends releases in digital silence)
        loud = np.nonzero(np.abs(rel) >= 0.5)[0]
        n = max(int(0.05 * sr), (loud[-1] + 1) if loud.size else 0)
        fo = min(n, int(0.004 * sr))
        rel = rel[:n]
        rel[n - fo:] *= np.linspace(1.0, 0.0, fo)
        pcm = np.clip(np.round(rel), -32768, 32767).astype("<i2")

        base = f"{args.prefix}_{s['name']}_n{s['note']:03d}_v{s['velocity']:03d}_rel"
        peak = 20 * math.log10(max(1, int(np.abs(pcm).max())) / 32768)
        if peak < args.min_peak_dbfs:
            print(f"{base}: peak {peak:.1f} dBFS is below {args.min_peak_dbfs:.0f} dBFS, no release written")
            skipped.append({"file": base + ".pcm", "note": s["note"], "velocity": s["velocity"],
                            "peak_dbfs": round(peak, 1)})
            continue
        pcm.tofile(os.path.join(args.out, base + ".pcm"))
        if args.wav_dir:
            sf.write(os.path.join(args.wav_dir, base + ".wav"), pcm, sr, subtype="PCM_16")

        info = {"file": base + ".pcm", "note": s["note"], "velocity": s["velocity"],
                "samples": int(n), "seconds": round(n / sr, 3),
                "peak_dbfs": round(peak, 1),
                "latency_ms": round((o - on) / sr * 1000, 2), "fade_delay_ms": round(float(best), 1),
                "sustain_model": model, "sustain_prediction_db": round(err, 1),
                "fade_gain_1ms": fade_gain,
                "level_match_db": round(gain_db, 2)}
        index.append(info)
        worst.append((err, base))
        print(f"{base}: {info['seconds']:.3f} s, peak {info['peak_dbfs']:6.1f} dBFS, "
              f"prediction {err:6.1f} dB ({model}), fade delay {best:.1f} ms, level {gain_db:+.1f} dB")

    with open(os.path.join(args.out, "index.json"), "w") as f:
        json.dump({"sample_rate": sr, "fade_delay_ms_default": FADE_DELAY_MS,
                   "fade_len_ms": FADE_LEN_MS, "min_peak_dbfs": args.min_peak_dbfs,
                   "files": index, "skipped_quiet": skipped}, f, indent=1)
    if worst:
        worst.sort(reverse=True)
        print(f"\n{len(index)} releases written to {args.out}")
        print("weakest sustain predictions (closer to 0 dB = more sustain left in the first ~10 ms):")
        for err, base in worst[:5]:
            print(f"  {err:6.1f} dB  {base}")
        lv = [i["level_match_db"] for i in index]
        print(f"level match: min {min(lv):+.1f}, median {sorted(lv)[len(lv) // 2]:+.1f}, max {max(lv):+.1f} dB")
    if skipped:
        print(f"{len(skipped)} releases below {args.min_peak_dbfs:.0f} dBFS not written: "
              + ", ".join(i["file"].split("_")[1] + " v" + str(i["velocity"]) for i in skipped))
    return 0


if __name__ == "__main__":
    sys.exit(main())
