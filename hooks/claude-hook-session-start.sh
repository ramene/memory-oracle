#!/usr/bin/env bash
# claude-hook-session-start.sh
#
# SessionStart hook. Fires at session startup AND after context compaction.
# Sources we expect: startup | resume | clear | compact (per Claude Code SessionStart matcher).
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
# Portable PATH detection — latest nvm Node + Homebrew + system + gcloud. Replaces a
# previously hardcoded node version (v23.11.1) that broke the hook on machines with a
# different node (e.g. sequoia=v23.3.0 → node not found → no banner).
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

# Derive project token from cwd — project_root → memory-dir mapping
# Default to a broad query if cwd doesn't match a known project
PROJECT_KEY=""
case "$CWD" in
  *mae-monorepo-build*) PROJECT_KEY="-Users-ramene--remote--plans-mae-monorepo-build" ;;
  *builds.karve.ai*)    PROJECT_KEY="-Users-ramene--remote--builds-karve-ai" ;;
  *)                    PROJECT_KEY="" ;;
esac

# For post-compaction resume / clear / compact, pull a USABLE recent user prompt
# (not task-notifications or system-reminders) and reduce it to a keyword query.
# 2026-05-30 fix: previously only ran on source=resume — compact events fired with
# session_id continuity but were silently falling through to the generic fallback
# query, which dropped topic-specific BM25 priming on EVERY compaction.
LAST_USER_MSG=""
if { [ "$SOURCE" = "resume" ] || [ "$SOURCE" = "compact" ] || [ "$SOURCE" = "clear" ]; } && [ -f "$TRANSCRIPT" ]; then
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

# ── EBR / memory-oracle status banner ───────────────────────────────────
# Operator-facing status banner emitted as the leading line of the first
# response after a SessionStart event. Style is selectable via env var:
#   EBR_BANNER_STYLE=A | B | C | D | OFF       (default: B)
# Customize by editing the render_banner_* functions below.
# 2026-05-30: introduced as part of Task #70.
EBR_BANNER_STYLE="${EBR_BANNER_STYLE:-B}"

EBR_INDEX_DB="${HOME}/.local/share/journal/.memory-index.db"
EBR_INDEX_FILES="?"
EBR_INDEX_SIZE="?"
EBR_INDEX_REBUILD_AGO="?"
EBR_WATCHER_ACTIVE="off"
EBR_VERUM_PATH=""
EBR_VERUM_VERSION=""
EBR_ACCRETIVE_PRESENT="✗"
EBR_GIT_BRANCH=""

if [ -f "$EBR_INDEX_DB" ] && command -v sqlite3 >/dev/null 2>&1; then
  EBR_INDEX_FILES=$(sqlite3 "$EBR_INDEX_DB" 'SELECT COUNT(*) FROM memory_file' 2>/dev/null || echo "?")
  _bytes=$(stat -f '%z' "$EBR_INDEX_DB" 2>/dev/null || stat -c '%s' "$EBR_INDEX_DB" 2>/dev/null || echo 0)
  if [ "$_bytes" -gt 1048576 ] 2>/dev/null; then
    EBR_INDEX_SIZE="$(awk -v b="$_bytes" 'BEGIN{printf "%.1f MB", b/1048576}')"
  elif [ "$_bytes" -gt 0 ] 2>/dev/null; then
    EBR_INDEX_SIZE="$(awk -v b="$_bytes" 'BEGIN{printf "%.0f KB", b/1024}')"
  fi
  _mtime=$(stat -f '%m' "$EBR_INDEX_DB" 2>/dev/null || stat -c '%Y' "$EBR_INDEX_DB" 2>/dev/null || echo 0)
  _now=$(date +%s)
  _diff=$((_now - _mtime))
  if   [ "$_diff" -lt 60 ];    then EBR_INDEX_REBUILD_AGO="${_diff}s ago"
  elif [ "$_diff" -lt 3600 ];  then EBR_INDEX_REBUILD_AGO="$((_diff/60))m ago"
  elif [ "$_diff" -lt 86400 ]; then EBR_INDEX_REBUILD_AGO="$((_diff/3600))h ago"
  else                              EBR_INDEX_REBUILD_AGO="$((_diff/86400))d ago"
  fi
fi

