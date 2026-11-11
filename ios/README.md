# MotionX iOS

iPhone app (SwiftUI, iOS 17+) for the MotionX server (`server/app/server.js`).

- **Live**: treadmill state, speed, duration, distance, estimated steps and calories, and the speed profile, in real time through `GET /api/stream` (SSE), falling back to `GET /api/live`.
- **History**: `GET /api/sessions` (summary and chart of the last 7 days, sessions grouped by day), details through `GET /api/sessions/<file>`.
- **Apple Health**: replaces the Shortcut. `GET /api/health/pending` → an indoor *Walking* workout (distance, kcal, steps) → `GET /api/health/done?file=…`.
  No duplicates: each workout carries the HealthKit sync identifier `motionx.<file>`. Sync runs when the app opens, at the end of each session (app open) and in the background (BGAppRefresh).
- **Live Activity** (lock screen and Dynamic Island): speed, walking timer, distance, steps, kcal. It starts when a session begins while the app is open, and ends with a summary shown for 10 minutes. Without push notifications (free Personal Team), the app itself updates it; the "Lock screen updates" option keeps the app awake during the session by playing mixed silent audio (`audio` background mode: fine for personal use, rejected on the App Store).

The server needs no change.

## Install on your iPhone

1. Open `MotionX.xcodeproj` in Xcode.
2. MotionX target › Signing & Capabilities: pick your Team (and change the bundle id `ch.perso.motionx` if it is already taken). Do the same for the MotionXWidgets target.
3. Plug in the iPhone (Developer Mode enabled), select it as the destination, then press ⌘R.
4. In the app, Settings tab: enter the server address, e.g. `192.168.1.10:3000`, then test it, save, and allow access to Health.

With a free Apple account, the app must be reinstalled every 7 days (Apple limit); with a paid developer account, once a year.

## Notes

- Plain HTTP is allowed (ATS exception) to reach the server on the local network; away from home, go through a VPN (Tailscale, WireGuard…).
- Live steps and calories use the same formulas as `server.js` (the profile set in the dashboard settings is read from the server).
