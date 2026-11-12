#!/usr/bin/env python3
"""
make_rebounce_midi.py
MIDI clip + manifest for bouncing the sustain library from Keyscape: the 5 layers kept
in flash (v016 v048 v064 v080 v112) x 88 keys = 440 notes. chop_rebounce.py then cuts
the bounce into files that start in silence just before the attack.

Each note is held for its file length (data/sustain_lengths.json, the lengths of the
original library) + 0.6 s, then 0.4 s of tail and 0.3 s gap. Hold times are written for a
148 BPM project (like the release renders): the MIDI is at 120 BPM, so every time is
stretched by 148/120 and plays back at the right length when the DAW is at 148 BPM.

Render settings: same Keyscape patch as the releases, release OFF, mechanical noise on,
transition mode OFF, effects off, 44.1 kHz 16-bit mono (or left channel), clip at 1.1.1,
bounce from zero, project at 148 BPM.

Usage (from the Rhodes_Sample_Libary folder):
    venv/bin/python scripts/make_rebounce_midi.py
writes midi/keyscape_rebounce_sustains.mid and midi/keyscape_rebounce_sustains_manifest.json
(slot times in the manifest are at 120 BPM, like the other manifests).
"""
import json

from make_release_midi import write_midi, sec_to_ticks, note_name, SR, TEMPO_BPM

LENGTHS = "data/sustain_lengths.json"
OUT = "midi/keyscape_rebounce_sustains"
LAYERS = (16, 48, 64, 80, 112)
STRETCH = 148.0 / 120.0          # real seconds at 148 BPM -> MIDI seconds at 120 BPM


def main():
    lengths = json.load(open(LENGTHS))["samples"]
    events, slots = [], []
    t = 0.5 * STRETCH
    for n in range(21, 109):
        for v in LAYERS:
            name = f"rhodes_{note_name(n)}_n{n:03d}_v{v:03d}_sus.pcm"
            real_len = lengths[name] / SR
            hold = (real_len + 0.6) * STRETCH
            on_s, off_s = t, t + hold
            end_s = off_s + 0.4 * STRETCH
            events.append((sec_to_ticks(on_s), 1, 0x90, n, v))
            events.append((sec_to_ticks(off_s), 0, 0x80, n, v))
            slots.append({"note": n, "name": note_name(n), "velocity": v,
                          "old_file": name, "old_samples": lengths[name],
                          "on_sample": round(on_s * SR), "off_sample": round(off_s * SR),
                          "end_sample": round(end_s * SR)})
            t = end_s + 0.3 * STRETCH
    total = t + 1.0
    write_midi(f"{OUT}.mid", events, sec_to_ticks(total))
    json.dump({"sample_rate": SR, "tempo_bpm": TEMPO_BPM, "intended_tempo_bpm": 148.0,
               "velocity_layers": list(LAYERS), "total_seconds": round(total, 3), "slots": slots},
              open(f"{OUT}_manifest.json", "w"), indent=1)
    print(f"Wrote {OUT}.mid + manifest: {len(slots)} notes, bounce {total / STRETCH / 60:.1f} min at 148 BPM")


if __name__ == "__main__":
    main()
