---
license: mit
language:
  - en
library_name: transformers
pipeline_tag: video-text-to-text
tags:
  - video-understanding
  - vision-language-model
  - qwen2-vl
  - whisper
  - structured-extraction
  - operator-curated
  - evidence-bound-retrieval
base_model:
  - Qwen/Qwen2.5-VL-7B-Instruct
  - openai/whisper-base
---

# mae-video-ingestion

**Profile-driven structured-signal extraction from videos using Qwen2.5-VL native video mode + Whisper transcript + 7 archetype prompt profiles + schema-agnostic provenance-tagged output.**

Built as Layer 3 of the offline LLM stack documented in [`architecture-notes`](https://github.com/ramene/architecture-notes). Validated against DeepMind AlphaProof Nexus paper (arXiv 2605.22763) and López de Prado / Warrior Trading educational videos.

## What this is

A sealed-box wrapper around the canonical Layer-2 notebook in [`memory-oracle/notebooks/video-ingestion/`](https://github.com/ramene/memory-oracle/tree/main/notebooks/video-ingestion). Customer provides:

- `video_url`: YouTube URL or direct `.mp4` URL
- `profile`: one of seven prompt archetypes
- Tuning knobs: `chunk_duration_sec`, `video_fps`, `video_max_pixels`, `max_new_tokens`

Returns the same `schema_version=2` JSON the local pipeline produces — metadata + transcript + per-chunk signal + schema-agnostic aggregate with provenance tagging on every entry.

## The seven prompt profiles

| Profile | When to use |
|---|---|
| `ai-systems-research` | Paper-companion videos (Two Minute Papers, AI Coffee Break, paper explainers) |
| `paper-author-talk` | Conference talks by paper authors (NeurIPS / ICML / ICLR), with Q&A extraction |
| `coding-tutorial` | Hands-on walkthroughs (Karpathy-style) — code is the content |
| `product-announcement` | AI lab launch videos, with capability_claims + caveats_buried_in_fine_print extraction |
| `trading-education` | Pedagogical trading videos with pattern / filter / risk extraction |
| `trading-intelligence` | Market-intel financial videos with ticker / sentiment extraction |
| `general-summary` | Fallback for videos that don't match any archetype |

Full schemas in [`memory-oracle/notebooks/video-ingestion/prompt-profiles/`](https://github.com/ramene/memory-oracle/tree/main/notebooks/video-ingestion/prompt-profiles).

## Companion artifacts

- **Public corpus**: [`mae-curriculae-quant-foundations`](https://github.com/ramene/mae-curriculae-quant-foundations) — 10 López lesson cards under CC-BY-SA 4.0, prototype of operator-curated curriculum extraction
- **Substrate paper**: [memory-oracle/paper/](https://github.com/ramene/memory-oracle/tree/main/paper) — LNCS clinical case study + CoALA position paper (in revision)
- **Lead essay**: [The Harness IS the Intelligence](https://github.com/ramene/architecture-notes/blob/main/posts/meta/harness-is-the-intelligence.md) — positions this work alongside DeepMind AlphaProof Nexus

## What this is NOT

This model card describes a **pipeline**, not a new model. The actual inference uses [Qwen2.5-VL-7B-Instruct](https://huggingface.co/Qwen/Qwen2.5-VL-7B-Instruct) for vision-language extraction and [openai/whisper-base](https://huggingface.co/openai/whisper-base) for audio transcript — both unmodified upstream weights.

The differentiation is the **substrate layer around the model**:
- Profile-driven prompt selection with channel-hint runtime injection
- Schema-agnostic aggregate with provenance tagging (`_chunk_idx`, `_chunk_start_sec` on every entry)
- Cross-field consistency hallucination catch (operator-curated rejection log per source)
- Pinned reproducible build (CUDA + torch + transformers + decord + qwen-vl-utils all version-locked)
- Append-never-mutate amendment pattern via `.amendments.jsonl` sidecars when extractions are later corrected

## Reach the operator

| What | Where |
|---|---|
| Replicate listing (alternative deployment) | https://replicate.com/ramene/mae-video-ingestion |
| GitHub source | https://github.com/ramene/memory-oracle (notebook + Dockerfile + cog wrapper + this card) |
| Lead blog | https://github.com/ramene/architecture-notes |
| Commercial / batch / SLA / custom prompts | mailto:ramene@karve.ai (api.karve.ai launching Q3) |

## License

MIT for the wrapper code (cog wrapper, Dockerfile, predict.py, prompt profiles). Upstream model licenses apply for Qwen2.5-VL (Tongyi Qianwen License) and Whisper (MIT).

## Citation

If you use this in research:

```bibtex
@misc{ramene2026mae,
  author       = {Anthony, Ramene},
  title        = {mae-video-ingestion: profile-driven VLM extraction with operator-curated substrate},
  year         = {2026},
  publisher    = {Hugging Face},
  howpublished = {\url{https://huggingface.co/ramene/mae-video-ingestion}},
  note         = {Built on Qwen2.5-VL-7B-Instruct + Whisper. Substrate pattern: Evidence-Bound Retrieval (EBR) via memory-oracle.}
}
```
