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
  return { name: me, head, originHead, daemonPid: pid, lastSentPresence: sent, lastSentPulse: sentPulse };
}

// Query a peer via ssh — daemon log + git head
function peerState(peerName, _) {
  if (peerName === localHostMesh()) return null;
  try {
    // Use peer's `git` from PATH — sequoia/tunafish git is /usr/bin/git, noodles is /opt/homebrew/bin/git
    const cmd = [
      'V=$HOME/.remote/@vaults/.build/obsidian-vault',
      'H=$(git -C $V rev-parse --short=8 HEAD 2>/dev/null)',
      'git -C $V fetch -q 2>/dev/null',
      'O=$(git -C $V rev-parse --short=8 origin/main 2>/dev/null)',
      'P=$(launchctl list 2>/dev/null | awk "/mae.pulse-daemon/{print \\$1}")',
      'S=$(tail -80 $HOME/.claude-tmp/mae-pulse-daemon.log 2>/dev/null | grep "presence to" | tail -1 | awk "{print \\$1}")',
      'U=$(tail -80 $HOME/.claude-tmp/mae-pulse-daemon.log 2>/dev/null | grep "pulse commit" | tail -1 | awk "{print \\$1}")',
      'echo "$H|$O|$P|$S|$U"',
    ].join(';');
    const out = execSync(`ssh -o ConnectTimeout=3 -o BatchMode=yes ${peerName} '${cmd}' 2>/dev/null`,
                        {encoding:'utf8'}).trim();
    const [head, originHead, pid, sent, pulse] = out.split('|');
    return { name: peerName, head: head || '?', originHead: originHead || '?',
             daemonPid: pid || '-', lastSentPresence: sent || null, lastSentPulse: pulse || null,
             unreachable: !head };
  } catch {
    return { name: peerName, head: '?', originHead: '?', daemonPid: '?', lastSentPresence: null, lastSentPulse: null, unreachable: true };
  }
}

function colorStatus(s) {
  if (s.unreachable) return RED + 'UNREACHABLE' + RESET;
  if (s.daemonPid === '-' || s.daemonPid === '?') return RED + 'DAEMON DOWN' + RESET;
  if (s.head === s.maxHead) return GREEN + 'SYNCED' + RESET;
  // Peer's HEAD is older than max — they need to pull
  return YELLOW + 'BEHIND' + RESET;
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
  const local = localState();
  const states = [local];
  for (const p of peers) {
    if (p.name !== local.name) {
      const s = peerState(p.name);
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
    // Presence fires every 60s — fresh = ALIVE. Pulse fires only on vault changes — silence is NORMAL.
    const presAge = s.lastSentPresence ? (Date.now() - new Date(s.lastSentPresence).getTime()) / 1000 : Infinity;
    const presStr = !s.lastSentPresence ? '-' : presAge < 120 ? GREEN + age(s.lastSentPresence) + RESET : YELLOW + age(s.lastSentPresence) + RESET;
    const pulseStr = !s.lastSentPulse ? DIM + 'idle' + RESET : age(s.lastSentPulse);
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
  out += DIM + `  ALIVE = presence beacon (every 60s, freshness = daemon up).  LAST CHANGE = pulse broadcast (on vault edits only; "idle" = no edits yet, NOT down).` + RESET + '\n';
  if (WATCH) out += DIM + `\n  (refreshes every ${INTERVAL/1000}s · Ctrl-C to exit)` + RESET + '\n';
  process.stdout.write(out);
}

if (WATCH) {
  render();
  setInterval(render, INTERVAL);
} else {
  render();
}
