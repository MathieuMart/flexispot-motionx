/*
 *  MotionX (FlexiSpot WP01) — v3.0 "boîtier fermé"
 *  ------------------------------------------------
 *  Carte : ESP32 Dev Module (ESP32-WROOM-32).  Outils > Partition Scheme : "Default 4MB with spiffs" (indispensable pour l'OTA).
 *  Dossier du croquis : motionx_v3/  contenant motionx_v3.ino ET page.h
 *
 *  Fonctions (mêmes que la v2.1) :
 *    - décodage du bus TRX sur G34, détection des séances, stockage en flash, envoi HTTP au serveur, temps réel UDP.
 *  Ajouts pour fonctionner sans accès physique :
 *    - MISE À JOUR PAR WI-FI : page web > "Mise à jour" > fichier .bin. Si le nouveau firmware plante ou devient
 *      injoignable dans sa première minute, l'ESP32 revient automatiquement à l'ancien (rollback).
 *    - WI-FI RECONFIGURABLE : identifiants modifiables depuis la page. Si le réseau reste introuvable 90 s,
 *      l'ESP32 ouvre son propre Wi-Fi de secours "MotionX-Setup" (mot de passe = ADMIN_PASS), page http://192.168.4.1
 *    - CHIEN DE GARDE : redémarrage automatique si la boucle principale se fige plus de 30 s.
 *    - MODE SANS ÉCHEC : après 5 plantages consécutifs, seuls le Wi-Fi, la page et la mise à jour restent actifs.
 *    - DIAGNOSTIC À DISTANCE : journal (/api/log), cause du dernier redémarrage, mémoire, qualité du décodage.
 *    - Stockage auto-nettoyé (nombre de séances et espace libre), séances vides ignorées, redémarrage préventif hebdomadaire.
 *
 *  Les actions sensibles (réglages, mise à jour, redémarrage) demandent l'identifiant "admin" et ADMIN_PASS.
 *
 *  Câblage :  TRX (fil central J1) ──[2,2 kΩ]──┬── G34        5 V tapis (J5-V) ── V5/VIN       GND tapis ── GND
 *                                             └──[8,8 à 10 kΩ]── GND
 *
 *  Protocole TRX : 1 bit = niveau bas 0,5 ms (0) ou 1,5 ms (1) + 1,5 ms haut ; trame 48 bits MSB first :
 *      EB 90 <état> <vitesse×10> 00 <somme & 0xFF>   toutes les 120 ms
 *      état : 00 initialisation, 01 veille, 02 compte à rebours, 03 en marche, 05 décélération/arrêt
 */
#include <WiFi.h>
#include <WebServer.h>
#include <HTTPClient.h>
#include <WiFiUdp.h>
#include <ESPmDNS.h>
#include <LittleFS.h>
#include <Preferences.h>
#include <Update.h>
#include <Ticker.h>
#include <time.h>
#include <stdarg.h>
#include <esp_system.h>
#include <esp_ota_ops.h>
#include "page.h"

// ============================================================ CONFIGURATION (valeurs de départ, modifiables ensuite par la page web)
const char* DEFAULT_WIFI_SSID = "YOUR_WIFI_SSID";
const char* DEFAULT_WIFI_PASS = "YOUR_WIFI_PASSWORD";
const char* DEFAULT_SERVER    = "http://192.168.1.10:3000";
const char* DEVICE_NAME       = "motionx";            // http://motionx.local
const char* ADMIN_USER        = "admin";
const char* ADMIN_PASS        = "change-me-1234";    // 8 caractères minimum : sert aussi de mot de passe au Wi-Fi de secours
const char* AP_SSID           = "MotionX-Setup";

const uint32_t KEEP_SESSIONS  = 200;                  // nombre maximal de séances gardées en flash
const uint32_t MIN_FREE_BYTES = 96 * 1024;            // en dessous, les plus anciennes séances sont effacées
const float    MIN_SESSION_M  = 1.0;                  // une séance plus courte (start puis stop) n'est pas enregistrée

#define SIMULATION 0            // 1 = trames factices sur G25 (fil G25 -> G34), pour tester sans le tapis
#define FW_VERSION "3.0"

// Avec cette fonction, un firmware reçu par Wi-Fi n'est déclaré bon qu'après avoir prouvé qu'il tourne (voir loop).
extern "C" bool verifyRollbackLater() { return true; }

// ============================================================ DÉCODEUR TRX (inchangé depuis la v1.3)
const int TRX_PIN = 34;
const int SIM_PIN = 25;
const uint32_t FILTER_US  = 200;
const uint32_t BIT_ONE_US = 1000;
const uint32_t GAP_US     = 5000;
const uint8_t  MAX_SPEED10 = 100;

struct Edge { uint32_t t; uint8_t level; };
struct Ev   { uint32_t ms; uint8_t state; uint8_t spd; };

const uint16_t EDGE_BUF = 4096;
volatile Edge     edges[EDGE_BUF];
volatile uint16_t edgeHead = 0, edgeTail = 0;
volatile uint32_t edgeOverflow = 0, edgeCount = 0;

void IRAM_ATTR onEdge() {
  uint16_t next = (edgeHead + 1) % EDGE_BUF;
  edgeCount++;
  if (next == edgeTail) { edgeOverflow++; return; }
  edges[edgeHead].t     = micros();
  edges[edgeHead].level = digitalRead(TRX_PIN);
  edgeHead = next;
}

