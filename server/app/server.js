#!/usr/bin/env node
/*
 * Serveur de réception MotionX — Node.js, aucune dépendance (node >= 16).
 *
 *   node server.js            → écoute sur le port 3000
 *   PORT=8080 node server.js  → autre port
 *
 * Ce que l'ESP32 envoie :
 *   UDP  port PORT       état en TEMPS RÉEL (un paquet JSON à chaque changement de vitesse, sinon 1/s en marche)
 *   POST /api/sessions   une séance terminée (JSON brut de l'ESP32)  → enregistrée dans data/sessions/
 *   POST /api/live       même état qu'en UDP, en secours (toutes les 30 s)
 * Routes pour toi :
 *   GET  /               tableau de bord (mis à jour en direct)
 *   GET  /api/stream     flux temps réel (Server-Sent Events) : événements "live" et "session"
 *   GET  /api/sessions   liste des séances (résumés + valeurs calculées)
 *   GET  /api/sessions/<fichier>  une séance complète avec ses événements
 *   GET  /api/live       dernier état reçu + tracé de la séance en cours
 * Routes pour le raccourci iPhone (Apple Santé) :
 *   GET  /api/health/pending        séances pas encore transférées dans Santé (format simple pour Raccourcis)
 *   GET  /api/health/done?file=...  marque une séance comme transférée
 *   GET  /api/health/reset          remet toutes les séances "à transférer" (pour refaire un test)
 *
 * Les fichiers reçus ne sont jamais modifiés : tous les calculs (pas, calories...) sont refaits
 * à la lecture à partir des événements bruts. Change les formules ici, l'historique suit.
 */
const http = require('http');
const dgram = require('dgram');
const fs = require('fs');
const path = require('path');
const os = require('os');

const PORT = Number(process.env.PORT) || 3000;
const DATA_DIR = path.join(__dirname, 'data', 'sessions');
fs.mkdirSync(DATA_DIR, { recursive: true });

// ---------------------------------------------------------------- réglages personnels (calculs)
const PROFILE = {
  height_cm: Number(process.env.HEIGHT_CM) || 175,
  weight_kg: Number(process.env.WEIGHT_KG) || 75,
};

// Longueur de foulée (m) selon la vitesse : plus courte à basse vitesse. Estimation à ajuster avec ta montre.
function strideMeters(kmh) {
  const base = PROFILE.height_cm * 0.00414;                 // ≈ 0,414 × taille, à ~5 km/h
  const factor = Math.min(1.1, Math.max(0.6, 0.6 + 0.08 * kmh));
  return base * factor;
}
// Dépense (kcal/min) : MET de marche approximé selon la vitesse
function kcalPerMin(kmh) {
  if (kmh <= 0) return 0;
  const met = kmh < 3.2 ? 2.0 + 0.25 * kmh : 2.8 + 0.9 * (kmh - 3.2);
  return met * 3.5 * PROFILE.weight_kg / 200;
}

// Recalcule distance, pas et calories à partir des événements bruts [ms, état, vitesse×10]
function compute(session) {
  const ev = Array.isArray(session.events) ? session.events : [];
  let dist = 0, steps = 0, kcal = 0, walkMs = 0;
  const endMs = (session.duration_s || 0) * 1000;
  for (let i = 0; i < ev.length; i++) {
    const [t, , spd10] = ev[i];
    const tNext = i + 1 < ev.length ? ev[i + 1][0] : Math.max(endMs, t);
    const dt = Math.max(0, tNext - t) / 1000;                // secondes à cette vitesse
    const kmh = spd10 / 10;
    if (kmh > 0 && dt > 0) {
      const d = (kmh / 3.6) * dt;
      dist += d; walkMs += dt * 1000;
      steps += d / strideMeters(kmh);
      kcal += kcalPerMin(kmh) * dt / 60;
    }
  }
  return {
    distance_m: Math.round(dist * 10) / 10,
    walk_s: Math.round(walkMs / 1000),
    steps: Math.round(steps),
    kcal: Math.round(kcal),
  };
}

