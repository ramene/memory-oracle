#!/usr/bin/env node
// mae-substrate-merge — M3-β: gather memory from N machines → union → rebuild unified
// index. Redistribute with mae-substrate-export --full (reused). Coordinator-driven,
// pull-only (ssh `tar | extract`, no scp). Union is newest-mtime-wins with conflict
// backup — safe because each machine works a distinct facet (distinct card names).
//
// Usage:
//   node mae-substrate-merge.mjs --machines local,sequoia,tunafish [--out <dir>] [--rebuild]
//
// Machine spec: "local" = this box (no ssh). Others are ssh hosts; their node path for
// the optional --rebuild is auto-detected. Memory sources per machine:
//   ~/.claude/projects/*/memory/*.md   +   ~/.local/share/journal/digests/*.md
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import crypto from "node:crypto";
import { execSync, execFileSync } from "node:child_process";

const HOME = os.homedir();
const args = parse(process.argv.slice(2));
const machines = (args.machines || "local").split(",").map((s) => s.trim()).filter(Boolean);
const outDir = path.resolve(args.out || path.join(HOME, ".local", "share", "mae-substrate-union"));
const unionDir = path.join(outDir, "union");
const stageDir = path.join(outDir, ".gather");
const confDir = path.join(outDir, "conflicts");
for (const d of [unionDir, stageDir, confDir]) fs.mkdirSync(d, { recursive: true });

// find (not ls-glob) for digests so a missing dir / no-match never aborts under zsh nomatch.
const REMOTE_COLLECT =
  `cd "$HOME" && { find .claude/projects -path '*/memory/*.md' -type f 2>/dev/null; ` +
  `find .local/share/journal/digests -name '*.md' -type f 2>/dev/null; } | tar -czf - -T -`;

// ── 1. GATHER each machine into .gather/<machine>/ ────────────────────────────
const perMachine = {};
for (const m of machines) {
  const dest = path.join(stageDir, m);
  fs.rmSync(dest, { recursive: true, force: true });
  fs.mkdirSync(dest, { recursive: true });
  if (m === "local") {
    let n = 0;
    for (const f of localFiles()) { const rel = relOf(f); cp(f, path.join(dest, rel)); n++; }
    perMachine[m] = n;
  } else {
    const tarPath = path.join(stageDir, `${m}.tar.gz`);
    try {
      // offline-tolerant: a peer we can't reach right now is skipped (not fatal); the next
      // run re-converges it. BatchMode=yes so a refused/unknown host fails fast (no prompt).
      execSync(`ssh -o ConnectTimeout=12 -o BatchMode=yes ${m} bash -c ${shq(REMOTE_COLLECT)} > ${shq(tarPath)}`, { stdio: ["ignore", "ignore", "inherit"] });
      execFileSync("tar", ["-xzf", tarPath, "-C", dest]);
      perMachine[m] = walk(dest).length;
    } catch (e) {
      perMachine[m] = "unreachable(skipped)";
    } finally {
      fs.rmSync(tarPath, { force: true });
    }
  }
  console.log(`  gathered ${m}: ${perMachine[m]} files`);
}

// ── 2. UNION (newest-mtime wins; conflicts backed up) ──────────────────────────
let added = 0, skipped = 0, conflicts = 0;
for (const m of machines) {
  const base = path.join(stageDir, m);
  for (const abs of walk(base)) {
    const rel = abs.slice(base.length + 1);
    const target = path.join(unionDir, rel);
    if (!fs.existsSync(target)) { cp(abs, target); added++; continue; }
    if (sameHash(abs, target)) { skipped++; continue; }
    // content conflict — keep newer, back up the loser
    const inNewer = fs.statSync(abs).mtimeMs > fs.statSync(target).mtimeMs;
    const loser = inNewer ? target : abs;
    cp(loser, path.join(confDir, `${m}--${rel.replace(/\//g, "__")}.${Date.now()}`));
    if (inNewer) cp(abs, target);
    conflicts++;
  }
}

