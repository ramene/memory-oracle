#!/usr/bin/env node
// mae-pulse-status — live cluster-sync visualization for the substrate mesh.
//
// Polls each peer every 2s for:
//   - vault HEAD (git rev-parse)
//   - daemon liveness (launchctl + last log entry timestamp)
//   - last-presence received (from local daemon log)
//   - sync-lag vs the most-advanced HEAD across the cluster
//
// Usage:
//   mae-pulse-status                  one-shot snapshot
//   mae-pulse-status --watch          live table refreshing every 2s
//   mae-pulse-status --watch --interval 5  custom refresh rate

import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { execFileSync, execSync } from 'node:child_process';

const PEERS_FILE = path.join(os.homedir(), '.local/share/mae-substrate/pulse/peers.json');
const DAEMON_LOG = path.join(os.homedir(), '.claude-tmp/mae-pulse-daemon.log');
const VAULT = path.join(os.homedir(), '.remote/@vaults/.build/obsidian-vault');

const args = process.argv.slice(2);
const WATCH = args.includes('--watch');
const INTERVAL = parseInt(args[args.indexOf('--interval')+1] || '2', 10) * 1000;

// ANSI
const RESET = '\x1b[0m';
const BOLD = '\x1b[1m';
const GREEN = '\x1b[32m';
const YELLOW = '\x1b[33m';
const RED = '\x1b[31m';
const DIM = '\x1b[2m';
const CLEAR = '\x1b[2J\x1b[H';

function findGit() {
  for (const p of ['/opt/homebrew/bin/git', '/usr/local/bin/git', '/usr/bin/git']) {
    try { if (fs.statSync(p).isFile()) return p; } catch {}
  }
  return 'git';
}
const GIT = findGit();

function loadPeers() {
  const data = JSON.parse(fs.readFileSync(PEERS_FILE, 'utf8'));
  return Object.entries(data).map(([name, info]) => ({ name, ...info }));
}

function localHostMesh() {
  const p = path.join(os.homedir(), '.local/share/mae-substrate/.host-mesh');
  try { return fs.readFileSync(p, 'utf8').trim(); } catch { return os.hostname().split('.')[0]; }
}

function age(tsStr) {
  if (!tsStr) return '-';
  const sec = Math.round((Date.now() - new Date(tsStr).getTime()) / 1000);
  if (sec < 60) return `${sec}s`;
  if (sec < 3600) return `${Math.round(sec/60)}m`;
  return `${Math.round(sec/3600)}h`;
}

function tailLog(filePath, n = 60) {
  try {
    const data = fs.readFileSync(filePath, 'utf8');
    return data.trim().split('\n').slice(-n);
  } catch { return []; }
}

// Data-plane truth: what beacons did THIS node actually RECEIVE, per peer.
// The daemon logs every inbound packet as:
//   <iso> [info] ← presence|pulse from verum:ramene/<host> (<ip>:<port>)
// Liveness derived from this is honest — it reflects packets we got, not an
// SSH probe of the peer's own outbound log (which can show a peer "alive"
// while we receive nothing from it, or "unreachable" merely because ssh is slow).
function readInbound() {
  const map = {};
  let lines = [];
  try { lines = fs.readFileSync(DAEMON_LOG, 'utf8').split('\n'); } catch { return map; }
  for (const l of lines) {
    const m = l.match(/^(\S+).*?← (presence|pulse) from verum:[^/]+\/([A-Za-z0-9_.-]+)/);
    if (!m) continue;
    const [, ts, kind, name] = m;
    (map[name] ||= {})[kind === 'presence' ? 'recvPresence' : 'recvPulse'] = ts;
  }
  return map;
}

