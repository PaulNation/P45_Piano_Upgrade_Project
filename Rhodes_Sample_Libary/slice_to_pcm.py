#!/usr/bin/env python3
"""
slice_to_pcm.py
Cuts a bounced WAV (sample rate / bit depth / channel count as set in the
manifest, e.g. 44.1 kHz / 16-bit / mono) into headerless raw PCM files using
the manifest written by make_sampler_midi.py.

For every slot it writes, by default, just the sustain slice:
    <prefix>_<name>_n<note>_v<vel>_sus.pcm   (note-on  -> note-off)
Pass --with-release to also export the release tail:
    <prefix>_<name>_n<note>_v<vel>_rel.pcm   (note-off -> end of tail)
plus an index.json describing every file (format, frame counts, root note...).

Output format: raw interleaved PCM, signed little-endian, at the channel
count/sample rate/bit depth recorded in the manifest — byte-for-byte
identical to the WAV's data chunk (no resampling, no dither).

Alongside the PCM folder, a second folder is written with a plain WAV copy of
every slice (same bytes, just wrapped in a standard RIFF/WAVE header) so the
cuts can be dragged straight into a DAW to validate them by ear. Use
--no-wav to skip this if you only want the raw PCM.

Usage:
    python3 slice_to_pcm.py bounce.wav manifest.json -o samples/ -w samples_wav/
Options:
    --offset-ms N    shift all cut points (use if your bounce doesn't start at 0)
    --tempo-actual T rescale manifest positions by 120/T before cutting; only use if the wrong tempo was constant for the whole render
    --trim-db  -72   trim trailing near-silence from each slice (default -72 dBFS, 0 disables... use --no-trim)
    --no-trim        keep full slice lengths
    --fade-ms  4     apply a short fade-out at each slice end to avoid clicks (0 disables)
    --with-release   also export release (_rel) slices (default: sustain only)
    -w, --wavdir     output folder for DAW-friendly WAV copies (default: samples_wav)
    --no-wav         skip writing the WAV validation copies
"""

import argparse
import json
import os
import struct
import sys


# ---------------------------------------------------------------- WAV parsing
def parse_wav(path):
    """Return (fmt_dict, data_offset, data_size). Handles PCM and EXTENSIBLE."""
    f = open(path, "rb")
    riff, size, wave = struct.unpack("<4sI4s", f.read(12))
    if riff != b"RIFF" or wave != b"WAVE":
        if riff == b"RF64":
            sys.exit("RF64 (>4 GB) file detected. Split your bounce into parts "
                     "under 4 GB, or export as plain WAV.")
        sys.exit(f"{path} is not a RIFF/WAVE file.")
    fmt = None
    data_offset = data_size = None
    while True:
        hdr = f.read(8)
        if len(hdr) < 8:
            break
        cid, csize = struct.unpack("<4sI", hdr)
        if cid == b"fmt ":
            raw = f.read(csize)
            (tag, ch, rate, _br, _ba, bits) = struct.unpack("<HHIIHH", raw[:16])
            if tag == 0xFFFE and csize >= 40:  # WAVE_FORMAT_EXTENSIBLE
                tag = struct.unpack("<H", raw[24:26])[0]
            fmt = {"tag": tag, "channels": ch, "rate": rate, "bits": bits}
        elif cid == b"data":
            data_offset, data_size = f.tell(), csize
            f.seek(csize + (csize & 1), 1)
        else:
            f.seek(csize + (csize & 1), 1)
    f.close()
    if fmt is None or data_offset is None:
        sys.exit("Could not find fmt/data chunks in WAV.")
    return fmt, data_offset, data_size


# ------------------------------------------------------- bit-depth helpers
def frames_to_ints(buf, bytes_per_sample):
    """Decode interleaved signed LE bytes -> list of ints, one per channel per frame."""
    bps = bytes_per_sample
    sign_bit = 1 << (8 * bps - 1)
    full = 1 << (8 * bps)
    out = []
    for i in range(0, len(buf) - bps + 1, bps):
        v = 0
        for j in range(bps):
            v |= buf[i + j] << (8 * j)
        if v & sign_bit:
            v -= full
        out.append(v)
    return out


