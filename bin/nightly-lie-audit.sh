#!/bin/bash
# nightly-lie-audit.sh — empirical substrate-state vs claims audit.
#
# Runs at 23:50 noodles (before the 23:55 digest builder so output is
# ingestible by the digest). Five empirical checks, each producing PASS /
# FAIL with optional auto-fix:
#
#   1. UPSTREAM-PARITY  for tracked ~/.remote/github.com/@ramene/ repos
#   2. VAULT-SUBMOD     integrity (pointer ↔ submodule HEAD ↔ working tree)
#   3. CLUSTER-CODE     parity (md5 ~/.bin/<tool> across noodles+sequoia+tunafish)
#   4. CARDS-PROPAGATION today's memory cards present on peers
#   5. MAE-PLUGIN       main.js md5 parity across all 3 nodes
#
# Safe fixes auto-applied (git pull, brain-sync, push fast-forward, install.sh deploy).
# Unsafe fixes (force-push, --reset-hard, anything destructive) → MORNING BRIEF
# action items the operator reviews + decides on.
#
# Earned 2026-06-27 after a session where the operator caught 5 unverified
# claims that compounded into operator-facing failures. See:
#   feedback_verify_push_landed_not_just_script_output.md  (the canonical rule)
#
# Output:
#   JSON report: ~/.claude-tmp/lie-audit-YYYY-MM-DD.json
#   Digest appendix appended to: ~/.local/share/journal/_digests/YYYY-MM-DD.md
#   Memory card written ONLY when lies found:
#     ~/.claude/projects/_global/memory/feedback_nightly_lie_audit_YYYY-MM-DD.md
#
# Usage:
#   nightly-lie-audit.sh                    # full run, apply safe fixes
#   nightly-lie-audit.sh --no-fix           # report-only, no auto-apply
#   nightly-lie-audit.sh --dry-run          # show what would be checked
#   nightly-lie-audit.sh --json             # JSON-only output to stdout

set -uo pipefail

NO_FIX=0
DRY=0
JSON_ONLY=0
# Use LOCAL date (operator's "tonight" is local-time, and digest builder
# uses local date for its filename — keep these aligned).
DATE=$(date +%Y-%m-%d)
TIMESTAMP=$(date -u +%Y-%m-%dT%H:%M:%SZ)
JSON_REPORT="${HOME}/.claude-tmp/lie-audit-${DATE}.json"
DIGEST_PATH="${HOME}/.local/share/journal/_digests/${DATE}.md"
CARDS_DIR="${HOME}/.claude/projects/_global/memory"

for arg in "$@"; do
  case "$arg" in
    --no-fix) NO_FIX=1 ;;
    --dry-run) DRY=1 ;;
    --json) JSON_ONLY=1 ;;
    -h|--help) sed -n '2,30p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
  esac
done

mkdir -p "$(dirname "$JSON_REPORT")"

# ─── machinery ────────────────────────────────────────────────────────────
declare -a LIES=()           # human-readable lie strings
declare -a FIXES_APPLIED=()  # what we auto-fixed
declare -a MORNING_BRIEF=()  # action items operator must review

log_lie() { LIES+=("$1"); [ "$JSON_ONLY" -eq 0 ] && echo "  ✗ LIE: $1" >&2; }
log_fix() { FIXES_APPLIED+=("$1"); [ "$JSON_ONLY" -eq 0 ] && echo "  ✓ FIX: $1" >&2; }
log_brief() { MORNING_BRIEF+=("$1"); [ "$JSON_ONLY" -eq 0 ] && echo "  ⏰ MORNING-BRIEF: $1" >&2; }

