#!/usr/bin/env python3
"""Karplus-Strong ("pluck") tables and bit-exact model for synth_engine.v.

    python3 pluck_tables.py            print the tuning / decay summary
    python3 pluck_tables.py verilog    print the Verilog case tables
    python3 pluck_tables.py wav OUT    write a demo WAV (model output)

Per voice (key k = MIDI note 36 + k):
    delay line of N samples in a shared block RAM at offset BASE
    y[n] = sat16( g * (y[n-N] + y[n-N-1]) / 2  +  excitation )
    loop delay = N + 0.5 samples (the 2-point average adds half a sample)
    g = G / 65536: G_HOLD while the key is held, G_REL after release
Excitation: N samples of low-passed noise (x 2^EXC_SHIFT) after each key press.
"""
import math, struct, sys

FS = 100e6 / 2048            # sample rate, 48.828 kHz
T60_LOW, T60_HIGH = 4.0, 2.0 # ring time (to -60 dB) while held: C2 .. C4
T60_REL = 0.12               # ring time after the key is released
LFSR_SEED = 0xACE1ACE1
EXC_SHIFT = 2                # excitation gain 2^EXC_SHIFT (noise is 15-bit)

def freq(k):  return 440.0 * 2 ** ((36 + k - 69) / 12)

def tables():
    rows, base = [], 0
    for k in range(25):
        f = freq(k)
        n = round(FS / f - 0.5)
        p = n + 0.5                                   # loop period, samples
        t60 = T60_LOW * (T60_HIGH / T60_LOW) ** (k / 24)
        gh = round(65536 * 10 ** (-3 * p / (FS * t60)))
        gr = round(65536 * 10 ** (-3 * p / (FS * T60_REL)))
        cents = 1200 * math.log2((FS / p) / f)
        rows.append(dict(k=k, f=f, n=n, base=base, gh=min(gh, 65535), gr=gr,
                         t60=t60, cents=cents))
        base += n
    return rows, base

# ---------------------------------------------------------------- helpers
def sat16(x): return max(-32768, min(32767, x))
def lfsr_next(s):                       # Galois, x^32 + x^22 + x^2 + x + 1
    return (s >> 1) ^ (0x80200003 if s & 1 else 0)
def noise15(s):                         # lfsr[14:0] as signed 15-bit
    v = s & 0x7FFF
    return v - 0x8000 if v & 0x4000 else v
def brightness(vel): return 16 + ((vel * 7) >> 3)   # 16..127 (Q7)

class Pluck:
    """One sample of all 25 voices, in the same order and integer maths as
    synth_engine.v.  Returns the per-voice y values."""
    def __init__(self):
        self.rows, total = tables()
        self.mem = [0] * 16384
        self.ptr = [0] * 25; self.prev = [0] * 25
        self.exc = [0] * 25; self.lp = [0] * 25
        self.gate_old = [0] * 25
        self.lfsr = LFSR_SEED

    def step(self, gate, vel):
        ys = []
        for v in range(25):
            r = self.rows[v]
            noise = noise15(self.lfsr); self.lfsr = lfsr_next(self.lfsr)
            note_on = gate[v] and not self.gate_old[v]
            self.gate_old[v] = gate[v]
            excite = note_on or self.exc[v] != 0
            exc_n = r['n'] - 1 if note_on else (self.exc[v] - 1 if self.exc[v] else 0)
            lp = self.lp[v] + (((noise - self.lp[v]) * brightness(vel[v])) >> 7)
            a = self.mem[r['base'] + self.ptr[v]]
            g = r['gh'] if gate[v] else r['gr']
            fb = ((a + self.prev[v]) * g) >> 17
            y = sat16(fb + ((lp << EXC_SHIFT) if excite else 0))
            self.mem[r['base'] + self.ptr[v]] = y
            self.ptr[v] = 0 if self.ptr[v] + 1 == r['n'] else self.ptr[v] + 1
            self.prev[v] = a; self.exc[v] = exc_n; self.lp[v] = lp
            ys.append(y)
        return ys

def mix(ys, vel, mix_shift=2):        # MIX_SHIFT on the board (nollama_top.v)
    m = 0
    for v, y in enumerate(ys):
        m += (y * (vel[v] + 1)) >> 7
    return sat16(m >> mix_shift)

# ---------------------------------------------------------------- outputs
def verilog():
    rows, total = tables()
    def fn(name, width, key, comment):
        print(f"    function [{width-1}:0] {name};")
        print("        input [4:0] key;")
        print("        begin")
        print("            case (key)")
        for i in range(0, 25, 4):
            parts = [f"5'd{r['k']:<2}: {name} = {width}'d{r[key]};".ljust(len(name) + 22)
                     for r in rows[i:i+4]]
            print("            " + " ".join(parts).rstrip())
        print(f"            default: {name} = {width}'d0;")
        print("            endcase")
        print("        end")
        print("    endfunction\n")
    fn("ks_len", 10, 'n', '')
    fn("ks_base", 14, 'base', '')
    fn("ks_ghold", 16, 'gh', '')
    fn("ks_grel", 16, 'gr', '')
    print(f"    // total delay-line length {total} of 16384")

def summary():
    rows, total = tables()
    print(" key note    f(Hz)   N  base  G_hold G_rel  T60  tune(cents)")
    names = ['C','C#','D','D#','E','F','F#','G','G#','A','A#','B']
    for r in rows:
        nm = names[(36 + r['k']) % 12] + str((36 + r['k']) // 12 - 1)
        print(f"{r['k']:4} {nm:4} {r['f']:7.2f} {r['n']:4} {r['base']:5} {r['gh']:6} "
              f"{r['gr']:5} {r['t60']:4.1f} {r['cents']:+6.2f}")
    print("total delay-line samples:", total)

def wav(path):
    # C2, A2, C3, E3, C4 at velocity 127 (each held 1.5 s), then C3 at 127, 64, 16,
    # then a C-major chord, then a fast repeated note
    events, t = [], 0.0
    for k in (0, 9, 12, 16, 24):
        events.append((t, k, 127, 1.5)); t += 1.8
    for vel in (127, 64, 16):
        events.append((t, 12, vel, 1.2)); t += 1.5
    for k in (12, 16, 19, 24):
        events.append((t, k, 100, 2.5))
    t += 3.0
    for i in range(6):
        events.append((t + i * 0.15, 19, 110, 0.1))
    t += 1.5
    n = int(t * FS)
    p = Pluck(); out = []
    gate = [0] * 25; vel = [0] * 25
    for i in range(n):
        ts = i / FS
        gate = [0] * 25
        for (t0, k, ve, dur) in events:
            if t0 <= ts < t0 + dur:
                gate[k] = 1; vel[k] = ve
        out.append(mix(p.step(gate, vel), vel))
    rate = int(round(FS))
    with open(path, 'wb') as f:
        data = b''.join(struct.pack('<h', s) for s in out)
        f.write(b'RIFF' + struct.pack('<I', 36 + len(data)) + b'WAVEfmt ' +
                struct.pack('<IHHIIHH', 16, 1, 1, rate, rate * 2, 2, 16) +
                b'data' + struct.pack('<I', len(data)) + data)
    pk = max(abs(s) for s in out)
    print(f"wrote {path}: {t:.1f} s, peak {pk} ({20*math.log10(pk/32768):.1f} dBFS)")

if __name__ == '__main__':
    if len(sys.argv) > 1 and sys.argv[1] == 'verilog': verilog()
    elif len(sys.argv) > 2 and sys.argv[1] == 'wav':   wav(sys.argv[2])
    else: summary()
