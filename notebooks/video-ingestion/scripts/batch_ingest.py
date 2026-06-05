#!/usr/bin/env python3
"""
batch_ingest.py — YT-DLP + Deepnote v2 Runs API batch walker

Three-phase pipeline for ingesting a directory of YouTube videos through the
video-ingestion-qwen25vl-v2 notebook on Deepnote:

  1. download    — yt-dlp pulls each URL to ~/Downloads/upload/{youtube_id}.mp4
  2. ingest      — POSTs each to Deepnote v2 Runs API; polls until success/error
  3. summary     — reports per-video status, duration, chunks, output path

v1 limitation (manual sync steps):
  - Between download + ingest: drag mp4 files from ~/Downloads/upload/ into
    Deepnote's "work" folder (Google Drive integration syncs them to
    /datasets/_deepnote_work/work/)
  - After ingest: drag *-output.json files from Deepnote work folder back to
    ~/Downloads/upload/

v2 (Task #99): Google Drive API or rclone integration for fully unattended.

Usage:
  ./batch_ingest.py download urls.txt
  ./batch_ingest.py ingest urls.txt --notebook-id <id> [--wait]
  ./batch_ingest.py summary urls.txt

urls.txt format: one YouTube URL per line; lines starting with # are comments.

Environment / credentials:
  DEEPNOTE_TOKEN     read from ~/.claude/.credentials/deepnote-api-key.txt
  NOTEBOOK_ID        --notebook-id flag or DEEPNOTE_NOTEBOOK_ID env var
  Default notebook:  a84f230bd27042b1a5411a22aa840d42 (memory_oracle
                     native-video project, video-ingestion-qwen25vl-v2)
"""

from __future__ import annotations

import argparse
import json
import os
import re
import shutil
import subprocess
import sys
import time
import urllib.error
import urllib.request
from dataclasses import dataclass, field
from datetime import datetime
from pathlib import Path
from typing import Iterator


def _ts() -> str:
    """Timestamp prefix for every log line."""
    return datetime.now().strftime("%H:%M:%S")


def log(msg: str, indent: int = 0) -> None:
    """Single sink for all script output — timestamped, flushed immediately."""
    prefix = "  " * indent
    print(f"[{_ts()}] {prefix}{msg}", flush=True)

UPLOAD_DIR = Path.home() / "Downloads" / "upload"
TOKEN_PATH = Path.home() / ".claude" / ".credentials" / "deepnote-api-key.txt"
DEFAULT_NOTEBOOK_ID = "9b4190e393654580b9314b4bd2c81fed"
# ↑ Notebook ID changes every time you re-import a .deepnote file.
# Extract it from the notebook URL: the trailing UUID-without-dashes segment.
# Override via --notebook-id flag OR `export DEEPNOTE_NOTEBOOK_ID=<id>` before running.
DEEPNOTE_API_BASE = "https://api.deepnote.com"
DRIVE_WORK_PATH = "/datasets/_deepnote_work/work"

# Defaults for the notebook input blocks (matches the v2 trading-education profile)
DEFAULT_INPUTS = {
    "EXTRACT_MODE": "both",
    "CHUNK_DURATION_SEC": "300",
    "VIDEO_FPS": "0.5",
    "VIDEO_MAX_PIXELS": "151200",
    "MODEL": "Qwen/Qwen2.5-VL-7B-Instruct",
    "PROMPT_PROFILE": "trading-education",
    "MAX_NEW_TOKENS": "2048",
    "WHISPER_MODEL": "base",
}

YOUTUBE_ID_RE = re.compile(
    r"(?:youtube\.com/(?:watch\?v=|embed/|v/|shorts/)|youtu\.be/)([A-Za-z0-9_-]{11})"
)


@dataclass
class Video:
    url: str
    youtube_id: str = ""
    mp4_path: Path | None = None
    output_path: Path | None = None
    run_id: str = ""
    status: str = "pending"  # pending | downloaded | uploaded | running | success | error
    error: str = ""
    metadata: dict = field(default_factory=dict)


