# MotionX ESP32 — local stats for the FlexiSpot MotionX walking pad

Turn a FlexiSpot **MotionX** walking pad (Basic, no app) into a connected device — **without any cloud**.

An ESP32 listens to the treadmill's internal bus, records every session, and sends it over Wi‑Fi to a small self‑hosted server. You get a live dashboard on your network and your walks in **Apple Health**.

![Dashboard](docs/images/dashboard.png)

## What it does

- **Reads the treadmill passively** — the ESP32 only listens to the console → motor bus. It never sends anything to the treadmill.
- **Detects sessions automatically** — start, speed changes, stop. Each session is stored on the ESP32 (flash) and survives power cuts.
- **Live dashboard** — speed, time and distance update in real time (UDP + Server‑Sent Events), with a history of every session.
- **Apple Health** — an iOS Shortcut pulls new sessions from the server and logs a *Walking* workout plus steps.
- **Built to be closed in the treadmill** — over‑the‑air updates with automatic rollback, fallback Wi‑Fi access point, watchdog, safe mode, remote logs.
- **No cloud, no account, no dependency** — the server is a single Node.js file with zero npm packages.

## How it works

![Wiring on the console board (J1 cable, voltage divider to ESP32 G34) and data flow: treadmill console → ESP32 → Node.js server → dashboard and Apple Health](docs/images/wiring.jpg)

## Compatibility

Developed and tested on a **FlexiSpot MotionX, model WP01B‑EUV2** (manufacturer Ningbo Healthmate), control board **HSM‑W02‑APP‑CONB** (Holtek HT66F3185 MCU), 2026 production.

Other walking pads from the same family (WP01 / WR01 / WR02, often sold under different brands) very likely use the same bus. Check the [protocol](docs/protocol.md) with a logic analyzer before wiring anything.

## Repository

| Path | Content |
|---|---|
| [`firmware/motionx_v3/`](firmware/motionx_v3) | ESP32 firmware (Arduino IDE) |
| [`server/`](server) | Docker Compose file; `app/` holds the Node.js server and the dashboard |
| [`ios/`](ios) | Native iPhone app (SwiftUI): live view, history, Apple Health sync, Live Activity |
| [`tools/motionx_decode.py`](tools/motionx_decode.py) | Decodes a Saleae Logic CSV export of the bus |
| [`docs/protocol.md`](docs/protocol.md) | The reverse‑engineered TRX bus protocol |
| [`docs/hardware.md`](docs/hardware.md) | Boards, wiring, parts list, safety |
| [`docs/setup.md`](docs/setup.md) | Flashing, server, Docker, closing the treadmill |
| [`docs/apple-health.md`](docs/apple-health.md) | The iOS Shortcut, step by step |
| [`docs/api.md`](docs/api.md) | HTTP / UDP APIs of the ESP32 and the server |

## Quick start

1. **Hardware** — an ESP32 DevKit, two resistors, three wires. See [hardware.md](docs/hardware.md).
2. **Server** — `cd server && docker compose up -d` (or `cd server/app && node server.js`).
3. **Firmware** — set Wi‑Fi, server address and admin password at the top of `motionx_v3.ino`, flash it with Arduino IDE.
4. **Walk** — open `http://<server>:3000`.
5. **Apple Health** — build the Shortcut from [apple-health.md](docs/apple-health.md).

## ⚠️ Safety and disclaimer

The treadmill contains a **mains‑powered (230 V) power board** with large capacitors that stay charged after unplugging. Only work on the low‑voltage console board, always unplug the treadmill and wait a few minutes before opening it. Opening the device voids the warranty.

This project is not affiliated with or endorsed by FlexiSpot, Loctek or Ningbo Healthmate. Use it at your own risk.

## Status and ideas

- [x] Passive decoding of the TRX bus
- [x] Session storage, Wi‑Fi upload, live dashboard
- [x] Apple Health through an iOS Shortcut
- [x] OTA updates with rollback, fallback AP, watchdog
- [ ] Speed calibration (displayed speed vs real belt speed)
- [x] Native iOS app (indoor workouts, background sync) — see [`ios/`](ios)
- [ ] MQTT / Home Assistant
- [ ] Controlling the treadmill through the unpopulated `J5 LYAPP` header

## License

[MIT](LICENSE)