// ---------------------------------------------------------------- temps réel
let live = null;                                   // dernier état reçu de l'ESP32
let trace = { session_id: 0, events: [] };         // séance en cours : [ms, état, vitesse×10] à chaque changement
const streams = new Set();                         // navigateurs connectés au flux /api/stream
let udpCount = 0;

function broadcast(event, data) {
  const msg = `event: ${event}\ndata: ${JSON.stringify(data)}\n\n`;
  for (const res of streams) res.write(msg);
}

// Un état arrive de l'ESP32 (UDP ou POST /api/live)
function onLive(m, from, via) {
  live = { ...m, received_at: Date.now(), from: String(from || '').replace('::ffff:', ''), via };
  let point = null;
  if (m.in_session) {
    if (trace.session_id !== m.session_id) trace = { session_id: m.session_id, events: [] };
    const spd10 = Math.round((m.speed_kmh || 0) * 10);
    const last = trace.events[trace.events.length - 1];
    if (!last || last[1] !== m.state || last[2] !== spd10) {
      point = [m.session_ms || 0, m.state, spd10];
      trace.events.push(point);
    }
  }
  broadcast('live', { live, point, session_id: trace.session_id });
}

// ---------------------------------------------------------------- stockage

function fileNameFor(s) {
  const dev = String(s.device || 'motionx').replace(/[^a-zA-Z0-9_-]/g, '');
  return `${dev}_${String(s.start || 0).padStart(10, '0')}_${String(s.id || 0).padStart(6, '0')}.json`;
}

function saveSession(s) {
  s.received_at = Math.floor(Date.now() / 1000);
  if (!s.start) {                                            // l'ESP32 n'avait pas encore l'heure : on l'estime
    s.start = s.received_at - (s.duration_s || 0);
    s.start_estimated = true;
  }
  // même appareil + même identifiant + même début (à 2 min près) = renvoi : on remplace
  const dup = fs.readdirSync(DATA_DIR).find(f => {
    const m = f.match(/^(.+)_(\d{10})_(\d{6})\.json$/);
    return m && m[1] === String(s.device || 'motionx') && Number(m[3]) === s.id && Math.abs(Number(m[2]) - s.start) < 120;
  });
  const name = dup || fileNameFor(s);
  if (dup) {                                                 // on garde l'heure de début déjà connue
    try { const old = JSON.parse(fs.readFileSync(path.join(DATA_DIR, dup), 'utf8')); s.start = old.start; s.start_estimated = old.start_estimated; } catch {}
  }
  fs.writeFileSync(path.join(DATA_DIR, name), JSON.stringify(s));
  return { name, replaced: Boolean(dup) };
}

function listSessions() {
  let synced = {};
  try { synced = JSON.parse(fs.readFileSync(path.join(__dirname, 'data', 'health-synced.json'), 'utf8')); } catch {}
  return fs.readdirSync(DATA_DIR).filter(f => f.endsWith('.json')).map(f => {
    try {
      const s = JSON.parse(fs.readFileSync(path.join(DATA_DIR, f), 'utf8'));
      const { events, ...summary } = s;
      const computed = compute(s);
      const minWalk = Number(process.env.HEALTH_MIN_WALK_S) || 0;
      return { file: f, ...summary, events_count: (events || []).length, computed,
               health_synced: Boolean(synced[f]),
               health_ignored: !synced[f] && (computed.walk_s < minWalk || computed.distance_m <= 0) };
    } catch { return null; }
  }).filter(Boolean).sort((a, b) => b.start - a.start);
}

// ---------------------------------------------------------------- Apple Santé (via l'app Raccourcis de l'iPhone)
const HEALTH_FILE = path.join(__dirname, 'data', 'health-synced.json');
const HEALTH_MIN_WALK_S = Number(process.env.HEALTH_MIN_WALK_S) || 0;   // ignorer les séances plus courtes (0 = tout envoyer)