# ──────────────────────────────────────────────────────────────────────────────
# URL/ID handling
# ──────────────────────────────────────────────────────────────────────────────

def parse_youtube_id(url: str) -> str:
    """Extract the 11-char YouTube video ID from any common URL form."""
    m = YOUTUBE_ID_RE.search(url)
    if not m:
        raise ValueError(f"Could not extract YouTube ID from URL: {url}")
    return m.group(1)


def load_urls(urls_file: Path) -> list[Video]:
    """Read urls.txt: one URL per line, # comments and blanks skipped."""
    videos: list[Video] = []
    for line in urls_file.read_text().splitlines():
        line = line.strip()
        if not line or line.startswith("#"):
            continue
        vid = Video(url=line, youtube_id=parse_youtube_id(line))
        vid.mp4_path = UPLOAD_DIR / f"{vid.youtube_id}.mp4"
        vid.output_path = UPLOAD_DIR / f"{vid.youtube_id}-output.json"
        videos.append(vid)
    return videos


# ──────────────────────────────────────────────────────────────────────────────
# PHASE 1 — download
# ──────────────────────────────────────────────────────────────────────────────

def download_video(video: Video, format_spec: str = "best[height<=360][ext=mp4]") -> bool:
    """yt-dlp wrapper. Streams output live so operator sees progress.
    Returns True on success (or already-exists)."""
    UPLOAD_DIR.mkdir(parents=True, exist_ok=True)
    if video.mp4_path.exists() and video.mp4_path.stat().st_size > 0:
        size_mb = video.mp4_path.stat().st_size // 1024 // 1024
        log(f"[{video.youtube_id}] already on disk ({size_mb} MB) at {video.mp4_path} — skipping", indent=1)
        video.status = "downloaded"
        return True

    cmd = [
        "yt-dlp",
        "--no-update",
        "--newline",         # progress on its own line (better with live stream)
        "-f", format_spec,
        "-o", str(video.mp4_path),
        video.url,
    ]
    log(f"[{video.youtube_id}] yt-dlp starting — initial network handshake can take 1-3 min before download progress appears", indent=1)
    log(f"[{video.youtube_id}] target: {video.mp4_path}", indent=1)
    log(f"[{video.youtube_id}] command: {' '.join(cmd)}", indent=1)

    t0 = time.time()
    try:
        # Stream output line-by-line so operator sees yt-dlp progress in real time
        proc = subprocess.Popen(
            cmd,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            text=True,
            bufsize=1,           # line-buffered
        )
        for line in proc.stdout:
            line = line.rstrip()
            if line:
                log(f"[{video.youtube_id}] yt-dlp: {line}", indent=2)
        proc.wait(timeout=1800)   # 30 min hard limit per video
        elapsed = time.time() - t0
        if proc.returncode != 0:
            video.status = "error"
            video.error = f"yt-dlp exit {proc.returncode} after {elapsed:.0f}s"
            log(f"[{video.youtube_id}] FAILED: {video.error}", indent=1)
            return False
        if not video.mp4_path.exists():
            video.status = "error"
            video.error = "yt-dlp exited 0 but mp4 not found on disk"
            log(f"[{video.youtube_id}] FAILED: {video.error}", indent=1)
            return False
        size_mb = video.mp4_path.stat().st_size // 1024 // 1024
        log(f"[{video.youtube_id}] OK — {size_mb} MB in {elapsed:.0f}s → {video.mp4_path}", indent=1)
        video.status = "downloaded"
        return True
    except subprocess.TimeoutExpired:
        proc.kill()
        video.status = "error"
        video.error = "yt-dlp timeout after 30 min"
        log(f"[{video.youtube_id}] FAILED: timeout (killed after 30 min)", indent=1)
        return False
    except KeyboardInterrupt:
        proc.kill()
        video.status = "error"
        video.error = "interrupted by user"
        log(f"[{video.youtube_id}] INTERRUPTED — yt-dlp killed", indent=1)
        raise


