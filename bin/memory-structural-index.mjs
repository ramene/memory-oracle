#!/usr/bin/env node
// memory-structural-index — backfill the structural-index tables in .memory-index.db.
//
// Scans every memory file's body for:
//   - File paths (relative or absolute) → populates surface_map (path -> memory_id)
//   - Authority hints ("source of truth", "authoritative", "controlling source",
//     "DO NOT", "never", "always") → populates authority_map
//
// Runs idempotently. Re-runs on schedule (currently manual; can be hooked to fs-watcher).
//
// Day 6-7 of mae-ADR-001 (2026-05-16).

import { readFileSync, existsSync } from 'node:fs';
import { join } from 'node:path';
import { spawnSync } from 'node:child_process';

const DB_PATH = process.env.MEMORY_INDEX_DB || join(process.env.HOME, '.local', 'share', 'journal', '.memory-index.db');
const args = process.argv.slice(2);

if (!existsSync(DB_PATH)) { console.error(`error: no index at ${DB_PATH}. Run memory-index-build first.`); process.exit(2); }

function sql(q, json=false) {
  const argv = json ? ['-json', DB_PATH] : [DB_PATH];
  const r = spawnSync('sqlite3', argv, { input: q, encoding: 'utf8', maxBuffer: 100*1024*1024 });
  if (r.status !== 0) throw new Error(`sqlite3 failed: ${r.stderr}\nquery: ${q.slice(0,200)}`);
  return json ? (r.stdout.trim() ? JSON.parse(r.stdout) : []) : r.stdout;
}

