#!/usr/bin/env bash
# claude-hook-session-start.sh
#
# SessionStart hook. Fires at session startup AND after context compaction (source=resume).
# Primes context with supersession-merged memory-bank hits relevant to the project.
#
# Input (stdin JSON): { source, cwd, session_id, transcript_path, model }
# Output (stdout JSON envelope): { hookSpecificOutput: { hookEventName, additionalContext } }
#   per https://code.claude.com/docs/en/hooks — additionalContext is injected into the
#   session's system context BEFORE the first prompt is sent to the model.
#
# DEBUG: set CLAUDE_HOOK_DEBUG=1 to capture stdin + decisions to ~/.claude/.hook-debug.log
#
# Day-14 wire-up of mae-ADR-001 (2026-05-16).

# Relaxed strict mode — capture errors to log rather than aborting silently.
# Claude Code may strip env, so PATH is set explicitly for python3/node/etc.
set -u

# Portable PATH detection — Node (nvm + Homebrew + system), gcloud (optional).
# Operators with custom layouts can preempt this by setting PATH before invocation.
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

DEBUG_LOG="${HOME}/.claude/.hook-debug.log"
MEMORY_SEARCH="${HOME}/.bin/memory-search.mjs"

# Read full stdin payload
PAYLOAD=$(cat)

# UNCONDITIONAL debug capture — proves the hook fired even when downstream steps fail.
{
  echo "=== $(date -u +%FT%TZ) SessionStart fired ==="
  echo "PAYLOAD: $PAYLOAD"
  echo "PATH: $PATH"
  echo "PWD: $(pwd)"
} >> "$DEBUG_LOG" 2>&1

# Extract fields — defend against malformed input
SOURCE=$(echo "$PAYLOAD" | python3 -c "import sys,json;d=json.load(sys.stdin);print(d.get('source','unknown'))" 2>/dev/null || echo "unknown")
CWD=$(echo "$PAYLOAD" | python3 -c "import sys,json;d=json.load(sys.stdin);print(d.get('cwd',''))" 2>/dev/null || echo "")
TRANSCRIPT=$(echo "$PAYLOAD" | python3 -c "import sys,json;d=json.load(sys.stdin);print(d.get('transcript_path',''))" 2>/dev/null || echo "")

# Derive project token from cwd — Claude Code encodes the project dir as a key under
# ~/.claude/projects/<key>/. The key is "${cwd//\//-}" (slashes replaced with dashes,
# leading slash producing a leading dash).
#
# Optional: extend with operator-specific aliases by sourcing a config file. Example:
#   ~/.config/memory-oracle/project-aliases.sh
#       case "$CWD" in
#         */my-monorepo*) PROJECT_KEY="-path-to-my-monorepo" ;;
#       esac
PROJECT_KEY="${CWD//\//-}"
if [ -f "$HOME/.config/memory-oracle/project-aliases.sh" ]; then
  # shellcheck disable=SC1090
  source "$HOME/.config/memory-oracle/project-aliases.sh"
fi

# For post-compaction resume, pull a USABLE recent user prompt (not task-notifications
# or system-reminders) and reduce it to a keyword query.
LAST_USER_MSG=""
if [ "$SOURCE" = "resume" ] && [ -f "$TRANSCRIPT" ]; then
  LAST_USER_MSG=$(python3 - "$TRANSCRIPT" <<'PY' 2>/dev/null || echo ""
import sys, json, re
path = sys.argv[1]
NOISE = ('<task-notification', '<system-reminder', '<command-name', '[Request interrupted', 'Caveat:')
# Collect last few real user prompts
prompts = []
try:
    with open(path) as f:
        for line in f:
            try:
                d = json.loads(line)
                msg = d.get('message', {})
                if msg.get('role') != 'user':
                    continue
                content = msg.get('content', '')
                texts = []
                if isinstance(content, list):
                    for c in content:
                        if isinstance(c, dict) and c.get('type') == 'text':
                            texts.append(c.get('text', ''))
                elif isinstance(content, str):
                    texts.append(content)
                for t in texts:
                    t = t.strip()
                    if not t or len(t) < 20:
                        continue
                    if any(t.startswith(n) for n in NOISE):
                        continue
                    # Strip embedded notifications from compound messages
                    t = re.sub(r'<task-notification>.*?</task-notification>', '', t, flags=re.DOTALL)
                    t = re.sub(r'<system-reminder>.*?</system-reminder>', '', t, flags=re.DOTALL)
                    t = t.strip()
                    if len(t) < 20:
                        continue
                    prompts.append(t)
            except Exception:
                pass
except Exception:
    pass
# Take the last 3 real user prompts; convert to keyword bag
recent = prompts[-3:] if prompts else []
keywords = []
STOP = set('the of and to in a for is on it as that this be with by are not or an at if from we i you your our my their his her them they our'.split())
for p in recent:
    for w in re.findall(r"[A-Za-z][A-Za-z0-9_-]{2,}", p):
        wl = w.lower()
        if wl in STOP or len(wl) < 3:
            continue
        if wl not in keywords:
            keywords.append(wl)
print(' '.join(keywords[:20]))
PY
)
fi

