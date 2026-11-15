#!/usr/bin/env python3
"""
engine_ref.py
Vectors and checker for tb/audio_core_tb.sv (the whole audio domain: flash boot, voice manager,
voice engine, mixer, I2S).

  python3 tools/engine_ref.py gen                         # tb/vectors/engine_events.hex, engine_flash.hex
  python3 tools/engine_ref.py check sim/verilator/engine_log.txt
  python3 tools/engine_ref.py stress                      # 150+ voices at once, whole flash image

gen: a 0.6 s performance (chord, low/high keys, softest/hardest velocity, note-offs with
releases, sustain pedal, a re-strike under the pedal) and a sparse flash image: the real
header + file table of Rhodes_Sample_Libary/flash_image.bin and the first words of every file
those keys can use (all 5 layers, sustain and release), at their real addresses.

check (log lines from the testbench):
  R n v file gain         voice v restarted at sample n
  S n v s gain fade fdg   voice v produced decoded sample s at sample n (gain, fade value, fading)
  M n mix                 mixer output at the end of sample n
  I mix                   one I2S frame received (left channel; right must be equal)
  F underrun overrun lr   final status flags (lr = I2S frames where right != left)
Checks: every voice instance's decoded samples equal the library file from its first sample on
(bit-exact decode through the time-shared decoder and refill); gain matches the restart; the fade
runs fade.mem from entry 0 without gaps; M = sat16(sum((s*gain >> 14) * fade >> 15)); the I2S
frames carry M, one frame later; no underrun/overrun.
"""
import json
import os
import struct
import sys

ROOT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..")
LIB = os.path.join(ROOT, "..", "..", "Rhodes_Sample_Libary")
VEC = os.path.join(ROOT, "tb", "vectors")
TABLES = os.path.join(ROOT, "src", "Sample_Decoder", "tables")
WORDS_PER_FILE = 24000          # enough for 0.6 s of any file


def ev(typ, a, v=0):
    return (typ << 14) | (a << 7) | v


def performance():
    on, off, cc = 1, 0, 2
    return [
        (2000, ev(on, 39, 100)), (2000, ev(on, 43, 60)), (2001, ev(on, 46, 30)),   # chord C4 E4 G4
        (6000, ev(on, 6, 127)),                                                   # D#1 hardest
        (9000, ev(off, 43)),                                                      # release E4
        (10000, ev(cc, 64, 127)),                                                 # pedal down
        (11000, ev(off, 39)),                                                     # C4 held by pedal
        (12000, ev(on, 39, 80)),                                                  # re-strike C4
        (14000, ev(off, 46)),                                                     # G4 held by pedal
        (15000, ev(on, 60, 1)), (15000, ev(on, 87, 127)),                         # A5 softest, C8
        (16000, ev(cc, 64, 0)),                                                   # pedal up: G4 releases
        (17000, ev(off, 6)), (17000, ev(off, 60)), (17000, ev(off, 87)), (17500, ev(off, 39)),
        (3000, ev(cc, 7, 100)), (5000, ev(cc, 7, 127)),                           # master volume
        (19000, ev(cc, 7, 64)), (21000, ev(cc, 7, 0)), (23000, ev(cc, 7, 127)),
    ]


def gen():
    img = open(os.path.join(LIB, "flash_image.bin"), "rb").read()
    j = json.load(open(os.path.join(LIB, "flash_image.json")))
    files = j["files"]
    keys = sorted({(e >> 7) & 127 for _, e in performance() if (e >> 14) in (0, 1)})
    used = [k * 5 + l for k in keys for l in range(5)]
    used += [j["release_base"] + i for i in used]
    n_tab = 8 + 6 * len(files)
    out = ["@0"] + [f"{w:04X}" for w in struct.unpack(f"<{n_tab}H", img[:2 * n_tab])]
    for i in sorted(used):
        e = files[i]
        n = min(e["length_words"], WORDS_PER_FILE)
        a = e["start_word"]
        out.append(f"@{a:X}")
        out += [f"{w:04X}" for w in struct.unpack(f"<{n}H", img[2 * a:2 * (a + n)])]
    os.makedirs(VEC, exist_ok=True)
    open(os.path.join(VEC, "engine_flash.hex"), "w").write("\n".join(out) + "\n")
    open(os.path.join(VEC, "engine_events.hex"), "w").write(
        "".join(f"{t:08X}{e:04X}\n" for t, e in sorted(performance(), key=lambda x: x[0])))
    print(f"{len(performance())} events, keys {keys}, {len(used)} files in the sparse flash "
          f"({len(out)} lines)")


