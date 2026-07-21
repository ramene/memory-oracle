#!/bin/bash
# substrate-backup-pull — nightly offsite copy of the latest Pi daemon-DB snapshot → noodles + sequoia.
# Best-effort redundancy on top of the Pi-local rotating backups (Pi is the primary).
set -uo pipefail
PI=ramene@192.168.100.50
DEST="$HOME/.local/state/substrate-backups"
mkdir -p "$DEST"
LATEST=$(ssh -o ConnectTimeout=10 "$PI" 'ls -1t /mnt/substrate/daemon/backups/substrate-*.db.gz 2>/dev/null | head -1' 2>/dev/null)
if [ -z "$LATEST" ]; then echo "$(date -Iseconds) SKIP: Pi unreachable / no backup" >> "$DEST/pull.log"; exit 0; fi
rsync -a "$PI:$LATEST" "$DEST/" || { echo "$(date -Iseconds) FAIL pull" >> "$DEST/pull.log"; exit 1; }
BASE=$(basename "$LATEST")
# mirror to sequoia (best-effort)
ssh -o ConnectTimeout=10 sequoia 'mkdir -p ~/.local/state/substrate-backups' 2>/dev/null \
  && rsync -a "$DEST/$BASE" sequoia:.local/state/substrate-backups/ 2>/dev/null || true
# retain 7 on noodles
ls -1t "$DEST"/substrate-*.db.gz 2>/dev/null | tail -n +8 | xargs rm -f 2>/dev/null
echo "$(date -Iseconds) OK pulled $BASE → noodles+sequoia" >> "$DEST/pull.log"
echo "pulled $BASE → noodles + sequoia"

# --- tmux-session-map: per-host collection (NOT replication) ------------------
# ~/.local/share/tmux-session-map/sessions.jsonl maps tmux session NAME → claude
# session id. It is a per-machine runtime artifact covered by NEITHER git NOR
# dotfiles-autosync — one disk failure from gone, and it is what makes a crashed
# pane resumable (see reference_tmux_session_map, dotfiles 76504cb).
#
# CRITICAL: collected per-host into SEPARATE files and never written BACK to any
# machine. tmux session names are per-machine by design; merging or pushing these
# would corrupt each box's view of its own panes. This is backup, not sync.
MAPDEST="$DEST/tmux-session-map"
mkdir -p "$MAPDEST"
_map_ok=""
# noodles = local
if [ -f "$HOME/.local/share/tmux-session-map/sessions.jsonl" ]; then
  cp "$HOME/.local/share/tmux-session-map/sessions.jsonl" "$MAPDEST/noodles.jsonl" 2>/dev/null \
    && _map_ok="$_map_ok noodles:$(wc -l < "$MAPDEST/noodles.jsonl" | tr -d ' ')"
fi
for h in sequoia tunafish; do
  if rsync -a -e "ssh -o ConnectTimeout=10" \
      "$h:.local/share/tmux-session-map/sessions.jsonl" "$MAPDEST/$h.jsonl" 2>/dev/null; then
    _map_ok="$_map_ok $h:$(wc -l < "$MAPDEST/$h.jsonl" | tr -d ' ')"
  else
    echo "$(date -Iseconds) SKIP session-map $h (unreachable or absent)" >> "$DEST/pull.log"
  fi
done
echo "$(date -Iseconds) OK session-map rows:$_map_ok" >> "$DEST/pull.log"
echo "session-map collected →$_map_ok"
