#!/usr/bin/env python3
"""
rhodes_loop_tool.py -- analyse decaying instrument samples, find short
zero-crossing-aligned loop points, cut each sample at loop_end, and emit an
SFZ instrument that loops loop_start:loop_end at playback (click-free with
no crossfade, since find_loop only returns real zero-crossing samples).

Designed for electric piano (Rhodes/Wurlitzer) libraries where each note is
recorded to full decay at several velocities. The point of the tool is to
*measure* each sample so that loop length and amp decay are derived from the
audio rather than guessed.

Dependencies:
    pip install numpy soundfile

Usage:
    python rhodes_loop_tool.py analyse  IN_DIR
    python rhodes_loop_tool.py process  IN_DIR OUT_DIR --format flac --sfz rhodes.sfz
    # also write full-length baked-hold renders for auditioning by ear:
    python rhodes_loop_tool.py process  IN_DIR OUT_DIR --preview-dir PREVIEW_DIR --sfz rhodes.sfz

Filename convention (best effort; override with --regex):
    anything_C3_v064.wav / anything-60-100.wav / Rhodes_A#2_vl3.wav
Root pitch is taken from the filename when parseable, otherwise estimated.
"""

from __future__ import annotations

import argparse
import json
import re
import sys
from dataclasses import dataclass, asdict, field
from pathlib import Path

import numpy as np
import soundfile as sf


# --------------------------------------------------------------------------
# note / filename helpers
# --------------------------------------------------------------------------

_NOTE_OFFSETS = {"C": 0, "D": 2, "E": 4, "F": 5, "G": 7, "A": 9, "B": 11}
_NOTE_RE = re.compile(r"(?<![A-Za-z])([A-Ga-g])([#bs]?)(-?\d)(?![0-9])")
_NOTE_LABEL_RE = re.compile(r"(?:^|[_\-\s])(?:n|note|midi)[_\-]?(\d{1,3})(?![0-9])", re.IGNORECASE)
_MIDI_RE = re.compile(r"(?<!\d)(\d{1,3})(?!\d)")
_VEL_RE = re.compile(r"(?:^|[_\-\s])(?:v|vel|vl)[_\-]?(\d{1,3})", re.IGNORECASE)


def midi_to_hz(m: float) -> float:
    return 440.0 * 2.0 ** ((m - 69.0) / 12.0)


def hz_to_midi(f: float) -> float:
    return 69.0 + 12.0 * np.log2(max(f, 1e-6) / 440.0)


def parse_note(stem: str) -> int | None:
    """
    Pull a MIDI note number out of a filename. An explicit labeled number
    (n104, note104, midi104) wins when present -- it's unambiguous, unlike a
    bare note letter + octave, where "middle C" varies by convention (C3=60
    vs C4=60) between naming schemes. Falls back to the note letter, assuming
    C3=60, then to a bare number.
    """
    m = _NOTE_LABEL_RE.search(stem)
    if m:
        val = int(m.group(1))
        if 0 <= val <= 127:
            return val
    m = _NOTE_RE.search(stem)
    if m:
        letter, accidental, octave = m.group(1).upper(), m.group(2), int(m.group(3))
        semis = _NOTE_OFFSETS[letter]
        if accidental in ("#", "s"):
            semis += 1
        elif accidental == "b":
            semis -= 1
        return semis + (octave + 2) * 12  # C3 -> 60
    m = _MIDI_RE.search(stem)
    if m:
        val = int(m.group(1))
        if 0 <= val <= 127:
            return val
    return None


def parse_velocity(stem: str) -> int | None:
    m = _VEL_RE.search(stem)
    if m:
        v = int(m.group(1))
        return max(1, min(127, v))
    return None


# --------------------------------------------------------------------------
# analysis primitives
# --------------------------------------------------------------------------

_RAW_SUBTYPES = {16: "PCM_16", 24: "PCM_24", 32: "PCM_32"}