def ints_to_bytes(vals, bytes_per_sample):
    bps = bytes_per_sample
    sign_bit = 1 << (8 * bps - 1)
    minv, maxv = -sign_bit, sign_bit - 1
    mask = (1 << (8 * bps)) - 1
    b = bytearray(len(vals) * bps)
    for i, v in enumerate(vals):
        v = max(minv, min(maxv, v)) & mask
        for j in range(bps):
            b[i * bps + j] = (v >> (8 * j)) & 0xFF
    return bytes(b)


def trim_point(f, data_offset, start_frame, end_frame, thresh, frame_bytes, bytes_per_sample, channels):
    """Scan backwards in 0.25 s blocks; return new end_frame after which the
    signal never exceeds `thresh` (peak, absolute integer units for the
    current bit depth)."""
    block = 12000  # frames per scan block (0.25 s)
    end = end_frame
    while end > start_frame:
        lo = max(start_frame, end - block)
        f.seek(data_offset + lo * frame_bytes)
        vals = frames_to_ints(f.read((end - lo) * frame_bytes), bytes_per_sample)
        # find last sample above threshold in this block
        last = -1
        for i in range(len(vals) - 1, -1, -1):
            if abs(vals[i]) > thresh:
                last = i
                break
        if last >= 0:
            return min(end_frame, lo + (last // channels) + 1)
        end = lo
    return start_frame  # slice is entirely silent


def write_slice(f, data_offset, start_frame, end_frame, out_path, fade_frames, frame_bytes, bytes_per_sample, channels):
    n = end_frame - start_frame
    if n <= 0:
        return 0
    f.seek(data_offset + start_frame * frame_bytes)
    with open(out_path, "wb") as out:
        body = n - fade_frames if fade_frames and n > fade_frames else n
        # bulk copy (bit-perfect, no decode)
        chunk = 1 << 20
        left = body
        while left > 0:
            take = min(left, chunk // frame_bytes)
            out.write(f.read(take * frame_bytes))
            left -= take
        # faded tail
        tail = n - body
        if tail > 0:
            vals = frames_to_ints(f.read(tail * frame_bytes), bytes_per_sample)
            for i in range(tail):
                g = 1.0 - (i + 1) / tail
                for ch in range(channels):
                    vals[i * channels + ch] = int(vals[i * channels + ch] * g)
            out.write(ints_to_bytes(vals, bytes_per_sample))
    return n


def pcm_file_to_wav(pcm_path, wav_path, sr, channels, bits=24):
    """Wrap an existing headerless PCM file in a standard RIFF/WAVE header."""
    data_size = os.path.getsize(pcm_path)
    byte_rate = sr * channels * bits // 8
    block_align = channels * bits // 8
    with open(wav_path, "wb") as out, open(pcm_path, "rb") as inp:
        out.write(b"RIFF")
        out.write(struct.pack("<I", 36 + data_size))
        out.write(b"WAVE")
        out.write(b"fmt ")
        out.write(struct.pack("<IHHIIHH", 16, 1, channels, sr, byte_rate, block_align, bits))
        out.write(b"data")
        out.write(struct.pack("<I", data_size))
        chunk = 1 << 20
        while True:
            buf = inp.read(chunk)
            if not buf:
                break
            out.write(buf)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("wav")
    ap.add_argument("manifest")
    ap.add_argument("-o", "--outdir", default="samples")
    ap.add_argument("-w", "--wavdir", default="samples_wav",
                    help="output folder for DAW-friendly WAV copies of each slice")
    ap.add_argument("--no-wav", action="store_true",
                    help="skip writing the WAV validation copies")
    ap.add_argument("--offset-ms", type=float, default=0.0)
    ap.add_argument("--tempo-actual", type=float, default=None,
                    help="Rescale every manifest position by 120/tempo_actual before cutting; use only if the wrong tempo was constant for the whole render")
    ap.add_argument("--trim-db", type=float, default=-50.0)
    ap.add_argument("--no-trim", action="store_true")
    ap.add_argument("--fade-ms", type=float, default=4.0)
    ap.add_argument("--with-release", action="store_true",
                    help="also export release (_rel) slices; by default only sustain (_sus) slices are written")
    args = ap.parse_args()

    with open(args.manifest) as m:
        man = json.load(m)
    sr = man["sample_rate"]
    bits = man.get("bits_per_sample", 24)
    channels = man.get("channels", 2)
    prefix = man.get("prefix", "sample")

    bytes_per_sample = bits // 8
    frame_bytes = channels * bytes_per_sample

    fmt, data_offset, data_size = parse_wav(args.wav)
    problems = []
    if fmt["rate"] != sr:
        problems.append(f"sample rate {fmt['rate']} (expected {sr})")
    if fmt["bits"] != bits or fmt["tag"] != 1:
        problems.append(f"format tag={fmt['tag']} bits={fmt['bits']} (expected PCM {bits}-bit)")
    if fmt["channels"] != channels:
        problems.append(f"{fmt['channels']} channels (expected {channels})")
    if problems:
        chan_label = {1: "mono", 2: "stereo"}.get(channels, f"{channels}-channel")
        sys.exit("Bounce doesn't match the expected format: " + "; ".join(problems) +
                 f"\nRe-export as {sr} Hz / {bits}-bit / {chan_label} WAV (PCM).")

    total_frames = data_size // frame_bytes
    offset = int(round(args.offset_ms / 1000.0 * sr))
    fade_frames = int(round(args.fade_ms / 1000.0 * sr))
    peak = (1 << (bits - 1)) - 1
    thresh = 0 if args.no_trim else int(peak * (10 ** (args.trim_db / 20.0)))

    if args.tempo_actual is not None:
        if args.tempo_actual <= 0:
            sys.exit("--tempo-actual must be > 0")
        tempo_scale = 120.0 / args.tempo_actual
    else:
        tempo_scale = 1.0

    need = int(round(man["slots"][-1]["end_sample"] * tempo_scale)) + offset
    if need > total_frames:
        print(f"WARNING: bounce is shorter than the manifest expects "
              f"({total_frames} frames, need {need}). Late slices will be clipped/skipped.")

    os.makedirs(args.outdir, exist_ok=True)
    write_wav = not args.no_wav
    if write_wav:
        os.makedirs(args.wavdir, exist_ok=True)
    index = {"format": {"sample_rate": sr, "bits": bits, "channels": channels,
                        "encoding": f"pcm_s{bits}le interleaved"},
             "pcm_dir": args.outdir,
             "wav_dir": args.wavdir if write_wav else None,
             "samples": []}

    f = open(args.wav, "rb")
    written = 0
    for s in man["slots"]:
        on = min(total_frames, max(0, int(round(s["on_sample"] * tempo_scale)) + offset))
        off = min(total_frames, int(round(s["off_sample"] * tempo_scale)) + offset)
        end = min(total_frames, int(round(s["end_sample"] * tempo_scale)) + offset)
        base = f"{prefix}_{s['name']}_n{s['note']:03d}_v{s['velocity']:03d}"

        cuts = [("sus", on, off)]
        if args.with_release:
            cuts.append(("rel", off, end))

        for kind, a, b in cuts:
            if not args.no_trim:
                b = max(a, trim_point(f, data_offset, a, b, thresh, frame_bytes, bytes_per_sample, channels))
            if b - a < sr // 100:   # <10 ms -> treat as empty, skip
                continue
            name = f"{base}_{kind}.pcm"
            pcm_path = os.path.join(args.outdir, name)
            n = write_slice(f, data_offset, a, b, pcm_path, fade_frames, frame_bytes, bytes_per_sample, channels)
            wav_name = None
            if write_wav:
                wav_name = f"{base}_{kind}.wav"
                pcm_file_to_wav(pcm_path, os.path.join(args.wavdir, wav_name), sr, channels, bits=bits)
            index["samples"].append({
                "file": name, "wav_file": wav_name, "type": kind, "root_note": s["note"],
                "note_name": s["name"], "velocity": s["velocity"],
                "frames": n, "seconds": round(n / sr, 4),
            })
            written += 1
    f.close()

    with open(os.path.join(args.outdir, "index.json"), "w") as out:
        json.dump(index, out, indent=1)
    msg = f"Wrote {written} PCM files + index.json to {args.outdir}/"
    if write_wav:
        msg += f", and {written} WAV validation copies to {args.wavdir}/"
    print(msg)


if __name__ == "__main__":
    main()
