#!/usr/bin/env node
// memory-index-build — build/refresh the BM25 SQLite FTS5 index over all memory files,
// merging in supersession sidecars so the index reflects supersession-resolved content.
//
// Usage:
//   memory-index-build              # full rebuild
//   memory-index-build --watch      # initial build + fs-watcher (incremental)
//   memory-index-build --stats      # show index stats
//
// Index location: $MEMORY_INDEX_DB (default ~/.local/share/journal/.memory-index.db)
// Source: $CLAUDE_PROJECTS_ROOT (default ~/.claude/projects)
//
// Schema:
//   memory_file (id INTEGER PRIMARY KEY, project TEXT, file TEXT, type TEXT,
//                name TEXT, description TEXT, body TEXT, merged_body TEXT,
//                has_supersessions INTEGER, mtime REAL, sha256 TEXT)
//   memory_fts FTS5 (name, description, body, merged_body, type, project,
//                    content='memory_file', content_rowid='id', tokenize='porter unicode61')
//   supersession (memory_id INTEGER, superseded_at TEXT, scope TEXT,
//                 corrected_assertion TEXT, source TEXT, live_evidence TEXT)
//   index_meta (key TEXT PRIMARY KEY, value TEXT)
//
// P1 of mae-ADR-001 (2026-05-16).

import { readFileSync, existsSync, readdirSync, statSync, watch, mkdirSync } from 'node:fs';
import { join, dirname, basename } from 'node:path';
import { createHash } from 'node:crypto';
import { execSync, spawnSync } from 'node:child_process';

const DB_PATH = process.env.MEMORY_INDEX_DB || join(process.env.HOME, '.local', 'share', 'journal', '.memory-index.db');
const PROJECTS_ROOT = process.env.CLAUDE_PROJECTS_ROOT || join(process.env.HOME, '.claude', 'projects');
const DIGESTS_ROOT = process.env.JOURNAL_DIGESTS_ROOT || join(process.env.HOME, '.local', 'share', 'journal', 'digests');
const MERGE_CLI = join(process.env.HOME, '.bin', 'memory-merge.mjs');

const ARGS = process.argv.slice(2);

// Ensure parent dir exists
mkdirSync(dirname(DB_PATH), { recursive: true });

// Use the `sqlite3` CLI (no native deps). Verify it's available.
function sqliteAvailable() {
  try { execSync('which sqlite3', { stdio: 'pipe' }); return true; } catch { return false; }
}

if (!sqliteAvailable()) {
  console.error('error: sqlite3 CLI not found on PATH. macOS ships it; check $PATH.');
  process.exit(2);
}

function sql(query, opts = {}) {
  // Use stdin to avoid quoting issues; `.mode json` for structured reads.
  // PRAGMA busy_timeout=5000 makes the CLI block-retry for up to 5s when the DB
  // is locked by a concurrent writer (e.g., two memory-file writes from
  // different sessions racing through the fs-watcher). Without it the CLI
  // errors immediately with "database is locked (5)" and the write is lost
  // until the next watcher tick. Empirically observed 2026-05-21: ~47% of
  // writes erroring during multi-session bursts.
  // `.timeout 5000` dot-command sets busy_timeout for this connection without
  // emitting any output (unlike PRAGMA, which prints its return value in
  // shell mode and a JSON array in -json mode). Prepended to every query so
  // both read (json mode) and write (default mode) paths get the timeout.
  // Empirically verified 2026-05-21 — switching from in-stdin PRAGMA (which
  // ran AFTER parse-time lock checks and didn't help) to .timeout (set at
  // connection open before any query parses) resolved the concurrent-write
  // failures observed during multi-session bursts.
  const args = [DB_PATH];
  if (opts.json) args.unshift('-json');
  const prefixedQuery = `.timeout 5000\n${query}`;
  const r = spawnSync('sqlite3', args, { input: prefixedQuery, encoding: 'utf8', maxBuffer: 100 * 1024 * 1024 });
  if (r.status !== 0) {
    throw new Error(`sqlite3 failed (status ${r.status}): ${r.stderr}\nquery: ${query.slice(0,200)}`);
  }
  if (opts.json) {
    const out = r.stdout.trim();
    if (!out) return [];
    return JSON.parse(out);
  }
  return r.stdout;
}

function initSchema() {
  sql(`
    PRAGMA journal_mode=WAL;
    CREATE TABLE IF NOT EXISTS memory_file (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      project TEXT NOT NULL,
      file TEXT NOT NULL,
      type TEXT,
      name TEXT,
      description TEXT,
      body TEXT,
      merged_body TEXT,
      has_supersessions INTEGER DEFAULT 0,
      mtime REAL,
      sha256 TEXT,
      UNIQUE(project, file)
    );
    CREATE VIRTUAL TABLE IF NOT EXISTS memory_fts USING fts5(
      name, description, body, merged_body, type UNINDEXED, project UNINDEXED, file UNINDEXED,
      content='memory_file', content_rowid='id', tokenize='porter unicode61'
    );
    CREATE TABLE IF NOT EXISTS supersession (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      memory_id INTEGER NOT NULL REFERENCES memory_file(id) ON DELETE CASCADE,
      superseded_at TEXT,
      scope TEXT,
      corrected_assertion TEXT,
      source TEXT,
      live_evidence TEXT,
      operator_confirmed TEXT,
      retention_policy TEXT
    );
    CREATE INDEX IF NOT EXISTS supersession_memory_idx ON supersession(memory_id);
    CREATE TABLE IF NOT EXISTS index_meta (key TEXT PRIMARY KEY, value TEXT);
  `);
}

