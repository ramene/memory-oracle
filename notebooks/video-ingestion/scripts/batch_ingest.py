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
DEFAULT_NOTEBOOK_ID = "2bb7ec4d2a7c4fdd8faf190e32ff8c45"
# ↑ Notebook ID changes every time you re-import a .deepnote file.
# Extract it from the notebook URL: the trailing UUID-without-dashes segment.
# Override via --notebook-id flag OR `export DEEPNOTE_NOTEBOOK_ID=<id>` before running.
# 2026-06-18: re-imported D2 patch (CUDA-stats observability §5+§8) into the
# "native-video" project (id ae2b2f17-fb74-43bf-a749-b5a5b8a163c8) of the
# Ramene-Anthony workspace (id 9935bbbd-4ac8-49e6-8b7f-46ee3295cbbf).
# Prior ID: 271857dce0fd41d681a2d9909742fbab.
DEEPNOTE_API_BASE = "https://api.deepnote.com"
DRIVE_WORK_PATH = "/datasets/_deepnote_work/work"

# GCS staging bucket — closes the manual-drag loop on Deepnote ingest.
# Notebook supports VIDEO_URL = https URL natively (see v2 notebook §2).
# Inputs land here under inputs/; outputs (notebook patch) land under outputs/.
DEFAULT_GCS_BUCKET = "video-ingestion-staging"
DEFAULT_GCS_PROJECT = "claey-338919"
# User accounts can't sign URLs (no signing key); impersonate the GAE default SA
# of the project, which has a managed key. Operator needs roles/iam.serviceAccountTokenCreator
# on this SA — granted 2026-06-12.
DEFAULT_GCS_IMPERSONATE_SA = "claey-338919@appspot.gserviceaccount.com"
GCS_INPUT_PREFIX = "inputs"
GCS_OUTPUT_PREFIX = "outputs"
# Signed-URL TTLs. Input URL outlives the notebook cold-start + run; output URL
# outlives the run + retrieval lag. Both well under the bucket's 1-day lifecycle.
DEFAULT_INPUT_TTL_HOURS = 6
DEFAULT_OUTPUT_TTL_HOURS = 12

# YouTube extractor knobs — kills the 3-4 min "yt-dlp sits doing nothing" hang.
# Operator's working run showed `android_vr` client returns successfully; web/ios
# clients have been gated by YouTube anti-bot in 2026. Restricting the client
# list collapses the format-probe to seconds instead of minutes.
YT_EXTRACTOR_ARGS = "youtube:player_client=android_vr,web_safari"
# Default to format 18 (pre-muxed 360p mp4 with audio baked in) — no ffmpeg
# merge needed on the local side. Fall back to other pre-muxed mp4s; never
# select streams that require ffmpeg merging.
DEFAULT_FORMAT = "18/best[height<=480][ext=mp4][acodec!=none]/best[ext=mp4]"
# YouTube channel / playlist URL patterns. When matched, we expand to per-video
# URLs via yt-dlp --flat-playlist instead of treating as a single video.
CHANNEL_URL_RE = re.compile(
    r"^https?://(?:www\.)?youtube\.com/(?:@[\w.-]+(?:/videos)?|c/[\w.-]+(?:/videos)?|channel/[\w-]+(?:/videos)?|playlist\?list=[\w-]+|user/[\w.-]+(?:/videos)?)/?$"
)
DEFAULT_MAX_CHANNEL_VIDEOS = 50

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
    """Source-agnostic video record.

    `short_id` is the primary key used for GCS naming, output JSON file
    naming, and log lines.  For YouTube videos it equals the 11-char YT ID
    (no hash needed — already unique).  For other sources (workshops,
    podcasts, local files) we derive `short_id = sha1(full_label)[:11]`,
    which preserves the same 11-char shape so the GCS layout is uniform.

    `full_label` is the human-readable label that survives end-to-end:
    log lines, manifest, and the obsidian-curation writer rely on it to
    rejoin extracted output with the source meaning.  Never truncated.

    `source_type` discriminates the upstream source ("youtube" |
    "workshop" | "local" | ...) so downstream tools can branch on origin
    without parsing filenames.

    `source_metadata` is an arbitrary-shape dict that carries origin-
    specific data (workshop_slug, chapter_idx, muxPlaybackId, channel,
    uploaded_at, ...).  Passed through to the obsidian writer.
    """
    url: str = ""             # canonical source URL if any (empty for pure-local sources)
    short_id: str = ""        # 11-char primary key — YT ID for youtube, sha1[:11] otherwise
    full_label: str = ""      # human-readable, non-truncated — e.g. "build-and-deploy-a-cursor-clone-ch01-intro"
    source_type: str = "youtube"  # youtube | workshop | local | other
    source_metadata: dict = field(default_factory=dict)  # source-specific (workshop_slug, chapter_idx, mux_id, ...)
    mp4_path: Path | None = None
    output_path: Path | None = None
    run_id: str = ""
    status: str = "pending"  # pending | downloaded | staged | uploaded | running | success | error
    error: str = ""
    metadata: dict = field(default_factory=dict)  # processing metadata (run-id, retries, etc.)
    signed_get_url: str = ""   # signed GCS GET URL for the mp4 (set by stage phase)
    signed_put_url: str = ""   # signed GCS PUT URL for the output JSON (set by stage phase)
    gcs_input_blob: str = ""   # gs://<bucket>/inputs/<short_id>.mp4
    gcs_output_blob: str = ""  # gs://<bucket>/outputs/<short_id>-output.json

    @property
    def youtube_id(self) -> str:
        """Backward-compat alias for callers that still expect youtube_id.
        Prefer .short_id in new code — works for any source."""
        return self.short_id


# ──────────────────────────────────────────────────────────────────────────────
# URL/ID handling
# ──────────────────────────────────────────────────────────────────────────────

def parse_youtube_id(url: str) -> str:
    """Extract the 11-char YouTube video ID from any common URL form."""
    m = YOUTUBE_ID_RE.search(url)
    if not m:
        raise ValueError(f"Could not extract YouTube ID from URL: {url}")
    return m.group(1)


