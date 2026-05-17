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

# --- SessionStart hook in claude settings ------------------------------------
SETTINGS="${HOME}/.claude/settings.json"
if [ -f "$SETTINGS" ]; then
  if grep -q "claude-hook-session-start.sh" "$SETTINGS"; then
    echo "  SessionStart hook already registered in $SETTINGS"
  else
    echo "  ⚠ Manually add this to $SETTINGS under 'hooks':"
    cat <<'EOF'
    "SessionStart": [
      {
        "matcher": "startup|resume|clear|compact",
        "hooks": [{"type": "command", "command": "$HOME/.bin/claude-hook-session-start.sh"}]
      }
    ]
EOF
  fi
else
  echo "  (skipping settings.json update: file not found)"
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

# --- initial index build -----------------------------------------------------
echo "[memory-oracle] building initial index..."
node "$BIN_DIR/memory-index-build.mjs"
node "$BIN_DIR/memory-structural-index.mjs"

echo ""
echo "[memory-oracle] install complete."
echo ""
echo "Try:    memory-search 'your topic here'"
echo "Or:     memory-cite SESSION_ID --info"