bool     filtInit = false;
uint8_t  rawLevel = 1;   uint32_t rawSince = 0;   int32_t integ = FILTER_US;
uint8_t  cleanLevel = 1; uint32_t cleanEdgeT = 0;
uint64_t bitAcc = 0;     uint8_t  nBits = 0;
uint32_t framesOk = 0, framesBad = 0;
bool     showRaw = false;

// ============================================================ ÉTAT COURANT ET SÉANCE
uint8_t  curState = 0xFF, curSpeed10 = 0;
uint32_t lastFrameMs = 0;
bool     liveForce = false;

const uint16_t MAX_EVENTS = 2000;
Ev       events[MAX_EVENTS];
uint16_t nEvents = 0;   bool evTrunc = false;
bool     inSession = false;
uint32_t sesStartMs = 0, sesWalkMs = 0, lastCheckpointMs = 0, lastSessionEndMs = 0;
time_t   sesStartEpoch = 0;
double   sesDistM = 0;
uint8_t  sesMax10 = 0;

// ============================================================ RÉSEAU, STOCKAGE, SURVEILLANCE
Preferences prefs;
WebServer   web(80);
WiFiUDP     udp;
Ticker      watchdog;
String      serverUrl, wifiSsid, wifiPass;
uint32_t    nextId = 1, lastSent = 0, oldestId = 1;
uint32_t    uploadHoldStart = 0, uploadHoldMs = 0;
uint32_t    liveHoldStart = 0, liveHoldMs = 0, lastLiveMs = 0;
IPAddress   udpIp;   uint16_t udpPort = 0;
bool        udpReady = false, udpDue = false;
uint32_t    lastUdpMs = 0, udpSent = 0;
bool        mdnsStarted = false, fsOk = false, apActive = false, safeMode = false;
bool        wifiWas = false, otaAuth = false, otaOk = false, otaValidated = false, bootsCleared = false, rebootPending = false;
uint32_t    wifiLostMs = 0, wifiUpMs = 0, lastWifiRetryMs = 0, rebootAtMs = 0;
uint32_t    bootCount = 0, crashTotal = 0;
const char* resetText = "inconnu";

volatile uint32_t loopBeatMs = 0;                 // mis à jour à chaque tour de loop(), surveillé par le chien de garde
RTC_NOINIT_ATTR uint32_t wdtMagic;                // survit à un redémarrage logiciel : marque un redémarrage par le chien de garde
const uint32_t WDT_MAGIC = 0xD06F00D5;

// ------------------------------------------------------------ journal consultable à distance (/api/log)
const size_t LOG_SIZE = 6000;
char   logBuf[LOG_SIZE];
size_t logHead = 0;   bool logWrapped = false;

void logPut(const char* s) {
  while (*s) { logBuf[logHead++] = *s++; if (logHead >= LOG_SIZE) { logHead = 0; logWrapped = true; } }
}

void logMsg(const char* fmt, ...) {
  char line[230], pre[40];
  va_list ap; va_start(ap, fmt); vsnprintf(line, sizeof line, fmt, ap); va_end(ap);
  time_t now = time(nullptr);
  if (now > 1700000000) { struct tm t; gmtime_r(&now, &t); snprintf(pre, sizeof pre, "%02d/%02d %02d:%02d:%02d UTC  ", t.tm_mday, t.tm_mon + 1, t.tm_hour, t.tm_min, t.tm_sec); }
  else snprintf(pre, sizeof pre, "+%lus  ", (unsigned long)(millis() / 1000));
  Serial.println(line);
  logPut(pre); logPut(line); logPut("\n");
}

const char* stateName(uint8_t s) {
  switch (s) {
    case 0x00: return "initialisation";
    case 0x01: return "veille";
    case 0x02: return "compte a rebours";
    case 0x03: return "en marche";
    case 0x05: return "deceleration";
    default:   return "inconnu";
  }
}

bool timeOk() { return time(nullptr) > 1700000000; }
void sessionPath(char* out, size_t n, uint32_t id) { snprintf(out, n, "/s/%06u.json", (unsigned)id); }

void jsonEsc(const char* in, char* out, size_t n) {       // échappe " et \ pour les chaînes mises dans du JSON
  size_t o = 0;
  for (; *in && o + 2 < n; in++) {
    if (*in == '"' || *in == '\\') out[o++] = '\\';
    if ((uint8_t)*in >= 0x20) out[o++] = *in;
  }
  out[o] = 0;
}

// ============================================================ SÉANCES
void pruneStorage() {                 // limite le nombre de séances et garde de l'espace libre
  if (!fsOk) return;
  char path[24];
  uint32_t before = oldestId;
  while (nextId - oldestId > KEEP_SESSIONS) { sessionPath(path, sizeof path, oldestId); LittleFS.remove(path); oldestId++; }
  while (oldestId + 1 < nextId && LittleFS.totalBytes() - LittleFS.usedBytes() < MIN_FREE_BYTES) {
    sessionPath(path, sizeof path, oldestId); LittleFS.remove(path); oldestId++;
  }
  if (oldestId != before) {
    prefs.putUInt("oldest", oldestId);
    logMsg("Stockage : seances #%u a #%u effacees pour faire de la place", (unsigned)before, (unsigned)(oldestId - 1));
  }
}

