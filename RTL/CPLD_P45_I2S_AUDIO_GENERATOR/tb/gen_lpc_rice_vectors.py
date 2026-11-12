#!/usr/bin/env python3
"""Generate test vectors for lpc_rice_decoder_tb.sv.

Builds one concatenated word stream out of several test "files" and writes, into
tb/vectors/:
    lpc_rice_stream.hex    16-bit words, one per line (what the flash would return)
    lpc_rice_tests.hex     line 0 = test count, line 1 = index of the whole-file test whose
                           output the testbench writes to a .wav, then 4 x 32-bit lines per
                           test: start word, stream words, num_samples, expected-sample offset
    lpc_rice_expected.hex  expected decoded samples, 16-bit, one per line
    lpc_rice_tests.txt     human-readable list of the tests

Real tests copy frames straight out of Rhodes_Sample_Libary/flash_image.bin (frames are
independent, so any run of whole frames is a valid stream). Synthetic tests are encoded
with the packer's own encode_frame() to hit cases the real image rarely or never has
(RAW frames, wrap-around, k sweep, very long unary runs, forced orders, tiny files).
Expected samples always come from the packer's reference decode_file(), and synthetic
ones are also checked against their source samples.

Test 0 is always one complete sample file (default middle C, v080) so the testbench can
show its whole decoded waveform and write it out as a playable .wav.

Usage: python3 tb/gen_lpc_rice_vectors.py [--whole-file NAME]     (from the project root)
"""
from __future__ import annotations

import argparse
import json
import math
import random
import sys
from array import array
from pathlib import Path

HERE = Path(__file__).resolve().parent
REPO = HERE.parents[2]
LIB = REPO / "Rhodes_Sample_Libary"
sys.path.insert(0, str(LIB))
import lpc_rice_flash_packer as pk  # noqa: E402

OUT = HERE / "vectors"
N = pk.FRAME_SAMPLES


def load_image() -> tuple[array, list[dict]]:
    img = array("H")
    img.frombytes((LIB / "flash_image.bin").read_bytes())
    if sys.byteorder == "big":
        img.byteswap()
    entries = []
    for i in range(img[3]):
        b = pk.GLOBAL_HEADER_WORDS + pk.TABLE_ENTRY_WORDS * i
        entries.append({"start": (img[b] << 16) | img[b + 1],
                        "words": (img[b + 2] << 16) | img[b + 3],
                        "samples": (img[b + 4] << 16) | img[b + 5]})
    names = [f["name"] for f in json.loads((LIB / "flash_image.json").read_text())["files"]]
    for e, n in zip(entries, names):
        e["name"] = n
    return img, entries


def frame_addrs(img: array, e: dict) -> list[int]:
    """Word address of every frame header in a file."""
    addrs, pos, left = [], e["start"], e["samples"]
    while left > 0:
        addrs.append(pos)
        pos += 2 + (img[pos] & 0x3FF)
        left -= min(N, left)
    return addrs + [pos]


def max_q(img: array, addr: int) -> int:
    """Longest unary run in one Rice frame (0 for RAW)."""
    h = img[addr]
    k, order, length = h >> 12, ((h >> 10) & 3) + 1, (h & 0x3FF) + 1
    if k == pk.RAW_MODE:
        return 0
    bits = "".join(f"{w:016b}" for w in img[addr + 1 + order: addr + 1 + length])
    best, pos = 0, 0
    for _ in range(N - order):
        q = 0
        while pos < len(bits) and bits[pos] == "1":
            q += 1
            pos += 1
        pos += 1 + k
        best = max(best, q)
        if pos >= len(bits):
            break
    return best


def encode(samples: list[int], orders=pk.ORDERS) -> list[int]:
    words: list[int] = []
    for s in range(0, len(samples), N):
        words.extend(pk.encode_frame(samples[s:s + N], orders)[0])
    return words


def clamp16(v: float) -> int:
    return max(-32768, min(32767, int(round(v))))


