#!/usr/bin/env bash
# fleet-config-drift-check — verify laws.md + all 9 hooks are IDENTICAL across noodles/sequoia/tunafish
# against the canonical manifest (written by fleet-config-sync.sh). Writes a fleet-wide drift status that
# the ⚖️ Laws footer displays on every prompt. THROTTLED to hourly (status-file TTL + NFS lock) so the
# prompt hook can call it every prompt while it only does real work once/hour. (operator: check every hour via hooks)
# Usage: fleet-config-drift-check.sh [--force]
set -uo pipefail
export PATH="$HOME/.bin:/usr/local/bin:/usr/bin:/bin:${PATH:-}"
NFS_STATE="$HOME/ingest-scratch/state"; LOCAL_STATE="$HOME/.local/state/fleet-config"
mkdir -p "$NFS_STATE" "$LOCAL_STATE" 2>/dev/null || true
SHARED="$NFS_STATE/fleet-drift-status.json"; LOCAL="$LOCAL_STATE/drift-status.json"
MANIFEST="$NFS_STATE/fleet-config-MANIFEST.sha"
TTL=3600
HOOKS="claude-hook-session-start.sh claude-hook-prefer-substrate-search.sh claude-hook-scratch-nfs-guard.sh claude-hook-substrate-guard.mjs claude-hook-recall-first-guard.sh claude-hook-memory-hygiene.mjs claude-hook-capture.sh claude-hook-zerohits.sh claude-hook-user-prompt-submit.sh"

# throttle: fresh shared status → just mirror locally + exit (no work)
if [ "${1:-}" != "--force" ] && [ -f "$SHARED" ]; then
  age=$(( $(date +%s) - $(stat -f %m "$SHARED" 2>/dev/null || stat -c %Y "$SHARED" 2>/dev/null || echo 0) ))
  [ "$age" -lt "$TTL" ] && { cp "$SHARED" "$LOCAL" 2>/dev/null; exit 0; }
fi
# NFS lock so only one host runs the fleet check per hour
LOCK="$NFS_STATE/.drift-check.lock"
if [ -f "$LOCK" ]; then
  lage=$(( $(date +%s) - $(stat -f %m "$LOCK" 2>/dev/null || stat -c %Y "$LOCK" 2>/dev/null || echo 0) ))
  [ "$lage" -lt 120 ] && { [ -f "$SHARED" ] && cp "$SHARED" "$LOCAL" 2>/dev/null; exit 0; }  # someone checking now
fi
echo "$$@$(hostname -s) $(date -u +%FT%TZ)" > "$LOCK" 2>/dev/null || true
trap 'rm -f "$LOCK" 2>/dev/null' EXIT

[ -f "$MANIFEST" ] || { echo '{"synced":null,"error":"no canonical manifest — run fleet-config-sync.sh","checked":"'"$(date -u +%FT%TZ)"'"}' | tee "$SHARED" > "$LOCAL"; exit 0; }
CANON=$(sort "$MANIFEST")

# per-host manifest computation (laws.md + hooks → "hash  basename"), sorted
COMPUTE='L="$HOME/.local/share/journal/.claude/laws.md"; shasum "$L" 2>/dev/null | awk "{print \$1\"  laws.md\"}"; for h in '"$HOOKS"'; do shasum "$HOME/.bin/$h" 2>/dev/null | awk -v n="$h" "{print \$1\"  \"n}"; done'

overall="synced"; drift_on=""; per_host=""
for host in noodles sequoia tunafish; do
  if [ "$host" = "noodles" ]; then man=$(eval "$COMPUTE" 2>/dev/null | sort); else man=$(ssh -o ConnectTimeout=8 "$host" "$COMPUTE" 2>/dev/null | sort); fi
  if [ -z "$man" ]; then st="unreachable"; overall="unknown"; drift_on="$drift_on $host(unreachable)";
  else
    diff=$(comm -3 <(printf '%s\n' "$man") <(printf '%s\n' "$CANON") 2>/dev/null | sed '/^[[:space:]]*$/d')
    if [ -n "$diff" ]; then st="drift"; [ "$overall" = "synced" ] && overall="drift"; drift_on="$drift_on $host"; else st="synced"; fi
  fi
  per_host="$per_host\"$host\":\"$st\","
done
per_host="{${per_host%,}}"
drift_on=$(echo "$drift_on" | sed 's/^ *//')
CHECKED="$(date -u +%FT%TZ)"
printf '{"synced":%s,"overall":"%s","hosts":%s,"drift_on":"%s","checked":"%s","by":"%s"}\n' \
  "$([ "$overall" = synced ] && echo true || echo false)" "$overall" "$per_host" "$drift_on" "$CHECKED" "$(hostname -s)" \
  | tee "$SHARED" > "$LOCAL"