// ── 3. report (+ optional unified rebuild) ────────────────────────────────────
const memCount = walk(path.join(unionDir, ".claude", "projects")).length;
const digCount = walk(path.join(unionDir, ".local", "share", "journal", "digests")).length;
let indexed = null;
if (args.rebuild) {
  const env = { ...process.env, CLAUDE_PROJECTS_ROOT: path.join(unionDir, "projects"), JOURNAL_DIGESTS_ROOT: path.join(unionDir, "digests"), MEMORY_INDEX_DB: path.join(outDir, "union.memory-index.db") };
  indexed = execFileSync("node", [path.join(HOME, ".bin", "memory-index-build.mjs")], { env, encoding: "utf8" }).trim().split("\n").pop();
}

// ── 4. REDISTRIBUTE: push the unioned corpus back to EVERY machine's real dirs ──
// Closes the shared-brain loop: gather (pull) → union (newest-wins) → redistribute (push),
// so a memory card written on ANY machine converges to all three. Substrate-native (ssh tar),
// no third party. Each machine's launchd fs-watcher re-indexes once the write lands.
// NOTE: union is additive/newest-wins — it does NOT propagate deletions (brain is append-mostly;
// supersession is via sidecars, not file deletion). That is intentional for the brain.
let redistributed = null;
if (args.redistribute) {
  redistributed = {};
  for (const m of machines) {
    if (m === "local") {
      let n = 0;
      for (const f of walk(unionDir)) { cp(f, path.join(HOME, f.slice(unionDir.length + 1))); n++; }
      redistributed[m] = `applied ${n} locally`;
    } else {
      try {
        execSync(`tar -C ${shq(unionDir)} -czf - . | ssh -o ConnectTimeout=12 -o BatchMode=yes ${m} ${shq('tar -xzf - -C "$HOME"')}`, { stdio: ["ignore", "ignore", "inherit"] });
        redistributed[m] = "pushed";
      } catch (e) { redistributed[m] = "FAILED: " + String(e.message || e).split("\n")[0]; }
    }
  }
}

console.log(JSON.stringify({
  machines, perMachine, union: { added, skipped_identical: skipped, conflicts, memory_cards: memCount, digests: digCount },
  union_dir: unionDir, conflicts_dir: conflicts ? confDir : null,
  rebuilt_index: indexed, redistributed,
}, null, 2));

// ── helpers ──────────────────────────────────────────────────────────────────
function localFiles() {
  const out = [];
  const proot = path.join(HOME, ".claude", "projects");
  if (fs.existsSync(proot)) for (const p of fs.readdirSync(proot)) {
    const md = path.join(proot, p, "memory");
    if (fs.existsSync(md)) for (const f of fs.readdirSync(md)) if (f.endsWith(".md")) out.push(path.join(md, f));
  }
  const dg = path.join(HOME, ".local", "share", "journal", "digests");
  if (fs.existsSync(dg)) for (const f of fs.readdirSync(dg)) if (f.endsWith(".md")) out.push(path.join(dg, f));
  return out;
}
function relOf(f) {
  // Stage at $HOME-relative paths so LOCAL matches REMOTE (REMOTE_COLLECT tars
  // .claude/projects/... and .local/share/journal/digests/... relative to $HOME).
  // One structure => union actually merges local+remote, and redistribute is just
  // `tar union | ssh peer 'tar -x -C $HOME'`.
  if (f.startsWith(HOME + "/")) return f.slice(HOME.length + 1);
  return path.join("misc", path.basename(f));
}
function walk(d) { const o = []; if (!fs.existsSync(d)) return o; for (const e of fs.readdirSync(d, { withFileTypes: true })) { const p = path.join(d, e.name); e.isDirectory() ? o.push(...walk(p)) : o.push(p); } return o; }
function cp(src, dst) { fs.mkdirSync(path.dirname(dst), { recursive: true }); fs.copyFileSync(src, dst); }
function sameHash(a, b) { return sha(a) === sha(b); }
function sha(f) { return crypto.createHash("sha256").update(fs.readFileSync(f)).digest("hex"); }
function shq(s) { return "'" + s.replace(/'/g, "'\\''") + "'"; }
function parse(a) { const o = {}; for (let i = 0; i < a.length; i++) if (a[i].startsWith("--")) { const k = a[i].slice(2); o[k] = (i + 1 < a.length && !a[i + 1].startsWith("--")) ? a[++i] : true; } return o; }
