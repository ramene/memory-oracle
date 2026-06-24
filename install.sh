#!/usr/bin/env bash
# memory-oracle installer — copies binaries to ~/.bin, installs the SessionStart hook,
# sets up the launchd plist (macOS) or systemd unit (Linux) for the fs-watcher, and
# builds the initial FTS5 index.
#
# Idempotent. Safe to re-run.

set -u
SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"

echo "[memory-oracle] installing from $SCRIPT_DIR"

# --- dependencies -----------------------------------------------------------
if ! command -v sqlite3 >/dev/null 2>&1; then
  echo "error: sqlite3 CLI not found on PATH. macOS ships it; on Linux: apt install sqlite3" >&2
  exit 2
fi
if ! command -v node >/dev/null 2>&1; then
  echo "error: node not found on PATH. Install Node 18+ first." >&2
  exit 2
fi
NODE_VERSION=$(node -p "process.versions.node.split('.')[0]")
if [ "$NODE_VERSION" -lt 18 ]; then
  echo "error: Node 18+ required (found $NODE_VERSION)" >&2
  exit 2
fi

# --- copy binaries -----------------------------------------------------------
BIN_DIR="${HOME}/.bin"
mkdir -p "$BIN_DIR"
for f in memory-merge.mjs memory-search.mjs memory-index-build.mjs memory-structural-index.mjs memory-cite.mjs; do
  cp "$SCRIPT_DIR/bin/$f" "$BIN_DIR/$f"
  chmod +x "$BIN_DIR/$f"
  echo "  installed $BIN_DIR/$f"
done

# --- substrate tools (EBR cross-machine propagation) -------------------------
# Vendored copies of the substrate fleet tools — brain-sync, vault-autosync,
# the sovereign git remote-helper, the substrate guard hook, and the M3
# export/import/merge/pubkey tools. Installing these here makes ./install.sh the
# SINGLE propagation path: `git pull && ./install.sh` deploys the whole substrate.
for f in brain-sync.sh vault-autosync.sh git-remote-verum claude-hook-substrate-guard.mjs \
         mae-substrate-export.mjs mae-substrate-import.mjs mae-substrate-merge.mjs mae-verum-pubkeys.mjs; do
  if [ -f "$SCRIPT_DIR/bin/$f" ]; then
    cp "$SCRIPT_DIR/bin/$f" "$BIN_DIR/$f"
    chmod +x "$BIN_DIR/$f"
    echo "  installed $BIN_DIR/$f"
  else
    echo "  (skipping $f: not vendored in bin/)"
  fi
done

cp "$SCRIPT_DIR/hooks/claude-hook-session-start.sh" "$BIN_DIR/claude-hook-session-start.sh"
chmod +x "$BIN_DIR/claude-hook-session-start.sh"
echo "  installed $BIN_DIR/claude-hook-session-start.sh"

# --- skill (operator-wide) ---------------------------------------------------
SKILL_DEST="${HOME}/.local/share/journal/.seed/base/skills/memory-search"
if [ -d "$(dirname "$SKILL_DEST")" ]; then
  mkdir -p "$SKILL_DEST"
  cp "$SCRIPT_DIR/skills/memory-search/SKILL.md" "$SKILL_DEST/SKILL.md"
  echo "  installed Skill at $SKILL_DEST/"
else
  echo "  (skipping Skill install: ~/.local/share/journal/.seed/ not present)"
fi

# --- register hooks in claude settings (idempotent python3 merge) ------------
# Auto-register BOTH the SessionStart banner hook and the PreToolUse(Bash)
# substrate guard in ~/.claude/settings.json. Creates the file/keys if missing,
# de-dupes by command string before appending, so re-running is a no-op.
SETTINGS="${HOME}/.claude/settings.json"
mkdir -p "$(dirname "$SETTINGS")"
if command -v python3 >/dev/null 2>&1; then
  SETTINGS="$SETTINGS" python3 - <<'PY'
import json, os, sys

