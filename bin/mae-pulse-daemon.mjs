#!/usr/bin/env node
// mae-pulse-daemon — real-time substrate runtime.
//
// V1 capabilities:
//   - PULSE          : vault file-change broadcast → peers pull
//   - PRESENCE       : 60s liveness beacon
//   - Future stubs   : CHAT, KEY-EXCHANGE, REPO-PULSE (protocol-reserved, no impl yet)
//
// Architecture (per design doc 2026-06-25):
//   - One daemon per substrate node (noodles, sequoia, tunafish)
//   - UDP socket :38478, peer-to-peer on LAN, coturn relay TBD for cross-NAT
//   - Ed25519 signatures using operator's verum-class key at ~/.verum/operator-ed25519.key
//   - Same operator identity across all nodes; machine_id in envelope distinguishes
//   - fs.watch (stdlib, no chokidar dep) with debounce + recursive
//   - vault-write-tx.sh wraps ALL git operations (lock-serialized)
//   - launchd KeepAlive=true; failsafe is the */3 cron (daemon dies → cron catches up)
//
// Wire protocol v1 — extensible by design:
//   {
//     "v": 1,
//     "ts": "2026-06-25T19:30:00Z",
//     "from": "verum:ramene/noodles",       # operator-id/machine-id
//     "type": "pulse" | "presence" | "chat" | "key-exchange" | "repo-pulse",
//     "payload": { ... type-specific ... },
//     "sig": "<ed25519-base64url-64-chars>"
//   }
//
// Lifecycle:
//   ~/Library/LaunchAgents/com.mae.pulse-daemon.plist  (KeepAlive=true, RunAtLoad=true)
//   Logs to ~/.claude-tmp/mae-pulse-daemon.log

import dgram from 'node:dgram';
import fs from 'node:fs';
import { spawn, execFileSync, execSync } from 'node:child_process';
import crypto from 'node:crypto';
import path from 'node:path';
import os from 'node:os';

// ─── Config ─────────────────────────────────────────────────────────────────
const HOME = os.homedir();
const PORT = 38478;
const VAULT = `${HOME}/.remote/@vaults/.build/obsidian-vault`;
const PEERS_FILE = `${HOME}/.local/share/mae-substrate/pulse/peers.json`;
const SECRET_KEY_PATH = `${HOME}/.verum/operator-ed25519.key`;
const VAULT_WRITE_TX = `${HOME}/.bin/vault-write-tx.sh`;
const VAULT_AUTOSYNC = `${HOME}/.bin/vault-autosync.sh`;
const HOSTNAME = (() => {
  // Prefer mesh-canonical name written by install.sh (noodles/sequoia/tunafish)
  // — sequoia's hostname is "Ramenes-MacBook-Pro-7", not "sequoia".
  const meshPath = `${os.homedir()}/.local/share/mae-substrate/.host-mesh`;
  if (fs.existsSync(meshPath)) {
    const mesh = fs.readFileSync(meshPath, 'utf8').trim();
    if (mesh) return mesh;
  }
  try { return require('node:child_process').execSync('hostname -s', {encoding:'utf8'}).trim(); }
  catch { return os.hostname().split('.')[0]; }
})();
const OPERATOR_ID = 'verum:ramene';      // single-operator mesh v1
const FROM = `${OPERATOR_ID}/${HOSTNAME}`;

const DEBOUNCE_MS = 1000;
const SUPPRESSION_MS = 5000;             // post-pull, suppress re-broadcast for 5s
const PRESENCE_INTERVAL_MS = 60_000;
const PROTOCOL_VERSION = 1;

const IGNORE_PATHS = [
  /(^|\/)\.git(\/|$)/,                   // .git/ directory at any depth (also catches `.git` as top-level filename from fs.watch)
  /\/\.obsidian\/workspace.*\.json$/,
  /\/\.obsidian\/cache$/,
  /\/_review-/,                          // soft-launch staging area — too noisy
  /\.swp$/, /\.tmp$/, /~$/,
  /\.lock$/,
];

// ─── Log ────────────────────────────────────────────────────────────────────
function log(msg, level='info') {
  const ts = new Date().toISOString();
  process.stdout.write(`${ts} [${level}] ${msg}\n`);
}

// ─── Crypto: Ed25519 sign/verify via Node stdlib ────────────────────────────
let SECRET_KEY = null;
let PUB_KEYS = new Map();   // machine_id → KeyObject

function loadSecretKey() {
  if (!fs.existsSync(SECRET_KEY_PATH)) {
    log(`secret key missing: ${SECRET_KEY_PATH} — daemon cannot sign`, 'error');
    process.exit(1);
  }
  const raw = fs.readFileSync(SECRET_KEY_PATH);
  // Operator's verum key is PEM Ed25519. Use stdlib createPrivateKey.
  SECRET_KEY = crypto.createPrivateKey(raw);
  log(`secret key loaded (Ed25519)`);
}