def main() -> int:
    ap = argparse.ArgumentParser(description="Generate lpc_rice_decoder_tb vectors")
    ap.add_argument("--whole-file", default="rhodes_C4_n060_v080_sus.pcm",
                    help="sample file decoded in full as test 0 (name as in flash_image.json)")
    args = ap.parse_args()

    rnd = random.Random(1234)
    img, entries = load_image()
    tests: list[dict] = []

    def add_real(name: str, e: dict, first: int, count: int | None) -> None:
        addrs = frame_addrs(img, e)
        nfr = len(addrs) - 1
        last = nfr if count is None else min(nfr, first + count)
        a0, a1 = addrs[first], addrs[last]
        nsamp = min(e["samples"], last * N) - first * N
        words = list(img[a0:a1])
        tests.append({"name": f"{name}: {e['name']} frames {first}..{last - 1}",
                      "words": words, "samples": nsamp, "src": None})

    def add_syn(name: str, samples: list[int], orders=pk.ORDERS) -> None:
        tests.append({"name": name, "words": encode(samples, orders),
                      "samples": len(samples), "src": samples})

    # 1. Real data from the flash image; test 0 = one complete sample file
    whole = next((e for e in entries if e["name"] == args.whole_file), None)
    if whole is None:
        raise SystemExit(f"{args.whole_file} is not in flash_image.json")
    add_real("real, WHOLE FILE (written to .wav by the testbench)", whole, 0, None)
    src = pk.load_samples(LIB / "16bit_44.1kHz_Mono_Left_Only/samples" / whole["name"]).tolist()
    tests[-1]["src"] = src          # also check the reference decode against the original .pcm
    by_size = sorted(entries, key=lambda e: e["samples"])
    add_real("real, whole smallest file (short last frame)", by_size[0], 0, None)
    add_real("real, attack of the largest file", by_size[-1], 0, 6)
    mid = entries[len(entries) // 2]
    add_real("real, mid-file window (starts on an inner frame)", mid, (len(frame_addrs(img, mid)) - 1) // 2, 4)
    # attack frame with the longest unary run among every file's first 3 frames
    cand = []
    for e in entries:
        addrs = frame_addrs(img, e)
        for f in range(min(3, len(addrs) - 1)):
            cand.append((max_q(img, addrs[f]), e["name"], f, e))
    q, _, f, e = max(cand, key=lambda c: c[0])
    add_real(f"real, longest unary run in attacks (q={q})", e, f, 1)

    # 2. Synthetic edge cases
    add_syn("syn, white noise (RAW frames) + short last frame",
            [rnd.randint(-32768, 32767) for _ in range(2 * N + 300)])
    add_syn("syn, silence (k=0, 1-bit codes)", [0] * (N + 17))
    add_syn("syn, full-scale wrap-around patterns",
            [32767, -32768] * 300 + [(-32768 if (i // 7) % 2 else 32767) for i in range(600)]
            + [((i * 977) & 0xFFFF) - 32768 for i in range(424)])
    spikes = []
    for i in range(3 * N):
        v = rnd.randint(-2, 2)
        if i % 211 == 50:
            v += rnd.choice([-1, 1]) * rnd.randint(300, 3000)
        spikes.append(v)
    add_syn("syn, low noise + spikes (very long unary runs)", spikes)
    ksweep = []
    for j in range(12):
        amp = 1 << j
        ksweep += [rnd.randint(-amp, amp) for _ in range(N)]
    add_syn("syn, noise amplitude sweep 2^0..2^11 (k sweep up to RAW)", ksweep)
    sweep = [clamp16(20000 * math.sin(2 * math.pi * (40 + 3 * i / 200) * i / 44100)
                     * math.exp(-i / 6000)) for i in range(3 * N)]
    for o in (1, 2, 3, 4):
        add_syn(f"syn, decaying sine sweep, order forced to {o}", sweep, (o,))
    add_syn("syn, decaying sine sweep, free order choice", sweep)
    for n in (1, 2, 3, 4, 5, 9):
        add_syn(f"syn, tiny file of {n} samples", [rnd.randint(-500, 500) for _ in range(n)])

    # 3. Reference decode + write the files
    stream: list[int] = []
    expected: list[int] = []
    desc: list[tuple[int, int, int, int]] = []
    k_seen, o_seen, raw_frames = set(), set(), 0
    for t in tests:
        words = array("H", t["words"])
        dec = pk.decode_file(words, 0, t["samples"])
        if t["src"] is not None and dec != t["src"]:
            raise SystemExit(f"reference decode mismatch in {t['name']}")
        pos, left = 0, t["samples"]
        while left > 0:
            h = words[pos]
            if h >> 12 == pk.RAW_MODE:
                raw_frames += 1
            else:
                k_seen.add(h >> 12)
                o_seen.add(((h >> 10) & 3) + 1)
            pos += 2 + (h & 0x3FF)
            left -= min(N, left)
        assert pos == len(words), t["name"]
        desc.append((len(stream), len(words), t["samples"], len(expected)))
        stream.extend(words)
        expected.extend(v & 0xFFFF for v in dec)

    OUT.mkdir(exist_ok=True)
    (OUT / "lpc_rice_stream.hex").write_text("".join(f"{w:04X}\n" for w in stream))
    (OUT / "lpc_rice_expected.hex").write_text("".join(f"{v:04X}\n" for v in expected))
    lines = [f"{len(desc):08X}", f"{0:08X}"] + [f"{v:08X}" for d in desc for v in d]
    (OUT / "lpc_rice_tests.hex").write_text("\n".join(lines) + "\n")
    with open(OUT / "lpc_rice_tests.txt", "w") as f:
        f.write("idx  start_word  words  samples  name\n")
        for i, (t, d) in enumerate(zip(tests, desc)):
            f.write(f"{i:3d}  {d[0]:10d}  {d[1]:5d}  {d[2]:7d}  {t['name']}\n")

    print(f"{len(tests)} tests, {len(stream):,} stream words, {len(expected):,} expected samples")
    print(f"coverage: k {sorted(k_seen)}, orders {sorted(o_seen)}, RAW frames {raw_frames}")
    print(f"written to {OUT}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
