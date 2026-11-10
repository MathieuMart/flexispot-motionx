# The TRX bus protocol

Reverse‑engineered with a 24 MHz logic analyzer on a MotionX WP01B‑EUV2. Everything below was verified on captures of real sessions (start, speed changes, programs, stop).

## Where it is

The console board (`HSM-W02-APP-CONB`) and the power/motor board (`…-F004-DRVB-EM`) are linked by a 3‑wire cable, **J1 `CON`** on the console side, **J4** on the power board:

| Pin | Signal |
|---|---|
| 5V | 5 V supply for the console board |
| TRX | data, single wire |
| GND | ground |

The TRX line goes through optocouplers (PT2/PT3/PT4 "317C") on the power board, so the console side is **galvanically isolated from mains**. At rest the line sits at about **3.1–3.5 V**.

> The `TRX` pin of the `J3 KEYB` header is **not** this bus, despite the silkscreen. Use the middle wire of the J1 cable.

## Physical layer

This is **not a UART**. It is pulse‑width coding, one bit every 2 or 3 ms:

```
bit 0 :  ‾‾‾\_____/‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾\...      low 0.5 ms, then high 1.5 ms
bit 1 :  ‾‾‾\_______________/‾‾‾‾‾‾‾‾\...    low 1.5 ms, then high 1.5 ms
```

- Decision threshold: low pulse **< 1 ms → 0**, **≥ 1 ms → 1**.
- A frame is **48 bits, MSB first** (6 bytes).
- A high level longer than **5 ms** ends the frame (the real gap is ≥ 11 ms).
- One frame every **120 ms**.
- When the motor runs, short spikes (a few µs to ~0.3 ms) appear on the line. The firmware uses a 200 µs integrating filter, which ignores them without distorting real pulses.

Direction: on every capture, only the console talks. The motor board never answered — the console drives the motor in open loop.

## Frame

```
EB 90 <state> <speed×10> 00 <checksum>
```

| Byte | Meaning |
|---|---|
| 0–1 | header, always `EB 90` |
| 2 | state (see below) |
| 3 | speed × 10, km/h (`1E` = 3.0 km/h, `3C` = 6.0 km/h) |
| 4 | always `00` on this model |
| 5 | `(b0 + b1 + b2 + b3 + b4) & 0xFF` |

### States

| Value | State |
|---|---|
| `00` | console starting up (~3 s after power‑on) |
| `01` | standby |
| `02` | countdown (3 s, start requested) |
| `03` | running |
| `05` | slowing down / stopping |

### Examples

```
EB 90 01 00 00 7C   standby
EB 90 02 00 00 7D   countdown
EB 90 03 0A 00 88   running 1.0 km/h
EB 90 03 1E 00 9C   running 3.0 km/h
EB 90 05 09 00 89   slowing down, 0.9 km/h
```

## Behaviour worth knowing

- **Ramps are done by the console.** A remote press from 3 to 6 km/h becomes +0.1 km/h every 120 ms on the bus. Stopping is −0.1 km/h every ~240 ms with state `05`, then `01`. So the bus always carries the speed the belt is being driven at.
- **Start**: `02` during the countdown, then `03` starting at 1.0 km/h.
- **Remote buttons** *Mute*, *M* and *Reset* (when stopped) produce nothing on the bus. *Reset* while running stops the belt (`05` then `01`). *P* programs just change the speed byte.
- **It is a set‑point, not a measurement.** The value is what the console asks the motor for (and what it displays). The real belt speed can differ by a few percent — see the calibration idea in the README.

## Unpopulated headers on the console board

| Header | Pins | Notes |
|---|---|---|
| `J5 LYAPP` | V G T R | Connector for FlexiSpot's optional Wi‑Fi module. V = 5 V. **R20 / R21 (100 Ω) are not fitted**, so T and R are not connected to the MCU on the basic model. |
| `J3 KEYB` | 5V TRX GND S– | Keyboard connector. Its TRX is an MCU input pulled up through R5 (15 kΩ); silent on this model. |
| `JP2` | C D G V | Holtek ICP programming port of the HT66F3185. |
| `J2 MP3` | G V | Audio module supply (absent). |

The official FlexiSpot app talks to its Wi‑Fi module through AWS IoT; the module's UART protocol on J5 is not documented here.

## Decoding a capture

Export the channel as **transitions** (Saleae Logic → Export Data → CSV), then:

```
python3 tools/motionx_decode.py capture.csv
```

It prints every state or speed change with checksum verification.
