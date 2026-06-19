#!/usr/bin/env python3
"""
Import a .deepnote file into a Deepnote project via the web API.

Why this exists:
  The PUBLIC Deepnote API (api.deepnote.com) is a Runs-only surface — it can
  execute existing notebooks but cannot create or import them. The WEB API
  (deepnote.com/api/*) DOES have an import endpoint, but it's cookie-auth-only.

The endpoint was discovered via DevTools Network capture on 2026-06-18:
  POST https://deepnote.com/api/project/<projectId>/import-deepnote
  Content-Type: multipart/form-data
  Body field "file": raw .deepnote bytes (Content-Type: application/octet-stream)
  Response 200: {"notebookId":"<new-uuid>",
                 "notebookName":"<dir/name>",
                 "action":"created",
                 "importedNotebookCount":1}

Auth:
  Cookies extracted from operator's logged-in Chrome via
  ~/.remote/@util.sh/scripts/extract-deepnote-cookies.mjs

After-import resolver:
  Once the upload succeeds, the new notebook ID is in the response. But we ALSO
  expose a `resolve_notebook_id(project_name, notebook_name_substring)` that
  uses the PUBLIC API (GET /v2/projects, Bearer token) — handy when you need
  the live ID without re-importing.

Usage:
  python3 deepnote_import.py \\
    --project-id ae2b2f17-fb74-43bf-a749-b5a5b8a163c8 \\
    --file ~/Downloads/video-ingestion-qwen25vl-v2.deepnote

  # Or look up project ID by name first:
  python3 deepnote_import.py --resolve "native-video"

  # Just look up the current notebook ID (no import):
  python3 deepnote_import.py --resolve-notebook native-video video-ingestion-qwen25vl-v2
"""

from __future__ import annotations

import argparse
import json
import ssl
import sys
import urllib.error
import urllib.parse
import urllib.request
import uuid
from pathlib import Path

# python.org installer Python ships without a CA bundle on macOS; the urllib
# default context fails SSL verify.  Use certifi's bundle (available via pip
# `certifi` package — bundled with `requests` etc., always present here).
import certifi
_SSL_CONTEXT = ssl.create_default_context(cafile=certifi.where())

DEEPNOTE_WEB_BASE = "https://deepnote.com"
DEEPNOTE_PUBLIC_API_BASE = "https://api.deepnote.com"
CREDS_DIR = Path.home() / ".claude" / ".credentials"
COOKIE_FILE = CREDS_DIR / "deepnote-cookies.json"
BEARER_FILE = CREDS_DIR / "deepnote-api-key.txt"


# ─── credentials ────────────────────────────────────────────────────────────

def load_cookies() -> str:
    """Return the cookie header string, or raise."""
    if not COOKIE_FILE.exists():
        raise FileNotFoundError(
            f"{COOKIE_FILE} not found. Run "
            f"`node ~/.remote/@util.sh/scripts/extract-deepnote-cookies.mjs` first."
        )
    with COOKIE_FILE.open() as f:
        data = json.load(f)
    header = data.get("cookie_header", "").strip()
    if not header:
        raise ValueError(f"{COOKIE_FILE} has no cookie_header.")
    return header


def load_bearer() -> str:
    """Return the public-API bearer token, or raise."""
    if not BEARER_FILE.exists():
        raise FileNotFoundError(f"{BEARER_FILE} not found.")
    return BEARER_FILE.read_text().strip()


# ─── multipart encoder (no `requests` dep) ──────────────────────────────────

def build_multipart(file_path: Path) -> tuple[bytes, str]:
    """Encode a single-file multipart/form-data body.

    Returns (body_bytes, boundary).  Field name is "file" (matches the captured
    DevTools payload exactly).
    """
    boundary = f"----DeepnoteImporter{uuid.uuid4().hex}"
    filename = file_path.name
    file_bytes = file_path.read_bytes()

    crlf = b"\r\n"
    parts = [
        f"--{boundary}".encode("utf-8"),
        f'Content-Disposition: form-data; name="file"; filename="{filename}"'.encode("utf-8"),
        b"Content-Type: application/octet-stream",
        b"",
        file_bytes,
        f"--{boundary}--".encode("utf-8"),
        b"",
    ]
    body = crlf.join(parts)
    return body, boundary


# ─── web-api: import .deepnote ──────────────────────────────────────────────

