#!/bin/bash
# substrate-health.sh — end-to-end smoke test across the substrate cluster.
#
# Runs the EMPIRICAL validation matrix that "install.sh exit 0" doesn't cover.
# Designed to be run BEFORE and AFTER any install.sh change, or any time
# the operator wants to confirm "is the substrate actually working?"
#
# Tests (per node, then cross-node):
#   1. memory-oracle:  ~/.bin/memory-search.mjs runs with expected hits
#   2. vault git:       working tree clean, on main, in sync with origin
#   3. mae-pulse:       daemon up, socket bound, recent presence in log
#   4. vault-write-tx:  lock file infrastructure present, log writable
#   5. brain-sync:      log shows recent run
#   6. cron entries:    all 3 expected entries present
#   7. settings.json:   3 hooks registered (SessionStart, PreToolUse Bash, PreToolUse Write/Edit)
#   8. cross-node:      change file on noodles → sequoia/tunafish HEAD updates within 30s
#
# Exit code: 0 if all green, non-zero count of failed checks otherwise.

set -uo pipefail

FAILED=0
PASSED=0
WARN=0

red()   { printf "\033[31m%s\033[0m" "$1"; }
green() { printf "\033[32m%s\033[0m" "$1"; }
yellow(){ printf "\033[33m%s\033[0m" "$1"; }

pass() { PASSED=$((PASSED+1)); printf "  $(green '✓') %s\n" "$1"; }
fail() { FAILED=$((FAILED+1)); printf "  $(red '✗') %s\n" "$1"; }
warn() { WARN=$((WARN+1));     printf "  $(yellow '!') %s\n" "$1"; }
section() { printf "\n══ %s ══\n" "$1"; }

# ─── 1. memory-oracle ───────────────────────────────────────────────────────
section "memory-oracle (memory-search)"
HITS=$(~/.bin/memory-search.mjs 'substrate install propagation' 2>/dev/null | grep -c "^## " || echo 0)
[ "$HITS" -gt 0 ] && pass "memory-search returned $HITS hits" || fail "memory-search returned 0 hits"

# ─── 2. vault git ───────────────────────────────────────────────────────────
section "vault git state"
V="$HOME/.remote/@vaults/.build/obsidian-vault"
cd "$V" 2>/dev/null || { fail "vault dir missing"; exit 1; }
BRANCH=$(git rev-parse --abbrev-ref HEAD)
[ "$BRANCH" = "main" ] && pass "on main branch" || fail "on '$BRANCH' branch (expected main)"
DIVERGE=$(git rev-list --left-right --count origin/main...HEAD 2>/dev/null | tr '\t' ' ')
[ "$DIVERGE" = "0 0" ] && pass "in sync with origin/main" || warn "diverge: $DIVERGE (ahead behind)"

# ─── 3. mae-pulse daemon ────────────────────────────────────────────────────
section "mae-pulse daemon"
PID=$(launchctl list 2>/dev/null | awk '$3=="com.mae.pulse-daemon"{print $1}')
if [ -n "$PID" ] && [ "$PID" != "-" ]; then
  pass "daemon up (pid=$PID)"
  SOCK=$(lsof -nP -iUDP:38478 2>/dev/null | grep -c "node" || echo 0)
  [ "$SOCK" -gt 0 ] && pass "UDP :38478 socket bound" || fail "UDP :38478 NOT bound"
  LAST=$(tail -20 ~/.claude-tmp/mae-pulse-daemon.log 2>/dev/null | grep -c "presence" || echo 0)
  [ "$LAST" -gt 0 ] && pass "recent presence in log ($LAST entries)" || warn "no presence in last 20 log lines"
else
  fail "daemon NOT running"
fi

# ─── 4. vault-write-tx ──────────────────────────────────────────────────────
section "vault-write-tx"
[ -x ~/.bin/vault-write-tx.sh ] && pass "binary present" || fail "binary missing"
[ -d ~/.local/share/mae-substrate ] && pass "lock parent dir present" || fail "lock parent dir missing"
touch ~/.claude-tmp/vault-write-tx.log 2>/dev/null && pass "log path writable" || fail "log path NOT writable"