# ─── 1. UPSTREAM-PARITY for tracked repos ─────────────────────────────────
section() { [ "$JSON_ONLY" -eq 0 ] && echo -e "\n── $1 ──" >&2; }
section "1. UPSTREAM-PARITY (tracked repos)"
for repo_dir in "${HOME}/.remote/github.com/@ramene"/*/; do
  [ -d "$repo_dir/.git" ] || continue
  repo=$(basename "$repo_dir")
  [ "$DRY" -eq 1 ] && { echo "  [dry-run] would check $repo"; continue; }

  cd "$repo_dir" 2>/dev/null || continue
  git fetch -q origin main 2>/dev/null
  LOCAL=$(git rev-parse --short=8 HEAD 2>/dev/null)
  REMOTE=$(git rev-parse --short=8 origin/main 2>/dev/null)
  [ -z "$LOCAL" ] || [ -z "$REMOTE" ] && continue

  if [ "$LOCAL" != "$REMOTE" ]; then
    AHEAD=$(git rev-list --count origin/main..HEAD 2>/dev/null || echo 0)
    BEHIND=$(git rev-list --count HEAD..origin/main 2>/dev/null || echo 0)
    if [ "$AHEAD" -gt 0 ] && [ "$BEHIND" -eq 0 ]; then
      # We have local commits not on upstream — could be safe to push (fast-forward)
      log_lie "$repo: $AHEAD local commit(s) unpushed (local=$LOCAL upstream=$REMOTE)"
      if [ "$NO_FIX" -eq 0 ]; then
        if git push origin "main" 2>&1 | grep -q "main -> main"; then
          log_fix "$repo: pushed $AHEAD commit(s) to origin/main"
        else
          log_brief "$repo: push failed — manual investigation needed (local=$LOCAL upstream=$REMOTE)"
        fi
      else
        log_brief "$repo: $AHEAD unpushed commits (run git push manually)"
      fi
    elif [ "$BEHIND" -gt 0 ] && [ "$AHEAD" -eq 0 ]; then
      log_lie "$repo: $BEHIND upstream commit(s) unpulled (local=$LOCAL upstream=$REMOTE)"
      if [ "$NO_FIX" -eq 0 ]; then
        if git pull --rebase --autostash 2>&1 | grep -q "Fast-forward\|Successfully rebased"; then
          log_fix "$repo: pulled $BEHIND commit(s) from origin/main"
        else
          log_brief "$repo: pull failed — uncommitted changes or merge conflict; manual review"
        fi
      else
        log_brief "$repo: $BEHIND unpulled commits"
      fi
    else
      log_lie "$repo: DIVERGED (local=$LOCAL +$AHEAD upstream=$REMOTE +$BEHIND)"
      log_brief "$repo: diverged history — needs operator decision (force? merge? abandon?)"
    fi
  fi
done

# ─── 2. VAULT-SUBMOD integrity ────────────────────────────────────────────
section "2. VAULT-SUBMOD integrity"
VAULT="${HOME}/.remote/@vaults/.build/obsidian-vault"
if [ -d "$VAULT/.git" ]; then
  cd "$VAULT" 2>/dev/null
  while IFS= read -r line; do
    submod=$(echo "$line" | awk '{print $4}')
    expected=$(echo "$line" | awk '{print $3}' | cut -c1-8)
    if [ -d "$submod/.git" ] || [ -f "$submod/.git" ]; then
      actual=$(git -C "$submod" rev-parse --short=8 HEAD 2>/dev/null)
      if [ "$actual" != "$expected" ]; then
        log_lie "vault submodule $submod: recorded=$expected but checkout=$actual"
        if [ "$NO_FIX" -eq 0 ]; then
          if git submodule update --init --recursive "$submod" 2>&1 | grep -q "Submodule"; then
            log_fix "vault submodule $submod: synced to $expected"
          else
            log_brief "vault submodule $submod: update failed — manual review (likely uncommitted changes)"
          fi
        fi
      fi
    fi
  done < <(git ls-tree HEAD 2>/dev/null | grep '^160000')
fi

# ─── 3. CLUSTER-CODE parity ───────────────────────────────────────────────
section "3. CLUSTER-CODE parity (key tools across nodes)"
for tool in substrate-search walk-tmux-logs-nightly.sh walk-session-jsonl-nightly.sh \
            brain-sync.sh vault-autosync.sh vault-submod-push.sh memory-search.mjs \
            memory-cite.mjs memory-index-build.mjs vault-write-tx.sh; do
  noodles_md5=$(md5 -q "${HOME}/.bin/${tool}" 2>/dev/null)
  [ -z "$noodles_md5" ] && continue
  for peer in sequoia tunafish; do
    peer_md5=$(ssh -o ConnectTimeout=4 -o BatchMode=yes "$peer" "md5 -q ~/.bin/${tool} 2>/dev/null" 2>/dev/null)
    if [ -z "$peer_md5" ]; then
      log_lie "${tool} MISSING on $peer (noodles md5=${noodles_md5})"
      if [ "$NO_FIX" -eq 0 ]; then
        if ssh -o ConnectTimeout=8 "$peer" 'cd ~/.remote/github.com/@ramene/memory-oracle && git pull -q && ./install.sh' 2>&1 | grep -q "install complete"; then
          log_fix "${tool}: ran install.sh on $peer"
        else
          log_brief "${tool}: install.sh on $peer failed — manual deploy needed"
        fi
      fi
    elif [ "$peer_md5" != "$noodles_md5" ]; then
      log_lie "${tool} BYTE-DIVERGE on $peer (noodles=${noodles_md5} peer=${peer_md5})"
      if [ "$NO_FIX" -eq 0 ]; then
        if ssh -o ConnectTimeout=8 "$peer" 'cd ~/.remote/github.com/@ramene/memory-oracle && git pull -q && ./install.sh' 2>&1 | grep -q "install complete"; then
          log_fix "${tool}: re-installed on $peer (re-aligned md5)"
        else
          log_brief "${tool}: install.sh on $peer failed — manual review"
        fi
      fi
    fi
  done
done

# ─── 4. CARDS-PROPAGATION (today's memory cards on peers) ────────────────
section "4. CARDS-PROPAGATION (today's mtime)"
declare -a TODAYS_CARDS=()
while IFS= read -r card; do
  TODAYS_CARDS+=("$card")
done < <(find "${HOME}/.claude/projects" -name "*.md" -path "*/memory/*" -newermt "${DATE} 00:00" 2>/dev/null | head -50)

if [ ${#TODAYS_CARDS[@]} -gt 0 ]; then
  brain_sync_needed=0
  for card_path in "${TODAYS_CARDS[@]}"; do
    card_name=$(basename "$card_path")
    proj_segment=$(echo "$card_path" | sed -E 's|.*/projects/([^/]+)/memory/.*|\1|')
    for peer in sequoia tunafish; do
      peer_has=$(ssh -o ConnectTimeout=4 -o BatchMode=yes "$peer" "ls ~/.claude/projects/${proj_segment}/memory/${card_name} 2>/dev/null | wc -l" 2>/dev/null | tr -d ' ')
      [ "$peer_has" = "0" ] || [ -z "$peer_has" ] && {
        log_lie "card ${proj_segment}/${card_name} MISSING on $peer"
        brain_sync_needed=1
      }
    done
  done
  if [ "$brain_sync_needed" -eq 1 ] && [ "$NO_FIX" -eq 0 ]; then
    if BRAIN_MACHINES=local,sequoia,tunafish "${HOME}/.bin/brain-sync.sh" 2>&1 | grep -q "brain-sync done"; then
      log_fix "ran brain-sync to propagate today's cards"
    else
      log_brief "brain-sync failed — peers may be unreachable"
    fi
  fi