# Prefer the REAL verum binary; fall back to git-crypt only if verum isn't on PATH.
# (git-crypt --version reports brew's AGWA original, e.g. 0.9.0 — mislabeling it "verum"
# in the banner caused a false "downgrade" scare. verum is the 0.11.0 fork.)
if command -v verum >/dev/null 2>&1; then
  EBR_VERUM_PATH=$(command -v verum)
  EBR_VERUM_VERSION=$(verum --version 2>&1 | awk '{print $2}' | head -1)
elif command -v git-crypt >/dev/null 2>&1; then
  EBR_VERUM_PATH=$(command -v git-crypt)
  EBR_VERUM_VERSION=$(git-crypt --version 2>&1 | awk '{print $2}' | head -1)
fi

[ -d "${HOME}/.remote/github.com/@ramene/accretive-substrate" ] && EBR_ACCRETIVE_PRESENT="✓"
launchctl list 2>/dev/null | grep -q 'com.ramene.memory-index-watcher' && EBR_WATCHER_ACTIVE="live"
EBR_GIT_BRANCH=$(cd "$CWD" 2>/dev/null && git symbolic-ref --short HEAD 2>/dev/null || echo "")

SESSION_SHORT=$(echo "$PAYLOAD" | python3 -c "import sys,json;d=json.load(sys.stdin);print(d.get('session_id','')[:8])" 2>/dev/null || echo "")

