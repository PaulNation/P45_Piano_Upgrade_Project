#!/usr/bin/env python3
"""
make_fpga_tables.py
Writes the release-path ROM contents as $readmemh files for the FPGA (block RAM /
LUT ROM initialised at synthesis), so none of these tables live in the sample flash.

  release_gain.mem   3520 x 8 bit   release gain vs time held, per key and layer
                     address = ((key * 5) + layer) * 8 + slot
                       key   0..87  (MIDI note - 21)
                       layer 0..4   (v016, v048, v064, v080, v112)
                       slot  0..7   gain at a held time of 2^(13+slot) samples
                                    (0.186, 0.372, 0.743, 1.49, 2.97, 5.94, 11.9, 23.8 s)
                     code  = attenuation in 0.5 dB steps from +6 dB: gain_dB = 6 - code/2
                             (code 12 = 0 dB); 255 = mute
  db_to_lin.mem      256 x 16 bit   code -> linear gain, Q2.14 (16384 = 1.0); entry 255 = 0
  fade.mem           512 x 16 bit   sustain fade after note-off, one entry per sample
                                    (44.1 kHz), Q1.15 (32768 = 1.0); entries past the
                                    fade are 0

Player at note-off (once per note, time-shared):
  n     = samples since note-on (held-time counter)
  slot  = position of n's top bit - 13, clamped to 0..7 (n < 8192 -> slot 0, fraction 0;
          n >= 2^21 -> mute)
  frac  = the bits of n below its top bit, i.e. (n - 2^(13+slot)) / 2^(13+slot)
  code  = c[slot] + frac * (c[slot+1] - c[slot])   (linear in dB; slot 7 has no successor:
          past 2^20 samples, ramp to mute at 2^21)
  release gain = db_to_lin[code] x the voice's normal velocity gain
The sustain's gain after note-off is fade[k] for k samples, then the sustain voice is
freed. The release voice starts at note-off.

Source data: data/release_gain_table.json (make_release_gain_table.py) and
extract_releases.FADE_TABLE (measured, gain per ms). The JSON's holds (0.203 ... 12.97 s)
are resampled to the power-of-two slots by interpolating in dB over log2(time).

Usage (from the Rhodes_Sample_Libary folder):
    venv/bin/python scripts/make_fpga_tables.py   [-o ../RTL/CPLD_P45_I2S_AUDIO_GENERATOR/src/Sample_Decoder/tables]
"""

import argparse
import json
import math
import os
import sys

import numpy as np

from extract_releases import FADE_TABLE

SR = 44100
LAYERS = ("v016", "v048", "v064", "v080", "v112")
SLOT0_LOG2 = 13                    # slot k <-> 2^(13+k) samples
SLOTS = 8
TOP_DB = 6.0                       # code 0
MUTE_CODE = 255
FADE_LEN = 512


def gain_code(gdb: float) -> int:
    if gdb <= -100.0:
        return MUTE_CODE
    return int(min(MUTE_CODE - 1, max(0, round((TOP_DB - gdb) * 2))))


def code_db(code: int) -> float:
    return -1e9 if code == MUTE_CODE else TOP_DB - code / 2.0


def main() -> int:
    ap = argparse.ArgumentParser(description="FPGA ROM init files for the release path")
    ap.add_argument("--table", default="data/release_gain_table.json")
    ap.add_argument("-o", "--out", default="../RTL/CPLD_P45_I2S_AUDIO_GENERATOR/src/Sample_Decoder/tables")
    args = ap.parse_args()

    t = json.load(open(args.table))
    holds = np.array(t["hold_s"], dtype=float)
    mute = t["mute_db"]
    os.makedirs(args.out, exist_ok=True)

    # 1. Release gain: resample each key/layer row onto the power-of-two slots
    slot_s = np.array([2.0 ** (SLOT0_LOG2 + k) / SR for k in range(SLOTS)])
    pos = holds[1:]                                     # skip hold 0 (log of 0)
    codes = []
    for key in range(88):
        for lay in LAYERS:
            row = np.array(t["layers"][lay][key][1:], dtype=float)
            for s in slot_s:
                if s > pos[-1] * 1.5:                     # well past the last measured hold
                    g = mute
                else:
                    g = float(np.interp(math.log2(s), np.log2(pos), row))
                codes.append(gain_code(g))
    with open(os.path.join(args.out, "release_gain.mem"), "w") as f:
        f.write("".join(f"{c:02X}\n" for c in codes))

    # 2. dB code -> linear, Q2.14
    lin = [0 if c == MUTE_CODE else int(round(10 ** (code_db(c) / 20.0) * 16384)) for c in range(256)]
    assert max(lin) < 65536
    with open(os.path.join(args.out, "db_to_lin.mem"), "w") as f:
        f.write("".join(f"{v:04X}\n" for v in lin))

    # 3. Fade, one entry per sample, Q1.15 (32768 = 1.0)
    ms = np.arange(FADE_LEN) / SR * 1000.0
    fade = np.interp(ms, np.arange(len(FADE_TABLE)), FADE_TABLE, right=0.0)
    fq = [int(round(v * 32768)) for v in fade]
    with open(os.path.join(args.out, "fade.mem"), "w") as f:
        f.write("".join(f"{v:04X}\n" for v in fq))

    # 4. Check: the player's lookup (as described above) vs the JSON table at its own holds
    def player_db(key, lay, n):
        base = (key * 5 + LAYERS.index(lay)) * SLOTS
        if n < 2 ** SLOT0_LOG2:
            return code_db(codes[base])
        top = n.bit_length() - 1
        slot = top - SLOT0_LOG2
        if slot >= SLOTS:
            return -1e9
        frac = (n - 2 ** top) / 2 ** top
        c0 = codes[base + slot]
        c1 = codes[base + slot + 1] if slot + 1 < SLOTS else MUTE_CODE
        if MUTE_CODE in (c0, c1):                       # ramp toward mute in dB
            c0 = min(c0, MUTE_CODE - 1)
            c1 = min(c1, MUTE_CODE - 1) if c1 != MUTE_CODE else MUTE_CODE - 1
        return code_db(int(round(c0 + frac * (c1 - c0))))
    err = []
    for key in range(88):
        for lay in LAYERS:
            for h, g in zip(holds[1:], t["layers"][lay][key][1:]):
                if g > -40:
                    err.append(player_db(key, lay, int(h * SR)) - g)
    err = np.array(err)

    print(f"wrote {args.out}/release_gain.mem ({len(codes)} x 8 bit), db_to_lin.mem (256 x 16), "
          f"fade.mem ({FADE_LEN} x 16)")
    print(f"slots: " + ", ".join(f"{s:.3f}" for s in slot_s) + " s")
    print(f"player lookup vs table at the measured holds (gains above -40 dB): "
          f"rms {np.sqrt(np.mean(err ** 2)):.2f} dB, max |err| {np.abs(err).max():.2f} dB")
    print(f"fade: {sum(1 for v in fq if v > 0)} non-zero samples ({sum(1 for v in fq if v > 0) / SR * 1000:.1f} ms)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