def phase_download(videos: list[Video], format_spec: str) -> None:
    log(f"=== PHASE 1: download — {len(videos)} videos to {UPLOAD_DIR} ===")
    log(f"yt-dlp format: {format_spec}")
    log(f"NOTE: yt-dlp can take 1-3 min to start downloading (YouTube handshake + format probe)")
    log("")
    t0 = time.time()
    ok_count = 0
    for i, video in enumerate(videos, 1):
        log(f"--- Video {i}/{len(videos)}: {video.youtube_id} ---")
        if download_video(video, format_spec):
            ok_count += 1
    elapsed = time.time() - t0
    log("")
    log(f"=== Download phase complete: {ok_count}/{len(videos)} succeeded in {elapsed:.0f}s ===")
    log("")
    log(f"NEXT MANUAL STEP:")
    log(f"  Drag mp4 files from {UPLOAD_DIR}/ into Deepnote's 'work' folder")
    log(f"  (they'll sync to {DRIVE_WORK_PATH}/ via the Google Drive integration)")
    log("")
    log(f"Then run:  ./batch_ingest.py ingest {sys.argv[-1]}")


# ──────────────────────────────────────────────────────────────────────────────
# PHASE 2 — ingest (Deepnote v2 Runs API)
# ──────────────────────────────────────────────────────────────────────────────

def load_token() -> str:
    if not TOKEN_PATH.exists():
        sys.exit(f"FATAL: Deepnote token not found at {TOKEN_PATH}")
    return TOKEN_PATH.read_text().strip()


def deepnote_post(token: str, notebook_id: str, video: Video, extra_inputs: dict) -> dict:
    """POST a single run to Deepnote v2 API. Returns parsed JSON response."""
    inputs = dict(DEFAULT_INPUTS)
    inputs["VIDEO_URL"] = f"{DRIVE_WORK_PATH}/{video.youtube_id}.mp4"
    inputs["OUTPUT_PATH"] = f"{DRIVE_WORK_PATH}/{video.youtube_id}-output.json"
    inputs.update(extra_inputs)

    body = {
        "notebookId": notebook_id,
        "inputs": inputs,
        "detached": False,    # Team plan doesn't support detached
    }
    req = urllib.request.Request(
        f"{DEEPNOTE_API_BASE}/v2/runs",
        data=json.dumps(body).encode(),
        headers={
            "Authorization": f"Bearer {token}",
            "Content-Type": "application/json",
        },
        method="POST",
    )
    try:
        # Synchronous mode — request blocks until run completes or 10min timeout
        with urllib.request.urlopen(req, timeout=1200) as resp:
            return json.loads(resp.read().decode())
    except urllib.error.HTTPError as e:
        return {"error": f"HTTP {e.code}: {e.read().decode()[:300]}"}
    except urllib.error.URLError as e:
        return {"error": f"URL error: {e.reason}"}


def deepnote_get_run(token: str, run_id: str) -> dict:
    """Single GET of a run's status."""
    req = urllib.request.Request(
        f"{DEEPNOTE_API_BASE}/v2/runs/{run_id}",
        headers={"Authorization": f"Bearer {token}"},
    )
    try:
        with urllib.request.urlopen(req, timeout=30) as resp:
            return json.loads(resp.read().decode())
    except urllib.error.HTTPError as e:
        return {"error": f"HTTP {e.code}: {e.read().decode()[:300]}"}


def _extract_status(resp: dict) -> tuple[str, str]:
    """Pull status + error_detail from a /v2/runs/{id} response regardless of envelope."""
    run_obj = resp.get("run", resp)
    status = run_obj.get("status", "unknown")
    error_detail = run_obj.get("error", "") or resp.get("error", "")
    return status, str(error_detail)[:300] if error_detail else ""


# Terminal statuses — exit the polling loop when we see one of these
TERMINAL_STATUSES = {"success", "error", "cancelled", "failed", "timed_out"}