settings = os.environ["SETTINGS"]
home = os.path.expanduser("~")

# load (or start fresh if missing/empty/corrupt)
data = {}
if os.path.exists(settings):
    try:
        with open(settings) as f:
            txt = f.read().strip()
        data = json.loads(txt) if txt else {}
    except Exception as e:
        print(f"  ⚠ {settings} unparseable ({e}); leaving it untouched, skipping hook registration")
        sys.exit(0)
if not isinstance(data, dict):
    print("  ⚠ settings.json is not a JSON object; skipping hook registration")
    sys.exit(0)

hooks = data.setdefault("hooks", {})
changed = False

def has_command(entries, needle):
    for entry in entries:
        for h in entry.get("hooks", []):
            if needle in (h.get("command") or ""):
                return True
    return False

# SessionStart -> banner hook
ss = hooks.setdefault("SessionStart", [])
if not has_command(ss, "claude-hook-session-start.sh"):
    ss.append({
        "matcher": "startup|resume|clear|compact",
        "hooks": [{"type": "command", "command": "$HOME/.bin/claude-hook-session-start.sh"}],
    })
    changed = True
    print("  registered SessionStart -> claude-hook-session-start.sh")
else:
    print("  SessionStart hook already registered")

# PreToolUse(Bash) -> substrate guard
pt = hooks.setdefault("PreToolUse", [])
if not has_command(pt, "claude-hook-substrate-guard.mjs"):
    pt.append({
        "matcher": "Bash",
        "hooks": [{"type": "command", "command": "node $HOME/.bin/claude-hook-substrate-guard.mjs"}],
    })
    changed = True
    print("  registered PreToolUse(Bash) -> claude-hook-substrate-guard.mjs")
else:
    print("  PreToolUse(Bash) substrate guard already registered")

if changed:
    with open(settings, "w") as f:
        json.dump(data, f, indent=2)
        f.write("\n")
    print(f"  updated {settings}")
else:
    print(f"  {settings} already current")
PY
else
  echo "  ⚠ python3 not found — cannot auto-register hooks. Manually add to $SETTINGS under 'hooks':"
  cat <<'EOF'
    "SessionStart": [
      {"matcher": "startup|resume|clear|compact",
       "hooks": [{"type": "command", "command": "$HOME/.bin/claude-hook-session-start.sh"}]}
    ],
    "PreToolUse": [
      {"matcher": "Bash",
       "hooks": [{"type": "command", "command": "node $HOME/.bin/claude-hook-substrate-guard.mjs"}]}
    ]
EOF
fi

# --- launchd / systemd watcher -----------------------------------------------
case "$(uname)" in
  Darwin)
    PLIST_DEST="${HOME}/Library/LaunchAgents/com.local.memory-index-watcher.plist"
    # Render the plist with $HOME expanded
    sed "s|\$HOME|${HOME}|g" "$SCRIPT_DIR/runtime/launchd/com.memory-index-watcher.plist" > "$PLIST_DEST"
    launchctl unload "$PLIST_DEST" 2>/dev/null || true
    launchctl load "$PLIST_DEST"
    echo "  installed launchd watcher at $PLIST_DEST"
    ;;
  Linux)
    echo "  Linux: copy runtime/systemd/memory-index-watcher.service to ~/.config/systemd/user/ then 'systemctl --user enable --now memory-index-watcher'"
    ;;
esac

# --- substrate crons (per-host, idempotent) ----------------------------------
# vault-autosync on ALL hosts; brain-sync per-host with a staggered minute and a
# BRAIN_MACHINES list that names the OTHER two peers. Idempotent: read current
# crontab, strip our marked lines, re-add. Detect host via `hostname -s`.
HOST_SHORT="$(hostname -s 2>/dev/null || hostname)"
# Mesh identity is keyed on the RESERVED LAN IP, not hostname — hostnames don't always match
# the mesh short-name (e.g. sequoia's hostname is 'Ramenes-MacBook-Pro-7'). Fall back to hostname.
LAN_IP="$(ifconfig 2>/dev/null | grep 'inet 192.168.100.' | awk '{print $2}' | head -1)"
case "$LAN_IP" in
  192.168.100.2)                  HOST_MESH=noodles ;;
  192.168.100.14)                 HOST_MESH=sequoia ;;
  192.168.100.10|192.168.100.12)  HOST_MESH=tunafish ;;
  *)                              HOST_MESH="$HOST_SHORT" ;;