void writeSession(const char* path, uint32_t id, uint32_t endMs, const char* reason) {
  if (!fsOk) return;
  File f = LittleFS.open(path, "w");
  if (!f) { logMsg("!!! ecriture impossible : %s", path); return; }
  time_t startEpoch = sesStartEpoch;
  if (!startEpoch && timeOk()) startEpoch = time(nullptr) - (time_t)((millis() - sesStartMs) / 1000);
  float avg = sesWalkMs ? (float)((sesDistM / 1000.0) / (sesWalkMs / 3600000.0)) : 0;
  f.printf("{\"id\":%u,\"device\":\"%s\",\"fw\":\"%s\",\"start\":%lu,\"duration_s\":%u,\"walk_s\":%u,"
           "\"distance_m\":%.1f,\"max_kmh\":%.1f,\"avg_kmh\":%.2f,\"end\":\"%s\",\"truncated\":%s,\"events\":[",
           (unsigned)id, DEVICE_NAME, FW_VERSION, (unsigned long)startEpoch,
           (unsigned)((endMs - sesStartMs) / 1000), (unsigned)(sesWalkMs / 1000),
           sesDistM, sesMax10 / 10.0, avg, reason, evTrunc ? "true" : "false");
  for (uint16_t i = 0; i < nEvents; i++)
    f.printf("%s[%u,%u,%u]", i ? "," : "", (unsigned)events[i].ms, (unsigned)events[i].state, (unsigned)events[i].spd);
  f.print("]}");
  f.close();
}

void addEvent(uint32_t ms, uint8_t state, uint8_t spd) {
  if (nEvents >= MAX_EVENTS) { evTrunc = true; return; }
  events[nEvents].ms = ms; events[nEvents].state = state; events[nEvents].spd = spd;
  nEvents++;
}

void startSession(uint32_t nowMs) {
  inSession = true; sesStartMs = nowMs; sesWalkMs = 0; sesDistM = 0; sesMax10 = 0;
  nEvents = 0; evTrunc = false; lastCheckpointMs = nowMs;
  sesStartEpoch = timeOk() ? time(nullptr) : 0;
  udpDue = true;
  logMsg(">>> debut de seance #%u", (unsigned)nextId);
}

void endSession(uint32_t endMs, const char* reason) {
  inSession = false; liveForce = true; udpDue = true; lastSessionEndMs = millis();
  if (fsOk) LittleFS.remove("/cur.json");
  if (sesDistM < MIN_SESSION_M) { logMsg("<<< seance vide ignoree (%s, %.1f m)", reason, sesDistM); return; }
  char path[24];
  uint32_t id = nextId;
  sessionPath(path, sizeof path, id);
  writeSession(path, id, endMs, reason);
  nextId++; prefs.putUInt("nextId", nextId);
  pruneStorage();
  uploadHoldMs = 0;
  logMsg("<<< fin de seance #%u (%s) : %us, marche %us, %.0f m, max %.1f km/h, %u evenements",
         (unsigned)id, reason, (unsigned)((endMs - sesStartMs) / 1000), (unsigned)(sesWalkMs / 1000), sesDistM, sesMax10 / 10.0, (unsigned)nEvents);
}

// ------------------------------------------------------------ une trame complète vient d'être reçue
void handleFrame(uint64_t bits, uint8_t n) {
  if (n != 48) { framesBad++; return; }
  uint8_t b[6];
  for (int i = 0; i < 6; i++) b[i] = (bits >> (8 * (5 - i))) & 0xFF;
  uint8_t sum = (b[0] + b[1] + b[2] + b[3] + b[4]) & 0xFF;
  uint8_t state = b[2], spd = b[3];
  bool known = (state == 0x00 || state == 0x01 || state == 0x02 || state == 0x03 || state == 0x05);
  bool ok = (b[0] == 0xEB && b[1] == 0x90 && sum == b[5] && known && spd <= MAX_SPEED10 && b[4] == 0x00);
  if (showRaw) Serial.printf("[%8.3fs] %02X %02X %02X %02X %02X %02X  %s\n", millis() / 1000.0, b[0], b[1], b[2], b[3], b[4], b[5], ok ? "OK" : "REJETEE");
  if (!ok) { framesBad++; return; }
  framesOk++;

  uint32_t nowMs = millis();
  if (!inSession && (state == 0x02 || state == 0x03)) startSession(nowMs);

  if (inSession && lastFrameMs) {
    uint32_t dt = nowMs - lastFrameMs;
    if (dt < 1000 && curSpeed10 > 0) {
      sesWalkMs += dt;
      sesDistM  += (curSpeed10 / 36.0) * (dt / 1000.0);
    }
  }
  lastFrameMs = nowMs;

  if (state != curState || spd != curSpeed10) {
    if (state != curState) {
      liveForce = true;
      logMsg("etat : %s", stateName(state));
    }
    udpDue = true;
    curState = state; curSpeed10 = spd;
    if (inSession) {
      addEvent(nowMs - sesStartMs, state, spd);
      if (spd > sesMax10) sesMax10 = spd;
    }
    Serial.printf("[%8.3fs] %-16s %4.1f km/h\n", nowMs / 1000.0, stateName(state), spd / 10.0);
  }
  if (inSession && (state == 0x01 || state == 0x00)) endSession(nowMs, "stop");
}

// ------------------------------------------------------------ impulsions -> bits (filtre intégrateur)
void feedPulse(uint8_t level, uint32_t dur) {
  if (level == 0) {
    if (nBits < 64) { bitAcc = (bitAcc << 1) | (dur >= BIT_ONE_US ? 1 : 0); nBits++; }
  } else if (dur >= GAP_US && nBits) {
    handleFrame(bitAcc, nBits);
    bitAcc = 0; nBits = 0;
  }
}

