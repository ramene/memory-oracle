#!/bin/bash
# vault-write-tx.sh — atomic transaction wrapper for any process committing to
# the Obsidian vault. Serializes vault writes within a single machine so
# multiple writers (vault-autosync cron, claude sessions, manual operator
# commits) cannot race on rebase/push.
#
# CONTEXT (2026-06-25 incident):
#   - vault is git-tracked on noodles + sequoia + tunafish
#   - vault-autosync.sh runs every 3 min on each machine
#   - multiple claude sessions (this one + soft-launch) commit independently
#   - Obsidian's workspace.json was being constantly rewritten + tracked
#   - result: every rebase hit conflicts, multiple sessions burned cycles
#     wrestling with --theirs/--ours, occasional autostash orphans
#
# The fix (deployed 2026-06-25):
#   1. Gitignored .obsidian/workspace.json (commit 419748e)
#   2. THIS SCRIPT: per-machine mkdir-atomic lock serializes ALL vault git ops
#
# Locking — portable POSIX mkdir(1):
#   - mkdir(1) is atomic per POSIX — succeeds iff target doesn't exist.
#   - Lock dir: ~/.local/share/mae-substrate/.vault-write.lock.d/
#   - Stale-lock detection: pid file inside; if owner pid is dead, steal it.
#   - No external deps (no flock, no shlock, no Python). Works identically on
#     macOS BSD and Linux.
#
# Brand-expertise alignment: this is the "intra-machine coordinator" rung of
# the substrate sync stack. Together with git-remote-verum (sovereign transport,
# Tier 2) and brain-sync (substrate gather-union-redistribute), it's the third
# leg of the keybase/KBFS-revival posture: "private repos with institutional
# discipline, no third-party dependency."
#
# Usage:
#   vault-write-tx.sh "<reason>" -- <bash command sequence>
#
#   # operator manual edit + push
#   vault-write-tx.sh "operator edit" -- bash -c 'git add foo && git commit -m bar && git push'
#
#   # wrapping vault-autosync's inner sequence (the canonical use)
#   vault-write-tx.sh "vault-autosync@noodles" -- bash -c 'git pull --rebase && ...'
#
# Environment:
#   VAULT_WRITE_TX_TIMEOUT  — override the 60s default
#   VAULT_WRITE_TX_LOG       — override the default ~/.claude-tmp/vault-write-tx.log

set -e

LOCK_PARENT="$HOME/.local/share/mae-substrate"
LOCK_DIR="$LOCK_PARENT/.vault-write.lock.d"
TIMEOUT="${VAULT_WRITE_TX_TIMEOUT:-60}"
LOG_FILE="${VAULT_WRITE_TX_LOG:-$HOME/.claude-tmp/vault-write-tx.log}"

mkdir -p "$LOCK_PARENT" "$(dirname "$LOG_FILE")"

# Parse args
REASON="${1:-unspecified}"
shift
if [ "${1:-}" = "--" ]; then shift; fi
if [ $# -lt 1 ]; then
  echo "usage: vault-write-tx.sh <reason> -- <command...>" >&2
  exit 2
fi

TS_START=$(date -u +%FT%TZ)
HOST=$(hostname -s)

# Acquire lock via mkdir — atomic. Steal stale (dead-pid) locks.
acquire_lock() {
  local deadline=$(( $(date +%s) + TIMEOUT ))
  while ! mkdir "$LOCK_DIR" 2>/dev/null; do
    # Lock contended. Check if holder is alive.
    if [ -f "$LOCK_DIR/pid" ]; then
      local holder_pid
      holder_pid=$(cat "$LOCK_DIR/pid" 2>/dev/null || echo "")
      if [ -n "$holder_pid" ] && ! kill -0 "$holder_pid" 2>/dev/null; then
        # Stale lock — owner is dead. Steal it.
        local stale_reason
        stale_reason=$(cat "$LOCK_DIR/reason" 2>/dev/null || echo "unknown")
        echo "$(date -u +%FT%TZ) $HOST stale-lock-stolen prev_holder=$holder_pid prev_reason='$stale_reason'" >> "$LOG_FILE"
        rm -rf "$LOCK_DIR"
        continue
      fi
    fi
    # Holder alive — wait + retry until deadline.
    if [ "$(date +%s)" -ge "$deadline" ]; then
      return 1
    fi
    sleep 0.5
  done
  # We hold the lock — record ownership.
  echo "$$" > "$LOCK_DIR/pid"
  echo "$REASON" > "$LOCK_DIR/reason"
  echo "$TS_START" > "$LOCK_DIR/acquired_at"
  return 0
}

release_lock() {
  # Only release if WE hold it (defensive vs trap-on-failed-acquire)
  if [ -f "$LOCK_DIR/pid" ]; then
    local owner
    owner=$(cat "$LOCK_DIR/pid" 2>/dev/null || echo "")
    if [ "$owner" = "$$" ]; then
      rm -rf "$LOCK_DIR"
    fi
  fi
}

trap release_lock EXIT INT TERM

if ! acquire_lock; then
  echo "$TS_START $HOST reason=$REASON LOCK-TIMEOUT after ${TIMEOUT}s" >> "$LOG_FILE"
  exit 3
fi

# Run the wrapped command — don't set -e here, the caller chooses error handling.
"$@"
RC=$?

TS_END=$(date -u +%FT%TZ)
echo "$TS_END $HOST reason=$REASON rc=$RC" >> "$LOG_FILE"

# Lock released by trap on exit
exit "$RC"
