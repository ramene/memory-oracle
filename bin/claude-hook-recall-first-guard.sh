#!/usr/bin/env bash
# recall-first-guard — PreToolUse Bash gate (built 2026-07-14 at operator's direction).
#
# THE PROBLEM IT SOLVES: the agent keeps INVENTING an approach for a task that already has a PROVEN
# recipe in the substrate (video ingest, watch-video-scope, daemon build, sync, verum…), instead of
# `substrate search`-ing for the working recipe first. Prompt-level laws didn't make it stick.
#
# THE MECHANISM: for recipe-governed commands, this gate BLOCKS unless a substrate/memory recall
# happened in the last RECALL_TTL seconds. It's self-contained — it watches the command stream and
# refreshes a marker whenever a recall command passes through. No way to run the recipe cold.
#
# Exit 0 = allow. Exit 2 = block (stderr becomes the reason shown to the agent).
set -uo pipefail
MARKER="$HOME/.local/state/.last-recall"
RECALL_TTL=180

INPUT=$(cat)
CMD=$(printf '%s' "$INPUT" | python3 -c 'import sys,json
try:
    d=json.load(sys.stdin); print(d.get("tool_input",{}).get("command","") or "")
except Exception:
    print("")' 2>/dev/null)
[ -z "$CMD" ] && exit 0

# 1) A RECALL command → stamp the marker, always allow.
if printf '%s' "$CMD" | grep -qiE 'substrate[[:space:]]+search|memory-search|memory-cite'; then
  mkdir -p "$(dirname "$MARKER")" 2>/dev/null; : > "$MARKER"; exit 0
fi

# 2) Recipe-governed operations — each has a PROVEN approach in the substrate the agent keeps re-inventing.
RECIPE='watch-video|video-scope|video-lesson|latest-test|ingest\.mjs|--intent[[:space:]]|asciinema|screencapture|gemini|generativelanguage|cwa-transcribe|render_lesson|GOROOT|go[[:space:]]+build|GOOS=|substrate-daemon|arch-notes-sync|vault-autosync|brain-sync|watch-video-scope|git-crypt'
if printf '%s' "$CMD" | grep -qiE "$RECIPE"; then
  if [ -f "$MARKER" ]; then
    now=$(date +%s); m=$(stat -f %m "$MARKER" 2>/dev/null || stat -c %Y "$MARKER" 2>/dev/null || echo 0)
    age=$(( now - m ))
  else
    age=999999
  fi
  if [ "$age" -gt "$RECALL_TTL" ]; then
    {
      echo "🛑 RECALL-FIRST LAW (recall-first-guard): this is a RECIPE-GOVERNED operation and you have"
      echo "   NOT recalled from the substrate in the last ${RECALL_TTL}s. There is almost certainly a"
      echo "   PROVEN working recipe you are about to reinvent."
      echo ""
      echo "   DO THIS FIRST, then re-run your command:"
      echo "     substrate search \"<the operation, in the codebase's own words>\""
      echo "   (or ~/.bin/memory-search.mjs \"...\")  — read the canonical command / gotchas, use THOSE."
      echo ""
      echo "   You keep inventing instead of using the working approach; this gate is the fix you asked for."
    } >&2
    exit 2
  fi
fi
exit 0