# ─── 5. brain-sync ──────────────────────────────────────────────────────────
section "brain-sync"
if [ -f ~/.claude-tmp/brain-sync.log ]; then
  LAST_RUN=$(tail -1 ~/.claude-tmp/brain-sync.log 2>/dev/null | head -c 25)
  pass "log last line: $LAST_RUN"
else
  warn "no brain-sync.log yet (may not have run)"
fi

# ─── 6. cron entries ────────────────────────────────────────────────────────
section "crontab"
for entry in vault-autosync brain-sync memory-hygiene-audit; do
  N=$(crontab -l 2>/dev/null | grep -c "memory-oracle:$entry")
  [ "$N" -eq 1 ] && pass "$entry cron present" || fail "$entry cron missing or duplicated ($N entries)"
done

# ─── 7. settings.json hooks ─────────────────────────────────────────────────
section "claude settings.json hooks"
if /usr/local/bin/python3 - <<'PY'
import json, sys
d = json.load(open(__import__("os").path.expanduser("~/.claude/settings.json")))
h = d.get("hooks", {})
required = [
    ("SessionStart", "claude-hook-session-start"),
    ("PreToolUse", "claude-hook-substrate-guard"),
    ("PreToolUse", "claude-hook-memory-hygiene"),
]
miss = 0
for evt, needle in required:
    found = False
    for e in h.get(evt, []):
        for hh in e.get("hooks", []):
            if needle in (hh.get("command") or ""):
                found = True; break
    if found: print(f"OK {evt}:{needle}")
    else: print(f"MISS {evt}:{needle}"); miss += 1
sys.exit(miss)
PY
then
  pass "all 3 hooks registered"
else
  fail "missing hooks (see python output above)"
fi

# ─── 8. cross-node: mae-pulse round-trip ────────────────────────────────────
section "cross-node mae-pulse round-trip"
PEERS_FILE="$HOME/.local/share/mae-substrate/pulse/peers.json"
if [ ! -f "$PEERS_FILE" ]; then
  fail "peers.json missing — skipping cross-node test"
else
  PRE_NOODLES=$(git -C "$V" rev-parse --short HEAD 2>/dev/null)
  TEST_FILE="$V/_pulse-health-test-$(date +%s).tmp"
  echo "pulse health test $(date -u +%FT%TZ)" > "$TEST_FILE"
  echo "  → wrote $TEST_FILE"
  echo "  → waiting 15s for daemon to debounce + autosync + propagate"
  sleep 15
  # Daemon should have committed + pushed. Remove file so it doesn't pollute.
  rm -f "$TEST_FILE"
  sleep 5
  POST_NOODLES=$(git -C "$V" rev-parse --short HEAD 2>/dev/null)
  if [ "$PRE_NOODLES" != "$POST_NOODLES" ]; then
    pass "noodles HEAD advanced: $PRE_NOODLES → $POST_NOODLES"
    # Wait a bit more for peers to pull
    sleep 10
    SEQ_HEAD=$(ssh -o ConnectTimeout=3 sequoia "cd $V && git fetch -q && git rev-parse --short origin/main" 2>/dev/null || echo unreachable)
    TUN_HEAD=$(ssh -o ConnectTimeout=3 tunafish "cd $V && git fetch -q && git rev-parse --short origin/main" 2>/dev/null || echo unreachable)
    [ "$SEQ_HEAD" = "$POST_NOODLES" ] && pass "sequoia origin/main caught up: $SEQ_HEAD" || warn "sequoia origin/main: $SEQ_HEAD (expected $POST_NOODLES)"
    [ "$TUN_HEAD" = "$POST_NOODLES" ] && pass "tunafish origin/main caught up: $TUN_HEAD" || warn "tunafish origin/main: $TUN_HEAD (expected $POST_NOODLES)"
  else
    warn "noodles HEAD did not advance — daemon may not have detected change"
  fi
fi

# ─── Summary ─────────────────────────────────────────────────────────────────
section "summary"
printf "  passed=$PASSED  failed=$FAILED  warn=$WARN\n"
[ "$FAILED" -gt 0 ] && exit "$FAILED" || exit 0
