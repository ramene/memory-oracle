#!/usr/bin/env python3
"""
Stop + start the Deepnote machine for a project — the operator-side fix path
for the OOM patch failure documented in
[[project_deepnote_oom_patch_ineffective]] (every back-to-back warm run
silently corrupts; cold-starts are the only reliable way to get clean GPU
state today).

The Deepnote machine-control endpoints are NOT exposed by the public API
(`api.deepnote.com`) — all probes returned 404.  Like the import-deepnote
endpoint, they live on the WEB API (`deepnote.com/api/*`) with cookie-auth.

# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
# F12 CAPTURE TO COMPLETE THIS SCRIPT
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
# Open the project in Chrome with DevTools → Network → Fetch/XHR filter,
# `deepnote.com` in the filter box, Preserve log ON.  Then:
#
#   STEP A — capture Stop machine
#   1. Click 🚫 to clear the log
#   2. Project sidebar → "Stop machine" button (bottom-left)
#   3. Wait for the machine state to flip to "stopped"
#   4. In Network list, find the request that fires immediately after the
#      click — likely POST or DELETE.  Click it.
#   5. Headers tab — note Request URL + Method + Content-Type
#   6. Payload tab — note the body shape (often {} or {"action":"stop"})
#   7. Right-click → Copy → Copy as cURL  →  paste into:
#         /tmp/deepnote-stop-machine.curl
#      (Redact Cookie / Authorization values before sharing externally)
#
#   STEP B — capture Start machine
#   8. Same setup (clear log).  Click "Start machine" or "Run".
#   9. Find the matching POST/PUT request.  Same capture procedure.
#  10. Save → /tmp/deepnote-start-machine.curl
#
# Then fill in the two functions at the bottom of this file with:
#   - the captured URL (path under deepnote.com)
#   - the HTTP method
#   - the body shape (if any)
#
# Verification: run with --dry-run first, confirm the URL it would hit, then
# remove --dry-run for the real call.
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

from __future__ import annotations

import argparse
import json
import ssl
import sys
import time
import urllib.error
import urllib.request
from pathlib import Path

import certifi
_SSL_CONTEXT = ssl.create_default_context(cafile=certifi.where())

DEEPNOTE_WEB_BASE = "https://deepnote.com"
COOKIE_FILE = Path.home() / ".claude" / ".credentials" / "deepnote-cookies.json"


def load_cookies() -> str:
    if not COOKIE_FILE.exists():
        raise FileNotFoundError(f"{COOKIE_FILE} not found.")
    return json.loads(COOKIE_FILE.read_text())["cookie_header"]


def web_call(method: str, path: str, body: dict | None = None,
             cookie_header: str | None = None, timeout: int = 30) -> tuple[int, str]:
    """Generic WEB-API call. Returns (status_code, body_text)."""
    if cookie_header is None:
        cookie_header = load_cookies()
    url = f"{DEEPNOTE_WEB_BASE}{path}"
    payload = json.dumps(body).encode("utf-8") if body else b""
    req = urllib.request.Request(url, data=payload or None, method=method)
    req.add_header("Cookie", cookie_header)
    req.add_header("Accept", "application/json")
    req.add_header("Origin", DEEPNOTE_WEB_BASE)
    req.add_header("Referer", f"{DEEPNOTE_WEB_BASE}/")
    if body:
        req.add_header("Content-Type", "application/json")
    try:
        with urllib.request.urlopen(req, timeout=timeout, context=_SSL_CONTEXT) as resp:
            return (resp.status, resp.read().decode("utf-8"))
    except urllib.error.HTTPError as e:
        return (e.code, e.read().decode("utf-8", errors="replace"))


# ━━━ FILL IN AFTER F12 CAPTURE ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
# Replace `PATH`, `METHOD`, and `BODY` with the values from /tmp/deepnote-{stop,start}-machine.curl.

def stop_machine(project_id: str, *, dry_run: bool = False) -> dict:
    """Stop the running machine for project_id.  Returns the parsed response."""
    # TODO replace after F12: e.g. PATH=f"/api/project/{project_id}/machine/stop"
    PATH = f"/api/project/{project_id}/MACHINE_STOP_TODO"
    METHOD = "POST"
    BODY: dict | None = None  # most likely {} or {"action":"stop"}; check F12

    print(f"[stop] {METHOD} {DEEPNOTE_WEB_BASE}{PATH}  body={BODY}", file=sys.stderr)
    if dry_run:
        return {"dry_run": True, "method": METHOD, "path": PATH, "body": BODY}
    code, text = web_call(METHOD, PATH, BODY)
    print(f"[stop] HTTP {code}", file=sys.stderr)
    if code >= 400:
        raise RuntimeError(f"stop failed HTTP {code}: {text[:300]}")
    try: return json.loads(text)
    except: return {"raw": text, "status": code}


def start_machine(project_id: str, *, dry_run: bool = False) -> dict:
    """Start a machine for project_id.  Returns the parsed response."""
    # TODO replace after F12: e.g. PATH=f"/api/project/{project_id}/machine/start"
    PATH = f"/api/project/{project_id}/MACHINE_START_TODO"
    METHOD = "POST"
    BODY: dict | None = None  # may need {"hardware":"GPU_L4"} or similar — check F12

    print(f"[start] {METHOD} {DEEPNOTE_WEB_BASE}{PATH}  body={BODY}", file=sys.stderr)
    if dry_run:
        return {"dry_run": True, "method": METHOD, "path": PATH, "body": BODY}
    code, text = web_call(METHOD, PATH, BODY)
    print(f"[start] HTTP {code}", file=sys.stderr)
    if code >= 400:
        raise RuntimeError(f"start failed HTTP {code}: {text[:300]}")
    try: return json.loads(text)
    except: return {"raw": text, "status": code}


def restart_machine(project_id: str, *, settle_seconds: int = 30,
                    dry_run: bool = False) -> dict:
    """Stop, wait, then start.  Use between batch_ingest videos to defeat
    the warm-kernel state leak ([[project_deepnote_oom_patch_ineffective]])."""
    stop_resp = stop_machine(project_id, dry_run=dry_run)
    if not dry_run:
        print(f"[restart] settling {settle_seconds}s before re-start…", file=sys.stderr)
        time.sleep(settle_seconds)
    start_resp = start_machine(project_id, dry_run=dry_run)
    return {"stop": stop_resp, "start": start_resp}


# ─── cli ───────────────────────────────────────────────────────────────────

def main(argv: list[str] | None = None) -> int:
    p = argparse.ArgumentParser(description=__doc__,
                                formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("action", choices=["stop", "start", "restart"])
    p.add_argument("--project-id", default="ae2b2f17-fb74-43bf-a749-b5a5b8a163c8",
                   help="Deepnote project UUID (default: native-video)")
    p.add_argument("--settle-seconds", type=int, default=30,
                   help="Wait between stop and start during a restart (default 30s)")
    p.add_argument("--dry-run", action="store_true",
                   help="Print the planned call without firing it")
    args = p.parse_args(argv)

    if args.action == "stop":
        out = stop_machine(args.project_id, dry_run=args.dry_run)
    elif args.action == "start":
        out = start_machine(args.project_id, dry_run=args.dry_run)
    else:
        out = restart_machine(args.project_id,
                              settle_seconds=args.settle_seconds,
                              dry_run=args.dry_run)
    print(json.dumps(out, indent=2))
    return 0


if __name__ == "__main__":
    sys.exit(main())