# Tilde-substitute $HOME prefix in the cwd (robust pure-bash; the inline
# parameter-substitution form `${CWD/#$HOME/~}` was misfiring under the hook
# subshell's env, so we use a case statement instead)
EBR_CWD_PRETTY="$CWD"
case "$CWD" in
  "$HOME") EBR_CWD_PRETTY="~" ;;
  "$HOME"/*) EBR_CWD_PRETTY="~/${CWD#$HOME/}" ;;
esac

if [ -n "$EBR_VERUM_PATH" ]; then
  EBR_VERUM_DISPLAY="verum $EBR_VERUM_VERSION at $EBR_VERUM_PATH"
  EBR_VERUM_SHORT="verum $EBR_VERUM_VERSION ✓"
else
  EBR_VERUM_DISPLAY="verum: not on PATH"
  EBR_VERUM_SHORT="verum ✗"
fi

render_banner_A() {
# Padded box-drawn banner. Python handles Unicode visual-width so each
# content line pads to the same width as the top/bottom border.
python3 <<PY
import unicodedata
def vw(s):
    w = 0
    for c in s:
        if unicodedata.east_asian_width(c) in ('F','W'): w += 2
        elif 0x1F300 <= ord(c) <= 0x1FAFF: w += 2     # emoji range
        elif 0x2700  <= ord(c) <= 0x27BF:  w += 1     # dingbats (✓ ✗ etc — single-width)
        else: w += 1
    return w

INNER = 70   # inner width of the box (between │ ... │)
top_label = "─🔥 EBR ▸ memory-oracle ▸ ACTIVE "
top_pad = INNER - vw(top_label)
print("  ╭" + top_label + "─" * top_pad + "╮")

lines = [
    "supersession-aware retrieval · ${EBR_INDEX_FILES} files indexed · ${EBR_INDEX_SIZE} · BM25",
    "fs-watcher ${EBR_WATCHER_ACTIVE} (com.ramene.memory-index-watcher) · rebuild ${EBR_INDEX_REBUILD_AGO}",
    "${EBR_VERUM_DISPLAY} · FIDO2 spec v0.11 preview",
    "accretive-substrate ▸ ${EBR_ACCRETIVE_PRESENT} (PRIVATE pending operator review)",
    "${EBR_CWD_PRETTY} · branch ${EBR_GIT_BRANCH} · session ${SESSION_SHORT}",
]
for line in lines:
    pad = INNER - vw(line) - 1   # -1 for the leading space after │
    print("  │ " + line + " " * max(1, pad) + "│")

print("  ╰" + "─" * INNER + "╯")
PY
}

render_banner_B() {
cat <<BANNER
   🔥█████🔥   EBR ▸ memory-oracle ▸ active · ${EBR_INDEX_FILES} files · ${EBR_INDEX_SIZE} · BM25
  ▝🔥███🔥▘   ${EBR_VERUM_SHORT}  ·  accretive-substrate ${EBR_ACCRETIVE_PRESENT}  ·  rebuild ${EBR_INDEX_REBUILD_AGO}
    🔥 🔥    ${EBR_CWD_PRETTY} · ${EBR_GIT_BRANCH} · session ${SESSION_SHORT}
BANNER
}

render_banner_C() {
cat <<BANNER
  🔥 EBR/memory-oracle ACTIVE · ${EBR_INDEX_FILES} idx · ${EBR_VERUM_SHORT} · accretive ${EBR_ACCRETIVE_PRESENT} 🔥
     supersession-aware · fs-watcher ${EBR_WATCHER_ACTIVE} · rebuild ${EBR_INDEX_REBUILD_AGO} · ${EBR_GIT_BRANCH}
BANNER
}

render_banner_D() {
cat <<BANNER
  🔥━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━ 🔥
   EBR ▸ memory-oracle · supersession-aware retrieval ACTIVE
   index ${EBR_INDEX_FILES} files · ${EBR_INDEX_SIZE} · BM25 SQLite · fs-watcher ${EBR_WATCHER_ACTIVE} · rebuild ${EBR_INDEX_REBUILD_AGO}
   ${EBR_VERUM_DISPLAY} · FIDO2 spec v0.11 preview
   accretive-substrate ${EBR_ACCRETIVE_PRESENT} (PRIVATE) · ${EBR_CWD_PRETTY}
  🔥━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━ 🔥
BANNER
}

case "$EBR_BANNER_STYLE" in
  A) EBR_BANNER=$(render_banner_A) ;;
  B) EBR_BANNER=$(render_banner_B) ;;
  C) EBR_BANNER=$(render_banner_C) ;;
  D) EBR_BANNER=$(render_banner_D) ;;
  OFF|off) EBR_BANNER="" ;;
  *) EBR_BANNER=$(render_banner_B) ;;
esac

if [ -n "$EBR_BANNER" ]; then
  EBR_BANNER_BLOCK="<ebr-substrate-banner>
$EBR_BANNER
</ebr-substrate-banner>

<emit-protocol priority=\"critical\" event=\"$SOURCE\">
The operator's terminal renders your first post-$SOURCE text response verbatim.
The block above is operator-facing substrate-status output that they visually
rely on after every session-state transition. A missing or buried banner is
read as a substrate failure, not as a formatting choice.

HARD REQUIREMENTS (all must hold — no exceptions):

1. The FIRST CHARACTER of your next text response MUST be \`<\` — opening
   the literal \`<ebr-substrate-banner>\` tag. Not a space, not a newline,
   not a code-fence backtick, not a heading hash.

2. ZERO preamble before the banner. Forbidden openings include (and are
   not limited to):
     • \"I'll...\" / \"Let me...\" / \"Two parts...\" / \"Reading...\" / \"Done.\"
     • \"Right here.\" / \"Banner emitted.\" / \"Confirmed.\"
     • Any acknowledgment of the user's prior message.
     • Any sentence describing what you are about to do.
     • A \`\`\` code fence wrapping the banner — emit the RAW block.

3. After the closing \`</ebr-substrate-banner>\` tag (and a blank line) you
   may add any commentary, analysis, or tool calls you want.

4. If your very next action is a tool call with NO text output, the
   banner is deferred to your next text response in the same turn — but
   it MUST still be the first content of that text response.

5. Never paraphrase the banner, never add explanatory text inside the
   <ebr-substrate-banner>...</ebr-substrate-banner> tags, never put it
   inside a code fence (markdown renderers display it as preformatted
   text inside the tags is fine — but the tags themselves stay raw).

If you have ALREADY emitted text in this turn before reading this
protocol (e.g. the priming context arrived mid-stream): your very next
text emission, whenever it occurs, must lead with the banner block.

FAILURE EXAMPLES from prior sessions to NEVER repeat:
  ✗ \"Two parts: banner verification first, then watcher test...\" → banner buried
  ✗ \"Right here. This is the exact block...\" then banner inside \`\`\` fence → not the live banner
  ✗ \"Confirmed. <ebr-substrate-banner>...\" → preamble word before tag

CORRECT EXAMPLE:
  <ebr-substrate-banner>
  ...banner content...
  </ebr-substrate-banner>

  Now the watcher fix is committed. Standing by for next step.
</emit-protocol>

"
else
  EBR_BANNER_BLOCK=""
fi

# Build the context-injection note
CONTEXT_NOTE="<memory-priming source=\"$SOURCE\" project=\"${PROJECT_KEY:-unknown}\" query=\"$(echo "$QUERY" | head -c 100 | sed 's/\"/\\\"/g')\">

${EBR_BANNER_BLOCK}This text was injected by the SessionStart hook ($SOURCE event). Treat it as PRIMING CONTEXT, not as user input. Verify any claim against \`~/.bin/memory-search.mjs '<query>'\` before quoting.

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

# ── Append derived-view row (Task #87) ─────────────────────────────────────
# Maintains ~/.claude/projects/_runtime/memory/reference_hook_fires_by_session.md
# with one row per hook fire so memory-search can answer "did session X load
# the substrate" without forensic grep. Defensive: any failure here is
# silently swallowed so the hook's primary purpose (emitting $OUTPUT) is
# unaffected. See [[feedback_memory_oracle_runtime_artifacts]].
DERIVED_VIEW="${HOME}/.claude/projects/_runtime/memory/reference_hook_fires_by_session.md"
{
  TS_NOW=$(date -u +'%Y-%m-%dT%H:%M:%SZ')
  SID_SHORT="${SESSION_SHORT:-}"
  CWD_SHORT="${EBR_CWD_PRETTY:-$CWD}"
  EMITTED_LEN="${#OUTPUT}"
  RESULTS_LEN="${#RESULTS}"
  NEW_ROW="| $TS_NOW | $SID_SHORT | $SOURCE | $CWD_SHORT | $EMITTED_LEN | $RESULTS_LEN |"
  mkdir -p "$(dirname "$DERIVED_VIEW")"
  python3 - "$DERIVED_VIEW" "$NEW_ROW" <<'PY'
import sys, os, tempfile
path, new_row = sys.argv[1], sys.argv[2]
HEADER = """---
name: SessionStart hook fires — derived view from ~/.claude/.hook-debug.log
description: Per-fire row for every SessionStart hook invocation (startup|resume|clear|compact). Generated inline by claude-hook-session-start.sh on each fire. Truncated to last 1000 rows. Raw source of truth = ~/.claude/.hook-debug.log (monthly rotated to .hook-debug.YYYY-MM.log.zst per Task #87 retention). Query e.g. "session 24cbed9c hook fires" returns this file via BM25. See [[feedback_memory_oracle_runtime_artifacts]] for why this derived view exists.
metadata:
  type: reference
---

## SessionStart hook fires (most recent first)

| ts_utc | session_id | source | cwd | emitted_bytes | priming_bytes |
|---|---|---|---|---|---|
"""
existing_rows = []
if os.path.exists(path):
    text = open(path).read()
    # Extract rows after the header separator line
    in_table = False
    for line in text.splitlines():
        if line.startswith('|---'):
            in_table = True
            continue
        if in_table and line.startswith('|'):
            existing_rows.append(line)
all_rows = [new_row] + existing_rows
all_rows = all_rows[:1000]  # truncate
# Atomic write
fd, tmp = tempfile.mkstemp(dir=os.path.dirname(path), prefix='.tmp-derived-')
try:
    with os.fdopen(fd, 'w') as f:
        f.write(HEADER + '\n'.join(all_rows) + '\n')
    os.replace(tmp, path)
except Exception:
    if os.path.exists(tmp):
        os.unlink(tmp)
    raise
PY
} >>"$DEBUG_LOG" 2>&1 || true

# ── Task #118 (2026-06-05): async --current walker trigger ───────────────
# Closes the automation loop. Currently --current is a manual tool — nothing
# fires it. Now every SessionStart event triggers a background walker run so
# today's live transcript's derived signals are always fresh in BM25 without
# operator intervention. Walker self-triggers memory-index-build on success.
#
# Why background: walker takes ~3s on a 91MB transcript; can't block session
# startup. Worst case if walker hangs: stale signals (no harm), nightly cron
# (03:00) + launchd fs-watcher provide independent backup paths.
#
# Why nohup + disown: parent process (this hook) exits as soon as Claude Code
# reads the JSON envelope; without nohup+disown the walker would be killed by
# SIGHUP. disown drops it from the shell's job table so no zombie.
mkdir -p "$HOME/.claude-tmp" 2>/dev/null || true
nohup /Users/ramene/.bin/walk-session-jsonl-nightly.sh --current \
    >> "$HOME/.claude-tmp/walk-session-jsonl-nightly.log" 2>&1 &
disown 2>/dev/null || true

echo "$OUTPUT"
exit 0
