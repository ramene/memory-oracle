#!/bin/bash
# lmcanvas-preflight.sh — HARD-REFUSE an lmcanvas build/edit unless the checkout is the
# canonical, on the right remote, upstream-set, fetched, and NOT behind. Prevents the
# disparate-source disease (edits to /tmp copies, home dupes, stale checkouts) that caused
# the fork divergence + lost work. Run before build:host / before editing src.
set -uo pipefail
CANON="${LMCANVAS_CANON:-$HOME/lmcanvas-am-catalog}"
REMOTE_EXPECT="ramene/lmcanvas-am-catalog"
fail() { echo "❌ PREFLIGHT FAIL: $1" >&2; exit 1; }
[ -d "$CANON/.git" ] || fail "canonical checkout $CANON missing / not a git repo"
cd "$CANON" || fail "cannot cd $CANON"
git remote get-url origin 2>/dev/null | grep -q "$REMOTE_EXPECT" || fail "origin is not $REMOTE_EXPECT (wrong/forked checkout)"
UB=$(git rev-parse --abbrev-ref --symbolic-full-name '@{u}' 2>/dev/null) || fail "no upstream branch set (git branch --set-upstream-to)"
git fetch -q origin || fail "git fetch failed"
BEHIND=$(git rev-list --count "HEAD..@{u}" 2>/dev/null || echo '?')
[ "$BEHIND" = "0" ] || fail "$BEHIND commit(s) behind $UB — rebase first: git pull --rebase"
echo "✅ PREFLIGHT OK: $CANON @ $(git rev-parse --short HEAD) [$UB] — canonical, upstream-set, up-to-date"
