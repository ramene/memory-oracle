#!/bin/bash
# walk-session-jsonl-nightly.sh — Task #88. Nightly per-session JSONL summarizer.
#
# Walks ~/.claude/projects/*/*.jsonl and emits one
# ~/.claude/projects/_runtime/memory/session-<id>-summary.md per session,
# containing DERIVED SIGNALS (not raw content): hook-fire timeline,
# banner-emission count, compact markers, last 5 real user prompts as
# keyword bag, tool-use frequency, first/last message timestamps.
#
# Never indexes full session content — only derived signals. The raw
# JSONL stays where it is; if someone needs verbatim lines, that's
# `memory-cite --session <id> --grep <pattern>`.
#
# Schedule (cron, 03:00 local Central/Merida — after APAC close, before US
# pre-market, lowest active-session count):
#   0 3 * * * /Users/ramene/.bin/walk-session-jsonl-nightly.sh >> $HOME/.claude-tmp/walk-session-jsonl-nightly.log 2>&1
#
# Guard against re-summarizing during the same night: skip if the session's
# summary file exists AND was written within MIN_RESUMMARIZE_SECS of the
# JSONL's current mtime (default 300s = 5min).
#
# Usage:
#   walk-session-jsonl-nightly.sh                # all sessions, respect mtime guard
#   walk-session-jsonl-nightly.sh --force        # re-summarize even if guard says skip
#   walk-session-jsonl-nightly.sh --session=<id> # one session only (substring match)
#   walk-session-jsonl-nightly.sh --current      # ONLY today's live transcript (the most
#                                                # recently-modified jsonl across all projects).
#                                                # Implies --force. Closes the "today's session
#                                                # isn't BM25-searchable yet" coverage gap.
#                                                # Task #116 (2026-06-05).
#   walk-session-jsonl-nightly.sh --dry-run      # show what would be processed
#   walk-session-jsonl-nightly.sh --help

set -u

PROJECTS_ROOT="${HOME}/.claude/projects"
OUT_DIR="${HOME}/.claude/projects/_runtime/memory"
MIN_RESUMMARIZE_SECS="${MIN_RESUMMARIZE_SECS:-300}"

# ─── pile-up guard (2026-06-26 incident) ────────────────────────────────────
# Before this guard, the */5 cron could fire a new walker while the previous
# was still processing an 8+ MB live session JSONL. Multiple concurrent
# walkers each spawned memory-index-build.mjs children that piled up to
# load avg 749. Lock guarantees AT MOST ONE walker runs at a time.
# mkdir-atomic, same pattern as vault-write-tx.sh.
LOCK_DIR="${HOME}/.claude-tmp/walker-current.lock"
if mkdir "$LOCK_DIR" 2>/dev/null; then
  echo $$ > "$LOCK_DIR/pid"
  trap 'rm -rf "$LOCK_DIR"' EXIT
else
  # Lock exists — check if holder is alive
  if [ -f "$LOCK_DIR/pid" ]; then
    HOLDER_PID=$(cat "$LOCK_DIR/pid" 2>/dev/null || echo "")
    if [ -n "$HOLDER_PID" ] && kill -0 "$HOLDER_PID" 2>/dev/null; then
      # Holder is alive — skip cleanly (cron will retry next tick)
      echo "[$(date -u +%FT%TZ)] walker skip: pid=$HOLDER_PID still running" >&2
      exit 0
    fi
  fi
  # Stale lock (holder dead or no pid file) — steal it
  rm -rf "$LOCK_DIR"
  mkdir "$LOCK_DIR" 2>/dev/null
  echo $$ > "$LOCK_DIR/pid"
  trap 'rm -rf "$LOCK_DIR"' EXIT
  echo "[$(date -u +%FT%TZ)] walker stole stale lock" >&2
fi

# Args
FORCE=0
DRY=0
CURRENT=0
ONLY_SESSION=""
for arg in "$@"; do
  case "$arg" in
    --force)   FORCE=1 ;;
    --dry-run) DRY=1 ;;
    --current) CURRENT=1; FORCE=1 ;;  # --current implies --force (live transcript = always changing)
    --session=*) ONLY_SESSION="${arg#--session=}" ;;
    -h|--help) sed -n '2,27p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
  esac