def expand_channel_url(url: str, max_videos: int) -> list[str]:
    """yt-dlp --flat-playlist on a channel / playlist URL → per-video URLs.
    Caps at max_videos so a 4000-video channel doesn't trigger a runaway batch.
    Returns the original URL in a 1-element list if not a channel pattern."""
    if not CHANNEL_URL_RE.match(url):
        return [url]
    log(f"channel/playlist URL detected: {url} — expanding via yt-dlp --flat-playlist (max {max_videos})")
    cmd = [
        "yt-dlp",
        "--no-update",
        "--flat-playlist",
        "--print", "url",
        "--playlist-end", str(max_videos),
        "--extractor-args", YT_EXTRACTOR_ARGS,
        url,
    ]
    try:
        result = subprocess.run(cmd, capture_output=True, text=True, timeout=120)
        if result.returncode != 0:
            log(f"WARN: --flat-playlist exit {result.returncode}: {result.stderr[:200]}", indent=1)
            return [url]
        urls = [line.strip() for line in result.stdout.splitlines() if line.strip()]
        log(f"expanded to {len(urls)} videos", indent=1)
        return urls
    except subprocess.TimeoutExpired:
        log(f"WARN: --flat-playlist timeout after 120s — falling back to single URL", indent=1)
        return [url]


def load_urls(urls_file: Path, max_channel_videos: int = DEFAULT_MAX_CHANNEL_VIDEOS) -> list[Video]:
    """Read urls.txt: one URL per line, # comments and blanks skipped.
    Channel / playlist URLs are auto-expanded to per-video URLs (capped at
    max_channel_videos)."""
    videos: list[Video] = []
    for line in urls_file.read_text().splitlines():
        line = line.strip()
        if not line or line.startswith("#"):
            continue
        expanded = expand_channel_url(line, max_channel_videos)
        for video_url in expanded:
            try:
                vid_id = parse_youtube_id(video_url)
            except ValueError:
                log(f"skipping non-YouTube URL after expansion: {video_url}", indent=1)
                continue
            vid = Video(
                url=video_url,
                short_id=vid_id,
                full_label=vid_id,  # YouTube ID is the most useful label we have at load time
                source_type="youtube",
                source_metadata={"video_url": video_url},
            )
            vid.mp4_path = UPLOAD_DIR / f"{vid.short_id}.mp4"
            vid.output_path = UPLOAD_DIR / f"{vid.short_id}-output.json"
            videos.append(vid)
    return videos


def _short_id_from_label(label: str, length: int = 11) -> str:
    """Derive a deterministic 11-char primary key from a human label.
    Matches YouTube's 11-char ID shape so the GCS layout is uniform across
    source types.  SHA1 is fine here — we need stability + low-collision,
    not cryptographic strength."""
    import hashlib
    return hashlib.sha1(label.encode("utf-8")).hexdigest()[:length]


def load_manifest(manifest_path: Path) -> list[Video]:
    """Load videos from a manifest JSON.  Source-agnostic input mode.

    Walker-emitted manifests (e.g. walk-codewithantonio-workshop.mjs) have
    this shape:

        {
          "workshop_slug": "build-and-deploy-a-cursor-clone",
          "chapters": [
            {
              "chapter_idx": 1,
              "slug": "intro~jre5c",
              "title": "Intro",
              "mp4_path": "/abs/path/to/chapter-01.mp4",
              "muxPlaybackId": "Tg00nb..."  # optional, source-specific
            },
            ...
          ]
        }

    We accept this shape AND a generic flat form:

        {
          "source_type": "podcast",
          "items": [
            {"full_label": "ep042-deepnote-bench", "mp4_path": "..."}
          ]
        }

    Either way we produce Video records with short_id = sha1(full_label)[:11].
    The full label survives end-to-end in source_metadata for the obsidian
    writer to rejoin with extracted output.
    """
    data = json.loads(manifest_path.read_text())
    videos: list[Video] = []

    workshop_slug = data.get("workshop_slug")
    source_type = data.get("source_type") or ("workshop" if workshop_slug else "local")
    items = data.get("chapters") or data.get("items") or []

    for entry in items:
        mp4 = entry.get("mp4_path")
        if not mp4:
            continue
        # Build full_label: workshop chapters use <workshop>-ch<NN>-<slug-name>;
        # generic items use the user-provided full_label.
        if workshop_slug and "chapter_idx" in entry:
            slug_name = (entry.get("slug") or "").split("~")[0]
            full_label = f"{workshop_slug}-ch{int(entry['chapter_idx']):02d}-{slug_name}"
        else:
            full_label = entry.get("full_label") or Path(mp4).stem
        short_id = entry.get("short_id_override") or _short_id_from_label(full_label)

        # source_metadata carries everything the obsidian writer might need
        # (chapter index, title, playback id, …) without polluting the core
        # Video schema.
        source_meta = {k: v for k, v in entry.items()
                       if k not in ("mp4_path", "short_id_override")}
        source_meta["manifest_path"] = str(manifest_path)
        if workshop_slug:
            source_meta["workshop_slug"] = workshop_slug

        vid = Video(
            url="",  # no canonical URL for local-sourced MP4s
            short_id=short_id,
            full_label=full_label,
            source_type=source_type,
            source_metadata=source_meta,
        )
        vid.mp4_path = Path(mp4).expanduser()
        vid.output_path = UPLOAD_DIR / f"{vid.short_id}-output.json"
        videos.append(vid)

    log(f"manifest loaded: {len(videos)} item(s) — source_type={source_type}"
        + (f" workshop={workshop_slug}" if workshop_slug else ""))
    return videos


# ──────────────────────────────────────────────────────────────────────────────
# GCS staging — shell out to `gcloud storage`, no Python SDK dependency
# ──────────────────────────────────────────────────────────────────────────────