esac
mkdir -p "$HOME/.claude-tmp"
echo "[memory-oracle] installing substrate crons for mesh node '$HOST_MESH' (host $HOST_SHORT, ip ${LAN_IP:-?})..."

VAULT_MARK="# memory-oracle:vault-autosync"
BRAIN_MARK="# memory-oracle:brain-sync"
VAULT_LINE="*/3 * * * * \$HOME/.bin/vault-autosync.sh >> \$HOME/.claude-tmp/vault-autosync.log 2>&1 $VAULT_MARK"

case "$HOST_MESH" in
  noodles)  BRAIN_SCHED="*/15 * * * *";       BRAIN_MACHINES="local,sequoia,tunafish" ;;
  sequoia)  BRAIN_SCHED="5,20,35,50 * * * *"; BRAIN_MACHINES="local,noodles,tunafish" ;;
  tunafish) BRAIN_SCHED="10,25,40,55 * * * *";BRAIN_MACHINES="local,noodles,sequoia" ;;
  *)        BRAIN_SCHED="";                    BRAIN_MACHINES="" ;;
esac

# current crontab (empty if none), with our marked lines stripped
# strip BOTH our marked lines AND any pre-existing unmarked vault-autosync/brain-sync
# lines (from manual setups) so re-running never duplicates the cron.
CURRENT_CRON="$(crontab -l 2>/dev/null | grep -vE 'vault-autosync\.sh|brain-sync\.sh' || true)"
NEW_CRON="$CURRENT_CRON
$VAULT_LINE"
echo "  + vault-autosync: */3 (all hosts)"
if [ -n "$BRAIN_SCHED" ]; then
  BRAIN_LINE="$BRAIN_SCHED BRAIN_MACHINES=$BRAIN_MACHINES \$HOME/.bin/brain-sync.sh >> \$HOME/.claude-tmp/brain-sync.log 2>&1 $BRAIN_MARK"
  NEW_CRON="$NEW_CRON
$BRAIN_LINE"
  echo "  + brain-sync: '$BRAIN_SCHED' BRAIN_MACHINES=$BRAIN_MACHINES"
else
  echo "  (notice: mesh node '$HOST_MESH' (ip ${LAN_IP:-?}) not recognized — installing vault-autosync only, skipping brain-sync)"
fi
# strip leading blank line(s) and load
printf '%s\n' "$NEW_CRON" | sed '/./,$!d' | crontab -
echo "  crontab updated"

# --- verum binary (install/verify v0.11.0) -----------------------------------
VERUM_WANT="verum 0.11.0"
VERUM_BIN="$BIN_DIR/verum"
CURRENT_VERUM="$("$VERUM_BIN" --version 2>/dev/null || true)"
if [ "$CURRENT_VERUM" = "$VERUM_WANT" ]; then
  echo "[memory-oracle] verum already at $VERUM_WANT"
