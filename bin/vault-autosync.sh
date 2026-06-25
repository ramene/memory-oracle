#!/bin/bash
# vault-autosync.sh — reliable git-based Obsidian vault sync across noodles/sequoia/tunafish.
# Replaces LiveSync P2P for vault sync. git-crypt keeps content ciphertext on GitHub;
# verum redaction is the per-file app-layer E2E. Runs every few min via cron.
#
# CONCURRENCY (2026-06-25 hardening): All git operations are wrapped via
# vault-write-tx.sh — a per-machine flock-based transaction lock. Prevents races
# between cron + claude sessions + manual operator commits. Lock timeout 60s; if
# contended, this tick logs + exits 0 (next tick retries cleanly).
#
# Co-shipped with the gitignore of .obsidian/workspace.json (commit 419748e) —
# together these eliminate the cross-session rebase-conflict storm we hit
# 2026-06-25.

export PATH=/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin
V="$HOME/.remote/@vaults/.build/obsidian-vault"
cd "$V" 2>/dev/null || exit 0
[ -d .git ] || exit 0
TS=$(date -u +%FT%TZ); HOST=$(hostname -s)

# All git operations happen INSIDE the transaction lock.
"$HOME/.bin/vault-write-tx.sh" "vault-autosync@$HOST" -- bash -c "
  set -e
  # pull first (rebase local edits on top of remote; stash dirty tree during rebase)
  if ! git pull --rebase --autostash origin main >/dev/null 2>&1; then
    git rebase --abort >/dev/null 2>&1
    echo '$TS $HOST pull-conflict (skipped; will retry)'
    exit 0
  fi
  # push local changes, if any
  if [ -n \"\$(git status --porcelain)\" ]; then
    git add -A
    git commit -q -m 'vault auto-sync $HOST $TS' >/dev/null 2>&1
    if git push origin main >/dev/null 2>&1; then
      echo '$TS $HOST pushed'
    else
      echo '$TS $HOST push-failed'
    fi
  fi
"
RC=$?
# RC=3 = lock-timeout; log + skip (next cron tick retries)
if [ "$RC" = "3" ]; then
  echo "$TS $HOST lock-contended (skipped; will retry)"
fi
exit 0
