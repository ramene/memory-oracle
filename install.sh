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
# _VENDORED accumulates every basename the vendor for-loops install this run.
# The propagation self-check below diffs it against bin/ to catch unvendored tools.
_VENDORED=""
for f in memory-merge.mjs memory-search.mjs memory-index-build.mjs memory-structural-index.mjs memory-cite.mjs; do
  cp "$SCRIPT_DIR/bin/$f" "$BIN_DIR/$f"
  chmod +x "$BIN_DIR/$f"
  _VENDORED="$_VENDORED $f"
  echo "  installed $BIN_DIR/$f"
done

# --- substrate tools (EBR cross-machine propagation) -------------------------
# Vendored copies of the substrate fleet tools — brain-sync, vault-autosync,
# the sovereign git remote-helper, the substrate guard hook, and the M3
# export/import/merge/pubkey tools. Installing these here makes ./install.sh the
# SINGLE propagation path: `git pull && ./install.sh` deploys the whole substrate.
for f in brain-sync.sh vault-autosync.sh vault-write-tx.sh repo-write-tx.sh \
         vault-submod-push.sh substrate-health.sh substrate-search \
         walk-session-jsonl-nightly.sh walk-tmux-logs-nightly.sh \
         git-remote-verum \
         mae-pulse-daemon.mjs mae-pulse-status.mjs verum-vrm3.mjs \
         claude-hook-substrate-guard.mjs \
         claude-hook-memory-hygiene.mjs memory-hygiene-audit.mjs \
         mae-substrate-export.mjs mae-substrate-import.mjs mae-substrate-merge.mjs mae-verum-pubkeys.mjs; do
  if [ -f "$SCRIPT_DIR/bin/$f" ]; then
    cp "$SCRIPT_DIR/bin/$f" "$BIN_DIR/$f"
    chmod +x "$BIN_DIR/$f"
    _VENDORED="$_VENDORED $f"
    echo "  installed $BIN_DIR/$f"
  else
    echo "  (skipping $f: not vendored in bin/)"
  fi
done