done

mkdir -p "$OUT_DIR"

# Build job list
JOBS=()
if [ "$CURRENT" = "1" ]; then
  # --current: pick ONLY the most-recently-modified jsonl across all projects.
  # This is the live transcript (the one currently being written to by the
  # active Claude Code session). Closes the BM25-coverage gap where today's
  # session isn't yet searchable. Bypasses the mtime guard (set above).
  LATEST=$(find "$PROJECTS_ROOT" -maxdepth 2 -name "*.jsonl" -type f -exec stat -f '%m %N' {} \; 2>/dev/null | sort -rn | head -1 | cut -d' ' -f2-)
  if [ -n "$LATEST" ] && [ -f "$LATEST" ]; then
    JOBS+=("$LATEST")
    echo "[$(date -u +'%FT%TZ')] --current: $LATEST"
  else
    echo "[$(date -u +'%FT%TZ')] --current: no JSONLs found under $PROJECTS_ROOT"
    exit 0
  fi
else
  while IFS= read -r f; do
    [ -n "$f" ] && JOBS+=("$f")
  done < <(find "$PROJECTS_ROOT" -maxdepth 2 -name "*.jsonl" -type f 2>/dev/null)
fi

if [ -n "$ONLY_SESSION" ]; then
  FILTERED=()
  for f in "${JOBS[@]}"; do
    case "$(basename "$f")" in *"$ONLY_SESSION"*) FILTERED+=("$f");; esac
  done
  JOBS=("${FILTERED[@]}")
fi

[ "${#JOBS[@]}" -eq 0 ] && { echo "no sessions to process"; exit 0; }

echo "[$(date -u +'%FT%TZ')] walker start: ${#JOBS[@]} candidate session(s) (force=$FORCE dry-run=$DRY)"

PROCESSED=0
SKIPPED=0
FAILED=0
for FPATH in "${JOBS[@]}"; do
  SID=$(basename "$FPATH" .jsonl)
  SUMMARY="$OUT_DIR/session-${SID}-summary.md"

  # mtime guard
  if [ "$FORCE" = "0" ] && [ -f "$SUMMARY" ]; then
    JSONL_MTIME=$(stat -f '%m' "$FPATH" 2>/dev/null || echo 0)
    SUMMARY_MTIME=$(stat -f '%m' "$SUMMARY" 2>/dev/null || echo 0)
    DELTA=$((JSONL_MTIME - SUMMARY_MTIME))
    if [ "$DELTA" -lt "$MIN_RESUMMARIZE_SECS" ]; then
      SKIPPED=$((SKIPPED + 1))
      continue
    fi
  fi

  if [ "$DRY" = "1" ]; then
    SIZE=$(stat -f '%z' "$FPATH" 2>/dev/null || echo 0)
    echo "  [dry-run] would process $SID ($(awk -v b="$SIZE" 'BEGIN{if(b>1073741824)printf"%.1f GB",b/1073741824;else if(b>1048576)printf"%.0f MB",b/1048576;else if(b>1024)printf"%.0f KB",b/1024;else printf"%d B",b}'))"
    continue
  fi

  python3 - "$FPATH" "$SUMMARY" <<'PY' && PROCESSED=$((PROCESSED + 1)) || FAILED=$((FAILED + 1))
import sys, os, json, re, tempfile, collections, datetime

jsonl_path, summary_path = sys.argv[1], sys.argv[2]
sid = os.path.basename(jsonl_path)[:-len('.jsonl')]
project = os.path.basename(os.path.dirname(jsonl_path))