void cleanTransition(uint32_t t, uint8_t newLevel) {
  feedPulse(cleanLevel, t - cleanEdgeT);
  cleanLevel = newLevel; cleanEdgeT = t;
}

void advanceFilter(uint32_t d) {
  if (rawLevel) {
    if (cleanLevel == 0 && integ + (int32_t)d >= (int32_t)FILTER_US) cleanTransition(rawSince + (FILTER_US - integ), 1);
    if (d >= FILTER_US) integ = FILTER_US;
    else { integ += (int32_t)d; if (integ > (int32_t)FILTER_US) integ = FILTER_US; }
  } else {
    if (cleanLevel == 1 && (int32_t)d >= integ) cleanTransition(rawSince + integ, 0);
    if (d >= FILTER_US) integ = 0;
    else { integ -= (int32_t)d; if (integ < 0) integ = 0; }
  }
}

void rawEdge(uint32_t t, uint8_t level) {
  if (!filtInit) {
    filtInit = true; rawLevel = level; rawSince = t;
    cleanLevel = level; cleanEdgeT = t; integ = level ? FILTER_US : 0;
    return;
  }
  int32_t d = (int32_t)(t - rawSince);
  if (d > 0) advanceFilter((uint32_t)d); else t = rawSince;
  rawLevel = level; rawSince = t;
}

void processEdges() {
  uint32_t now = micros();
  while (edgeTail != edgeHead) {
    noInterrupts();
    uint32_t t = edges[edgeTail].t;
    uint8_t  l = edges[edgeTail].level;
    edgeTail = (edgeTail + 1) % EDGE_BUF;
    interrupts();
    rawEdge(t, l);
  }
  if (!filtInit) return;
  int32_t idle = (int32_t)(now - rawSince);
  if (idle > 0) { advanceFilter((uint32_t)idle); rawSince = now; }
  if (cleanLevel == 1 && nBits && (int32_t)(now - cleanEdgeT) > (int32_t)GAP_US) {
    handleFrame(bitAcc, nBits);
    bitAcc = 0; nBits = 0;
  }
}

// ------------------------------------------------------------ simulateur (optionnel)
#if SIMULATION
void simSendFrame(uint8_t state, uint8_t speed10) {
  uint8_t b[6] = {0xEB, 0x90, state, speed10, 0x00, 0};
  b[5] = (b[0] + b[1] + b[2] + b[3] + b[4]) & 0xFF;
  for (int i = 0; i < 6; i++)
    for (int bit = 7; bit >= 0; bit--) {
      digitalWrite(SIM_PIN, LOW);  delayMicroseconds(((b[i] >> bit) & 1) ? 1500 : 500);
      digitalWrite(SIM_PIN, HIGH); delayMicroseconds(1500);
    }
}
void simStep() {
  static uint32_t t0 = millis();
  static uint8_t  spd = 0;
  uint32_t t = (millis() - t0) / 1000;
  uint8_t state;
  if      (t < 5)  { state = 0x01; spd = 0; }
  else if (t < 8)  { state = 0x02; spd = 0; }
  else if (t < 20) { state = 0x03; if (spd < 10) spd = 10; else if (spd < 30) spd++; }
  else if (t < 35) { state = 0x03; if (spd < 60) spd++; }
  else if (t < 45) { state = 0x05; if (spd > 0) spd--; }
  else if (t < 65) { state = 0x01; spd = 0; }
  else             { t0 = millis(); return; }
  simSendFrame(state, spd);
}
#endif

// ============================================================ ÉTAT EN JSON (page web, UDP, HTTP)
String statusJson() {
  static char buf[1200];
  char ssidE[80], srvE[170];
  jsonEsc(wifiSsid.c_str(), ssidE, sizeof ssidE);
  jsonEsc(serverUrl.c_str(), srvE, sizeof srvE);
  uint32_t nowMs = millis();
  bool signal = lastFrameMs && (nowMs - lastFrameMs < 2000);
  bool wifiOk = (WiFi.status() == WL_CONNECTED);
  uint32_t stored  = nextId - oldestId;
  uint32_t pending = (lastSent + 1 >= nextId) ? 0 : nextId - 1 - lastSent;
  if (pending > stored) pending = stored;
  snprintf(buf, sizeof buf,
    "{\"device\":\"%s\",\"fw\":\"%s\",\"ts\":%lu,\"uptime_s\":%u,"
    "\"signal\":%s,\"state\":%u,\"state_name\":\"%s\",\"speed_kmh\":%.1f,"
    "\"in_session\":%s,\"session_id\":%u,\"session_ms\":%u,\"elapsed_s\":%u,\"walk_s\":%u,\"distance_m\":%.1f,"
    "\"frames_ok\":%u,\"frames_bad\":%u,\"edges_lost\":%u,"
    "\"stored\":%u,\"pending\":%u,\"fs_used_kb\":%u,\"fs_total_kb\":%u,"
    "\"wifi\":%s,\"ssid\":\"%s\",\"ip\":\"%s\",\"rssi\":%d,\"ap\":%s,\"server\":\"%s\",\"udp_sent\":%u,"
    "\"heap\":%u,\"heap_min\":%u,\"reset\":\"%s\",\"crashes\":%u,\"safe_mode\":%s}",
    DEVICE_NAME, FW_VERSION, (unsigned long)(timeOk() ? time(nullptr) : 0), (unsigned)(nowMs / 1000),
    signal ? "true" : "false", (unsigned)(curState == 0xFF ? 0 : curState), signal ? stateName(curState) : "aucun signal", signal ? curSpeed10 / 10.0 : 0.0,
    inSession ? "true" : "false", (unsigned)(inSession ? nextId : 0), (unsigned)(inSession ? nowMs - sesStartMs : 0),
    (unsigned)(inSession ? (nowMs - sesStartMs) / 1000 : 0), (unsigned)(inSession ? sesWalkMs / 1000 : 0), inSession ? sesDistM : 0.0,
    (unsigned)framesOk, (unsigned)framesBad, (unsigned)edgeOverflow,
    (unsigned)stored, (unsigned)pending, (unsigned)(fsOk ? LittleFS.usedBytes() / 1024 : 0), (unsigned)(fsOk ? LittleFS.totalBytes() / 1024 : 0),
    wifiOk ? "true" : "false", ssidE, wifiOk ? WiFi.localIP().toString().c_str() : "", (int)(wifiOk ? WiFi.RSSI() : 0), apActive ? "true" : "false", srvE, (unsigned)udpSent,
    (unsigned)ESP.getFreeHeap(), (unsigned)ESP.getMinFreeHeap(), resetText, (unsigned)crashTotal, safeMode ? "true" : "false");
  return String(buf);
}

