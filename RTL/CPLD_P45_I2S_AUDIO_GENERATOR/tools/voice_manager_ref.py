#!/usr/bin/env python3
"""
voice_manager_ref.py
Bit-exact reference model of src/Voice/voice_manager.v, plus vectors for its testbench.

  python3 tools/voice_manager_ref.py gen     # writes tb/vectors/vm_events.hex + vm_expected.txt
  python3 tools/voice_manager_ref.py check sim/verilator/vm_writes.txt

gen: a random but reproducible performance (seed 1): note-ons at random velocities, note-offs,
re-strikes of sounding keys, sustain pedal down/up with keys released under it, holds from a
few ms to ~30 s (all release-gain slots and the mute region), enough releases to wrap the
32-voice release ring several times.
Events file: one 48-bit word per line = {time in samples (32 bit), event (16 bit)}.
Expected file: every voice-RAM write in order, "slot data" (hex).
"""
import os
import random
import sys

ROOT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..")
TABLES = os.path.join(ROOT, "src", "Sample_Decoder", "tables")
VEC = os.path.join(ROOT, "tb", "vectors")
MUTE = 255
RELEASE_BASE = 440
NUM_REL = 32


def mem(name):
    return [int(l, 16) for l in open(os.path.join(TABLES, name)) if l.strip()]


VEL, REL, LIN = mem("velocity_layer.mem"), mem("release_gain.mem"), mem("db_to_lin.mem")


def hold_code(key, layer, held):
    base = (key * 5 + layer) * 8
    if held < 8192:
        return REL[base]
    top = held.bit_length() - 1
    if top >= 21:
        return MUTE
    slot = top - 13
    c0 = min(REL[base + slot], 254)
    c1 = min(REL[base + slot + 1], 254) if slot < 7 else 254
    frac8 = ((held - (1 << top)) << 8) >> top
    return c0 + ((frac8 * (c1 - c0) + 128) >> 8)


def total_code(vcode, hcode):
    if vcode == MUTE or hcode == MUTE:
        return MUTE
    s = vcode + hcode
    return 0 if s < 12 else min(254, s - 12)


class Model:
    def __init__(self):
        self.voice = [[0, 0, 0, 0, 0] for _ in range(176 + NUM_REL)]   # active gen fading file gain
        self.key = [dict(held=0, sus=0, p=0, layer=0, vcode=0, start=0) for _ in range(88)]
        self.pedal = 0
        self.ring = 0
        self.writes = []

    def write(self, slot, active, gen, fading, file, gain):
        self.voice[slot] = [active, gen, fading, file, gain]
        self.writes.append((slot, (active << 29) | (gen << 27) | (fading << 26) | (file << 16) | gain))

    def release(self, k, now):
        r = self.key[k]
        slot = 2 * k + r["p"]
        a, g, f, fi, ga = self.voice[slot]
        if a:
            self.write(slot, a, g, 1, fi, ga)
        code = total_code(r["vcode"], hold_code(k, r["layer"], (now - r["start"]) & 0xFFFFFFFF))
        if code != MUTE:
            rs = 176 + self.ring
            self.write(rs, 1, (self.voice[rs][1] + 1) & 3, 0, RELEASE_BASE + k * 5 + r["layer"], LIN[code])
            self.ring = (self.ring + 1) % NUM_REL

    def event(self, now, ev):
        typ, a, v = ev >> 14, (ev >> 7) & 127, ev & 127
        if typ == 1 and a < 88:
            r = self.key[a]
            if r["held"] or r["sus"]:
                self.release(a, now)
            p = r["p"] ^ 1
            w = VEL[a * 128 + v]
            layer, vcode = w >> 8, w & 255
            slot = 2 * a + p
            self.write(slot, 1, (self.voice[slot][1] + 1) & 3, 0, a * 5 + layer, LIN[vcode])
            self.key[a] = dict(held=1, sus=0, p=p, layer=layer, vcode=vcode, start=now)
        elif typ == 0 and a < 88:
            r = self.key[a]
            if not r["held"]:
                return
            if self.pedal:
                r["held"], r["sus"] = 0, 1
            else:
                self.release(a, now)
                r["held"], r["sus"] = 0, 0
        elif typ == 2 and a == 64:
            if v >= 64:
                self.pedal = 1
            else:
                self.pedal = 0
                for k in range(88):
                    r = self.key[k]
                    if r["sus"] and not r["held"]:
                        self.release(k, now)
                        r["held"], r["sus"] = 0, 0


def gen():
    rnd = random.Random(1)
    SR = 44100
    t = 1000
    events, down = [], {}
    pedal = False
    for step in range(700):
        t += rnd.choice([1, 50, 400, 2000, 6000, 20000])
        r = rnd.random()
        if r < 0.45 or not down:
            k = rnd.choice([0, 3, 20, 39, 40, 41, 55, 60, 70, 80, 87] + list(range(30, 50)))
            v = rnd.choice([1, 5, 16, 30, 47, 48, 49, 63, 64, 80, 96, 112, 127])
            events.append((t, (1 << 14) | (k << 7) | v))          # note-on (re-strike if down)
            down[k] = t
        elif r < 0.85:
            k = rnd.choice(list(down))
            del down[k]
            events.append((t, (0 << 14) | (k << 7)))              # note-off
        else:
            pedal = not pedal
            events.append((t, (2 << 14) | (64 << 7) | (127 if pedal else 0)))
        if step % 97 == 0:                                         # long holds: jump time
            t += rnd.choice([4 * SR, 9 * SR, 15 * SR, 31 * SR, 60 * SR])
    events.append((t + 10, (2 << 14) | (64 << 7)))                 # pedal up at the end
    for k in list(down):
        events.append((t + 20, k << 7))
    os.makedirs(VEC, exist_ok=True)
    with open(os.path.join(VEC, "vm_events.hex"), "w") as f:
        f.write("".join(f"{tt:08X}{ev:04X}\n" for tt, ev in events))
    m = Model()
    for tt, ev in events:
        m.event(tt, ev)
    with open(os.path.join(VEC, "vm_expected.txt"), "w") as f:
        f.write("".join(f"{s:02X} {d:08X}\n" for s, d in m.writes))
    rel = sum(1 for s, _ in m.writes if s >= 176)
    print(f"{len(events)} events, {len(m.writes)} voice writes expected ({rel} release voices, "
          f"ring wraps {rel // NUM_REL}x)")


def check(log):
    exp = [l.split() for l in open(os.path.join(VEC, "vm_expected.txt")) if l.strip()]
    got = [l.split() for l in open(log) if l.strip()]
    bad = 0
    for i, (e, g) in enumerate(zip(exp, got)):
        if [x.upper() for x in e] != [x.upper() for x in g]:
            bad += 1
            if bad <= 10:
                print(f"write {i}: expected slot {e[0]} data {e[1]}, got slot {g[0]} data {g[1]}")
    if len(exp) != len(got):
        bad += 1
        print(f"{len(got)} writes, expected {len(exp)}")
    print(f"{'PASS' if bad == 0 else 'FAIL'} voice_manager vs reference model: {len(got)} writes compared"
          + ("" if bad == 0 else f", {bad} mismatches"))
    return 0 if bad == 0 else 1


if __name__ == "__main__":
    if sys.argv[1:2] == ["gen"]:
        gen()
    elif sys.argv[1:2] == ["check"]:
        sys.exit(check(sys.argv[2]))
    else:
        print(__doc__)