# ── INCREMENTAL STREAMING (2026-06-26 redesign) ──────────────────────────
# Persistent sidecar at ~/.claude/projects/_runtime/.offsets/<sid>.off tracks:
#   - last byte_offset processed (seek-resume point)
#   - cumulative aggregates (msg counts, tool counter, compact/banner lists)
# Next walker run: seek to byte_offset, process only NEW bytes, merge with
# loaded state. Reduces per-tick cost from O(session_size) to O(new_bytes).
# See project_walker_streaming_chunked_redesign_2026_06_26.md for design.
SIDECAR_VERSION = 1
OFFSETS_DIR = os.path.expanduser('~/.claude/projects/_runtime/.offsets')
os.makedirs(OFFSETS_DIR, exist_ok=True)
sidecar_path = os.path.join(OFFSETS_DIR, f'{sid}.off')

def load_state():
    if not os.path.exists(sidecar_path):
        return None
    try:
        with open(sidecar_path) as f:
            return json.loads(f.read())
    except Exception:
        return None

# ── extract signals (streaming, never load full content) ──────────────────
NOISE_PREFIXES = ('<task-notification', '<system-reminder', '<command-name', '[Request interrupted', 'Caveat:')
COMPACT_MARKER = 'This session is being continued from a previous conversation'

file_size = os.path.getsize(jsonl_path)
loaded = load_state()
# Validate sidecar: same version + offset must not exceed file size (catches
# truncation / session-replaced cases — start fresh in those scenarios).
if loaded and loaded.get('version') == SIDECAR_VERSION and loaded.get('byte_offset', 0) <= file_size:
    stats = {
        'total_lines': loaded.get('total_lines', 0),
        'msg_user': loaded.get('msg_user', 0),
        'msg_assistant': loaded.get('msg_assistant', 0),
        'msg_system': loaded.get('msg_system', 0),
        'msg_other': loaded.get('msg_other', 0),
        'first_ts': loaded.get('first_ts'),
        'last_ts': loaded.get('last_ts'),
        # sidecar stores [line, ts] arrays (JSON-native); restore as tuples
        'compact_markers': [tuple(x) for x in loaded.get('compact_markers', [])],
        'banner_emissions': [tuple(x) for x in loaded.get('banner_emissions', [])],
        'tool_use_counter': collections.Counter(loaded.get('tool_use_counter', {})),
        'recent_user_prompts': list(loaded.get('recent_user_prompts', [])),
        'parse_errors': loaded.get('parse_errors', 0),
    }
    start_offset = loaded.get('byte_offset', 0)
    start_line_no = loaded.get('total_lines', 0)
else:
    stats = {
        'total_lines': 0, 'msg_user': 0, 'msg_assistant': 0, 'msg_system': 0,
        'msg_other': 0, 'first_ts': None, 'last_ts': None,
        'compact_markers': [], 'banner_emissions': [],
        'tool_use_counter': collections.Counter(), 'recent_user_prompts': [],
        'parse_errors': 0,
    }
    start_offset = 0
    start_line_no = 0

KEYWORD_RE = re.compile(r"[A-Za-z][A-Za-z0-9_-]{2,}")
STOP = set('the of and to in a for is on it as that this be with by are not or an at if from we i you your our my their his her them they you our'.split())

def maybe_collect_prompt(text):
    t = (text or '').strip()
    if not t or len(t) < 20:
        return
    if any(t.startswith(n) for n in NOISE_PREFIXES):
        return
    if t.startswith(COMPACT_MARKER):
        return
    # keep only last 5
    stats['recent_user_prompts'].append(t)
    if len(stats['recent_user_prompts']) > 5:
        stats['recent_user_prompts'].pop(0)

