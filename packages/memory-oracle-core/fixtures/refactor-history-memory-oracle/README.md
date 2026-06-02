# refactor-history-memory-oracle

Refactor-history corpus mined from the memory-oracle repo's own git log.
Each pair is a canonical "old API / old location / old terminology" doc
and an amendment record citing the commit hash + date where the
supersession landed.

This corpus is grounded in **real public commit data** — every amendment
has `live_evidence` pointing to a verifiable commit hash. No synthetic
content; all canonical/amendment content reflects what was actually in
the repo before and after the cited commit.

## Corpus contents

| Canonical (pre-refactor) | Amendment (post-refactor) | Commit |
|---|---|---|
| `mechanism_supersession_sidecar.md` | "supersession sidecar" → "amendment record"; `.supersessions.jsonl` → `.amendments.jsonl` | `d5c9f5a` (2026-05-27) |
| `package_mobile.md` | `packages/mobile/` → `packages/mobile-patient/` (Phase 3a scaffold) | `d771610` (2026-05-31) |
| `notebook_mae_video_ingestion.md` | `notebooks/mae-video-ingestion/` → `notebooks/video-ingestion/` | `90538da` (2026-05-28) |
| `docs_root_paper_files.md` | `docs/RETRIEVAL-*.md`, `docs/PAPER-ROADMAP.md` → `docs/genesis/` archive | `0b077c2` (2026-05-28) |
| `file_clinical_supersession_proof.md` | `clinical-supersession-proof.{sh,md}` → `clinical-amendment-proof.{sh,md}` | `d5c9f5a` (2026-05-27) |
| `file_trading_supersession_proof.md` | `trading-supersession-proof.sh` → `trading-amendment-proof.sh` | `d5c9f5a` (2026-05-27) |
| `paper_title.md` | "Accretive Memory for Clinical AI: A Evidence-Bound Retrieval Substrate" → "Evidence-Bound Retrieval for Clinical AI: An Accretive Memory Substrate" | `d5c9f5a` (2026-05-27) |
| `figure_f5_supersession_view.md` | `F5-supersession-view.png` → `F5-amendment-view.png` | `d5c9f5a` (2026-05-27) |
| `function_loadSupersessions.md` | `loadSupersessions()` reads ONLY `.supersessions.jsonl` → reads BOTH `.amendments.jsonl` (preferred) AND `.supersessions.jsonl` (fallback) | `d5c9f5a` (2026-05-27) |

All amendment records are sidecar JSONL with the standard fields
(`superseded_at`, `corrected_assertion`, `source`, `live_evidence`,
`operator_confirmed`, `retention_policy`) matching the trading vault
convention. Live evidence cites commit hashes you can verify in this
repository's git log.
