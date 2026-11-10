# Apple Health

Only an app running on the iPhone can write to Apple Health — not the ESP32, not the server. This project uses the built‑in **Shortcuts** app: it asks the server for sessions not yet synced, logs them, and confirms them so they are never sent twice.

```
server  GET /api/health/pending  ──►  Shortcut  ──►  Log Workout + Log Health Sample
        GET /api/health/done?file=…  ◄──┘
```

Action names below are those of the English iOS 26 interface. Replace `192.168.1.10:3000` with your server.

## Check first

Open `http://192.168.1.10:3000/api/health/pending` in Safari on the iPhone. You should see `{"count":…`. If the count is 0, walk at least as long as `HEALTH_MIN_WALK_S` first.

Each session looks like:

```json
{ "file": "motionx_1794338616_000012.json", "id": 12,
  "start": "2026-11-10T20:03:36+01:00", "end": "2026-11-10T20:05:36+01:00",
  "duration_min": 2, "distance_km": 0.09, "distance_m": 90, "kcal": 8, "steps": 143 }
```

## Build the Shortcut

**Shortcuts → + →** name it *Treadmill to Health*.

1. **Get Contents of URL** — `http://192.168.1.10:3000/api/health/pending`
2. **Get Dictionary Value** — Get *Value* for `sessions` in *Contents of URL*
3. **Repeat with Each** — item in *Dictionary Value*

   Inside the loop:

4. For each of `start`, `duration_min`, `kcal`, `distance_m`, `steps`, `file`, add a pair:
   - **Get Dictionary Value** — Get *Value* for `<key>` in *Repeat Item*
   - **Set Variable** — name `<key>`, value *Dictionary Value*
5. **Log Workout** (tap *Show More*)
   - Type **Walking**
   - Start Date: `start`
   - Duration: `duration_min`, unit **min**
   - Active Energy: `kcal`, unit **Cal** (capital C) or **kcal** — *not* `cal`
   - Distance: `distance_m`, unit **m**
6. **Log Health Sample** — type **Steps**, value `steps`, *Show More* → Start Date `start`
7. **Get Contents of URL** — `http://192.168.1.10:3000/api/health/done?file=` followed by the `file` variable, no space
8. After **End Repeat**: **Show Notification** — "Treadmill sessions added to Health"

Run it once by hand and allow Health access (Workouts, Steps) and the local network connection.

## Automate it

**Automation → + → Wi‑Fi** (joining your network) or **Time of Day** → *Run Shortcut* → *Treadmill to Health* → **Run Immediately**.

The iPhone must be **unlocked** when it runs (Health data is encrypted while locked), so prefer a daytime trigger.

## Troubleshooting

| Symptom | Cause / fix |
|---|---|
| Distance 1000× too small | unit set to m with `distance_km` — use `distance_m` + **m** |
| Energy 0 or 0.01 kcal | unit `cal` (small calorie) — choose **Cal** / **kcal** |
| Start Date error | add **Get Dates from Input** on `start` before Log Workout |
| Same session logged again and again | the *done* URL is malformed (space or line break before the variable) |
| Wrong time in Health | the server has no `TZ` set |

To redo a test: delete the entries in Health, then open `/api/health/reset` (marks **all** sessions as not synced).

## Known limitations

- Workouts are not flagged as *indoor*: Shortcuts' Log Workout action has no such option. Rings, steps, distance and calories are not affected.
- Steps and calories are **estimates** computed from speed, height and weight — the treadmill has no step sensor.
