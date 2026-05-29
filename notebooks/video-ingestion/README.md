# Video ingestion via Qwen2.5-VL on Deepnote

A batch video-ingestion pattern: trigger via Deepnote Jobs API, POST → poll →
fetch `/work/output.json`. Pairs nicely with any downstream consumer that needs
structured signal extraction from a YouTube URL (per-frame inference + transcript
aggregation).

This notebook is published as a generic reference for the Deepnote-Jobs-API +
Qwen2.5-VL pattern. It is **not** a memory-oracle / EBR component. Operators
running EBR workloads do not need this notebook; it is included only because the
pattern is reusable and was authored in the same window as the substrate work.

## Pipeline

`yt-dlp` → frame extraction (ffmpeg, every `FRAME_INTERVAL_SEC`) → **Qwen2.5-VL**
per-frame inference with a configurable prompt profile → aggregated signal record
→ `/work/output.json` → any downstream consumer (e.g., a GPU-manager service that
polls the Deepnote job and reads the file).

## Parameters (Deepnote Jobs API payload)

| Parameter | Default | Notes |
|---|---|---|
| `VIDEO_URL` | *(required)* | Full YouTube URL or 11-char video ID |
| `EXTRACT_MODE` | `both` | `frames` \| `transcript` \| `both` |
| `FRAME_INTERVAL_SEC` | `12` | Seconds between sampled frames |
| `MAX_FRAMES` | `30` | Hard cap regardless of duration (cost control) |
| `MODEL` | `Qwen/Qwen2.5-VL-7B-Instruct` | Override to `-3B-Instruct` on small GPUs |
| `PROMPT_PROFILE` | `general-summary` | Add additional profiles in the notebook's prompt-config cell |
| `OUTPUT_PATH` | `/work/output.json` | Where the result lands inside the Deepnote container |

## Triggering the job (curl)

```bash
# Set these once
DEEPNOTE_TOKEN='<api-key from Deepnote → Settings → API tokens>'
DEEPNOTE_PROJECT_ID='<project-id from Deepnote project URL>'
NOTEBOOK_ID='<notebook-id, get via GET /v1/projects/{pid}/notebooks>'

# Submit job — returns notebookRunId
curl -X POST "https://api.deepnote.com/v1/projects/${DEEPNOTE_PROJECT_ID}/jobs" \
  -H "Authorization: Bearer ${DEEPNOTE_TOKEN}" \
  -H "Content-Type: application/json" \
  -d '{
    "notebookId": "'"${NOTEBOOK_ID}"'",
    "parameters": {
      "VIDEO_URL":          "https://youtu.be/REPLACE_ME",
      "EXTRACT_MODE":       "both",
      "FRAME_INTERVAL_SEC": 12,
      "MAX_FRAMES":         30,
      "MODEL":              "Qwen/Qwen2.5-VL-7B-Instruct",
      "PROMPT_PROFILE":     "general-summary"
    }
  }'
# → {"notebookRunId": "nbr_abc123", "status": "queued"}

# Poll
curl -s "https://api.deepnote.com/v1/projects/${DEEPNOTE_PROJECT_ID}/jobs/nbr_abc123" \
  -H "Authorization: Bearer ${DEEPNOTE_TOKEN}" | jq .status
# → "running" → "succeeded"

# Fetch output (Deepnote File API)
curl -s "https://api.deepnote.com/v1/projects/${DEEPNOTE_PROJECT_ID}/files/work/output.json" \
  -H "Authorization: Bearer ${DEEPNOTE_TOKEN}" > output.json
```

## Reference consumer wrapper

A minimal Node.js wrapper for triggering, polling, and reading the result:

```javascript
import { setTimeout as sleep } from 'node:timers/promises';

const BASE = 'https://api.deepnote.com/v1';
const TOKEN = process.env.DEEPNOTE_TOKEN;
const PROJ  = process.env.DEEPNOTE_PROJECT_ID;
const NB    = process.env.DEEPNOTE_VIDEO_NOTEBOOK_ID;

const headers = {
  'Authorization': `Bearer ${TOKEN}`,
  'Content-Type':  'application/json',
};

export async function ingestVideo({ url, extractMode = 'both', maxFrames = 30 }) {
  const submit = await fetch(`${BASE}/projects/${PROJ}/jobs`, {
    method: 'POST', headers,
    body: JSON.stringify({
      notebookId: NB,
      parameters: {
        VIDEO_URL: url,
        EXTRACT_MODE: extractMode,
        MAX_FRAMES: maxFrames,
      },
    }),
  }).then(r => r.json());

  const { notebookRunId } = submit;

  // Poll every 15s, up to 30 min
  for (let i = 0; i < 120; i++) {
    await sleep(15_000);
    const status = await fetch(
      `${BASE}/projects/${PROJ}/jobs/${notebookRunId}`,
      { headers }
    ).then(r => r.json());
    if (status.status === 'succeeded') {
      const file = await fetch(
        `${BASE}/projects/${PROJ}/files/work/output.json`,
        { headers }
      ).then(r => r.json());
      return file;
    }
    if (status.status === 'failed') {
      throw new Error(`Deepnote job failed: ${JSON.stringify(status)}`);
    }
  }
  throw new Error('Deepnote job timed out after 30 min');
}
```

## Output schema (`/work/output.json`)

```json
{
  "schema_version": 1,
  "source": "youtube/<videoId>",
  "source_url": "https://youtu.be/<videoId>",
  "title": "...",
  "uploader": "...",
  "duration_sec": 312,
  "extracted_at": "2026-05-25T01:00:00Z",
  "extract_mode": "both",
  "model": "Qwen/Qwen2.5-VL-7B-Instruct",
  "prompt_profile": "general-summary",
  "frames_analyzed": 26,
  "transcript": {
    "text": "...",
    "segments": [{"start_sec": 0.0, "end_sec": 4.5, "text": "..."}],
    "segment_count": 87,
    "char_count": 5429
  },
  "aggregate": {
    "dominant_topics": ["..."],
    "topic_frame_counts": {"...": 18},
    "time_sensitivity_dist": {"now": 14, "this-week": 9, "longer-term": 3},
    "speaker_confidence_dist": {"high": 16, "medium": 8, "low": 2}
  },
  "frames": [{ "frame_idx": 0, "timestamp_sec": 0.0, "signal": { } }]
}
```

The `aggregate` shape is profile-dependent — the notebook's prompt-config cell
defines what fields each `PROMPT_PROFILE` produces.

## Provider fallbacks

If Deepnote is unavailable for any reason, the same notebook adapts to other
GPU providers with minor trigger-side changes:

- **Modal serverless GPU** — same notebook, different trigger; adapt the wrapper
  above to hit Modal's API.
- **Colab Pro+** — same notebook, run via Colab's background-execution feature.
- **Local** — verify `localhost:11434` (Ollama) or a local vLLM endpoint has a
  Qwen-VL variant; cheapest if you already have GPU hardware.