function esc(s) { return s === null || s === undefined ? 'NULL' : "'" + String(s).replace(/'/g, "''") + "'"; }

function initSchema() {
  sql(`
    CREATE TABLE IF NOT EXISTS surface_map (
      memory_id INTEGER NOT NULL REFERENCES memory_file(id) ON DELETE CASCADE,
      surface_kind TEXT NOT NULL,
      surface_value TEXT NOT NULL,
      occurrences INTEGER DEFAULT 1,
      PRIMARY KEY (memory_id, surface_kind, surface_value)
    );
    CREATE INDEX IF NOT EXISTS surface_value_idx ON surface_map(surface_value, surface_kind);
    CREATE TABLE IF NOT EXISTS authority_map (
      memory_id INTEGER NOT NULL REFERENCES memory_file(id) ON DELETE CASCADE,
      query_class TEXT NOT NULL,
      controlling_source TEXT NOT NULL,
      confidence REAL DEFAULT 1.0,
      PRIMARY KEY (memory_id, query_class, controlling_source)
    );
    CREATE INDEX IF NOT EXISTS authority_class_idx ON authority_map(query_class);
  `);
}

// Patterns
const PATH_RE = /(?:[\/\w.-]+\/)+[\w.-]+\.[a-zA-Z0-9]{1,5}|packages\/[\w-]+\/[\w./-]+|services\/[\w-]+\/[\w./-]+|apps\/[\w-]+\/[\w./-]+|scripts\/[\w./-]+|data\/\.[\w./-]+/g;
const ENDPOINT_RE = /(?:\/api\/[\w/-]+|https?:\/\/[\w.-]+\.[a-z]{2,}[\w/-]*)/gi;
const ENV_RE = /\b[A-Z][A-Z0-9_]{4,}_[A-Z0-9_]+\b/g; // env var names like MAE_OPENAI_PROXY_SECRET
const COMMAND_RE = /\b(pm2|gcloud|pulumi|kubectl|docker|psql|gh|git|pnpm|node|npm|sqlite3)\s+[\w:-]+/gi;

// Authority hints — when paired with a target token, the file claims authority for that target
const AUTHORITY_HINT_RE = /\b(?:source of truth|authoritative|controlling|do not|don't|never|always|MUST|must not|forbid|forbidden|only|never use)\b/gi;

function scanFile(rec) {
  const body = (rec.body || '') + '\n' + (rec.name || '') + '\n' + (rec.description || '');
  const surfaces = new Map(); // kind|value -> count
  function bump(kind, value) {
    if (!value || value.length < 3 || value.length > 200) return;
    const k = kind + '|' + value;
    surfaces.set(k, (surfaces.get(k) || 0) + 1);
  }
  for (const m of body.matchAll(PATH_RE))    bump('path', m[0]);
  for (const m of body.matchAll(ENDPOINT_RE)) bump('endpoint', m[0]);
  for (const m of body.matchAll(ENV_RE))     bump('env', m[0]);
  for (const m of body.matchAll(COMMAND_RE)) bump('command', m[0].toLowerCase().trim().replace(/\s+/g, ' '));

  // Authority detection: if the file uses an authority hint AND mentions a specific surface,
  // record the file as the controlling source for queries about that surface.
  const hasAuthority = AUTHORITY_HINT_RE.test(body);
  AUTHORITY_HINT_RE.lastIndex = 0;
  const authorities = new Map();
  if (hasAuthority) {
    // For each unique surface mentioned in this file, mark file as authority for it
    for (const [k] of surfaces.entries()) {
      const [kind, value] = k.split('|');
      // Heuristic: confidence weighted by occurrence count
      const occ = surfaces.get(k) || 1;
      const conf = Math.min(1.0, 0.3 + 0.2 * occ);
      const queryClass = `${kind}:${value.slice(0, 80)}`;
      authorities.set(queryClass, conf);
    }
  }
  return { surfaces, authorities };
}

async function backfill() {
  initSchema();
  const files = sql(`SELECT id, project, file, name, description, body FROM memory_file;`, true);
  let surfaces = 0, auths = 0;
  // Clear existing entries (idempotent rebuild)
  sql(`DELETE FROM surface_map; DELETE FROM authority_map;`);
  for (const rec of files) {
    const { surfaces: surf, authorities: auth } = scanFile(rec);
    for (const [k, count] of surf.entries()) {
      const [kind, value] = k.split('|');
      sql(`INSERT OR REPLACE INTO surface_map (memory_id, surface_kind, surface_value, occurrences) VALUES (${rec.id}, ${esc(kind)}, ${esc(value)}, ${count});`);
      surfaces++;
    }
    for (const [qc, conf] of auth.entries()) {
      sql(`INSERT OR REPLACE INTO authority_map (memory_id, query_class, controlling_source, confidence) VALUES (${rec.id}, ${esc(qc)}, ${esc(rec.project + '/' + rec.file)}, ${conf});`);
      auths++;
    }
  }
  sql(`INSERT OR REPLACE INTO index_meta (key, value) VALUES ('last_structural_build', '${new Date().toISOString()}'), ('structural_surfaces', '${surfaces}'), ('structural_authorities', '${auths}');`);
  console.log(`[struct] ${files.length} files: ${surfaces} surface records, ${auths} authority records`);
}

async function querySurface(value, kind=null) {
  const where = kind ? `surface_value=${esc(value)} AND surface_kind=${esc(kind)}` : `surface_value=${esc(value)}`;
  const rows = sql(`SELECT mf.project, mf.file, mf.name, mf.description, sm.surface_kind, sm.occurrences FROM surface_map sm JOIN memory_file mf ON mf.id=sm.memory_id WHERE ${where} ORDER BY sm.occurrences DESC, mf.mtime DESC LIMIT 20;`, true);
  console.log(JSON.stringify(rows, null, 2));
}

async function main() {
  if (args[0] === 'query') {
    await querySurface(args[1], args[2] || null);
  } else if (args[0] === 'stats') {
    const out = sql(`SELECT (SELECT COUNT(*) FROM surface_map) AS surfaces, (SELECT COUNT(DISTINCT surface_value) FROM surface_map) AS unique_surfaces, (SELECT COUNT(*) FROM authority_map) AS authorities, (SELECT value FROM index_meta WHERE key='last_structural_build') AS last_build;`, true);
    console.log(JSON.stringify(out[0], null, 2));
  } else {
    await backfill();
  }
}

main().catch(e => { console.error('[struct] fatal:', e); process.exit(1); });
