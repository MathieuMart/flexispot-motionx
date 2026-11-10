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
  "signal":true, "state":3, "state_name":"en marche", "speed_kmh":3.4,
  "in_session":true, "session_id":12, "session_ms":95400, "elapsed_s":95, "walk_s":91, "distance_m":78.4,
  "frames_ok":8123, "frames_bad":2, "edges_lost":0,
  "stored":12, "pending":0, "fs_used_kb":64, "fs_total_kb":1408,
  "wifi":true, "ssid":"…", "ip":"192.168.1.23", "rssi":-58, "ap":false, "server":"http://192.168.1.10:3000", "udp_sent":420,
  "heap":201000, "heap_min":176000, "reset":"mise sous tension", "crashes":0, "safe_mode":false }
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

`events` are the raw changes: `[ms since start, state, speed×10]`. `start` is a Unix timestamp (0 if the ESP32 had no NTP time yet — the server then estimates it). `end` is `stop`, `signal_perdu` (signal lost), `interrompue` (power cut, recovered) or `mise_a_jour` (OTA during a walk).

## Server (`http://<server>:3000`)

| Method & path | Description |
|---|---|
| `GET /` | dashboard |
| `GET /api/stream` | Server‑Sent Events: `init` `{live, trace}`, `live` `{live, point, session_id}`, `session` `{file, id}` |
| `GET /api/live` | last status, current session trace, UDP packet counter |
| `GET /api/sessions` | all sessions with `computed` (distance, walk time, steps, kcal) and Health status |
| `GET /api/sessions/<file>` | one full session |
| `GET /api/health/pending` | sessions to send to Apple Health (oldest first) |
| `GET /api/health/done?file=…` | mark one as synced |
| `GET /api/health/reset` | mark all as not synced |

### Using the live stream in your own page

```js
const es = new EventSource('http://192.168.1.10:3000/api/stream');
es.addEventListener('live', e => {
  const { live, point } = JSON.parse(e.data);
  console.log(live.speed_kmh, live.state, live.distance_m);
});
```