def poll_until_terminal(token: str, run_id: str, label: str = "",
                        max_seconds: int = 1800, poll_interval: int = 30) -> dict:
    """Loop-poll a runId every poll_interval seconds until status is terminal
    or max_seconds elapsed. Logs every poll so operator sees activity.
    Returns the final response dict."""
    tag = f"[{label}]" if label else f"[{run_id[:8]}]"
    t0 = time.time()
    last_status = None
    poll_count = 0
    log(f"{tag} polling runId={run_id} every {poll_interval}s (max {max_seconds // 60} min)", indent=1)
    while True:
        elapsed = time.time() - t0
        resp = deepnote_get_run(token, run_id)
        poll_count += 1
        if "error" in resp and "run" not in resp:
            log(f"{tag} poll #{poll_count} ERROR after {elapsed:.0f}s: {resp['error']}", indent=2)
            return resp
        status, _ = _extract_status(resp)
        # Log every poll. Mark status transitions with arrow.
        if status != last_status:
            log(f"{tag} poll #{poll_count} @ {elapsed:.0f}s: {last_status or '(initial)'} → {status}", indent=2)
            last_status = status
        else:
            log(f"{tag} poll #{poll_count} @ {elapsed:.0f}s: {status}", indent=2)
        if status in TERMINAL_STATUSES:
            log(f"{tag} TERMINAL: {status} after {elapsed:.0f}s ({poll_count} polls)", indent=2)
            return resp
        if elapsed > max_seconds:
            log(f"{tag} POLL TIMEOUT after {max_seconds}s — last status: {status}", indent=2)
            return resp
        time.sleep(poll_interval)


def auto_upload_to_drive(video: Video, drive_path: Path) -> bool:
    """Copy mp4 from local ~/Downloads/upload/ into a Drive-synced folder
    that Deepnote sees via its `work` integration. Returns True if file already
    in Drive or copy succeeded."""
    drive_target = drive_path / f"{video.youtube_id}.mp4"
    if drive_target.exists() and drive_target.stat().st_size > 0:
        log(f"[{video.youtube_id}] already in Drive at {drive_target} — skipping upload", indent=1)
        return True
    if not video.mp4_path.exists():
        log(f"[{video.youtube_id}] cannot auto-upload: local mp4 missing at {video.mp4_path}", indent=1)
        return False
    log(f"[{video.youtube_id}] auto-uploading to Drive: {drive_target}", indent=1)
    drive_path.mkdir(parents=True, exist_ok=True)
    shutil.copy2(str(video.mp4_path), str(drive_target))
    log(f"[{video.youtube_id}] copied to Drive — Deepnote sync takes ~30-60s", indent=1)
    return True


def auto_download_from_drive(video: Video, drive_path: Path,
                               max_wait_seconds: int = 300) -> bool:
    """Poll for output.json in the Drive folder, then copy back to local
    ~/Downloads/upload/. Returns True if file found + copied within max_wait."""
    drive_source = drive_path / f"{video.youtube_id}-output.json"
    if video.output_path.exists() and video.output_path.stat().st_size > 0:
        log(f"[{video.youtube_id}] output.json already local — skipping download", indent=1)
        return True
    log(f"[{video.youtube_id}] watching Drive for output.json at {drive_source} (max {max_wait_seconds}s)", indent=1)
    t0 = time.time()
    while time.time() - t0 < max_wait_seconds:
        if drive_source.exists() and drive_source.stat().st_size > 0:
            shutil.copy2(str(drive_source), str(video.output_path))
            elapsed = time.time() - t0
            log(f"[{video.youtube_id}] auto-downloaded after {elapsed:.0f}s → {video.output_path}", indent=1)
            return True
        time.sleep(5)
    log(f"[{video.youtube_id}] WARN: output.json not in Drive after {max_wait_seconds}s — manual download required", indent=1)
    return False