# Incremental read — seek to recorded offset, continue line numbering
with open(jsonl_path, errors='replace') as f:
    f.seek(start_offset)
    line_no = start_line_no
    for line in f:
        line_no += 1
        stats['total_lines'] = line_no
        line = line.strip()
        if not line:
            continue
        try:
            d = json.loads(line)
        except Exception:
            stats['parse_errors'] += 1
            continue

        ts = d.get('timestamp', '')
        if ts:
            if stats['first_ts'] is None:
                stats['first_ts'] = ts
            stats['last_ts'] = ts

        t = d.get('type', 'other')
        msg = d.get('message', {}) if isinstance(d.get('message'), dict) else {}
        role = msg.get('role', '')
        content = msg.get('content', '')

        if t == 'user':
            stats['msg_user'] += 1
            text = ''
            if isinstance(content, str):
                text = content
            elif isinstance(content, list):
                for c in content:
                    if isinstance(c, dict) and c.get('type') == 'text':
                        text = c.get('text', '')
                        break
            if text.startswith(COMPACT_MARKER):
                stats['compact_markers'].append((line_no, ts))
            else:
                maybe_collect_prompt(text)

        elif t == 'assistant':
            stats['msg_assistant'] += 1
            if isinstance(content, list):
                for c in content:
                    if not isinstance(c, dict):
                        continue
                    ctype = c.get('type', '')
                    if ctype == 'tool_use':
                        stats['tool_use_counter'][c.get('name', 'unknown')] += 1
                    elif ctype == 'text':
                        txt = c.get('text', '')
                        if txt.startswith('<ebr-substrate-banner>'):
                            stats['banner_emissions'].append((line_no, ts))
            elif isinstance(content, str):
                if content.startswith('<ebr-substrate-banner>'):
                    stats['banner_emissions'].append((line_no, ts))

        elif t == 'system':
            stats['msg_system'] += 1
        else:
            stats['msg_other'] += 1

# ── persist sidecar (the streaming foundation) ────────────────────────────
size_bytes = os.path.getsize(jsonl_path)
new_state = {
    'version': SIDECAR_VERSION,
    'session_id': sid,
    'byte_offset': size_bytes,
    'total_lines': stats['total_lines'],
    'msg_user': stats['msg_user'],
    'msg_assistant': stats['msg_assistant'],
    'msg_system': stats['msg_system'],
    'msg_other': stats['msg_other'],
    'first_ts': stats['first_ts'],
    'last_ts': stats['last_ts'],
    'compact_markers': [list(x) for x in stats['compact_markers']],
    'banner_emissions': [list(x) for x in stats['banner_emissions']],
    'tool_use_counter': dict(stats['tool_use_counter']),
    'recent_user_prompts': stats['recent_user_prompts'],
    'parse_errors': stats['parse_errors'],
    'updated_at': datetime.datetime.utcnow().strftime('%Y-%m-%dT%H:%M:%SZ'),
}
fd, tmp = tempfile.mkstemp(dir=OFFSETS_DIR, prefix='.tmp-off-')
try:
    with os.fdopen(fd, 'w') as wf:
        json.dump(new_state, wf)
    os.replace(tmp, sidecar_path)
except Exception:
    if os.path.exists(tmp):
        os.unlink(tmp)
    raise

# Visibility line (stderr — observable in cron log without polluting stdout)
processed_bytes = size_bytes - start_offset
sys.stderr.write(f'[walker] sid={sid[:8]} processed={processed_bytes} bytes (offset {start_offset} → {size_bytes}); cumulative lines={stats["total_lines"]}\n')

# ── render summary md ─────────────────────────────────────────────────────
def human(b):
    if b > 1073741824: return f"{b/1073741824:.2f} GB"
    if b > 1048576:    return f"{b/1048576:.1f} MB"
    if b > 1024:       return f"{b/1024:.0f} KB"
    return f"{b} B"

# top tools by use
top_tools = stats['tool_use_counter'].most_common(10)

# keyword bag from last 5 prompts
kw_seen = []
for p in stats['recent_user_prompts']:
    for w in KEYWORD_RE.findall(p):
        wl = w.lower()
        if wl in STOP or len(wl) < 3:
            continue
        if wl not in kw_seen:
            kw_seen.append(wl)
keyword_bag = ' '.join(kw_seen[:30])

# compact / banner views
compact_view = '\n'.join(f"  - line {ln} ({ts})" for ln, ts in stats['compact_markers'][-10:]) or '  (none)'
banner_view = '\n'.join(f"  - line {ln} ({ts})" for ln, ts in stats['banner_emissions'][-10:]) or '  (none — model never emitted post-compact)'

