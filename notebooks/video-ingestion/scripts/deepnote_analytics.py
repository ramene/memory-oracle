#!/usr/bin/env python3
"""
deepnote_analytics.py — programmatic notebook-run + project-log fetcher with
per-run cost rollup.  Closes the "no public billing API" gap by combining the
DevTools-captured GraphQL operations with the L4 GPU rate confirmed from the
Deepnote UI (operator screenshots, 2026-06-18).

GraphQL operations wrapped:
  - GetNotebookRuns  — per-run start/end timestamps + status + author
  - GetProjectLogs   — project-level event log (app_opened, notebook_opened, ...)

Cost model: per-minute rate × wall-clock minutes per run.  L4 = $0.104/min per
Deepnote's machine selection panel (operator-verified 2026-06-18).  Other rates
(CPU Basic/Plus/Performance, T4, etc.) handled by --rate.

Usage:
  deepnote_analytics.py runs <notebookId> [--days N] [--limit N]
  deepnote_analytics.py logs <fileId>     [--days N] [--types ...]
  deepnote_analytics.py cost <notebookId> [--days N] [--rate $/min]
"""

from __future__ import annotations

import argparse
import json
import ssl
import sys
import urllib.error
import urllib.parse
import urllib.request
from datetime import datetime, timezone
from pathlib import Path

import certifi
_SSL_CONTEXT = ssl.create_default_context(cafile=certifi.where())

DEEPNOTE_WEB_BASE = "https://deepnote.com"
COOKIE_FILE = Path.home() / ".claude" / ".credentials" / "deepnote-cookies.json"

# L4 = $0.104/min ($6.24/hr) — operator confirmed from Deepnote UI 2026-06-18.
# Override via --rate for other machine tiers.
DEFAULT_RATE_PER_MIN_USD = 0.104

DEFAULT_PROJECT_ID = "ae2b2f17-fb74-43bf-a749-b5a5b8a163c8"  # native-video


# ─── GraphQL queries (verbatim from DevTools 2026-06-19) ───────────────────

GET_NOTEBOOK_RUNS_QUERY = """query GetNotebookRuns($projectId: String!, $lastNDays: Int, $notebookId: ID, $triggeredBy: String, $offset: Int!, $limit: Int!) {
  projectById(id: $projectId) {
    __typename
    ... on Project {
      id
      notebookRuns(
        lastNDays: $lastNDays
        notebookId: $notebookId
        triggeredBy: $triggeredBy
        offset: $offset
        limit: $limit
      ) {
        runs {
          id
          notebook_id
          user_id
          status
          triggered_by
          created_at
          execution_finished_at
          error
          hasSnapshot
          snapshotStatus
          detached_source_project_id
          author { id name avatar is_anonymous email __typename }
          __typename
        }
        hasMore
        __typename
      }
      __typename
    }
  }
}"""

GET_PROJECT_LOGS_QUERY = """query GetProjectLogs($projectId: String!, $types: [ProjectLogType!]!, $limit: Int, $skipProjectVersions: Boolean!, $lastNDays: Int, $fileId: String) {
  projectById(id: $projectId) {
    __typename
    ... on Project {
      id
      logs(types: $types, limit: $limit, lastNDays: $lastNDays, fileId: $fileId) {
        ...ProjectLogFragment
        __typename
      }
      __typename
    }
  }
  projectVersions(projectId: $projectId) @skip(if: $skipProjectVersions) {
    ...ProjectVersionFragment
    __typename
  }
}

fragment ProjectLogFragment on ProjectLog {
  id user_id file_id type created_at project_id metadata snapshotStatus
  author { id name avatar is_anonymous email __typename }
  __typename
}

fragment ProjectVersionFragment on ProjectVersion {
  id title user_id project_id created_at description
  author { id name avatar __typename }
  __typename
}"""


# ─── HTTP plumbing ─────────────────────────────────────────────────────────

def _load_cookies() -> str:
    if not COOKIE_FILE.exists():
        raise FileNotFoundError(
            f"{COOKIE_FILE} not found. Run extract-deepnote-cookies.mjs first."
        )
    return json.loads(COOKIE_FILE.read_text())["cookie_header"]


