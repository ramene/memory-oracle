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
  # Pull vault first, RECURSING into submodules so they fetch + advance to the
  # commit recorded in the parent (the 2026-06-25 submodule footgun fix:
  # without --recurse-submodules, submodule local clones never fetch new
  # upstream commits and stay stale even when the parent pointer advances).
  if ! git pull --rebase --autostash --recurse-submodules origin main >/dev/null 2>&1; then
    git rebase --abort >/dev/null 2>&1
    echo '$TS $HOST pull-conflict (skipped; will retry)'
    exit 0
  fi
  # Advance submodules to their UPSTREAM HEADs (--remote) — operator-owned repos
  # like architecture-notes auto-follow their main branch. If this advances any
  # submodule pointer, git status will show the gitlink as modified and the
  # commit block below will record + push the advance.
  git submodule update --init --recursive --remote >/dev/null 2>&1 || true
  # SAFEGUARD (2026-06-26 incident): refuse to commit if any tracked
  # .obsidian/*.json file shrunk to <10 bytes when its previous version was
  # >50 bytes. Obsidian momentarily writes empty files during plugin
  # enable/disable + restart, and the cron's commit-grab can catch that
  # half-state. Without this check, the empty file gets cluster-propagated
  # and breaks Obsidian on every node.
  SHRUNK=\$(git status --porcelain .obsidian/ 2>/dev/null | awk '/^.M / {print \$2}' | while read f; do
    cur=\$(wc -c < \"\$f\" 2>/dev/null || echo 0)
    prev=\$(git show HEAD:\"\$f\" 2>/dev/null | wc -c || echo 0)
    if [ \"\$cur\" -lt 10 ] && [ \"\$prev\" -gt 50 ]; then echo \"\$f\"; fi
  done)
  if [ -n \"\$SHRUNK\" ]; then
    echo \"$TS $HOST refused: suspected corruption (.obsidian file truncated): \$SHRUNK\"
    # Restore the shrunk files from HEAD so the commit doesn't include them
    for f in \$SHRUNK; do
      git checkout HEAD -- \"\$f\" 2>/dev/null
    done
  fi
  # Commit working-tree changes (including submodule pointer advances)
  if [ -n \"\$(git status --porcelain)\" ]; then
    git add -A
    git commit -q -m 'vault auto-sync $HOST $TS' >/dev/null 2>&1
  fi
  # Push if local is ahead of origin/main (covers freshly-committed AND
  # pre-existing-but-unpushed commits — the 2026-06-25 soft-launch case)
  AHEAD=\$(git rev-list --count origin/main..HEAD 2>/dev/null || echo 0)
  if [ \"\$AHEAD\" -gt 0 ]; then
    if git push --recurse-submodules=check origin main >/dev/null 2>&1; then
      echo \"$TS $HOST pushed (commits=\$AHEAD)\"
    else
      echo \"$TS $HOST push-failed\"
    fi
  fi
"
RC=$?
# RC=3 = lock-timeout; log + skip (next cron tick retries)
if [ "$RC" = "3" ]; then
  echo "$TS $HOST lock-contended (skipped; will retry)"
fi
exit 0