// Pull state for local node from local log + git
function localState() {
  const me = localHostMesh();
  const lines = tailLog(DAEMON_LOG, 80);
  // last presence sent
  const lastSentPresence = lines.reverse().find(l => l.includes('→ presence'));
  const sent = lastSentPresence ? lastSentPresence.split(' ')[0] : null;
  // last pulse sent
  const lastSentPulse = lines.find(l => l.includes('→ pulse'));
  const sentPulse = lastSentPulse ? lastSentPulse.split(' ')[0] : null;
  let head = 'unknown';
  try {
    head = execFileSync(GIT, ['-C', VAULT, 'rev-parse', '--short=8', 'HEAD'], {encoding:'utf8'}).trim();
  } catch {}
  let originHead = 'unknown';
  try {
    execFileSync(GIT, ['-C', VAULT, 'fetch', '-q'], {encoding:'utf8'});
    originHead = execFileSync(GIT, ['-C', VAULT, 'rev-parse', '--short=8', 'origin/main'], {encoding:'utf8'}).trim();
  } catch {}
  // daemon up?
  let pid = '-';
  try {
    const out = execSync('launchctl list 2>/dev/null | grep mae.pulse-daemon', {encoding:'utf8'}).trim();
    pid = out.split(/\s+/)[0];
  } catch {}
  return { name: me, local: true, head, originHead, daemonPid: pid, lastSentPresence: sent, lastSentPulse: sentPulse };
}

// Enrich a peer's row with HEAD/PID via ssh, but derive LIVENESS from beacons
// we RECEIVED (inb), not from this probe. ssh failure no longer means "down" —
// a peer we're receiving beacons from is LIVE even if ssh/HEAD is unavailable.
function peerState(peerName, inb = {}) {
  if (peerName === localHostMesh()) return null;
  let head = '', originHead = '', pid = '';
  try {
    // Resolve git absolutely on the peer — non-login ssh to Apple-Silicon (noodles)
    // lacks /opt/homebrew/bin on PATH, which silently emptied HEAD before.
    const cmd = [
      'for g in /opt/homebrew/bin/git /usr/local/bin/git /usr/bin/git; do [ -x "$g" ] && GIT="$g" && break; done; GIT="${GIT:-git}"',
      'V=$HOME/.remote/@vaults/.build/obsidian-vault',
      'H=$("$GIT" -C $V rev-parse --short=8 HEAD 2>/dev/null)',
      '"$GIT" -C $V fetch -q 2>/dev/null',
      'O=$("$GIT" -C $V rev-parse --short=8 origin/main 2>/dev/null)',
      'P=$(launchctl list 2>/dev/null | awk "/mae.pulse-daemon/{print \\$1}")',
      'echo "$H|$O|$P"',
    ].join(';');
    const out = execSync(
      `ssh -o ConnectTimeout=8 -o ServerAliveInterval=2 -o ServerAliveCountMax=2 -o BatchMode=yes ${peerName} '${cmd}' 2>/dev/null`,
      {encoding:'utf8'}).trim();
    [head, originHead, pid] = out.split('|');
  } catch { /* ssh-unreachable: liveness still comes from received beacons below */ }
  return {
    name: peerName,
    head: head || '?', originHead: originHead || '?', daemonPid: pid || '-',
    sshOk: !!head,
    recvPresence: inb.recvPresence || null,
    recvPulse: inb.recvPulse || null,
  };
}

function colorStatus(s) {
  // Local node: liveness = own daemon emitting; sync = HEAD vs cluster max.
  if (s.local) {
    if (s.daemonPid === '-' || s.daemonPid === '?') return RED + 'DAEMON DOWN' + RESET;
    return s.head === s.maxHead ? GREEN + 'SYNCED' + RESET : YELLOW + 'BEHIND' + RESET;
  }
  // Peers: liveness = beacon we RECEIVED (data-plane truth), not the ssh probe.
  const beaconAge = s.recvPresence ? (Date.now() - new Date(s.recvPresence).getTime()) / 1000 : Infinity;
  if (beaconAge < 120) {
    if (!s.sshOk) return GREEN + 'LIVE' + RESET;              // receiving beacons; HEAD just not ssh-readable
    return s.head === s.maxHead ? GREEN + 'SYNCED' + RESET : YELLOW + 'BEHIND' + RESET;
  }
  // No fresh inbound beacon from this peer:
  if (s.sshOk) return RED + 'NO BEACON' + RESET;              // peer daemon up (ssh) but its UDP isn't reaching us
  return RED + 'UNREACHABLE' + RESET;                          // no beacon AND no ssh
}

