#!/usr/bin/env python3
"""
make_velocity_curve.py
Writes src/Key_Events/velocity_curve.mem: the M1->M2 time -> MIDI velocity curve used by
key_event_gen.v (512 x 7 bit, $readmemh).

ROM index (from key_event_gen.v): idx = {msb (5 bit), mant (4 bit)} where msb is the
position of the top set bit of the elapsed time in microseconds and mant the 4 bits
below it, so idx covers t = 2^msb * (1 + mant/16) us, 16 steps per doubling of time.

Curve: velocity 127 at --fast-ms or faster, 1 at --slow-ms or slower, and in between
  v = 1 + 126 * (1 - x) ** gamma,   x = log(t / fast) / log(slow / fast)
(gamma 1 = straight line in log time; > 1 = more of the range at the soft end).

The default --fast-ms / --slow-ms are PLACEHOLDERS: measure the real M1->M2 times of
the P45 action (fastest and softest playable strike) and regenerate:
    python3 tools/make_velocity_curve.py --fast-ms 2.0 --slow-ms 80 --gamma 1.0
"""
import argparse
import math
import os

ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
ap.add_argument("--fast-ms", type=float, default=1.5, help="M1->M2 time that gives velocity 127")
ap.add_argument("--slow-ms", type=float, default=60.0, help="M1->M2 time that gives velocity 1")
ap.add_argument("--gamma", type=float, default=1.0)
ap.add_argument("-o", "--out", default=os.path.join(os.path.dirname(__file__), "..", "src", "Key_Events",
                                                       "velocity_curve.mem"))
args = ap.parse_args()

fast, slow = args.fast_ms * 1000.0, args.slow_ms * 1000.0
vals = []
for idx in range(512):
    msb, mant = idx >> 4, idx & 15
    if msb > 16:
        vals.append(1)
        continue
    t = (2 ** msb) * (1 + (mant + 0.5) / 16)          # middle of the bin, in us
    if t <= fast:
        v = 127
    elif t >= slow:
        v = 1
    else:
        x = math.log(t / fast) / math.log(slow / fast)
        v = 1 + 126 * (1 - x) ** args.gamma
    vals.append(max(1, min(127, int(round(v)))))
with open(args.out, "w") as f:
    f.write("".join(f"{v:02X}\n" for v in vals))
print(f"wrote {os.path.normpath(args.out)}: 127 at <= {args.fast_ms} ms, 1 at >= {args.slow_ms} ms, gamma {args.gamma}")
for ms in (0.5, 1, 1.5, 2, 3, 5, 8, 12, 20, 30, 45, 60, 80):
    t = ms * 1000
    msb = int(t).bit_length() - 1
    mant = ((int(t) << 4) >> msb) & 15 if msb >= 0 else 0
    print(f"  {ms:5.1f} ms -> velocity {vals[(msb << 4) | mant]}")
