#!/usr/bin/env node
/*
 * MotionX receiving server — Node.js, no dependencies (node >= 16).
 *
 *   node server.js            → listens on port 3000
 *   PORT=8080 node server.js  → another port
 *
 * What the ESP32 sends:
 *   UDP  port PORT       REAL-TIME state (one JSON packet on every speed change, otherwise 1/s while walking)
 *   POST /api/sessions   a finished session (raw JSON from the ESP32)  → saved in data/sessions/
 *   POST /api/live       same state as over UDP, as a fallback (every 30 s)
 * Routes for you:
 *   GET  /               dashboard (updated live)
 *   GET  /api/stream     real-time stream (Server-Sent Events): "live" and "session" events
 *   GET  /api/sessions   list of sessions (summaries + computed values)
 *   GET  /api/sessions/<file>  a full session with its events
 *   GET  /api/live       last state received + trace of the current session
 *   GET  /api/settings   profile, daily goal and pause length (POST the fields to change; kept in data/settings.json)
 * Routes for the iPhone shortcut (Apple Health):
 *   GET  /api/health/pending        sessions not yet transferred to Health (simple format for Shortcuts)
 *   GET  /api/health/done?file=...  marks a session as transferred
 *   GET  /api/health/reset          sets all sessions back to "to transfer" (to redo a test)
 *
 * Received files are never modified: all computations (steps, calories...) are redone
 * on read from the raw events. Change the formulas here, the history follows.
 */
const http = require('http');
const dgram = require('dgram');
const fs = require('fs');
const path = require('path');
const os = require('os');

const PORT = Number(process.env.PORT) || 3000;
const DATA_DIR = path.join(__dirname, 'data', 'sessions');
fs.mkdirSync(DATA_DIR, { recursive: true });

// ---------------------------------------------------------------- settings (profile, daily goal, pauses)
// Changed from the dashboard and kept in data/settings.json. HEIGHT_CM and WEIGHT_KG only give the first values.
const SETTINGS_FILE = path.join(__dirname, 'data', 'settings.json');
const GOAL_TYPES = ['walk_min', 'distance_km', 'steps'];
const SETTING_RANGE = { height_cm: [100, 230], weight_kg: [30, 250], step_factor: [0.5, 2], goal_value: [0, 100000], merge_gap_s: [0, 3600] };
let settings = {
  height_cm: Number(process.env.HEIGHT_CM) || 175,
  weight_kg: Number(process.env.WEIGHT_KG) || 75,
  step_factor: 1,              // steps × this factor, to match what your watch counts
  goal_type: 'walk_min',       // what the daily goal counts
  goal_value: 30,              // 0 = no goal
  merge_gap_s: 300,            // two sessions separated by a shorter pause are one walk (0 = never)
};
try { applySettings(JSON.parse(fs.readFileSync(SETTINGS_FILE, 'utf8'))); } catch {}

// Checks then applies a partial change; nothing changes if one value is invalid
function applySettings(patch) {
  const next = { ...settings };
  for (const [k, [min, max]] of Object.entries(SETTING_RANGE)) {
    if (patch[k] === undefined) continue;
    const v = typeof patch[k] === 'number' ? patch[k] : NaN;
    if (!Number.isFinite(v) || v < min || v > max) throw new Error(`${k} must be a number between ${min} and ${max}`);
    next[k] = v;
  }
  if (patch.goal_type !== undefined) {
    if (!GOAL_TYPES.includes(patch.goal_type)) throw new Error('goal_type must be one of: ' + GOAL_TYPES.join(', '));
    next.goal_type = patch.goal_type;
  }
  settings = next;
}

// Stride length (m) depending on speed: shorter at low speed. Estimate, adjusted by step_factor.
function strideMeters(kmh) {
  const base = settings.height_cm * 0.00414;                // ≈ 0.414 × height, at ~5 km/h
  const factor = Math.min(1.1, Math.max(0.6, 0.6 + 0.08 * kmh));
  return base * factor / settings.step_factor;
}
// Energy expenditure (kcal/min): walking MET approximated from speed
function kcalPerMin(kmh) {
  if (kmh <= 0) return 0;
  const met = kmh < 3.2 ? 2.0 + 0.25 * kmh : 2.8 + 0.9 * (kmh - 3.2);
  return met * 3.5 * settings.weight_kg / 200;
}

