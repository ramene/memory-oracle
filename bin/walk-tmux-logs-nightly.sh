#!/bin/bash
# walk-tmux-logs-nightly.sh — Phase 1.5 chunked chronicle for tmux-logs.
#
# Mirrors walk-session-jsonl-nightly.sh's pattern, but for raw tmux session
# captures at ~/.local/share/tmux-logs/YYYY/MM/DD/transcripts/*.log. The
# transcripts/ subdir is the cleanest source — it's the JSON-equivalent
# format (one event per line). term/, streaming/, hooks/ are deferred to
# Phase B.
#
# Output layout (BM25-discoverable via Phase 2 indexer extension):
#   ~/.claude/projects/_runtime/memory/tmux/<YYYY-MM-DD>-<sessionname>/
#     chunk-001.md      lines 1-1000 of the log, frozen
#     chunk-002.md      lines 1001-2000, frozen
#     chunk-NNN.md      current/growing chunk
#     HEAD.md           chunk index + rollup
#
# Sidecar offset tracking (streaming O(new_bytes) per tick):
#   ~/.claude/projects/_runtime/.offsets/tmux-<YYYY-MM-DD>-<sessionname>.off
#
# CPU-friendly defaults (after 2026-06-26 load-avg-749 incident):
#   - Serial processing (no parallel xargs)
#   - File-size cap (default 20 MB; --max-bytes overrides)
#   - mkdir-atomic lock (same as JSONL walker)
#   - Skip files <100 bytes (almost certainly noise)
#
# Usage:
#   walk-tmux-logs-nightly.sh                    # last 30 days, transcripts/ only
#   walk-tmux-logs-nightly.sh --days N           # last N days
#   walk-tmux-logs-nightly.sh --all              # all-time (SLOW)
#   walk-tmux-logs-nightly.sh --date YYYY-MM-DD  # single day only
#   walk-tmux-logs-nightly.sh --dry-run          # show what would be processed
#   walk-tmux-logs-nightly.sh --max-bytes N      # cap file size (default 20M)
#   walk-tmux-logs-nightly.sh --help

set -u

TMUX_LOGS_ROOT="${HOME}/.local/share/tmux-logs"
# MVP: file tmux-log chunks under sessions/tmux-<key>/ so the existing Phase 2
# memory-index-build watcher picks them up via the same _sessions code path.
# Cleaner long-term: extend the indexer to scan _runtime/memory/tmux/ as
# synthetic project _tmux. For tonight: stay under sessions/ namespace.
OUT_ROOT="${HOME}/.claude/projects/_runtime/memory/sessions"
TMUX_KEY_PREFIX="tmux-"
OFFSETS_DIR="${HOME}/.claude/projects/_runtime/.offsets"
DAYS=30
ALL=0
ONE_DATE=""
DRY=0
MAX_BYTES=20971520   # 20 MB

# ─── pile-up guard (mkdir-atomic, same as JSONL walker) ────────────────────
LOCK_DIR="${HOME}/.claude-tmp/tmux-walker.lock"
if mkdir "$LOCK_DIR" 2>/dev/null; then
  echo $$ > "$LOCK_DIR/pid"
  trap 'rm -rf "$LOCK_DIR"' EXIT
else
  if [ -f "$LOCK_DIR/pid" ]; then
    HOLDER_PID=$(cat "$LOCK_DIR/pid" 2>/dev/null || echo "")
    if [ -n "$HOLDER_PID" ] && kill -0 "$HOLDER_PID" 2>/dev/null; then
      echo "[$(date -u +%FT%TZ)] tmux-walker skip: pid=$HOLDER_PID still running" >&2
      exit 0
    fi
  fi
  rm -rf "$LOCK_DIR"
  mkdir "$LOCK_DIR" 2>/dev/null
  echo $$ > "$LOCK_DIR/pid"
  trap 'rm -rf "$LOCK_DIR"' EXIT
fi

for arg in "$@"; do
  case "$arg" in
    --all) ALL=1 ;;
    --days=*) DAYS="${arg#--days=}" ;;
    --days) shift; DAYS="$1" ;;
    --date=*) ONE_DATE="${arg#--date=}" ;;
    --date) shift; ONE_DATE="$1" ;;
    --dry-run) DRY=1 ;;
    --max-bytes=*) MAX_BYTES="${arg#--max-bytes=}" ;;
    --max-bytes) shift; MAX_BYTES="$1" ;;
    -h|--help) sed -n '2,30p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
  esac
done

mkdir -p "$OUT_ROOT" "$OFFSETS_DIR"

