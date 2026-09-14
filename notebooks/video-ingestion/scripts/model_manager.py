#!/usr/bin/env python
"""model_manager.py — single-GPU residency manager for the tunafish $0/local stack.

WHY: 36GB unified memory canNOT co-resident the large local models (measured,
arch-note ws5 + the text/image bench): TEXT-32B(18.9) + FLUX(19.6) = 38.6GB > box;
FLUX @1080x1920 alone peaks 34GB; any trio >45GB. So residency is a SCHEDULING
problem, not a quantization one. This manager keeps a safe GPU budget, loads
on demand per request-class {vlm|text|image}, and EVICTS (del + mx.clear_cache)
the LRU large model before loading the next. A small model (VLM-7B, 7.7GB, the
default video path) may be PINNED and stay co-resident with one ~19GB peer — but
the manager evicts EVERYTHING (incl pinned) for an exclusive job (FLUX @1080x1920).

Single GPU -> all inference is serialized on one lock; only one model computes at
a time regardless of residency.

Standalone peaks (GB) that drive the budget math:
    vlm-7b 7.7 | vlm-32b 23 | text-32b 18.9 | flux-1024 19.6 | flux-1080x1920 34
Safe GPU budget default 28GB (36 - ~8 for OS/other). Tune via MAE_GPU_BUDGET_GB.
"""
from __future__ import annotations

import fcntl
import os
import threading
import time
from contextlib import contextmanager
from datetime import datetime, timezone
from pathlib import Path
from typing import Callable, Optional

SAFE_BUDGET_GB = float(os.environ.get("MAE_GPU_BUDGET_GB", "28"))

# ── SINGLE-MODEL LAW (operator/lead, 2026-09-03, post-crash) ──────────────────
# Co-modeling crashed tunafish (load 72 -> watchdog panic): the :8823 pin+peer
# co-residency AND, worse, :8823 + LM Studio (:1234) each holding a model with no
# shared throttle. ENFORCEMENT: exactly ONE local model resident on the box at a
# time, across BOTH tiers. When on (default): no pinned co-residency, every load
# is exclusive (evict all other :8823 models), and each load first DRAINS the
# LM Studio tier (`lms unload --all`). A box-wide flock makes a CLI-driven :1234
# load and the daemon's load mutually exclusive (see ~/.bin/gpu-guard.sh).
SINGLE_MODEL = os.environ.get("MAE_SINGLE_MODEL", "1") == "1"
GPU_LOCKFILE = Path.home() / ".local" / "state" / "substrate" / "gpu.lock"   # ONE fleet-wide GPU primitive (shared w/ substrate app-up/retrain governor + gpu-guard)


def log(msg: str, indent: int = 0) -> None:
    ts = datetime.now(timezone.utc).strftime("%H:%M:%S")
    print(f"[{ts}] {'  ' * indent}[mgr] {msg}", flush=True)


def _clear_gpu():
    try:
        import mlx.core as mx
        mx.clear_cache()
    except Exception:
        pass


# ── model wrappers ────────────────────────────────────────────────────────────
class TextModel:
    """Qwen2.5-32B-Instruct-4bit via mlx-lm."""
    KEY = "text-32b"
    EST_GB = 19.0
    def __init__(self, model_id="mlx-community/Qwen2.5-32B-Instruct-4bit"):
        self.model_id = model_id
        self.model = self.tok = None

    def load(self):
        from mlx_lm import load
        t0 = time.time()
        self.model, self.tok = load(self.model_id)
        return time.time() - t0

    def unload(self):
        self.model = self.tok = None
        _clear_gpu()

    def generate(self, prompt: str, max_tokens: int = 900, system: Optional[str] = None) -> dict:
        from mlx_lm import stream_generate
        msgs = ([{"role": "system", "content": system}] if system else []) + \
               [{"role": "user", "content": prompt}]
        p = self.tok.apply_chat_template(msgs, add_generation_prompt=True)
        text, last = "", None
        for r in stream_generate(self.model, self.tok, p, max_tokens=max_tokens):
            text += r.text
            last = r
        return {"text": text,
                "prompt_tokens": getattr(last, "prompt_tokens", None),
                "prompt_tps": round(getattr(last, "prompt_tps", 0), 1),
                "generation_tokens": getattr(last, "generation_tokens", None),
                "generation_tps": round(getattr(last, "generation_tps", 0), 1)}


