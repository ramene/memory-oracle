#!/usr/bin/env node
// memory-hygiene-audit — daily/on-demand audit of memory↔script staleness.
//
// For each memory card:
//   1. Extract referenced file paths (absolute or ~-relative).
//   2. For each referenced path that EXISTS: compare script mtime vs memory mtime.
//   3. If script is NEWER than the memory by more than --threshold-days (default 7),
//      flag the memory as potentially stale.
//
// Outputs:
//   - JSON report at ~/.local/share/memory-oracle/hygiene-report-YYYY-MM-DD.json
//   - One-line digest to stdout: "N memories potentially stale (vs M scanned)"
//
// Cron entry (daily 10:00 — installed by memory-oracle/install.sh):
//   0 10 * * * $HOME/.bin/memory-hygiene-audit.mjs >> $HOME/.claude-tmp/memory-hygiene-audit.log 2>&1
//
// Usage:
//   memory-hygiene-audit.mjs                          (default: 7-day threshold)
//   memory-hygiene-audit.mjs --threshold-days 1       (stricter)
//   memory-hygiene-audit.mjs --since 2026-06-20       (only memories older than date)
//   memory-hygiene-audit.mjs --memory <path>          (audit one memory only)
//   memory-hygiene-audit.mjs --json                   (machine-readable to stdout)

import fs from "node:fs";
import path from "node:path";
import { homedir } from "node:os";

const argv = process.argv.slice(2);
const opts = {
  thresholdDays: 7,
  since: null,
  memoryFilter: null,
  jsonOnly: false,
};
for (let i = 0; i < argv.length; i++) {
  const a = argv[i];
  if (a === "--threshold-days") opts.thresholdDays = parseInt(argv[++i], 10);
  else if (a === "--since") opts.since = new Date(argv[++i]);
  else if (a === "--memory") opts.memoryFilter = argv[++i];
  else if (a === "--json") opts.jsonOnly = true;
  else if (a === "-h" || a === "--help") {
    console.log("Usage: memory-hygiene-audit.mjs [--threshold-days N] [--since YYYY-MM-DD] [--memory PATH] [--json]");
    process.exit(0);
  }
}

const MEMORY_ROOT = path.join(homedir(), ".claude/projects");
const REPORT_DIR = path.join(homedir(), ".local/share/memory-oracle");
fs.mkdirSync(REPORT_DIR, { recursive: true });

function* walkMemories(dir) {
  let entries;
  try { entries = fs.readdirSync(dir, { withFileTypes: true }); }
  catch { return; }
  for (const e of entries) {
    const full = path.join(dir, e.name);
    if (e.isDirectory()) {
      if (e.name === "subagents" || e.name.startsWith(".")) continue;
      yield* walkMemories(full);
    } else if (e.isFile() && e.name.endsWith(".md") && full.includes("/memory/")) {
      // Skip MEMORY.md indexes
      if (e.name === "MEMORY.md") continue;
      yield full;
    }
  }
}

// Extract absolute or ~-relative file paths from memory body.
// Conservative: only paths starting with / or ~/ that look like real paths.
function extractRefs(text) {
  const out = new Set();
  const REGEX = /(?:^|[\s`'"(\[])(~\/[A-Za-z0-9._\/-]+|\/[A-Za-z][A-Za-z0-9._\/-]{2,}[A-Za-z0-9])/g;
  let m;
  while ((m = REGEX.exec(text)) !== null) {
    let p = m[1];
    if (p.startsWith("~/")) p = path.join(homedir(), p.slice(2));
    // Filter out obvious non-files (dirs without ext, URLs, etc)
    if (p.endsWith("/")) continue;
    // Only inspect tracked-extension files (matches the hook)
    if (!/\.(mjs|js|ts|tsx|py|sh|zsh|bash|rb|go|rs|mts|cjs|cts|sql|toml|yaml|yml|json|md)$/.test(p)) continue;
    out.add(p);
  }
  return [...out];
}

function safeStat(p) {
  try { return fs.statSync(p); } catch { return null; }
}

const now = Date.now();
const thresholdMs = opts.thresholdDays * 24 * 3600 * 1000;
const report = {
  generated_at: new Date().toISOString(),
  threshold_days: opts.thresholdDays,
  memories_scanned: 0,
  memories_with_refs: 0,
  potentially_stale: [],   // {memory, mem_mtime, drift: [{ref, ref_mtime, days_newer}]}
  refs_missing: [],         // {memory, ref}
  errors: [],
};

for (const memPath of walkMemories(MEMORY_ROOT)) {
  if (opts.memoryFilter && !memPath.includes(opts.memoryFilter)) continue;
  const memStat = safeStat(memPath);
  if (!memStat) continue;
  if (opts.since && memStat.mtime < opts.since) continue;
  report.memories_scanned++;
  let body;
  try { body = fs.readFileSync(memPath, "utf8"); } catch { continue; }
  const refs = extractRefs(body);
  if (refs.length === 0) continue;
  report.memories_with_refs++;
  const drift = [];
  for (const ref of refs) {
    const refStat = safeStat(ref);
    if (!refStat) {
      report.refs_missing.push({ memory: memPath.replace(homedir(), "~"), ref: ref.replace(homedir(), "~") });
      continue;
    }
    const driftMs = refStat.mtime.getTime() - memStat.mtime.getTime();
    if (driftMs > thresholdMs) {
      drift.push({
        ref: ref.replace(homedir(), "~"),
        ref_mtime: refStat.mtime.toISOString(),
        days_newer: Math.round(driftMs / (24 * 3600 * 1000) * 10) / 10,
      });
    }
  }
  if (drift.length > 0) {
    report.potentially_stale.push({
      memory: memPath.replace(homedir(), "~"),
      mem_mtime: memStat.mtime.toISOString(),
      refs_drift: drift.sort((a, b) => b.days_newer - a.days_newer),
    });
  }
}

// Sort potentially_stale by max-drift descending
report.potentially_stale.sort((a, b) =>
  b.refs_drift[0].days_newer - a.refs_drift[0].days_newer,
);

const dateStr = new Date().toISOString().slice(0, 10);
const reportPath = path.join(REPORT_DIR, `hygiene-report-${dateStr}.json`);
fs.writeFileSync(reportPath, JSON.stringify(report, null, 2) + "\n");

if (opts.jsonOnly) {
  process.stdout.write(JSON.stringify(report, null, 2));
} else {
  console.log(`memory-hygiene-audit · ${dateStr}`);
  console.log(`  scanned:      ${report.memories_scanned}`);
  console.log(`  with refs:    ${report.memories_with_refs}`);
  console.log(`  stale (≥${opts.thresholdDays}d drift): ${report.potentially_stale.length}`);
  console.log(`  refs missing: ${report.refs_missing.length}`);
  console.log(`  report:       ${reportPath.replace(homedir(), "~")}`);
  if (report.potentially_stale.length > 0) {
    console.log("");
    console.log("Top stale memories:");
    for (const s of report.potentially_stale.slice(0, 5)) {
      const worst = s.refs_drift[0];
      console.log(`  • ${path.basename(s.memory)} — ${worst.days_newer}d behind ${worst.ref}`);
    }
    console.log("");
    console.log("To address: open each memory, verify it still describes current behavior, update or write a 'supersedes' follow-up.");
  }
}

// Exit non-zero if drift exists (useful for cron monitoring)
process.exit(report.potentially_stale.length > 0 ? 1 : 0);
