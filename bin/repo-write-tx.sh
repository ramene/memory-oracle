#!/bin/bash
# repo-write-tx.sh — generalize vault-write-tx for ANY substrate-tracked repo.
#
# Motivation (2026-06-25 incident #2): this session and soft-launch both edit
# memory-oracle/install.sh independently, push commits to the same remote, and
# race on rebase/push. Same race class as vault-autosync, different repo.
#
# Usage:
#   repo-write-tx.sh <repo-name> "<reason>" -- <command>
#
#   # Example: any session that edits memory-oracle/install.sh
#   repo-write-tx.sh memory-oracle "claude-86eb7a09 install.sh edit" -- bash -c '
#     cd ~/.remote/github.com/@ramene/memory-oracle
#     git pull --rebase --autostash
#     # edit + commit + push
#   '
#
# Lock path: ~/.local/share/mae-substrate/.repo-write-<repo-name>.lock.d/
# Same mkdir-atomic + stale-pid-steal semantics as vault-write-tx.sh.

set -e

if [ $# -lt 3 ]; then
  echo "usage: repo-write-tx.sh <repo-name> <reason> -- <command...>" >&2
  exit 2
fi

REPO_NAME="$1"; shift
REASON="$1"; shift
if [ "${1:-}" = "--" ]; then shift; fi

LOCK_PARENT="$HOME/.local/share/mae-substrate"
LOCK_DIR="$LOCK_PARENT/.repo-write-${REPO_NAME}.lock.d"
TIMEOUT="${REPO_WRITE_TX_TIMEOUT:-120}"     # repos can take longer than vault (commit + push)
LOG_FILE="${REPO_WRITE_TX_LOG:-$HOME/.claude-tmp/repo-write-tx.log}"

mkdir -p "$LOCK_PARENT" "$(dirname "$LOG_FILE")"

TS_START=$(date -u +%FT%TZ)
HOST=$(hostname -s)

acquire_lock() {
  local deadline=$(( $(date +%s) + TIMEOUT ))
  while ! mkdir "$LOCK_DIR" 2>/dev/null; do
    if [ -f "$LOCK_DIR/pid" ]; then
      local holder_pid
      holder_pid=$(cat "$LOCK_DIR/pid" 2>/dev/null || echo "")
      if [ -n "$holder_pid" ] && ! kill -0 "$holder_pid" 2>/dev/null; then
        local stale_reason
        stale_reason=$(cat "$LOCK_DIR/reason" 2>/dev/null || echo "unknown")
        echo "$(date -u +%FT%TZ) $HOST repo=$REPO_NAME stale-lock-stolen prev_holder=$holder_pid prev_reason='$stale_reason'" >> "$LOG_FILE"
        rm -rf "$LOCK_DIR"
        continue
      fi
    fi
    if [ "$(date +%s)" -ge "$deadline" ]; then
      return 1
    fi
    sleep 1
  done
  echo "$$" > "$LOCK_DIR/pid"
  echo "$REASON" > "$LOCK_DIR/reason"
  echo "$TS_START" > "$LOCK_DIR/acquired_at"
  return 0
}

release_lock() {
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
  echo "$TS_START $HOST repo=$REPO_NAME reason=$REASON LOCK-TIMEOUT after ${TIMEOUT}s" >> "$LOG_FILE"
  exit 3
fi

"$@"
RC=$?

TS_END=$(date -u +%FT%TZ)
echo "$TS_END $HOST repo=$REPO_NAME reason=$REASON rc=$RC" >> "$LOG_FILE"

exit "$RC"