// ============================================================ TEMPS RÉEL : paquets UDP vers le serveur
void resolveServer() {
  udpReady = false;
  if (WiFi.status() != WL_CONNECTED) return;
  const char* u = serverUrl.c_str();
  const char* h = strstr(u, "://");
  h = h ? h + 3 : u;
  char host[64];
  size_t i = 0;
  while (h[i] && h[i] != ':' && h[i] != '/' && i < sizeof(host) - 1) { host[i] = h[i]; i++; }
  host[i] = 0;
  uint16_t port = 80;
  if (h[i] == ':') port = (uint16_t)atoi(h + i + 1);
  if (!host[0] || !port) return;
  if (!udpIp.fromString(host) && WiFi.hostByName(host, udpIp) != 1) { logMsg("Temps reel : nom de serveur introuvable (%s)", host); return; }
  udpPort = port; udpReady = true;
  logMsg("Temps reel : UDP vers %s:%u", udpIp.toString().c_str(), (unsigned)udpPort);
}

void sendUdp() {
  if (!udpReady || WiFi.status() != WL_CONNECTED) { udpDue = false; return; }
  uint32_t nowMs = millis();
  bool active = (curState == 0x02 || curState == 0x03 || curState == 0x05);
  if (!udpDue && nowMs - lastUdpMs < (active ? 1000u : 5000u)) return;
  udpDue = false; lastUdpMs = nowMs;
  String js = statusJson();
  if (udp.beginPacket(udpIp, udpPort)) {
    udp.write((const uint8_t*)js.c_str(), js.length());
    udp.endPacket();
    udpSent++;
  }
}

// ============================================================ PAGE WEB ET API LOCALE
void jsonHeaders() {
  web.sendHeader("Access-Control-Allow-Origin", "*");
  web.sendHeader("Cache-Control", "no-store");
}

bool admin() {                        // demande l'identifiant et le mot de passe pour les actions sensibles
  if (web.authenticate(ADMIN_USER, ADMIN_PASS)) return true;
  web.requestAuthentication();
  return false;
}

void handleRoot()   { web.send_P(200, "text/html; charset=utf-8", INDEX_HTML); }
void handleStatus() { jsonHeaders(); web.send(200, "application/json", statusJson()); }
void handleAuth()   { if (!admin()) return; jsonHeaders(); web.send(200, "application/json", "{\"ok\":true}"); }

void handleSessions() {              // /api/sessions?limit=30 : les plus récentes d'abord
  static char buf[1025];
  char path[24];
  uint32_t limit = web.hasArg("limit") ? (uint32_t)web.arg("limit").toInt() : 30;
  if (limit == 0) limit = 30;
  jsonHeaders();
  web.setContentLength(CONTENT_LENGTH_UNKNOWN);
  web.send(200, "application/json", "");
  web.sendContent("[");
  bool first = true;
  uint32_t sent = 0;
  for (uint32_t id = nextId - 1; id >= oldestId && id >= 1 && sent < limit; id--) {
    sessionPath(path, sizeof path, id);
    if (!fsOk || !LittleFS.exists(path)) continue;
    File f = LittleFS.open(path, "r");
    if (!f) continue;
    if (!first) web.sendContent(",");
    first = false; sent++;
    while (f.available()) {
      size_t n = f.read((uint8_t*)buf, 1024);
      if (!n) break;
      web.sendContent(buf, n);
    }
    f.close();
    processEdges();
    loopBeatMs = millis();
  }
  web.sendContent("]");
  web.sendContent("");
}

void handleLog() {                   // journal des événements depuis le démarrage (texte)
  web.sendHeader("Cache-Control", "no-store");
  web.setContentLength(CONTENT_LENGTH_UNKNOWN);
  web.send(200, "text/plain; charset=utf-8", "");
  if (logWrapped) web.sendContent(logBuf + logHead, LOG_SIZE - logHead);
  if (logHead)    web.sendContent(logBuf, logHead);
  web.sendContent("");
}

