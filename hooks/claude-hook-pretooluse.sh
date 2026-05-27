#!/usr/bin/env bash
# claude-hook-pretooluse.sh
#
# Fires BEFORE every tool invocation. When the tool is Bash and the command starts with a
# watched ops CLI (gh, gcloud, aws, pulumi, kubectl, psql, pm2, docker, launchctl, terraform,
# helm), runs memory-search for "<cli> <subcommand>" and surfaces hits as additionalContext.
# The bash command still executes — the agent gets a heads-up of any operator-documented
# patterns/quirks BEFORE the call lands.
#
# Input  (stdin JSON):  { tool_name, tool_input: { command, ... }, ... }
# Output (stdout JSON): { hookSpecificOutput: { hookEventName, permissionDecision, additionalContext } }
#
# DEBUG: always logs to ~/.claude/.hook-debug-pretool.log (unconditional, like the SessionStart hook).
#
# Companion to ~/.bin/claude-hook-session-start.sh. Day 14 of mae-ADR-001.

set -u

# Portable PATH detection — Node (nvm + Homebrew + system), gcloud (optional).
_oracle_setup_path() {
  local p="${PATH:-/usr/local/bin:/usr/bin:/bin}"
  if [ -d "$HOME/.nvm/versions/node" ]; then
    local latest
    latest=$(ls -1 "$HOME/.nvm/versions/node" 2>/dev/null | sort -V | tail -1)
    [ -n "$latest" ] && p="$HOME/.nvm/versions/node/$latest/bin:$p"
  fi
  [ -d /opt/homebrew/bin ] && p="/opt/homebrew/bin:$p"
  [ -d /usr/local/bin ]   && p="/usr/local/bin:$p"
  [ -d "$HOME/.bin/google-cloud-sdk/bin" ] && p="$HOME/.bin/google-cloud-sdk/bin:$p"
  [ -d "$HOME/google-cloud-sdk/bin" ]      && p="$HOME/google-cloud-sdk/bin:$p"
  export PATH="$p"
}
_oracle_setup_path

DEBUG_LOG="${HOME}/.claude/.hook-debug-pretool.log"
MEMORY_SEARCH="${HOME}/.bin/memory-search.mjs"
INDEX_DB="${MEMORY_INDEX_DB:-${HOME}/.local/share/journal/.memory-index.db}"

# Watched ops CLIs — extend this list as new ones earn operator-curated memory
WATCHED='^(gh|gcloud|aws|pulumi|kubectl|psql|pm2|docker|launchctl|terraform|helm|sqlite3)$'

# Grep-family CLIs — intercepted only when target paths overlap with memory/journal dirs.
# Raw grep against ~/.claude/projects/*/memory/ misses the _digests synthetic project
# (per-day transcript-distilled digests) which is ONLY reachable via memory-search.
# Background: 2026-05-18 incident — agent ran `grep -r 'short'` across memory + tmux logs,
# concluded "no shorting discussion found", but _digests/2026-05-13.md had the full
# "short-side rollout — shadow → testnet paper → real-money canary" decision.
GREP_CMDS='^(grep|rg|ag|ripgrep)$'

# Path patterns that signal memory-corpus targeting (any one match → intercept).
# Order from most-specific to least, but matching is OR.
MEMORY_PATH_RX='(\.claude/projects/[^/]+/memory|\.local/share/journal|MEMORY\.md|_digests|tmux-logs)'

PAYLOAD=$(cat)

# Always log invocation so we can prove the hook fired
{
  echo "=== $(date -u +%FT%TZ) PreToolUse fired ==="
  echo "PAYLOAD: $(echo "$PAYLOAD" | head -c 500)"
} >> "$DEBUG_LOG" 2>&1

# Extract tool_name and command (if Bash)
TOOL_NAME=$(echo "$PAYLOAD" | python3 -c "import sys,json;d=json.load(sys.stdin);print(d.get('tool_name',''))" 2>/dev/null || echo "")
COMMAND=$(echo "$PAYLOAD" | python3 -c "import sys,json;d=json.load(sys.stdin);print(d.get('tool_input',{}).get('command',''))" 2>/dev/null || echo "")

# Only intervene on Bash tool calls
if [ "$TOOL_NAME" != "Bash" ] || [ -z "$COMMAND" ]; then
  echo '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"allow"}}'
  echo "SKIP: tool=$TOOL_NAME (not Bash or empty cmd)" >> "$DEBUG_LOG"
  exit 0
fi

