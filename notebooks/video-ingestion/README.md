# Video ingestion via Qwen2.5-VL on Deepnote

A video-ingestion pattern: trigger via the Deepnote v2 Runs API, POST → poll →
fetch `output.json`. Pairs nicely with any downstream consumer that needs
structured signal extraction from a YouTube URL or local video file.

This notebook is published as a generic reference for the Deepnote v2 Runs API
+ Qwen2.5-VL pattern. It is **not** a memory-oracle / EBR component. Operators
running EBR workloads do not need this notebook; it is included only because the
pattern is reusable and was authored in the same window as the substrate work.

## Pipeline (current implementation)

`yt-dlp` (or local file) → frame extraction (ffmpeg, every `FRAME_INTERVAL_SEC`)
→ **Qwen2.5-VL** per-frame inference with a configurable prompt profile →
aggregated signal record → `OUTPUT_PATH`.

> ⚠️ **Architectural note (2026-06-03):** The current per-frame pattern THROWS
> AWAY temporal context across frames — each frame is processed in isolation.
> Qwen2.5-VL natively supports VIDEO input with full temporal awareness (motion,
> narrative arc, event localization across the full 1+ hour video). A v2
> rewrite using `{"type": "video", ...}` content blocks via
> `qwen_vl_utils.process_vision_info(messages, return_video_kwargs=True)` is
> queued. See the project's curriculum work for the full motivation. Until then,
> per-frame mode is the working baseline.

## Parameters

These are env vars the notebook reads at start. When triggering via Deepnote's
v2 Runs API (below), they must be passed as `inputs` — which requires
DECLARED INPUT BLOCKS in the notebook with matching names. Without input
blocks, the API call returns `"Input X is not defined for this notebook"`.

| Parameter | Default | Notes |
|---|---|---|
| `VIDEO_URL` | *(required)* | Full YouTube URL, direct https URL, OR local file path (e.g., `/datasets/_deepnote_work/work/foo.mp4`). Local files are detected via path resolution and skip yt-dlp. |
| `EXTRACT_MODE` | `both` | `frames` \| `transcript` \| `both` |
| `FRAME_INTERVAL_SEC` | `12` | Seconds between sampled frames |
| `MAX_FRAMES` | `30` | Hard cap regardless of duration (cost control). Raise to 200+ for high-fidelity work; cost on T4 is ~$0.06/min. |
| `MODEL` | `Qwen/Qwen2.5-VL-7B-Instruct` | Override to `-3B-Instruct` on small GPUs |
| `PROMPT_PROFILE` | `trading-intelligence` | `trading-intelligence` \| `general-summary` \| `trading-education` — defined in §5's `PROMPT_PROFILES` dict |
| `OUTPUT_PATH` | `/work/output.json` | Where the result lands. For Deepnote, prefer `/datasets/_deepnote_work/work/output.json` so it shows in the Files panel. |
| `YT_COOKIES_PATH` | `/work/youtube-cookies.txt` | OPTIONAL — workaround for YouTube bot-check on data-center IPs. Export cookies via browser extension on a logged-in machine, upload to Deepnote. |

## Triggering via Deepnote v2 Runs API