function loadPeers() {
  if (!fs.existsSync(PEERS_FILE)) {
    log(`peers file missing: ${PEERS_FILE}`, 'error');
    process.exit(1);
  }
  const peers = JSON.parse(fs.readFileSync(PEERS_FILE, 'utf8'));
  let count = 0;
  for (const [name, p] of Object.entries(peers)) {
    if (name === HOSTNAME) continue;     // skip self
    if (p.pub_key_pem) {
      PUB_KEYS.set(name, crypto.createPublicKey(p.pub_key_pem));
    }
    count++;
  }
  log(`peers loaded: ${count} (excluding self=${HOSTNAME})`);
  return peers;
}

function sign(payloadBuf) {
  return crypto.sign(null, payloadBuf, SECRET_KEY).toString('base64url');
}

function verify(payloadBuf, sigB64u, machineId) {
  const pub = PUB_KEYS.get(machineId);
  if (!pub) return false;
  try {
    return crypto.verify(null, payloadBuf, pub, Buffer.from(sigB64u, 'base64url'));
  } catch { return false; }
}

// ─── Envelope ───────────────────────────────────────────────────────────────
function envelope(type, payload) {
  const base = {
    v: PROTOCOL_VERSION,
    ts: new Date().toISOString(),
    from: FROM,
    type,
    payload,
  };
  const canonical = JSON.stringify(base);
  const sig = sign(Buffer.from(canonical, 'utf8'));
  return JSON.stringify({ ...base, sig });
}

function parseAndVerify(buf) {
  let msg;
  try { msg = JSON.parse(buf.toString('utf8')); } catch { return null; }
  if (msg.v !== PROTOCOL_VERSION) return null;
  if (!msg.type || !msg.from || !msg.sig) return null;
  const machineId = msg.from.split('/').pop();
  const sig = msg.sig;
  const { sig: _, ...withoutSig } = msg;
  const canonical = JSON.stringify(withoutSig);
  if (!verify(Buffer.from(canonical, 'utf8'), sig, machineId)) {
    log(`✗ sig verify failed: from=${msg.from} type=${msg.type}`, 'warn');
    return null;
  }
  return msg;
}

// ─── Suppression window ─────────────────────────────────────────────────────
// After we pull due to a remote PULSE, suppress our own broadcast for SUPPRESSION_MS
// so we don't re-PULSE the same commit back at the sender.
let suppressUntil = 0;
function inSuppressionWindow() { return Date.now() < suppressUntil; }
function setSuppression() { suppressUntil = Date.now() + SUPPRESSION_MS; }

// ─── Pull / push ────────────────────────────────────────────────────────────
function runAutosync(reason, callback) {
  // vault-autosync.sh ALREADY wraps its own git ops in vault-write-tx.
  // DO NOT wrap it again — nested same-lock = self-deadlock at the 60s timeout.
  // Pass reason via env so the inner lock's reason reflects who called.
  const proc = spawn(VAULT_AUTOSYNC, [], {
    stdio: 'pipe',
    env: { ...process.env, MAE_PULSE_REASON: `mae-pulse@${HOSTNAME}:${reason}` },
  });
  let out = '';
  proc.stdout.on('data', d => { out += d.toString(); });
  proc.stderr.on('data', d => { out += d.toString(); });
  proc.on('exit', (code) => {
    if (callback) callback(code, out.trim());
  });
}

// Discover git binary once at startup — launchd's PATH may differ from interactive shell
function findGit() {
  const candidates = [
    '/opt/homebrew/bin/git',
    '/usr/local/bin/git',
    '/usr/bin/git',
    process.env.HOME + '/.bin/git',
  ];
  for (const p of candidates) {
    try { if (fs.statSync(p).isFile()) return p; } catch {}
  }
  try { return execSync('command -v git', {encoding:'utf8', shell:'/bin/bash'}).trim() || 'git'; }
  catch { return 'git'; }
}
const GIT = findGit();

function currentCommit() {
  try {
    return execFileSync(GIT, ['-C', VAULT, 'rev-parse', '--short=12', 'HEAD'], {encoding:'utf8'}).trim();
  } catch (e) {
    log(`currentCommit failed: ${e.message}`, 'warn');
    return 'unknown';
  }
}