fi

# ─── 5. MAE-PLUGIN main.js parity ─────────────────────────────────────────
section "5. MAE-PLUGIN main.js parity"
MAE_PATH="${HOME}/.remote/@vaults/.build/obsidian-vault/.obsidian/plugins/mae/main.js"
if [ -f "$MAE_PATH" ]; then
  noodles_mae=$(md5 -q "$MAE_PATH" 2>/dev/null)
  for peer in sequoia tunafish; do
    peer_mae=$(ssh -o ConnectTimeout=4 -o BatchMode=yes "$peer" "md5 -q ~/.remote/@vaults/.build/obsidian-vault/.obsidian/plugins/mae/main.js 2>/dev/null" 2>/dev/null)
    if [ -z "$peer_mae" ]; then
      log_lie "mae plugin main.js MISSING on $peer"
      log_brief "mae plugin main.js missing on $peer — run vault pull there"
    elif [ "$peer_mae" != "$noodles_mae" ]; then
      log_lie "mae plugin main.js BYTE-DIVERGE on $peer (noodles=${noodles_mae} peer=${peer_mae})"
      if [ "$NO_FIX" -eq 0 ]; then
        if ssh -o ConnectTimeout=8 "$peer" 'cd ~/.remote/@vaults/.build/obsidian-vault && git pull --rebase --autostash --recurse-submodules' 2>&1 | tail -1 | grep -qiE "up to date|Fast-forward|Successfully"; then
          log_fix "vault pulled on $peer (re-aligned mae plugin)"
        else
          log_brief "vault pull on $peer failed — manual review"
        fi
      fi
    fi
  done
fi