def gcs_upload(local_path: Path, bucket: str, blob_name: str, project: str,
               impersonate_sa: str = "") -> bool:
    """Upload local file to gs://<bucket>/<blob_name>. Idempotent: skips upload
    if the blob already exists with matching size. Returns True on success.

    The existence probe is best-effort — if gcloud is being slow (seen in
    practice as 30+s for `objects describe` when the local network is
    congested), we DON'T abort: just log a warning and proceed with the
    upload.  gcloud cp is idempotent enough at the storage layer that
    re-uploading an existing object is at worst wasted bandwidth, never
    data corruption.
    """
    gs_uri = f"gs://{bucket}/{blob_name}"
    # Check if already uploaded — best effort; tolerate timeouts.
    try:
        probe = subprocess.run(
            ["gcloud", "storage", "objects", "describe", gs_uri,
             "--project", project, "--format=value(size)"],
            capture_output=True, text=True, timeout=90,
        )
        if probe.returncode == 0 and probe.stdout.strip():
            remote_size = int(probe.stdout.strip())
            local_size = local_path.stat().st_size
            if remote_size == local_size:
                log(f"already in bucket ({remote_size // 1024 // 1024} MB) — skipping upload", indent=2)
                return True
    except subprocess.TimeoutExpired:
        log(f"WARN: GCS probe timed out after 90s — proceeding with upload anyway", indent=2)
    log(f"uploading {local_path.name} ({local_path.stat().st_size // 1024 // 1024} MB) → {gs_uri}", indent=2)
    t0 = time.time()
    result = subprocess.run(
        ["gcloud", "storage", "cp", str(local_path), gs_uri, "--project", project],
        capture_output=True, text=True, timeout=600,
    )
    if result.returncode != 0:
        log(f"GCS upload FAILED: {result.stderr[:300]}", indent=2)
        return False
    log(f"uploaded in {time.time() - t0:.0f}s", indent=2)
    return True


def gcs_sign_url(bucket: str, blob_name: str, project: str, ttl_hours: int,
                 method: str = "GET", impersonate_sa: str = "") -> str:
    """Generate a signed URL for GET or PUT. User accounts cannot sign — we
    must impersonate a service account that has a managed key. Defaults to
    the GAE default SA of the project (requires
    roles/iam.serviceAccountTokenCreator on the impersonator's identity).
    Returns empty string on failure."""
    gs_uri = f"gs://{bucket}/{blob_name}"
    cmd = [
        "gcloud", "storage", "sign-url", gs_uri,
        "--duration", f"{ttl_hours}h",
        "--http-verb", method,
        "--project", project,
    ]
    if impersonate_sa:
        cmd.extend(["--impersonate-service-account", impersonate_sa])
    # Sign-url calls can also be slow under network congestion (similar to
    # describe).  Allow 90s before giving up.
    try:
        result = subprocess.run(cmd, capture_output=True, text=True, timeout=90)
    except subprocess.TimeoutExpired:
        log(f"sign-url TIMEOUT after 90s ({method})", indent=2)
        return ""
    if result.returncode != 0:
        log(f"sign-url FAILED ({method}): {result.stderr[:300]}", indent=2)
        return ""
    # gcloud emits YAML-ish output; extract the signed_url line
    for line in result.stdout.splitlines():
        if line.startswith("signed_url:"):
            return line.split(":", 1)[1].strip()
    return ""


def gcs_download(bucket: str, blob_name: str, local_path: Path, project: str,
                 max_wait_seconds: int = 0) -> bool:
    """Download gs://<bucket>/<blob_name> to local_path. If max_wait_seconds > 0,
    poll for blob existence first."""
    gs_uri = f"gs://{bucket}/{blob_name}"
    if max_wait_seconds > 0:
        t0 = time.time()
        while time.time() - t0 < max_wait_seconds:
            try:
                probe = subprocess.run(
                    ["gcloud", "storage", "objects", "describe", gs_uri,
                     "--project", project, "--format=value(size)"],
                    capture_output=True, text=True, timeout=90,
                )
            except subprocess.TimeoutExpired:
                log(f"WARN: describe probe timeout while waiting for {gs_uri} — retrying", indent=2)
                continue
            if probe.returncode == 0 and probe.stdout.strip():
                break
            time.sleep(10)
        else:
            return False
    local_path.parent.mkdir(parents=True, exist_ok=True)
    result = subprocess.run(
        ["gcloud", "storage", "cp", gs_uri, str(local_path), "--project", project],
        capture_output=True, text=True, timeout=120,
    )
    return result.returncode == 0


# ──────────────────────────────────────────────────────────────────────────────
# PHASE 1.5 — stage (upload to GCS, sign URLs)
# ──────────────────────────────────────────────────────────────────────────────

def phase_stage(videos: list[Video], bucket: str, project: str,
                input_ttl_hours: int, output_ttl_hours: int,
                impersonate_sa: str = "") -> None:
    """Upload each downloaded mp4 to gs://<bucket>/inputs/, sign a GET URL for it,
    and pre-sign a PUT URL for gs://<bucket>/outputs/<id>-output.json so the
    notebook can upload its output directly. Sets signed_get_url / signed_put_url
    on each Video."""
    log(f"=== PHASE 1.5: stage — {len(videos)} videos → gs://{bucket}/ ===")
    log(f"project: {project}")
    log(f"input TTL: {input_ttl_hours}h | output TTL: {output_ttl_hours}h")
    log("")
    t0 = time.time()
    ok = err = 0
    for i, video in enumerate(videos, 1):
        log(f"--- Video {i}/{len(videos)}: {video.youtube_id} ---")
        if not video.mp4_path or not video.mp4_path.exists():
            log(f"[{video.youtube_id}] cannot stage: local mp4 missing at {video.mp4_path}", indent=1)
            video.status = "error"
            video.error = f"local mp4 missing for stage"
            err += 1
            continue
        input_blob = f"{GCS_INPUT_PREFIX}/{video.youtube_id}.mp4"
        output_blob = f"{GCS_OUTPUT_PREFIX}/{video.youtube_id}-output.json"
        if not gcs_upload(video.mp4_path, bucket, input_blob, project):
            video.status = "error"
            video.error = "GCS upload failed"
            err += 1
            continue
        get_url = gcs_sign_url(bucket, input_blob, project, input_ttl_hours, "GET", impersonate_sa)
        put_url = gcs_sign_url(bucket, output_blob, project, output_ttl_hours, "PUT", impersonate_sa)
        if not get_url:
            video.status = "error"
            video.error = "signed GET URL generation failed"
            err += 1
            continue
        # PUT URL is best-effort — older gcloud versions don't sign PUT URLs.
        # If it fails, ingest still works; output retrieval falls back to Drive.
        video.signed_get_url = get_url
        video.signed_put_url = put_url
        video.gcs_input_blob = input_blob
        video.gcs_output_blob = output_blob
        video.status = "staged"
        log(f"[{video.youtube_id}] staged ✓ (input blob={input_blob}, output blob={output_blob})", indent=1)
        if not put_url:
            log(f"[{video.youtube_id}] WARN: PUT URL signing failed — notebook output retrieval will need Drive fallback", indent=1)
        ok += 1
    elapsed = time.time() - t0
    log("")
    log(f"=== Stage phase complete: {ok}/{len(videos)} staged in {elapsed:.0f}s ===")