// Sums distance, walking time, steps and calories over raw events [ms, state, speed×10] (not rounded)
function integrate(ev, endMs) {
  let dist = 0, steps = 0, kcal = 0, walkMs = 0;
  for (let i = 0; i < ev.length; i++) {
    const [t, , spd10] = ev[i];
    const tNext = i + 1 < ev.length ? ev[i + 1][0] : Math.max(endMs, t);
    const dt = Math.max(0, tNext - t) / 1000;                // seconds at this speed
    const kmh = spd10 / 10;
    if (kmh > 0 && dt > 0) {
      const d = (kmh / 3.6) * dt;
      dist += d; walkMs += dt * 1000;
      steps += d / strideMeters(kmh);
      kcal += kcalPerMin(kmh) * dt / 60;
    }
  }
  return { dist, walkMs, steps, kcal };
}

// Recomputes distance, steps and calories of a stored session from its raw events
function compute(session) {
  const r = integrate(Array.isArray(session.events) ? session.events : [], (session.duration_s || 0) * 1000);
  return {
    distance_m: Math.round(r.dist * 10) / 10,
    walk_s: Math.round(r.walkMs / 1000),
    steps: Math.round(r.steps),
    kcal: Math.round(r.kcal),
  };
}

// ---------------------------------------------------------------- real time
let live = null;                                   // last state received from the ESP32
let trace = { session_id: 0, events: [] };         // current session: [ms, state, speed×10] on every change
const streams = new Set();                         // browsers connected to the /api/stream stream
let carry = null;                                  // what was walked before the pause, when the current session continues a walk
let udpCount = 0;

function broadcast(event, data) {
  const msg = `event: ${event}\ndata: ${JSON.stringify(data)}\n\n`;
  for (const res of streams) res.write(msg);
}

// Steps and calories of the session in progress (the ESP32 only counts time and distance), same formulas as
// compute(). The two rates let a page keep the counters moving between two packets.
function liveEstimate(m) {
  const r = integrate(trace.events, m.session_ms || 0);
  // part of the walk this server did not see (restarted mid-session, lost packets): counted at its average speed
  const missM = (m.distance_m || 0) - r.dist, missS = (m.walk_s || 0) - r.walkMs / 1000;
  if (missM > 10 && missS > 5) {
    const avg = missM / missS * 3.6;
    r.steps += missM / strideMeters(avg);
    r.kcal += kcalPerMin(avg) * missS / 60;
  }
  const kmh = m.speed_kmh || 0;
  return {
    steps: Math.round(r.steps),
    kcal: Math.round(r.kcal * 10) / 10,
    steps_per_min: kmh > 0 ? Math.round(kmh / 3.6 * 60 / strideMeters(kmh)) : 0,
    kcal_per_h: Math.round(kcalPerMin(kmh) * 60),
  };
}

// A state arrives from the ESP32 (UDP or POST /api/live)
function onLive(m, from, via) {
  live = { ...m, received_at: Date.now(), from: String(from || '').replace('::ffff:', ''), via };
  let point = null;
  if (m.in_session) {
    const ms = m.session_ms || 0;
    let last = trace.events[trace.events.length - 1];
    // New session. The ESP32 reuses the number of a session it discarded (too short) or lost in a reboot:
    // its clock then jumps back. A jump of a few ms is only a UDP packet that arrived late, and is not traced.
    if (trace.session_id !== m.session_id || (last && ms < last[0] - 2000)) { trace = { session_id: m.session_id, events: [] }; last = undefined; carry = carryFor(m); }
    const spd10 = Math.round((m.speed_kmh || 0) * 10);
    if (!last || (ms >= last[0] && (last[1] !== m.state || last[2] !== spd10))) {
      point = [ms, m.state, spd10];
      trace.events.push(point);
    }
    live.est = liveEstimate(m);
    if (carry) live.carry = carry;
  }
  broadcast('live', { live, point, session_id: trace.session_id });
}