def _graphql(operation: str, query: str, variables: dict) -> dict:
    """POST to deepnote.com/graphql with cookie auth.  Returns parsed JSON
    (data field or raises on HTTP/network error)."""
    url = f"{DEEPNOTE_WEB_BASE}/graphql?operation_name={operation}"
    body = json.dumps({"operationName": operation, "variables": variables, "query": query}).encode("utf-8")
    req = urllib.request.Request(url, data=body, method="POST")
    req.add_header("Cookie", _load_cookies())
    req.add_header("Content-Type", "application/json")
    req.add_header("Accept", "application/json")
    req.add_header("Origin", DEEPNOTE_WEB_BASE)
    req.add_header("Referer", f"{DEEPNOTE_WEB_BASE}/")
    try:
        with urllib.request.urlopen(req, timeout=30, context=_SSL_CONTEXT) as resp:
            raw = resp.read().decode("utf-8")
    except urllib.error.HTTPError as e:
        body_excerpt = e.read().decode("utf-8", errors="replace")[:400]
        raise RuntimeError(f"GraphQL {operation} HTTP {e.code}: {body_excerpt}") from e
    parsed = json.loads(raw)
    if parsed.get("errors"):
        raise RuntimeError(f"GraphQL {operation} errors: {parsed['errors']}")
    return parsed.get("data") or {}


# ─── API wrappers ──────────────────────────────────────────────────────────

def list_runs(notebook_id: str, project_id: str = DEFAULT_PROJECT_ID,
              last_n_days: int = 30, offset: int = 0, limit: int = 50,
              triggered_by: str | None = None) -> list[dict]:
    """Return the run dicts for a notebook over the trailing window."""
    data = _graphql(
        "GetNotebookRuns",
        GET_NOTEBOOK_RUNS_QUERY,
        {
            "projectId": project_id,
            "lastNDays": last_n_days,
            "notebookId": notebook_id,
            "triggeredBy": triggered_by,
            "offset": offset,
            "limit": limit,
        },
    )
    proj = data.get("projectById") or {}
    runs_block = proj.get("notebookRuns") or {}
    return runs_block.get("runs") or []


def list_project_logs(file_id: str | None = None,
                      project_id: str = DEFAULT_PROJECT_ID,
                      types: list[str] | None = None,
                      last_n_days: int = 30, limit: int | None = None) -> list[dict]:
    """Return project logs (default types: app_opened, notebook_opened)."""
    types = types or ["app_opened", "notebook_opened"]
    data = _graphql(
        "GetProjectLogs",
        GET_PROJECT_LOGS_QUERY,
        {
            "projectId": project_id,
            "types": types,
            "limit": limit,
            "skipProjectVersions": True,
            "lastNDays": last_n_days,
            "fileId": file_id,
        },
    )
    proj = data.get("projectById") or {}
    return proj.get("logs") or []


# ─── Cost rollup ───────────────────────────────────────────────────────────

def _parse_iso(ts) -> datetime | None:
    """Accept either:
       - ISO-8601 string (from REST endpoints)  — e.g. "2026-06-19T19:33:45Z"
       - Unix-millisecond int (from GraphQL)    — e.g. 1781832764314
    Returns timezone-aware datetime in UTC, or None on failure."""
    if ts is None or ts == "":
        return None
    if isinstance(ts, (int, float)):
        # Unix millis if > 10^12; Unix seconds otherwise.  Deepnote uses millis.
        seconds = ts / 1000.0 if ts > 1e11 else float(ts)
        return datetime.fromtimestamp(seconds, tz=timezone.utc)
    try:
        return datetime.fromisoformat(str(ts).replace("Z", "+00:00"))
    except Exception:
        return None


