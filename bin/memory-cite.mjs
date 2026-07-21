#!/usr/bin/env node
// memory-cite — bridge Tier 1 (BM25 memory citations) to Tier 2 (raw JSONL transcripts)
// without indexing the firehose. Resolves session_id → JSONL path, fetches context around
// a specific line, timestamp, or grep match.
//
// Usage:
//   memory-cite <session_id>                  # session metadata + first 10 user prompts
//   memory-cite <session_id>#L<n>             # ±20 lines around line n
//   memory-cite <session_id>#L<n> --context 50
//   memory-cite --session <id> --grep <pat>   # first 5 grep hits with context
//   memory-cite --session <id> --at <iso-ts>  # nearest message to timestamp
//   memory-cite --session <id> --tail 20      # last 20 turns
//
// The companion CLI to memory-search. Memory points at WHERE; this fetches WHAT.
// Day 14 of mae-ADR-001 (2026-05-16).

import { createReadStream, existsSync, readdirSync, statSync } from 'node:fs';
import { createInterface } from 'node:readline';
import { join } from 'node:path';

const PROJECTS_ROOT = process.env.CLAUDE_PROJECTS_ROOT || join(process.env.HOME, '.claude', 'projects');
const ARGS = process.argv.slice(2);

function usage() {
  console.error(`Usage:
  memory-cite <session_id>[#L<n>] [--context N]
  memory-cite --session <id> --grep <pattern> [--first N]
  memory-cite --session <id> --at <iso-timestamp> [--context N]
  memory-cite --session <id> --tail N
  memory-cite --session <id> --info`);
  process.exit(2);
}

function parseArgs(argv) {
  const opts = { context: 20, first: 5 };
  const positional = [];
  for (let i = 0; i < argv.length; i++) {
    const a = argv[i];
    if (a === '--session') opts.session = argv[++i];
    else if (a === '--grep') opts.grep = argv[++i];
    else if (a === '--at') opts.at = argv[++i];
    else if (a === '--tail') opts.tail = parseInt(argv[++i], 10);
    else if (a === '--context') opts.context = parseInt(argv[++i], 10);
    else if (a === '--first') opts.first = parseInt(argv[++i], 10);
    else if (a === '--info') opts.info = true;
    else if (a === '--json') opts.json = true;
    else if (a.startsWith('--')) { console.error(`unknown flag: ${a}`); usage(); }
    else positional.push(a);
  }
  if (positional[0] && !opts.session) {
    const [sid, anchor] = positional[0].split('#');
    opts.session = sid;
    if (anchor && anchor.startsWith('L')) opts.line = parseInt(anchor.slice(1), 10);
  }
  if (!opts.session) usage();
  return opts;
}

function findTranscript(sessionId) {
  // Resolves BOTH a full uuid and a short prefix (e.g. `86eb7a09`).
  //
  // Why prefixes matter: every surface a human or agent reads a session id FROM —
  // the hook-debug log, the SessionStart banner, `substrate send` output, the
  // tmux-session-map — prints the 8-char prefix. Exact-match-only meant the id you
  // can actually SEE returned "no transcript found", which reads as "no history
  // exists" rather than "you passed a prefix". That false negative cost a full
  // recovery cycle on 2026-07-20 after LEAD session 86eb7a09 died: the transcript
  // was sitting right there, 198.9 MB of it, and the tool said it wasn't.
  if (!existsSync(PROJECTS_ROOT)) return null;
  const projects = readdirSync(PROJECTS_ROOT);

  // Fast path: exact id.
  for (const proj of projects) {
    const candidate = join(PROJECTS_ROOT, proj, `${sessionId}.jsonl`);
    if (existsSync(candidate)) return { project: proj, path: candidate, sessionId };
  }

  // Prefix resolution. Collect ALL matches before deciding — never silently take
  // the first, or a prefix shared by two sessions would cite the wrong transcript.
  const matches = [];
  for (const proj of projects) {
    const dir = join(PROJECTS_ROOT, proj);
    let entries;
    try { entries = readdirSync(dir); } catch { continue; }
    for (const f of entries) {
      if (!f.endsWith('.jsonl')) continue;
      const id = f.slice(0, -6);
      if (id.startsWith(sessionId)) {
        matches.push({ project: proj, path: join(dir, f), sessionId: id });
      }
    }
  }

  if (matches.length === 1) {
    const m = matches[0];
    // Announce the resolution on stderr: the caller asked for a prefix and is
    // getting a specific full uuid back. Silent expansion would be its own trap.
    console.error(`# resolved prefix ${sessionId} → ${m.sessionId}  (${m.project})`);
    return m;
  }

  if (matches.length > 1) {
    console.error(`error: prefix ${sessionId} is ambiguous — ${matches.length} sessions match:`);
    for (const m of matches) console.error(`  ${m.sessionId}  (${m.project})  ${fileSize(m.path)}`);
    console.error(`Pass more characters, or the full uuid.`);
    process.exit(7);
  }

  return null;
}

