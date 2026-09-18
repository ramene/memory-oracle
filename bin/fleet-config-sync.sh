#!/usr/bin/env bash
# fleet-config-sync — propagate the canonical laws.md + ALL discipline hooks from noodles (LEAD/author)
# to the blvck-pi durable master AND every fleet host's LOCAL copies, so every session runs identical
# laws + hooks + brain. Local copies (never network symlinks) → reboot-safe + no per-command Pi dependency.
# Idempotent, backs up before overwrite, smoke-tests gating hooks, verifies hashes. RUN AFTER ANY laws/hook edit.
# (Operator source-of-truth ruling 2026-09-16: "Pi single-source + local hooks".)
set -uo pipefail
CANON="$HOME/.local/share/journal/.claude/laws.md"
HOOKS=(claude-hook-session-start.sh claude-hook-prefer-substrate-search.sh claude-hook-scratch-nfs-guard.sh \
       claude-hook-substrate-guard.mjs claude-hook-recall-first-guard.sh claude-hook-memory-hygiene.mjs \
       claude-hook-capture.sh claude-hook-zerohits.sh claude-hook-user-prompt-submit.sh)
REMOTES=(sequoia tunafish)
STAGE="$HOME/ingest-scratch/scratch/fleet-config-sync"; mkdir -p "$STAGE/hooks"

echo "== stage canonical (noodles) → NFS =="
cp -L "$CANON" "$STAGE/laws.md"
for hk in "${HOOKS[@]}"; do cp -L "$HOME/.bin/$hk" "$STAGE/hooks/$hk" 2>/dev/null || echo "  WARN missing on noodles: $hk"; done

echo "== write canonical manifest (drift-check reads this) =="
MAN="$HOME/ingest-scratch/state/fleet-config-MANIFEST.sha"; mkdir -p "$(dirname "$MAN")"
{ (cd "$STAGE" && shasum laws.md); for hk in "${HOOKS[@]}"; do (cd "$STAGE/hooks" && shasum "$hk"); done; } > "$MAN"
echo "  manifest: $MAN ($(wc -l < "$MAN" | tr -d ' ') entries)"

echo "== push to blvck-pi durable master (~/.fleet-config-master) =="
# rsync's dir-copy silently no-op'd here; tar-over-ssh is reliable for the hooks dir.
{ ssh -o ConnectTimeout=15 blvck-pi 'mkdir -p ~/.fleet-config-master/hooks' \
  && rsync -q -e 'ssh -o ConnectTimeout=15' "$STAGE/laws.md" blvck-pi:.fleet-config-master/laws.md \
  && tar -C "$STAGE/hooks" -cf - . | ssh -o ConnectTimeout=15 blvck-pi 'tar -C ~/.fleet-config-master/hooks -xf -' \
  && echo "  pi master updated" ; } || echo "  WARN pi master push failed (non-fatal; local copies still authoritative)"

for h in "${REMOTES[@]}"; do
  echo "== sync → $h (local copies) =="
  ssh -o ConnectTimeout=15 "$h" 'bash -s' <<'RE'
TS=$(date +%Y%m%d-%H%M%S); BK="$HOME/.cache/fleet-config-sync-$TS"; mkdir -p "$BK/hooks"
S="$HOME/ingest-scratch/scratch/fleet-config-sync"
[ -f "$S/laws.md" ] || { echo "  FATAL: NFS stage not visible"; exit 9; }
mkdir -p "$HOME/.local/share/journal/.claude"
[ -f "$HOME/.local/share/journal/.claude/laws.md" ] && cp -L "$HOME/.local/share/journal/.claude/laws.md" "$BK/laws.md.bak"
cp "$S/laws.md" "$HOME/.local/share/journal/.claude/laws.md"
for hk in "$S"/hooks/*; do b=$(basename "$hk"); [ -e "$HOME/.bin/$b" ] && cp -L "$HOME/.bin/$b" "$BK/hooks/$b.bak" 2>/dev/null; rm -f "$HOME/.bin/$b"; cp "$hk" "$HOME/.bin/$b"; chmod +x "$HOME/.bin/$b"; done
# smoke-test the bash gates on a benign command (must not block)
for g in claude-hook-prefer-substrate-search.sh claude-hook-scratch-nfs-guard.sh claude-hook-recall-first-guard.sh; do
  rc=$(echo '{"tool_input":{"command":"echo hi"}}' | "$HOME/.bin/$g" >/dev/null 2>&1; echo $?)
  [ "$rc" = 0 ] || echo "  WARN $g exited $rc on benign input (backup: $BK)"
done
echo "  ok laws=$(shasum "$HOME/.local/share/journal/.claude/laws.md"|cut -c1-8) (backup: $BK)"
RE
done
echo "== done =="