def stress():
    """Pedal down, all 88 keys one after another at v127, then 32 re-strikes while everything
    rings (each re-strike = a fading sustain + a release + a new sustain), then pedal up (88
    sustains fade, releases start). Writes the whole image byte-swapped for $fread."""
    on, off, cc = 1, 0, 2
    evs = [(1000, ev(cc, 64, 127))]
    evs += [(1100 + 20 * k, ev(on, k, 127)) for k in range(88)]
    evs += [(1100 + 20 * k + 10, ev(off, k)) for k in range(88)]          # held by the pedal
    evs += [(4000 + 15 * i, ev(on, 2 * i + 10, 64)) for i in range(32)]   # re-strikes
    evs += [(4000 + 15 * i + 5, ev(off, 2 * i + 10)) for i in range(32)]
    evs += [(6000, ev(cc, 64, 0))]
    evs.sort(key=lambda x: x[0])
    open(os.path.join(VEC, "engine_stress_events.hex"), "w").write("".join(f"{t:08X}{e:04X}\n" for t, e in evs))
    img = open(os.path.join(LIB, "flash_image.bin"), "rb").read()
    sw = bytearray(len(img)); sw[0::2] = img[1::2]; sw[1::2] = img[0::2]
    out = os.path.join(ROOT, "sim", "verilator", "flash_image_be.bin")
    os.makedirs(os.path.dirname(out), exist_ok=True)
    open(out, "wb").write(bytes(sw))
    print(f"{len(evs)} events; full image (byte-swapped) -> {out}")