function streamLines(path) {
  // Async iterator yielding {n, raw, parsed} — 1-indexed. Streams to avoid V8 string limit.
  const rl = createInterface({ input: createReadStream(path, { encoding: 'utf8' }), crlfDelay: Infinity });
  let n = 0;
  return (async function* () {
    for await (const ln of rl) {
      n++;
      if (!ln.trim()) continue;
      let parsed = null;
      try { parsed = JSON.parse(ln); } catch {}
      yield { n, raw: ln, parsed };
    }
  })();
}

async function collectLines(path, predicate, maxKeep = null) {
  // Streams the file, returns array of matching {n, raw, parsed}.
  const out = [];
  for await (const e of streamLines(path)) {
    if (predicate(e)) {
      out.push(e);
      if (maxKeep && out.length >= maxKeep) break;
    }
  }
  return out;
}

async function ringBufferAround(path, targetLine, ctx) {
  // Stream until we get to targetLine+ctx, keep a rolling window of size 2ctx+1 centered on target
  const buf = [];
  let total = 0;
  for await (const e of streamLines(path)) {
    if (e.n < targetLine - ctx) { total++; continue; }
    if (e.n > targetLine + ctx) break;
    buf.push(e);
    total++;
  }
  // total is approximate (we don't count blank-trimmed lines)
  return { band: buf, totalSeen: total };
}

async function countLines(path) {
  let n = 0;
  for await (const _ of streamLines(path)) n++;
  return n;
}

function summarize(entry) {
  if (!entry.parsed) return { role: 'malformed', ts: '', preview: entry.raw.slice(0, 200) };
  const p = entry.parsed;
  const msg = p.message || {};
  const role = msg.role || p.type || 'system';
  const ts = p.timestamp || msg.timestamp || '';
  let text = '';
  const c = msg.content;
  if (typeof c === 'string') text = c;
  else if (Array.isArray(c)) {
    for (const part of c) {
      if (typeof part === 'string') text += part;
      else if (part?.type === 'text') text += part.text || '';
      else if (part?.type === 'tool_use') text += `[tool_use: ${part.name}]`;
      else if (part?.type === 'tool_result') text += `[tool_result]`;
    }
  }
  text = text.replace(/\s+/g, ' ').trim();
  return { role, ts, preview: text.slice(0, 400) };
}

function fmt(entry, opts) {
  const s = summarize(entry);
  if (opts.json) return JSON.stringify({ line: entry.n, ...s, full: opts.full ? entry.parsed : undefined });
  const tsShort = s.ts ? s.ts.slice(0, 19) + 'Z' : '?';
  return `L${String(entry.n).padStart(6)}  ${tsShort}  ${s.role.padEnd(9)}  ${s.preview}`;
}

function bandAround(lines, target, ctx) {
  const lo = Math.max(0, target - ctx - 1);
  const hi = Math.min(lines.length, target + ctx);
  return lines.slice(lo, hi);
}

