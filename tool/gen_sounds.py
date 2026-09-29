"""Generate Cairn's alert and UI sounds: short, soft bell tones.

Run from the repo root: `python tool/gen_sounds.py`. Writes 16-bit mono WAVs
to android/app/src/main/res/raw/ (notification channel sounds, referenced by
name) and assets/sounds/ (in-app sound effects). Pure standard library, so the
sounds can be regenerated or tweaked without any tooling.
"""
import math
import os
import struct
import wave

RATE = 44100


def bell(freq, dur, gain=0.5, decay=6.0):
    """A soft bell: a sine with a touch of 2nd/3rd harmonic, a 5 ms attack and
    an exponential decay."""
    n = int(RATE * dur)
    out = []
    for i in range(n):
        t = i / RATE
        env = min(1.0, t / 0.005) * math.exp(-decay * t)
        s = (math.sin(2 * math.pi * freq * t)
             + 0.25 * math.sin(2 * math.pi * 2 * freq * t)
             + 0.08 * math.sin(2 * math.pi * 3 * freq * t))
        out.append(gain * env * s / 1.33)
    return out


def seq(notes):
    """Mix (start seconds, samples) pairs into one track."""
    end = max(int(start * RATE) + len(s) for start, s in notes)
    mix = [0.0] * end
    for start, s in notes:
        o = int(start * RATE)
        for i, v in enumerate(s):
            mix[o + i] += v
    peak = max(abs(v) for v in mix) or 1
    scale = min(1.0, 0.9 / peak)
    return [v * scale for v in mix]


# Notes (Hz), from a C-major pentatonic so everything sounds related.
C5, E5, G5, A5, C6, E6 = 523.25, 659.25, 783.99, 880.00, 1046.50, 1318.51

SOUNDS = {
    # Someone arrived at a place: a rising two-note chime.
    'cairn_arrive': seq([(0.0, bell(E5, 0.5)), (0.14, bell(A5, 0.7))]),
    # Someone left a place: the same two notes, falling.
    'cairn_leave': seq([(0.0, bell(A5, 0.5)), (0.14, bell(E5, 0.7))]),
    # A contact went quiet: two low, soft taps.
    'cairn_quiet': seq([(0.0, bell(C5, 0.35, 0.4, 9)),
                        (0.2, bell(C5, 0.5, 0.35, 8))]),
    # A new contact: a bright three-note arpeggio.
    'cairn_contact': seq([(0.0, bell(C5, 0.5)), (0.1, bell(E5, 0.5)),
                          (0.2, bell(G5, 0.8))]),
    # In-app: something saved or set — a single short, high tick.
    'cairn_tick': seq([(0.0, bell(E6, 0.18, 0.35, 22))]),
    # In-app: connected with someone — a quick rising pair, up an octave.
    'cairn_connected': seq([(0.0, bell(G5, 0.4)), (0.09, bell(C6, 0.6))]),
}

RAW = ['cairn_arrive', 'cairn_leave', 'cairn_quiet', 'cairn_contact']
ASSETS = ['cairn_tick', 'cairn_connected'] + RAW  # RAW too, for previews


def write(path, samples):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with wave.open(path, 'wb') as w:
        w.setnchannels(1)
        w.setsampwidth(2)
        w.setframerate(RATE)
        w.writeframes(b''.join(
            struct.pack('<h', int(max(-1, min(1, v)) * 32767)) for v in samples))


for name in RAW:
    write(f'android/app/src/main/res/raw/{name}.wav', SOUNDS[name])
for name in ASSETS:
    write(f'assets/sounds/{name}.wav', SOUNDS[name])
print('wrote', len(RAW), 'raw and', len(ASSETS), 'asset sounds')