def ingest_video(token: str, notebook_id: str, video: Video, extra_inputs: dict,
                  drive_path: Path | None = None) -> None:
    """Submit one video to Deepnote, block until done (synchronous mode).
    If drive_path is set, auto-uploads to Drive before submission and
    auto-downloads output.json from Drive after success."""
    # Auto-upload to Drive if configured
    if drive_path is not None:
        if not auto_upload_to_drive(video, drive_path):
            video.status = "error"
            video.error = "auto-upload to Drive failed (local mp4 missing)"
            return
        # Give Drive sync a moment before submitting
        log(f"[{video.youtube_id}] waiting 30s for Drive→Deepnote sync before submission", indent=1)
        time.sleep(30)

    if not video.mp4_path or not video.mp4_path.exists():
        video.status = "error"
        video.error = f"mp4 not found at {video.mp4_path} — was it uploaded to Deepnote work folder?"
        log(f"[{video.youtube_id}] SKIP: {video.error}", indent=1)
        return

    # Idempotency: skip if output.json already in ~/Downloads/upload/
    if video.output_path.exists() and video.output_path.stat().st_size > 0:
        kb = video.output_path.stat().st_size // 1024
        log(f"[{video.youtube_id}] output.json already present ({kb} KB) — skipping", indent=1)
        video.status = "success"
        return

    log(f"[{video.youtube_id}] POSTing to Deepnote v2 Runs API (synchronous mode — blocks up to 20 min while notebook runs)", indent=1)
    log(f"[{video.youtube_id}] VIDEO_URL={DRIVE_WORK_PATH}/{video.youtube_id}.mp4", indent=1)
    log(f"[{video.youtube_id}] OUTPUT_PATH={DRIVE_WORK_PATH}/{video.youtube_id}-output.json", indent=1)
    log(f"[{video.youtube_id}] NOTE: Deepnote machine cold-start adds 2-5 min if no machine running", indent=1)

    t0 = time.time()
    resp = deepnote_post(token, notebook_id, video, extra_inputs)
    submit_elapsed = time.time() - t0

    if "error" in resp:
        video.status = "error"
        video.error = resp["error"]
        log(f"[{video.youtube_id}] FAILED after {submit_elapsed:.0f}s: {video.error}", indent=1)
        return

    video.run_id = resp.get("runId", "")
    initial_status = resp.get("status", "unknown")
    log(f"[{video.youtube_id}] runId={video.run_id} initial_status={initial_status} (post took {submit_elapsed:.0f}s)", indent=1)

    # POLL IN A LOOP until terminal status — Deepnote synchronous mode returns
    # quickly with 'pending'/'running' on Team plan; we have to drive the wait client-side.
    final = poll_until_terminal(token, video.run_id, label=video.youtube_id,
                                  max_seconds=1800, poll_interval=30)
    run_status, error_detail = _extract_status(final)
    total_elapsed = time.time() - t0

    if run_status == "success":
        video.status = "success"
        log(f"[{video.youtube_id}] SUCCESS in {total_elapsed:.0f}s — output should be at {DRIVE_WORK_PATH}/{video.youtube_id}-output.json", indent=1)
        # Auto-download from Drive if configured
        if drive_path is not None:
            auto_download_from_drive(video, drive_path)
    elif run_status in ("error", "failed"):
        video.status = "error"
        video.error = error_detail or "Deepnote reported error (no detail)"
        log(f"[{video.youtube_id}] ERROR after {total_elapsed:.0f}s: {video.error}", indent=1)
    else:
        video.status = run_status or "unknown"
        log(f"[{video.youtube_id}] non-terminal status={video.status} after {total_elapsed:.0f}s (poll timeout?)", indent=1)