# Determine display project (e.g. "-Users-ramene--remote--plans-mae-monorepo-build")
display_project = project.replace('-Users-ramene-', '').replace('--', '/')

# Now timestamp in UTC for the summary
now_utc = datetime.datetime.utcnow().strftime('%Y-%m-%dT%H:%M:%SZ')

body = f"""---
name: session {sid[:8]} ({display_project}) — derived signals
description: Per-session signal summary auto-generated by walk-session-jsonl-nightly.sh. {stats['msg_user']} user msgs, {stats['msg_assistant']} assistant msgs, {len(stats['compact_markers'])} compact events, {len(stats['banner_emissions'])} banner emissions. File size {human(size_bytes)}, {stats['total_lines']} lines. Source of truth = raw JSONL at the path below; this file is a queryable derived index, never edit by hand.
metadata:
  type: reference
---

# Session {sid[:8]} — derived signals

| Field | Value |
|---|---|
| session_id | `{sid}` |
| project | `{display_project}` |
| path | `~/.claude/projects/{project}/{sid}.jsonl` |
| size | {human(size_bytes)} ({size_bytes:,} bytes) |
| total lines | {stats['total_lines']:,} |
| first message | {stats['first_ts'] or '(unknown)'} |
| last message | {stats['last_ts'] or '(unknown)'} |
| user msgs | {stats['msg_user']:,} |
| assistant msgs | {stats['msg_assistant']:,} |
| system msgs | {stats['msg_system']:,} |
| other msgs | {stats['msg_other']:,} |
| compact events | {len(stats['compact_markers'])} |
| banner emissions | {len(stats['banner_emissions'])} |
| emit rate | {(len(stats['banner_emissions']) / max(1, len(stats['compact_markers'])) * 100):.1f}% (banner / compact) |
| parse errors | {stats['parse_errors']} |

## Recent compact markers (last 10)
{compact_view}

## Recent banner emissions (last 10)
{banner_view}

## Top tool usage
{chr(10).join(f"  - `{name}`: {count:,}" for name, count in top_tools) or '  (no tool_use messages)'}

## Recent user prompts (keyword bag, last 5 prompts)
{keyword_bag or '(no qualifying user prompts found)'}

## Cross-reference
- Hook fires for this session: see `reference_hook_fires_by_session.md` filtered to `{sid[:8]}`
- Verbatim look-up: `memory-cite --session {sid} --grep <pattern>`
- File metadata snapshot: `memory-stat {sid[:8]}`

---
_Auto-generated {now_utc} by `walk-session-jsonl-nightly.sh`. See [[feedback_memory_oracle_runtime_artifacts]]._
"""

# Atomic write
fd, tmp = tempfile.mkstemp(dir=os.path.dirname(summary_path), prefix='.tmp-summary-')
try:
    with os.fdopen(fd, 'w') as wf:
        wf.write(body)
    os.replace(tmp, summary_path)
except Exception:
    if os.path.exists(tmp):
        os.unlink(tmp)
    raise
PY
done

echo "[$(date -u +'%FT%TZ')] walker done: processed=$PROCESSED skipped=$SKIPPED failed=$FAILED"

# After the walker writes derived summaries, rebuild the BM25 index so new files
# are queryable immediately (defense-in-depth on the launchd watcher, Task #113).
# FIX 2026-06-25: this block was unreachable (it sat AFTER `exit 0`) and hardcoded
# /usr/local/bin/node (breaks on arm64/tunafish). Moved above the exit + portable node.
if [ "$PROCESSED" -gt 0 ] && [ -f "$HOME/.bin/memory-index-build.mjs" ]; then
  NODE_BIN="$(command -v node || echo /usr/local/bin/node)"
  echo "[$(date -u +'%FT%TZ')] triggering memory-index-build after $PROCESSED new summaries"
  "$NODE_BIN" "$HOME/.bin/memory-index-build.mjs" >> "$HOME/.claude-tmp/walk-session-jsonl-nightly.log" 2>&1
fi

exit 0