void handleConfig() {                // /api/config  server=...   resend=1   raw=0|1
  if (!admin()) return;
  if (web.hasArg("server")) {
    serverUrl = web.arg("server");
    serverUrl.trim();
    while (serverUrl.endsWith("/")) serverUrl.remove(serverUrl.length() - 1);
    prefs.putString("server", serverUrl);
    uploadHoldMs = 0; liveHoldMs = 0; liveForce = true;
    logMsg("Serveur : %s", serverUrl.c_str());
    resolveServer();
  }
  if (web.hasArg("resend")) {
    lastSent = 0; prefs.putUInt("lastSent", 0); uploadHoldMs = 0;
    logMsg("Renvoi de toutes les seances demande");
  }
  jsonHeaders();
  web.send(200, "application/json", statusJson());
}

void handleWifi() {                  // /api/wifi  ssid=...&pass=...
  if (!admin()) return;
  if (!web.hasArg("ssid") || web.arg("ssid").length() == 0) { web.send(400, "text/plain", "ssid manquant"); return; }
  wifiSsid = web.arg("ssid");
  wifiPass = web.arg("pass");
  prefs.putString("ssid", wifiSsid);
  prefs.putString("pass", wifiPass);
  logMsg("Nouveau reseau Wi-Fi enregistre : %s", wifiSsid.c_str());
  jsonHeaders();
  web.send(200, "application/json", "{\"ok\":true}");
  delay(300);
  WiFi.disconnect();
  WiFi.begin(wifiSsid.c_str(), wifiPass.c_str());
  wifiLostMs = millis(); lastWifiRetryMs = millis();
}

void handleReboot() {                // /api/reboot   (normal=1 : quitte le mode sans échec)
  if (!admin()) return;
  if (web.hasArg("normal")) prefs.putUInt("boots", 0);
  jsonHeaders();
  web.send(200, "application/json", "{\"ok\":true}");
  logMsg("Redemarrage demande depuis la page");
  rebootPending = true; rebootAtMs = millis();
}

// ------------------------------------------------------------ mise à jour du firmware par la page (/update)
void handleUpdateUpload() {
  HTTPUpload& up = web.upload();
  loopBeatMs = millis();
  if (up.status == UPLOAD_FILE_START) {
    otaOk = false;
    otaAuth = web.authenticate(ADMIN_USER, ADMIN_PASS);
    if (!otaAuth) return;
    if (inSession) endSession(millis(), "mise_a_jour");
    logMsg("Mise a jour : reception de %s", up.filename.c_str());
    if (!Update.begin(UPDATE_SIZE_UNKNOWN)) logMsg("Mise a jour impossible : %s", Update.errorString());
  } else if (up.status == UPLOAD_FILE_WRITE) {
    if (otaAuth && Update.isRunning() && Update.write(up.buf, up.currentSize) != up.currentSize)
      logMsg("Mise a jour : erreur d'ecriture : %s", Update.errorString());
  } else if (up.status == UPLOAD_FILE_END) {
    if (!otaAuth) return;
    if (Update.end(true)) { otaOk = true; logMsg("Mise a jour : %u octets ecrits, redemarrage", (unsigned)up.totalSize); }
    else logMsg("Mise a jour refusee : %s", Update.errorString());
  } else if (up.status == UPLOAD_FILE_ABORTED) {
    if (otaAuth) Update.abort();
    logMsg("Mise a jour interrompue");
  }
}

void handleUpdateDone() {
  if (!admin()) return;
  web.sendHeader("Connection", "close");
  web.send(otaOk ? 200 : 500, "text/plain; charset=utf-8",
           otaOk ? "Mise a jour recue. Redemarrage en cours, la page se rechargera dans 20 secondes."
                 : "Echec de la mise a jour : fichier invalide ou trop gros. Detail dans /api/log.");
  if (otaOk) { rebootPending = true; rebootAtMs = millis(); }
}

// ============================================================ ENVOIS HTTP VERS LE SERVEUR
void tryUpload() {                   // une séance en attente par appel, uniquement hors séance
  if (!fsOk || WiFi.status() != WL_CONNECTED || serverUrl.length() == 0) return;
  if (lastSent + 1 >= nextId) return;
  if (uploadHoldMs && millis() - uploadHoldStart < uploadHoldMs) return;
  uploadHoldMs = 0;
  if (lastSent + 1 < oldestId) lastSent = oldestId - 1;
  uint32_t id = lastSent + 1;
  char path[24];
  sessionPath(path, sizeof path, id);
  if (!LittleFS.exists(path)) { lastSent = id; prefs.putUInt("lastSent", lastSent); return; }
  File f = LittleFS.open(path, "r");
  if (!f) { lastSent = id; prefs.putUInt("lastSent", lastSent); return; }
  HTTPClient http;
  http.setConnectTimeout(1000);
  http.setTimeout(2500);
  http.begin(serverUrl + "/api/sessions");
  http.addHeader("Content-Type", "application/json");
  int code = http.sendRequest("POST", &f, f.size());
  f.close();
  http.end();
  if (code >= 200 && code < 300) {
    lastSent = id; prefs.putUInt("lastSent", lastSent);
    logMsg("Seance #%u envoyee au serveur (HTTP %d)", (unsigned)id, code);
  } else {
    static int lastCode = 0;
    if (code != lastCode) logMsg("Envoi de la seance #%u impossible (code %d) : nouvel essai toutes les 30 s", (unsigned)id, code);
    lastCode = code;
    uploadHoldStart = millis(); uploadHoldMs = 30000;
  }
}