// ---------------------------------------------------------------- storage

function fileNameFor(s) {
  const dev = String(s.device || 'motionx').replace(/[^a-zA-Z0-9_-]/g, '');
  return `${dev}_${String(s.start || 0).padStart(10, '0')}_${String(s.id || 0).padStart(6, '0')}.json`;
}

function saveSession(s) {
  s.received_at = Math.floor(Date.now() / 1000);
  if (!s.start) {                                            // the ESP32 did not have the time yet: estimate it
    s.start = s.received_at - (s.duration_s || 0);
    s.start_estimated = true;
  }
  // same device + same id + same start (within 2 min) = resend: replace
  const dup = fs.readdirSync(DATA_DIR).find(f => {
    const m = f.match(/^(.+)_(\d{10})_(\d{6})\.json$/);
    return m && m[1] === String(s.device || 'motionx') && Number(m[3]) === s.id && Math.abs(Number(m[2]) - s.start) < 120;
  });
  const name = dup || fileNameFor(s);
  if (dup) {                                                 // keep the start time already known
    try { const old = JSON.parse(fs.readFileSync(path.join(DATA_DIR, dup), 'utf8')); s.start = old.start; s.start_estimated = old.start_estimated; } catch {}
  }
  fs.writeFileSync(path.join(DATA_DIR, name), JSON.stringify(s));
  return { name, replaced: Boolean(dup) };
}

// ---------------------------------------------------------------- reading: sessions, walks, Apple Health
const HEALTH_FILE = path.join(__dirname, 'data', 'health-synced.json');
const HEALTH_MIN_WALK_S = Number(process.env.HEALTH_MIN_WALK_S) || 0;   // ignore shorter sessions (0 = send everything)

function healthState() { try { return JSON.parse(fs.readFileSync(HEALTH_FILE, 'utf8')); } catch { return {}; } }
function healthSave(st) { fs.writeFileSync(HEALTH_FILE, JSON.stringify(st, null, 1)); }

// Every stored session with its computed values and its Health state, oldest first
function loadParts() {
  const synced = healthState();
  return fs.readdirSync(DATA_DIR).filter(f => f.endsWith('.json')).map(f => {
    try {
      const s = JSON.parse(fs.readFileSync(path.join(DATA_DIR, f), 'utf8'));
      const computed = compute(s);
      return { file: f, s, computed, end: s.start + (s.duration_s || 0), synced: Boolean(synced[f]),
               ignored: computed.walk_s < HEALTH_MIN_WALK_S || computed.distance_m <= 0 };
    } catch { return null; }
  }).filter(Boolean).sort((a, b) => a.s.start - b.s.start);
}

// A walk = consecutive sessions separated by pauses shorter than merge_gap_s. The files stay as received:
// the grouping is redone on every read, so changing the setting regroups the whole history.
function groupParts(parts) {
  const groups = [];
  for (const p of parts) {
    const g = groups[groups.length - 1], device = p.s.device || 'motionx';
    if (g && settings.merge_gap_s > 0 && g.device === device && p.s.start - g.end <= settings.merge_gap_s) { g.parts.push(p); g.end = Math.max(g.end, p.end); }
    else groups.push({ device, parts: [p], end: p.end });
  }
  return groups;
}

const sum = (parts, f) => parts.reduce((a, p) => a + (f(p) || 0), 0);
const round1 = v => Math.round(v * 10) / 10;

