#!/usr/bin/env python3
"""Lossless LPC + Golomb-Rice packer for 16-bit word-addressable parallel Flash.

Takes a directory of 16-bit signed mono 44.1 kHz audio (.pcm raw little-endian,
or .wav read with the `wave` module) and builds one `flash_image.bin` laid out
as an array of 16-bit words, so every address in it is a WORD address that maps
straight onto the Flash's parallel address bus (A0 selects a 16-bit word).

Compression pipeline (per file, per 1024-sample frame):
    1. Fixed polynomial predictor, order picked per frame (smallest output):
         order 1  P = X1
         order 2  P = 2*X1 - X2
         order 3  P = 3*X1 - 3*X2 + X3
         order 4  P = 4*X1 - 6*X2 + 4*X3 - X4         (Xd = X[n-d])
       All coefficients are small integers -> shifts and adds, no multiplier
       (e.g. 3*a = (a<<1)+a, 6*a = (a<<2)+(a<<1)).
    2. Residual  R[n] = X[n] - P[n], wrapped into int16 (mod 2^16)
    3. Zig-zag map  0->0, -1->1, 1->2, -2->3 ...
    4. Golomb-Rice code with the per-frame optimal k in 0..8
         code = q ones, one 0 terminator, k-bit remainder  (q = u >> k)
    5. Bits packed MSB-first into 16-bit words; each frame starts word-aligned.

---------------------------------------------------------------------------
IMAGE LAYOUT  (every field is one 16-bit word unless noted; 32-bit values are
stored as two words, HIGH word first)
---------------------------------------------------------------------------
Word 0      : magic 0x5243 ('RC')
Word 1      : format version (3)
Word 2      : frame size in samples (1024)
Word 3      : file count N
Word 4-5    : total image length in words (32-bit)
Word 6      : sample rate in Hz (44100)
Word 7      : reserved (0)
Word 8 ...  : file table, N entries x 6 words:
                +0..1  start word address of the file's first frame (32-bit)
                +2..3  compressed length in words                (32-bit)
                +4..5  number of samples                          (32-bit)
After table : compressed file data, back to back.

FRAME LAYOUT (word-aligned, independently decodable -> random access / loops)
    Header word : bits[15:12] = k (0..8) or 0xF for a RAW frame
                  bits[11:10] = predictor order p - 1 (p = 1..4; 0 in a RAW frame)
                  bits[9:0]   = payload length in words - 1 (excludes header, 1..1024)
    Rice frame  : p words X[0..p-1]   (raw warm-up samples, int16)
                  Rice bitstream for residuals of X[p..n-1], zero padded
    RAW frame   : n raw int16 words (used when Rice would not be smaller)
The last frame of a file may hold fewer than 1024 samples; the decoder gets the
exact count from the file table. The length field lets a decoder hop from
frame header to frame header without parsing the bitstream.

Because every frame carries its own warm-up samples, a decoder can start at
any frame boundary (e.g. a loop point) without decoding the file from the top.

Usage:
    python lpc_rice_flash_packer.py 16bit_44.1kHz_Mono_Left_Only/samples
    python lpc_rice_flash_packer.py samples/ -o flash_image.bin --verify
    python lpc_rice_flash_packer.py samples/ --exclude '*_v016_*'   # drop quietest layer
    python lpc_rice_flash_packer.py samples/ --orders 2             # order-2 predictor only
"""
from __future__ import annotations

import argparse
import json
import os
import sys
import time
import wave
from array import array
from fnmatch import fnmatch
from concurrent.futures import ProcessPoolExecutor
from functools import partial
from pathlib import Path

# ---------------------------------------------------------------------------
# Format constants
# ---------------------------------------------------------------------------
MAGIC = 0x5243
VERSION = 3
FRAME_SAMPLES = 1024                 # max 1024: payload length is stored as len-1 in 10 bits
SAMPLE_RATE = 44100
MAX_K = 8
RAW_MODE = 0xF                      # k-field value marking an uncompressed frame
ORDERS = (1, 2, 3, 4)               # default predictor orders tried per frame (= raw warm-up samples)
GLOBAL_HEADER_WORDS = 8
TABLE_ENTRY_WORDS = 6

FLASH_WORDS = 32 * 1024 * 1024      # 64 MB part = 32 Mi x 16-bit words
FLASH_BYTES = FLASH_WORDS * 2


