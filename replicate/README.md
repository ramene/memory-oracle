# mae-video-ingestion — Replicate listing (Layer 3 of offline-LLM stack)

Pay-per-call wrapper around the video-ingestion notebook (Layer 2). Exposes
Qwen2.5-VL native-video extraction + Whisper transcript + 7 prompt profiles
as a single HTTPS endpoint at `r8.im/ramene/mae-video-ingestion`.

## Files

| File | Purpose |
|---|---|
| `cog.yaml` | Replicate's build config — pinned to the same versions as our `notebooks/video-ingestion/Dockerfile` |
| `predict.py` | The `Predictor` class — `setup()` loads model once per container, `predict()` is per-call |
| `prompt-profiles/` | Symlink → `../notebooks/video-ingestion/prompt-profiles/` (single source of truth) |

## Build + push

```bash
# One-time auth
cog login

# Test syntax locally (won't run inference without GPU)
cog predict -i video_url=https://youtu.be/Dkqzqw8rxXI -i profile=ai-systems-research

# Push to Replicate marketplace (~10-15 min first build, cached after)
cog push r8.im/ramene/mae-video-ingestion
```

## Inputs (customer-facing)

| Field | Type | Default | Notes |
|---|---|---|---|
| `video_url` | string | required | YouTube URL or direct .mp4 URL |
| `profile` | enum | `ai-systems-research` | One of 7 archetypes (see profile YAMLs) |
| `chunk_duration_sec` | int | 300 | 60-600 |
| `video_fps` | float | 0.5 | 0.1-2.0 |
| `video_max_pixels` | int | 151200 | 10000-500000 |
| `max_new_tokens` | int | 2048 | 512-8192 |
| `prompt_override` | string | `""` | Optional: paste custom prompt to bypass profile |

## Output

Same `schema_version: 2` shape produced by `notebooks/video-ingestion/video-ingestion-qwen25vl-v2.ipynb`:

```json
{
  "schema_version": 2,
  "inference_mode": "native_video",
  "source": "youtube/Dkqzqw8rxXI",
  "title": "...",
  "uploader": "Two Minute Papers",
  "prompt_profile": "ai-systems-research",
  "chunks_analyzed": 2,
  "transcript": { "text": "...", "segments": [...] },
  "aggregate": { "fields_observed": [...], "claimed_problem": [...], ... },
  "chunks": [ { "signal": { ... } }, ... ]
}
```

## Cost + hardware

| GPU | Replicate hourly | Per-300s-chunk extraction (~80s) |
|---|---|---|
| L4 (24 GB) | ~$0.81/hr | ~$0.02 |

Suggested customer pricing: $0.10-0.50/video-minute (markup over Replicate's
GPU cost + Replicate's 30% platform fee).

## Relationship to the rest of the stack

- **Layer 2 notebook** (`notebooks/video-ingestion/video-ingestion-qwen25vl-v2.ipynb`)
  is the canonical source for the inference logic; `predict.py` mirrors its §5–§11
- **Layer 4 curriculum factory** (`mae-curriculae`) consumes the same output shape
  for operator-curated lesson cards (manual review gate between)
- **Layer 5 verticals** (mae trading, clinical, academic) consume cards produced
  upstream, never call Layer 3 directly
- **Layer 6 storytelling** (`architecture-notes`) — the lead blog post citing
  AlphaProof Nexus as third-party validation links here as the public artifact

## Drift discipline

When `notebooks/video-ingestion/video-ingestion-qwen25vl-v2.ipynb` cells §5/§7/§8
change, this `predict.py` needs corresponding updates. The two diverging is the
biggest footgun — operator-honest framing demands the customer-facing API stay
in sync with the locally-validated notebook.

Single source of truth for the prompts: the YAML profiles in
`../notebooks/video-ingestion/prompt-profiles/`. predict.py loads them via the
symlink at build time. Edit the YAMLs there; predict.py picks up the change on
next `cog push`.
