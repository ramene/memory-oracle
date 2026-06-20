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
# ============================================================================
"""

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


# ━━━ GraphQL operations (captured 2026-06-19 from DevTools, operator-confirmed) ━━━

DEEPNOTE_GRAPHQL_URL = f"{DEEPNOTE_WEB_BASE}/graphql"

# Mutation: StartProjectHardware → startProjectExecutor union(Success{ok} | Error{error})
START_HARDWARE_QUERY = """mutation StartProjectHardware($projectId: String!) {
  startProjectExecutor(projectId: $projectId) {
    ... on ProjectExecutorStartSuccess { ok __typename }
    ... on ProjectExecutorStartError { error __typename }
    __typename
  }
}"""

# Mutation: StopProjectHardware → stopProjectExecutor union(Success{ok} | Error{error})
STOP_HARDWARE_QUERY = """mutation StopProjectHardware($projectId: String!) {
  stopProjectExecutor(projectId: $projectId) {
    ... on ProjectExecutorStopSuccess { ok __typename }
    ... on ProjectExecutorStopError { error __typename }
    __typename
  }
}"""

# Query: GetProjectHardwareState → hardware_state + hardware_message (read-only)
GET_HARDWARE_STATE_QUERY = """query GetProjectHardwareState($projectId: String!) {
  projectById(id: $projectId) {
    ... on Project {
      hardware_state {
        hardware_status
        executor_status
        initialized
        tunnel_domain
        __typename
      }
      hardware_message {
        message severity documentationUrl duration actionable __typename
      }
      __typename
    }
    __typename
  }
}"""


def _graphql(operation_name: str, query: str, variables: dict,
             cookie_header: str | None = None, timeout: int = 30) -> dict:
    """POST a GraphQL operation to deepnote.com/graphql with cookie auth.

    The DevTools-captured curls always pass operation_name as a query param
    (cosmetic — actual routing is by `operationName` in the body), and the
    `query` field must be the FULL query string (Apollo persisted-queries
    are not registered for our session)."""
    url = f"{DEEPNOTE_GRAPHQL_URL}?operation_name={operation_name}"
    body_obj = {"operationName": operation_name, "variables": variables, "query": query}
    code, text = web_call("POST", f"/graphql?operation_name={operation_name}",
                          body_obj, cookie_header=cookie_header, timeout=timeout)
    if code >= 400:
        raise RuntimeError(f"GraphQL {operation_name} HTTP {code}: {text[:400]}")
    try:
        resp = json.loads(text)
    except Exception:
        return {"raw": text, "status": code}
    if "errors" in resp and resp["errors"]:
        # Surface GraphQL errors without raising — caller decides
        return {"errors": resp["errors"], "data": resp.get("data")}
    return resp.get("data", {})


def get_hardware_state(project_id: str) -> dict:
    """Return current hardware state including tunnel_domain (Incoming Connections URL)
    when initialized=true. Read-only — safe to call at any time."""
    data = _graphql("GetProjectHardwareState", GET_HARDWARE_STATE_QUERY,
                    {"projectId": project_id})
    if "errors" in data:
        return data
    proj = data.get("projectById") or {}
    return {
        "hardware_state": proj.get("hardware_state"),
        "hardware_message": proj.get("hardware_message"),
    }


def stop_machine(project_id: str, *, dry_run: bool = False) -> dict:
    """Stop the running machine for project_id.  Returns the parsed response."""
    print(f"[stop] POST /graphql?operation_name=StopProjectHardware projectId={project_id}", file=sys.stderr)
    if dry_run:
        return {"dry_run": True, "operation": "StopProjectHardware", "projectId": project_id}
    data = _graphql("StopProjectHardware", STOP_HARDWARE_QUERY, {"projectId": project_id})
    if "errors" in data:
        raise RuntimeError(f"stop failed: {data['errors']}")
    result = data.get("stopProjectExecutor") or {}
    print(f"[stop] {result.get('__typename')}: ok={result.get('ok')} error={result.get('error')}", file=sys.stderr)
    return result


def start_machine(project_id: str, *, dry_run: bool = False) -> dict:
    """Start a machine for project_id.  Returns the parsed response."""
    print(f"[start] POST /graphql?operation_name=StartProjectHardware projectId={project_id}", file=sys.stderr)
    if dry_run:
        return {"dry_run": True, "operation": "StartProjectHardware", "projectId": project_id}
    data = _graphql("StartProjectHardware", START_HARDWARE_QUERY, {"projectId": project_id})
    if "errors" in data:
        raise RuntimeError(f"start failed: {data['errors']}")
    result = data.get("startProjectExecutor") or {}
    print(f"[start] {result.get('__typename')}: ok={result.get('ok')} error={result.get('error')}", file=sys.stderr)
    return result


def restart_machine(project_id: str, *, settle_seconds: int = 30,
                    poll_seconds: int = 120, dry_run: bool = False) -> dict:
    """Stop, wait, then start. Use between batch_ingest videos to defeat the warm-kernel state leak (see project_deepnote_oom_patch_ineffective memory).

    After issuing Start, poll hardware_state up to poll_seconds until
    executor_status reaches a steady running state (or fail clearly)."""
    stop_resp = stop_machine(project_id, dry_run=dry_run)
    if not dry_run:
        print(f"[restart] settling {settle_seconds}s before re-start...", file=sys.stderr)
        time.sleep(settle_seconds)
    start_resp = start_machine(project_id, dry_run=dry_run)
    if dry_run:
        return {"stop": stop_resp, "start": start_resp, "final_state": None}

    # Poll for machine readiness so the caller can immediately fire work
    t0 = time.time()
    final_state = None
    while time.time() - t0 < poll_seconds:
        st = get_hardware_state(project_id)
        hw = st.get("hardware_state") or {}
        status = hw.get("hardware_status")
        exec_status = hw.get("executor_status")
        print(f"[restart] poll @ {int(time.time()-t0)}s: hardware_status={status} executor_status={exec_status}",
              file=sys.stderr)
        if exec_status in ("running", "ready", "idle"):
            final_state = hw
            break
        if exec_status in ("error", "failed"):
            final_state = hw
            break
        time.sleep(10)
    return {"stop": stop_resp, "start": start_resp, "final_state": final_state,
            "wait_seconds": int(time.time() - t0)}


# ─── cli ───────────────────────────────────────────────────────────────────

def main(argv: list[str] | None = None) -> int:
    p = argparse.ArgumentParser(description=__doc__,
                                formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("action", choices=["stop", "start", "restart", "state"])
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
    elif args.action == "state":
        out = get_hardware_state(args.project_id)
    else:
        out = restart_machine(args.project_id,
                              settle_seconds=args.settle_seconds,
                              dry_run=args.dry_run)
    print(json.dumps(out, indent=2))
    return 0


if __name__ == "__main__":
    sys.exit(main())