# Build job list — find transcripts/*.log files in scope
if [ -n "$ONE_DATE" ]; then
  YY=$(echo "$ONE_DATE" | cut -d- -f1); MM=$(echo "$ONE_DATE" | cut -d- -f2); DD=$(echo "$ONE_DATE" | cut -d- -f3)
  SEARCH_ROOT="$TMUX_LOGS_ROOT/$YY/$MM/$DD/transcripts"
  [ -d "$SEARCH_ROOT" ] || { echo "  $SEARCH_ROOT not found"; exit 0; }
  JOBS=$(find "$SEARCH_ROOT" -name "*.log" -type f 2>/dev/null)
elif [ "$ALL" -eq 1 ]; then
  JOBS=$(find "$TMUX_LOGS_ROOT" -path "*/transcripts/*.log" -type f 2>/dev/null)
else
  JOBS=$(find "$TMUX_LOGS_ROOT" -path "*/transcripts/*.log" -type f -mtime -"$DAYS" 2>/dev/null)
fi

JOB_COUNT=$(echo "$JOBS" | grep -c .)
echo "[$(date -u +%FT%TZ)] tmux-walker start: $JOB_COUNT transcripts in scope (--days=$DAYS --all=$ALL --date=$ONE_DATE)"

PROCESSED=0; SKIPPED=0; FAILED=0; TOO_BIG=0

while IFS= read -r FPATH; do
  [ -z "$FPATH" ] && continue

  FILESIZE=$(stat -f '%z' "$FPATH" 2>/dev/null || echo 0)
  [ "$FILESIZE" -lt 100 ] && { SKIPPED=$((SKIPPED+1)); continue; }
  if [ "$FILESIZE" -gt "$MAX_BYTES" ]; then
    TOO_BIG=$((TOO_BIG+1))
    [ "$DRY" -eq 1 ] && echo "  [over-cap] $FPATH ($FILESIZE > $MAX_BYTES)"
    continue
  fi

  # Derive a key: YYYY-MM-DD-<basename-without-.log>
  DATE_PART=$(echo "$FPATH" | sed -E 's|.*/tmux-logs/([0-9]{4})/([0-9]{2})/([0-9]{2})/.*|\1-\2-\3|')
  SESS_PART=$(basename "$FPATH" .log)
  KEY="${TMUX_KEY_PREFIX}${DATE_PART}-${SESS_PART}"
  CHUNK_DIR="$OUT_ROOT/$KEY"
  SIDECAR="$OFFSETS_DIR/${KEY}.off"

  if [ "$DRY" -eq 1 ]; then
    echo "  [dry-run] $KEY  $(awk -v b="$FILESIZE" 'BEGIN{if(b>1048576)printf"%.1f MB",b/1048576;else printf"%d KB",b/1024}')"
    continue
  fi

  mkdir -p "$CHUNK_DIR"

  python3 - "$FPATH" "$CHUNK_DIR" "$SIDECAR" "$KEY" <<'PY' && PROCESSED=$((PROCESSED+1)) || FAILED=$((FAILED+1))
import sys, os, json, re, tempfile, datetime, hashlib

fpath, chunk_dir, sidecar_path, key = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4]

CHUNK_LINES = 1000
SIDECAR_VERSION = 1

def load_sidecar():
    if not os.path.exists(sidecar_path):
        return None
    try:
        with open(sidecar_path) as f:
            return json.loads(f.read())
    except Exception:
        return None

file_size = os.path.getsize(fpath)
loaded = load_sidecar()
if loaded and loaded.get('version') == SIDECAR_VERSION and loaded.get('byte_offset', 0) <= file_size:
    start_offset = loaded.get('byte_offset', 0)
    start_line_no = loaded.get('total_lines', 0)
    current_chunk_id = loaded.get('current_chunk_id', 1)
else:
    start_offset = 0
    start_line_no = 0
    current_chunk_id = 1

# Strip ANSI escape codes — tmux-logs often contain them
ANSI_RE = re.compile(r'\x1b\[[0-9;]*[a-zA-Z]|\x1b\][^\x07]*\x07|\x1b[=>]')

def clean_line(s):
    return ANSI_RE.sub('', s).rstrip()

# Accumulator for current chunk's text body
chunk_lines_accum = []
chunk_start_line = max(start_line_no + 1, 1)
chunk_start_byte = start_offset

def chunk_id_for_line(n):
    return (n - 1) // CHUNK_LINES + 1

