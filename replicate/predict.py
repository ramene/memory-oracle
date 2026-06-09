"""
predict.py — Replicate Cog Predictor wrapping the video-ingestion pipeline.

Layer 3 of the offline LLM stack (offline-llm-stack.md). Customer sends a
video URL + profile name; we return the same structured-signal JSON the
local Deepnote pipeline produces — metadata + transcript + per-chunk signal
+ schema-agnostic aggregate with provenance tagging.

Mirrors logic from notebooks/video-ingestion/video-ingestion-qwen25vl-v2.ipynb:
  §1   env-var defaults
  §5   model load (Qwen2.5-VL fp16 / 4-bit NF4 fallback)
  §6   prompt resolution (profile + channel_hints + PROMPT_OVERRIDE)
  §7   ffmpeg chunking
  §8   per-chunk native-video inference
  §9   Whisper transcript
  §10  schema-agnostic aggregate
  §11  output JSON construction

When the notebook changes, this file needs corresponding updates. Single
source of TRUTH for the prompts: notebooks/video-ingestion/prompt-profiles/*.yaml
(symlinked into this directory at build time).
"""

import os
import sys
import json
import subprocess
import tempfile
import time
import re
from pathlib import Path
from datetime import datetime, timezone
from typing import Optional

# Force decord backend before any qwen-vl-utils import touches the env
os.environ.setdefault('FORCE_QWENVL_VIDEO_READER', 'decord')
os.environ.setdefault('TOKENIZERS_PARALLELISM', 'false')

from cog import BasePredictor, Input


# ──────────────────────────────────────────────────────────────────────────────
#  Profile loader — parse YAML profiles from disk
# ──────────────────────────────────────────────────────────────────────────────

def _load_profiles() -> tuple[dict, dict]:
    """Load 7 prompt profiles from the prompt-profiles/ directory.
    Returns (profiles_dict, channel_hints_dict).
    """
    import yaml
    profiles_dir = Path(__file__).parent / 'prompt-profiles'
    if not profiles_dir.exists():
        raise RuntimeError(f"profiles dir missing: {profiles_dir}")
    profiles, channel_hints = {}, {}
    for yp in sorted(profiles_dir.glob('*.yaml')):
        spec = yaml.safe_load(yp.read_text())
        profiles[spec['name']] = spec['prompt']
        channel_hints[spec['name']] = spec.get('channel_hints', {})
    if not profiles:
        raise RuntimeError(f"no profiles loaded from {profiles_dir}")
    return profiles, channel_hints


def _resolve_prompt(profile: str, profiles: dict, channel_hints: dict,
                    uploader: str, prompt_override: str) -> tuple[str, str]:
    """Implements §6 resolver: override > matched profile + channel hint > matched profile > fallback.
    Returns (resolved_prompt_text, selected_profile_label).
    """
    if prompt_override.strip():
        return prompt_override.strip(), 'PROMPT_OVERRIDE'
    if profile in profiles:
        base = profiles[profile]
        hints = channel_hints.get(profile, {})
        uploader_l = (uploader or '').lower()
        for ch_key, hint_text in hints.items():
            if ch_key.lower() in uploader_l:
                return f"{base}\n\n## Channel hint — {ch_key}\n{hint_text}\n", profile
        return base, profile
    # Fallback
    fb = 'trading-education' if 'trading-education' in profiles else next(iter(profiles))
    return profiles[fb], fb


# ──────────────────────────────────────────────────────────────────────────────
#  Video download + metadata + chunking
# ──────────────────────────────────────────────────────────────────────────────

YOUTUBE_ID_RE = re.compile(
    r"(?:youtube\.com/(?:watch\?v=|embed/|v/|shorts/)|youtu\.be/)([A-Za-z0-9_-]{11})"
)


