#!/usr/bin/env python3
"""
bookmarks-sync.py — durable sync of operator's Code-Insiders (alefragnani.Bookmarks)
into NocoDB, snapshotting the bookmarked log content so it survives tmux-log archival.

Source of truth: Code-Insiders workspaceStorage state.vscdb, ItemTable key
'alefragnani.Bookmarks'. Value = {"bookmarks":"<json>"} where inner JSON is
{"files":[{"path":"<rel>","bookmarks":[{"line":N,"column":C,"label":"..."}]}]}.
`line` is 0-indexed; editor line = line+1. Paths are relative to the tmux-logs
workspace root (~/.local/share/tmux-logs), except ../../../Journal/... -> ~/Journal/...

For each bookmark we snapshot the bookmarked line +/- CONTEXT lines:
  - local file present            -> source=local
  - rotated to Pi offline archive -> source=pi-archive
      ssh blvck-pi 'zstd -dc /mnt/substrate/tmux-logs-offline/YYYY/YYYY-MM.tar.zst
                    | tar -xO <member>'  (member mirrors the tmux-logs layout)
  - neither resolves              -> source=unresolved, content=UNRESOLVED

Upsert is idempotent, keyed by (File,Line), into NocoDB table "Bookmarks"
(created if absent) in base pk3ri3t5afke4f6 on the Pi.
$0, local, safe to re-run.
"""
import glob
import json
import os
import re
import sqlite3
import subprocess
import sys
import urllib.request
import urllib.error
from datetime import datetime, timezone

HOME = os.path.expanduser("~")
WS_GLOB = os.path.join(
    HOME,
    "Library/Application Support/Code - Insiders/User/workspaceStorage/*/state.vscdb",
)
TMUX_ROOT = os.path.join(HOME, ".local/share/tmux-logs")
JOURNAL_ROOT = os.path.join(HOME, "Journal")
PI_HOST = "blvck-pi"
PI_ARCHIVE = "/mnt/substrate/tmux-logs-offline"
CONTEXT = 8
LINE_TRUNC = 400  # cap per-line width in snapshots

NOCODB_URL = "http://192.168.100.50:8080"
BASE_ID = "pk3ri3t5afke4f6"
TOKEN_FILE = os.path.join(HOME, ".config/lotl/nocodb-token")
TABLE_TITLE = "Bookmarks"

STATUS_DIR = os.path.join(HOME, ".local/state/bookmarks")
STATUS_FILE = os.path.join(STATUS_DIR, "status.json")

SEP = "\x01"


def log(*a):
    print(*a, file=sys.stderr)


# ---------------------------------------------------------------- discovery
def find_bookmarks_value():
    """Sweep workspaceStorage for the alefragnani.Bookmarks value.
    Prefer the workspace whose value references turboquant (the operator's
    tmux-logs workspace); fall back to the longest non-empty value."""
    best = None  # (score, length, path, value)
    for db in glob.glob(WS_GLOB):
        try:
            con = sqlite3.connect(f"file:{db}?mode=ro", uri=True)
            cur = con.execute(
                "SELECT CAST(value AS TEXT) FROM ItemTable "
                "WHERE key='alefragnani.Bookmarks'"
            )
            row = cur.fetchone()
            con.close()
        except Exception:
            continue
        if not row or not row[0]:
            continue
        val = row[0]
        try:
            inner = json.loads(json.loads(val)["bookmarks"])
        except Exception:
            continue
        if not isinstance(inner, dict) or not isinstance(inner.get("files"), list):
            continue  # skip older/foreign bookmark schemas
        nbm = sum(len(f.get("bookmarks", [])) for f in inner["files"]
                  if isinstance(f, dict))
        if nbm == 0:
            continue
        score = (2 if "turboquant" in val.lower() else 1, nbm)
        cand = (score, db, inner)
        if best is None or cand[0] > best[0]:
            best = cand
    if best is None:
        log("FATAL: no non-empty alefragnani.Bookmarks found in any workspace")
        sys.exit(1)
    log(f"Using workspace db: {best[1]}")
    return best[2]


# ---------------------------------------------------------------- resolution
def resolve_abs(rel):
    """Resolve a bookmark path to (abs_path, is_journal)."""
    if "Journal/" in rel:
        m = re.search(r"Journal/(.*)$", rel)
        return os.path.join(JOURNAL_ROOT, m.group(1)), True
    return os.path.join(TMUX_ROOT, rel), False


def path_date(rel):
    """Extract YYYY-MM-DD from the path (works for tmux + Journal layouts)."""
    m = re.search(r"(\d{4})/(\d{2})/(\d{2})", rel)
    return f"{m.group(1)}-{m.group(2)}-{m.group(3)}" if m else ""