void postLive() {                    // secours du temps réel UDP
  if (WiFi.status() != WL_CONNECTED || serverUrl.length() == 0) return;
  uint32_t nowMs = millis();
  if (liveHoldMs && nowMs - liveHoldStart < liveHoldMs) { liveForce = false; return; }
  liveHoldMs = 0;
  bool active = (curState == 0x02 || curState == 0x03 || curState == 0x05);
  uint32_t interval = active ? 30000 : 60000;
  if (!liveForce && lastLiveMs && nowMs - lastLiveMs < interval) return;
  liveForce = false; lastLiveMs = nowMs;
  HTTPClient http;
  http.setConnectTimeout(600);
  http.setTimeout(1000);
  http.begin(serverUrl + "/api/live");
  http.addHeader("Content-Type", "application/json");
  int code = http.POST(statusJson());
  http.end();
  if (code < 200 || code >= 300) { liveHoldStart = millis(); liveHoldMs = 30000; }
}

// ============================================================ WI-FI : connexion, reconnexion, point d'accès de secours
void startAp() {
  WiFi.setAutoReconnect(false);                       // les tentatives automatiques perturbent le point d'accès
  WiFi.mode(WIFI_AP_STA);
  WiFi.softAP(AP_SSID, ADMIN_PASS);
  apActive = true;
  logMsg("Wi-Fi de secours actif : reseau \"%s\", page http://192.168.4.1", AP_SSID);
}

void stopAp() {
  WiFi.softAPdisconnect(true);
  WiFi.setAutoReconnect(true);
  apActive = false;
  logMsg("Wi-Fi de secours arrete");
}

void wifiTick() {
  uint32_t nowMs = millis();
  bool is = (WiFi.status() == WL_CONNECTED);
  if (is && !wifiWas) {
    wifiUpMs = nowMs;
    logMsg("Wi-Fi connecte a \"%s\" : http://%s  (ou http://%s.local), %d dBm", wifiSsid.c_str(), WiFi.localIP().toString().c_str(), DEVICE_NAME, (int)WiFi.RSSI());
    if (!mdnsStarted && MDNS.begin(DEVICE_NAME)) { MDNS.addService("http", "tcp", 80); mdnsStarted = true; }
    configTime(0, 0, "pool.ntp.org", "time.google.com");
    uploadHoldStart = nowMs; uploadHoldMs = 2000; liveForce = true; liveHoldMs = 0;
    resolveServer();
  }
  if (!is && wifiWas) { wifiLostMs = nowMs; lastWifiRetryMs = nowMs; udpReady = false; logMsg("Wi-Fi perdu"); }
  wifiWas = is;

  if (!is) {
    if (!apActive && nowMs - wifiLostMs > 90000) startAp();
    uint32_t every = apActive ? 120000 : 30000;       // en mode secours, on laisse du temps pour utiliser la page
    if (nowMs - lastWifiRetryMs > every) {
      lastWifiRetryMs = nowMs;
      WiFi.disconnect();
      WiFi.begin(wifiSsid.c_str(), wifiPass.c_str());
    }
  } else if (apActive && nowMs - wifiUpMs > 60000) stopAp();
}

// ============================================================ SURVEILLANCE
void watchdogCheck() {               // appelé toutes les 5 s par un minuteur indépendant de loop()
  if (millis() - loopBeatMs > 30000) { wdtMagic = WDT_MAGIC; ESP.restart(); }
}

const char* resetReasonText(esp_reset_reason_t r) {
  switch (r) {
    case ESP_RST_POWERON:  return "mise sous tension";
    case ESP_RST_SW:       return "redemarrage logiciel";
    case ESP_RST_PANIC:    return "plantage";
    case ESP_RST_INT_WDT:
    case ESP_RST_TASK_WDT:
    case ESP_RST_WDT:      return "blocage (chien de garde systeme)";
    case ESP_RST_BROWNOUT: return "chute de tension d'alimentation";
    case ESP_RST_DEEPSLEEP: return "reveil";
    default:               return "autre";
  }
}