else
  echo "[memory-oracle] installing verum v0.11.0 (found: '${CURRENT_VERUM:-none}')..."
  # match the release asset to this machine's arch/os
  case "$(uname -m)-$(uname -s)" in
    arm64-Darwin|aarch64-Darwin) VERUM_PAT='*macos-arm64*' ;;
    x86_64-Darwin)               VERUM_PAT='*macos-x86_64*' ;;
    x86_64-Linux)                VERUM_PAT='*linux-x86_64*' ;;
    aarch64-Linux|arm64-Linux)   VERUM_PAT='*linux-arm64*' ;;
    *)                           VERUM_PAT='' ;;
  esac
  if [ -z "$VERUM_PAT" ]; then
    echo "  ⚠ unrecognized arch/os '$(uname -m)-$(uname -s)' — install verum v0.11.0 manually from https://github.com/ramene/verum/releases/tag/v0.11.0"
  elif ! command -v gh >/dev/null 2>&1; then
    echo "  ⚠ gh CLI not found — cannot auto-download verum."
    echo "    Manual: gh release download v0.11.0 -R ramene/verum --pattern '$VERUM_PAT' then tar xzf -> $VERUM_BIN"
  else
    VERUM_TMP="$(mktemp -d)"
    if gh release download v0.11.0 -R ramene/verum --pattern "$VERUM_PAT" --dir "$VERUM_TMP" 2>/dev/null; then
      VERUM_TAR="$(find "$VERUM_TMP" -maxdepth 1 -type f -name '*.tar.gz' | head -1)"
      if [ -n "$VERUM_TAR" ]; then
        tar -xzf "$VERUM_TAR" -C "$VERUM_TMP"
        VERUM_EXTRACTED="$(find "$VERUM_TMP" -type f -name verum | head -1)"
        if [ -n "$VERUM_EXTRACTED" ]; then
          cp "$VERUM_EXTRACTED" "$VERUM_BIN"
          chmod +x "$VERUM_BIN"
          echo "  installed $VERUM_BIN ($("$VERUM_BIN" --version 2>/dev/null || echo 'version check failed'))"
        else
          echo "  ⚠ no 'verum' binary inside the asset — install manually"
        fi
      else
        echo "  ⚠ no .tar.gz asset matched '$VERUM_PAT' — install verum v0.11.0 manually"
      fi
    else
      echo "  ⚠ gh release download failed (asset/network/auth) — install verum v0.11.0 manually:"
      echo "    gh release download v0.11.0 -R ramene/verum --pattern '$VERUM_PAT'"
    fi
    rm -rf "$VERUM_TMP"
  fi
fi

# --- mesh ssh aliases (idempotent, skip current host) ------------------------
# Ensure ~/.ssh/config has Host blocks for the fleet so brain-sync/git-remote-verum
# can ssh peers by short name. Dedup-safe: only append a block if its `Host <name>`
# line is absent. Skip whichever host we are running on.
SSH_CONFIG="$HOME/.ssh/config"
mkdir -p "$HOME/.ssh"; chmod 700 "$HOME/.ssh"
touch "$SSH_CONFIG"; chmod 600 "$SSH_CONFIG"
add_mesh_host() {
  local name="$1" ip="$2"
  if [ "$name" = "$HOST_MESH" ]; then
    echo "  (skipping ssh alias for current host '$name')"
    return
  fi
  if grep -qE "^[[:space:]]*Host[[:space:]]+$name([[:space:]]|\$)" "$SSH_CONFIG"; then
    echo "  ssh alias '$name' already present"
    return
  fi
  {
    echo ""
    echo "Host $name"
    echo "    HostName $ip"
    echo "    User ramene"
    echo "    IdentityFile ~/.ssh/id_ed25519_ramene_auth"
    echo "    StrictHostKeyChecking accept-new"
  } >> "$SSH_CONFIG"
  echo "  added ssh alias '$name' ($ip)"
}
echo "[memory-oracle] ensuring mesh ssh aliases in $SSH_CONFIG..."
add_mesh_host noodles  192.168.100.2
add_mesh_host sequoia  192.168.100.14
add_mesh_host tunafish 192.168.100.12

# --- initial index build -----------------------------------------------------
echo "[memory-oracle] building initial index..."
node "$BIN_DIR/memory-index-build.mjs"
node "$BIN_DIR/memory-structural-index.mjs"

echo ""
echo "[memory-oracle] install complete."
echo ""
echo "Try:    memory-search 'your topic here'"
echo "Or:     memory-cite SESSION_ID --info"
