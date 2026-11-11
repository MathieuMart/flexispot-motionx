# APIs

## ESP32 (`http://motionx.local`)

| Method & path | Auth | Description |
|---|---|---|
| `GET /` | – | device page |
| `GET /api/status` | – | live status JSON (below) |
| `GET /api/sessions?limit=30` | – | stored sessions, newest first |
| `GET /api/log` | – | text log since boot |
| `GET /api/config?server=…` | admin | change the server URL |
| `GET /api/config?resend=1` | admin | upload all stored sessions again |
| `POST /api/wifi` `ssid`, `pass` | admin | change Wi‑Fi network |
| `GET /api/reboot` (`?normal=1` leaves safe mode) | admin | reboot |
| `POST /update` (multipart `.ino.bin`) | admin | OTA firmware update |

*admin* = HTTP Basic auth, user `admin`, password `ADMIN_PASS`.

### Status JSON

Sent by `/api/status`, by UDP and by `POST /api/live`:

```json
{ "device":"motionx", "fw":"3.0", "ts":1794338616, "uptime_s":5230,
  "signal":true, "state":3, "state_name":"walking", "speed_kmh":3.4,
  "in_session":true, "session_id":12, "session_ms":95400, "elapsed_s":95, "walk_s":91, "distance_m":78.4,
  "frames_ok":8123, "frames_bad":2, "edges_lost":0,
  "stored":12, "pending":0, "fs_used_kb":64, "fs_total_kb":1408,
  "wifi":true, "ssid":"…", "ip":"192.168.1.23", "rssi":-58, "ap":false, "server":"http://192.168.1.10:3000", "udp_sent":420,
  "heap":201000, "heap_min":176000, "reset":"power-on", "crashes":0, "safe_mode":false }
```

## ESP32 → server

| Channel | When | Payload |
|---|---|---|
| UDP to `<server host>:<server port>` | on every speed/state change, else every 1 s while walking / 5 s idle | status JSON |
| `POST /api/live` | every 30 s walking / 60 s idle (fallback) | status JSON |
| `POST /api/sessions` | when a session ends, retried until HTTP 2xx | session JSON |

### Session JSON

```json
{ "id":12, "device":"motionx", "fw":"3.0", "start":1794338616,
  "duration_s":124, "walk_s":120, "distance_m":90.3, "max_kmh":3.0, "avg_kmh":2.71,
  "end":"stop", "truncated":false,
  "events":[[0,2,0],[3010,3,10],[3130,3,11], …] }
```

`events` are the raw changes: `[ms since start, state, speed×10]`. `start` is a Unix timestamp (0 if the ESP32 had no NTP time yet — the server then estimates it). `end` is `stop`, `signal_lost` (no frame for 3 s), `interrupted` (power cut, session recovered) or `update` (OTA during a walk). Sessions recorded by older firmware use `signal_perdu`, `interrompue` and `mise_a_jour` instead.

## Server (`http://<server>:3000`)

| Method & path | Description |
|---|---|
| `GET /` | dashboard |
| `GET /api/stream` | Server‑Sent Events: `init` `{live, trace}`, `live` `{live, point, session_id}`, `session` `{file, id}` |
| `GET /api/live` | last status (`live`), current session trace, UDP packet counter |
| `GET /api/sessions` | all sessions with `computed` (distance, walk time, steps, kcal) and Health status, plus `settings` |
| `GET /api/sessions/<file>` | one full session (`?raw` = the file as received, see *Pauses*) |
| `GET /api/settings` | profile, daily goal and pause length |
| `POST /api/settings` | change some of them (JSON, only the fields to change); HTTP 400 with the reason if a value is invalid |
| `GET /api/health/pending` | sessions to send to Apple Health (oldest first) |
| `GET /api/health/done?file=…` | mark one as synced |
| `GET /api/health/reset` | mark all as not synced |

### Settings

Kept in `data/settings.json` and changed from the dashboard (button next to the status pill):

```json
{ "height_cm":175, "weight_kg":75, "step_factor":1, "goal_type":"walk_min", "goal_value":30, "merge_gap_s":300 }
```

`step_factor` multiplies the estimated steps (1.05 = 5 % more, to match a watch). `goal_type` is `walk_min`,
`distance_km` or `steps`; `goal_value` 0 means no daily goal. Steps and calories are always recomputed from the
raw events, so a change applies to the whole history (workouts already in Apple Health keep their values).

### Pauses

Two sessions separated by less than `merge_gap_s` (5 min by default, 0 = never) are one walk. The files stay as
the ESP32 sent them; the grouping is done on every read:

- `GET /api/sessions` lists the walk once, under the `file` of its first part, with summed values, `duration_s`
  from the first start to the last stop, and three extra fields: `parts` (files), `ids` and `pause_s`.
- `GET /api/sessions/<file>` of that first file returns the whole walk, the events of the parts following each
  other on the same clock (speed 0 during the pause). Add `?raw` to get the file alone.
- Apple Health still receives each part as its own workout, right after it ends: `/api/health/*` are unchanged.
  A walk shows as synced once all its parts are.

### Live status

`live` is the status JSON of the ESP32 plus what the server adds: `received_at` (ms, server clock), `from`
(address of the ESP32), `via` (`udp` or `http`) and, during a session, `est`:

```json
"est": { "steps": 5705, "kcal": 253.8, "steps_per_min": 88, "kcal_per_h": 228 }
```

`steps` and `kcal` are estimated for the session in progress with the same formulas as the stored sessions;
the two rates are those of the current speed, so a page can keep its counters moving between two packets.

When the session in progress started after a short pause (see *Pauses*), `live` also has `carry`, what the walk
already counted before the pause: `{ "distance_m":522.8, "walk_s":477, "steps":786, "kcal":36, "sessions":1 }`.
The dashboard adds it to the live counters.

### Using the live stream in your own page

```js
const es = new EventSource('http://192.168.1.10:3000/api/stream');
es.addEventListener('live', e => {
  const { live, point } = JSON.parse(e.data);
  console.log(live.speed_kmh, live.state, live.distance_m, live.est && live.est.kcal);
});
```