# ──────────────────────────────────────────────────────────────────────────────
# PHASE 4 — retrieve (download notebook outputs from GCS)
# ──────────────────────────────────────────────────────────────────────────────

def phase_retrieve(videos: list[Video], bucket: str, project: str,
                   max_wait_seconds: int = 300) -> None:
    """Download <id>-output.json from gs://<bucket>/outputs/ for each video.
    Polls for blob existence (notebook uploads asynchronously after run completes).
    Requires the notebook to have been patched to PUT output to OUTPUT_PUT_URL."""
    log(f"=== PHASE 4: retrieve — {len(videos)} videos from gs://{bucket}/{GCS_OUTPUT_PREFIX}/ ===")
    log(f"polling for output blobs (max {max_wait_seconds}s per video)")
    log("")
    ok = miss = 0
    for video in videos:
        if video.output_path.exists() and video.output_path.stat().st_size > 0:
            log(f"[{video.youtube_id}] output.json already local — skipping retrieve", indent=1)
            ok += 1
            continue
        blob = video.gcs_output_blob or f"{GCS_OUTPUT_PREFIX}/{video.youtube_id}-output.json"
        if gcs_download(bucket, blob, video.output_path, project, max_wait_seconds):
            kb = video.output_path.stat().st_size // 1024
            log(f"[{video.youtube_id}] retrieved ({kb} KB) → {video.output_path}", indent=1)
            ok += 1
        else:
            log(f"[{video.youtube_id}] NOT FOUND in bucket after {max_wait_seconds}s — needs notebook patch (see docs)", indent=1)
            miss += 1
    log("")
    log(f"=== Retrieve phase complete: {ok} retrieved, {miss} missing ===")


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
        # Anti-hang: restrict YouTube extractor to clients that actually work in 2026.
        # The default client list does serial probes that can sit 3-4 min before failing.
        "--extractor-args", YT_EXTRACTOR_ARGS,
        "--no-check-formats",   # skip per-format probe (huge speedup, format selector handles fallback)
        "--socket-timeout", "20",
        "--retries", "2",
        "-f", format_spec,
        "-o", str(video.mp4_path),
        video.url,
    ]
    log(f"[{video.youtube_id}] yt-dlp starting (android_vr client, no format probe — should download in seconds)", indent=1)
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


_SSL_CTX = None
def _ssl_context():
    """Build an SSLContext that works on macOS conda envs lacking a baked CA bundle.
    Tries certifi → macOS system store → Python default. Cached after first build."""
    global _SSL_CTX
    if _SSL_CTX is not None:
        return _SSL_CTX
    import ssl
    try:
        import certifi
        _SSL_CTX = ssl.create_default_context(cafile=certifi.where())
        return _SSL_CTX
    except ImportError:
        pass
    sys_ca = Path("/etc/ssl/cert.pem")
    if sys_ca.exists():
        _SSL_CTX = ssl.create_default_context(cafile=str(sys_ca))
        return _SSL_CTX
    _SSL_CTX = ssl.create_default_context()
    return _SSL_CTX


def deepnote_post(token: str, notebook_id: str, video: Video, extra_inputs: dict) -> dict:
    """POST a single run to Deepnote v2 API. Returns parsed JSON response.
    If video.signed_get_url is set (stage phase ran), VIDEO_URL is the signed
    GCS URL — notebook downloads it directly, NO Drive sync needed.
    If video.signed_put_url is set, OUTPUT_PUT_URL is included so a patched
    notebook can upload its output JSON straight back to the bucket."""
    inputs = dict(DEFAULT_INPUTS)
    if video.signed_get_url:
        inputs["VIDEO_URL"] = video.signed_get_url
    else:
        inputs["VIDEO_URL"] = f"{DRIVE_WORK_PATH}/{video.youtube_id}.mp4"
    inputs["OUTPUT_PATH"] = f"{DRIVE_WORK_PATH}/{video.youtube_id}-output.json"
    if video.signed_put_url:
        inputs["OUTPUT_PUT_URL"] = video.signed_put_url
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
        with urllib.request.urlopen(req, timeout=1200, context=_ssl_context()) as resp:
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
        with urllib.request.urlopen(req, timeout=30, context=_ssl_context()) as resp:
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


# ──────────────────────────────────────────────────────────────────────────────
# PHASE 2 — ingest (Replicate API alternate backend)
# Same shape as Deepnote path so --backend replicate is a drop-in switch.
# ──────────────────────────────────────────────────────────────────────────────

REPLICATE_API_BASE = "https://api.replicate.com"
DEFAULT_REPLICATE_MODEL = "ramene/mae-video-ingestion"


def replicate_load_token() -> str:
    """Load Replicate API token. Order: REPLICATE_API_TOKEN env > ~/.config/replicate/auth.json."""
    token = os.environ.get("REPLICATE_API_TOKEN", "").strip()
    if token:
        return token
    cfg = Path.home() / ".config" / "replicate" / "auth.json"
    if cfg.exists():
        try:
            data = json.loads(cfg.read_text())
            t = data.get("token") or data.get("api_token")
            if t:
                return t
        except Exception:
            pass
    sys.exit("FATAL: no REPLICATE_API_TOKEN env var; export it or save to ~/.config/replicate/auth.json")