function parseFrontmatter(text) {
  const m = text.match(/^---\n([\s\S]*?)\n---\n([\s\S]*)$/);
  if (!m) return { fm: {}, body: text };
  const fm = {};
  for (const line of m[1].split('\n')) {
    const k = line.match(/^(\w+):\s*(.*)$/);
    if (k) fm[k[1]] = k[2];
  }
  return { fm, body: m[2] };
}

function sha256(s) { return createHash('sha256').update(s).digest('hex').slice(0, 16); }

// SQL string escape — single quotes doubled
function esc(s) {
  if (s === null || s === undefined) return 'NULL';
  return "'" + String(s).replace(/'/g, "''") + "'";
}

function listMemoryFiles() {
  const out = [];
  if (!existsSync(PROJECTS_ROOT)) return out;
  for (const proj of readdirSync(PROJECTS_ROOT)) {
    const memDir = join(PROJECTS_ROOT, proj, 'memory');
    if (!existsSync(memDir)) continue;
    try {
      for (const f of readdirSync(memDir)) {
        if (!f.endsWith('.md') || f === 'MEMORY.md') continue;
        out.push({ project: proj, file: f, path: join(memDir, f) });
      }
    } catch {}
  }
  return out;
}

// Day 13: index journal digests (per-day transcript-distilled rollups).
// Treated as synthetic project '_digests' so BM25 ranks them alongside memory files.
// No frontmatter / no supersession sidecars expected — upsertFile handles both gracefully.
function listDigestFiles() {
  const out = [];
  if (!existsSync(DIGESTS_ROOT)) return out;
  try {
    for (const f of readdirSync(DIGESTS_ROOT)) {
      if (!f.endsWith('.md')) continue;
      out.push({ project: '_digests', file: f, path: join(DIGESTS_ROOT, f), isDigest: true });
    }
  } catch {}
  return out;
}

function getMerged(filePath) {
  const r = spawnSync('node', [MERGE_CLI, filePath], { encoding: 'utf8', maxBuffer: 10 * 1024 * 1024 });
  if (r.status === 0) return r.stdout;
  return readFileSync(filePath, 'utf8');
}

function loadSupersessionsFor(filePath) {
  const sc = filePath + '.supersessions.jsonl';
  if (!existsSync(sc)) return [];
  const raw = readFileSync(sc, 'utf8');
  const out = [];
  for (const ln of raw.split('\n')) {
    const s = ln.trim();
    if (!s) continue;
    try { out.push(JSON.parse(s)); } catch {}
  }
  return out;
}

function upsertFile(rec) {
  const original = readFileSync(rec.path, 'utf8');
  const { fm, body } = parseFrontmatter(original);
  // Digests have no frontmatter and no supersession sidecars — skip the merge subprocess.
  const merged = rec.isDigest ? original : getMerged(rec.path);
  const supersessions = rec.isDigest ? [] : loadSupersessionsFor(rec.path);
  const hasSup = supersessions.length > 0 ? 1 : 0;
  const mtime = statSync(rec.path).mtimeMs;
  const hash = sha256(original + JSON.stringify(supersessions));
  // Fallback name from filename (digests + frontmatter-less files)
  if (!fm.name) fm.name = `${rec.isDigest ? 'digest ' : ''}${basename(rec.file, '.md')}`;
  if (!fm.type && rec.isDigest) fm.type = 'digest';
  if (!fm.description && rec.isDigest) fm.description = `Per-day journal digest (transcript-distilled rollup) for ${basename(rec.file, '.md')}`;

  const existing = sql(`SELECT id, sha256 FROM memory_file WHERE project=${esc(rec.project)} AND file=${esc(rec.file)};`, { json: true });
  if (existing.length && existing[0].sha256 === hash) return { id: existing[0].id, action: 'unchanged' };

  // Upsert (delete + insert to keep id stable would require ORM; just delete fts entries + upsert main)
  const idStmt = existing.length
    ? `UPDATE memory_file SET type=${esc(fm.type || '')}, name=${esc(fm.name || '')}, description=${esc(fm.description || '')}, body=${esc(body)}, merged_body=${esc(merged)}, has_supersessions=${hasSup}, mtime=${mtime}, sha256=${esc(hash)} WHERE id=${existing[0].id}; SELECT ${existing[0].id} AS id;`
    : `INSERT INTO memory_file (project, file, type, name, description, body, merged_body, has_supersessions, mtime, sha256) VALUES (${esc(rec.project)}, ${esc(rec.file)}, ${esc(fm.type || '')}, ${esc(fm.name || '')}, ${esc(fm.description || '')}, ${esc(body)}, ${esc(merged)}, ${hasSup}, ${mtime}, ${esc(hash)}); SELECT last_insert_rowid() AS id;`;
  const out = sql(idStmt, { json: true });
  const id = out[0]?.id ?? existing[0]?.id;

  // Refresh supersession rows
  sql(`DELETE FROM supersession WHERE memory_id=${id};`);
  for (const s of supersessions) {
    const le = Array.isArray(s.live_evidence) ? s.live_evidence.join(' | ') : (s.live_evidence || '');
    sql(`INSERT INTO supersession (memory_id, superseded_at, scope, corrected_assertion, source, live_evidence, operator_confirmed, retention_policy) VALUES (${id}, ${esc(s.superseded_at || '')}, ${esc(s.scope || '')}, ${esc(s.corrected_assertion || '')}, ${esc(s.superseded_by || '')}, ${esc(le)}, ${esc(s.operator_confirmed || '')}, ${esc(s.retention_policy || '')});`);
  }

  // FTS5 with content-table doesn't need direct insert — `INSERT INTO memory_fts(memory_fts) VALUES('rebuild');` rebuilds. For incremental, just trigger an update via rebuild on small N.
  return { id, action: existing.length ? 'updated' : 'inserted' };
}

function rebuildFts() {
  sql(`INSERT INTO memory_fts(memory_fts) VALUES('rebuild');`);
}

function buildAll() {
  initSchema();
  const memFiles = listMemoryFiles();
  const digestFiles = listDigestFiles();
  const files = [...memFiles, ...digestFiles];
  let stats = { unchanged: 0, inserted: 0, updated: 0 };
  for (const f of files) {
    try {
      const r = upsertFile(f);
      stats[r.action] = (stats[r.action] || 0) + 1;
    } catch (e) {
      console.error(`[index] FAIL ${f.path}: ${e.message}`);
    }
  }
  rebuildFts();
  sql(`INSERT OR REPLACE INTO index_meta (key, value) VALUES ('last_full_build', '${new Date().toISOString()}'), ('file_count', '${files.length}'), ('memory_count', '${memFiles.length}'), ('digest_count', '${digestFiles.length}');`);
  console.log(`[index] ${files.length} files (${memFiles.length} memory + ${digestFiles.length} digests): ${stats.inserted || 0} inserted, ${stats.updated || 0} updated, ${stats.unchanged || 0} unchanged`);
  return stats;
}

function watchMode() {
  buildAll();
  console.log(`[index] watching ${PROJECTS_ROOT} + ${DIGESTS_ROOT} for changes...`);
  const watchers = [];
  for (const proj of readdirSync(PROJECTS_ROOT)) {
    const memDir = join(PROJECTS_ROOT, proj, 'memory');
    if (!existsSync(memDir)) continue;
    const w = watch(memDir, { recursive: false }, (event, fname) => {
      if (!fname) return;
      if (!fname.endsWith('.md') && !fname.endsWith('.supersessions.jsonl')) return;
      const baseFile = fname.endsWith('.supersessions.jsonl') ? fname.replace('.supersessions.jsonl', '') : fname;
      const fullPath = join(memDir, baseFile);
      if (!existsSync(fullPath)) return;
      try {
        const r = upsertFile({ project: proj, file: baseFile, path: fullPath });
        if (r.action !== 'unchanged') {
          console.log(`[index] ${r.action}: ${proj}/${baseFile}`);
          rebuildFts();
        }
      } catch (e) { console.error(`[index] watch upsert failed for ${fullPath}: ${e.message}`); }
    });
    watchers.push(w);
  }
  // Day 13: also watch the digests dir
  if (existsSync(DIGESTS_ROOT)) {
    const w = watch(DIGESTS_ROOT, { recursive: false }, (event, fname) => {
      if (!fname || !fname.endsWith('.md')) return;
      const fullPath = join(DIGESTS_ROOT, fname);
      if (!existsSync(fullPath)) return;
      try {
        const r = upsertFile({ project: '_digests', file: fname, path: fullPath, isDigest: true });
        if (r.action !== 'unchanged') {
          console.log(`[index] ${r.action}: _digests/${fname}`);
          rebuildFts();
        }
      } catch (e) { console.error(`[index] watch upsert failed for ${fullPath}: ${e.message}`); }
    });
    watchers.push(w);
  }
}

function stats() {
  initSchema();
  const r = sql(`SELECT (SELECT COUNT(*) FROM memory_file) AS files, (SELECT COUNT(*) FROM supersession) AS supersessions, (SELECT value FROM index_meta WHERE key='last_full_build') AS last_build, (SELECT SUM(LENGTH(merged_body)) FROM memory_file) AS total_bytes;`, { json: true });
  console.log(JSON.stringify(r[0], null, 2));
}

async function main() {
  if (ARGS.includes('--stats')) { stats(); return; }
  if (ARGS.includes('--watch')) { watchMode(); return; }
  buildAll();
}

main().catch(e => { console.error('fatal:', e); process.exit(1); });