def write_chunk(cid, lines_in_chunk, frozen, lstart, lend, bstart, bend):
    chunk_path = os.path.join(chunk_dir, f'chunk-{cid:03d}.md')
    body_text = '\n'.join(lines_in_chunk[:200])  # cap excerpted body at 200 lines per chunk to keep BM25 lean
    excerpt_marker = f' (showing first 200 of {len(lines_in_chunk)})' if len(lines_in_chunk) > 200 else ''
    now = datetime.datetime.utcnow().strftime('%Y-%m-%dT%H:%M:%SZ')
    body = f"""---
name: tmux-log {key} chunk {cid:03d} (lines {lstart}-{lend})
description: Chunk-local excerpt from tmux-log {key}, lines {lstart}-{lend}{excerpt_marker}. {'frozen' if frozen else 'current'}.
metadata:
  type: reference
  source: tmux-log
  tmux_key: {key}
  chunk_id: {cid}
  lines: [{lstart}, {lend}]
  bytes: [{bstart}, {bend}]
  frozen: {str(frozen).lower()}
  mtime: {now}
---

# tmux-log {key} chunk {cid:03d}

| Field | Value |
|---|---|
| tmux_key | `{key}` |
| chunk_id | {cid:03d} |
| lines | {lstart}-{lend} ({lend - lstart + 1} lines) |
| bytes | {bstart}-{bend} |
| frozen | {frozen} |

## Excerpt{excerpt_marker}

```
{body_text}
```
"""
    fd, tmp = tempfile.mkstemp(dir=chunk_dir, prefix='.tmp-chunk-')
    try:
        with os.fdopen(fd, 'w') as wf:
            wf.write(body)
        os.replace(tmp, chunk_path)
    except Exception:
        if os.path.exists(tmp):
            os.unlink(tmp)
        raise

# Incremental read with chunk-boundary detection
line_no = start_line_no
cur_byte_start = start_offset
cur_line_start = max(line_no + 1, 1)

with open(fpath, 'rb') as f:
    f.seek(start_offset)
    pre = start_offset
    for raw in f:
        line_no += 1
        post = pre + len(raw)
        try:
            line = clean_line(raw.decode('utf-8', errors='replace'))
        except Exception:
            line = ''
        if line:
            chunk_lines_accum.append(line)

        # Boundary crossed?
        new_cid = chunk_id_for_line(line_no)
        if new_cid != current_chunk_id:
            # Finalize previous chunk
            write_chunk(current_chunk_id, chunk_lines_accum, True,
                        cur_line_start, line_no - 1, cur_byte_start, pre - 1)
            current_chunk_id = new_cid
            chunk_lines_accum = []
            cur_line_start = line_no
            cur_byte_start = pre

        pre = post

# Emit current/last chunk (frozen=false)
if chunk_lines_accum:
    write_chunk(current_chunk_id, chunk_lines_accum, False,
                cur_line_start, line_no, cur_byte_start, file_size - 1)

# HEAD.md — scan chunks dir + assemble
chunk_files = sorted([f for f in os.listdir(chunk_dir) if f.startswith('chunk-') and f.endswith('.md')])
now = datetime.datetime.utcnow().strftime('%Y-%m-%dT%H:%M:%SZ')
head_yaml = ['---', f'tmux_key: {key}', f'source: tmux-log', f'current_chunk_id: {current_chunk_id}',
             f'total_lines: {line_no}', f'total_bytes: {file_size}',
             f'mtime: {now}',
             'chunks:']
for cf in chunk_files:
    cid_match = re.match(r'chunk-(\d+)\.md', cf)
    if cid_match:
        head_yaml.append(f'  - id: {int(cid_match.group(1))}')
        head_yaml.append(f'    file: {cf}')
head_yaml.append('---')
head_yaml.append('')
head_yaml.append(f'# tmux-log {key} chunk index (HEAD)')
head_yaml.append('')
head_yaml.append(f'{len(chunk_files)} chunks. Current chunk: {current_chunk_id:03d}. Total {line_no} lines / {file_size} bytes.')

head_path = os.path.join(chunk_dir, 'HEAD.md')
fd, tmp = tempfile.mkstemp(dir=chunk_dir, prefix='.tmp-head-')
try:
    with os.fdopen(fd, 'w') as wf:
        wf.write('\n'.join(head_yaml))
    os.replace(tmp, head_path)
except Exception:
    if os.path.exists(tmp):
        os.unlink(tmp)
    raise

# Persist sidecar
new_state = {
    'version': SIDECAR_VERSION,
    'tmux_key': key,
    'byte_offset': file_size,
    'total_lines': line_no,
    'current_chunk_id': current_chunk_id,
    'updated_at': now,
}
fd, tmp = tempfile.mkstemp(dir=os.path.dirname(sidecar_path), prefix='.tmp-off-')
try:
    with os.fdopen(fd, 'w') as wf:
        json.dump(new_state, wf)
    os.replace(tmp, sidecar_path)
except Exception:
    if os.path.exists(tmp):
        os.unlink(tmp)
    raise

processed_bytes = file_size - start_offset
sys.stderr.write(f'[tmux-walker] {key} processed={processed_bytes} bytes lines={line_no} chunks={len(chunk_files)}\n')
PY

done <<< "$JOBS"

echo "[$(date -u +%FT%TZ)] tmux-walker done: processed=$PROCESSED skipped=$SKIPPED failed=$FAILED too-big=$TOO_BIG"
exit 0
