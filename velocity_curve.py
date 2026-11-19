#!/usr/bin/env python3
"""Generate the velocity lookup table used by calc_velocity() in nollama_top.v.

Usage: velocity_curve.py            print the Verilog case entries
       velocity_curve.py --check    compare against the table in nollama_top.v
       velocity_curve.py --write    replace the table in nollama_top.v

Curve: logarithmic in key travel time (top contact to bottom contact):
    v = 127 - 126 * ln(t / T_FAST) / ln(T_SLOW / T_FAST), clamped to 1..127
so velocity is 127 at T_FAST or faster and 1 at T_SLOW or slower.
Velocity never reaches 0, because a Note On with velocity 0 means Note Off.

Index mapping (must match vel_index() in nollama_top.v): the 12-bit timer
counts 100 us ticks. Indices 0..31 are exact tick counts (0..3.1 ms); above
that each doubling of time is split into 16 equal bins, giving 144 entries.
Each entry uses the middle of the tick range its bin covers.
"""
import math
import os
import re
import sys

TICK_MS = 0.1    # key_timer resolution (tick_100us)
T_FAST_MS = 2.0  # this travel time or faster -> velocity 127
T_SLOW_MS = 400.0  # this travel time or slower -> velocity 1

VERILOG = os.path.join(os.path.dirname(os.path.abspath(__file__)),
                       "midi_pluck.srcs", "sources_1", "imports", "Downloads",
                       "nollama_top.v")


def bins():
    """(first_tick, last_tick) for each table index, as vel_index() maps it."""
    out = [(t, t) for t in range(32)]          # exact below 3.2 ms
    for msb in range(5, 12):                   # t[5] .. t[11] set
        step = 1 << (msb - 4)                  # 16 bins per doubling
        for j in range(16):
            lo = (1 << msb) + j * step
            out.append((lo, lo + step - 1))
    return out


def velocity(ticks):
    t_ms = ticks * TICK_MS
    if t_ms <= T_FAST_MS:
        return 127
    v = 127 - 126 * math.log(t_ms / T_FAST_MS) / math.log(T_SLOW_MS / T_FAST_MS)
    return max(1, min(127, round(v)))


def table():
    return [velocity((lo + hi) / 2) for lo, hi in bins()]


def verilog_lines(vals):
    lines = []
    for row in range(0, len(vals), 4):
        lines.append("                " + " ".join(
            f"{i:3d}: v = 7'd{vals[i]:3d};" for i in range(row, min(row + 4, len(vals)))))
    lines.append("                default: v = 7'd1;")
    return lines


# The case entries between "case (vel_index(ticks))" and "default:" (inclusive)
TABLE_RE = re.compile(r"(case \(vel_index\(ticks\)\)\n)(.*?default: v = 7'd1;)", re.S)


def main():
    vals = table()
    arg = sys.argv[1] if len(sys.argv) > 1 else ""

    if arg not in ("", "--check", "--write"):
        sys.exit(__doc__)
    if not arg:
        print("\n".join(verilog_lines(vals)))
        return

    with open(VERILOG) as f:
        src = f.read()
    m = TABLE_RE.search(src)
    if not m:
        sys.exit(f"velocity table not found in {VERILOG}")

    if arg == "--check":
        current = {int(i): int(v) for i, v in
                   re.findall(r"(\d+): v = 7'd\s*(\d+);", m.group(2))}
        bad = [i for i in range(len(vals)) if current.get(i) != vals[i]]
        if bad or len(current) != len(vals):
            for i in bad:
                print(f"index {i}: file has {current.get(i)}, curve gives {vals[i]}")
            sys.exit(1)
        print(f"OK: all {len(vals)} entries match")
    else:
        new = src[:m.start(2)] + "\n".join(verilog_lines(vals)) + src[m.end(2):]
        with open(VERILOG, "w") as f:
            f.write(new)
        print(f"wrote {len(vals)} entries to {VERILOG}")


if __name__ == "__main__":
    main()
