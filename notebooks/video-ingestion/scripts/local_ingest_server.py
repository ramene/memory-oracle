#!/usr/bin/env python
"""local_ingest_server.py — the tunafish $0/local inference endpoint for noodles
(GTM WS11 + platform-cutover WS4). ONE HTTP seam over localhost+LAN that serves
three request-classes — video (VLM), text, image — behind a single-GPU
residency MODEL-MANAGER (model_manager.py) that load-on-demands + LRU-evicts so
the 36GB box never over-commits.

Security: binds localhost + LAN (0.0.0.0), shared-secret bearer token. NOT for
the public internet — tunafish is behind the LAN. Rotate by restarting with a
new MAE_LOCAL_INGEST_TOKEN.

CONTRACT
========
  GET  /health                 -> {ok, host, manager:{budget_gb,resident,resident_gb}}
  POST /ingest  (VLM / video)  -> output.json dict (cloud-backend schema)
     { "mp4_path": "...", "profile": "concept-talk", "quality": false,
       "chunk_duration_sec": 384, "video_fps": 2.0, "max_frames": 768,
       "max_new_tokens": 2048, "override_prompt": null, "out_path": "..." }
  POST /text    (LLM)          -> {text, prompt_tokens, generation_tokens, ...tps, model}
     { "prompt": "...", "system": null, "max_tokens": 900 }
  POST /image   (FLUX)         -> {png, height, width, steps, seconds, [image_base64]}
     { "prompt": "...", "height": 1024, "width": 1024, "steps": 4, "seed": 42,
       "out_path": "/abs/on/tunafish.png", "return_base64": false }

Auth: Authorization: Bearer <TOKEN>  |  X-Ingest-Token: <TOKEN>  |  ?token=<TOKEN>

Residency (measured peaks): vlm-7b 7.7 | vlm-32b 23 | text-32b 18.9 | flux 19.6
(1024) / 34 (1080x1920). Budget 28GB. vlm-7b is PINNED by default (the video
default path) and co-resides with ONE ~19GB peer; a 1080x1920 image job is
'exclusive' and transiently evicts everything (incl the pin).
"""
from __future__ import annotations

import base64
import hashlib
import json
import os
import socket
import sys
import threading
import traceback
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import urlparse, parse_qs

sys.path.insert(0, str(Path(__file__).resolve().parent))
import local_ingest as li
from model_manager import ModelManager, ImageModel

# option-B: standalone Qwen tokenizer cache for POST /count (CPU-only, no GPU/weights).
_COUNT_TOK_CACHE = {}

TOKEN_FILE = Path.home() / ".local" / "state" / "mae-local-vlm" / "server-token.txt"
DEFAULT_IMG_DIR = Path.home() / ".local" / "state" / "mae-local-vlm" / "images"
SUBSTRATE_HUB = os.environ.get("SUBSTRATE_HUB", "http://192.168.100.50:8787")  # Pi coordinator; BM25 over the whole cluster brain

MGR: ModelManager = None  # set in main()


def _substrate_search(query: str, k: int = 6, project: str = None, timeout: int = 6) -> list:
    """Retrieve from the LIVE substrate hub (BM25 over the whole cluster brain).
    Pure HTTP, no model dependency; returns [] on any hub failure (graceful-degrade)."""
    import urllib.request as _u, urllib.parse as _p
    qs = _p.urlencode({"q": query, "k": k, **({"project": project} if project else {})})
    try:
        r = json.loads(_u.urlopen(f"{SUBSTRATE_HUB}/search?{qs}", timeout=timeout).read())
    except Exception as e:
        li.log(f"/ask substrate hub unreachable: {e!r}", 1); return []
    return [{"name": h.get("Name"), "project": h.get("Project"), "file": h.get("File"),
             "body": h.get("MergedBody") or "", "rank": h.get("Rank", 0.0)}
            for h in (r.get("results") or [])]


def _lan_ip() -> str:
    try:
        s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        s.connect(("8.8.8.8", 80)); ip = s.getsockname()[0]; s.close()
        return ip
    except Exception:
        return "127.0.0.1"


