'use strict';
// Doomscroll Rehab: a proxy that makes short-video feeds slower the longer you scroll.
// No dependencies. Node 18+.

const http = require('http');
const net = require('net');
const fs = require('fs');
const path = require('path');
const os = require('os');

// ---------- config ----------

(function loadEnv() {
  const p = path.join(__dirname, '.env');
  if (!fs.existsSync(p)) return;
  for (const line of fs.readFileSync(p, 'utf8').split(/\r?\n/)) {
    const m = line.match(/^\s*([A-Z0-9_]+)\s*=\s*(.*?)\s*$/);
    if (m && !(m[1] in process.env)) process.env[m[1]] = m[2].replace(/^["']|["']$/g, '');
  }
})();

const PROXY_PORT = Number(process.env.PROXY_PORT || 8888);
const DASH_PORT = Number(process.env.DASH_PORT || 3000);

// The four `let` values are the taper plan. The AI coach rewrites them per person.
let START_GRACE_MIN = 10;     // day 1: full speed for the first 10 minutes of a session
let DAILY_FACTOR = 0.93;      // each day the grace period shrinks by 7 percent
const MIN_GRACE_MIN = 1;
const PLAN_DAYS = 14;
let RAMP_MIN = 15;            // minutes to go from full speed to the floor
const MAX_KBPS = 3000;        // speed right after the grace period ends
let MIN_KBPS = 40;            // floor: below the lowest video bitrate, so feeds stall
let planNote = '';            // the coach's explanation of the current plan
let planSource = 'default';   // 'default' or 'coach'
const sessionLog = [];        // finished sessions: { minutes, boosts, endedAt }
const MAX_CONNECT_DELAY_MS = 3000;
const IDLE_RESET_MIN = 10;    // away from the feed this long and the session resets
const ACTIVE_WINDOW_MS = 8000;
const MAX_GRANT_MIN = 10;
const MAX_GRANTS_PER_DAY = 3;

// Host suffixes treated as feeds. The ByteDance China entries (for Hongguo) are
// a best guess; use the dashboard's host list to add whatever your phone really hits.
const targets = new Set((process.env.TARGETS || [
  'instagram.com', 'cdninstagram.com', 'fbcdn.net',
  'threads.net', 'threads.com',
  'tiktok.com', 'tiktokv.com', 'tiktokcdn.com', 'tiktokcdn-us.com',
  'byteoversea.com', 'ibytedtp.com', 'ibyteimg.com', 'muscdn.com',
  'googlevideo.com',
  'snssdk.com', 'pstatp.com', 'byteimg.com', 'bytecdn.cn', 'douyinvod.com', 'fqnovel.com',
].join(',')).split(',').map((s) => s.trim().toLowerCase()).filter(Boolean));

function isTarget(host) {
  host = String(host || '').toLowerCase();
  for (const t of targets) if (host === t || host.endsWith('.' + t)) return true;
  return false;
}

// ---------- session state ----------

const state = {
  sessionMs: 0,       // scaled time spent scrolling in the current session
  lastActive: 0,      // last time feed bytes went through
  boostUntil: 0,      // full speed until this timestamp
  timeScale: Math.max(1, Number(process.env.TIME_SCALE || 1)),
  day: 0,             // day of the taper plan, 0-based
  grantsToday: 0,
};

const hostStats = new Map(); // host -> { bytes, last, target }

function graceFor(day) {
  return Math.max(MIN_GRACE_MIN, START_GRACE_MIN * Math.pow(DAILY_FACTOR, day));
}

function progress() {
  // 0 while in the grace period, then 0..1 along the ramp
  const m = state.sessionMs / 60000;
  const g = graceFor(state.day);
  if (m < g) return 0;
  return Math.min(1, (m - g) / RAMP_MIN);
}

function inGrace() {
  return state.sessionMs / 60000 < graceFor(state.day);
}

function currentKbps() {
  if (Date.now() < state.boostUntil || inGrace()) return Infinity;
  const t = progress();
  return Math.exp(Math.log(MAX_KBPS) + (Math.log(MIN_KBPS) - Math.log(MAX_KBPS)) * t);
}

function currentRate() {
  const k = currentKbps();
  return Number.isFinite(k) ? (k * 1000) / 8 : Infinity; // bytes per second
}

function connectDelayMs() {
  if (Date.now() < state.boostUntil || inGrace()) return 0;
  return Math.round(progress() * MAX_CONNECT_DELAY_MS);
}

function isActive() {
  return Date.now() - state.lastActive < ACTIVE_WINDOW_MS;
}

function idleResetMs() {
  return Math.max(20000, (IDLE_RESET_MIN * 60000) / state.timeScale);
}

let lastTick = Date.now();
setInterval(() => {
  const now = Date.now();
  const dt = now - lastTick;
  lastTick = now;
  const boosted = now < state.boostUntil;
  if (isActive()) {
    if (!boosted) state.sessionMs += dt * state.timeScale;
  } else if (state.sessionMs > 0 && now - state.lastActive > idleResetMs()) {
    sessionLog.push({ minutes: Math.round(state.sessionMs / 6000) / 10, boosts: state.grantsToday, endedAt: new Date().toISOString() });
    if (sessionLog.length > 50) sessionLog.shift();
    state.sessionMs = 0;
  }
}, 250);

function noteBytes(host, n, target) {
  let s = hostStats.get(host);
  if (!s) {
    s = { bytes: 0, last: 0, target };
    hostStats.set(host, s);
    if (hostStats.size > 400) {
      const oldest = [...hostStats.entries()].sort((a, b) => a[1].last - b[1].last)[0];
      hostStats.delete(oldest[0]);
    }
  }
  s.bytes += n;
  s.last = Date.now();
  s.target = target;
  if (target) state.lastActive = s.last;
}

// ---------- throttling ----------

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

// One shared token bucket, so opening many connections does not get around the limit.
const limiter = {
  tokens: 0,
  last: Date.now(),
  chain: Promise.resolve(),
  take(n) {
    const p = this.chain.then(() => this._take(n));
    this.chain = p.catch(() => {});
    return p;
  },
  async _take(n) {
    for (;;) {
      const rate = currentRate();
      const now = Date.now();
      if (!Number.isFinite(rate)) {
        this.tokens = 0;
        this.last = now;
        return;
      }
      const cap = Math.max(rate, n);
      this.tokens = Math.min(cap, this.tokens + ((now - this.last) / 1000) * rate);
      this.last = now;
      if (this.tokens >= n) {
        this.tokens -= n;
        return;
      }
      await sleep(Math.max(10, Math.min(250, ((n - this.tokens) / rate) * 1000)));
    }
  },
};

function waitDrain(dst) {
  return new Promise((resolve) => {
    const done = () => {
      dst.removeListener('drain', done);
      dst.removeListener('close', done);
      dst.removeListener('error', done);
      resolve();
    };
    dst.once('drain', done);
    dst.once('close', done);
    dst.once('error', done);
  });
}

function throttledPipe(src, dst, host) {
  src.on('data', async (chunk) => {
    src.pause();
    try {
      let off = 0;
      while (off < chunk.length) {
        const rate = currentRate();
        const piece = Number.isFinite(rate) ? Math.max(256, Math.floor(rate / 8)) : chunk.length;
        const part = chunk.subarray(off, off + piece);
        off += part.length;
        await limiter.take(part.length);
        if (dst.destroyed || dst.writableEnded) return;
        noteBytes(host, part.length, true);
        if (!dst.write(part)) await waitDrain(dst);
      }
    } catch (e) {
      // socket went away mid-write; nothing to do
    }
    if (!src.destroyed) src.resume();
  });
  src.on('end', () => { if (!dst.destroyed) dst.end(); });
}

// ---------- access control ----------

const extraAllowed = new Set((process.env.ALLOW_IPS || '').split(',').map((s) => s.trim()).filter(Boolean));

function clientAllowed(addr) {
  const ip = String(addr || '').replace(/^::ffff:/, '');
  if (extraAllowed.has(ip)) return true;
  if (ip === '::1' || ip.startsWith('127.')) return true;
  if (ip.startsWith('10.') || ip.startsWith('192.168.')) return true;
  const m = ip.match(/^172\.(\d+)\./);
  return !!m && Number(m[1]) >= 16 && Number(m[1]) <= 31;
}

// ---------- proxy ----------

const proxy = http.createServer((req, res) => {
  // plain HTTP through the proxy
  if (!clientAllowed(req.socket.remoteAddress)) return req.socket.destroy();
  let url;
  try {
    url = new URL(req.url);
  } catch (e) {
    res.writeHead(400);
    return res.end('This is a proxy. Open the dashboard on port ' + DASH_PORT + '.');
  }
  const host = url.hostname;
  const target = isTarget(host);
  const headers = { ...req.headers };
  delete headers['proxy-connection'];
  const go = () => {
    const up = http.request({
      host, port: url.port || 80, method: req.method, path: url.pathname + url.search, headers,
    }, (upRes) => {
      res.writeHead(upRes.statusCode || 502, upRes.headers);
      if (target) {
        throttledPipe(upRes, res, host);
      } else {
        upRes.on('data', (c) => noteBytes(host, c.length, false));
        upRes.pipe(res);
      }
    });
    up.on('error', () => { if (!res.headersSent) res.writeHead(502); res.end(); });
    req.pipe(up);
  };
  if (target) setTimeout(go, connectDelayMs()); else go();
});

proxy.on('connect', (req, client, head) => {
  // HTTPS tunnels: we only ever see the hostname, never the content
  if (!clientAllowed(client.remoteAddress)) return client.destroy();
  const m = String(req.url).match(/^\[?([^\]]+?)\]?:(\d+)$/);
  if (!m) return client.destroy();
  const host = m[1].toLowerCase();
  const port = Number(m[2]);
  const target = isTarget(host);
  client.on('error', () => {});

  const open = () => {
    if (client.destroyed) return;
    const up = net.connect(port, host);
    up.on('error', () => client.destroy());
    client.on('error', () => up.destroy());
    client.on('close', () => up.destroy());
    up.on('close', () => { if (!client.destroyed) client.end(); });
    up.on('connect', () => {
      client.write('HTTP/1.1 200 Connection Established\r\n\r\n');
      if (head && head.length) up.write(head);
      client.pipe(up);
      if (target) {
        throttledPipe(up, client, host);
      } else {
        up.on('data', (c) => noteBytes(host, c.length, false));
        up.pipe(client);
      }
    });
  };
  if (target) {
    state.lastActive = Date.now();
    setTimeout(open, connectDelayMs());
  } else {
    open();
  }
});

proxy.on('clientError', (err, socket) => socket.destroy());

// ---------- AI negotiator ----------

function aiConfigured() {
  return !!(process.env.LLM_API_KEY && process.env.LLM_BASE_URL && process.env.LLM_MODEL);
}

function systemPrompt() {
  const kbps = currentKbps();
  return [
    'You are the negotiator inside Doomscroll Rehab, an app that slows short-video feeds the longer someone scrolls.',
    'The user has been slowed down and is asking you for full speed back.',
    '',
    'Right now:',
    '- Scrolling this session: ' + Math.round(state.sessionMs / 60000) + ' minutes',
    '- Current feed speed: ' + (Number.isFinite(kbps) ? Math.round(kbps) + ' kbps' : 'full speed'),
    '- Speed boosts already granted today: ' + state.grantsToday + ' of ' + MAX_GRANTS_PER_DAY,
    '- Day ' + (state.day + 1) + ' of a ' + PLAN_DAYS + '-day taper',
    '',
    'How to talk (motivational interviewing):',
    '- Never lecture, never shame, never quote statistics.',
    '- Ask one short open question at a time so the user says in their own words what they want from the next few minutes.',
    '- Reflect their answer back in a few words.',
    '- If they give a specific reason and a specific stopping point, grant a boost. Grant less than they ask for when they are vague.',
    '- If they just say "because I want to", ask what they were hoping to feel, once. If they are still vague, grant nothing and offer one small alternative they could do in two minutes.',
    '- If all boosts for today are used, say so plainly and grant nothing.',
    '- Keep every reply under 45 words. Reply in the language the user writes in.',
    '',
    'Answer with JSON only, no other text: {"reply": "<what you say>", "grant_minutes": <integer 0 to ' + MAX_GRANT_MIN + '>}',
  ].join('\n');
}

async function askLLM(messages, system) {
  const base = process.env.LLM_BASE_URL.replace(/\/+$/, '');
  const r = await fetch(base + '/chat/completions', {
    method: 'POST',
    headers: { 'content-type': 'application/json', authorization: 'Bearer ' + process.env.LLM_API_KEY },
    body: JSON.stringify({
      model: process.env.LLM_MODEL,
      messages: [{ role: 'system', content: system || systemPrompt() }, ...messages],
      temperature: 0.5,
      max_tokens: 600,
    }),
    signal: AbortSignal.timeout(25000),
  });
  if (!r.ok) throw new Error('LLM HTTP ' + r.status + ': ' + (await r.text()).slice(0, 200));
  const j = await r.json();
  return String((j.choices && j.choices[0] && j.choices[0].message && j.choices[0].message.content) || '');
}

function parseDecision(text) {
  const clean = text.replace(/<think>[\s\S]*?<\/think>/g, '').trim();
  const a = clean.indexOf('{');
  const b = clean.lastIndexOf('}');
  if (a !== -1 && b > a) {
    try {
      const j = JSON.parse(clean.slice(a, b + 1));
      return { reply: String(j.reply || '').trim(), grant: Number(j.grant_minutes) || 0 };
    } catch (e) {
      // fall through to plain text
    }
  }
  return { reply: clean, grant: 0 };
}

// Used only when no model is configured or the call fails. The dashboard labels it.
function scriptedDecision(messages) {
  const turns = messages.filter((m) => m.role === 'user').length;
  if (state.grantsToday >= MAX_GRANTS_PER_DAY) {
    return { reply: 'You have used all ' + MAX_GRANTS_PER_DAY + ' boosts for today. The feed stays slow until tomorrow.', grant: 0 };
  }
  if (turns <= 1) return { reply: 'What do you want from the next few minutes on the feed?', grant: 0 };
  return { reply: 'Okay. Five minutes at full speed, then it slows again.', grant: 5 };
}

async function negotiate(messages) {
  let decision;
  let source = 'model';
  let error = null;
  if (aiConfigured()) {
    try {
      decision = parseDecision(await askLLM(messages));
      if (!decision.reply) throw new Error('empty reply');
    } catch (e) {
      error = String(e.message || e);
      decision = null;
    }
  }
  if (!decision) {
    decision = scriptedDecision(messages);
    source = 'scripted';
  }
  let grant = Math.max(0, Math.min(MAX_GRANT_MIN, Math.round(decision.grant)));
  if (state.grantsToday >= MAX_GRANTS_PER_DAY) grant = 0;
  if (grant > 0) {
    state.grantsToday += 1;
    state.boostUntil = Date.now() + Math.max(20000, (grant * 60000) / state.timeScale);
  }
  return { reply: decision.reply, grantMinutes: grant, source, error };
}

// ---------- AI coach: writes the taper plan ----------

function extractJson(text) {
  const clean = String(text).replace(/<think>[\s\S]*?<\/think>/g, '');
  const a = clean.indexOf('{');
  const b = clean.lastIndexOf('}');
  if (a === -1 || b <= a) throw new Error('model did not return JSON');
  return JSON.parse(clean.slice(a, b + 1));
}

const clamp = (v, lo, hi, fallback) => (Number.isFinite(Number(v)) ? Math.max(lo, Math.min(hi, Number(v))) : fallback);

async function coachPlan(about) {
  if (!aiConfigured()) throw new Error('No model configured. Set LLM_BASE_URL, LLM_API_KEY and LLM_MODEL in .env.');
  const system = [
    'You are the coach inside Doomscroll Rehab. The app does not block short-video feeds. It makes them slower the longer one session runs, and tightens a little every day for 14 days.',
    'You set four numbers for this person:',
    '- start_grace_min (2 to 30): minutes of full speed at the start of a session on day 1. Set it a little under how long their sessions run now, so day 1 barely feels different.',
    '- daily_factor (0.85 to 0.98): the full-speed window is multiplied by this each day. Closer to 1 is gentler. Use gentler values for people who have quit and relapsed before.',
    '- ramp_min (5 to 30): minutes to fall from full speed to the floor. Shorter for people who say they lose track of time.',
    '- floor_kbps (20 to 300): the slowest speed. 40 stalls video entirely. 150 to 300 leaves it blurry but watchable, for people who would remove the app if it stalled.',
    'Then write note: at most 50 words, to the person, in the language they wrote in, saying why these numbers fit what they told you. No lecturing, no statistics.',
    'Answer with JSON only: {"start_grace_min": n, "daily_factor": n, "ramp_min": n, "floor_kbps": n, "note": "..."}',
  ].join('\n');
  const user = 'What the person said about their scrolling:\n' + about +
    '\n\nSessions measured by the app so far (minutes, speed boosts asked for):\n' +
    (sessionLog.length ? JSON.stringify(sessionLog.slice(-20)) : 'none yet');
  const j = extractJson(await askLLM([{ role: 'user', content: user }], system));
  START_GRACE_MIN = clamp(j.start_grace_min, 2, 30, START_GRACE_MIN);
  DAILY_FACTOR = clamp(j.daily_factor, 0.85, 0.98, DAILY_FACTOR);
  RAMP_MIN = clamp(j.ramp_min, 5, 30, RAMP_MIN);
  MIN_KBPS = clamp(j.floor_kbps, 20, 300, MIN_KBPS);
  planNote = String(j.note || '').slice(0, 500);
  planSource = 'coach';
}

// ---------- AI feed finder: which of the hosts the phone is loading are feeds ----------

async function findFeeds() {
  if (!aiConfigured()) throw new Error('No model configured. Set LLM_BASE_URL, LLM_API_KEY and LLM_MODEL in .env.');
  const now = Date.now();
  const seen = [...hostStats.entries()]
    .filter(([h, s]) => !isTarget(h) && now - s.last < 600000)
    .sort((a, b) => b[1].bytes - a[1].bytes)
    .slice(0, 40)
    .map(([h, s]) => ({ host: h, kb: Math.round(s.bytes / 1024) }));
  if (!seen.length) return [];
  const system = [
    'You are given hostnames a phone connected to in the last ten minutes, with kilobytes downloaded.',
    'Pick the ones that serve short-video or infinite social feeds or their video CDNs (for example TikTok, Douyin, Instagram Reels, Threads, YouTube Shorts, Hongguo, Kuaishou, Xiaohongshu, Facebook Reels).',
    'Do not pick messaging, maps, payments, search, email, app stores, system services, analytics or ad hosts.',
    'Answer with JSON only: {"feeds": ["domain suffix", ...]} using the shortest suffix that still belongs to that service, for example "tiktokcdn.com". Use an empty list if none.',
  ].join('\n');
  const j = extractJson(await askLLM([{ role: 'user', content: JSON.stringify(seen) }], system));
  const added = [];
  for (const raw of Array.isArray(j.feeds) ? j.feeds : []) {
    const suffix = String(raw).trim().toLowerCase().replace(/^\*?\./, '');
    if (!/^[a-z0-9-]+(\.[a-z0-9-]+)+$/.test(suffix)) continue;
    // only accept suffixes of hosts the phone really contacted
    if (!seen.some((s) => s.host === suffix || s.host.endsWith('.' + suffix))) continue;
    if (!targets.has(suffix)) { targets.add(suffix); added.push(suffix); }
  }
  return added;
}

// ---------- dashboard + API ----------

function lanAddresses() {
  const out = [];
  for (const list of Object.values(os.networkInterfaces())) {
    for (const a of list || []) if (a.family === 'IPv4' && !a.internal) out.push(a.address);
  }
  return out;
}

function snapshot() {
  const now = Date.now();
  const kbps = currentKbps();
  const boosted = now < state.boostUntil;
  let stage = 'idle';
  if (boosted) stage = 'boost';
  else if (state.sessionMs === 0 && !isActive()) stage = 'idle';
  else if (inGrace()) stage = 'full';
  else if (progress() >= 1) stage = 'floor';
  else stage = 'slowing';

  const hosts = [...hostStats.entries()]
    .filter(([, s]) => now - s.last < 120000)
    .sort((a, b) => b[1].bytes - a[1].bytes)
    .slice(0, 12)
    .map(([host, s]) => ({ host, target: isTarget(host), kb: Math.round(s.bytes / 1024), agoSec: Math.round((now - s.last) / 1000) }));

  const plan = [];
  for (let d = 0; d < PLAN_DAYS; d++) plan.push(Math.round(graceFor(d) * 10) / 10);

  return {
    stage,
    active: isActive(),
    sessionMin: state.sessionMs / 60000,
    graceMin: graceFor(state.day),
    rampMin: RAMP_MIN,
    kbps: Number.isFinite(kbps) ? Math.round(kbps) : null,
    maxKbps: MAX_KBPS,
    minKbps: MIN_KBPS,
    connectDelayMs: connectDelayMs(),
    boostLeftSec: boosted ? Math.ceil((state.boostUntil - now) / 1000) : 0,
    timeScale: state.timeScale,
    day: state.day,
    plan,
    planNote,
    planSource,
    planParams: { startGraceMin: START_GRACE_MIN, dailyFactor: DAILY_FACTOR, rampMin: RAMP_MIN, floorKbps: MIN_KBPS },
    sessionsLogged: sessionLog.length,
    grantsToday: state.grantsToday,
    maxGrants: MAX_GRANTS_PER_DAY,
    hosts,
    targets: [...targets].sort(),
    proxy: { addresses: lanAddresses(), port: PROXY_PORT },
    ai: aiConfigured() ? process.env.LLM_MODEL : null,
  };
}

function readJson(req) {
  return new Promise((resolve, reject) => {
    let size = 0;
    const chunks = [];
    req.on('data', (c) => {
      size += c.length;
      if (size > 200000) { reject(new Error('too large')); req.destroy(); return; }
      chunks.push(c);
    });
    req.on('end', () => {
      try { resolve(chunks.length ? JSON.parse(Buffer.concat(chunks).toString('utf8')) : {}); }
      catch (e) { reject(e); }
    });
    req.on('error', reject);
  });
}

function sendJson(res, code, obj) {
  const body = JSON.stringify(obj);
  res.writeHead(code, { 'content-type': 'application/json; charset=utf-8', 'cache-control': 'no-store' });
  res.end(body);
}

const dash = http.createServer(async (req, res) => {
  if (!clientAllowed(req.socket.remoteAddress)) return req.socket.destroy();
  const url = new URL(req.url, 'http://x');
  try {
    if (req.method === 'GET' && url.pathname === '/api/state') return sendJson(res, 200, snapshot());

    if (req.method === 'POST' && url.pathname === '/api/chat') {
      const body = await readJson(req);
      const messages = (Array.isArray(body.messages) ? body.messages : [])
        .filter((m) => m && (m.role === 'user' || m.role === 'assistant') && typeof m.content === 'string')
        .slice(-12)
        .map((m) => ({ role: m.role, content: m.content.slice(0, 600) }));
      if (!messages.length) return sendJson(res, 400, { error: 'no messages' });
      return sendJson(res, 200, await negotiate(messages));
    }

    if (req.method === 'POST' && url.pathname === '/api/plan') {
      const body = await readJson(req);
      const about = String(body.about || '').trim().slice(0, 1200);
      if (!about) return sendJson(res, 400, { error: 'Tell the coach something first.' });
      await coachPlan(about);
      return sendJson(res, 200, snapshot());
    }

    if (req.method === 'POST' && url.pathname === '/api/find-feeds') {
      const added = await findFeeds();
      return sendJson(res, 200, { added, state: snapshot() });
    }

    if (req.method === 'POST' && url.pathname === '/api/demo') {
      const body = await readJson(req);
      if (body.reset) {
        state.sessionMs = 0;
        state.boostUntil = 0;
        state.grantsToday = 0;
      }
      if (Number.isFinite(body.timeScale)) state.timeScale = Math.max(1, Math.min(120, body.timeScale));
      if (Number.isFinite(body.addMinutes)) {
        state.sessionMs = Math.max(0, state.sessionMs + body.addMinutes * 60000);
        state.lastActive = Date.now();
      }
      if (Number.isFinite(body.day)) state.day = Math.max(0, Math.min(PLAN_DAYS - 1, Math.round(body.day)));
      return sendJson(res, 200, snapshot());
    }

    if (req.method === 'POST' && url.pathname === '/api/targets') {
      const body = await readJson(req);
      const clean = (s) => String(s || '').trim().toLowerCase().replace(/^\*?\./, '');
      if (body.add && /^[a-z0-9.-]+\.[a-z]{2,}$/.test(clean(body.add))) targets.add(clean(body.add));
      if (body.remove) targets.delete(clean(body.remove));
      return sendJson(res, 200, snapshot());
    }

    if (req.method === 'GET' && (url.pathname === '/' || url.pathname === '/index.html')) {
      const html = fs.readFileSync(path.join(__dirname, 'public', 'index.html'));
      res.writeHead(200, { 'content-type': 'text/html; charset=utf-8', 'cache-control': 'no-store' });
      return res.end(html);
    }

    res.writeHead(404);
    res.end('not found');
  } catch (e) {
    sendJson(res, 500, { error: String(e.message || e) });
  }
});

proxy.listen(PROXY_PORT, '0.0.0.0', () => {
  console.log('Proxy      : port ' + PROXY_PORT + '  (set this as the Wi-Fi proxy on the phone)');
  for (const a of lanAddresses()) console.log('             ' + a + ':' + PROXY_PORT);
});
dash.listen(DASH_PORT, '0.0.0.0', () => {
  console.log('Dashboard  : http://localhost:' + DASH_PORT);
  console.log('Negotiator : ' + (aiConfigured() ? process.env.LLM_MODEL : 'no model configured, scripted replies'));
});

process.on('uncaughtException', (e) => console.error('uncaught:', e.message));
