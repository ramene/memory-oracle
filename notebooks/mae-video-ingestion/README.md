# mae — video ingestion (Qwen2.5-VL on Deepnote)

Triggered via Deepnote Jobs API. POST → poll → fetch `/work/output.json`.

Per Task #174 (operator session `24cbed9c`, 2026-05-03 spec). Replaces the RunPod L40S video-extraction path with a managed Deepnote notebook trigger.

## Pipeline

`yt-dlp` → frame extraction (ffmpeg, every `FRAME_INTERVAL_SEC`) → **Qwen2.5-VL** inference per frame with a trading-intelligence prompt → aggregated signal record → `/work/output.json` → `mae-gpu-manager.mjs` consumes.

## Parameters (Deepnote Jobs API payload)

| Parameter | Default | Notes |
|---|---|---|
| `VIDEO_URL` | *(required)* | Full YouTube URL or 11-char video ID |
| `EXTRACT_MODE` | `both` | `frames` \| `transcript` \| `both` |
| `FRAME_INTERVAL_SEC` | `12` | Seconds between sampled frames |
| `MAX_FRAMES` | `30` | Hard cap regardless of duration (cost control) |
| `MODEL` | `Qwen/Qwen2.5-VL-7B-Instruct` | Override to `-3B-Instruct` on small GPUs |
| `PROMPT_PROFILE` | `trading-intelligence` | or `general-summary` |
| `OUTPUT_PATH` | `/work/output.json` | Where the result lands inside the Deepnote container |

## Triggering the job (curl)

```bash
# Operator sets these once
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
      "PROMPT_PROFILE":     "trading-intelligence"
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

## Triggering from `mae-gpu-manager.mjs`

The May-3 spec called for `gpu-manager.mjs` to POST the trigger, poll for completion, read the JSON output. A reference wrapper:

```javascript
// services/mae-gpu-manager/lib/deepnote-trigger.mjs
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
  "prompt_profile": "trading-intelligence",
  "frames_analyzed": 26,
  "transcript": {
    "text": "...",
    "segments": [{"start_sec": 0.0, "end_sec": 4.5, "text": "..."}, ...],
    "segment_count": 87,
    "char_count": 5429
  },
  "aggregate": {
    "dominant_tickers": ["BTC", "ETH", "SOL"],
    "ticker_frame_counts": {"BTC": 18, "ETH": 11, "SOL": 4},
    "net_sentiment": {"BTC": 0.72, "ETH": 0.45, "SOL": -0.25},
    "macro_events_mentioned": {"FOMC Wed": 6, "CPI Thu": 3},
    "time_sensitivity_dist": {"now": 14, "this-week": 9, "longer-term": 3},
    "speaker_confidence_dist": {"high": 16, "medium": 8, "low": 2},
    "price_callouts": [{"ticker": "BTC", "price": 67500, "context": "support", "frame_idx": 5}]
  },
  "frames": [{ "frame_idx": 0, "timestamp_sec": 0.0, "signal": { ... } }, ...]
}
```

## Compute trade-off (post Deepnote Teams cancellation 2026-06-01)

Deepnote Teams subscription valid through **2026-06-01**. If this notebook works end-to-end on Deepnote's GPU tier before then, we stick with Deepnote (cheaper than Colab Pro+ for periodic batch jobs).

If Deepnote falls through after June 1:
- **Fallback A**: Modal serverless GPU — same notebook, different trigger. Adapt the `mae-gpu-manager.mjs` wrapper above to hit Modal's API.
- **Fallback B**: Colab Pro+ ($50/mo) — same notebook, run via Colab's background execution.
- **Fallback C**: Local Ollama on tunafish — verify `localhost:11434` has a Qwen-VL variant; cheapest if available.

## Provenance

Authored 2026-05-25 in session `2d097fa8` (memory-oracle paper-side), per operator request to resurface the 2026-05-03 Task #174 spec found via `find-prior-work 'Qwen3 video YouTube'` (which surfaced the hook capture at `~/.local/share/tmux-logs/2026/05/03/hooks/mae-monorepo-build_24cbed9c-fe4f-4a61-8b86-491d4ac98f4f.log` showing the original `VIDEO_URL`/`EXTRACT_MODE` parameter spec).