def infer_area(rel):
    low = rel.lower()
    if "turboquant" in low:
        return "turboquant/trading"
    if "platform-cutover" in low:
        return "platform-cutover"
    if "journal" in low:
        return "journal"
    if "/hooks/" in low or "-build" in low:
        return "hooks/build"
    return "other"


def trunc(s):
    s = s.rstrip("\n")
    return s if len(s) <= LINE_TRUNC else s[:LINE_TRUNC] + " …[truncated]"


def window_from_lines(lines, center1):
    """lines: list of str (0-indexed). center1: 1-indexed editor line.
    Returns snapshot string or None if center is beyond EOF."""
    if center1 > len(lines) or center1 < 1:
        return None
    lo = max(1, center1 - CONTEXT)
    hi = min(len(lines), center1 + CONTEXT)
    out = []
    for n in range(lo, hi + 1):
        mark = ">>>" if n == center1 else "   "
        out.append(f"{mark} L{n}: {trunc(lines[n - 1])}")
    return "\n".join(out)


def snapshot_local(abs_path, centers):
    """centers: list of 1-indexed lines. Returns {center: content-or-None}."""
    with open(abs_path, "r", errors="replace") as fh:
        lines = fh.read().split("\n")
    return {c: window_from_lines(lines, c) for c in centers}


def _merge_ranges(centers):
    """Return merged, sorted (lo,hi) windows covering each center +/- CONTEXT."""
    wins = sorted((max(1, c - CONTEXT), c + CONTEXT) for c in centers)
    merged = []
    for lo, hi in wins:
        if merged and lo <= merged[-1][1] + 1:
            merged[-1] = (merged[-1][0], max(merged[-1][1], hi))
        else:
            merged.append((lo, hi))
    return merged


def snapshot_pi(rel, date, centers):
    """Extract member from the monthly Pi tar, return {center: content-or-None}.
    Uses `sed -n 'LO,HI{=;p}'` so each printed content line is preceded by its
    line number (safe quoting: exprs are digits + {=;p} only).
    On any failure returns {} (caller treats missing as unresolved)."""
    yyyy, mm = date[:4], date[5:7]
    tar = f"{PI_ARCHIVE}/{yyyy}/{yyyy}-{mm}.tar.zst"
    member = rel  # tar member mirrors the tmux-logs relative layout (verified)
    exprs = " ".join(f"-e '{lo},{hi}{{=;p}}'" for lo, hi in _merge_ranges(centers))
    remote = (
        f"zstd -dc {tar} 2>/dev/null | tar -xO {member} 2>/dev/null | "
        f"sed -n {exprs}"
    )
    try:
        p = subprocess.run(
            ["ssh", "-o", "BatchMode=yes", "-o", "ConnectTimeout=15", PI_HOST, remote],
            capture_output=True, text=True, timeout=300,
        )
    except Exception as e:
        log(f"  pi ssh error for {rel}: {e}")
        return {}
    if not p.stdout:
        log(f"  pi extract empty for {rel}: rc={p.returncode} {p.stderr.strip()[:120]}")
        return {}
    # sed emits: <lineno>\n<content>\n<lineno>\n<content>...
    lines = p.stdout.split("\n")
    numbered = {}  # nr -> text
    i = 0
    while i + 1 < len(lines):
        try:
            nr = int(lines[i])
        except ValueError:
            i += 1
            continue
        numbered[nr] = lines[i + 1]
        i += 2
    res = {}
    for c in centers:
        if c not in numbered:  # center beyond EOF / member absent
            res[c] = None
            continue
        lo = max(1, c - CONTEXT)
        hi = c + CONTEXT
        out = []
        for n in range(lo, hi + 1):
            if n not in numbered:
                continue
            mark = ">>>" if n == c else "   "
            out.append(f"{mark} L{n}: {trunc(numbered[n])}")
        res[c] = "\n".join(out)
    return res


# ---------------------------------------------------------------- nocodb
def api(method, path, body=None):
    token = open(TOKEN_FILE).read().strip()
    url = NOCODB_URL + path
    data = json.dumps(body).encode() if body is not None else None
    req = urllib.request.Request(url, data=data, method=method)
    req.add_header("xc-token", token)
    req.add_header("Content-Type", "application/json")
    try:
        with urllib.request.urlopen(req, timeout=30) as r:
            raw = r.read().decode()
            return json.loads(raw) if raw else {}
    except urllib.error.HTTPError as e:
        log(f"  API {method} {path} -> {e.code}: {e.read().decode()[:300]}")
        raise