// ============================================================ Arduino
void setup() {
  Serial.begin(115200);
  delay(300);
  Serial.println();
  loopBeatMs = millis();

  // ---- cause du redémarrage et compteur de plantages consécutifs
  esp_reset_reason_t rr = esp_reset_reason();
  bool byWatchdog = (rr == ESP_RST_SW && wdtMagic == WDT_MAGIC);
  wdtMagic = 0;
  resetText = byWatchdog ? "blocage de la boucle (chien de garde)" : resetReasonText(rr);
  bool abnormal = byWatchdog || rr == ESP_RST_PANIC || rr == ESP_RST_INT_WDT || rr == ESP_RST_TASK_WDT || rr == ESP_RST_WDT || rr == ESP_RST_BROWNOUT;

  prefs.begin("motionx", false);
  bootCount  = prefs.getUInt("boots", 0);
  crashTotal = prefs.getUInt("crashes", 0);
  if (abnormal) { bootCount++; crashTotal++; prefs.putUInt("crashes", crashTotal); } else bootCount = 0;
  prefs.putUInt("boots", bootCount);
  safeMode = (bootCount >= 5);

  nextId    = prefs.getUInt("nextId", 1);
  lastSent  = prefs.getUInt("lastSent", 0);
  oldestId  = prefs.getUInt("oldest", 1);
  serverUrl = prefs.getString("server", DEFAULT_SERVER);
  wifiSsid  = prefs.getString("ssid", DEFAULT_WIFI_SSID);
  wifiPass  = prefs.getString("pass", DEFAULT_WIFI_PASS);

  logMsg("=== MotionX v" FW_VERSION " === demarrage : %s (plantages consecutifs %u, total %u)", resetText, (unsigned)bootCount, (unsigned)crashTotal);
  if (safeMode) logMsg("!!! MODE SANS ECHEC : decodage et stockage desactives. Mets a jour le firmware ou redemarre en mode normal depuis la page.");

  if (!safeMode) {
    pinMode(TRX_PIN, INPUT);
#if SIMULATION
    pinMode(SIM_PIN, OUTPUT); digitalWrite(SIM_PIN, HIGH);
    logMsg("MODE SIMULATION : relier G25 a G34");
#endif
    fsOk = LittleFS.begin(true);
    if (!fsOk) logMsg("!!! stockage indisponible : les seances ne seront pas enregistrees");
    else {
      if (!LittleFS.exists("/s")) LittleFS.mkdir("/s");
      if (LittleFS.exists("/cur.json")) {             // séance interrompue par une coupure de courant
        char path[24];
        sessionPath(path, sizeof path, nextId);
        LittleFS.rename("/cur.json", path);
        logMsg("Seance interrompue recuperee : #%u", (unsigned)nextId);
        nextId++; prefs.putUInt("nextId", nextId);
      }
      pruneStorage();
    }
    if (nextId == oldestId) logMsg("Aucune seance en memoire | serveur %s", serverUrl.c_str());
    else logMsg("Seances : #%u a #%u en memoire, envoyees jusqu'a #%u | serveur %s", (unsigned)oldestId, (unsigned)(nextId - 1), (unsigned)lastSent, serverUrl.c_str());
  }

  WiFi.mode(WIFI_STA);
  WiFi.setHostname(DEVICE_NAME);
  WiFi.setAutoReconnect(true);
  WiFi.begin(wifiSsid.c_str(), wifiPass.c_str());
  wifiLostMs = millis(); lastWifiRetryMs = millis();
  logMsg("Connexion au Wi-Fi \"%s\"...", wifiSsid.c_str());

  web.on("/", handleRoot);
  web.on("/api/status", handleStatus);
  web.on("/api/sessions", handleSessions);
  web.on("/api/log", handleLog);
  web.on("/api/auth", handleAuth);
  web.on("/api/config", handleConfig);
  web.on("/api/wifi", handleWifi);
  web.on("/api/reboot", handleReboot);
  web.on("/update", HTTP_POST, handleUpdateDone, handleUpdateUpload);
  web.begin();

  if (!safeMode) attachInterrupt(digitalPinToInterrupt(TRX_PIN), onEdge, CHANGE);
  loopBeatMs = millis();
  watchdog.attach(5, watchdogCheck);
}

void loop() {
  uint32_t nowMs = millis();
  loopBeatMs = nowMs;

  if (!safeMode) {
#if SIMULATION
    static uint32_t lastSim = 0;
    if (nowMs - lastSim >= 120) { lastSim = nowMs; simStep(); }
#endif
    processEdges();
  }
  wifiTick();
  web.handleClient();

  bool wifiOk = (WiFi.status() == WL_CONNECTED);
  nowMs = millis();

  // ---- un firmware reçu par Wi-Fi est validé seulement une fois joignable ; sinon l'ESP32 reviendra à l'ancien
  if (!otaValidated && nowMs > 60000 && (apActive || (wifiOk && nowMs - wifiUpMs > 20000))) {
    otaValidated = true;
    esp_ota_mark_app_valid_cancel_rollback();
    logMsg("Firmware v" FW_VERSION " valide (joignable depuis le reseau)");
  }
  // ---- trois minutes sans plantage : le compteur de plantages consécutifs repart de zéro
  if (!bootsCleared && nowMs > 180000) {
    bootsCleared = true;
    if (bootCount && !safeMode) prefs.putUInt("boots", 0);
  }
  if (rebootPending && nowMs - rebootAtMs > 800) { delay(100); ESP.restart(); }

  if (safeMode) { delay(2); return; }

  processEdges();
  if (inSession && nowMs - lastFrameMs > 3000) endSession(lastFrameMs, "signal_perdu");
  if (inSession && nowMs - lastCheckpointMs > 60000) {
    writeSession("/cur.json", nextId, nowMs, "interrompue");
    lastCheckpointMs = nowMs;
  }
  sendUdp();
  if (!inSession) tryUpload();
  postLive();

  // ---- redémarrage préventif : une semaine d'allumage continu, tapis au repos depuis 10 minutes, rien en attente
  if (nowMs > 7UL * 24 * 3600 * 1000 && !inSession && curState != 0x02 && curState != 0x03 && curState != 0x05
      && nowMs - lastSessionEndMs > 600000 && lastSent + 1 >= nextId) {
    logMsg("Redemarrage preventif hebdomadaire");
    delay(200);
    ESP.restart();
  }

  if (Serial.available()) {          // utile seulement tant que le câble USB est branché
    char c = Serial.read();
    if (c == 'r') { showRaw = !showRaw; Serial.printf("Affichage brut : %s\n", showRaw ? "ON" : "OFF"); }
    if (c == 's') Serial.println(statusJson().c_str());
  }
}