def import_deepnote(project_id: str, file_path: Path, cookie_header: str) -> dict:
    """POST the .deepnote file. Returns the parsed JSON response."""
    url = f"{DEEPNOTE_WEB_BASE}/api/project/{project_id}/import-deepnote"
    body, boundary = build_multipart(file_path)

    req = urllib.request.Request(url, data=body, method="POST")
    req.add_header("Cookie", cookie_header)
    req.add_header("Content-Type", f"multipart/form-data; boundary={boundary}")
    req.add_header("Accept", "*/*")
    req.add_header("Accept-Language", "en-US,en;q=0.9")
    # Origin + Referer matter for some session-cookie backends (CSRF defense
    # via Sec-Fetch-Site=same-origin). Mirror what the browser sends.
    req.add_header("Origin", DEEPNOTE_WEB_BASE)
    req.add_header("Referer", f"{DEEPNOTE_WEB_BASE}/workspace/")

    print(f"[import] POST {url}", file=sys.stderr)
    print(f"[import] file={file_path.name}  size={len(body)} bytes (incl. boundary)",
          file=sys.stderr)

    try:
        with urllib.request.urlopen(req, timeout=60, context=_SSL_CONTEXT) as resp:
            raw = resp.read().decode("utf-8")
            return json.loads(raw)
    except urllib.error.HTTPError as e:
        body_excerpt = e.read().decode("utf-8", errors="replace")[:500]
        raise RuntimeError(
            f"import failed: HTTP {e.code} — {body_excerpt}"
        ) from e


# ─── public api: project / notebook discovery ──────────────────────────────

def list_projects(bearer: str) -> list[dict]:
    """GET /v2/projects — returns the list of projects (with nested notebooks)."""
    req = urllib.request.Request(
        f"{DEEPNOTE_PUBLIC_API_BASE}/v2/projects",
        headers={"Authorization": f"Bearer {bearer}", "Accept": "application/json"},
        method="GET",
    )
    with urllib.request.urlopen(req, timeout=20, context=_SSL_CONTEXT) as resp:
        return json.loads(resp.read().decode("utf-8")).get("projects", [])


def resolve_project_id(project_name: str, bearer: str) -> str:
    """Find the project UUID whose .name equals `project_name`. Case-insensitive."""
    needle = project_name.strip().lower()
    for p in list_projects(bearer):
        if (p.get("name") or "").strip().lower() == needle:
            return p["id"]
    raise LookupError(f"No project found with name {project_name!r}")


def resolve_notebook_id(project_name: str, notebook_name_substring: str,
                        bearer: str) -> str:
    """Find the current live notebook ID inside `project_name` whose .name
    contains `notebook_name_substring`. Case-insensitive substring match.

    When multiple notebooks match (common after re-imports where Deepnote
    auto-appends `-2`, `-3`, ... to disambiguate), returns the MOST RECENTLY
    CREATED one (sorted by `createdAt` DESC) — that's what callers almost
    always want after running the import."""
    needle_p = project_name.strip().lower()
    needle_nb = notebook_name_substring.strip().lower()
    for p in list_projects(bearer):
        if (p.get("name") or "").strip().lower() != needle_p:
            continue
        matches = [
            nb for nb in (p.get("notebooks") or [])
            if needle_nb in (nb.get("name") or "").lower()
        ]
        if not matches:
            raise LookupError(
                f"Project {project_name!r} found but no notebook matched substring "
                f"{notebook_name_substring!r}.  Notebooks present: "
                f"{[nb.get('name') for nb in p.get('notebooks') or []]}"
            )
        # ISO-8601 strings sort lexicographically; newest createdAt comes last.
        matches.sort(key=lambda nb: nb.get("createdAt") or "")
        return matches[-1]["id"]
    raise LookupError(f"No project found with name {project_name!r}")


# ─── cli ───────────────────────────────────────────────────────────────────

def main(argv: list[str] | None = None) -> int:
    p = argparse.ArgumentParser(
        description=__doc__,
        formatter_class=argparse.RawDescriptionHelpFormatter,
    )
    p.add_argument("--project-id", help="Deepnote project UUID (with dashes)")
    p.add_argument("--file", type=Path,
                   help="Path to the .deepnote file to import")
    p.add_argument("--resolve", metavar="PROJECT_NAME",
                   help="Look up project UUID by name (public API, Bearer token). "
                        "No import is performed.")
    p.add_argument("--resolve-notebook", nargs=2,
                   metavar=("PROJECT_NAME", "NOTEBOOK_SUBSTRING"),
                   help="Look up the live notebook ID inside a project by name. "
                        "Public API, Bearer token.  No import is performed.")
    args = p.parse_args(argv)

    # Mode 1: resolve project ID by name
    if args.resolve:
        bearer = load_bearer()
        pid = resolve_project_id(args.resolve, bearer)
        print(pid)
        return 0

    # Mode 2: resolve notebook ID by name within a project
    if args.resolve_notebook:
        bearer = load_bearer()
        proj, nb = args.resolve_notebook
        nbid = resolve_notebook_id(proj, nb, bearer)
        print(nbid)
        return 0

    # Mode 3: import
    if not args.project_id or not args.file:
        p.print_help()
        return 2
    if not args.file.exists():
        sys.exit(f"FATAL: file not found: {args.file}")

    cookie_header = load_cookies()
    resp = import_deepnote(args.project_id, args.file, cookie_header)
    print(json.dumps(resp, indent=2))
    return 0


if __name__ == "__main__":
    sys.exit(main())
