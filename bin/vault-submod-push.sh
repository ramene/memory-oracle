#!/bin/bash
# vault-submod-push.sh — operator-driven manual advance of a vault submodule.
#
# Use case: operator edits/pushes content in a submodule's own repo
# (architecture-notes, etc.). This script then advances the vault's submodule
# pointer to the new submodule HEAD and pushes the vault commit, so peers
# pull it on their next cron tick.
#
# Usage:
#   vault-submod-push.sh <submodule-name>
#   vault-submod-push.sh architecture-notes
#
# What it does:
#   1. cd into the submodule, git pull origin main (gets your local in sync with its remote)
#   2. cd back to the vault, git add <submodule>
#   3. git commit + git push (vault commit records the new submodule pointer)
#   All wrapped in vault-write-tx for lock safety.

set -e
NAME="${1:-}"
if [ -z "$NAME" ]; then
  echo "usage: vault-submod-push.sh <submodule-name>" >&2
  echo "e.g.   vault-submod-push.sh architecture-notes" >&2
  exit 2
fi

V="$HOME/.remote/@vaults/.build/obsidian-vault"
SUB="$V/$NAME"
if [ ! -d "$SUB" ]; then
  echo "✗ submodule path not found: $SUB" >&2
  exit 1
fi

echo "─ $NAME submodule current HEAD: $(git -C "$SUB" rev-parse --short=8 HEAD)"
TS=$(date -u +%FT%TZ)

# CRITICAL FIX (2026-06-26 race): do EVERYTHING inside the vault-write-tx lock
# so vault-autosync cron can't run `git submodule update --init --recursive`
# in between our submodule pull and our vault commit (which would reset the
# submodule back to the OLD recorded pointer).
"$HOME/.bin/vault-write-tx.sh" "vault-submod-push@$(hostname -s)" -- bash -c "
  set -e
  cd '$V'
  # 1. Pull vault first (so we have latest origin state)
  git pull --rebase --autostash 2>&1 | tail -1
  # 2. NOW advance the submodule (inside the lock — cron can't interfere)
  cd '$SUB'
  git pull origin main 2>&1 | tail -2
  NEW=\$(git rev-parse --short=8 HEAD)
  echo \"  $NAME advanced to: \$NEW\"
  cd '$V'
  # 3. Did the pointer actually change?
  if git diff --quiet '$NAME'; then
    echo '  ✓ vault pointer already at \$NEW — nothing to commit'
    exit 0
  fi
  # 4. Commit + push the new pointer (still inside the lock)
  git add '$NAME'
  git commit -q -m \"vault: advance $NAME submodule pointer → \$NEW ($TS)\"
  git push origin main
  echo \"  ✓ vault pushed (vault HEAD now records $NAME at \$NEW)\"
"