def phase_ingest(videos: list[Video], notebook_id: str, extra_inputs: dict,
                  drive_path: Path | None = None) -> None:
    log(f"=== PHASE 2: ingest — {len(videos)} videos via Deepnote v2 API ===")
    log(f"Notebook: {notebook_id}")
    log(f"Default inputs: {DEFAULT_INPUTS}")
    if extra_inputs:
        log(f"Overrides: {extra_inputs}")
    if drive_path is not None:
        log(f"Drive sync ENABLED — auto-upload/download via {drive_path}")
    else:
        log(f"Drive sync DISABLED — manual upload/download required (see phase output for instructions)")
    log("")
    token = load_token()
    t0 = time.time()
    ok = err = 0
    for i, video in enumerate(videos, 1):
        log(f"--- Video {i}/{len(videos)}: {video.youtube_id} ---")
        ingest_video(token, notebook_id, video, extra_inputs, drive_path)
        if video.status == "success":
            ok += 1
        elif video.status == "error":
            err += 1
    elapsed = time.time() - t0
    log("")
    log(f"=== Ingest phase complete: {ok} success, {err} error, {len(videos) - ok - err} other ({elapsed:.0f}s total) ===")
    log("")
    if drive_path is None:
        log(f"NEXT MANUAL STEP:")
        log(f"  Drag *-output.json files from Deepnote 'work' folder back to {UPLOAD_DIR}/")
        log("")
        log(f"Then run:  ./batch_ingest.py summary {sys.argv[-1]}")
    else:
        log(f"All output.json files auto-downloaded from Drive to {UPLOAD_DIR}/")
        log(f"Run summary directly:  ./batch_ingest.py summary {sys.argv[-1]}")


# ──────────────────────────────────────────────────────────────────────────────
# PHASE 3 — summary
# ──────────────────────────────────────────────────────────────────────────────

def summarize_video(video: Video) -> None:
    if not video.output_path or not video.output_path.exists():
        log(f"[{video.youtube_id}] MISSING — no output.json at {video.output_path}", indent=1)
        return
    try:
        data = json.loads(video.output_path.read_text())
    except json.JSONDecodeError as e:
        log(f"[{video.youtube_id}] INVALID JSON: {e}", indent=1)
        return
    duration = data.get("duration_sec", 0)
    chunks_total = data.get("chunks_analyzed", 0)
    chunks_list = data.get("chunks", [])
    ok = sum(1 for c in chunks_list
             if not (isinstance(c.get("signal"), dict)
                     and any(k.startswith("_") for k in c["signal"])))
    err = chunks_total - ok
    transcript_chars = data.get("transcript", {}).get("char_count", 0)
    agg = data.get("aggregate", {})
    patterns = len(agg.get("patterns_named", []))
    formulas = len(agg.get("formulas_or_math", []))
    filters_ = len(agg.get("filters_or_scanners", []))
    log(f"[{video.youtube_id}] {duration:.0f}s, {chunks_total} chunks ({ok} ok / {err} err), "
        f"transcript={transcript_chars} chars, patterns={patterns} formulas={formulas} filters={filters_}", indent=1)


def phase_summary(videos: list[Video]) -> None:
    log(f"=== PHASE 3: summary — {len(videos)} videos ===")
    log("Format: [youtube_id] duration, chunks (ok/err), transcript chars, signal counts")
    log("")
    for video in videos:
        summarize_video(video)
    log("")
    log(f"Output.json files in {UPLOAD_DIR}/:")
    found = 0
    for video in videos:
        if video.output_path and video.output_path.exists():
            kb = video.output_path.stat().st_size // 1024
            log(f"  {video.output_path.name} ({kb} KB)", indent=1)
            found += 1
    log("")
    log(f"=== {found}/{len(videos)} output.json files present locally ===")


# ──────────────────────────────────────────────────────────────────────────────
# CLI
# ──────────────────────────────────────────────────────────────────────────────

