#!/usr/bin/env node
// claude-hook-memory-hygiene — PreToolUse(Write|Edit) hook that protects against
// the cross-session-blindness footgun: when session B operationalizes a script
// referenced in session A's memory, session A's memory goes stale.
//
// What this hook does:
//   - On Write or Edit of any file, scan ALL memory cards on this machine for
//     references to that file path (or its basename).
//   - If found, return permissionDecision="ask" with the memory paths surfaced.
//   - The agent (and operator approving the prompt) sees: "this file is
//     referenced in N memories — consider updating them after substantive
//     changes." Non-blocking on operator's explicit approval; blocks the
//     silent path that caused the 2026-06-25 incident.
//
// What this hook does NOT do:
//   - Does NOT deny by default — uses "ask" to require operator awareness.
//   - Does NOT block edits to non-substrate-referenced files.
//   - Does NOT walk session JSONLs (only the memory cards, which are the
//     load-bearing substrate). Session JSONLs change too often.
//   - Does NOT scan the file being edited (only checks if the PATH being
//     written-to is referenced elsewhere).
//
// Registered in ~/.claude/settings.json under hooks.PreToolUse with
// matcher "Write|Edit". Propagated by memory-oracle/install.sh.
//
// Companion: ~/.bin/memory-hygiene-audit.mjs — daily cron audit + JSON report.

import fs from "node:fs";
import path from "node:path";
import { homedir } from "node:os";

let raw = "";
try { raw = fs.readFileSync(0, "utf8"); } catch {}
let input = {};
try { input = JSON.parse(raw); } catch {}
const tool = input.tool_name || "";
const filePath = (input.tool_input || {}).file_path || "";

// Bail early — only Write/Edit, only with a file_path
if (!/^(Write|Edit|NotebookEdit)$/.test(tool) || !filePath) {
  process.exit(0);
}

// Skip files NOT in the substrate-tracked tooling set. We want to catch
// operationalizing changes (scripts, install paths, configs that memories
// reference), not every doc/lesson card edit.
const TRACKED_EXTS = /\.(mjs|js|ts|tsx|py|sh|zsh|bash|rb|go|rs|mts|cjs|cts)$/;
if (!TRACKED_EXTS.test(filePath)) {
  process.exit(0);
}

// Search memory cards on this machine for references to this path.
// Match by absolute path OR basename — paths in memories sometimes use ~
// or relative forms.
const MEMORY_ROOTS = [
  path.join(homedir(), ".claude/projects"),
];
const basename = path.basename(filePath);
const homeRel  = filePath.startsWith(homedir() + "/")
  ? "~" + filePath.slice(homedir().length)
  : filePath;

function* walk(dir) {
  let entries;
  try { entries = fs.readdirSync(dir, { withFileTypes: true }); }
  catch { return; }
  for (const e of entries) {
    const full = path.join(dir, e.name);
    if (e.isDirectory()) {
      // Skip subagents/ and other large noisy subdirs
      if (e.name === "subagents" || e.name.startsWith(".")) continue;
      yield* walk(full);
    } else if (e.isFile() && e.name.endsWith(".md") && full.includes("/memory/")) {
      yield full;
    }
  }
}

const matches = [];
for (const root of MEMORY_ROOTS) {
  for (const mem of walk(root)) {
    let content;
    try { content = fs.readFileSync(mem, "utf8"); } catch { continue; }
    if (content.includes(filePath) || content.includes(homeRel) || content.includes(basename)) {
      // Strong match: full path. Weaker: basename only.
      const isStrong = content.includes(filePath) || content.includes(homeRel);
      matches.push({
        memory: mem.replace(homedir(), "~"),
        match: isStrong ? "path" : "basename",
      });
    }
  }
}

if (matches.length === 0) {
  process.exit(0);
}

// Surface ALL matches to the agent — emit "ask" so operator must confirm.
const strong = matches.filter(m => m.match === "path");
const weak   = matches.filter(m => m.match === "basename");
const lines = [];
lines.push(`MEMORY-HYGIENE GUARD: this file is referenced in ${matches.length} memory card${matches.length > 1 ? "s" : ""}.`);
lines.push("If this change is OPERATIONAL (not a trivial fix/typo), update the referenced memory cards to point at the new behavior — or write a follow-up memory with `supersedes: <name>`.");
lines.push("");
if (strong.length) {
  lines.push("Strong matches (full path):");
  for (const m of strong.slice(0, 8)) lines.push(`  - ${m.memory}`);
}
if (weak.length) {
  lines.push("Weaker matches (basename only — verify relevance):");
  for (const m of weak.slice(0, 5)) lines.push(`  - ${m.memory}`);
}
lines.push("");
lines.push("To proceed: confirm the edit. After substantive changes, run:");
lines.push("  ~/.bin/memory-hygiene-audit.mjs --since <yyyy-mm-dd>   (to surface stale memories)");
lines.push("Why: cross-session-blindness footgun — session B operationalizes session A's referenced script, A's memory goes stale silently. See [[reference_codewithantonio_bulk_walker_operationalization]].");

process.stdout.write(JSON.stringify({
  hookSpecificOutput: {
    hookEventName: "PreToolUse",
    permissionDecision: "ask",
    permissionDecisionReason: lines.join("\n"),
  },
}));
process.exit(0);
