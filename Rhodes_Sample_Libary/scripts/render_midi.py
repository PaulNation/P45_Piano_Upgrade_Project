#!/usr/bin/env python3
"""
render_midi.py
Plays a MIDI file through the sample library the way the FPGA engine is planned to, so
it can be heard before the hardware exists. It uses the same data the FPGA uses:
library/sustains + library/releases (bit-identical to flash_image.bin) and the ROM
tables in ../RTL/.../Sample_Decoder/tables (velocity_layer, release_gain, db_to_lin, fade).

Behaviour (NOTES.md, "88-voice top-level plan" and items 6-8):
  note-on    velocity -> (layer, gain code) from velocity_layer.mem; the sustain starts
             at gain db_to_lin[code]. A key that is still sounding is first released
             (re-strike = note-off + note-on, as Keyscape does).
  note-off   sustain fades with fade.mem (9 ms) and the release sample of the same
             key/layer starts, at gain db_to_lin[vel_code + hold_code - 12], where
             hold_code comes from release_gain.mem at the samples held since note-on.
  pedal      CC64 >= 64 = down: note-offs are deferred while it is down; pedal up
             releases every key that is no longer held. (Pedal sounds and half-pedal
             are not modelled.)
  end        a sustain that reaches the end of its file just stops (4 ms fade in file).
Output: 16-bit 44.1 kHz WAV, same signal on both channels, clipped at full scale (the
script prints the peak and how many samples clipped; --gain-db lowers the mix).

Usage (from the Rhodes_Sample_Libary folder):
    venv/bin/python scripts/render_midi.py "midi/Test midi.mid"        -> previews/midi/<name>.wav
    venv/bin/python scripts/render_midi.py song.mid -o out.wav --gain-db -6
"""
import argparse
import os
import struct
import sys

import numpy as np
import soundfile as sf

SR = 44100
LAYERS = (16, 48, 64, 80, 112)
NAMES = ["C", "Cs", "D", "Ds", "E", "F", "Fs", "G", "Gs", "A", "As", "B"]
TABLES = "../RTL/CPLD_P45_I2S_AUDIO_GENERATOR/src/Sample_Decoder/tables"
MUTE = 255


# ---------------------------------------------------------------- MIDI file reader
def read_midi(path: str):
    """Returns a time-sorted list of (seconds, status, data1, data2), tempo map applied."""
    d = open(path, "rb").read()
    if d[:4] != b"MThd":
        sys.exit("not a MIDI file")
    _, ntrk, div = struct.unpack(">HHH", d[8:14])
    if div & 0x8000:
        sys.exit("SMPTE time division is not supported")
    pos, events, tempos = 8 + struct.unpack(">I", d[4:8])[0], [], []
    for _ in range(ntrk):
        assert d[pos:pos + 4] == b"MTrk"
        end = pos + 8 + struct.unpack(">I", d[pos + 4:pos + 8])[0]
        p, tick, run = pos + 8, 0, 0
        while p < end:
            v = 0
            while True:
                b = d[p]; p += 1
                v = (v << 7) | (b & 0x7F)
                if b < 0x80:
                    break
            tick += v
            st = d[p]
            if st == 0xFF:                                   # meta
                typ, p = d[p + 1], p + 2
                ln = 0
                while True:
                    b = d[p]; p += 1
                    ln = (ln << 7) | (b & 0x7F)
                    if b < 0x80:
                        break
                if typ == 0x51:
                    tempos.append((tick, int.from_bytes(d[p:p + 3], "big")))
                p += ln
                continue
            if st in (0xF0, 0xF7):                           # sysex
                p += 1
                ln = 0
                while True:
                    b = d[p]; p += 1
                    ln = (ln << 7) | (b & 0x7F)
                    if b < 0x80:
                        break
                p += ln
                continue
            if st & 0x80:
                run, p = st, p + 1
            else:
                st = run
            n = 1 if (st & 0xF0) in (0xC0, 0xD0) else 2
            data = d[p:p + n]; p += n
            events.append((tick, st & 0xF0, data[0], data[1] if n == 2 else 0))
        pos = end
    tempos = sorted(tempos) or [(0, 500000)]
    if tempos[0][0] != 0:
        tempos.insert(0, (0, 500000))

    def secs(t):
        s, last_t, last_us = 0.0, 0, tempos[0][1]
        for tt, us in tempos:
            if tt > t:
                break
            s += (tt - last_t) * last_us / div / 1e6
            last_t, last_us = tt, us
        return s + (t - last_t) * last_us / div / 1e6
    # note-offs before note-ons at the same tick (re-strike = off + on)
    order = {0x80: 0, 0xB0: 1, 0x90: 2}
    return [(secs(t), st, a, b) for t, st, a, b in
            sorted(events, key=lambda e: (e[0], order.get(e[1], 3) if not (e[1] == 0x90 and e[3] == 0) else 0))]


# ---------------------------------------------------------------- engine
def mem(name):
    return [int(l, 16) for l in open(os.path.join(TABLES, name)) if l.strip()]