# ---------------------------------------------------------------------------
# Integer helpers
# ---------------------------------------------------------------------------
def wrap16(v: int) -> int:
    """Wrap any integer into signed int16 range (two's-complement mod 2^16).

    The predictor 2*X[n-1] - X[n-2] can reach +/-98303, so the raw residual
    needs 18 bits. Wrapping it mod 2^16 keeps it in 16 bits and is still
    lossless: the decoder computes wrap16(P + R) and lands on the exact X.
    """
    return ((v + 0x8000) & 0xFFFF) - 0x8000


def zigzag(v: int) -> int:
    """Signed -> unsigned: 0->0, -1->1, 1->2, -2->3, 2->4 ..."""
    return (v << 1) if v >= 0 else ((-v << 1) - 1)


def unzigzag(u: int) -> int:
    return (u >> 1) if not (u & 1) else -((u + 1) >> 1)


def to_u16(v: int) -> int:
    """Signed int16 -> its raw 16-bit word pattern."""
    return v & 0xFFFF


def to_s16(w: int) -> int:
    return w - 0x10000 if w & 0x8000 else w


# ---------------------------------------------------------------------------
# Input
# ---------------------------------------------------------------------------
def load_samples(path: Path) -> array:
    """Return the file's samples as array('h') (native int16)."""
    if path.suffix.lower() == ".wav":
        with wave.open(str(path), "rb") as w:
            if w.getsampwidth() != 2 or w.getnchannels() != 1:
                raise ValueError(f"{path.name}: need 16-bit mono WAV")
            if w.getframerate() != SAMPLE_RATE:
                raise ValueError(f"{path.name}: need {SAMPLE_RATE} Hz, got {w.getframerate()}")
            raw = w.readframes(w.getnframes())
    else:
        raw = path.read_bytes()
    if len(raw) % 2:
        raise ValueError(f"{path.name}: odd byte count, not 16-bit PCM")
    samples = array("h")
    samples.frombytes(raw)
    if sys.byteorder == "big":          # .pcm / .wav data is little-endian
        samples.byteswap()
    return samples


# ---------------------------------------------------------------------------
# Encoder
# ---------------------------------------------------------------------------
def best_rice_k(values: list[int]) -> tuple[int, int]:
    """Exact optimal k in 0..MAX_K for a list of unsigned values.

    Bit cost of one value u with parameter k is (u >> k) + 1 + k, so the
    block cost is sum(u >> k) + n*(k + 1). Every k is evaluated exactly.
    Returns (k, total_bits).
    """
    n = len(values)
    best_k, best_bits = 0, None
    for k in range(MAX_K + 1):
        bits = sum(u >> k for u in values) + n * (k + 1)
        if best_bits is None or bits < best_bits:
            best_k, best_bits = k, bits
    return best_k, best_bits


def pack_rice(values: list[int], k: int, total_bits: int) -> list[int]:
    """Pack Rice codes MSB-first into a list of 16-bit words (zero padded).

    Each code is built as one integer: q ones, a 0 terminator, then the k-bit
    remainder, i.e. ((2^q - 1) << (k + 1)) | remainder, width q + 1 + k.
    Codes are concatenated in a Python big int, then sliced into words.
    """
    acc = 0
    mask = (1 << k) - 1
    for u in values:
        q = u >> k
        width = q + 1 + k
        acc = (acc << width) | (((1 << q) - 1) << (k + 1)) | (u & mask)
    n_words = (total_bits + 15) // 16
    acc <<= n_words * 16 - total_bits             # pad the tail with zeros
    data = acc.to_bytes(n_words * 2, "big")
    return [(data[i] << 8) | data[i + 1] for i in range(0, len(data), 2)]


def predict(x: list[int], i: int, order: int) -> int:
    """Fixed polynomial prediction of x[i] from the previous `order` samples."""
    if order == 1:
        return x[i - 1]
    if order == 2:
        return 2 * x[i - 1] - x[i - 2]
    if order == 3:
        return 3 * x[i - 1] - 3 * x[i - 2] + x[i - 3]
    return 4 * x[i - 1] - 6 * x[i - 2] + 4 * x[i - 3] - x[i - 4]


