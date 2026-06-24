#!/usr/bin/env node
// claude-hook-substrate-guard — PreToolUse(Bash) guard that makes the memory-oracle PRIMARY.
//
// Blocks raw grep/rg/cat/fd/find/head/tail/sed/awk/ls over the SUBSTRATE (memory cards +
// digests + MEMORY.md) so RECALL goes through memory-search / memory-cite instead of
// file-scraping. The oracle tools (~/.bin/*) and the Read/Edit tools are unaffected, so
// editing a known file still works — only "search the substrate with raw shell tools" is denied.
//
// Registered under hooks.PreToolUse (matcher "Bash"). Returns a deny decision + a corrective
// message pointing at the oracle.
import fs from "node:fs";

let raw = "";
try { raw = fs.readFileSync(0, "utf8"); } catch {}
let cmd = "";
try { cmd = (JSON.parse(raw).tool_input || {}).command || ""; } catch {}

const SUBSTRATE = /(\.claude\/projects|\.local\/share\/journal\/digests|\/memory\/[^ ]*\.md|MEMORY\.md)/;
const RAW_TOOL  = /(^|[|;&]|\s)(rg|grep|egrep|fgrep|fd|find|cat|head|tail|sed|awk|ls)\s/;
// allowlist: the oracle + substrate tools themselves (they live in ~/.bin and legitimately touch it)
const ALLOW = /(memory-search|memory-cite|memory-index-build|memory-merge|memory-structural|mae-substrate|brain-sync|vault-autosync|git-remote-verum|claude-hook-)/;

if (cmd && SUBSTRATE.test(cmd) && RAW_TOOL.test(cmd) && !ALLOW.test(cmd)) {
  process.stdout.write(JSON.stringify({
    hookSpecificOutput: {
      hookEventName: "PreToolUse",
      permissionDecision: "deny",
      permissionDecisionReason:
        "SUBSTRATE-FIRST (guard): the memory-oracle is PRIMARY for substrate recall. " +
        "Do NOT grep/cat/find/rg the memory cards or digests. Use:\n" +
        "  ~/.bin/memory-search.mjs \"<topic>\"            (cross-session facts/history)\n" +
        "  ~/.bin/memory-cite.mjs <session-id> --grep <p>  (THIS session's work)\n" +
        "To read/edit a specific known file, use the Read/Edit tools (not Bash). " +
        "Canonical footgun: never re-derive what a component is (e.g. verum) from file inspection — search the substrate first.",
    },
  }));
  process.exit(0);
}
process.exit(0);