// ─── Outbound: watch vault → debounce → autosync → broadcast PULSE ──────────
// inflight: skip new autosyncs while one is running (the daemon's own git ops
// trigger fs.watch — without this we'd queue redundant autosyncs that
// lock-timeout while the first one completes).
let debounceTimer = null;
let autosyncInflight = false;
function onLocalChange(filePath) {
  if (IGNORE_PATHS.some(re => re.test(filePath))) return;
  if (inSuppressionWindow()) return;
  if (autosyncInflight) return;     // already running; skip
  if (debounceTimer) clearTimeout(debounceTimer);
  debounceTimer = setTimeout(() => {
    debounceTimer = null;
    if (autosyncInflight) return;
    autosyncInflight = true;
    log(`change detected → autosync`);
    runAutosync('outbound', (code, out) => {
      autosyncInflight = false;
      if (code !== 0) { log(`autosync failed rc=${code}: ${out}`, 'warn'); return; }
      const commit = currentCommit();
      setSuppression();             // suppress for 5s so peers' incoming PULSE→our pull
                                    // doesn't echo back, AND our own git-write fs.watch
                                    // chatter doesn't re-trigger
      broadcastPulse(commit);
    });
  }, DEBOUNCE_MS);
}

function broadcastPulse(commit) {
  const env = envelope('pulse', { commit, host: HOSTNAME });
  sendToAllPeers(Buffer.from(env, 'utf8'), `pulse commit=${commit}`);
}

function broadcastPresence() {
  const env = envelope('presence', { host: HOSTNAME, commit: currentCommit() });
  sendToAllPeers(Buffer.from(env, 'utf8'), `presence`);
}

const sock = dgram.createSocket('udp4');
const peers = loadPeers();
function sendToAllPeers(buf, label) {
  let sent = 0;
  for (const [name, p] of Object.entries(peers)) {
    if (name === HOSTNAME) continue;
    sock.send(buf, p.port || PORT, p.ip, (err) => {
      if (err) log(`✗ send to ${name} failed: ${err.message}`, 'warn');
    });
    sent++;
  }
  log(`→ ${label} to ${sent} peer(s)`);
}

// ─── Inbound: receive UDP → verify → dispatch ───────────────────────────────
sock.on('message', (buf, rinfo) => {
  const msg = parseAndVerify(buf);
  if (!msg) return;
  if (msg.from === FROM) return;            // self-loop ignore
  log(`← ${msg.type} from ${msg.from} (${rinfo.address}:${rinfo.port})`);
  switch (msg.type) {
    case 'pulse':
      handlePulse(msg);
      break;
    case 'presence':
      // could update presence registry here; v1 just logs
      break;
    case 'chat':
    case 'key-exchange':
    case 'repo-pulse':
      // protocol-reserved for future impl
      log(`type=${msg.type} reserved; no impl yet`);
      break;
    default:
      log(`unknown type=${msg.type} from=${msg.from}`, 'warn');
  }
});

function handlePulse(msg) {
  if (inSuppressionWindow()) {
    log(`pulse from ${msg.from} — in suppression window, skipping pull`);
    return;
  }
  log(`pulse from ${msg.from} commit=${msg.payload.commit} → pull`);
  setSuppression();   // suppress our own re-broadcast while we pull
  runAutosync('inbound-pull', (code, out) => {
    if (code !== 0) log(`pull failed rc=${code}: ${out}`, 'warn');
    else log(`pull complete (commit=${currentCommit()})`);
  });
}

sock.on('error', (err) => {
  log(`socket error: ${err.message}`, 'error');
});

// ─── Watcher: fs.watch (stdlib, recursive) ──────────────────────────────────
function startWatcher() {
  try {
    fs.watch(VAULT, { recursive: true }, (eventType, filename) => {
      if (!filename) return;
      const fp = path.join(VAULT, filename);
      onLocalChange(fp);
    });
    log(`watching ${VAULT}`);
  } catch (e) {
    log(`watcher failed: ${e.message}`, 'error');
    process.exit(2);
  }
}

// ─── Main ───────────────────────────────────────────────────────────────────
async function main() {
  log(`mae-pulse-daemon starting (host=${HOSTNAME}, from=${FROM})`);
  loadSecretKey();
  // peers already loaded above (top-level for closure access)
  sock.bind(PORT, () => {
    log(`UDP socket bound :${PORT}`);
  });
  startWatcher();
  setInterval(broadcastPresence, PRESENCE_INTERVAL_MS);
  log(`daemon ready (PROTOCOL_VERSION=${PROTOCOL_VERSION})`);
}

main().catch(e => {
  log(`fatal: ${e.message}`, 'error');
  process.exit(1);
});

process.on('SIGTERM', () => { log('SIGTERM — shutting down'); sock.close(); process.exit(0); });
process.on('SIGINT',  () => { log('SIGINT — shutting down');  sock.close(); process.exit(0); });
