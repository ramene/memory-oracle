// memory-oracle/packages/core/handlers.mjs
//
// Shared handler module. MCP server (stdio) and REST API (Express) both import these.
// Each handler shells out to the existing ~/.bin/memory-*.mjs CLIs — single source of truth.

import { spawn } from 'node:child_process';
import { join } from 'node:path';
import { existsSync, appendFileSync, statSync } from 'node:fs';

const BIN = process.env.MEMORY_ORACLE_BIN || join(process.env.HOME, '.bin');
const PROJECTS_ROOT = process.env.CLAUDE_PROJECTS_ROOT || join(process.env.HOME, '.claude', 'projects');

function run(cmd, args, opts = {}) {
  return new Promise((resolve, reject) => {
    const p = spawn(cmd, args, { stdio: ['ignore', 'pipe', 'pipe'], ...opts });
    let stdout = '', stderr = '';
    p.stdout.on('data', d => stdout += d.toString());
    p.stderr.on('data', d => stderr += d.toString());
    p.on('close', code => {
      if (code === 0) resolve(stdout);
      else reject(new Error(`${cmd} exited ${code}: ${stderr}`));
    });
    p.on('error', reject);
  });
}

// memory_search — primary retrieval
export async function memory_search({ query, project, k = 10, budget = 30000 }) {
  if (!query || typeof query !== 'string') throw new Error('query (string) is required');
  const args = [join(BIN, 'memory-search.mjs'), query, `--budget=${budget}`, `--k=${k}`];
  if (project) args.push(`--project=${project}`);
  const out = await run('node', args);
  return { query, project: project || null, k, budget, results: out };
}

// memory_cite — fetch transcript context for a Tier-1 citation
export async function memory_cite({ session_id, line, grep, at, tail, context = 20, first = 5, info = false }) {
  if (!session_id) throw new Error('session_id is required');
  const args = [join(BIN, 'memory-cite.mjs'), '--session', session_id, '--context', String(context), '--first', String(first)];
  if (info) args.push('--info');
  else if (line != null) { args[args.indexOf('--session')] = '--session'; args.push(`${session_id}#L${line}`); args.splice(args.indexOf('--session'), 2); }
  else if (grep) args.push('--grep', grep);
  else if (at) args.push('--at', at);
  else if (tail) args.push('--tail', String(tail));
  const out = await run('node', args);
  return { session_id, results: out };
}

// memory_supersede — append a sidecar entry (the corrective primitive)
export async function memory_supersede({ project, file, scope, corrected_assertion, source, live_evidence, operator_confirmed, retention_policy }) {
  if (!project || !file) throw new Error('project + file are required');
  if (!scope || !corrected_assertion) throw new Error('scope + corrected_assertion are required');
  const memDir = join(PROJECTS_ROOT, project, 'memory');
  const target = join(memDir, file);
  if (!existsSync(target)) throw new Error(`canonical file does not exist: ${target}`);
  const sidecar = target + '.supersessions.jsonl';
  const record = {
    superseded_at: new Date().toISOString(),
    scope,
    corrected_assertion,
    superseded_by: source || `api-call-${new Date().toISOString()}`,
    live_evidence: Array.isArray(live_evidence) ? live_evidence : [live_evidence || ''],
    operator_confirmed: operator_confirmed || new Date().toISOString(),
    retention_policy: retention_policy || 'permanent — append further supersessions if context changes again',
  };
  appendFileSync(sidecar, JSON.stringify(record) + '\n');
  return { sidecar, record, indexed: 'fs-watcher will pick up within ~1s' };
}

// memory_stats — index-meta state
export async function memory_stats() {
  const out = await run('node', [join(BIN, 'memory-index-build.mjs'), '--stats']);
  try { return JSON.parse(out); } catch { return { raw: out }; }
}

// memory_info — list projects + counts
export async function memory_info() {
  const out = await run('sqlite3', [
    process.env.MEMORY_INDEX_DB || join(process.env.HOME, '.local', 'share', 'journal', '.memory-index.db'),
    '-json',
    `SELECT project, COUNT(*) AS files, date(MIN(mtime)/1000, 'unixepoch') AS oldest, date(MAX(mtime)/1000, 'unixepoch') AS newest FROM memory_file GROUP BY project ORDER BY files DESC;`
  ]);
  try { return { projects: JSON.parse(out) }; } catch { return { raw: out }; }
}

export const HANDLERS = { memory_search, memory_cite, memory_supersede, memory_stats, memory_info };

export const TOOL_DEFINITIONS = {
  memory_search: {
    description: 'Supersession-aware BM25 retrieval over operator-curated memory files and journal digests. Returns ranked hits with supersession sidecars merged at read time.',
    inputSchema: {
      type: 'object',
      properties: {
        query: { type: 'string', description: 'Natural-language query. Keyword-dense queries rank better than long sentences.' },
        project: { type: 'string', description: 'Optional project filter (e.g., "-Users-ramene--remote--plans-mae-monorepo-build")' },
        k: { type: 'number', description: 'Top-K hits to return', default: 10 },
        budget: { type: 'number', description: 'Byte budget for merged output', default: 30000 },
      },
      required: ['query'],
    },
  },
  memory_cite: {
    description: 'Bridge Tier-1 supersession citations (e.g., "session-id#L94616") to raw transcript content. Streams large JSONL — no in-memory load.',
    inputSchema: {
      type: 'object',
      properties: {
        session_id: { type: 'string', description: 'Claude Code session UUID' },
        line: { type: 'number', description: 'Specific line number to fetch with surrounding context' },
        grep: { type: 'string', description: 'Find first N matches of a regex pattern' },
        at: { type: 'string', description: 'ISO timestamp — fetch nearest message' },
        tail: { type: 'number', description: 'Return last N lines' },
        context: { type: 'number', description: 'Lines of surrounding context', default: 20 },
        first: { type: 'number', description: 'Number of grep matches to return', default: 5 },
        info: { type: 'boolean', description: 'Return session metadata only', default: false },
      },
      required: ['session_id'],
    },
  },
  memory_supersede: {
    description: 'Append a supersession sidecar entry to a canonical memory file. The original is never modified; the correction lives in `<file>.supersessions.jsonl`. Watcher re-indexes within ~1s.',
    inputSchema: {
      type: 'object',
      properties: {
        project: { type: 'string', description: 'Project directory under ~/.claude/projects/' },
        file: { type: 'string', description: 'Memory file name (e.g., "feedback_brain_pipeline.md")' },
        scope: { type: 'string', description: 'What assertion in the canonical file is invalidated' },
        corrected_assertion: { type: 'string', description: 'The new, authoritative truth' },
        source: { type: 'string', description: 'Citation pointing to evidence (e.g., session-id#L94616, file path, FHIR resource)' },
        live_evidence: { type: 'array', items: { type: 'string' }, description: 'Paths/URLs to verify ground truth NOW' },
        operator_confirmed: { type: 'string', description: 'ISO timestamp + context of human confirmation' },
        retention_policy: { type: 'string', description: 'When (if ever) to retire this supersession' },
      },
      required: ['project', 'file', 'scope', 'corrected_assertion'],
    },
  },
  memory_stats: {
    description: 'Index statistics: file count, supersession count, total bytes, last full build timestamp.',
    inputSchema: { type: 'object', properties: {} },
  },
  memory_info: {
    description: 'Per-project file counts + date ranges. Useful for understanding corpus coverage.',
    inputSchema: { type: 'object', properties: {} },
  },
};
