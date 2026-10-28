#!/usr/bin/env python3
"""Q-Audion message sounds: original, fully synthesized, deterministic.

Every sample is computed here from decaying sine partials. No recordings, no existing melodies, no third-party
audio of any kind. Running the script twice yields byte-identical files.

Output: 44.1 kHz, mono, 16-bit PCM WAV, each well under 2 s (the notification sound limit is 30 s), written to
QAudionApp/Resources/MessageSounds/qa_msg_<id>.wav.

Usage: python3 gen_message_sounds.py [output dir]      (Python 3.9+, standard library only)
"""
import math
import os
import struct
import sys
import wave

SR = 44_100
PEAK = 0.7  # about -3 dBFS


def midi(m):
    return 440.0 * 2.0 ** ((m - 69) / 12.0)


def note(freq, dur, decay, partials=((1.0, 1.0), (2.0, 0.28), (3.0, 0.08)), attack=0.004, drop=0.0):
    """One struck tone: sum of sine partials with an exponential decay; `drop` bends the pitch down."""
    n = int(dur * SR)
    out = []
    phase = [0.0] * len(partials)
    for i in range(n):
        t = i / SR
        f = freq * (1.0 - drop * min(1.0, t / dur))
        env = math.exp(-t * decay) * min(1.0, t / attack)
        s = 0.0
        for k, (mult, amp) in enumerate(partials):
            phase[k] += 2.0 * math.pi * f * mult / SR
            s += amp * math.sin(phase[k])
        out.append(s * env)
    return out


def mix(parts, total):
    buf = [0.0] * int(total * SR)
    for t0, sig, gain in parts:
        i0 = int(t0 * SR)
        for j, v in enumerate(sig):
            if i0 + j < len(buf):
                buf[i0 + j] += v * gain
    return buf


def finish(buf):
    peak = max(abs(v) for v in buf) or 1.0
    scale = PEAK / peak
    fade = int(0.02 * SR)
    for i in range(fade):  # 20 ms fade-out so the file never ends on a click
        buf[len(buf) - 1 - i] *= i / fade
    return [int(round(max(-1.0, min(1.0, v * scale)) * 32767)) for v in buf]


SOUNDS = {
    # a single bright drop
    "goccia": lambda: mix([(0.0, note(midi(88), 0.55, 9.0, drop=0.03), 1.0)], 0.55),
    # two rising bell notes
    "nota": lambda: mix([(0.0, note(midi(79), 0.8, 5.5), 0.9), (0.14, note(midi(86), 0.9, 5.0), 1.0)], 1.04),
    # soft low pop
    "tocco": lambda: mix([(0.0, note(midi(55), 0.3, 14.0, partials=((1.0, 1.0), (2.0, 0.15)), drop=0.35), 1.0)], 0.3),
    # two short pings on the same pitch
    "doppio": lambda: mix([(0.0, note(midi(81), 0.35, 11.0), 0.9), (0.15, note(midi(81), 0.4, 10.0), 1.0)], 0.55),
    # three falling notes
    "brezza": lambda: mix([(0.0, note(midi(88), 0.6, 7.0), 0.8), (0.12, note(midi(83), 0.6, 7.0), 0.9),
                           (0.24, note(midi(79), 0.8, 6.0), 1.0)], 1.04),
}


def main():
    here = os.path.dirname(os.path.abspath(__file__))
    out_dir = sys.argv[1] if len(sys.argv) > 1 else os.path.join(here, "..", "..", "QAudionApp", "Resources", "MessageSounds")
    os.makedirs(out_dir, exist_ok=True)
    for sid, make in SOUNDS.items():
        samples = finish(make())
        path = os.path.join(out_dir, "qa_msg_%s.wav" % sid)
        with wave.open(path, "wb") as w:
            w.setnchannels(1)
            w.setsampwidth(2)
            w.setframerate(SR)
            w.writeframes(struct.pack("<%dh" % len(samples), *samples))
        print(path, "%.2f s" % (len(samples) / SR))


if __name__ == "__main__":
    main()