// Summary of a walk: the session itself, or the sum of its parts (the file of the first part identifies it)
function summarize(g) {
  const first = g.parts[0], last = g.parts[g.parts.length - 1];
  const { events, ...head } = first.s;
  const out = { file: first.file, ...head, events_count: sum(g.parts, p => (p.s.events || []).length), computed: first.computed };
  if (g.parts.length > 1) {
    const walk = sum(g.parts, p => p.s.walk_s), dist = sum(g.parts, p => p.s.distance_m);
    Object.assign(out, {
      duration_s: g.end - first.s.start, walk_s: walk, distance_m: round1(dist),
      max_kmh: Math.max(...g.parts.map(p => p.s.max_kmh || 0)), avg_kmh: walk ? Math.round(dist / walk * 360) / 100 : 0,
      end: last.s.end, truncated: g.parts.some(p => p.s.truncated), received_at: last.s.received_at,
      computed: { distance_m: round1(sum(g.parts, p => p.computed.distance_m)), walk_s: sum(g.parts, p => p.computed.walk_s),
                  steps: sum(g.parts, p => p.computed.steps), kcal: sum(g.parts, p => p.computed.kcal) },
      parts: g.parts.map(p => p.file), ids: g.parts.map(p => p.s.id),
      pause_s: Math.max(0, g.end - first.s.start - sum(g.parts, p => p.s.duration_s)),
    });
  }
  // Health receives the parts one by one: the walk is in Health once every part that counts is
  out.health_synced = g.parts.some(p => p.synced) && g.parts.every(p => p.synced || p.ignored);
  out.health_ignored = !g.parts.some(p => p.synced) && g.parts.every(p => p.ignored);
  return out;
}

function listSessions() {
  return groupParts(loadParts()).map(summarize).sort((a, b) => b.start - a.start);
}

// One session with its events. Asked by the file of its first part, a walk comes back whole:
// the events of the parts follow each other on the clock of the first one (raw = the file alone).
function sessionDetail(file, raw) {
  const g = groupParts(loadParts()).find(x => x.parts.some(p => p.file === file));
  if (!g) return null;
  if (raw || g.parts.length === 1 || g.parts[0].file !== file) { const p = g.parts.find(x => x.file === file); return { ...p.s, computed: p.computed }; }
  const events = [];
  let floor = 0;
  for (const p of g.parts) {
    const ev = Array.isArray(p.s.events) ? p.s.events : [], lastEv = ev[ev.length - 1];
    const off = Math.max(floor, (p.s.start - g.parts[0].s.start) * 1000);
    for (const [t, st, spd] of ev) events.push([t + off, st, spd]);
    floor = off + Math.max((p.s.duration_s || 0) * 1000, lastEv ? lastEv[0] : 0);
    if (lastEv && lastEv[2] > 0) events.push([floor, 1, 0]);    // part cut short (signal lost, power cut): nobody walks during the pause
  }
  return { ...summarize(g), events };
}

// The session in progress continues the last walk if it started less than merge_gap_s after it:
// returns what that walk already counts, for the pages that show the walk as a whole
function carryFor(m) {
  if (!settings.merge_gap_s) return null;
  const start = (m.ts || Date.now() / 1000) - (m.session_ms || 0) / 1000;
  const g = groupParts(loadParts()).pop();
  if (!g || g.device !== (m.device || 'motionx') || start < g.end - 5 || start - g.end > settings.merge_gap_s) return null;
  return { ...summarize(g).computed, sessions: g.parts.length };
}
function refreshCarry() {                                    // the stored sessions or the settings have changed
  if (!live || !live.in_session) return;
  carry = carryFor(live);
  if (carry) live.carry = carry; else delete live.carry;
}

// ---------------------------------------------------------------- Apple Health (iPhone app or Shortcuts)
// Local date in ISO 8601 format with UTC offset: 2026-11-09T21:33:03+01:00 (understood as is by Shortcuts)
function isoLocal(epochS) {
  const d = new Date(epochS * 1000), off = -d.getTimezoneOffset(), p = n => String(Math.abs(n)).padStart(2, '0');
  return `${d.getFullYear()}-${p(d.getMonth() + 1)}-${p(d.getDate())}T${p(d.getHours())}:${p(d.getMinutes())}:${p(d.getSeconds())}` +
         `${off >= 0 ? '+' : '-'}${p(Math.floor(Math.abs(off) / 60))}:${p(Math.abs(off) % 60)}`;
}