class ImageModel:
    """FLUX.1-schnell 4bit via mflux (ungated mirror)."""
    KEY = "flux-schnell"
    EST_GB = 20.0                 # ~19.6 at 1024; larger res is handled 'exclusive'
    EXCLUSIVE_PIXELS = 1024 * 1024 * 2   # above this, needs the whole box
    def __init__(self, repo="dhairyashil/FLUX.1-schnell-mflux-4bit", base="schnell"):
        self.repo, self.base = repo, base
        self.flux = None

    def load(self):
        from mflux.models.flux.variants.txt2img.flux import Flux1
        from mflux.models.common.config.model_config import ModelConfig
        t0 = time.time()
        mc = ModelConfig.from_name(self.repo, base_model=self.base)
        self.flux = Flux1(model_config=mc)
        return time.time() - t0

    def unload(self):
        self.flux = None
        _clear_gpu()

    @staticmethod
    def _round16(n: int) -> int:
        return max(16, (int(n) // 16) * 16)

    def est_gb_for(self, h: int, w: int) -> float:
        return 34.0 if h * w >= self.EXCLUSIVE_PIXELS else self.EST_GB

    def generate(self, prompt: str, height=1024, width=1024, steps=4, seed=42,
                 out_path: Optional[str] = None) -> dict:
        h, w = self._round16(height), self._round16(width)
        t0 = time.time()
        img = self.flux.generate_image(seed=seed, prompt=prompt,
                                       num_inference_steps=steps, height=h, width=w)
        dt = time.time() - t0
        if out_path:
            Path(out_path).parent.mkdir(parents=True, exist_ok=True)
            img.save(path=out_path)
        return {"height": h, "width": w, "steps": steps, "seconds": round(dt, 1),
                "png": out_path}


class VLMModel:
    """Qwen2.5-VL (7B or 32B) via local_ingest.LocalVLM. Reused for video ingest."""
    def __init__(self, quality: bool):
        self.quality = quality
        self.KEY = "vlm-32b" if quality else "vlm-7b"
        self.EST_GB = 23.0 if quality else 8.0
        self._vlm = None

    def load(self):
        import importlib.util as ilu
        p = Path(__file__).parent / "local_ingest.py"
        spec = ilu.spec_from_file_location("local_ingest", p)
        self._li = ilu.module_from_spec(spec)
        spec.loader.exec_module(self._li)
        t0 = time.time()
        self._vlm = self._li.LocalVLM(quality=self.quality)
        self._vlm.load()
        return time.time() - t0

    def unload(self):
        self._vlm = None
        _clear_gpu()

    def ingest(self, **kw) -> dict:
        return self._li.run_local_ingest(_vlm=self._vlm, **kw)

    def teardown(self, mp4_path: str, prompt_body: str, max_new_tokens: int = 6000) -> dict:
        """Forensic teardown of ONE segment: whisper audio + VERBATIM prose prompt
        through the VLM -> raw 13-section markdown. Chunking/stitch is the caller's
        job (watch-video-chunked.sh); this is one true-2fps pass per <=384s segment."""
        from pathlib import Path
        p = Path(mp4_path)
        transcript = self._vlm.transcribe(p)
        res = self._vlm.generate_markdown(p, prompt_body, transcript, max_new_tokens=max_new_tokens)
        return {"markdown": res["markdown"], "transcript_chars": len(transcript),
                "peak_gpu_gb": res["peak_gpu_gb"], "model": self._vlm.model_id}


# ── the manager ───────────────────────────────────────────────────────────────
class _Resident:
    __slots__ = ("handle", "est_gb", "pinned", "last_used", "load_s")
    def __init__(self, handle, est_gb, pinned, load_s):
        self.handle, self.est_gb, self.pinned = handle, est_gb, pinned
        self.load_s, self.last_used = load_s, time.time()


class ModelManager:
    """Single large-slot, LRU-evicting, budget-bounded. One GPU -> one lock."""
    # factory per key; VLM keys carry the quality flag
    FACTORY: dict[str, Callable[[], object]] = {
        "vlm-7b":  lambda: VLMModel(False),
        "vlm-32b": lambda: VLMModel(True),
        "text-32b": lambda: TextModel(),
        "flux-schnell": lambda: ImageModel(),
    }
    PINNABLE = {"vlm-7b"}   # small enough to co-reside with one ~19GB peer

    def __init__(self, budget_gb: float = SAFE_BUDGET_GB, pin_vlm7b: bool = True):
        self.budget = budget_gb
        # SINGLE-MODEL LAW: no pinned co-residency when single-model is enforced.
        self.pin_vlm7b = pin_vlm7b and not SINGLE_MODEL
        self.gpu = threading.RLock()          # serialize ALL inference on the one GPU
        self._job_depth = 0                    # reentrancy counter for gpu_job() flock (guarded by self.gpu)
        self._job_lock_fd = None               # the box-wide flock fd, held for a whole GPU job
        self._resident: dict[str, _Resident] = {}
        if SINGLE_MODEL:
            log("SINGLE-MODEL LAW active: 1 model box-wide; loads are exclusive + drain LM Studio (:1234)", 1)

    def _drain_other_tier(self):
        """Cross-tier evict: clear LM Studio (:1234) before a :8823 load so the box
        never holds two models. Best-effort; a missing/idle lms is a no-op."""
        import subprocess
        try:
            subprocess.run(["lms", "unload", "--all"], timeout=20,
                           capture_output=True, text=True)
            log("drained LM Studio tier (:1234) before load", 2)
        except Exception as e:
            log(f"lms drain skipped: {e!r}", 2)

    @contextmanager
    def gpu_job(self):
        """Hold the ONE box-wide GPU primitive for a WHOLE job (load + the multi-minute
        inference), not just the model load. Serializes on self.gpu (RLock) AND takes the
        box-wide fcntl.flock on gpu.lock so the :1234 tier (gpu-guard.sh) and any flock-aware
        peer (Charlie's voice loop) are mutually excluded for the entire job — closing the
        race where an evict could pull a model mid-ingest. Reentrancy-aware: nested calls
        (same thread) share the one flock via a depth counter guarded by self.gpu.
        NOTE: acquire() no longer flocks — the single flock lives HERE (a 2nd flock over the
        same file from the same process would self-deadlock)."""
        with self.gpu:
            if self._job_depth == 0:
                GPU_LOCKFILE.parent.mkdir(parents=True, exist_ok=True)
                self._job_lock_fd = open(GPU_LOCKFILE, "w")
                fcntl.flock(self._job_lock_fd, fcntl.LOCK_EX)
            self._job_depth += 1
            try:
                yield
            finally:
                self._job_depth -= 1
                if self._job_depth == 0:
                    try:
                        fcntl.flock(self._job_lock_fd, fcntl.LOCK_UN)
                        self._job_lock_fd.close()
                    except Exception as e:
                        log(f"gpu_job flock release warned: {e!r}", 2)
                    self._job_lock_fd = None

    # -- introspection --
    def status(self) -> dict:
        return {
            "budget_gb": self.budget,
            "resident": {k: {"est_gb": r.est_gb, "pinned": r.pinned,
                             "idle_s": round(time.time() - r.last_used, 1),
                             "load_s": round(r.load_s, 1)}
                         for k, r in self._resident.items()},
            "resident_gb": round(sum(r.est_gb for r in self._resident.values()), 1),
        }

    def _evict(self, key: str):
        r = self._resident.pop(key, None)
        if r:
            log(f"evicting {key} (~{r.est_gb}GB)", 1)
            try:
                r.handle.unload()
            except Exception as e:
                log(f"unload {key} warned: {e!r}", 2)

    def evict_all(self) -> list:
        """Unload every :8823-resident model (structural drain point for the other
        tier: the :1234 guard calls this before an `lms load`). Returns evicted keys."""
        with self.gpu:
            keys = list(self._resident)
            for k in keys:
                self._evict(k)
            return keys

    def _make_room(self, key: str, need_gb: float, exclusive: bool):
        """Evict until (resident + need) <= budget. exclusive => evict everything,
        incl pinned. Never evicts the target key."""
        if exclusive or need_gb > self.budget:
            for k in [k for k in self._resident if k != key]:
                self._evict(k)
            return
        def resident_gb():
            return sum(r.est_gb for k, r in self._resident.items() if k != key)
        # evict non-pinned LRU first
        while resident_gb() + need_gb > self.budget:
            cands = [(k, r) for k, r in self._resident.items()
                     if k != key and not r.pinned]
            if not cands:
                break
            k = min(cands, key=lambda kr: kr[1].last_used)[0]
            self._evict(k)
        # still over? we must drop pinned too
        while resident_gb() + need_gb > self.budget:
            cands = [(k, r) for k, r in self._resident.items() if k != key]
            if not cands:
                break
            k = min(cands, key=lambda kr: kr[1].last_used)[0]
            self._evict(k)

    def acquire(self, key: str, need_gb: Optional[float] = None, exclusive: bool = False):
        """Ensure `key` is resident (evicting as needed) and return its handle.
        MUST be called with self.gpu held (the server holds it for the whole request)."""
        if key not in self.FACTORY:
            raise KeyError(f"unknown model key: {key}")
        if key in self._resident:
            self._resident[key].last_used = time.time()
            return self._resident[key].handle
        handle = self.FACTORY[key]()
        est = need_gb if need_gb is not None else getattr(handle, "EST_GB", 20.0)
        if SINGLE_MODEL:
            exclusive = True                  # one model box-wide: evict all other :8823 residents
        # NOTE: the box-wide fcntl.flock is now held by gpu_job() for the WHOLE job (server holds
        # it around this acquire). Do NOT re-flock here — a 2nd flock on the same file from the same
        # process self-deadlocks against gpu_job's hold. (Callers MUST enter via gpu_job().)
        self._make_room(key, est, exclusive)
        if SINGLE_MODEL:
            self._drain_other_tier()          # clear LM Studio (:1234) before we load
        log(f"loading {key} (~{est}GB; budget {self.budget}GB; "
            f"resident now {list(self._resident)})", 1)
        load_s = handle.load()
        pinned = self.pin_vlm7b and key in self.PINNABLE
        self._resident[key] = _Resident(handle, est, pinned, load_s)
        log(f"loaded {key} in {load_s:.1f}s "
            f"({'PINNED' if pinned else 'swappable'})", 1)
        return handle

    def idle_evict(self, max_idle_s: float):
        """Evict swappable models idle longer than max_idle_s. Call from a timer."""
        with self.gpu:
            now = time.time()
            for k in [k for k, r in self._resident.items()
                      if not r.pinned and now - r.last_used > max_idle_s]:
                self._evict(k)