def check(log, events_file=None):
    j = json.load(open(os.path.join(LIB, "flash_image.json")))
    names = [e["name"] for e in j["files"]]
    fade = [int(l, 16) for l in open(os.path.join(TABLES, "fade.mem")) if l.strip()]
    pcm_cache = {}

    def pcm(i):
        if i not in pcm_cache:
            d = "releases" if names[i].endswith("_rel.pcm") else "sustains"
            raw = open(os.path.join(LIB, "library", d, names[i]), "rb").read()
            pcm_cache[i] = struct.unpack(f"<{len(raw) // 2}h", raw)
        return pcm_cache[i]

    def s16(x):
        return x - 65536 if x >= 32768 else x

    inst = {}                       # voice -> dict(file, gain, pos, fpos)
    mix_exp = {}
    mixes, i2s, gains = [], [], []
    errors, n_samples, n_inst, flags, walk = [], 0, 0, None, None
    active = {}
    for line in open(log):
        f = line.split()
        if not f:
            continue
        if f[0] == "R":
            n, v, file, gain = int(f[1]), int(f[2]), int(f[3]), int(f[4])
            inst[v] = dict(file=file, gain=gain, pos=0, fpos=None)
            n_inst += 1
        elif f[0] == "S":
            n, v, s, g, fd = int(f[1]), int(f[2]), s16(int(f[3])), int(f[4]), int(f[5])
            n_samples += 1
            it = inst.get(v)
            if it is None:
                errors.append(f"sample {n}: voice {v} played without a restart")
                continue
            ref = pcm(it["file"])
            if it["pos"] >= len(ref) or ref[it["pos"]] != s:
                errors.append(f"sample {n}: voice {v} file {names[it['file']]} sample {it['pos']} = {s}, "
                              f"expected {ref[it['pos']] if it['pos'] < len(ref) else 'end of file'}")
            it["pos"] += 1
            if g != it["gain"]:
                errors.append(f"sample {n}: voice {v} gain {g}, restart said {it['gain']}")
            fading = int(f[6])
            if it["fpos"] is not None and not fading:
                errors.append(f"sample {n}: voice {v} stopped fading")
            if fading:
                it["fpos"] = 0 if it["fpos"] is None else it["fpos"] + 1
                if fade[it["fpos"]] != fd:
                    errors.append(f"sample {n}: voice {v} fade {fd}, expected fade[{it['fpos']}] = {fade[it['fpos']]}")
            elif fd != 32768:
                errors.append(f"sample {n}: voice {v} not fading but fade = {fd}")
            mix_exp[n] = mix_exp.get(n, 0) + ((((s * g) >> 14) * fd) >> 15)
            active[n] = active.get(n, 0) + 1
        elif f[0] == "M":
            mixes.append((int(f[1]), s16(int(f[2]))))
            gains.append(int(f[3]))
        elif f[0] == "I":
            i2s.append(s16(int(f[1])))
        elif f[0] == "W":
            walk = int(f[1])
        elif f[0] == "F":
            flags = tuple(int(x) for x in f[1:])
    for (n, m), g in zip(mixes, gains):
        e = max(-32768, min(32767, (mix_exp.get(n, 0) * g) >> 14))
        if m != e:
            errors.append(f"mix at sample {n} = {m}, expected {e}")
    # I2S frames carry the mixes in order (frames start at reset, mixes after boot): align on the
    # first non-zero mix, then every frame must equal its mix
    seq = [m for _, m in mixes]
    nz_m = next((i for i, m in enumerate(seq) if m), None)
    nz_i = next((i for i, m in enumerate(i2s) if m), None)
    if nz_m is None or nz_i is None:
        errors.append("no sound in the mix or on I2S")
    else:
        k = nz_i - nz_m
        pairs = [(i2s[k + i], m) for i, m in enumerate(seq) if 0 <= k + i < len(i2s)]
        bad = sum(1 for a, b in pairs if a != b)
        if bad or k < 0:
            errors.append(f"{bad} of {len(pairs)} I2S frames differ from the mixer output (offset {k})")
    vol = [int(l, 16) for l in open(os.path.join(ROOT, "src", "Voice", "volume_curve.mem")) if l.strip()]
    if any(abs(b - a) > 32 for a, b in zip(gains, gains[1:])):
        errors.append("master gain jumps by more than one ramp step")
    played = [int(l[8:12], 16) for l in open(events_file or os.path.join(VEC, "engine_events.hex")) if l.strip()]
    for target in sorted({vol[(e & 127)] for e in played if (e >> 7) == (2 << 7 | 7)}):
        if target not in gains:
            errors.append(f"master gain never reached {target}")
    if flags is None or any(flags):
        errors.append(f"underrun / overrun / I2S L!=R flags = {flags}")
    for e in errors[:15]:
        print("ERROR:", e)
    peak = max((abs(m) for _, m in mixes), default=0)
    print(f"{'PASS' if not errors else 'FAIL'} audio_core: {n_inst} voice starts, {n_samples} decoded samples "
          f"checked against the library, {len(mixes)} mixes, {len(i2s)} I2S frames, mix peak {peak}, "
          f"max {max(active.values(), default=0)} voices in one sample, longest voice walk "
          f"{walk} of 1024 clocks, master gain {min(gains, default=0)}..{max(gains, default=0)}"
          + ("" if not errors else f", {len(errors)} errors"))
    return 0 if not errors else 1


if __name__ == "__main__":
    if sys.argv[1:2] == ["gen"]:
        gen()
    elif sys.argv[1:2] == ["stress"]:
        stress()
    elif sys.argv[1:2] == ["check"]:
        sys.exit(check(sys.argv[2], sys.argv[3] if len(sys.argv) > 3 else None))
    else:
        print(__doc__)