// Health gets every session as received, right after it ends: a walk with a pause makes two workouts there
function healthPending(limit = 20) {
  return loadParts()
    .filter(p => !p.synced && !p.ignored)                    // oldest first
    .slice(0, limit)
    .map(({ file, s, computed }) => ({
      file,
      id: s.id,
      start: isoLocal(s.start),
      end: isoLocal(s.start + (s.duration_s || computed.walk_s)),
      duration_min: Math.round(computed.walk_s / 6) / 10,    // minutes of walking, 1 decimal
      distance_km: Math.round(computed.distance_m) / 1000,
      distance_m: Math.round(computed.distance_m),
      kcal: computed.kcal,
      steps: computed.steps,
    }));
}

// ---------------------------------------------------------------- HTTP
function send(res, code, body, type = 'application/json') {
  const data = typeof body === 'string' ? body : JSON.stringify(body);
  res.writeHead(code, { 'Content-Type': type + '; charset=utf-8', 'Access-Control-Allow-Origin': '*', 'Cache-Control': 'no-store' });
  res.end(data);
}

function readBody(req, limit = 2 * 1024 * 1024) {
  return new Promise((resolve, reject) => {
    const chunks = []; let size = 0;
    req.on('data', c => { size += c.length; if (size > limit) { reject(new Error('body too large')); req.destroy(); } else chunks.push(c); });
    req.on('end', () => resolve(Buffer.concat(chunks).toString('utf8')));
    req.on('error', reject);
  });
}

const stamp = () => new Date().toLocaleTimeString('en-GB');

// A browser always sends Origin on a cross-site POST: it must name this very server
function sameOrigin(req) {
  const o = req.headers.origin;
  if (!o) return true;                                       // not a browser (curl, scripts)
  try { return new URL(o).host === req.headers.host; } catch { return false; }
}