function fileSize(path) {
  try { return (statSync(path).size / 1024 / 1024).toFixed(1) + ' MB'; } catch { return '?'; }
}

async function main() {
  const opts = parseArgs(ARGS);
  const found = findTranscript(opts.session);
  if (!found) {
    console.error(`error: no transcript found for session ${opts.session} under ${PROJECTS_ROOT}`);
    console.error(`(tried exact id AND prefix match — this session genuinely has no JSONL here)`);
    process.exit(3);
  }
  // Use the RESOLVED full uuid everywhere downstream, so printed headers are
  // copy-pasteable into `claude --resume` / `substrate send` without re-lookup.
  opts.session = found.sessionId;

  if (opts.info) {
    // Stream once to get first ts, last ts, count
    let first = null, last = null, count = 0;
    for await (const e of streamLines(found.path)) {
      count++;
      const s = summarize(e);
      if (!first && s.ts) first = s;
      if (s.ts) last = s;
    }
    console.log(JSON.stringify({
      session: opts.session, project: found.project, path: found.path,
      size: fileSize(found.path), lines: count,
      first_ts: first?.ts || null, last_ts: last?.ts || null,
    }, null, 2));
    return;
  }

  if (opts.line) {
    const { band, totalSeen } = await ringBufferAround(found.path, opts.line, opts.context);
    if (!band.length) { console.error(`error: line ${opts.line} not found`); process.exit(4); }
    console.log(`# memory-cite ${opts.session}#L${opts.line}  (project=${found.project}, size=${fileSize(found.path)})`);
    for (const e of band) console.log((e.n === opts.line ? '>>' : '  ') + ' ' + fmt(e, opts));
    return;
  }

  if (opts.grep) {
    const re = new RegExp(opts.grep, 'i');
    const hits = await collectLines(found.path, e => re.test(e.raw), opts.first);
    console.log(`# memory-cite --session ${opts.session} --grep ${JSON.stringify(opts.grep)}  (${hits.length} hit(s) of first ${opts.first})`);
    for (const e of hits) console.log(fmt(e, opts));
    return;
  }

  if (opts.at) {
    const tgt = Date.parse(opts.at);
    if (isNaN(tgt)) { console.error(`error: --at must be ISO timestamp`); process.exit(5); }
    let best = null, bestDelta = Infinity;
    for await (const e of streamLines(found.path)) {
      const s = summarize(e);
      if (!s.ts) continue;
      const d = Math.abs(Date.parse(s.ts) - tgt);
      if (d < bestDelta) { best = e; bestDelta = d; }
    }
    if (!best) { console.error(`error: no timestamped messages found`); process.exit(6); }
    const { band } = await ringBufferAround(found.path, best.n, opts.context);
    console.log(`# memory-cite --session ${opts.session} --at ${opts.at}  (nearest L${best.n}, Δ=${Math.round(bestDelta/1000)}s)`);
    for (const e of band) console.log((e.n === best.n ? '>>' : '  ') + ' ' + fmt(e, opts));
    return;
  }

  if (opts.tail) {
    // Stream all, keep last N in ring buffer
    const ring = [];
    for await (const e of streamLines(found.path)) {
      ring.push(e);
      if (ring.length > opts.tail) ring.shift();
    }
    console.log(`# memory-cite --session ${opts.session} --tail ${opts.tail}  (project=${found.project})`);
    for (const e of ring) console.log(fmt(e, opts));
    return;
  }

  // Default: first 10 user turns
  const userPrompts = await collectLines(found.path, e => summarize(e).role === 'user', 10);
  console.log(`# memory-cite ${opts.session}  (project=${found.project}, size=${fileSize(found.path)})`);
  console.log(`# first 10 user turns:`);
  for (const e of userPrompts) console.log(fmt(e, opts));
}

main().catch(e => { console.error('fatal:', e.message); process.exit(1); });