def load(path: Path, raw_rate: int | None = None, raw_bits: int = 16,
         raw_channels: int = 1):
    """
    Return (multichannel float64 array [n, ch], mono analysis signal, sr).

    Headerless PCM (.pcm) has no self-describing format, so raw_rate must be
    given; raw_bits/raw_channels default to the tool's usual 16-bit mono.
    """
    if path.suffix.lower() == ".pcm":
        if raw_rate is None:
            raise ValueError(
                f"{path.name}: headerless PCM needs --raw-rate "
                f"(and --raw-bits/--raw-channels if not 16-bit mono)"
            )
        data, sr = sf.read(
            str(path), samplerate=raw_rate, channels=raw_channels,
            format="RAW", subtype=_RAW_SUBTYPES[raw_bits], endian="LITTLE",
            always_2d=True, dtype="float64",
        )
    else:
        data, sr = sf.read(str(path), always_2d=True, dtype="float64")
    mono = data.mean(axis=1)
    return data, mono, sr


def save_audio(path: Path, data: np.ndarray, sr: int, fmt: str, raw_bits: int = 16) -> None:
    """Write .flac/.wav normally, or headerless raw PCM (fmt == 'pcm') for direct FPGA use."""
    if fmt == "pcm":
        sf.write(str(path), data, sr, subtype=_RAW_SUBTYPES[raw_bits], format="RAW")
    else:
        subtype = "PCM_24" if fmt == "flac" else None
        sf.write(str(path), data, sr, subtype=subtype, format=fmt.upper())