def encode_frame(x: list[int], orders: tuple[int, ...] = ORDERS) -> tuple[list[int], int, int]:
    """Encode one frame (<=1024 int16 samples).

    Tries every predictor order, keeps the one with the fewest words, and falls
    back to a RAW frame when nothing beats storing the samples verbatim.
    Returns (words, k or RAW_MODE, order or 0).
    """
    n = len(x)
    raw_words = [to_u16(s) for s in x]

    best = None                                  # (payload_words, order, k, bits, zz)
    for order in orders:
        if n <= order:
            continue
        zz = [zigzag(wrap16(x[i] - predict(x, i, order))) for i in range(order, n)]
        k, bits = best_rice_k(zz)
        payload_words = order + (bits + 15) // 16
        if best is None or payload_words < best[0]:
            best = (payload_words, order, k, bits, zz)

    if best is not None and best[0] < n:         # only keep Rice if it actually wins
        _, order, k, bits, zz = best
        payload = raw_words[:order] + pack_rice(zz, k, bits)
        return [(k << 12) | ((order - 1) << 10) | (len(payload) - 1)] + payload, k, order

    return [(RAW_MODE << 12) | (n - 1)] + raw_words, RAW_MODE, 0


def encode_file(path_str: str, orders: tuple[int, ...] = ORDERS) -> dict:
    """Compress one file into a word list. Runs in a worker process."""
    path = Path(path_str)
    samples = load_samples(path)
    words = array("H")
    k_hist = [0] * 16
    order_hist = [0] * (max(ORDERS) + 1)          # indexed by order; 0 = RAW frame
    for start in range(0, len(samples), FRAME_SAMPLES):
        frame_words, k, order = encode_frame(samples[start:start + FRAME_SAMPLES].tolist(), orders)
        words.extend(frame_words)
        k_hist[k] += 1
        order_hist[order] += 1
    return {
        "name": path.name,
        "samples": len(samples),
        "raw_bytes": len(samples) * 2,
        "words": words.tobytes(),       # native-order bytes; cheap to ship between processes
        "k_hist": k_hist,
        "order_hist": order_hist,
    }


# ---------------------------------------------------------------------------
# Decoder (reference model of the hardware, used by --verify)
# ---------------------------------------------------------------------------
def decode_file(image: array, start: int, n_samples: int) -> list[int]:
    """Decode one file directly from the word image, starting at word `start`."""
    out: list[int] = []
    pos = start
    while len(out) < n_samples:
        n = min(FRAME_SAMPLES, n_samples - len(out))
        header = image[pos]
        k, order, length = header >> 12, ((header >> 10) & 0x3) + 1, (header & 0x3FF) + 1
        payload = image[pos + 1:pos + 1 + length]
        pos += 1 + length

        if k == RAW_MODE:
            out.extend(to_s16(w) for w in payload)
            continue

        x = [to_s16(w) for w in payload[:order]]
        bitstream = int.from_bytes(b"".join(w.to_bytes(2, "big") for w in payload[order:]), "big")
        bitpos = (length - order) * 16 - 1       # index of the next bit, MSB first
        for i in range(order, n):
            q = 0
            while (bitstream >> bitpos) & 1:     # count unary ones
                q += 1
                bitpos -= 1
            bitpos -= 1                          # skip the 0 terminator
            rem = (bitstream >> (bitpos - k + 1)) & ((1 << k) - 1) if k else 0
            bitpos -= k
            r = unzigzag((q << k) | rem)
            x.append(wrap16(predict(x, i, order) + r))
        out.extend(x)
    return out


# ---------------------------------------------------------------------------
# Image assembly
# ---------------------------------------------------------------------------
def split32(v: int) -> tuple[int, int]:
    return (v >> 16) & 0xFFFF, v & 0xFFFF


def build_image(results: list[dict]) -> tuple[array, list[dict]]:
    """Lay out header + file table + data. Returns (word image, table entries)."""
    data_start = GLOBAL_HEADER_WORDS + TABLE_ENTRY_WORDS * len(results)

    entries = []
    addr = data_start
    for r in results:
        n_words = len(r["words"]) // 2
        entries.append({"name": r["name"], "start_word": addr,
                        "length_words": n_words, "samples": r["samples"]})
        addr += n_words
    total_words = addr

    image = array("H", [MAGIC, VERSION, FRAME_SAMPLES, len(results),
                        *split32(total_words), SAMPLE_RATE, 0])
    for e in entries:
        image.extend([*split32(e["start_word"]), *split32(e["length_words"]),
                      *split32(e["samples"])])
    for r in results:
        chunk = array("H")
        chunk.frombytes(r["words"])
        image.extend(chunk)
    assert len(image) == total_words
    return image, entries