# ─── REPORT ───────────────────────────────────────────────────────────────
# Generate JSON report
N_LIES=${#LIES[@]}
N_FIXES=${#FIXES_APPLIED[@]}
N_BRIEF=${#MORNING_BRIEF[@]}

# Use python3 for proper JSON quoting
# Safe array expansion (set -u tolerates empty arrays this way)
_LIES_JSON=$(printf '%s\n' "${LIES[@]+"${LIES[@]}"}" | /usr/local/bin/python3 -c 'import sys,json; print(json.dumps([l.rstrip() for l in sys.stdin if l.strip()]))')
_FIXES_JSON=$(printf '%s\n' "${FIXES_APPLIED[@]+"${FIXES_APPLIED[@]}"}" | /usr/local/bin/python3 -c 'import sys,json; print(json.dumps([l.rstrip() for l in sys.stdin if l.strip()]))')
_BRIEF_JSON=$(printf '%s\n' "${MORNING_BRIEF[@]+"${MORNING_BRIEF[@]}"}" | /usr/local/bin/python3 -c 'import sys,json; print(json.dumps([l.rstrip() for l in sys.stdin if l.strip()]))')

JSON=$(/usr/local/bin/python3 - <<PYEOF
import json
data = {
    "audit_date": "$DATE",
    "audit_timestamp": "$TIMESTAMP",
    "lies_caught": $N_LIES,
    "fixes_applied": $N_FIXES,
    "morning_brief_items": $N_BRIEF,
    "lies": $_LIES_JSON,
    "fixes": $_FIXES_JSON,
    "morning_brief": $_BRIEF_JSON
}
print(json.dumps(data, indent=2))
PYEOF
)
echo "$JSON" > "$JSON_REPORT"

if [ "$JSON_ONLY" -eq 1 ]; then
  cat "$JSON_REPORT"
  exit 0
fi

# Append to today's digest if it exists (or create stub)
if [ -f "$DIGEST_PATH" ] || [ ! "$DRY" -eq 1 ]; then
  {
    echo ""
    echo "## Nightly LIE audit — ${TIMESTAMP}"
    echo ""
    echo "- **Lies caught**: ${N_LIES}"
    echo "- **Auto-fixes applied**: ${N_FIXES}"
    echo "- **Morning brief items**: ${N_BRIEF}"
    echo ""
    if [ "$N_LIES" -gt 0 ]; then
      echo "### Lies caught"
      for lie in "${LIES[@]+"${LIES[@]}"}"; do echo "- $lie"; done
      echo ""
    fi
    if [ "$N_FIXES" -gt 0 ]; then
      echo "### Auto-fixes applied"
      for fix in "${FIXES_APPLIED[@]+"${FIXES_APPLIED[@]}"}"; do echo "- $fix"; done
      echo ""
    fi
    if [ "$N_BRIEF" -gt 0 ]; then
      echo "### Morning brief — operator action items"
      for item in "${MORNING_BRIEF[@]+"${MORNING_BRIEF[@]}"}"; do echo "- $item"; done
      echo ""
    fi
    if [ "$N_LIES" -eq 0 ] && [ "$N_BRIEF" -eq 0 ]; then
      echo "_All substrate-state checks passed — no lies, no action items._"
    fi
    echo ""
    echo "JSON report: \`${JSON_REPORT}\`"
  } >> "$DIGEST_PATH" 2>/dev/null
fi

# Write a memory card ONLY when lies found
if [ "$N_LIES" -gt 0 ]; then
  CARD_PATH="${CARDS_DIR}/feedback_nightly_lie_audit_${DATE//-/_}.md"
  cat > "$CARD_PATH" <<CARDEOF
---
name: nightly-lie-audit-${DATE}
description: "${N_LIES} lies caught by nightly-lie-audit ${DATE}, ${N_FIXES} auto-fixes applied, ${N_BRIEF} morning-brief action items. Full JSON at ${JSON_REPORT}."
metadata:
  type: feedback
  audit_date: ${DATE}
  lies: ${N_LIES}
  fixes_applied: ${N_FIXES}
  morning_brief_items: ${N_BRIEF}
---

# Nightly LIE audit — ${DATE}

Substrate-state empirical audit caught **${N_LIES}** discrepancies between claimed and empirical state.

## Lies caught
$(for lie in "${LIES[@]+"${LIES[@]}"}"; do echo "- $lie"; done)

## Auto-fixes applied
$(for fix in "${FIXES_APPLIED[@]+"${FIXES_APPLIED[@]}"}"; do echo "- $fix"; done)

## Morning brief — operator action items
$(for item in "${MORNING_BRIEF[@]+"${MORNING_BRIEF[@]}"}"; do echo "- $item"; done)

## See also
- \`feedback_verify_push_landed_not_just_script_output.md\` — the canonical rule earned this audit
- JSON report: \`${JSON_REPORT}\`
CARDEOF
fi

# Summary line for cron log
[ "$JSON_ONLY" -eq 0 ] && echo -e "\n${TIMESTAMP} nightly-lie-audit done — lies=${N_LIES} fixes=${N_FIXES} morning-brief=${N_BRIEF}"

exit 0