# Extract the first command word — handle env-prefixes like `GH_TOKEN=xxx gh ...`
# Strip leading env assignments (VAR=value)
STRIPPED="$COMMAND"
while [[ "$STRIPPED" =~ ^[A-Z_][A-Z0-9_]*=([^[:space:]]+|\".*\"|\$\(.*\))[[:space:]]+ ]]; do
  STRIPPED="${STRIPPED#${BASH_REMATCH[0]}}"
done

# Now the first token should be the actual CLI
CLI=$(echo "$STRIPPED" | awk '{print $1}')
SUBCMD=$(echo "$STRIPPED" | awk '{print $2}')

# --- Branch: ops-CLI path vs grep-family path vs neither ---
MODE=""
if [[ "$CLI" =~ $WATCHED ]]; then
  MODE="ops"
elif [[ "$CLI" =~ $GREP_CMDS ]] && [[ "$STRIPPED" =~ $MEMORY_PATH_RX ]]; then
  MODE="grep_memory"
else
  echo '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"allow"}}'
  echo "SKIP: cli=$CLI (mode=none — not ops; not grep-on-memory)" >> "$DEBUG_LOG"
  exit 0
fi

# --- Extract the query to feed memory-search ---
QUERY=""
PATTERN=""
if [ "$MODE" = "ops" ]; then
  QUERY="$CLI $SUBCMD"
else
  # grep-family — extract the search pattern (first non-flag arg after grep/rg/ag)
  # python is cleaner than bash for arg parsing with quotes
  PATTERN=$(python3 - "$STRIPPED" <<'PY' 2>/dev/null
import shlex, sys
try:
    tokens = shlex.split(sys.argv[1])
except ValueError:
    tokens = sys.argv[1].split()
# Skip the grep CLI and any flags (start with '-')
seen_cli = False
for t in tokens:
    if not seen_cli:
        seen_cli = True
        continue
    # Skip flag tokens like -E, -r, --line-number, --include=*.md
    if t.startswith('-'):
        continue
    # Skip -e PATTERN style — handled by skipping flags then taking next
    print(t)
    break
PY
)
  QUERY="$PATTERN"
fi
echo "MODE: $MODE  QUERY: $QUERY" >> "$DEBUG_LOG"

# --- Run memory-search ---
RESULTS=""
if [ -x "$MEMORY_SEARCH" ] && [ -n "$QUERY" ]; then
  RESULTS=$("$MEMORY_SEARCH" "$QUERY" --budget=4000 --k=3 2>/dev/null || echo "")
fi

# --- Structural-index hits (ops mode only) ---
STRUCT_HITS=""
if [ "$MODE" = "ops" ] && [ -f "$INDEX_DB" ]; then
  STRUCT_HITS=$(sqlite3 "$INDEX_DB" "SELECT mf.project || '/' || mf.file FROM surface_map sm JOIN memory_file mf ON mf.id=sm.memory_id WHERE sm.surface_kind='command' AND sm.surface_value LIKE '${CLI}%' ORDER BY sm.occurrences DESC LIMIT 5;" 2>/dev/null)
fi

# --- Decide whether to emit context ---
HAS_RESULTS=0
[ -n "$RESULTS" ] && [ "$(echo "$RESULTS" | wc -c)" -ge 200 ] && HAS_RESULTS=1

if [ "$MODE" = "ops" ] && [ "$HAS_RESULTS" = "0" ] && [ -z "$STRUCT_HITS" ]; then
  echo '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"allow"}}'
  echo "NO_HITS: silent allow (ops)" >> "$DEBUG_LOG"
  exit 0
fi
# grep_memory: always emit context (even if RESULTS is empty) because the digest-layer
# warning itself is the value of the intercept

# --- Build the surfaced context block ---
if [ "$MODE" = "ops" ]; then
  CONTEXT_BLOCK="<memory-pretool-check cli=\"$CLI\" subcmd=\"$SUBCMD\">

This text was injected by the PreToolUse hook because the next Bash call invokes \`$CLI\`, a CLI with operator-curated patterns in memory. **Review the hits below BEFORE the call lands** — there may be documented quirks, project IDs, scope/auth requirements, or anti-patterns to avoid.

"
  if [ -n "$STRUCT_HITS" ]; then
    CONTEXT_BLOCK+="## Structural-index hits (files known to use \`$CLI\`):
$STRUCT_HITS

"
  fi
  if [ "$HAS_RESULTS" = "1" ]; then
    CONTEXT_BLOCK+="## memory-search BM25 hits for \"$QUERY\":
$RESULTS

"
  fi
else
  # grep_memory branch
  CONTEXT_BLOCK="<memory-pretool-check mode=\"grep-on-memory\" cli=\"$CLI\" pattern=\"$PATTERN\">

You are about to run \`$CLI\` against memory or tmux-log directories. **Raw \`$CLI\` cannot see the \`_digests\` synthetic project** (per-day transcript-distilled digests) — those are only reachable via \`memory-search\`. Decisions and operator commitments frequently live in the digest layer, not in individual memory files.

**Recommended:** Replace this \`$CLI\` with a \`memory-search\` call FIRST. The digest-aware retrieval below was run automatically against your search pattern. If it surfaced what you need, skip the \`$CLI\` invocation; otherwise the call still proceeds.

  \`\`\`
  ~/.bin/memory-search.mjs '$PATTERN' --budget=8000 --k=6
  \`\`\`

"
  if [ "$HAS_RESULTS" = "1" ]; then
    CONTEXT_BLOCK+="## memory-search BM25 hits for \"$PATTERN\":
$RESULTS

"
  else
    CONTEXT_BLOCK+="## memory-search returned no hits for \"$PATTERN\"
The pattern may be too specific, or the relevant content may genuinely live only in raw transcripts/tmux-logs (Tier 2 firehose, indexed but not BM25-prioritized). After your \`$CLI\` runs, consider widening the query and re-running \`memory-search\`.

"
  fi
fi

CONTEXT_BLOCK+="</memory-pretool-check>"

# Emit hook envelope — allow the call but surface the context
OUTPUT=$(python3 -c "
import json, sys
note = sys.stdin.read()
print(json.dumps({
  'hookSpecificOutput': {
    'hookEventName': 'PreToolUse',
    'permissionDecision': 'allow',
    'additionalContext': note
  }
}))
" <<< "$CONTEXT_BLOCK" 2>>"$DEBUG_LOG")

{
  echo "EMITTED: ${#OUTPUT} bytes, RESULTS=${#RESULTS} bytes, STRUCT=${#STRUCT_HITS} bytes"
  echo "---"
} >> "$DEBUG_LOG"

echo "$OUTPUT"
exit 0
