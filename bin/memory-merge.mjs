#!/usr/bin/env node
// memory-merge — read-time merge of a memory file + its supersession sidecar.
//
// Usage:
//   memory-merge <memory-file.md>
//   memory-merge <memory-file.md> --json
//   memory-merge --prime <memory-dir>   # emit all merged files for session-priming
//
// Output: original markdown with a "## ⚠ Supersession Notice" block prepended IF
// a sidecar exists. Each superseding entry lists scope + corrected_assertion +
// live_evidence + when/who confirmed it. The original file content is preserved
// VERBATIM below the notice — never destructive, always additive.
//
// This is P0 of the mae memory architecture (ADR mae-ADR-001, 2026-05-16).

import { readFileSync, existsSync, readdirSync, statSync } from 'node:fs';
import { join, basename, dirname } from 'node:path';

const ARGS = process.argv.slice(2);

function loadSupersessions(memoryFilePath) {
  // Post-2026-05-27 EBR rename: prefer .amendments.jsonl; fall back to
  // .supersessions.jsonl for operator's live corpus backwards compat.
  const candidates = [memoryFilePath + '.amendments.jsonl', memoryFilePath + '.supersessions.jsonl'];
  const sidecar = candidates.find(p => existsSync(p));
  if (!sidecar) return [];
  const raw = readFileSync(sidecar, 'utf8');
  const out = [];
  for (const line of raw.split('\n')) {
    const s = line.trim();
    if (!s) continue;
    try { out.push(JSON.parse(s)); }
    catch (e) { console.error(`[memory-merge] WARN: bad jsonl in ${sidecar}: ${e.message}`); }
  }
  // Newest supersession last in file → reverse for "newest first" presentation
  out.sort((a, b) => (b.superseded_at || '').localeCompare(a.superseded_at || ''));
  return out;
}

function renderSupersessionBlock(supersessions) {
  if (supersessions.length === 0) return '';
  const lines = [];
  lines.push('---');
  lines.push('');
  lines.push(`## ⚠ Supersession Notice (${supersessions.length} record${supersessions.length > 1 ? 's' : ''})`);
  lines.push('');
  lines.push('**This file contains content that has been superseded by later authoritative events. Read the supersession records below BEFORE treating any assertion in this file as current.**');
  lines.push('');
  for (let i = 0; i < supersessions.length; i++) {
    const s = supersessions[i];
    lines.push(`### Supersession ${i + 1} — ${s.superseded_at || 'unknown date'}`);
    lines.push('');
    lines.push(`**Scope of supersession:** ${s.scope || '(unspecified)'}`);
    lines.push('');
    lines.push(`**Corrected assertion:** ${s.corrected_assertion || '(unspecified)'}`);
    lines.push('');
    if (s.superseded_by) {
      lines.push(`**Source:** ${s.superseded_by}`);
      lines.push('');
    }
    if (Array.isArray(s.live_evidence) && s.live_evidence.length > 0) {
      lines.push('**Live evidence (where to verify ground truth NOW):**');
      for (const e of s.live_evidence) lines.push(`- ${e}`);
      lines.push('');
    } else if (typeof s.live_evidence === 'string') {
      lines.push(`**Live evidence:** ${s.live_evidence}`);
      lines.push('');
    }
    if (s.operator_confirmed) {
      lines.push(`**Operator confirmed:** ${s.operator_confirmed}`);
      lines.push('');
    }
    if (s.retention_policy) {
      lines.push(`**Retention policy:** ${s.retention_policy}`);
      lines.push('');
    }
  }
  lines.push('---');
  lines.push('');
  lines.push('**Original file content (preserved verbatim — read with the corrections above in mind):**');
  lines.push('');
  return lines.join('\n');
}

function mergeFile(memoryFilePath) {
  const original = readFileSync(memoryFilePath, 'utf8');
  const supersessions = loadSupersessions(memoryFilePath);
  if (supersessions.length === 0) return { merged: original, supersessions: [], hasSupersessions: false };
  const block = renderSupersessionBlock(supersessions);
  return {
    merged: block + original,
    supersessions,
    hasSupersessions: true,
  };
}

function findMemoryDirs() {
  const projectsRoot = process.env.CLAUDE_PROJECTS_ROOT || join(process.env.HOME, '.claude', 'projects');
  if (!existsSync(projectsRoot)) return [];
  const dirs = [];
  for (const proj of readdirSync(projectsRoot)) {
    const memDir = join(projectsRoot, proj, 'memory');
    if (existsSync(memDir) && statSync(memDir).isDirectory()) dirs.push(memDir);
  }
  return dirs;
}

function listMemoryFiles(dir) {
  return readdirSync(dir)
    .filter(f => f.endsWith('.md') && f !== 'MEMORY.md')
    .map(f => join(dir, f));
}

async function main() {
  if (ARGS.length === 0 || ARGS.includes('--help') || ARGS.includes('-h')) {
    console.log('usage: memory-merge <file.md> [--json]');
    console.log('       memory-merge --prime [memory-dir...]');
    console.log('       memory-merge --audit   # list all files with supersession sidecars');
    process.exit(0);
  }

  if (ARGS[0] === '--audit') {
    const dirs = findMemoryDirs();
    let total = 0, withSupersessions = 0;
    for (const dir of dirs) {
      for (const f of listMemoryFiles(dir)) {
        total += 1;
        // Look for either extension (.amendments.jsonl preferred, .supersessions.jsonl legacy)
        const sidecar = existsSync(f + '.amendments.jsonl') ? f + '.amendments.jsonl'
                       : (existsSync(f + '.supersessions.jsonl') ? f + '.supersessions.jsonl' : null);
        if (sidecar) {
          withSupersessions += 1;
          const sups = loadSupersessions(f);
          console.log(`[amendment] ${f}`);
          for (const s of sups) {
            console.log(`  → ${s.superseded_at || '?'}: ${(s.scope || '').slice(0, 100)}`);
          }
        }
      }
    }
    console.log(`\nTotal memory files: ${total}`);
    console.log(`Files with supersessions: ${withSupersessions} (${(withSupersessions/total*100).toFixed(1)}%)`);
    process.exit(0);
  }

  if (ARGS[0] === '--prime') {
    const dirs = ARGS.slice(1).length > 0 ? ARGS.slice(1) : findMemoryDirs();
    for (const dir of dirs) {
      console.log(`\n# Memory dir: ${dir}\n`);
      for (const f of listMemoryFiles(dir)) {
        const { merged, hasSupersessions } = mergeFile(f);
        if (hasSupersessions) {
          console.log(`\n## ${basename(f)} (HAS SUPERSESSIONS)\n`);
          console.log(merged);
          console.log('\n---\n');
        }
      }
    }
    process.exit(0);
  }

  // Single file path
  const filePath = ARGS[0];
  if (!existsSync(filePath)) {
    console.error(`error: file not found: ${filePath}`);
    process.exit(1);
  }
  const result = mergeFile(filePath);
  if (ARGS.includes('--json')) {
    console.log(JSON.stringify({
      file: filePath,
      hasSupersessions: result.hasSupersessions,
      supersessionCount: result.supersessions.length,
      supersessions: result.supersessions,
    }, null, 2));
  } else {
    process.stdout.write(result.merged);
  }
}

main().catch(e => { console.error('[memory-merge] fatal:', e); process.exit(1); });