function colorHead(h, maxHead) {
  if (h === maxHead) return GREEN + h + RESET;
  return YELLOW + h + RESET;
}

function pad(s, n) {
  const visible = String(s).replace(/\x1b\[[0-9;]*m/g, '');
  return s + ' '.repeat(Math.max(0, n - visible.length));
}

function render() {
  const peers = loadPeers();
  const inbound = readInbound();
  const local = localState();
  const states = [local];
  for (const p of peers) {
    if (p.name !== local.name) {
      const s = peerState(p.name, inbound[p.name] || {});
      if (s) states.push(s);
    }
  }
  // find max HEAD across the cluster
  const heads = states.map(s => s.head).filter(h => h && h !== '?' && h !== 'unknown');
  const maxHead = heads.length ? heads[0] : '-';
  for (const s of states) s.maxHead = maxHead;

  let out = '';
  if (WATCH) out += CLEAR;
  out += BOLD + `mae-pulse-status · ${new Date().toISOString()} · cluster=noodles,sequoia,tunafish` + RESET + '\n';
  out += DIM + `  daemon: UDP :38478, Ed25519 verum-class envelope, fail-safe vault-autosync cron */3` + RESET + '\n';
  out += '\n';
  // Table header
  out += BOLD + pad('  DEVICE', 14) + pad('HEAD', 16) + pad('ORIGIN', 16) + pad('PID', 10) +
                 pad('ALIVE (60s)', 14) + pad('LAST CHANGE', 14) + 'STATUS' + RESET + '\n';
  out += DIM + '  ' + '─'.repeat(95) + RESET + '\n';
  for (const s of states) {
    const head = s.head === '?' ? RED + '?' + RESET : colorHead(s.head, maxHead);
    const orig = s.originHead === '?' ? RED + '?' + RESET : colorHead(s.originHead, maxHead);
    // ALIVE = presence beacon. Self: what we SENT. Peers: what we RECEIVED (data-plane).
    // Pulse fires only on vault changes — silence ("idle") is NORMAL, not down.
    const aliveTs = s.local ? s.lastSentPresence : s.recvPresence;
    const changeTs = s.local ? s.lastSentPulse : s.recvPulse;
    const aliveAge = aliveTs ? (Date.now() - new Date(aliveTs).getTime()) / 1000 : Infinity;
    const presStr = !aliveTs ? RED + '-' + RESET : aliveAge < 120 ? GREEN + age(aliveTs) + RESET : YELLOW + age(aliveTs) + RESET;
    const pulseStr = !changeTs ? DIM + 'idle' + RESET : age(changeTs);
    out += '  ' + pad(s.name, 12) + pad(head, 14) + pad(orig, 14) + pad(s.daemonPid, 10) +
                  pad(presStr, 12) + pad(pulseStr, 14) +
                  colorStatus(s) + '\n';
  }
  out += '\n';
  if (heads.every(h => h === maxHead)) {
    out += GREEN + `  ✓ all peers converged at HEAD=${maxHead}` + RESET + '\n';
  } else {
    out += YELLOW + `  ! cluster has divergent HEADs — newest=${maxHead}` + RESET + '\n';
  }
  out += DIM + `  ALIVE = presence beacon RECEIVED from peer (self: sent), every 60s — freshness = we're hearing it.` + RESET + '\n';
  out += DIM + `  STATUS: NO BEACON = peer daemon up (ssh) but its UDP isn't reaching THIS node; UNREACHABLE = no beacon AND no ssh. LAST CHANGE = pulse received (vault edits only; "idle" = none).` + RESET + '\n';
  if (WATCH) out += DIM + `\n  (refreshes every ${INTERVAL/1000}s · Ctrl-C to exit)` + RESET + '\n';
  process.stdout.write(out);
}

if (WATCH) {
  render();
  setInterval(render, INTERVAL);
} else {
  render();
}
