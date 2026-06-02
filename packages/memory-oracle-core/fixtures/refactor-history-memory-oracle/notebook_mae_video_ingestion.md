---
name: NOTEBOOK-MAE-VIDEO-INGESTION
description: Video ingestion notebook for mae trading transcripts via Qwen2.5-VL.
metadata:
  type: notebook
  authored_at: 2026-05-15T14:00:00Z
  notebook_path: notebooks/mae-video-ingestion/
  primary_notebook: video-ingestion-qwen25vl.ipynb
---

# notebooks/mae-video-ingestion/

The mae-video-ingestion notebook directory contains a Colab-runnable
pipeline that takes operator-provided trading-floor video clips and
runs them through Qwen2.5-VL for transcript extraction, then writes
the transcripts back into the memory-oracle substrate as amendment
candidates.

Layout:
- `notebooks/mae-video-ingestion/README.md`
- `notebooks/mae-video-ingestion/video-ingestion-qwen25vl.ipynb`

The "mae-" prefix in the directory name reflects the original use
case (mae trading-floor videos).