> The v2 API is the current public API. The v1 endpoints documented in older
> notebooks/agents are DEAD — they return Not Found. See
> [`https://deepnote.com/docs/api-reference`](https://deepnote.com/docs/api-reference).

```bash
# Set once
DEEPNOTE_TOKEN='<api-key from Deepnote → Account settings → API keys>'
NOTEBOOK_ID='<notebook-id from notebook URL: ...notebook/<this-part>>'

# Submit a run (returns runId, status: pending)
curl -X POST https://api.deepnote.com/v2/runs \
  -H "Authorization: Bearer ${DEEPNOTE_TOKEN}" \
  -H "Content-Type: application/json" \
  -d '{
    "notebookId": "'"${NOTEBOOK_ID}"'",
    "inputs": {
      "VIDEO_URL":          "https://youtu.be/REPLACE_ME",
      "EXTRACT_MODE":       "both",
      "FRAME_INTERVAL_SEC": "12",
      "MAX_FRAMES":         "30",
      "MODEL":              "Qwen/Qwen2.5-VL-7B-Instruct",
      "PROMPT_PROFILE":     "trading-intelligence",
      "OUTPUT_PATH":        "/datasets/_deepnote_work/work/output.json"
    },
    "detached": true
  }'
# → {"runId": "<uuid>", "status": "pending", "createdAt": "..."}

# Poll status
curl -H "Authorization: Bearer ${DEEPNOTE_TOKEN}" \
  https://api.deepnote.com/v2/runs/<RUN_ID>
# → {"run": {"status": "running"|"success"|"error"|..., ...}}
```

**Critical**: the `inputs` keys MUST match declared Deepnote input blocks in
the notebook (top-of-notebook UI elements). Without input blocks, the API
rejects the run. Add input blocks via Deepnote's block picker: `+ between
cells → Text input / Select input / Big number`.

## Input source dispatch

The §3 cell auto-detects the source type:

- **Local path** (file exists at the given path): skips yt-dlp, runs ffprobe
  for metadata, looks for sidecar `.vtt`/`.srt` subtitles
- **YouTube / HTTPS URL**: uses yt-dlp with optional cookies file
- **Google Drive**: connect Drive in Deepnote's Integrations panel; uploaded
  files appear under `/datasets/_deepnote_work/work/` or wherever Drive mounts

### YouTube bot-check workaround

YouTube blocks data-center IPs with "Sign in to confirm you're not a bot."
Two options:

1. **Cookies**: Export cookies via "Get cookies.txt LOCALLY" browser
   extension (logged-in browser on your machine), upload `youtube-cookies.txt`
   to Deepnote, point `YT_COOKIES_PATH` at it
2. **Download locally first**: `yt-dlp -f 'best[height<=360]' -o ~/Downloads/video.mp4 <url>`,
   upload to Deepnote, set `VIDEO_URL` to the local path

For recurring use (curriculum building), pre-stage videos in Google Drive
and point the notebook at the Drive-mounted paths.

## Output schema (`output.json`)

```json
{
  "schema_version": 1,
  "source": "youtube/<videoId>" | "local/<filename>",
  "source_url": "...",
  "title": "...",
  "uploader": "...",
  "duration_sec": 312,
  "extracted_at": "2026-06-03T...",
  "extract_mode": "both",
  "model": "Qwen/Qwen2.5-VL-7B-Instruct",
  "prompt_profile": "trading-intelligence",
  "frames_analyzed": 26,
  "transcript": {
    "text": "...",
    "segments": [{"start_sec": 0.0, "end_sec": 4.5, "text": "..."}],
    "segment_count": 87,
    "char_count": 5429
  },
  "aggregate": { ... },          // profile-dependent shape
  "frames": [{"frame_idx": 0, "timestamp_sec": 0.0, "signal": {...}}, ...]
}
```

The `aggregate` shape is profile-dependent — `PROMPT_PROFILES` in §5 defines
what fields each profile produces.

## Provider fallbacks

If Deepnote is unavailable:
- **Modal serverless GPU** — same notebook, different trigger
- **Colab Pro+** — Colab's background-execution feature
- **Local** — `localhost:11434` (Ollama) or a local vLLM endpoint with a Qwen-VL variant

## Operational notes

- Setup dependencies: ffmpeg (apt), yt-dlp, transformers>=4.49, accelerate,
  bitsandbytes>=0.43, qwen-vl-utils, pillow, einops, sentencepiece, torchvision.
  For optimal video loading: `pip install 'qwen-vl-utils[decord]==0.0.8'`.
- 8-bit quantization triggers cuBLAS status 15 errors on T4. Use **4-bit nf4
  via BitsAndBytesConfig** instead — cleaner, faster, no errors. See §4.
- For Hugging Face faster downloads + rate-limit avoidance, set `HF_TOKEN` env
  var. The notebook will use it automatically.