def rms_envelope(x: np.ndarray, sr: int, win_s: float = 0.050, hop_s: float = 0.010):
    """Frame-wise RMS. Returns (times, rms)."""
    win = max(16, int(win_s * sr))
    hop = max(1, int(hop_s * sr))
    n_frames = 1 + max(0, (len(x) - win) // hop)
    if n_frames < 2:
        return np.array([0.0]), np.array([np.sqrt(np.mean(x ** 2) + 1e-20)])
    idx = np.arange(n_frames) * hop
    frames = np.lib.stride_tricks.as_strided(
        x, shape=(n_frames, win), strides=(x.strides[0] * hop, x.strides[0])
    )
    rms = np.sqrt(np.mean(frames ** 2, axis=1) + 1e-20)
    return (idx + win / 2) / sr, rms


def estimate_f0(x: np.ndarray, sr: int, fmin: float = 25.0, fmax: float = 2000.0):
    """Autocorrelation f0 estimate with parabolic peak interpolation."""
    n = min(len(x), int(0.25 * sr))
    if n < 128:
        return None
    seg = x[:n] * np.hanning(n)
    spec = np.fft.rfft(seg, 2 * n)
    ac = np.fft.irfft(np.abs(spec) ** 2)[:n]
    ac /= ac[0] + 1e-20
    lo = max(2, int(sr / fmax))
    hi = min(n - 2, int(sr / fmin))
    if hi <= lo + 2:
        return None
    k = lo + int(np.argmax(ac[lo:hi]))
    a, b, c = ac[k - 1], ac[k], ac[k + 1]
    denom = a - 2 * b + c
    shift = 0.5 * (a - c) / denom if abs(denom) > 1e-12 else 0.0
    return sr / (k + shift)


def estimate_beat_period(times: np.ndarray, rms: np.ndarray,
                         pmin: float = 0.15, pmax: float = 8.0):
    """
    Tine/tonebar beating shows up as periodic ripple on the dB envelope once the
    overall exponential decay is removed. Returns (period_seconds, strength) or
    (None, 0.0).
    """
    if len(times) < 32:
        return None, 0.0
    db = 20.0 * np.log10(rms + 1e-20)
    # fit and remove the linear-in-dB decay trend
    coeffs = np.polyfit(times, db, 1)
    resid = db - np.polyval(coeffs, times)
    resid -= resid.mean()
    if np.std(resid) < 1e-9:
        return None, 0.0
    n = len(resid)
    spec = np.fft.rfft(resid * np.hanning(n), 2 * n)
    ac = np.fft.irfft(np.abs(spec) ** 2)[:n]
    ac /= ac[0] + 1e-20
    dt = float(np.median(np.diff(times)))
    lo = max(2, int(pmin / dt))
    hi = min(n - 2, int(pmax / dt))
    if hi <= lo + 2:
        return None, 0.0
    k = lo + int(np.argmax(ac[lo:hi]))
    return k * dt, float(ac[k])


def fit_decay(times: np.ndarray, rms: np.ndarray, start_s: float = 0.0):
    """
    Fit dB(t) = intercept + slope * t over the region after start_s.
    Returns (slope_db_per_s, t60_seconds).
    """
    mask = times >= start_s
    if mask.sum() < 8:
        mask = np.ones_like(times, dtype=bool)
    if mask.sum() < 2:
        # too little audio (e.g. a near-silent stub) to fit a trend -- a
        # single point can't constrain a line, so assume a fast decay
        return -60.0, 1.0
    db = 20.0 * np.log10(rms[mask] + 1e-20)
    t = times[mask]
    slope, _ = np.polyfit(t, db, 1)
    slope = min(slope, -0.05)  # guard against flat / rising fits
    return float(slope), float(-60.0 / slope)


def rolloff_track(x: np.ndarray, sr: int, pct: float = 0.85,
                  win_s: float = 0.050, hop_s: float = 0.020):
    """Spectral rolloff frequency per frame -- a proxy for perceived brightness."""
    win = max(256, 1 << int(np.ceil(np.log2(win_s * sr))))
    hop = max(1, int(hop_s * sr))
    if len(x) < win + hop:
        return np.array([0.0]), np.array([sr / 4.0])
    n_frames = 1 + (len(x) - win) // hop
    idx = np.arange(n_frames) * hop
    frames = np.lib.stride_tricks.as_strided(
        x, shape=(n_frames, win), strides=(x.strides[0] * hop, x.strides[0])
    ) * np.hanning(win)
    mag = np.abs(np.fft.rfft(frames, axis=1))
    freqs = np.fft.rfftfreq(win, 1.0 / sr)
    csum = np.cumsum(mag, axis=1)
    total = csum[:, -1:] + 1e-20
    k = np.argmax(csum >= pct * total, axis=1)
    return (idx + win / 2) / sr, freqs[k]


def fit_brightness(x: np.ndarray, sr: int, start_s: float, floor_hz: float = 200.0):
    """
    Fit an exponential fall of the rolloff frequency. Returns
    (start_hz, end_hz, halflife_seconds).
    """
    t, ro = rolloff_track(x, sr)
    mask = t >= start_s
    if mask.sum() < 8:
        mask = np.ones_like(t, dtype=bool)
    t, ro = t[mask], np.maximum(ro[mask], floor_hz)
    if len(t) < 2:
        # too little audio to fit a trend -- report it as flat
        flat = float(ro[0])
        return flat, flat, 1.0
    slope, intercept = np.polyfit(t, np.log2(ro), 1)
    slope = min(slope, -1e-4)
    start_hz = float(2 ** (intercept + slope * t[0]))
    end_hz = float(2 ** (intercept + slope * t[-1]))
    halflife = float(-1.0 / slope)
    return start_hz, max(end_hz, floor_hz), halflife


# --------------------------------------------------------------------------
# loop finding
# --------------------------------------------------------------------------

def _norm_corr(a: np.ndarray, b: np.ndarray) -> float:
    na = np.linalg.norm(a)
    nb = np.linalg.norm(b)
    if na < 1e-12 or nb < 1e-12:
        return -1.0
    return float(np.dot(a, b) / (na * nb))


def _zero_crossings_near(x: np.ndarray, center: int, radius: int) -> np.ndarray:
    """Indices i in [center-radius, center+radius] where sign(x[i]) != sign(x[i+1])."""
    lo = max(0, center - radius)
    hi = min(len(x) - 2, center + radius)
    if hi <= lo:
        return np.array([], dtype=int)
    seg = np.sign(x[lo:hi + 2])
    seg[seg == 0] = 1.0
    return lo + np.where(np.diff(seg) != 0)[0]


@dataclass
class LoopResult:
    loop_start: int
    loop_end: int
    score: float
    length_s: float
    periods: float


def find_loop(mono: np.ndarray, sr: int, period: float,
              loop_start_s: float, min_len_s: float, max_len_s: float) -> LoopResult | None:
    """
    Find a short, click-free loop: a same-direction pair of zero crossings
    an integer number of pitch periods apart, so [loop_start:loop_end) can
    be duplicated with no crossfade -- both edges are genuine zero samples
    from the recording, not blended, so there's nothing to click.

    Score is the normalised correlation between one pitch period starting
    at loop_start and one starting at loop_end: both landing near zero
    isn't enough on its own (every cycle crosses zero twice), this checks
    the waveform actually repeats at that spacing, not just that the two
    samples happen to be small.
    """
    period_n = max(2, int(round(period * sr)))
    ls_target = int(loop_start_s * sr)
    n_lo = max(1, int(round(min_len_s * sr / period_n)))
    n_hi = max(n_lo, int(round(max_len_s * sr / period_n)))
    radius = max(1, period_n // 2)
    cmp_w = period_n

    start_candidates = _zero_crossings_near(mono, ls_target, radius)
    if start_candidates.size == 0:
        return None

    best = None  # (score, start, end, periods)
    for s in start_candidates:
        if s + cmp_w >= len(mono):
            continue
        s_dir = 1.0 if mono[s + 1] > mono[s] else -1.0
        for n in range(n_lo, n_hi + 1):
            target_e = s + n * period_n
            if target_e + cmp_w >= len(mono):
                break
            for e in _zero_crossings_near(mono, target_e, radius):
                if e <= s or e + cmp_w >= len(mono):
                    continue
                e_dir = 1.0 if mono[e + 1] > mono[e] else -1.0
                if e_dir != s_dir:
                    continue
                score = _norm_corr(mono[s:s + cmp_w], mono[e:e + cmp_w])
                if best is None or score > best[0]:
                    best = (score, int(s), int(e), float(n))

    if best is None:
        return None
    score, s, e, n = best
    return LoopResult(s, e, score, (e - s) / sr, n)


def render_hold(data: np.ndarray, loop: LoopResult, sr: int,
                decay_db_per_s: float, target_s: float,
                floor_db: float = -60.0) -> np.ndarray:
    """
    Bake a full-length held note out of a short, zero-crossing-aligned loop
    cycle: natural audio up to loop_start, then [loop_start:loop_end)
    duplicated with no crossfade out to target_s.

    find_loop only returns cycles bounded by real zero-crossing samples in
    matching directions, so the duplicated edges are already continuous --
    no blending needed, unlike a loop point picked without that constraint.
    The cycle is also short enough (a handful to a few dozen pitch periods)
    that it has no measurable decay or brightness change across its own
    length, so unlike a longer loop there's no within-cycle drift to
    compensate and no spectral shaping needed either: a plain volume ramp
    over the repeats is enough to match the real recording's decay.
    """
    ls, le = loop.loop_start, loop.loop_end
    cycle = data[ls:le]

    head = data[:ls].copy()
    target_n = int(target_s * sr)
    if target_n <= len(head):
        return head[:target_n]

    reps = -(-(target_n - len(head)) // len(cycle))  # ceil div
    tail = np.tile(cycle, (reps, 1))[: target_n - len(head)]

    tail_t = (np.arange(len(tail)) + 1) / sr
    floor_gain = 10.0 ** (floor_db / 20.0)
    env = np.maximum(10.0 ** (decay_db_per_s * tail_t / 20.0), floor_gain)
    tail = tail * env[:, None]

    return np.concatenate([head, tail], axis=0)


# --------------------------------------------------------------------------
# per-file driver
# --------------------------------------------------------------------------

@dataclass
class Analysis:
    path: str
    sr: int
    channels: int
    duration_s: float
    midi_note: int | None
    velocity: int | None
    f0_hz: float | None
    peak_time_s: float
    beat_period_s: float | None
    beat_strength: float
    decay_db_per_s: float
    t60_s: float
    bright_start_hz: float
    bright_end_hz: float
    bright_halflife_s: float
    loop: dict | None = None
    out_file: str | None = None
    preview_file: str | None = None
    size_ratio: float | None = None


def analyse_file(path: Path, args) -> Analysis:
    data, mono, sr = load(path, args.raw_rate, args.raw_bits, args.raw_channels)
    dur = len(mono) / sr

    stem = path.stem
    note = parse_note(stem)
    vel = parse_velocity(stem)

    peak_i = int(np.argmax(np.abs(mono)))
    peak_t = peak_i / sr

    # settle past the attack transient before measuring anything steady
    settle_t = min(peak_t + args.settle, dur * 0.5)

    f0 = midi_to_hz(note) if note is not None else estimate_f0(mono[peak_i:], sr)
    if f0 is None or not (20.0 <= f0 <= 4000.0):
        f0 = estimate_f0(mono[peak_i:], sr) or 220.0

    times, rms = rms_envelope(mono, sr)
    beat_p, beat_str = estimate_beat_period(
        times[times >= settle_t], rms[times >= settle_t]
    )
    if beat_str < args.beat_threshold:
        beat_p = None

    slope, t60 = fit_decay(times, rms, settle_t)
    b_start, b_end, b_half = fit_brightness(mono, sr, settle_t)

    return Analysis(
        path=str(path), sr=sr, channels=data.shape[1], duration_s=dur,
        midi_note=note, velocity=vel, f0_hz=float(f0), peak_time_s=peak_t,
        beat_period_s=beat_p, beat_strength=beat_str,
        decay_db_per_s=slope, t60_s=t60,
        bright_start_hz=b_start, bright_end_hz=b_end, bright_halflife_s=b_half,
    )


def process_file(path: Path, out_dir: Path, args) -> Analysis:
    an = analyse_file(path, args)
    data, mono, sr = load(path, args.raw_rate, args.raw_bits, args.raw_channels)

    settle_t = min(an.peak_time_s + args.settle, an.duration_s * 0.5)
    loop_start_s = max(settle_t, args.loop_start)

    loop = find_loop(
        mono, sr, period=1.0 / an.f0_hz, loop_start_s=loop_start_s,
        min_len_s=args.min_loop, max_len_s=args.max_loop,
    )

    out_path = out_dir / (path.stem + "." + args.format)
    out_dir.mkdir(parents=True, exist_ok=True)

    if loop is None or loop.score < args.min_score:
        # not loopable at these settings -- keep the natural recording as-is
        trimmed = data
        loop_meta = None
    else:
        # cut right at loop_end: loop_start/loop_end go in the SFZ and the
        # engine repeats that span at playback, no crossfade needed since
        # find_loop only returns zero-crossing-aligned, click-free cycles
        trimmed = data[:loop.loop_end]
        loop_meta = asdict(loop)

    save_audio(out_path, trimmed, sr, args.format, args.raw_bits)
    an.loop = loop_meta
    an.out_file = out_path.name
    an.size_ratio = out_path.stat().st_size / path.stat().st_size

    if args.preview_dir and loop_meta is not None:
        # a full-length baked render purely for auditioning by ear -- always
        # in a directly-playable format regardless of --format, since a raw
        # PCM --format (e.g. for FPGA use) wouldn't open in a media player
        args.preview_dir.mkdir(parents=True, exist_ok=True)
        preview_path = args.preview_dir / (path.stem + "." + args.preview_format)
        target_s = args.hold if args.hold else an.duration_s
        preview = render_hold(data, loop, sr, an.decay_db_per_s, target_s)
        save_audio(preview_path, preview, sr, args.preview_format)
        an.preview_file = preview_path.name

    return an


# --------------------------------------------------------------------------
# SFZ output
# --------------------------------------------------------------------------

def write_sfz(analyses: list[Analysis], sfz_path: Path, sample_dir: str):
    """
    One region per file. Key ranges are split midway between adjacent sampled
    notes; velocity ranges are split midway between adjacent layers.
    """
    usable = [a for a in analyses if a.midi_note is not None and a.out_file]
    if not usable:
        print("No regions with a resolvable root note; skipping SFZ.", file=sys.stderr)
        return

    notes = sorted({a.midi_note for a in usable})
    lo_hi: dict[int, tuple[int, int]] = {}
    for i, n in enumerate(notes):
        lo = 0 if i == 0 else (notes[i - 1] + n) // 2 + 1
        hi = 127 if i == len(notes) - 1 else (n + notes[i + 1]) // 2
        lo_hi[n] = (lo, hi)

    lines = [
        "// generated by rhodes_loop_tool.py",
        "// samples are cut at loop_end; the engine repeats loop_start:loop_end",
        "// at playback. find_loop only returns short, zero-crossing-aligned,",
        "// same-direction cycles, so the wrap is click-free with no crossfade",
        "// opcode needed -- ampeg_decay/ampeg_sustain=0 shape the continuing",
        "// decay, since a raw loop alone would hold at a constant level.",
        "<control>",
        f"default_path={sample_dir}/",
        "",
        "<global>",
        "ampeg_attack=0.001",
        "ampeg_release=0.30",
        "",
    ]

    by_note: dict[int, list[Analysis]] = {}
    for a in usable:
        by_note.setdefault(a.midi_note, []).append(a)

    for note in notes:
        group = sorted(by_note[note], key=lambda a: (a.velocity or 127))
        vels = [a.velocity or 127 for a in group]
        lines.append(f"<group> // note {note}")
        for i, a in enumerate(group):
            vlo = 1 if i == 0 else (vels[i - 1] + vels[i]) // 2 + 1
            vhi = 127 if i == len(group) - 1 else (vels[i] + vels[i + 1]) // 2
            klo, khi = lo_hi[note]

            lines.append("<region>")
            lines.append(f"sample={a.out_file}")
            lines.append(f"lokey={klo} hikey={khi} pitch_keycenter={note}")
            lines.append(f"lovel={vlo} hivel={vhi}")

            if a.loop:
                lines.append("loop_mode=loop_sustain")
                lines.append(f"loop_start={a.loop['loop_start']}")
                lines.append(f"loop_end={a.loop['loop_end'] - 1}")
                lines.append("ampeg_sustain=0")
                lines.append(f"ampeg_decay={a.t60_s:.3f}")
            else:
                lines.append("loop_mode=no_loop")
            lines.append("")
        lines.append("")

    sfz_path.write_text("\n".join(lines))
    print(f"wrote {sfz_path} ({len(usable)} regions)")


# --------------------------------------------------------------------------
# cli
# --------------------------------------------------------------------------

def gather(in_dir: Path) -> list[Path]:
    exts = {".wav", ".aif", ".aiff", ".flac", ".pcm"}
    return sorted(p for p in in_dir.rglob("*") if p.suffix.lower() in exts)


def main(argv=None):
    p = argparse.ArgumentParser(description=__doc__,
                                formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("mode", choices=["analyse", "process"])
    p.add_argument("in_dir", type=Path)
    p.add_argument("out_dir", type=Path, nargs="?")
    p.add_argument("--settle", type=float, default=0.35,
                   help="seconds after the peak before measurements begin")
    p.add_argument("--loop-start", dest="loop_start", type=float, default=1.0,
                   help="earliest loop start, seconds")
    p.add_argument("--min-loop", type=float, default=0.005,
                   help="shortest loop to search for, seconds -- a handful of "
                        "pitch periods (default: 5ms)")
    p.add_argument("--max-loop", type=float, default=0.3,
                   help="longest loop to search for, seconds (default: 300ms)")
    p.add_argument("--hold", type=float, default=None,
                   help="seconds of held note to render past the attack in "
                        "--preview-dir files (default: match the original "
                        "recording's own duration)")
    p.add_argument("--preview-dir", type=Path, default=None,
                   help="also write full-length baked-hold renders here for "
                        "auditioning by ear -- OUT_DIR itself only gets the "
                        "short, loop-point-tagged files the SFZ actually uses")
    p.add_argument("--min-score", type=float, default=0.5,
                   help="reject loops below this correlation")
    p.add_argument("--beat-threshold", type=float, default=0.25,
                   help="min envelope autocorrelation to trust a beat period")
    p.add_argument("--raw-rate", type=int, default=None,
                   help="sample rate for headerless .pcm input (required to read .pcm files)")
    p.add_argument("--raw-bits", type=int, default=16, choices=[16, 24, 32],
                   help="bit depth for headerless .pcm input and output (default 16)")
    p.add_argument("--raw-channels", type=int, default=1,
                   help="channel count for headerless .pcm input (default 1)")
    p.add_argument("--format", default="flac", choices=["flac", "wav", "pcm"],
                   help="OUT_DIR sample format. pcm writes headerless raw PCM "
                        "(interleaved, --raw-bits, little-endian) for direct use "
                        "outside a soundfile-aware player, e.g. an FPGA")
    p.add_argument("--preview-format", default="wav", choices=["flac", "wav"],
                   help="--preview-dir format -- always directly playable, "
                        "regardless of --format (default wav)")
    p.add_argument("--sfz", type=Path)
    p.add_argument("--report", type=Path)
    args = p.parse_args(argv)

    files = gather(args.in_dir)
    if not files:
        print(f"no audio found in {args.in_dir}", file=sys.stderr)
        return 1
    if args.raw_rate is None and any(f.suffix.lower() == ".pcm" for f in files):
        print("found headerless .pcm input -- pass --raw-rate (and --raw-bits/"
              "--raw-channels if not 16-bit mono) to read it", file=sys.stderr)
        return 1

    results: list[Analysis] = []
    for f in files:
        try:
            if args.mode == "analyse":
                a = analyse_file(f, args)
                beat = f"{a.beat_period_s:.2f}s" if a.beat_period_s else "none"
                print(f"{f.name:40s} f0={a.f0_hz:7.2f}Hz  T60={a.t60_s:6.2f}s  "
                      f"beat={beat:>7s} ({a.beat_strength:.2f})  "
                      f"bright {a.bright_start_hz:6.0f}->{a.bright_end_hz:5.0f}Hz")
            else:
                if args.out_dir is None:
                    print("process mode needs OUT_DIR", file=sys.stderr)
                    return 1
                a = process_file(f, args.out_dir, args)
                if a.loop:
                    print(f"{f.name:40s} loop {a.loop['length_s']*1000:.1f}ms  "
                          f"({a.loop['periods']:.0f} periods)  "
                          f"score={a.loop['score']:.3f}  "
                          f"size={a.size_ratio:.1%}")
                else:
                    print(f"{f.name:40s} NO LOOP (kept full)  size={a.size_ratio:.1%}")
            results.append(a)
        except Exception as exc:  # keep going through the library
            print(f"{f.name}: {type(exc).__name__}: {exc}", file=sys.stderr)

    if args.mode == "process":
        total_in = sum(Path(a.path).stat().st_size for a in results)
        total_out = sum((args.out_dir / a.out_file).stat().st_size
                        for a in results if a.out_file)
        print(f"\ntotal: {total_in/1e6:.1f} MB -> {total_out/1e6:.1f} MB "
              f"({total_out/total_in:.1%})")
        if args.sfz:
            write_sfz(results, args.sfz, args.out_dir.name)

    if args.report:
        args.report.write_text(json.dumps([asdict(a) for a in results], indent=2))
        print(f"wrote {args.report}")

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
