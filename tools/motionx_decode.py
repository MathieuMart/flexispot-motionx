#!/usr/bin/env python3
"""Décode le bus TRX (câble CON) du FlexiSpot MotionX WP01 à partir d'un export CSV
de transitions Saleae Logic (colonnes : Time[s], niveau).

Codage : 1 bit toutes les 2-3 ms. Niveau bas 0,5 ms = 0, 1,5 ms = 1, suivi de 1,5 ms haut.
Trame : 48 bits MSB-first = 6 octets  EB 90 <état> <vitesse×10> 00 <somme>
Somme = (EB+90+état+vitesse+00) & 0xFF.  Une trame toutes les 120 ms, pause ≥ 11 ms entre trames.
Usage : python3 motionx_decode.py export.csv
"""
import csv, sys, collections

STATES = {0x01: "veille", 0x02: "demande start", 0x03: "en marche", 0x05: "décélération/stop"}

def load(fn):
    rows = [(float(t), int(v)) for t, v in csv.reader(open(fn)) if t[:1].isdigit()]
    # 1) filtre anti-parasites : on supprime les impulsions < 0,25 ms (bruit moteur)
    pulses = [(t0, v0, (t1 - t0) * 1000) for (t0, v0), (t1, v1) in zip(rows, rows[1:])]
    clean = []
    for t, v, d in pulses:
        if d < 0.25 and clean:                        # parasite : on le fusionne avec le précédent
            clean[-1] = (clean[-1][0], clean[-1][1], clean[-1][2] + d)
        elif clean and clean[-1][1] == v:             # même niveau que le précédent : fusion
            clean[-1] = (clean[-1][0], v, clean[-1][2] + d)
        else:
            clean.append((t, v, d))
    # 2) découpe en trames et bits
    frames, cur, start = [], [], None
    for t0, v0, d in clean:
        if v0 == 0:
            if start is None: start = t0
            cur.append(0 if d < 1.0 else 1)          # <1 ms = 0, sinon = 1
        elif d > 5 and cur:                           # silence = fin de trame
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
            print(f"{st:8.3f}s  trame incomplète ({len(bits)} bits)"); continue
        ok = (sum(b[:5]) & 0xFF) == b[5]
        hexs = " ".join(f"{x:02X}" for x in b)
        if hexs == last: continue                     # n'affiche que les changements
        last = hexs
        state = STATES.get(b[2], f"état 0x{b[2]:02X}")
        print(f"{st:8.3f}s  {hexs}  {'OK ' if ok else 'CRC?'}  {state:18s} vitesse {b[3]/10:.1f} km/h")

if __name__ == "__main__":
    main(sys.argv[1])