def main() -> int:
    ap = argparse.ArgumentParser(description="Render a MIDI file with the FPGA sample engine model")
    ap.add_argument("midi")
    ap.add_argument("-o", "--out", default=None, help="default previews/midi/<midi name>.wav")
    ap.add_argument("--gain-db", type=float, default=0.0, help="master gain before the 16-bit clip")
    ap.add_argument("--library", default="library")
    args = ap.parse_args()

    vel_tab, rel_tab, lin, fade = (mem(n) for n in ("velocity_layer.mem", "release_gain.mem",
                                                    "db_to_lin.mem", "fade.mem"))
    lin = np.array(lin) / 16384.0
    fade = np.array(fade) / 32768.0
    cache = {}

    def load(n, li, kind):
        k = (n, li, kind)
        if k not in cache:
            f = os.path.join(args.library, "sustains" if kind == "sus" else "releases",
                             f"rhodes_{NAMES[n % 12]}{n // 12 - 1}_n{n:03d}_v{LAYERS[li]:03d}_{kind}.pcm")
            cache[k] = np.fromfile(f, "<i2").astype(np.float64) if os.path.exists(f) else np.zeros(0)
        return cache[k]

    def hold_code(key, li, held):                    # make_fpga_tables.py player lookup
        base = (key * 5 + li) * 8
        if held < 2 ** 13:
            return rel_tab[base]
        top = held.bit_length() - 1
        slot = top - 13
        if slot >= 8:
            return MUTE
        frac = (held - 2 ** top) / 2 ** top
        c0 = rel_tab[base + slot]
        c1 = rel_tab[base + slot + 1] if slot < 7 else MUTE
        c0, c1 = min(c0, MUTE - 1), min(c1, MUTE - 1)
        return int(round(c0 + frac * (c1 - c0)))

    events = read_midi(args.midi)
    end_s = (events[-1][0] if events else 0) + 2.0
    out = np.zeros(int(end_s * SR) + SR)
    voices = {}                  # note -> dict(start, li, vcode, held, pedal_held)
    pedal = False
    stats = {"notes": 0, "restrikes": 0, "releases": 0}

    def note_off(n, t):
        v = voices.pop(n)
        key, li = n - 21, v["li"]
        held = t - v["start"]
        sus = load(n, li, "sus")
        g = lin[v["vcode"]]
        seg = sus[:held + len(fade)].copy()                       # sustain until note-off ...
        k = min(len(fade), max(0, len(seg) - held))
        seg[held:held + k] *= fade[:k]                            # ... then the 9 ms fade
        out[v["start"]:v["start"] + len(seg)] += seg * g
        hc = hold_code(key, li, held)
        code = MUTE if MUTE in (hc, v["vcode"]) else max(0, min(MUTE - 1, v["vcode"] + hc - 12))
        rel = load(n, li, "rel")
        if code != MUTE and len(rel):
            out[t:t + len(rel)] += rel * lin[code]
            stats["releases"] += 1

    for ts, st, a, b in events:
        t = int(round(ts * SR))
        if st == 0x90 and b > 0 and 21 <= a <= 108:
            if a in voices:
                note_off(a, t)
                stats["restrikes"] += 1
            w = vel_tab[(a - 21) * 128 + b]
            voices[a] = {"start": t, "li": w >> 8, "vcode": w & 0xFF, "held": True}
            stats["notes"] += 1
        elif (st == 0x80 or (st == 0x90 and b == 0)) and a in voices:
            if pedal:
                voices[a]["held"] = False
            else:
                note_off(a, t)
        elif st == 0xB0 and a == 64:
            down = b >= 64
            if pedal and not down:
                for n in [n for n, v in voices.items() if not v["held"]]:
                    note_off(n, t)
            pedal = down
    for n in list(voices):                                       # still sounding at the end
        v = voices.pop(n)
        sus = load(n, v["li"], "sus")
        out[v["start"]:v["start"] + len(sus)] += sus * lin[v["vcode"]]

    nz = np.flatnonzero(out)
    out = out[:nz[-1] + SR // 2] if nz.size else out[:SR]
    out *= 10 ** (args.gain_db / 20)
    peak = np.abs(out).max()
    clipped = int(np.sum(np.abs(out) > 32767))
    pcm = np.clip(np.round(out), -32768, 32767).astype("<i2")
    path = args.out or os.path.join("previews", "midi", os.path.splitext(os.path.basename(args.midi))[0] + ".wav")
    os.makedirs(os.path.dirname(path) or ".", exist_ok=True)
    sf.write(path, np.stack([pcm, pcm], axis=1), SR, subtype="PCM_16")
    print(f"wrote {path}: {len(pcm) / SR:.1f} s, {stats['notes']} notes, {stats['restrikes']} re-strikes, "
          f"{stats['releases']} releases")
    print(f"mix peak {20 * np.log10(peak / 32768 + 1e-12):+.1f} dBFS"
          + (f", {clipped} samples clipped (try --gain-db {-20 * np.log10(peak / 32767) - 0.5:.1f})"
             if clipped else ", no clipping"))
    return 0


if __name__ == "__main__":
    sys.exit(main())
