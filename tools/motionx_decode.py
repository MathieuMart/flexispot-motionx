#!/usr/bin/env python3
"""Decodes the TRX bus (CON cable) of the FlexiSpot MotionX WP01 from a Saleae Logic
CSV export of transitions (columns: Time[s], level).

Encoding: 1 bit every 2-3 ms. Low level for 0.5 ms = 0, 1.5 ms = 1, followed by 1.5 ms high.
Frame: 48 bits MSB-first = 6 bytes  EB 90 <state> <speed×10> 00 <checksum>
Checksum = (EB+90+state+speed+00) & 0xFF.  One frame every 120 ms, gap ≥ 11 ms between frames.
Usage: python3 motionx_decode.py export.csv
"""
import csv, sys, collections

STATES = {0x01: "standby", 0x02: "start requested", 0x03: "walking", 0x05: "decelerating/stop"}

def load(fn):
    rows = [(float(t), int(v)) for t, v in csv.reader(open(fn)) if t[:1].isdigit()]
    # 1) glitch filter: drop pulses shorter than 0.25 ms (motor noise)
    pulses = [(t0, v0, (t1 - t0) * 1000) for (t0, v0), (t1, v1) in zip(rows, rows[1:])]
    clean = []
    for t, v, d in pulses:
        if d < 0.25 and clean:                        # glitch: merge it into the previous pulse
            clean[-1] = (clean[-1][0], clean[-1][1], clean[-1][2] + d)
        elif clean and clean[-1][1] == v:             # same level as the previous pulse: merge
            clean[-1] = (clean[-1][0], v, clean[-1][2] + d)
        else:
            clean.append((t, v, d))
    # 2) split into frames and bits
    frames, cur, start = [], [], None
    for t0, v0, d in clean:
        if v0 == 0:
            if start is None: start = t0
            cur.append(0 if d < 1.0 else 1)          # <1 ms = 0, otherwise 1
        elif d > 5 and cur:                           # silence = end of frame
            frames.append((start, cur)); cur, start = [], None
    if cur: frames.append((start, cur))
    return frames

def to_bytes(bits):
    bits = bits[:len(bits) - len(bits) % 8]
    return [int("".join(map(str, bits[i:i+8])), 2) for i in range(0, len(bits), 8)]

def main(fn):
    last = None
    for st, bits in load(fn):
        b = to_bytes(bits)
        if len(b) != 6:
            print(f"{st:8.3f}s  incomplete frame ({len(bits)} bits)"); continue
        ok = (sum(b[:5]) & 0xFF) == b[5]
        hexs = " ".join(f"{x:02X}" for x in b)
        if hexs == last: continue                     # only print changes
        last = hexs
        state = STATES.get(b[2], f"state 0x{b[2]:02X}")
        print(f"{st:8.3f}s  {hexs}  {'OK ' if ok else 'CRC?'}  {state:18s} speed {b[3]/10:.1f} km/h")

if __name__ == "__main__":
    main(sys.argv[1])
