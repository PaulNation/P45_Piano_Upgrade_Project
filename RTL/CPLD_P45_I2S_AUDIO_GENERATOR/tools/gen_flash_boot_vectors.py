#!/usr/bin/env python3
"""
gen_flash_boot_vectors.py
From Rhodes_Sample_Libary/flash_image.bin (+ .json) writes, for tb/flash_boot_tb.sv:
  tb/vectors/flash_head.hex            header + file table words (what the boot loader reads)
  tb/vectors/flash_table_expected.hex  {start[24:0], samples[23:0]} per file, from the json
"""
import json, os, struct
ROOT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..")
LIB = os.path.join(ROOT, "..", "..", "Rhodes_Sample_Libary")
img = open(os.path.join(LIB, "flash_image.bin"), "rb").read(2 * (8 + 6 * 1024))
j = json.load(open(os.path.join(LIB, "flash_image.json")))
n = len(j["files"])
words = struct.unpack(f"<{8 + 6 * n}H", img[:2 * (8 + 6 * n)])
os.makedirs(os.path.join(ROOT, "tb", "vectors"), exist_ok=True)
with open(os.path.join(ROOT, "tb", "vectors", "flash_head.hex"), "w") as f:
    f.write("".join(f"{w:04X}\n" for w in words))
with open(os.path.join(ROOT, "tb", "vectors", "flash_table_expected.hex"), "w") as f:
    f.write("".join(f"{(e['start_word'] << 24) | e['samples']:013X}\n" for e in j["files"]))
print(f"{n} files, header + table = {len(words)} words, release base {j['release_base']}")
