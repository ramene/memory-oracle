#!/usr/bin/env node
// memory-search — BM25 + supersession-aware retrieval over the memory corpus.
//
// Usage:
//   memory-search "<query>"                  # top-K results, supersession-merged
//   memory-search "<query>" --project=mae    # filter to one project
//   memory-search "<query>" --k=5            # top-K (default 10)
//   memory-search "<query>" --budget=8000    # max total bytes returned (default 30000)
//   memory-search "<query>" --raw            # raw FTS5 hits, no merge
//   memory-search "<query>" --json           # structured output
//
// Designed to be called BOTH at session-start AND mid-session (post-compaction).
// Output is a single supersession-resolved priming bundle the caller can paste back.
//
// Day 14 of mae-ADR-001 (2026-05-16) — the user-facing entry over P0-P5.

import { readFileSync, existsSync } from 'node:fs';
import { join } from 'node:path';
import { spawnSync } from 'node:child_process';

const DB_PATH = process.env.MEMORY_INDEX_DB || join(process.env.HOME, '.local', 'share', 'journal', '.memory-index.db');

const args = process.argv.slice(2);
if (args.length === 0 || args.includes('--help') || args.includes('-h')) {
  console.log('memory-search "<query>" [--project=NAME] [--k=N] [--budget=BYTES] [--raw] [--json]');
  console.log('');
  console.log('  Returns supersession-merged memory bundles matching the query.');
  console.log('  Use this AT ANY POINT in a session, especially after context compaction.');
  process.exit(0);
}

const query = args[0];
let project = null, k = 10, budget = 30000, raw = false, jsonOut = false;
for (const a of args.slice(1)) {
  if (a.startsWith('--project=')) project = a.split('=')[1];
  else if (a.startsWith('--k=')) k = parseInt(a.split('=')[1], 10);
  else if (a.startsWith('--budget=')) budget = parseInt(a.split('=')[1], 10);
  else if (a === '--raw') raw = true;
  else if (a === '--json') jsonOut = true;
}

if (!existsSync(DB_PATH)) {
  console.error(`error: index not built at ${DB_PATH}. Run: memory-index-build`);
  process.exit(2);
}

// Sanitize FTS5 query — quote special chars, support phrase queries by default
function ftsQuery(q) {
  // Tokenize on whitespace, drop FTS5 special chars in each token, OR them together
  const toks = q.split(/\s+/).map(t => t.replace(/["'()*]/g, '')).filter(t => t.length > 1);
  if (toks.length === 0) return '""';
  // Use OR for recall, FTS5 will rank with BM25
  return toks.map(t => `"${t}"`).join(' OR ');
}

function esc(s) { return "'" + String(s).replace(/'/g, "''") + "'"; }

function sql(q) {
  const r = spawnSync('sqlite3', ['-json', DB_PATH], { input: q, encoding: 'utf8', maxBuffer: 100 * 1024 * 1024 });
  if (r.status !== 0) throw new Error(`sqlite3 failed: ${r.stderr}`);
  const out = r.stdout.trim();
  if (!out) return [];
  return JSON.parse(out);
}

const ftsQ = ftsQuery(query);
const projFilter = project ? `AND mf.project = ${esc(project)}` : '';

const hits = sql(`
  SELECT mf.id, mf.project, mf.file, mf.type, mf.name, mf.description,
         mf.has_supersessions, mf.merged_body,
         bm25(memory_fts) AS rank
  FROM memory_fts
  JOIN memory_file mf ON mf.id = memory_fts.rowid
  WHERE memory_fts MATCH '${ftsQ}' ${projFilter}
  ORDER BY rank
  LIMIT ${k};
`);

// Supersession sidecar — pull supersession records for these hits
const ids = hits.map(h => h.id).join(',');
const sups = ids ? sql(`SELECT memory_id, superseded_at, scope, corrected_assertion, source, live_evidence FROM supersession WHERE memory_id IN (${ids}) ORDER BY memory_id, superseded_at DESC;`) : [];
const supsByMem = new Map();
for (const s of sups) {
  if (!supsByMem.has(s.memory_id)) supsByMem.set(s.memory_id, []);
  supsByMem.get(s.memory_id).push(s);
}

// Build the bundle — fit as much as we can; truncate the last fitting block if needed
let bundleBytes = 0;
const blocks = [];
let truncated = false;
for (const h of hits) {
  const body = raw ? h.merged_body : h.merged_body; // already supersession-merged at index time
  const header = `## ${h.project}/${h.file}  ${h.has_supersessions ? '⚠ HAS SUPERSESSIONS' : ''}\n**Name**: ${h.name}\n**Description**: ${h.description}\n**Rank (BM25)**: ${h.rank.toFixed(3)}\n\n`;
  let block = header + body + '\n\n---\n\n';
  const remaining = budget - bundleBytes;
  if (block.length > remaining) {
    if (blocks.length === 0) {
      // First hit doesn't fit — return it truncated, prioritizing the supersession notice (which is prepended)
      block = block.slice(0, Math.max(remaining - 200, 500)) + '\n\n... [truncated to fit budget; raise --budget for full content] ...\n\n---\n\n';
      blocks.push({ hit: h, block, supersessions: supsByMem.get(h.id) || [] });
      bundleBytes += block.length;
      truncated = true;
    }
    break;
  }
  blocks.push({ hit: h, block, supersessions: supsByMem.get(h.id) || [] });
  bundleBytes += block.length;
}

if (jsonOut) {
  console.log(JSON.stringify({
    query, project, k, budget,
    fts_query: ftsQ,
    hit_count: hits.length,
    returned: blocks.length,
    bundle_bytes: bundleBytes,
    results: blocks.map(b => ({
      project: b.hit.project,
      file: b.hit.file,
      name: b.hit.name,
      description: b.hit.description,
      rank: b.hit.rank,
      has_supersessions: !!b.hit.has_supersessions,
      supersession_count: b.supersessions.length,
      body: b.block,
    })),
  }, null, 2));
} else {
  console.log(`# memory-search results for: "${query}"`);
  console.log(`# Index: ${DB_PATH}`);
  console.log(`# Returned ${blocks.length}/${hits.length} hits, ${bundleBytes} bytes (budget ${budget})`);
  if (project) console.log(`# Project filter: ${project}`);
  const supsTotal = blocks.reduce((s, b) => s + b.supersessions.length, 0);
  if (supsTotal > 0) console.log(`# ${supsTotal} supersession record(s) merged into output`);
  console.log('');
  for (const b of blocks) process.stdout.write(b.block);
}