# --- propagation self-check (loud failure on unvendored bin/ tools) ----------
# Forensic lesson (2026-06-26, fix commit ab30be6): a tool placed in bin/ but NOT
# named in a vendor for-loop above is silently skipped while install.sh still exits
# 0 — which makes "all nodes synced" a lie (see the 2026-06-25/26 install.sh arc).
# This guard walks bin/ and FAILS LOUDLY if any *.mjs/*.sh there went uninstalled.
VENDOR_DRIFT=0
for src in "$SCRIPT_DIR"/bin/*.mjs "$SCRIPT_DIR"/bin/*.sh; do
  [ -e "$src" ] || continue   # tolerate an empty glob
  base="$(basename "$src")"
  case " $_VENDORED " in
    *" $base "*) : ;;          # installed by a vendor for-loop above — good
    *)
      echo "  ⚠ PROPAGATION GAP: bin/$base is in bin/ but NOT in any install.sh vendor for-loop — it will NOT reach peers" >&2
      VENDOR_DRIFT=1
      ;;
  esac
done
if [ "$VENDOR_DRIFT" -eq 0 ]; then
  echo "  ✓ propagation self-check: every bin/*.{mjs,sh} is vendored"
fi

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

# PreToolUse(Write|Edit|NotebookEdit) -> memory-hygiene guard
if not has_command(pt, "claude-hook-memory-hygiene.mjs"):
    pt.append({
        "matcher": "Write|Edit|NotebookEdit",
        "hooks": [{"type": "command", "command": "node $HOME/.bin/claude-hook-memory-hygiene.mjs"}],
    })
    changed = True
    print("  registered PreToolUse(Write|Edit|NotebookEdit) -> claude-hook-memory-hygiene.mjs")
else:
    print("  PreToolUse(Write|Edit|NotebookEdit) memory-hygiene guard already registered")

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

# --- mae-pulse-daemon (real-time substrate runtime) --------------------------
# Generates peers.json from operator's verum-ed25519 pub key + renders launchd
# plist. Runs ONLY if the operator's signing key exists locally (single-operator
# mesh; key replicated via initial setup).
PULSE_BIN="${HOME}/.bin/mae-pulse-daemon.mjs"
PULSE_KEY="${HOME}/.verum/operator-ed25519.key"
PULSE_PUB="${HOME}/.verum/operator-ed25519.pub"
PULSE_PEERS="${HOME}/.local/share/mae-substrate/pulse/peers.json"
PULSE_PLIST_SRC="$SCRIPT_DIR/runtime/launchd/com.mae.pulse-daemon.plist"

if [ -f "$PULSE_BIN" ] && [ -f "$PULSE_KEY" ] && [ -f "$PULSE_PUB" ]; then
  mkdir -p "$(dirname "$PULSE_PEERS")"
  if [ ! -f "$PULSE_PEERS" ] || ! grep -q "pub_key_pem" "$PULSE_PEERS" 2>/dev/null; then
    # Generate peers.json from pub key (idempotent — overwrites only on key change)
    PUB_PEM=$(awk 'NR==1{printf "%s", $0; next}{printf "\\n%s", $0}' "$PULSE_PUB")
    cat > "$PULSE_PEERS" <<EOF
{
  "noodles":  { "ip": "192.168.100.2",  "port": 38478, "pub_key_pem": "$PUB_PEM" },
  "sequoia":  { "ip": "192.168.100.14", "port": 38478, "pub_key_pem": "$PUB_PEM" },
  "tunafish": { "ip": "192.168.100.10", "port": 38478, "pub_key_pem": "$PUB_PEM" }
}
EOF
    echo "  generated $PULSE_PEERS"
  else
    echo "  peers.json already present ($PULSE_PEERS)"
  fi
  if [ "$(uname)" = "Darwin" ] && [ -f "$PULSE_PLIST_SRC" ]; then
    PULSE_PLIST_DEST="${HOME}/Library/LaunchAgents/com.mae.pulse-daemon.plist"
    # Discover node binary path (Apple Silicon → /opt/homebrew, Intel → /usr/local).
    NODE_BIN="$(command -v node 2>/dev/null || true)"
    if [ -z "$NODE_BIN" ]; then
      echo "  ⚠ node not found in PATH — mae-pulse-daemon plist needs manual node path"
    else
      sed -e "s|\$NODE_BIN|${NODE_BIN}|g" -e "s|\$HOME|${HOME}|g" "$PULSE_PLIST_SRC" > "$PULSE_PLIST_DEST"
      launchctl unload "$PULSE_PLIST_DEST" 2>/dev/null || true
      launchctl load "$PULSE_PLIST_DEST"
      echo "  installed mae-pulse-daemon at $PULSE_PLIST_DEST (node=$NODE_BIN)"
    fi
  fi
else
  echo "  (skipping mae-pulse-daemon: missing $PULSE_BIN or $PULSE_KEY)"
fi

# --- substrate crons (per-host, idempotent) ----------------------------------
# vault-autosync on ALL hosts; brain-sync per-host with a staggered minute and a
# BRAIN_MACHINES list that names the OTHER two peers. Idempotent: read current
# crontab, strip our marked lines, re-add. Detect host via `hostname -s`.
HOST_SHORT="$(hostname -s 2>/dev/null || hostname)"
# Mesh identity is keyed on the RESERVED LAN IP, not hostname — hostnames don't always match
# the mesh short-name (e.g. sequoia's hostname is 'Ramenes-MacBook-Pro-7'). Fall back to hostname.
# ifconfig lives in /sbin (often absent from a minimal cron/ssh PATH) — call it absolutely,
# fall back to PATH ifconfig, then `ip` (Linux). Without this LAN_IP is empty -> misdetect.
LAN_IP="$( { /sbin/ifconfig 2>/dev/null || ifconfig 2>/dev/null || ip -4 addr 2>/dev/null; } | grep -oE '192\.168\.100\.[0-9]+' | head -1)"
case "$LAN_IP" in
  192.168.100.2)                  HOST_MESH=noodles ;;
  192.168.100.14)                 HOST_MESH=sequoia ;;
  192.168.100.10|192.168.100.12)  HOST_MESH=tunafish ;;
  *)                              HOST_MESH="$HOST_SHORT" ;;
esac
mkdir -p "$HOME/.claude-tmp"
# Write mesh-canonical hostname for any daemons that need it (e.g. mae-pulse-daemon
# — sequoia's `hostname -s` returns "Ramenes-MacBook-Pro-7", not "sequoia").
mkdir -p "$HOME/.local/share/mae-substrate"
echo -n "$HOST_MESH" > "$HOME/.local/share/mae-substrate/.host-mesh"
echo "[memory-oracle] installing substrate crons for mesh node '$HOST_MESH' (host $HOST_SHORT, ip ${LAN_IP:-?})..."

VAULT_MARK="# memory-oracle:vault-autosync"
BRAIN_MARK="# memory-oracle:brain-sync"
HYGIENE_MARK="# memory-oracle:memory-hygiene-audit"
WALKER_MARK="# memory-oracle:walker-current"
VAULT_LINE="*/3 * * * * \$HOME/.bin/vault-autosync.sh >> \$HOME/.claude-tmp/vault-autosync.log 2>&1 $VAULT_MARK"
WALKER_LINE="*/5 * * * * \$HOME/.bin/walk-session-jsonl-nightly.sh walk-tmux-logs-nightly.sh --current >> \$HOME/.claude-tmp/walk-session-jsonl-nightly.log 2>&1 $WALKER_MARK"
HYGIENE_LINE="0 10 * * * \$HOME/.bin/memory-hygiene-audit.mjs >> \$HOME/.claude-tmp/memory-hygiene-audit.log 2>&1 $HYGIENE_MARK"