# ---------------------------------------------------------------------------
# Reporting
# ---------------------------------------------------------------------------
def fmt_bytes(n: float) -> str:
    for unit in ("B", "KB", "MB", "GB"):
        if n < 1024 or unit == "GB":
            return f"{n:.0f} {unit}" if unit == "B" else f"{n:.2f} {unit}"
        n /= 1024
    return ""


def print_summary(results: list[dict], entries: list[dict], image_words: int,
                  out_path: Path, elapsed: float, show_files: bool) -> None:
    name_w = max([len(e["name"]) for e in entries] + [4])
    if show_files:
        print(f"\n{'File':<{name_w}}  {'Word addr':>10}  {'Raw':>10}  {'Packed':>10}  {'Ratio':>6}  {'Savings':>7}")
        print("-" * (name_w + 54))
        for r, e in zip(results, entries):
            packed = e["length_words"] * 2
            ratio = r["raw_bytes"] / packed if packed else 0
            print(f"{e['name']:<{name_w}}  0x{e['start_word']:08X}  {fmt_bytes(r['raw_bytes']):>10}  "
                  f"{fmt_bytes(packed):>10}  {ratio:5.2f}:1  {100 * (1 - 1 / ratio) if ratio else 0:6.1f}%")

    raw_total = sum(r["raw_bytes"] for r in results)
    data_words = sum(e["length_words"] for e in entries)
    header_words = image_words - data_words
    image_bytes = image_words * 2
    k_hist = [sum(r["k_hist"][i] for r in results) for i in range(16)]
    frames = sum(k_hist)
    ratios = [r["raw_bytes"] / (e["length_words"] * 2) for r, e in zip(results, entries) if e["length_words"]]

    print("\n================ SUMMARY ================")
    print(f"Files packed          : {len(results)}")
    print(f"Total samples         : {sum(r['samples'] for r in results):,} "
          f"({sum(r['samples'] for r in results) / SAMPLE_RATE:,.1f} s @ {SAMPLE_RATE} Hz)")
    print(f"Raw PCM size          : {fmt_bytes(raw_total)} ({raw_total:,} bytes)")
    print(f"Header + table        : {header_words:,} words")
    print(f"Compressed audio      : {fmt_bytes(data_words * 2)} ({data_words:,} words)")
    print(f"flash_image.bin       : {fmt_bytes(image_bytes)} ({image_words:,} words) -> {out_path}")
    if ratios:
        print(f"Overall ratio         : {raw_total / max(data_words * 2, 1):.3f}:1 "
              f"(per-file min {min(ratios):.2f}, max {max(ratios):.2f})")
    print(f"Frames                : {frames:,}  (k usage: "
          + ", ".join(f"k={i}:{100 * k_hist[i] / frames:.1f}%" for i in range(MAX_K + 1) if k_hist[i])
          + (f", RAW:{100 * k_hist[RAW_MODE] / frames:.1f}%" if k_hist[RAW_MODE] else "") + ")")
    orders = [sum(r["order_hist"][o] for r in results) for o in ORDERS]
    print("Predictor orders      : " + ", ".join(f"p={o}:{100 * c / frames:.1f}%"
                                                  for o, c in zip(ORDERS, orders) if c))
    print(f"Encode time           : {elapsed:.1f} s")

    used = 100 * image_words / FLASH_WORDS
    last_addr = image_words - 1
    print("\n---- 64 MB (32 Mi-word) parallel Flash ----")
    print(f"Capacity              : {FLASH_WORDS:,} words (0x{FLASH_WORDS - 1:07X} max addr, 25-bit bus)")
    print(f"Image occupies        : 0x0000000 .. 0x{last_addr:07X}  ({used:.2f}% of chip)")
    if image_words <= FLASH_WORDS:
        print(f"Free                  : {FLASH_WORDS - image_words:,} words ({fmt_bytes(FLASH_BYTES - image_bytes)})  -> FITS")
    else:
        over = image_words - FLASH_WORDS
        print(f"OVER BY               : {over:,} words ({fmt_bytes(over * 2)})  -> DOES NOT FIT")
        print(f"                        needs {image_words / FLASH_WORDS:.2f}x the chip, "
              f"or ~{FLASH_BYTES / image_bytes * 100:.0f}% of the current material")
    raw_used = raw_total / FLASH_BYTES * 100
    print(f"(Uncompressed would be {raw_used:.1f}% of the chip)")


# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    ap.add_argument("input_dir", type=Path, help="directory of 16-bit mono 44.1 kHz .pcm/.wav files")
    ap.add_argument("-o", "--output", type=Path, default=Path("flash_image.bin"))
    ap.add_argument("--big-endian", action="store_true",
                    help="write each 16-bit word high byte first (default: little-endian)")
    ap.add_argument("--verify", action="store_true",
                    help="decode every file back out of the image and compare bit-exact")
    ap.add_argument("--jobs", type=int, default=os.cpu_count() or 1, help="worker processes")
    ap.add_argument("--quiet-files", action="store_true", help="skip the per-file table")
    ap.add_argument("--orders", default="1,2,3,4", metavar="LIST",
                    help="predictor orders the encoder may pick per frame, e.g. '2' to force "
                         "order 2 everywhere (default: 1,2,3,4)")
    ap.add_argument("--exclude", action="append", default=[], metavar="GLOB",
                    help="skip files matching this name pattern, e.g. '*_v016_*' (repeatable; "
                         "source files are never touched)")
    args = ap.parse_args()

    orders = tuple(sorted({int(o) for o in args.orders.split(",")}))
    if not orders or any(o not in ORDERS for o in orders):
        print(f"--orders must be drawn from {ORDERS}", file=sys.stderr)
        return 1

    files = sorted(p for p in args.input_dir.iterdir()
                   if p.is_file() and p.suffix.lower() in (".pcm", ".wav")
                   and not any(fnmatch(p.name, pat) for pat in args.exclude))
    if not files:
        print(f"No .pcm/.wav files in {args.input_dir}", file=sys.stderr)
        return 1
    if len(files) > 0xFFFF:
        print("Too many files for a 16-bit file count", file=sys.stderr)
        return 1

    print(f"Encoding {len(files)} files from {args.input_dir} with {args.jobs} worker(s)...")
    t0 = time.time()
    results: list[dict] = []
    with ProcessPoolExecutor(max_workers=args.jobs) as pool:
        for i, r in enumerate(pool.map(partial(encode_file, orders=orders), [str(f) for f in files], chunksize=1), 1):
            results.append(r)
            print(f"\r  {i}/{len(files)}  {r['name']:<40}", end="", flush=True)
    print()
    elapsed = time.time() - t0

    image, entries = build_image(results)
    if image.itemsize != 2:
        raise RuntimeError("array('H') is not 16-bit on this platform")

    out = array("H", image)
    if (sys.byteorder == "little") == args.big_endian:
        out.byteswap()
    args.output.write_bytes(out.tobytes())

    # Name -> address map for host tooling (not stored in Flash).
    index_path = args.output.with_suffix(".json")
    index_path.write_text(json.dumps({
        "format": "LPC2 + Golomb-Rice, 16-bit word addressed",
        "version": VERSION, "frame_samples": FRAME_SAMPLES, "sample_rate": SAMPLE_RATE,
        "word_byte_order": "big" if args.big_endian else "little",
        "total_words": len(image), "files": entries,
    }, indent=2))

    print_summary(results, entries, len(image), args.output, elapsed, not args.quiet_files)
    print(f"Index                 : {index_path}")

    if args.verify:
        print("\nVerifying (decoding every file from the image)...")
        bad = 0
        for idx, (f, e) in enumerate(zip(files, entries), 1):
            decoded = decode_file(image, e["start_word"], e["samples"])
            if decoded != load_samples(f).tolist():
                bad += 1
                print(f"\n  MISMATCH: {e['name']}")
            print(f"\r  {idx}/{len(files)}", end="", flush=True)
        print(f"\nVerify: {'PASS - bit-exact' if not bad else f'FAIL ({bad} files)'}")
        return 1 if bad else 0
    return 0


if __name__ == "__main__":
    sys.exit(main())