def cost_for_run(run: dict, rate_per_min_usd: float = DEFAULT_RATE_PER_MIN_USD) -> dict:
    """Return {duration_seconds, cost_usd, status, run_id, created_at}.
    Cost is null when execution_finished_at is missing (run still in-flight)."""
    started = _parse_iso(run.get("created_at"))
    finished = _parse_iso(run.get("execution_finished_at"))
    duration_sec = (finished - started).total_seconds() if (started and finished) else None
    cost_usd = round(duration_sec / 60.0 * rate_per_min_usd, 4) if duration_sec is not None else None
    return {
        "run_id": run.get("id"),
        "status": run.get("status"),
        "triggered_by": run.get("triggered_by"),
        "created_at": run.get("created_at"),
        "execution_finished_at": run.get("execution_finished_at"),
        "duration_sec": round(duration_sec, 1) if duration_sec is not None else None,
        "cost_usd": cost_usd,
    }


def cost_rollup(notebook_id: str, project_id: str = DEFAULT_PROJECT_ID,
                last_n_days: int = 30, rate_per_min_usd: float = DEFAULT_RATE_PER_MIN_USD) -> dict:
    """Per-run cost + aggregate over the trailing window."""
    runs = list_runs(notebook_id, project_id=project_id, last_n_days=last_n_days, limit=200)
    per_run = [cost_for_run(r, rate_per_min_usd=rate_per_min_usd) for r in runs]
    total_seconds = sum((r["duration_sec"] or 0) for r in per_run)
    total_cost = round(sum((r["cost_usd"] or 0) for r in per_run), 4)
    success_runs = [r for r in per_run if r["status"] == "success"]
    return {
        "notebook_id": notebook_id,
        "project_id": project_id,
        "lookback_days": last_n_days,
        "rate_per_min_usd": rate_per_min_usd,
        "run_count": len(per_run),
        "success_count": len(success_runs),
        "total_duration_sec": round(total_seconds, 1),
        "total_duration_min": round(total_seconds / 60.0, 2),
        "total_cost_usd": total_cost,
        "avg_cost_per_run_usd": round(total_cost / len(per_run), 4) if per_run else 0,
        "runs": per_run,
    }


# ─── CLI ───────────────────────────────────────────────────────────────────

def main(argv: list[str] | None = None) -> int:
    p = argparse.ArgumentParser(description=__doc__,
                                formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = p.add_subparsers(dest="action", required=True)

    p_runs = sub.add_parser("runs", help="List notebook runs over lookback window")
    p_runs.add_argument("notebook_id")
    p_runs.add_argument("--project-id", default=DEFAULT_PROJECT_ID)
    p_runs.add_argument("--days", type=int, default=30)
    p_runs.add_argument("--limit", type=int, default=50)

    p_logs = sub.add_parser("logs", help="List project logs")
    p_logs.add_argument("--file-id", default=None)
    p_logs.add_argument("--project-id", default=DEFAULT_PROJECT_ID)
    p_logs.add_argument("--days", type=int, default=30)
    p_logs.add_argument("--types", nargs="+", default=None,
                        help="event types (default: app_opened, notebook_opened)")

    p_cost = sub.add_parser("cost", help="Compute per-run + aggregate cost")
    p_cost.add_argument("notebook_id")
    p_cost.add_argument("--project-id", default=DEFAULT_PROJECT_ID)
    p_cost.add_argument("--days", type=int, default=30)
    p_cost.add_argument("--rate", type=float, default=DEFAULT_RATE_PER_MIN_USD,
                        help=f"$/min (default {DEFAULT_RATE_PER_MIN_USD} for L4)")

    args = p.parse_args(argv)

    if args.action == "runs":
        out = list_runs(args.notebook_id, project_id=args.project_id,
                        last_n_days=args.days, limit=args.limit)
    elif args.action == "logs":
        out = list_project_logs(file_id=args.file_id, project_id=args.project_id,
                                types=args.types, last_n_days=args.days)
    elif args.action == "cost":
        out = cost_rollup(args.notebook_id, project_id=args.project_id,
                          last_n_days=args.days, rate_per_min_usd=args.rate)
    else:
        return 2

    print(json.dumps(out, indent=2, default=str))
    return 0


if __name__ == "__main__":
    sys.exit(main())
