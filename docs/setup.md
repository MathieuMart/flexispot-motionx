# Setup

## 1. Server

The server is a single Node.js file with **no dependencies**. It receives sessions, keeps them as JSON files and serves the dashboard.

### Docker (recommended, e.g. on a NAS)

```
server/
├── docker-compose.yml
└── app/
    ├── server.js
    └── dashboard.html
```

Then:

```
cd server
docker compose up -d
```

The compose file publishes port **3000 in TCP and UDP** — both are needed (HTTP + real‑time UDP). It also sets `TZ`, which matters: without it, workouts land in Apple Health with a time offset.

Sessions are stored in `app/data/sessions/` on the host, so they survive container updates and go into your NAS backups.

On a UGREEN NAS (UGOS Pro): *Docker → Project → Create*, pick the folder, paste the compose file, deploy.

### Without Docker

```
cd server/app
HEIGHT_CM=180 WEIGHT_KG=78 node server.js
```

Node 16 or later.

### Settings (environment variables)

| Variable | Default | Effect |
|---|---|---|
| `PORT` | `3000` | HTTP **and** UDP port |
| `HEIGHT_CM` | `175` | first value of the height (stride length → steps); then changed in the dashboard settings |
| `WEIGHT_KG` | `75` | first value of the weight (calories); then changed in the dashboard settings |
| `HEALTH_MIN_WALK_S` | `0` | sessions shorter than this are never offered to Apple Health (e.g. `120`) |
| `TZ` | system | time zone for the dates sent to Apple Health |
| `ALLOWED_HOSTS` | – | names you open the dashboard with, besides IP addresses, `localhost` and `.local` names (e.g. `nas.home`); needed to save the settings from such a name |

Steps, calories and distance are **recomputed from the raw events** every time, so changing these values updates the whole history (but not what has already been written to Apple Health).

### Network

- Give the server a **fixed IP** (DHCP reservation on your router).
- Allow port 3000 TCP + UDP in the server's firewall.
- **Do not expose it to the internet**: there is no authentication.
- Inside Docker the server prints its container IP (`172.x.x.x`): ignore it, use the host's IP.

## 2. Firmware

### Arduino IDE

1. Install **Arduino IDE 2** and the **esp32** board package by Espressif (*Boards Manager*; URL `https://espressif.github.io/arduino-esp32/package_esp32_index.json`).
2. Open `firmware/motionx_v3/motionx_v3.ino` (the folder must keep that name, next to `page.h`).
3. Edit the top of the file:
   ```cpp
   const char* DEFAULT_WIFI_SSID = "YOUR_WIFI_SSID";      // 2.4 GHz network
   const char* DEFAULT_WIFI_PASS = "YOUR_WIFI_PASSWORD";
   const char* DEFAULT_SERVER    = "http://192.168.1.10:3000";
   const char* ADMIN_PASS        = "change-me-1234";      // 8+ chars, also the fallback AP password
   ```
4. *Tools → Board*: **ESP32 Dev Module**.
   *Tools → Partition Scheme*: **Default 4MB with spiffs** — required for OTA updates.
5. Upload. If it stays on *Connecting…*, hold the **BOOT** button.

Serial monitor at 115200: `s` prints the full status, `r` toggles raw frames.

### Test without the treadmill

Set `#define SIMULATION 1`, put a wire between **G25 and G34**: the ESP32 generates a fake session every minute.

### Device page

`http://motionx.local` (or the ESP32's IP) shows live status, stored sessions, settings, firmware update and diagnostics. Settings, update and reboot ask for the user `admin` and `ADMIN_PASS`.

## 3. Before closing the treadmill

Once closed, there is no USB anymore. While the cable is still reachable, test:

1. **An OTA update** — change `FW_VERSION`, *Sketch → Export Compiled Binary*, send the `.ino.bin` from the device page, check the new version.
2. **Rollback** — upload this through the page (same partition scheme):
   ```cpp
   extern "C" bool verifyRollbackLater() { return true; }
   void setup() { delay(3000); ESP.restart(); }
   void loop() {}
   ```
   The ESP32 must come back to the previous firmware by itself within a minute.
3. **Fallback Wi‑Fi** — enter a wrong network name on the page, wait 90 s, join `MotionX-Setup`, open `http://192.168.4.1`, fix it.
4. **Power from the treadmill** — remove USB, power from J5‑V, walk for an hour. In *Diagnostics*, *Last boot* must stay "power on" and *Crashes* at 0.

## Robustness features

| Feature | Behaviour |
|---|---|
| Upload queue | sessions stay in flash and are retried every 30 s until the server answers |
| Power cut during a walk | a checkpoint is written every minute and recovered at boot |
| OTA rollback | a new firmware is only marked valid once it is reachable on the network |
| Fallback AP | `MotionX-Setup` opens if the Wi‑Fi is unreachable for 90 s |
| Watchdog | reboot if the main loop freezes for 30 s |
| Safe mode | after 5 crashes in a row, only Wi‑Fi, the page and OTA stay active |
| Storage | keeps the last 200 sessions and always leaves free space |
| Weekly reboot | after 7 days of uptime, when idle and with nothing left to upload |
