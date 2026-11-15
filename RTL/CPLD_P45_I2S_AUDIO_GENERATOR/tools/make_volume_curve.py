#!/usr/bin/env python3
"""
make_volume_curve.py
Writes src/Voice/volume_curve.mem: master volume (MIDI CC7 value 0..127, from the volume pot)
-> linear gain, Q2.14 (16384 = 0 dB), 128 x 16 bit, $readmemh.

  value 0       mute
  value 1..127  straight line in dB from --min-db up to --max-db (default -60 .. 0 dB)

If the pot is a linear-taper pot, this dB curve makes it feel like an audio (log) pot. For a
log-taper pot use --gamma > 1 to compress the top of the range, or change the mapping here.
    python3 tools/make_volume_curve.py [--min-db -60] [--max-db 0] [--gamma 1.0]
"""
import argparse
import os

ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
ap.add_argument("--min-db", type=float, default=-60.0)
ap.add_argument("--max-db", type=float, default=0.0, help="at most +6 dB (Q2.14 limit)")
ap.add_argument("--gamma", type=float, default=1.0)
ap.add_argument("-o", "--out", default=os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "src",
                                                       "Voice", "volume_curve.mem"))
args = ap.parse_args()
vals = [0]
for v in range(1, 128):
    x = ((v - 1) / 126.0) ** args.gamma
    db = args.min_db + (args.max_db - args.min_db) * x
    vals.append(min(65535, int(round(16384 * 10 ** (db / 20.0)))))
open(args.out, "w").write("".join(f"{g:04X}\n" for g in vals))
print(f"wrote {os.path.normpath(args.out)}: 0 = mute, 1 = {args.min_db} dB, 127 = {args.max_db} dB "
      f"(127 -> {vals[127]}, 64 -> {vals[64]})")