def main():
    # Force line-buffered stdout — fixes silent gaps when piped through `tee`
    try:
        sys.stdout.reconfigure(line_buffering=True)
    except AttributeError:
        pass  # Python <3.7 fallback

    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("phase", choices=["download", "ingest", "summary", "all", "wait"],
                   help="Which phase to run. 'all' runs download then ingest then summary, but ingest will fail if you haven't uploaded to Deepnote work folder yet. 'wait' takes a runId in place of urls_file and polls until terminal.")
    p.add_argument("urls_file", type=str, help="Path to urls.txt (one YouTube URL per line) — OR a Deepnote runId when phase=wait")
    p.add_argument("--notebook-id", default=os.environ.get("DEEPNOTE_NOTEBOOK_ID", DEFAULT_NOTEBOOK_ID),
                   help=f"Deepnote notebook ID (default: {DEFAULT_NOTEBOOK_ID})")
    p.add_argument("--format", default="best[height<=360][ext=mp4]",
                   help="yt-dlp format spec (default: best[height<=360][ext=mp4])")
    p.add_argument("--input", action="append", default=[], metavar="KEY=VALUE",
                   help="Override a Deepnote input block (e.g. --input CHUNK_DURATION_SEC=600). Can be repeated.")
    p.add_argument("--drive-path", default=os.environ.get("DEEPNOTE_DRIVE_PATH"),
                   help=("Local path to the Deepnote 'work' folder via Google Drive Desktop mount "
                         "(e.g. ~/Library/CloudStorage/GoogleDrive-you@gmail.com/My\\ Drive/deepnote-work). "
                         "When set, the ingest phase auto-uploads mp4 to Drive (Deepnote sees it via "
                         "Drive integration sync ~30-60s later) AND auto-downloads output.json back. "
                         "Eliminates the two manual drag-drop sync steps. Alternative: set "
                         "DEEPNOTE_DRIVE_PATH env var. For rclone-only setups (no Drive Desktop), "
                         "point this at a local staging dir and add `rclone sync` cron alongside."))
    args = p.parse_args()
    drive_path = Path(os.path.expanduser(args.drive_path)) if args.drive_path else None

    # phase=wait short-circuits — urls_file is interpreted as a runId
    if args.phase == "wait":
        run_id = args.urls_file
        log(f"=== batch_ingest.py — phase=wait ===")
        log(f"run id: {run_id}")
        token = load_token()
        resp = poll_until_terminal(token, run_id, label=run_id[:8],
                                    max_seconds=1800, poll_interval=30)
        status, err = _extract_status(resp)
        log(f"final status: {status}")
        if err:
            log(f"error detail: {err}")
        if status == "success":
            log(f"")
            log(f"NEXT MANUAL STEP:")
            log(f"  Drag *-output.json from Deepnote 'work' folder back to {UPLOAD_DIR}/")
            log(f"")
            log(f"Then run:  ./batch_ingest.py summary <urls_file>")
        return

    urls_path = Path(args.urls_file)
    if not urls_path.exists():
        sys.exit(f"FATAL: urls file not found: {urls_path}")

    videos = load_urls(urls_path)
    if not videos:
        sys.exit(f"FATAL: no URLs in {urls_path}")

    extra_inputs = {}
    for kv in args.input:
        if "=" not in kv:
            sys.exit(f"FATAL: --input expects KEY=VALUE, got: {kv}")
        k, v = kv.split("=", 1)
        extra_inputs[k] = v

    log(f"=== batch_ingest.py — phase={args.phase} ===")
    log(f"urls file:     {urls_path}")
    log(f"upload dir:    {UPLOAD_DIR}")
    log(f"token file:    {TOKEN_PATH}")
    log(f"notebook id:   {args.notebook_id}")
    log(f"yt-dlp format: {args.format}")
    log(f"loaded {len(videos)} video URL(s):")
    for v in videos:
        log(f"  - {v.youtube_id}  ({v.url})", indent=1)
    log("")

    if args.phase == "download":
        phase_download(videos, args.format)
    elif args.phase == "ingest":
        phase_ingest(videos, args.notebook_id, extra_inputs, drive_path)
    elif args.phase == "summary":
        phase_summary(videos)
    elif args.phase == "all":
        phase_download(videos, args.format)
        if drive_path is None:
            input("\nPress Enter once you've dragged mp4 files into Deepnote work folder...")
        phase_ingest(videos, args.notebook_id, extra_inputs, drive_path)
        if drive_path is None:
            input("\nPress Enter once you've dragged output.json files back to ~/Downloads/upload/...")
        phase_summary(videos)


if __name__ == "__main__":
    main()