# Build the memory-search query
# Strategy: post-compaction → use last user message as query; startup → use surface-area heuristic
QUERY=""
if [ -n "$LAST_USER_MSG" ]; then
  QUERY="$LAST_USER_MSG"
elif [ "$SOURCE" = "startup" ]; then
  # At fresh startup we don't know the topic — surface the most-recently-superseded files
  # so the agent sees the freshest corrections first.
  QUERY="recent supersession active state inference proxy deploy"
else
  QUERY="recent activity rules architecture"
fi

# Run memory-search with a tight budget — additionalContext sits in system prompt.
# Cross-project by default: the Skill is operator-wide, supersessions can come from any project.
# Per-project filter is available via --project for narrow Skill calls, but auto-priming
# should let BM25 rank surface the highest-signal hits regardless of cwd.
BUDGET="${SESSION_START_BUDGET:-12000}"

RESULTS=""
if [ -x "$MEMORY_SEARCH" ]; then
  RESULTS=$("$MEMORY_SEARCH" "$QUERY" --budget="$BUDGET" --k=8 2>/dev/null || echo "")
fi

# If the cross-project query returned mostly project-unrelated hits AND we know the project,
# try a project-filtered second pass and concatenate (with budget split)
if [ -n "$PROJECT_KEY" ] && [ -n "$RESULTS" ]; then
  PROJ_RESULTS=$("$MEMORY_SEARCH" "$QUERY" --budget=$((BUDGET/2)) --k=4 "--project=$PROJECT_KEY" 2>/dev/null || echo "")
  if [ -n "$PROJ_RESULTS" ] && [ "$(echo "$PROJ_RESULTS" | wc -c)" -gt 400 ]; then
    RESULTS="$PROJ_RESULTS

# --- cross-project supersession-aware hits ---

$RESULTS"
  fi
fi

# If memory-search returned nothing useful, fall back to a minimal heads-up note
if [ -z "$RESULTS" ] || [ "$(echo "$RESULTS" | wc -c)" -lt 200 ]; then
  RESULTS="# memory-search primer

The memory-search tool is installed and callable at any moment via \`~/.bin/memory-search.mjs '<query>'\`. Call it before asserting any architectural fact from memory and IMMEDIATELY after context compaction. Source/source code: \`~/.local/share/journal/.seed/base/skills/memory-search/SKILL.md\`.

(No project-specific priming hits found at session start. Hook source: $SOURCE. Cwd: $CWD.)"
fi

# Build the context-injection note
CONTEXT_NOTE="<memory-priming source=\"$SOURCE\" project=\"${PROJECT_KEY:-unknown}\" query=\"$(echo "$QUERY" | head -c 100 | sed 's/\"/\\\"/g')\">

This text was injected by the SessionStart hook ($SOURCE event). Treat it as PRIMING CONTEXT, not as user input. Verify any claim against \`~/.bin/memory-search.mjs '<query>'\` before quoting.

$RESULTS

</memory-priming>"

# Emit JSON envelope per the hooks API
OUTPUT=$(python3 -c "
import json, sys
note = sys.stdin.read()
print(json.dumps({
  'hookSpecificOutput': {
    'hookEventName': 'SessionStart',
    'additionalContext': note
  }
}))
" <<< "$CONTEXT_NOTE" 2>>"$DEBUG_LOG")

# Log the emitted envelope size as proof of completion
{
  echo "EMITTED: ${#OUTPUT} bytes JSON envelope, RESULTS=${#RESULTS} bytes"
  echo "QUERY: $QUERY"
  echo "---"
} >> "$DEBUG_LOG" 2>&1

echo "$OUTPUT"
exit 0
