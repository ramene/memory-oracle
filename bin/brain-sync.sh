#!/bin/bash
# brain-sync.sh — continuous SHARED-BRAIN sync across noodles/sequoia/tunafish.
# Gather each machine's memory cards + digests -> union (newest-wins) -> redistribute to all,
# so a memory card written on ANY machine converges to the others. Substrate-native (ssh tar),
# NO third party (the brain is the crown jewels — sovereign by default). Each machine's launchd
# fs-watcher re-indexes once the writes land. Runs on the coordinator (noodles) via cron.
# NOTE: union is additive/newest-wins; it does NOT propagate deletions (brain is append-mostly —
# supersession is via sidecars, not file deletion). Intentional.
set -u
# portable node PATH (latest nvm + brew + system) — cron runs with a minimal env
P="/usr/local/bin:/usr/bin:/bin"
if [ -d "$HOME/.nvm/versions/node" ]; then
  L=$(ls -1 "$HOME/.nvm/versions/node" 2>/dev/null | sort -V | tail -1)
  [ -n "$L" ] && P="$HOME/.nvm/versions/node/$L/bin:$P"
fi
[ -d /opt/homebrew/bin ] && P="/opt/homebrew/bin:$P"
export PATH="$P"
MERGE="$HOME/.bin/mae-substrate-merge.mjs"
[ -f "$MERGE" ] || MERGE="$HOME/.remote/@builds.karve.ai/apps/mae/scripts/mae-substrate-merge.mjs"
[ -f "$MERGE" ] || { echo "$(date -u +%FT%TZ) brain-sync: merge tool missing"; exit 0; }
# Same command on every machine: unreachable peers are skipped (offline-tolerant), so noodles
# bridges both and sequoia<->tunafish sync directly. BRAIN_MACHINES overridable if needed.
echo "$(date -u +%FT%TZ) brain-sync start ($(hostname -s))"
node "$MERGE" --machines "${BRAIN_MACHINES:-local,sequoia,tunafish}" --redistribute 2>&1
echo "$(date -u +%FT%TZ) brain-sync done"