case "$HOST_MESH" in
  noodles)  BRAIN_SCHED="*/15 * * * *";       BRAIN_MACHINES="local,sequoia,tunafish" ;;
  sequoia)  BRAIN_SCHED="5,20,35,50 * * * *"; BRAIN_MACHINES="local,noodles,tunafish" ;;
  tunafish) BRAIN_SCHED="10,25,40,55 * * * *";BRAIN_MACHINES="local,noodles,sequoia" ;;
  *)        BRAIN_SCHED="";                    BRAIN_MACHINES="" ;;
esac

# current crontab (empty if none), with our marked lines stripped
# strip BOTH our marked lines AND any pre-existing unmarked vault-autosync/brain-sync
# lines (from manual setups) so re-running never duplicates the cron.
CURRENT_CRON="$(crontab -l 2>/dev/null | grep -vE 'vault-autosync\.sh|brain-sync\.sh|memory-hygiene-audit\.mjs|walk-session-jsonl-nightly\.sh --current' || true)"
NEW_CRON="$CURRENT_CRON
$VAULT_LINE
$WALKER_LINE
$HYGIENE_LINE"
echo "  + vault-autosync: */3 (all hosts)"
echo "  + walker --current: */5 (all hosts) — keeps live session BM25-searchable"
echo "  + memory-hygiene-audit: daily 10:00 (all hosts)"
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

# Non-zero exit if the propagation self-check found unvendored bin/ tools.
# Deliberately the LAST thing the script does so all install work still completes.
if [ "${VENDOR_DRIFT:-0}" -ne 0 ]; then
  echo "" >&2
  echo "install.sh: COMPLETED WITH PROPAGATION GAPS (see ⚠ above)." >&2
  echo "Add each flagged bin/ tool to a vendor for-loop, then re-run. Until then," >&2
  echo "do NOT claim peers are synced — exit-code 0 would be a lie." >&2
  exit 17
fi