def replicate_latest_version(token: str, model: str) -> str:
    """Fetch the latest version SHA for a Replicate model. Returns empty string on error."""
    url = f"{REPLICATE_API_BASE}/v1/models/{model}"
    req = urllib.request.Request(url, headers={"Authorization": f"Bearer {token}"})
    try:
        with urllib.request.urlopen(req, timeout=30, context=_ssl_context()) as resp:
            d = json.loads(resp.read().decode())
            v = d.get("latest_version") or {}
            return v.get("id", "")
    except (urllib.error.HTTPError, urllib.error.URLError):
        return ""


def replicate_post(token: str, model: str, video: Video, extra_inputs: dict,
                    version_sha: str = "") -> dict:
    """POST a prediction to Replicate.

    Uses /v1/predictions with explicit version field (NOT /v1/models/{owner}/{name}/predictions —
    that route requires the model's default-version to be explicitly set, which fresh cog
    pushes often don't have). Auto-fetches the latest version SHA if not supplied."""
    if not version_sha:
        version_sha = replicate_latest_version(token, model)
        if not version_sha:
            return {"error": f"could not resolve a version SHA for model {model} — confirm model exists + has a published version"}

    # Map our Deepnote-style env-var names to Replicate predict.py field names
    inputs = {
        "video_url": video.url,
        "profile": extra_inputs.get("PROMPT_PROFILE", DEFAULT_INPUTS["PROMPT_PROFILE"]),
        "chunk_duration_sec": int(extra_inputs.get("CHUNK_DURATION_SEC", DEFAULT_INPUTS["CHUNK_DURATION_SEC"])),
        "video_fps": float(extra_inputs.get("VIDEO_FPS", DEFAULT_INPUTS["VIDEO_FPS"])),
    }
    if "VIDEO_MAX_PIXELS" in extra_inputs:
        inputs["video_max_pixels"] = int(extra_inputs["VIDEO_MAX_PIXELS"])
    if "MAX_NEW_TOKENS" in extra_inputs:
        inputs["max_new_tokens"] = int(extra_inputs["MAX_NEW_TOKENS"])
    if "PROMPT_OVERRIDE" in extra_inputs:
        inputs["prompt_override"] = extra_inputs["PROMPT_OVERRIDE"]

    body = {"version": version_sha, "input": inputs}
    url = f"{REPLICATE_API_BASE}/v1/predictions"
    req = urllib.request.Request(
        url,
        data=json.dumps(body).encode(),
        headers={
            "Authorization": f"Bearer {token}",
            "Content-Type": "application/json",
            "Prefer": "wait=10",   # let Replicate hold up to 10s before returning — saves one poll
        },
        method="POST",
    )
    try:
        with urllib.request.urlopen(req, timeout=60, context=_ssl_context()) as resp:
            return json.loads(resp.read().decode())
    except urllib.error.HTTPError as e:
        body_text = e.read().decode("utf-8", "replace")[:500]
        # 402 = insufficient credit; surface a clearer message
        if e.code == 402:
            return {"error": f"HTTP 402 INSUFFICIENT CREDIT — add at https://replicate.com/account/billing\n   detail: {body_text}"}
        return {"error": f"HTTP {e.code}: {body_text}"}
    except urllib.error.URLError as e:
        return {"error": f"URL error: {e.reason}"}


def replicate_get_prediction(token: str, prediction_id: str) -> dict:
    """Single GET of a prediction's status."""
    req = urllib.request.Request(
        f"{REPLICATE_API_BASE}/v1/predictions/{prediction_id}",
        headers={"Authorization": f"Bearer {token}"},
    )
    try:
        with urllib.request.urlopen(req, timeout=30, context=_ssl_context()) as resp:
            return json.loads(resp.read().decode())
    except urllib.error.HTTPError as e:
        return {"error": f"HTTP {e.code}: {e.read().decode('utf-8', 'replace')[:300]}"}


REPLICATE_TERMINAL = {"succeeded", "failed", "canceled"}


def replicate_poll_until_terminal(token: str, prediction_id: str, label: str = "",
                                   max_seconds: int = 1800, poll_interval: int = 15) -> dict:
    """Loop-poll a prediction every poll_interval seconds until terminal or max_seconds elapsed."""
    tag = f"[{label}]" if label else f"[{prediction_id[:8]}]"
    t0 = time.time()
    last_status = "(initial)"
    poll_n = 0
    log(f"{tag} polling prediction={prediction_id} every {poll_interval}s (max {max_seconds // 60} min)", indent=1)
    while True:
        elapsed = int(time.time() - t0)
        if elapsed > max_seconds:
            log(f"{tag} TIMEOUT after {elapsed}s (last={last_status})", indent=2)
            return {"status": "timed_out", "error": f"poll exceeded {max_seconds}s"}
        resp = replicate_get_prediction(token, prediction_id)
        if "error" in resp and "status" not in resp:
            log(f"{tag} poll #{poll_n + 1} @ {elapsed}s: API error: {resp['error']}", indent=2)
            return resp
        new_status = resp.get("status", "unknown")
        poll_n += 1
        if new_status != last_status:
            log(f"{tag} poll #{poll_n} @ {elapsed}s: {last_status} → {new_status}", indent=2)
        last_status = new_status
        if new_status in REPLICATE_TERMINAL:
            return resp
        time.sleep(poll_interval)