class Handler(BaseHTTPRequestHandler):
    server_version = "mae-local-endpoint/2.0"
    TOKEN = ""

    def _send(self, code: int, obj: dict):
        body = json.dumps(obj).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def _authed(self) -> bool:
        if not self.TOKEN:
            return True
        h = self.headers.get("Authorization", "")
        if h.startswith("Bearer ") and h[7:].strip() == self.TOKEN:
            return True
        if self.headers.get("X-Ingest-Token", "").strip() == self.TOKEN:
            return True
        return parse_qs(urlparse(self.path).query).get("token", [""])[0] == self.TOKEN

    def _body(self) -> dict:
        n = int(self.headers.get("Content-Length", 0))
        return json.loads(self.rfile.read(n) or b"{}")

    def log_message(self, fmt, *args):
        li.log(f"http {self.address_string()} {fmt % args}", 1)

    # ── routes ──
    ROUTES = ["GET /health", "POST /ingest", "POST /text", "POST /image", "POST /teardown", "POST /ask", "POST /evict", "POST /count"]

    def do_GET(self):
        if urlparse(self.path).path == "/health":
            self._send(200, {"ok": True, "host": socket.gethostname(),
                             "backend": "local-mlx", "routes": self.ROUTES,
                             "manager": MGR.status()})
        else:
            self._send(404, {"error": "GET /health | POST /ingest,/text,/image,/teardown,/ask,/evict"})

    def do_POST(self):
        path = urlparse(self.path).path
        if path not in ("/ingest", "/text", "/image", "/teardown", "/ask", "/evict", "/count"):
            return self._send(404, {"error": "POST /ingest | /text | /image | /teardown | /ask | /evict"})
        if not self._authed():
            return self._send(401, {"error": "unauthorized — Bearer token / X-Ingest-Token / ?token="})
        try:
            req = self._body()
        except Exception as e:
            return self._send(400, {"error": f"bad JSON body: {e!r}"})
        try:
            if path == "/ingest":
                return self._handle_ingest(req)
            if path == "/text":
                return self._handle_text(req)
            if path == "/image":
                return self._handle_image(req)
            if path == "/teardown":
                return self._handle_teardown(req)
            if path == "/ask":
                return self._handle_ask(req)
            if path == "/count":
                return self._handle_count(req)
            if path == "/evict":
                return self._send(200, {"evicted": MGR.evict_all(), "manager": MGR.status()})
        except KeyError as e:
            return self._send(400, {"error": str(e)})
        except FileNotFoundError as e:
            return self._send(404, {"error": str(e)})
        except Exception as e:
            traceback.print_exc()
            return self._send(500, {"error": repr(e)})

    def _handle_ingest(self, req):
        mp4 = req.get("mp4_path")
        if not mp4:
            return self._send(400, {"error": "mp4_path is required (path local to tunafish)"})
        if not Path(mp4).expanduser().exists():
            return self._send(404, {"error": f"mp4_path not found on tunafish: {mp4}"})
        quality = bool(req.get("quality", False))
        key = "vlm-32b" if quality else "vlm-7b"
        with MGR.gpu_job():                            # serialize + residency + box-wide flock (WHOLE job)
            vlm = MGR.acquire(key)
            result = vlm.ingest(
                mp4_path=mp4,
                profile=req.get("profile", "general-summary"),
                chunk_duration_sec=int(req.get("chunk_duration_sec", li.TRUE_2FPS_CHUNK_CAP_SEC)),
                video_fps=float(req.get("video_fps", li.DEFAULT_FPS)),
                max_frames=int(req.get("max_frames", li.DEFAULT_MAX_FRAMES)),
                max_new_tokens=int(req.get("max_new_tokens", li.DEFAULT_MAX_NEW_TOKENS)),
                override_prompt=req.get("override_prompt"),
            )
        op = req.get("out_path")
        if op:
            p = Path(op).expanduser(); p.parent.mkdir(parents=True, exist_ok=True)
            p.write_text(json.dumps(result, indent=2)); result["_written_to"] = str(p)
        self._send(200, result)

    def _handle_teardown(self, req):
        """Forensic teardown of ONE segment via the local VLM ($0 replacement for
        the Gemini watcher). The caller supplies the VERBATIM 13-section prompt
        (sourced from watch-video-teardown.mjs) so output structure stays byte-
        parity. Chunking/stitch is the caller's job (watch-video-chunked.sh)."""
        import time as _t
        mp4 = req.get("mp4_path")
        prompt = req.get("prompt")
        if not mp4:
            return self._send(400, {"error": "mp4_path is required (path local to tunafish)"})
        if not Path(mp4).expanduser().exists():
            return self._send(404, {"error": f"mp4_path not found on tunafish: {mp4}"})
        if not prompt:
            return self._send(400, {"error": "prompt is required (the VERBATIM teardown prompt "
                                             "from watch-video-teardown.mjs — keeps 13-section parity)"})
        key = "vlm-32b" if bool(req.get("quality", False)) else "vlm-7b"
        t0 = _t.time()
        with MGR.gpu_job():                            # box-wide flock for the WHOLE teardown job
            vlm = MGR.acquire(key)
            out = vlm.teardown(str(Path(mp4).expanduser()), prompt,
                               max_new_tokens=int(req.get("max_new_tokens", 6000)))
        out["seconds"] = round(_t.time() - t0, 1)
        op = req.get("out_path")
        if op:
            p = Path(op).expanduser(); p.parent.mkdir(parents=True, exist_ok=True)
            p.write_text(out["markdown"]); out["_written_to"] = str(p)
        self._send(200, out)

    def _handle_text(self, req):
        prompt = req.get("prompt")
        if not prompt:
            return self._send(400, {"error": "prompt is required"})
        with MGR.gpu_job():                            # box-wide flock for the WHOLE text job
            tm = MGR.acquire("text-32b")
            out = tm.generate(prompt, max_tokens=int(req.get("max_tokens", 900)),
                              system=req.get("system"))
        out["model"] = tm.model_id
        self._send(200, out)

    def _handle_count(self, req):
        """Real Qwen tokenizer count for a text blob. CPU-only: loads JUST the
        tokenizer (no GPU, no 18.9GB weights, no MGR.acquire) so it never blocks a
        running ingestion. Lets the digest builder size chunks by the TRUE token
        count instead of a bytes/N guess (was over-counting 2.8x)."""
        text = req.get("text")
        if text is None:
            return self._send(400, {"error": "text is required"})
        tok = _COUNT_TOK_CACHE.get("tok")
        if tok is None:
            from transformers import AutoTokenizer
            tok = AutoTokenizer.from_pretrained("mlx-community/Qwen2.5-32B-Instruct-4bit")
            _COUNT_TOK_CACHE["tok"] = tok
        n = len(tok.encode(text))
        return self._send(200, {"tokens": n, "chars": len(text),
                                "model": "mlx-community/Qwen2.5-32B-Instruct-4bit"})

    def _handle_ask(self, req):
        """RAG over the LIVE substrate — the fleet capability: retrieve from the
        whole brain (all sessions/machines, always-current) -> ground the resident
        SLM -> cited [n] answer. Any session on any box: POST /ask {query}."""
        query = req.get("query") or req.get("prompt")
        if not query:
            return self._send(400, {"error": "query is required"})
        k = int(req.get("k", 6))
        hits = _substrate_search(query, k, project=req.get("project"))
        if not hits:  # corrective broaden: retry on the salient terms
            import re as _re
            broad = " ".join(_re.findall(r"[A-Za-z0-9][A-Za-z0-9\-]{2,}", query)[:4])
            if broad and broad != query:
                hits = _substrate_search(broad, k)
        if not hits:
            return self._send(200, {"answer": "(no grounded context in the substrate for this query)",
                                    "sources": [], "grounded": False})
        if req.get("retrieve_only"):
            return self._send(200, {"grounded": True, "sources": [
                {"n": i+1, "source": h["name"], "project": h["project"], "file": h["file"],
                 "excerpt": h["body"][:600]} for i, h in enumerate(hits)]})
        sources = "\n\n".join(f"[{i+1}] {h['name']} ({h['project']}/{h['file']})\n{h['body'][:1400]}"
                              for i, h in enumerate(hits))
        system = ("You answer ONLY from the provided substrate SOURCES (our own fleet memory). "
                  "Cite sources inline as [n]. If the sources don't cover it, say so — never invent.")
        with MGR.gpu_job():                            # box-wide flock for the WHOLE ask job
            tm = MGR.acquire("text-32b")
            out = tm.generate(f"SOURCES:\n{sources}\n\nQUESTION: {query}\n\nGrounded answer with [n] citations:",
                              max_tokens=int(req.get("max_tokens", 900)), system=system)
        self._send(200, {"answer": out.get("text", out), "grounded": True, "model": tm.model_id,
                         "sources": [{"n": i+1, "source": h["name"], "project": h["project"],
                                      "file": h["file"]} for i, h in enumerate(hits)]})

    # Operator policy (2026-08-27): local /image serves FLUX.1-schnell-4bit at
    # 1024-class ONLY. 1080x1920 peaks 34GB (unsafe on 36GB) — native 9:16 batch
    # is a Vertex Imagen fallback in the GTM app seam; the 9:16 upscale+crop is
    # app-side. So the route NEVER runs an 'exclusive' job and residency stays
    # pin(VLM-7B) + one swappable slot.
    IMG_MAX_DIM = 1024

    def _handle_image(self, req):
        prompt = req.get("prompt")
        if not prompt:
            return self._send(400, {"error": "prompt is required"})
        h = int(req.get("height", 1024)); w = int(req.get("width", 1024))
        steps = int(req.get("steps", 4)); seed = int(req.get("seed", 42))
        if h > self.IMG_MAX_DIM or w > self.IMG_MAX_DIM:
            return self._send(400, {
                "error": f"local /image is {self.IMG_MAX_DIM}-class only "
                         f"(requested {w}x{h}). 1080x1920 peaks ~34GB — unsafe on 36GB. "
                         f"Use Vertex Imagen (GTM app seam) for native 9:16; do the "
                         f"9:16 upscale+crop app-side.",
                "policy": "local-image-1024-only", "max_dim": self.IMG_MAX_DIM})
        # Cache key MUST include the PROMPT (+ steps, size, seed). Keying on
        # {size, seed} alone made 3 distinct prompts collide on one stale file
        # (img_1024x1024_42.png) — the GTM parity bug. Prompt-hash fixes it.
        key = hashlib.sha1(
            f"{prompt}\x00{steps}\x00{w}x{h}\x00{seed}".encode()).hexdigest()[:12]
        out_path = req.get("out_path") or str(
            DEFAULT_IMG_DIR / f"img_{w}x{h}_s{steps}_seed{seed}_{key}.png")
        # Idempotent cache: distinct prompts -> distinct keys -> distinct files.
        # A hit skips the model entirely (no needless FLUX swap). `force` overrides.
        p = Path(out_path)
        if not req.get("force") and p.exists() and p.stat().st_size > 0:
            out = {"png": out_path, "width": w, "height": h, "steps": steps,
                   "seed": seed, "cache_key": key, "cached": True}
            if req.get("return_base64"):
                out["image_base64"] = base64.b64encode(p.read_bytes()).decode()
            return self._send(200, out)
        with MGR.gpu:
            im = MGR.acquire("flux-schnell", need_gb=ImageModel.EST_GB, exclusive=False)
            out = im.generate(prompt, height=h, width=w, steps=steps, seed=seed,
                              out_path=out_path)
        out["cache_key"] = key; out["cached"] = False
        if req.get("return_base64"):
            out["image_base64"] = base64.b64encode(Path(out["png"]).read_bytes()).decode()
        self._send(200, out)