def ensure_table():
    tables = api("GET", f"/api/v2/meta/bases/{BASE_ID}/tables").get("list", [])
    for t in tables:
        if t["title"] == TABLE_TITLE:
            log(f"Reusing table {TABLE_TITLE} ({t['id']})")
            return t["id"]
    cols = [
        {"column_name": "Label", "title": "Label", "uidt": "SingleLineText", "pv": True},
        {"column_name": "Date", "title": "Date", "uidt": "SingleLineText"},
        {"column_name": "File", "title": "File", "uidt": "SingleLineText"},
        {"column_name": "Line", "title": "Line", "uidt": "Number"},
        {"column_name": "Area", "title": "Area", "uidt": "SingleLineText"},
        {"column_name": "Content", "title": "Content", "uidt": "LongText"},
        {"column_name": "Source", "title": "Source", "uidt": "SingleLineText"},
        {"column_name": "Synced", "title": "Synced", "uidt": "SingleLineText"},
    ]
    r = api("POST", f"/api/v2/meta/bases/{BASE_ID}/tables",
            {"title": TABLE_TITLE, "columns": cols})
    log(f"Created table {TABLE_TITLE} ({r['id']})")
    return r["id"]


def existing_index(table_id):
    """Return {(File,Line): record_id} for idempotent upsert."""
    idx = {}
    offset = 0
    while True:
        r = api("GET", f"/api/v2/tables/{table_id}/records?limit=200&offset={offset}"
                        f"&fields=Id,File,Line")
        rows = r.get("list", [])
        for row in rows:
            idx[(row.get("File"), int(row.get("Line") or 0))] = row.get("Id")
        pi = r.get("pageInfo", {})
        if pi.get("isLastPage", True) or not rows:
            break
        offset += len(rows)
    return idx


# ---------------------------------------------------------------- main
def main():
    inner = find_bookmarks_value()
    now = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%MZ")

    # build per-file bookmark groups
    records = []  # dict per bookmark
    files = inner["files"]
    for f in files:
        rel = f["path"]
        abs_path, is_journal = resolve_abs(rel)
        date = path_date(rel)
        area = infer_area(rel)
        bms = f["bookmarks"]
        centers = [b["line"] + 1 for b in bms]  # editor line
        # resolve content for all centers of this file at once
        if os.path.exists(abs_path):
            content_map = snapshot_local(abs_path, centers)
            src_default = "local"
        elif not is_journal and date:
            content_map = snapshot_pi(rel, date, centers)
            src_default = "pi-archive"
        else:
            content_map = {}
            src_default = "unresolved"
        for b in bms:
            c = b["line"] + 1
            content = content_map.get(c)
            if content is None:
                src = "unresolved"
                content = "UNRESOLVED"
            else:
                src = src_default
            records.append({
                "Label": b.get("label", "") or "(no label)",
                "Date": date,
                "File": rel,
                "Line": c,
                "Area": area,
                "Content": content,
                "Source": src,
                "Synced": now,
            })

    log(f"Parsed {len(records)} bookmarks across {len(files)} files")

    # nocodb upsert
    table_id = ensure_table()
    idx = existing_index(table_id)
    creates, updates = [], []
    for rec in records:
        key = (rec["File"], rec["Line"])
        if key in idx:
            u = dict(rec); u["Id"] = idx[key]
            updates.append(u)
        else:
            creates.append(rec)
    if creates:
        for i in range(0, len(creates), 50):
            api("POST", f"/api/v2/tables/{table_id}/records", creates[i:i + 50])
    if updates:
        for i in range(0, len(updates), 50):
            api("PATCH", f"/api/v2/tables/{table_id}/records", updates[i:i + 50])

    # status cache
    os.makedirs(STATUS_DIR, exist_ok=True)
    json.dump({"total": len(records), "ts": now}, open(STATUS_FILE, "w"))

    # summary
    n_local = sum(1 for r in records if r["Source"] == "local")
    n_pi = sum(1 for r in records if r["Source"] == "pi-archive")
    n_un = sum(1 for r in records if r["Source"] == "unresolved")
    print(f"table_id={table_id}")
    print(f"synced={len(records)} (created={len(creates)} updated={len(updates)})")
    print(f"local={n_local} pi-archive={n_pi} unresolved={n_un}")
    if n_un:
        for r in records:
            if r["Source"] == "unresolved":
                print(f"  UNRESOLVED: {r['File']}:{r['Line']} — {r['Label']}")


if __name__ == "__main__":
    main()