def ingest_video_replicate(token: str, model: str, video: Video, extra_inputs: dict) -> None:
    """Submit one video to Replicate, block until done. Saves output JSON to
    video.output_path (same path Deepnote backend uses, for downstream compatibility)."""
    # Idempotency: skip if output.json already in ~/Downloads/upload/
    if video.output_path.exists() and video.output_path.stat().st_size > 0:
        kb = video.output_path.stat().st_size // 1024
        log(f"[{video.youtube_id}] output.json already present ({kb} KB) — skipping", indent=1)
        video.status = "success"
        return

    log(f"[{video.youtube_id}] POSTing to Replicate API (model={model})", indent=1)
    log(f"[{video.youtube_id}] video_url={video.url}", indent=1)
    log(f"[{video.youtube_id}] NOTE: Replicate cold-start adds 30-90s if instance scaled to zero", indent=1)

    t0 = time.time()
    resp = replicate_post(token, model, video, extra_inputs)
    submit_elapsed = time.time() - t0

    if "error" in resp and "id" not in resp:
        video.status = "error"
        video.error = resp["error"]
        log(f"[{video.youtube_id}] POST FAILED after {submit_elapsed:.0f}s: {video.error}", indent=1)
        return

    prediction_id = resp.get("id", "")
    initial_status = resp.get("status", "unknown")
    video.run_id = prediction_id
    log(f"[{video.youtube_id}] prediction={prediction_id} initial={initial_status} (post took {submit_elapsed:.0f}s)", indent=1)

    # If Prefer: wait=10 already returned a terminal status, skip polling
    if initial_status in REPLICATE_TERMINAL:
        final = resp
    else:
        final = replicate_poll_until_terminal(token, prediction_id, label=video.youtube_id,
                                                max_seconds=1800, poll_interval=15)

    status = final.get("status", "unknown")
    total_elapsed = time.time() - t0

    if status == "succeeded":
        output = final.get("output")
        if not output:
            video.status = "error"
            video.error = "Replicate reported succeeded but output is empty"
            log(f"[{video.youtube_id}] {video.error}", indent=1)
            return
        video.output_path.parent.mkdir(parents=True, exist_ok=True)
        video.output_path.write_text(json.dumps(output, indent=2))
        kb = video.output_path.stat().st_size // 1024
        video.status = "success"
        log(f"[{video.youtube_id}] SUCCESS in {total_elapsed:.0f}s — wrote {kb} KB to {video.output_path}", indent=1)
    elif status in ("failed", "canceled", "timed_out"):
        video.status = "error"
        video.error = str(final.get("error") or final.get("logs", "no error detail"))[:500]
        log(f"[{video.youtube_id}] {status.upper()} after {total_elapsed:.0f}s: {video.error}", indent=1)
    else:
        video.status = status
        log(f"[{video.youtube_id}] non-terminal status={status} after {total_elapsed:.0f}s", indent=1)


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

    # Local mp4 check only matters when we're NOT using the GCS signed-URL path.
    # If signed_get_url is set, the notebook fetches the video over HTTPS from
    # the bucket — no local mp4 needed at ingest time.
    if not video.signed_get_url:
        if not video.mp4_path or not video.mp4_path.exists():
            video.status = "error"
            video.error = f"mp4 not found at {video.mp4_path} and no signed URL — run stage phase first OR upload to Deepnote work folder"
            log(f"[{video.youtube_id}] SKIP: {video.error}", indent=1)
            return

    # Idempotency: skip if output.json already in ~/Downloads/upload/
    if video.output_path.exists() and video.output_path.stat().st_size > 0:
        kb = video.output_path.stat().st_size // 1024
        log(f"[{video.youtube_id}] output.json already present ({kb} KB) — skipping", indent=1)
        video.status = "success"
        return

    log(f"[{video.youtube_id}] POSTing to Deepnote v2 Runs API (synchronous mode — blocks up to 20 min while notebook runs)", indent=1)
    if video.signed_get_url:
        log(f"[{video.youtube_id}] VIDEO_URL=<signed GCS URL, {len(video.signed_get_url)} chars>", indent=1)
    else:
        log(f"[{video.youtube_id}] VIDEO_URL={DRIVE_WORK_PATH}/{video.youtube_id}.mp4", indent=1)
    log(f"[{video.youtube_id}] OUTPUT_PATH={DRIVE_WORK_PATH}/{video.youtube_id}-output.json", indent=1)
    if video.signed_put_url:
        log(f"[{video.youtube_id}] OUTPUT_PUT_URL=<signed PUT URL> (requires notebook patch — see docs)", indent=1)
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
                  drive_path: Path | None = None,
                  backend: str = "deepnote",
                  replicate_model: str = DEFAULT_REPLICATE_MODEL,
                  restart_between: bool = False,
                  restart_project_id: str = "") -> None:
    # Replicate backend short-circuits the Deepnote-specific path
    if backend == "replicate":
        log(f"=== PHASE 2: ingest — {len(videos)} videos via REPLICATE API ===")
        log(f"Replicate model: {replicate_model}")
        log(f"Inputs: {extra_inputs}")
        token = replicate_load_token()
        for i, video in enumerate(videos, 1):
            log("")
            log(f"--- Video {i}/{len(videos)}: {video.youtube_id} ---")
            ingest_video_replicate(token, replicate_model, video, extra_inputs)
        return

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
        # Cold-start guarantee: before the 2nd+ video, restart the machine to
        # defeat the warm-kernel state leak.  Each restart adds ~30-60s + a
        # ~$0.05-0.10 cold-start cost; in exchange every run starts with the
        # full ~22 GB VRAM free (vs ~3 GB free after a leaky warm reuse).
        # See [[project_deepnote_oom_patch_ineffective]] for the empirical data.
        if restart_between and i > 1:
            if not restart_project_id:
                log(f"WARN: --restart-between set but --restart-project-id empty; skipping restart")
            else:
                log(f"--- Restarting machine before video {i} (cold-start defeats warm-kernel OOM) ---")
                try:
                    # Lazy import — the machine-control module needs F12 endpoints
                    # filled in before this call works.  Fails clearly if not.
                    import importlib.util as _ilu
                    _mc_path = Path(__file__).parent / "deepnote_machine_control.py"
                    _spec = _ilu.spec_from_file_location("dmc", _mc_path)
                    _mc = _ilu.module_from_spec(_spec)
                    _spec.loader.exec_module(_mc)
                    _mc.restart_machine(restart_project_id, settle_seconds=30)
                    log(f"  ✓ machine restarted; resuming ingest")
                except Exception as e:
                    log(f"  ✗ restart failed: {e}", indent=1)
                    log(f"  (check deepnote_machine_control.py — F12 endpoints filled in?)", indent=1)
                    log(f"  proceeding WITHOUT restart — extraction may produce _inference_error", indent=1)

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
    p.add_argument("phase", choices=["download", "stage", "ingest", "retrieve", "summary", "all", "wait"],
                   help=("Which phase to run. 'all' chains download → stage → ingest → retrieve → summary "
                         "for fully automated direct-POST. 'stage' uploads downloaded mp4s to GCS and signs URLs. "
                         "'retrieve' pulls output JSON back from GCS (needs notebook patch). 'wait' takes "
                         "a runId in place of urls_file."))
    p.add_argument("urls_file", type=str, nargs="?", default="",
                   help="Path to urls.txt (YouTube URLs, channels, playlists — auto-expanded). "
                        "OR a Deepnote runId when phase=wait. Omit when using --manifest.")
    p.add_argument("--manifest", type=str, default="",
                   help="Path to a manifest JSON for source-agnostic ingest "
                        "(workshop walker output, local-dir walker output, podcast list, etc.). "
                        "Each item provides mp4_path + full_label; short_id is derived as sha1(label)[:11]. "
                        "Mutually exclusive with urls_file.  See load_manifest() docstring for shape.")
    p.add_argument("--restart-between", action="store_true",
                   help="Stop+start the Deepnote machine between videos to defeat the warm-kernel "
                        "OOM leak documented in [[project_deepnote_oom_patch_ineffective]]. Adds "
                        "~30-60s + ~$0.05-0.10 cold-start cost per video, but yields reliable "
                        "extractions. Requires deepnote_machine_control.py F12 endpoints to be filled.")
    p.add_argument("--restart-project-id", default="ae2b2f17-fb74-43bf-a749-b5a5b8a163c8",
                   help="Project UUID for --restart-between (default: native-video)")
    p.add_argument("--notebook-id", default=os.environ.get("DEEPNOTE_NOTEBOOK_ID", DEFAULT_NOTEBOOK_ID),
                   help=f"Deepnote notebook ID (default: {DEFAULT_NOTEBOOK_ID})")
    p.add_argument("--format", default=DEFAULT_FORMAT,
                   help=f"yt-dlp format spec (default: {DEFAULT_FORMAT}). Prefers pre-muxed formats so ffmpeg isn't needed locally.")
    p.add_argument("--gcs-bucket", default=os.environ.get("VIDEO_GCS_BUCKET", DEFAULT_GCS_BUCKET),
                   help=f"GCS staging bucket name (default: {DEFAULT_GCS_BUCKET}). Used by stage + retrieve phases.")
    p.add_argument("--gcs-project", default=os.environ.get("VIDEO_GCS_PROJECT", DEFAULT_GCS_PROJECT),
                   help=f"GCP project owning the bucket (default: {DEFAULT_GCS_PROJECT}).")
    p.add_argument("--gcs-impersonate-sa", default=os.environ.get("VIDEO_GCS_IMPERSONATE_SA", DEFAULT_GCS_IMPERSONATE_SA),
                   help=(f"Service account to impersonate for sign-url (default: {DEFAULT_GCS_IMPERSONATE_SA}). "
                         "User accounts can't sign URLs; this SA must have a managed key (GAE default SA "
                         "always does). Caller needs roles/iam.serviceAccountTokenCreator on this SA. "
                         "Set to empty string to skip impersonation if you have a service-account JSON key activated."))
    p.add_argument("--no-gcs", action="store_true",
                   help="Disable GCS staging entirely — fall back to legacy Drive-sync path (ingest uses local Deepnote path).")
    p.add_argument("--input-ttl-hours", type=int, default=DEFAULT_INPUT_TTL_HOURS,
                   help=f"Signed-GET-URL TTL for input mp4 (default: {DEFAULT_INPUT_TTL_HOURS}h)")
    p.add_argument("--output-ttl-hours", type=int, default=DEFAULT_OUTPUT_TTL_HOURS,
                   help=f"Signed-PUT-URL TTL for output JSON (default: {DEFAULT_OUTPUT_TTL_HOURS}h)")
    p.add_argument("--max-channel-videos", type=int, default=DEFAULT_MAX_CHANNEL_VIDEOS,
                   help=f"Per-channel-URL cap when expanding via --flat-playlist (default: {DEFAULT_MAX_CHANNEL_VIDEOS}). Stops a 4000-video channel from triggering a runaway batch.")
    p.add_argument("--retrieve-max-wait", type=int, default=300,
                   help="Max seconds to poll bucket for each output JSON during retrieve phase (default: 300)")
    p.add_argument("--input", action="append", default=[], metavar="KEY=VALUE",
                   help="Override a Deepnote input block (e.g. --input CHUNK_DURATION_SEC=600). Can be repeated.")
    p.add_argument("--profile", default=None,
                   help=("Shorthand for --input PROMPT_PROFILE=<name>. Selects a prompt profile from "
                         "the inline library in Cell 14 of the notebook (or matching disk YAML at "
                         "notebooks/video-ingestion/prompt-profiles/<name>.yaml). Common values: "
                         "ai-systems-research, paper-author-talk, coding-tutorial, product-announcement, "
                         "trading-education, trading-intelligence, general-summary."))
    p.add_argument("--override-prompt", default=None, metavar="PATH",
                   help=("Read prompt body from PATH and pass as --input PROMPT_OVERRIDE=<content>. "
                         "Bypasses the profile lookup entirely. Use for one-off experiments without "
                         "committing a new profile. Use '-' to read from stdin."))
    p.add_argument("--backend", default="deepnote", choices=["deepnote", "replicate"],
                   help=("Inference backend. 'deepnote' (default) runs the notebook on Deepnote "
                         "via v2 Runs API. 'replicate' calls the deployed Replicate model API "
                         "at r8.im/ramene/mae-video-ingestion (or --replicate-model). Replicate "
                         "skips Drive sync entirely — output JSON returns in the API response."))
    p.add_argument("--replicate-model", default=DEFAULT_REPLICATE_MODEL,
                   help=f"Replicate model identifier when --backend=replicate (default: {DEFAULT_REPLICATE_MODEL})")
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

    # Manifest mode (source-agnostic) vs urls.txt mode (YouTube).  Mutually
    # exclusive; manifest wins if both are provided.
    if args.manifest:
        manifest_path = Path(args.manifest).expanduser()
        if not manifest_path.exists():
            sys.exit(f"FATAL: manifest not found: {manifest_path}")
        videos = load_manifest(manifest_path)
        if not videos:
            sys.exit(f"FATAL: no items in {manifest_path}")
        # The download phase is meaningless for manifest mode — MP4s already
        # exist locally (walker pre-staged them).  Warn but don't fail.
        if args.phase in ("download", "all"):
            log(f"NOTE: phase={args.phase} with --manifest — download phase is a no-op for pre-staged MP4s")
    else:
        if not args.urls_file:
            sys.exit("FATAL: provide urls_file (YouTube URLs) OR --manifest (any source). Both omitted.")
        urls_path = Path(args.urls_file)
        if not urls_path.exists():
            sys.exit(f"FATAL: urls file not found: {urls_path}")
        videos = load_urls(urls_path, max_channel_videos=args.max_channel_videos)
        if not videos:
            sys.exit(f"FATAL: no URLs in {urls_path}")

    extra_inputs = {}
    for kv in args.input:
        if "=" not in kv:
            sys.exit(f"FATAL: --input expects KEY=VALUE, got: {kv}")
        k, v = kv.split("=", 1)
        extra_inputs[k] = v

    # --profile shorthand → --input PROMPT_PROFILE=<name>
    if args.profile:
        extra_inputs["PROMPT_PROFILE"] = args.profile

    # --override-prompt → read body, --input PROMPT_OVERRIDE=<content>
    if args.override_prompt:
        if args.override_prompt == "-":
            prompt_body = sys.stdin.read()
        else:
            prompt_path = Path(args.override_prompt).expanduser()
            if not prompt_path.exists():
                sys.exit(f"FATAL: --override-prompt path not found: {prompt_path}")
            prompt_body = prompt_path.read_text()
        prompt_body = prompt_body.strip()
        if not prompt_body:
            sys.exit(f"FATAL: --override-prompt body is empty")
        extra_inputs["PROMPT_OVERRIDE"] = prompt_body
        log(f"--override-prompt loaded {len(prompt_body)} chars (bypasses PROMPT_PROFILE)")

    log(f"=== batch_ingest.py — phase={args.phase} ===")
    if args.manifest:
        log(f"manifest:      {args.manifest}")
    else:
        log(f"urls file:     {urls_path}")
    log(f"upload dir:    {UPLOAD_DIR}")
    log(f"token file:    {TOKEN_PATH}")
    log(f"notebook id:   {args.notebook_id}")
    log(f"yt-dlp format: {args.format}")
    log(f"loaded {len(videos)} video item(s):")
    for v in videos:
        # Show full_label (human) + short_id (gcs key) + source-type so the
        # operator can verify what's about to be processed at a glance.
        log(f"  - {v.short_id}  [{v.source_type}]  {v.full_label}", indent=1)
    log("")

    use_gcs = not args.no_gcs

    if args.phase == "download":
        phase_download(videos, args.format)
    elif args.phase == "stage":
        if not use_gcs:
            sys.exit("FATAL: stage phase requires GCS — drop --no-gcs to enable")
        phase_stage(videos, args.gcs_bucket, args.gcs_project,
                    args.input_ttl_hours, args.output_ttl_hours,
                    impersonate_sa=args.gcs_impersonate_sa)
    elif args.phase == "ingest":
        # Auto-stage if GCS enabled and signed_get_url not set (running ingest in isolation)
        if use_gcs and args.backend == "deepnote" and not any(v.signed_get_url for v in videos):
            log("auto-staging before ingest (use --no-gcs to skip)")
            phase_stage(videos, args.gcs_bucket, args.gcs_project,
                        args.input_ttl_hours, args.output_ttl_hours,
                        impersonate_sa=args.gcs_impersonate_sa)
            log("")
        phase_ingest(videos, args.notebook_id, extra_inputs, drive_path,
                     backend=args.backend, replicate_model=args.replicate_model,
                     restart_between=args.restart_between,
                     restart_project_id=args.restart_project_id)
    elif args.phase == "retrieve":
        phase_retrieve(videos, args.gcs_bucket, args.gcs_project, args.retrieve_max_wait)
    elif args.phase == "summary":
        phase_summary(videos)
    elif args.phase == "all":
        # Replicate backend short-circuits download (the API fetches from URL itself)
        if args.backend == "replicate":
            phase_ingest(videos, args.notebook_id, extra_inputs, drive_path,
                         backend=args.backend, replicate_model=args.replicate_model)
            phase_summary(videos)
            return
        # Deepnote backend: download → stage → ingest → retrieve → summary
        phase_download(videos, args.format)
        if use_gcs:
            phase_stage(videos, args.gcs_bucket, args.gcs_project,
                        args.input_ttl_hours, args.output_ttl_hours,
                        impersonate_sa=args.gcs_impersonate_sa)
            phase_ingest(videos, args.notebook_id, extra_inputs, drive_path,
                         backend=args.backend, replicate_model=args.replicate_model)
            phase_retrieve(videos, args.gcs_bucket, args.gcs_project, args.retrieve_max_wait)
        else:
            # Legacy path — operator drags files manually
            if drive_path is None:
                input("\nPress Enter once you've dragged mp4 files into Deepnote work folder...")
            phase_ingest(videos, args.notebook_id, extra_inputs, drive_path,
                         backend=args.backend, replicate_model=args.replicate_model)
            if drive_path is None:
                input("\nPress Enter once you've dragged output.json files back to ~/Downloads/upload/...")
        phase_summary(videos)


if __name__ == "__main__":
    main()