def _idle_evictor(mgr: ModelManager, interval_s: float, max_idle_s: float):
    stop = threading.Event()
    def loop():
        while not stop.wait(interval_s):
            try:
                mgr.idle_evict(max_idle_s)
            except Exception as e:
                li.log(f"idle-evict warned: {e!r}", 1)
    t = threading.Thread(target=loop, daemon=True); t.start()
    return stop


def main():
    global MGR
    import argparse
    ap = argparse.ArgumentParser(description="tunafish local MLX inference endpoint (VLM/text/image) with residency manager")
    ap.add_argument("--host", default="0.0.0.0")
    ap.add_argument("--port", type=int, default=8823)
    ap.add_argument("--token", default=os.environ.get("MAE_LOCAL_INGEST_TOKEN", ""))
    ap.add_argument("--budget-gb", type=float, default=float(os.environ.get("MAE_GPU_BUDGET_GB", "28")))
    ap.add_argument("--no-pin-vlm7b", dest="pin_vlm7b", action="store_false", default=True,
                    help="don't keep VLM-7B pinned resident")
    ap.add_argument("--preload", choices=["none", "vlm-7b", "vlm-32b", "text-32b", "flux-schnell"],
                    default="vlm-7b")
    ap.add_argument("--idle-evict-s", type=float, default=900,
                    help="evict swappable models idle longer than this (0=off)")
    args = ap.parse_args()

    MGR = ModelManager(budget_gb=args.budget_gb, pin_vlm7b=args.pin_vlm7b)

    token = args.token or os.urandom(16).hex()
    Handler.TOKEN = token
    TOKEN_FILE.parent.mkdir(parents=True, exist_ok=True)
    TOKEN_FILE.write_text(token + "\n"); TOKEN_FILE.chmod(0o600)
    DEFAULT_IMG_DIR.mkdir(parents=True, exist_ok=True)

    if args.preload != "none":
        li.log(f"preloading {args.preload} ...")
        with MGR.gpu:
            MGR.acquire(args.preload)

    if args.idle_evict_s > 0:
        _idle_evictor(MGR, interval_s=min(300, args.idle_evict_s), max_idle_s=args.idle_evict_s)

    lan = _lan_ip()
    httpd = ThreadingHTTPServer((args.host, args.port), Handler)
    li.log("=" * 68)
    li.log(f"mae-local-endpoint UP  host={socket.gethostname()}  budget={args.budget_gb}GB")
    li.log(f"  local: http://127.0.0.1:{args.port}   LAN: http://{lan}:{args.port}")
    li.log(f"  routes: GET /health | POST /ingest (video) | POST /text | POST /image | POST /teardown | POST /ask (RAG over live substrate)")
    li.log(f"  token: {token}  (also {TOKEN_FILE})")
    li.log("=" * 68)
    try:
        httpd.serve_forever()
    except KeyboardInterrupt:
        li.log("shutting down"); httpd.shutdown()


if __name__ == "__main__":
    main()