def _download_video(video_url: str, workdir: Path) -> tuple[Path, dict]:
    """yt-dlp the URL → local mp4 in workdir. Returns (mp4_path, metadata_dict).
    Accepts YouTube URLs OR direct https mp4 URLs.
    """
    is_youtube = 'youtu' in video_url or YOUTUBE_ID_RE.search(video_url or '')
    if is_youtube:
        m = YOUTUBE_ID_RE.search(video_url)
        video_id = m.group(1) if m else 'unknown'
        out_path = workdir / f'{video_id}.mp4'
        # Get metadata first (cheap, no download)
        meta_proc = subprocess.run(
            ['yt-dlp', '--dump-single-json', '--skip-download', video_url],
            capture_output=True, text=True, timeout=120
        )
        metadata = json.loads(meta_proc.stdout) if meta_proc.returncode == 0 else {}
        # Now download (360p mp4 for budget)
        subprocess.run([
            'yt-dlp', '-f', 'best[height<=360][ext=mp4]/best[ext=mp4]',
            '-o', str(out_path), video_url
        ], check=True, timeout=600)
        return out_path, metadata
    else:
        # Direct https URL — curl it
        video_id = Path(video_url.split('?')[0]).stem or 'direct'
        out_path = workdir / f'{video_id}.mp4'
        subprocess.run(['curl', '-fL', '-o', str(out_path), video_url], check=True, timeout=600)
        return out_path, {'title': video_id, 'uploader': 'direct', 'duration': None}


def _chunk_video(mp4_path: Path, chunk_dir: Path, chunk_duration_sec: int) -> list[dict]:
    """ffmpeg-split the mp4 into <chunk_duration_sec> segments.
    Returns [{'chunk_idx', 'start_sec', 'end_sec', 'path'}].
    """
    chunk_dir.mkdir(parents=True, exist_ok=True)
    # Probe duration
    probe = subprocess.run([
        'ffprobe', '-v', 'error', '-show_entries', 'format=duration',
        '-of', 'default=noprint_wrappers=1:nokey=1', str(mp4_path)
    ], capture_output=True, text=True, check=True)
    duration_sec = float(probe.stdout.strip())
    chunks = []
    i = 0
    start = 0
    while start < duration_sec:
        end = min(start + chunk_duration_sec, duration_sec)
        out = chunk_dir / f'chunk_{i:03d}.mp4'
        subprocess.run([
            'ffmpeg', '-y', '-loglevel', 'error', '-i', str(mp4_path),
            '-ss', str(start), '-t', str(end - start),
            '-c', 'copy', str(out)
        ], check=True, timeout=300)
        chunks.append({'chunk_idx': i, 'start_sec': start, 'end_sec': end, 'path': out})
        i += 1
        start = end
    return chunks


# ──────────────────────────────────────────────────────────────────────────────
#  Aggregate (schema-agnostic, same logic as notebook §8 / Task #120)
# ──────────────────────────────────────────────────────────────────────────────

def _build_aggregate(chunk_signals: list[dict]) -> dict:
    """Schema-agnostic aggregate with provenance. Mirrors notebook Cell 19."""
    from collections import defaultdict
    agg = {
        'segment_count': len(chunk_signals),
        'segments_with_signal': sum(
            1 for cs in chunk_signals
            if isinstance(cs.get('signal'), dict)
            and not any(k.startswith('_') for k in cs['signal'])
        ),
        'fields_observed': [],
    }
    collected = defaultdict(list)
    for cs in chunk_signals:
        sig = cs.get('signal', {})
        if not isinstance(sig, dict) or any(k.startswith('_') for k in sig):
            continue
        prov = {'_chunk_idx': cs['chunk_idx'], '_chunk_start_sec': cs['start_sec']}
        for field_name, value in sig.items():
            if field_name.startswith('_'):
                continue
            if value is None or value == '' or value == [] or value == {}:
                continue
            if isinstance(value, list):
                for item in value:
                    entry = dict(item) if isinstance(item, dict) else {'value': item}
                    entry.update(prov)
                    collected[field_name].append(entry)
            else:
                collected[field_name].append({'value': value, **prov})
    for k, items in collected.items():
        agg[k] = items
    agg['fields_observed'] = sorted(collected.keys())
    return agg


# ──────────────────────────────────────────────────────────────────────────────
#  Predictor — the Cog entry point
# ──────────────────────────────────────────────────────────────────────────────