function healthState() { try { return JSON.parse(fs.readFileSync(HEALTH_FILE, 'utf8')); } catch { return {}; } }
function healthSave(st) { fs.writeFileSync(HEALTH_FILE, JSON.stringify(st, null, 1)); }

// Date locale au format ISO 8601 avec décalage horaire : 2026-11-09T21:33:03+01:00 (compris tel quel par Raccourcis)
function isoLocal(epochS) {
  const d = new Date(epochS * 1000), off = -d.getTimezoneOffset(), p = n => String(Math.abs(n)).padStart(2, '0');
  return `${d.getFullYear()}-${p(d.getMonth() + 1)}-${p(d.getDate())}T${p(d.getHours())}:${p(d.getMinutes())}:${p(d.getSeconds())}` +
         `${off >= 0 ? '+' : '-'}${p(Math.floor(Math.abs(off) / 60))}:${p(Math.abs(off) % 60)}`;
}

function healthPending(limit = 20) {
  const st = healthState();
  return listSessions()
    .filter(s => !st[s.file] && s.computed.walk_s >= HEALTH_MIN_WALK_S && s.computed.distance_m > 0)
    .sort((a, b) => a.start - b.start)                     // les plus anciennes d'abord
    .slice(0, limit)
    .map(s => ({
      file: s.file,
      id: s.id,
      start: isoLocal(s.start),
      end: isoLocal(s.start + (s.duration_s || s.computed.walk_s)),
      duration_min: Math.round(s.computed.walk_s / 6) / 10,   // minutes de marche, 1 décimale
      distance_km: Math.round(s.computed.distance_m) / 1000,
      distance_m: Math.round(s.computed.distance_m),
      kcal: s.computed.kcal,
      steps: s.computed.steps,
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
    req.on('data', c => { size += c.length; if (size > limit) { reject(new Error('corps trop volumineux')); req.destroy(); } else chunks.push(c); });
    req.on('end', () => resolve(Buffer.concat(chunks).toString('utf8')));
    req.on('error', reject);
  });
}

const stamp = () => new Date().toLocaleTimeString('fr-FR');

const server = http.createServer(async (req, res) => {
  const url = new URL(req.url, 'http://x');
  try {
    if (req.method === 'OPTIONS') { res.writeHead(204, { 'Access-Control-Allow-Origin': '*', 'Access-Control-Allow-Headers': '*' }); return res.end(); }

    if (req.method === 'POST' && url.pathname === '/api/sessions') {
      const s = JSON.parse(await readBody(req));
      if (typeof s.id !== 'number' || !Array.isArray(s.events)) return send(res, 400, { error: 'séance invalide' });
      const r = saveSession(s);
      const c = compute(s);
      console.log(`[${stamp()}] séance #${s.id} ${r.replaced ? 'mise à jour' : 'reçue'} : ${c.walk_s}s de marche, ${c.distance_m} m, ~${c.steps} pas → ${r.name}`);
      broadcast('session', { file: r.name, id: s.id });
      return send(res, 200, { ok: true, file: r.name, replaced: r.replaced });
    }

    if (req.method === 'POST' && url.pathname === '/api/live') {
      onLive(JSON.parse(await readBody(req)), req.socket.remoteAddress, 'http');
      return send(res, 200, { ok: true });
    }

    if (req.method === 'GET' && url.pathname === '/api/live') return send(res, 200, { live, trace, udp_packets: udpCount });

    if (req.method === 'GET' && url.pathname === '/api/stream') {          // flux temps réel vers le navigateur
      res.writeHead(200, { 'Content-Type': 'text/event-stream; charset=utf-8', 'Cache-Control': 'no-store', 'Connection': 'keep-alive', 'Access-Control-Allow-Origin': '*' });
      res.write(`retry: 2000\nevent: init\ndata: ${JSON.stringify({ live, trace })}\n\n`);
      streams.add(res);
      req.on('close', () => streams.delete(res));
      return;
    }
    if (req.method === 'GET' && url.pathname === '/api/sessions')
      return send(res, 200, { profile: PROFILE, health_min_walk_s: Number(process.env.HEALTH_MIN_WALK_S) || 0, sessions: listSessions() });

    if (req.method === 'GET' && url.pathname.startsWith('/api/sessions/')) {
      const f = path.basename(decodeURIComponent(url.pathname.slice('/api/sessions/'.length)));
      const p = path.join(DATA_DIR, f);
      if (!f.endsWith('.json') || !fs.existsSync(p)) return send(res, 404, { error: 'introuvable' });
      const s = JSON.parse(fs.readFileSync(p, 'utf8'));
      return send(res, 200, { ...s, computed: compute(s) });
    }

    // ---- Apple Santé
    if (req.method === 'GET' && url.pathname === '/api/health/pending') {
      const list = healthPending();
      console.log(`[${stamp()}] Santé : ${list.length} séance(s) proposée(s) au raccourci`);
      return send(res, 200, { count: list.length, sessions: list });
    }
    if (url.pathname === '/api/health/done') {
      const f = path.basename(url.searchParams.get('file') || '');
      if (!f || !fs.existsSync(path.join(DATA_DIR, f))) return send(res, 404, { ok: false, error: 'séance inconnue' });
      const st = healthState(); st[f] = Math.floor(Date.now() / 1000); healthSave(st);
      console.log(`[${stamp()}] Santé : ${f} marquée comme transférée`);
      broadcast('session', { file: f });
      return send(res, 200, { ok: true, file: f });
    }
    if (url.pathname === '/api/health/reset') {
      healthSave({});
      console.log(`[${stamp()}] Santé : toutes les séances sont de nouveau à transférer`);
      broadcast('session', {});
      return send(res, 200, { ok: true });
    }

    if (req.method === 'GET' && (url.pathname === '/' || url.pathname === '/index.html'))
      return send(res, 200, fs.readFileSync(path.join(__dirname, 'dashboard.html'), 'utf8'), 'text/html');

    send(res, 404, { error: 'route inconnue' });
  } catch (e) {
    console.error(`[${stamp()}] erreur ${req.method} ${url.pathname} : ${e.message}`);
    send(res, 400, { error: e.message });
  }
});

// Réception temps réel : l'ESP32 envoie ses paquets UDP sur le même numéro de port que l'HTTP
const udp = dgram.createSocket('udp4');
udp.on('message', (buf, rinfo) => {
  try { const m = JSON.parse(buf.toString('utf8')); udpCount++; onLive(m, rinfo.address, 'udp');
        if (process.env.VERBOSE) console.log(`[${stamp()}] udp : ${m.state_name} ${m.speed_kmh} km/h`); }
  catch (e) { /* paquet illisible : ignoré */ }
});
udp.on('error', e => console.error('UDP : ' + e.message));
udp.bind(PORT, '0.0.0.0');
setInterval(() => { for (const res of streams) res.write(': ping\n\n'); }, 15000);   // garde les flux ouverts

server.listen(PORT, '0.0.0.0', () => {
  const ips = Object.values(os.networkInterfaces()).flat().filter(i => i && i.family === 'IPv4' && !i.internal).map(i => i.address);
  console.log(`Serveur MotionX prêt.`);
  console.log(`  Tableau de bord : http://localhost:${PORT}   (HTTP + temps réel UDP sur le port ${PORT})`);
  ips.forEach(ip => console.log(`  Adresse à donner à l'ESP32 : http://${ip}:${PORT}`));
  console.log(`  Données : ${DATA_DIR}`);
  console.log(`  Profil  : ${PROFILE.height_cm} cm, ${PROFILE.weight_kg} kg (variables HEIGHT_CM et WEIGHT_KG)`);
});
