// Page web embarquée de l'ESP32 (http://motionx.local, http://<ip>, ou http://192.168.4.1 sur le Wi-Fi de secours)
#pragma once
#include <Arduino.h>

const char INDEX_HTML[] PROGMEM = R"HTML(<!DOCTYPE html>
<html lang="fr"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>MotionX</title>
<style>
:root{--bg:#f6f5f1;--fg:#1c2128;--mut:#667080;--card:#fff;--line:#d8d4ca;--acc:#1f6f5a;--warn:#b4541f;--warnbg:#fdf0e3}
@media (prefers-color-scheme:dark){:root{color-scheme:dark;--bg:#15181c;--fg:#e8e6e1;--mut:#9aa3ad;--card:#1e2227;--line:#343a42;--acc:#58c7a5;--warn:#e79a6b;--warnbg:#33261c}}
*{box-sizing:border-box}body{margin:0 auto;padding:20px;background:var(--bg);color:var(--fg);font:15px/1.45 system-ui,sans-serif;max-width:780px}
h1{font-size:20px;margin:0 0 14px}h2{font-size:13px;margin:24px 0 8px;color:var(--mut);font-weight:650;text-transform:uppercase;letter-spacing:.05em}
.card{background:var(--card);border:1px solid var(--line);border-radius:8px;padding:14px 16px}
.big{font-size:44px;font-weight:650;font-variant-numeric:tabular-nums;line-height:1.1}
.row{display:flex;gap:22px;flex-wrap:wrap;margin-top:8px;color:var(--mut)}.row b{color:var(--fg);font-variant-numeric:tabular-nums}
table{width:100%;border-collapse:collapse;font-variant-numeric:tabular-nums}th,td{text-align:left;padding:6px 8px;border-bottom:1px solid var(--line)}
th{color:var(--mut);font-weight:600;font-size:13px}tr:last-child td{border-bottom:0}
label{display:block;font-size:13px;color:var(--mut);margin:10px 0 3px}
input{width:100%;padding:7px 9px;border:1px solid var(--line);border-radius:6px;background:var(--card);color:var(--fg);font:inherit}
button{margin-top:10px;padding:7px 12px;border:1px solid var(--acc);border-radius:6px;background:var(--acc);color:#fff;font:inherit;cursor:pointer}
button.ghost{background:transparent;color:var(--acc)}button:disabled{opacity:.5}
small,.mut{color:var(--mut)}a{color:var(--acc)}
.warn{background:var(--warnbg);border:1px solid var(--warn);color:var(--fg);border-radius:8px;padding:10px 14px;margin-bottom:12px}
.grid{display:grid;grid-template-columns:repeat(auto-fit,minmax(150px,1fr));gap:6px 18px}.grid span{color:var(--mut);font-size:13px}.grid b{display:block;font-variant-numeric:tabular-nums}
</style></head><body>
<h1>MotionX <small id="fw"></small></h1>
<div class="warn" id="safe" hidden><b>Mode sans échec.</b> Le firmware a planté plusieurs fois de suite : le décodage est désactivé. Envoie une mise à jour, ou <a href="#" onclick="reboot(1);return false">redémarre en mode normal</a>.</div>
<div class="warn" id="apw" hidden><b>Wi‑Fi de secours actif.</b> Le réseau configuré est introuvable. Corrige le nom ou le mot de passe ci‑dessous.</div>

<div class="card"><div class="big"><span id="spd">–</span> <small>km/h</small></div>
<div id="st" style="margin-top:4px">–</div>
<div class="row"><span>Séance <b id="el">–</b></span><span>Marche <b id="wk">–</b></span><span>Distance <b id="di">–</b></span></div></div>

<h2>Dernières séances en mémoire</h2>
<div class="card" style="padding:4px 8px"><table><thead><tr><th>#</th><th>Début</th><th>Marche</th><th>Distance</th><th>Moy.</th><th>Max</th></tr></thead><tbody id="tb"><tr><td colspan="6">Chargement…</td></tr></tbody></table></div>

<h2>Réglages</h2>
<div class="card">
<label for="srv">Serveur de destination</label><input id="srv" placeholder="http://192.168.1.10:3000">
<button onclick="saveSrv()">Enregistrer le serveur</button> <button class="ghost" onclick="resend()">Renvoyer toutes les séances</button>
<label for="ssid" style="margin-top:18px">Réseau Wi‑Fi (2,4 GHz)</label><input id="ssid" autocomplete="off">
<label for="pass">Mot de passe Wi‑Fi</label><input id="pass" type="password" autocomplete="new-password" placeholder="laisser vide pour un réseau ouvert">
<button onclick="saveWifi()">Changer de réseau</button>
<div style="margin-top:8px"><small id="msg"></small></div></div>

<h2>Mise à jour du firmware</h2>
<div class="card"><small>Dans Arduino IDE : Croquis → Exporter les binaires compilés, puis choisir le fichier qui se termine par <b>.ino.bin</b>.</small>
<input id="bin" type="file" accept=".bin" style="margin-top:10px"><button id="ub" onclick="update()">Envoyer la mise à jour</button>
<div style="margin-top:8px"><small id="um"></small></div></div>

<h2>Diagnostic</h2>
<div class="card"><div class="grid" id="dg"></div>
<button class="ghost" onclick="location.href='/api/log'">Voir le journal</button> <button class="ghost" onclick="reboot(0)">Redémarrer l'ESP32</button></div>

<script>
const $=i=>document.getElementById(i);
const hms=s=>{s=Math.round(s);const h=Math.floor(s/3600),m=Math.floor(s/60)%60;return (h?h+'h ':'')+String(m).padStart(2,'0')+':'+String(s%60).padStart(2,'0')};
const dur=s=>s>=86400?Math.floor(s/86400)+' j '+Math.floor(s%86400/3600)+' h':s>=3600?Math.floor(s/3600)+' h '+Math.floor(s%3600/60)+' min':Math.floor(s/60)+' min';
let filled=false;
async function tick(){try{const s=await (await fetch('/api/status')).json();
 $('fw').textContent='v'+s.fw;$('spd').textContent=s.speed_kmh.toFixed(1);
 $('st').textContent=s.safe_mode?'décodage désactivé':(s.signal?s.state_name:'aucun signal du tapis');
 $('el').textContent=s.in_session?hms(s.elapsed_s):'–';$('wk').textContent=s.in_session?hms(s.walk_s):'–';
 $('di').textContent=s.in_session?(s.distance_m/1000).toFixed(3)+' km':'–';
 $('safe').hidden=!s.safe_mode;$('apw').hidden=!s.ap;
 if(!filled){$('srv').value=s.server;$('ssid').value=s.ssid;filled=true}
 const tot=s.frames_ok+s.frames_bad;
 const d=[['Allumé depuis',dur(s.uptime_s)],['Dernier démarrage',s.reset],['Plantages (total)',s.crashes],
  ['Wi‑Fi',s.wifi?s.ssid+' · '+s.rssi+' dBm':'non connecté'],['Adresse',s.ip||'–'],['Temps réel',s.udp_sent+' paquets'],
  ['Trames rejetées',tot?(100*s.frames_bad/tot).toFixed(2)+' %':'–'],['Séances en mémoire',s.stored+' ('+s.pending+' à envoyer)'],
  ['Stockage',s.fs_used_kb+' / '+s.fs_total_kb+' Ko'],['Mémoire libre',Math.round(s.heap/1024)+' Ko (min '+Math.round(s.heap_min/1024)+')']];
 $('dg').innerHTML=d.map(x=>'<div><span>'+x[0]+'</span><b>'+x[1]+'</b></div>').join('');
}catch(e){$('st').textContent='ESP32 injoignable'}}
async function list(){try{const a=await (await fetch('/api/sessions?limit=20')).json();
 $('tb').innerHTML=a.length?a.map(x=>'<tr><td>'+x.id+'</td><td>'+(x.start?new Date(x.start*1000).toLocaleString('fr-FR'):'heure inconnue')+'</td><td>'+hms(x.walk_s)+'</td><td>'+(x.distance_m/1000).toFixed(3)+' km</td><td>'+x.avg_kmh.toFixed(1)+'</td><td>'+x.max_kmh.toFixed(1)+'</td></tr>').join(''):'<tr><td colspan="6">Aucune séance enregistrée</td></tr>';
}catch(e){}}
async function call(u,o){const r=await fetch(u,o);if(!r.ok)throw new Error(r.status==401?'mot de passe administrateur refusé':'erreur '+r.status);return r}
async function saveSrv(){try{await call('/api/config?server='+encodeURIComponent($('srv').value));$('msg').textContent='Serveur enregistré.'}catch(e){$('msg').textContent=e.message}}
async function resend(){try{await call('/api/config?resend=1');$('msg').textContent='Renvoi demandé.'}catch(e){$('msg').textContent=e.message}}
async function saveWifi(){if(!confirm('Changer de réseau Wi‑Fi ? Si les identifiants sont faux, l\'ESP32 rouvrira son Wi‑Fi de secours "MotionX-Setup" après 90 secondes.'))return;
 try{await call('/api/wifi',{method:'POST',body:new URLSearchParams({ssid:$('ssid').value,pass:$('pass').value})});$('msg').textContent='Réseau enregistré, reconnexion en cours…'}catch(e){$('msg').textContent=e.message}}
async function reboot(n){if(!confirm('Redémarrer l\'ESP32 ?'))return;try{await call('/api/reboot'+(n?'?normal=1':''));$('msg').textContent='Redémarrage…';setTimeout(()=>location.reload(),8000)}catch(e){alert(e.message)}}
async function update(){const f=$('bin').files[0];if(!f){$('um').textContent='Choisis d\'abord un fichier .bin';return}
 if(!/\.bin$/.test(f.name)||/bootloader|partitions|merged/.test(f.name)){$('um').textContent='Mauvais fichier : il faut celui qui se termine par .ino.bin';return}
 try{await call('/api/auth');$('ub').disabled=true;$('um').textContent='Envoi de '+Math.round(f.size/1024)+' Ko… ne coupe pas le tapis.';
  const fd=new FormData();fd.append('firmware',f,f.name);const r=await fetch('/update',{method:'POST',body:fd});const t=await r.text();$('um').textContent=t;
  if(r.ok)setTimeout(()=>location.reload(),20000);else $('ub').disabled=false}
 catch(e){$('um').textContent='Connexion coupée : '+e.message+'. Si l\'envoi était terminé, la page reviendra après le redémarrage.';$('ub').disabled=false;setTimeout(()=>location.reload(),20000)}}
tick();list();setInterval(tick,1000);setInterval(list,20000);
</script></body></html>)HTML";