class Predictor(BasePredictor):

    def setup(self):
        """Loaded ONCE when the container boots. Heavy stuff goes here.
        Mirrors notebook §5 (model load) + §6 (profile loader)."""
        import torch
        import gc
        from transformers import (
            Qwen2_5_VLForConditionalGeneration, AutoProcessor, BitsAndBytesConfig
        )
        import whisper

        self.MODEL_NAME = 'Qwen/Qwen2.5-VL-7B-Instruct'
        device = 'cuda' if torch.cuda.is_available() else 'cpu'
        print(f'[setup] device={device}')

        load_kwargs = {'device_map': 'auto'}
        if device == 'cuda':
            gpu_gb = torch.cuda.get_device_properties(0).total_memory // (1024**3)
            print(f'[setup] GPU {torch.cuda.get_device_name(0)} {gpu_gb} GB')
            if gpu_gb < 20:
                print('[setup] 4-bit NF4 quantization (small GPU)')
                load_kwargs['quantization_config'] = BitsAndBytesConfig(
                    load_in_4bit=True,
                    bnb_4bit_quant_type='nf4',
                    bnb_4bit_compute_dtype=torch.float16,
                    bnb_4bit_use_double_quant=True,
                )
            else:
                print('[setup] FP16')
                load_kwargs['torch_dtype'] = torch.float16
        else:
            load_kwargs['torch_dtype'] = torch.float32

        t0 = time.time()
        print(f'[setup] loading {self.MODEL_NAME}...')
        self.vl_model = Qwen2_5_VLForConditionalGeneration.from_pretrained(
            self.MODEL_NAME, **load_kwargs
        )
        self.vl_processor = AutoProcessor.from_pretrained(self.MODEL_NAME)
        print(f'[setup] VL model loaded in {time.time()-t0:.1f}s')

        # Whisper for audio transcript
        t0 = time.time()
        self.whisper_model = whisper.load_model('base')
        print(f'[setup] Whisper base loaded in {time.time()-t0:.1f}s')

        # Prompt profiles
        self.profiles, self.channel_hints = _load_profiles()
        print(f'[setup] loaded {len(self.profiles)} prompt profiles: {sorted(self.profiles.keys())}')

    def predict(
        self,
        video_url: str = Input(
            description="YouTube URL or direct https .mp4 URL"
        ),
        profile: str = Input(
            description="Prompt profile (archetype). Determines extraction schema.",
            default="ai-systems-research",
            choices=[
                "trading-education", "trading-intelligence", "general-summary",
                "ai-systems-research", "paper-author-talk", "coding-tutorial",
                "product-announcement",
            ],
        ),
        chunk_duration_sec: int = Input(
            description="Seconds per video chunk (smaller = more chunks, more memory headroom)",
            default=300, ge=60, le=600,
        ),
        video_fps: float = Input(
            description="Sample fps per chunk (higher = denser visual capture, more memory)",
            default=0.5, ge=0.1, le=2.0,
        ),
        video_max_pixels: int = Input(
            description="Per-frame pixel budget (360*420=151200 default)",
            default=151200, ge=10000, le=500000,
        ),
        max_new_tokens: int = Input(
            description="Per-chunk LLM output cap",
            default=2048, ge=512, le=8192,
        ),
        prompt_override: str = Input(
            description="Optional: paste custom prompt to bypass PROFILE entirely",
            default="",
        ),
    ) -> dict:
        """Extract structured signal from a video.
        Returns the schema_version=2 output.json shape produced by the local
        Deepnote notebook — see notebooks/video-ingestion/README.md for fields.
        """
        import torch
        import gc

        # GPU cleanup before this prediction (Task #122 pattern — prevents OOM
        # on back-to-back predict() calls if container is reused)
        gc.collect()
        if torch.cuda.is_available():
            torch.cuda.empty_cache()
            torch.cuda.synchronize()

        t_start = time.time()
        with tempfile.TemporaryDirectory(prefix='cog-vid-') as wd:
            workdir = Path(wd)
            chunk_dir = workdir / 'chunks'

            # 1. Download
            print(f'[predict] downloading {video_url}')
            mp4_path, video_meta = _download_video(video_url, workdir)
            uploader = video_meta.get('uploader', '') or ''
            title = video_meta.get('title', mp4_path.stem)
            duration_sec = video_meta.get('duration')
            print(f'[predict] downloaded {mp4_path.stat().st_size/1024/1024:.1f} MB, uploader={uploader!r}')

            # 2. Resolve prompt (with channel-hint matching)
            resolved_prompt, selected_profile = _resolve_prompt(
                profile, self.profiles, self.channel_hints, uploader, prompt_override
            )
            print(f'[predict] profile={selected_profile} ({len(resolved_prompt)} chars)')

            # 3. Chunk via ffmpeg
            chunks = _chunk_video(mp4_path, chunk_dir, chunk_duration_sec)
            print(f'[predict] chunked into {len(chunks)} segments')

            # 4. Per-chunk Qwen2.5-VL native-video inference
            chunk_signals = self._run_inference(chunks, resolved_prompt,
                                                video_fps, video_max_pixels, max_new_tokens)

            # 5. Whisper transcript on full audio
            print(f'[predict] running Whisper transcript...')
            try:
                wh_result = self.whisper_model.transcribe(str(mp4_path), verbose=False)
                transcript = {
                    'text': wh_result.get('text', ''),
                    'segments': [{'start_sec': s['start'], 'end_sec': s['end'], 'text': s['text']}
                                 for s in wh_result.get('segments', [])],
                }
                transcript['segment_count'] = len(transcript['segments'])
                transcript['char_count'] = len(transcript['text'])
            except Exception as e:
                transcript = {'text': '', 'segments': [], 'segment_count': 0,
                              'char_count': 0, '_whisper_error': str(e)}

            # 6. Schema-agnostic aggregate
            agg = _build_aggregate(chunk_signals)

            # 7. Assemble output
            source_prefix = 'youtube' if 'youtu' in video_url else ('local' if mp4_path.exists() else 'url')
            output = {
                'schema_version': 2,
                'inference_mode': 'native_video',
                'source': f"{source_prefix}/{mp4_path.stem}",
                'source_url': video_url,
                'title': title,
                'uploader': uploader,
                'duration_sec': duration_sec,
                'extracted_at': datetime.now(timezone.utc).isoformat(),
                'extract_mode': 'both',
                'model': self.MODEL_NAME,
                'prompt_profile': selected_profile,
                'chunk_duration_sec': chunk_duration_sec,
                'video_fps': video_fps,
                'video_max_pixels': video_max_pixels,
                'chunks_analyzed': len(chunk_signals),
                'transcript': transcript,
                'aggregate': agg,
                'chunks': chunk_signals,
                '_replicate_elapsed_sec': round(time.time() - t_start, 2),
            }
            print(f'[predict] done in {time.time()-t_start:.1f}s')
            return output

    def _run_inference(self, chunks: list[dict], prompt: str,
                       fps: float, max_pixels: int, max_new_tokens: int) -> list[dict]:
        """Per-chunk Qwen2.5-VL native-video inference. Mirrors notebook §7."""
        import torch
        from qwen_vl_utils import process_vision_info

        chunk_signals = []
        for cr in chunks:
            t0 = time.time()
            try:
                messages = [{
                    'role': 'user',
                    'content': [
                        {'type': 'video', 'video': f"file://{cr['path']}", 'fps': fps,
                         'max_pixels': max_pixels},
                        {'type': 'text', 'text': prompt},
                    ],
                }]
                text = self.vl_processor.apply_chat_template(
                    messages, tokenize=False, add_generation_prompt=True
                )
                image_inputs, video_inputs, video_kwargs = process_vision_info(
                    messages, return_video_kwargs=True
                )
                inputs = self.vl_processor(
                    text=[text], images=image_inputs, videos=video_inputs,
                    padding=True, return_tensors='pt', **video_kwargs
                )
                inputs = inputs.to(self.vl_model.device)
                with torch.inference_mode():
                    generated = self.vl_model.generate(
                        **inputs, max_new_tokens=max_new_tokens, do_sample=False
                    )
                generated_trimmed = [
                    out[len(inp):] for inp, out in zip(inputs.input_ids, generated)
                ]
                raw = self.vl_processor.batch_decode(
                    generated_trimmed, skip_special_tokens=True,
                    clean_up_tokenization_spaces=False
                )[0]
                # Try to parse as JSON; fall back to {summary: raw}
                try:
                    # Strip markdown code fences if present
                    cleaned = re.sub(r'^```(?:json)?\s*|\s*```$', '', raw.strip(), flags=re.MULTILINE)
                    sig = json.loads(cleaned)
                except json.JSONDecodeError:
                    sig = {'summary': raw.strip()}
            except Exception as e:
                sig = {'_inference_error': f'{type(e).__name__}: {e}'}

            chunk_signals.append({
                'chunk_idx': cr['chunk_idx'],
                'start_sec': cr['start_sec'],
                'end_sec': cr['end_sec'],
                'inference_sec': round(time.time() - t0, 2),
                'signal': sig,
            })
            print(f"[predict] chunk {cr['chunk_idx']+1}/{len(chunks)} "
                  f"({cr['start_sec']}-{cr['end_sec']}s) {'ERROR' if '_inference_error' in sig else 'OK'} "
                  f"in {time.time()-t0:.1f}s")
        return chunk_signals