const server = http.createServer(async (req, res) => {
  const url = new URL(req.url, 'http://x');
  try {
    if (req.method === 'OPTIONS') { res.writeHead(204, { 'Access-Control-Allow-Origin': '*', 'Access-Control-Allow-Headers': '*' }); return res.end(); }

    if (req.method === 'POST' && url.pathname === '/api/sessions') {
      const s = JSON.parse(await readBody(req));
      if (typeof s.id !== 'number' || !Array.isArray(s.events)) return send(res, 400, { error: 'invalid session' });
      const r = saveSession(s);
      const c = compute(s);
      console.log(`[${stamp()}] session #${s.id} ${r.replaced ? 'updated' : 'received'}: ${c.walk_s}s of walking, ${c.distance_m} m, ~${c.steps} steps → ${r.name}`);
      refreshCarry();
      broadcast('session', { file: r.name, id: s.id });
      return send(res, 200, { ok: true, file: r.name, replaced: r.replaced });
    }

    if (req.method === 'POST' && url.pathname === '/api/live') {
      onLive(JSON.parse(await readBody(req)), req.socket.remoteAddress, 'http');
      return send(res, 200, { ok: true });
    }

    if (req.method === 'GET' && url.pathname === '/api/live') return send(res, 200, { live, trace, udp_packets: udpCount });

    if (req.method === 'GET' && url.pathname === '/api/stream') {          // real-time stream to the browser
      res.writeHead(200, { 'Content-Type': 'text/event-stream; charset=utf-8', 'Cache-Control': 'no-store', 'Connection': 'keep-alive', 'Access-Control-Allow-Origin': '*' });
      res.write(`retry: 2000\nevent: init\ndata: ${JSON.stringify({ live, trace })}\n\n`);
      streams.add(res);
      req.on('close', () => streams.delete(res));
      return;
    }
    if (req.method === 'GET' && url.pathname === '/api/sessions') {
      const { height_cm, weight_kg, step_factor } = settings;
      return send(res, 200, { profile: { height_cm, weight_kg, step_factor }, settings, health_min_walk_s: HEALTH_MIN_WALK_S, sessions: listSessions() });
    }

    if (req.method === 'GET' && url.pathname.startsWith('/api/sessions/')) {
      const f = path.basename(decodeURIComponent(url.pathname.slice('/api/sessions/'.length)));
      const s = f.endsWith('.json') && fs.existsSync(path.join(DATA_DIR, f)) ? sessionDetail(f, url.searchParams.has('raw')) : null;
      return s ? send(res, 200, s) : send(res, 404, { error: 'not found' });
    }

    if (req.method === 'GET' && url.pathname === '/api/settings') return send(res, 200, settings);
    if (req.method === 'POST' && url.pathname === '/api/settings') {
      // Only the dashboard served by this server may change the settings: a page of another site open in the
      // same browser could otherwise post here, since every route answers Access-Control-Allow-Origin: *
      if (!sameOrigin(req) || !/^application\/json\b/i.test(req.headers['content-type'] || '')) return send(res, 403, { error: 'settings can only be changed from the dashboard' });
      applySettings(JSON.parse(await readBody(req)));           // an invalid value is answered with HTTP 400 and its reason
      fs.writeFileSync(SETTINGS_FILE, JSON.stringify(settings, null, 1));
      console.log(`[${stamp()}] settings: ${JSON.stringify(settings)}`);
      refreshCarry();
      broadcast('session', {});                                 // every page reloads the sessions: their computed values have changed
      return send(res, 200, settings);
    }

    // ---- Apple Health
    if (req.method === 'GET' && url.pathname === '/api/health/pending') {
      const list = healthPending();
      console.log(`[${stamp()}] Health: ${list.length} session(s) offered to the shortcut`);
      return send(res, 200, { count: list.length, sessions: list });
    }
    if (url.pathname === '/api/health/done') {
      const f = path.basename(url.searchParams.get('file') || '');
      if (!f || !fs.existsSync(path.join(DATA_DIR, f))) return send(res, 404, { ok: false, error: 'unknown session' });
      const st = healthState(); st[f] = Math.floor(Date.now() / 1000); healthSave(st);
      console.log(`[${stamp()}] Health: ${f} marked as transferred`);
      broadcast('session', { file: f });
      return send(res, 200, { ok: true, file: f });
    }
    if (url.pathname === '/api/health/reset') {
      healthSave({});
      console.log(`[${stamp()}] Health: all sessions are to be transferred again`);
      broadcast('session', {});
      return send(res, 200, { ok: true });
    }

    if (req.method === 'GET' && (url.pathname === '/' || url.pathname === '/index.html'))
      return send(res, 200, fs.readFileSync(path.join(__dirname, 'dashboard.html'), 'utf8'), 'text/html');

    send(res, 404, { error: 'unknown route' });
  } catch (e) {
    console.error(`[${stamp()}] error ${req.method} ${url.pathname}: ${e.message}`);
    send(res, 400, { error: e.message });
  }
});

// Real-time reception: the ESP32 sends its UDP packets to the same port number as HTTP
const udp = dgram.createSocket('udp4');
udp.on('message', (buf, rinfo) => {
  try { const m = JSON.parse(buf.toString('utf8')); udpCount++; onLive(m, rinfo.address, 'udp');
        if (process.env.VERBOSE) console.log(`[${stamp()}] udp: ${m.state_name} ${m.speed_kmh} km/h`); }
  catch (e) { /* unreadable packet: ignored */ }
});
udp.on('error', e => console.error('UDP: ' + e.message));
udp.bind(PORT, '0.0.0.0');
setInterval(() => { for (const res of streams) res.write(': ping\n\n'); }, 15000);   // keeps the streams open

server.listen(PORT, '0.0.0.0', () => {
  const ips = Object.values(os.networkInterfaces()).flat().filter(i => i && i.family === 'IPv4' && !i.internal).map(i => i.address);
  console.log(`MotionX server ready.`);
  console.log(`  Dashboard: http://localhost:${PORT}   (HTTP + real-time UDP on port ${PORT})`);
  ips.forEach(ip => console.log(`  Address to give to the ESP32: http://${ip}:${PORT}`));
  console.log(`  Data: ${DATA_DIR}`);
  console.log(`  Profile: ${settings.height_cm} cm, ${settings.weight_kg} kg (changed from the dashboard, kept in data/settings.json)`);
});
