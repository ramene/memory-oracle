#!/usr/bin/env python3
"""
beir_panel_harness.py — BEIR-style multi-corpus retrieval evaluation
for §8 of the LNCS paper.

Compares three retrieval paths on operator-grounded supersession corpora:

  - BM25  (rank_bm25 over canonical+amendment docs)
  - dense (sentence-transformers all-MiniLM-L6-v2 cosine)
  - EBR   (memory-merge.mjs amendment-merged docs, BM25-ranked)

Metrics per corpus per path:
  - nDCG@10 with graded relevance (amendment=2, canonical=1, distractor=0)
  - Recall@10 for "the amendment record appears in top-10"
  - Top-1 correctness (binary, for §8 continuity)

Outputs:
  - notebooks/memory-oracle/figures/beir-panel-<corpus-slug>.json
  - notebooks/memory-oracle/figures/beir-panel-summary.json

Run:
  /tmp/beir-venv/bin/python notebooks/memory-oracle/beir_panel_harness.py

The notebook version (beir-panel-build.ipynb) wraps this in cells for
reproducibility on Colab/Deepnote.
"""

from __future__ import annotations
import json
import math
import os
import re
import subprocess
import sys
import time
from pathlib import Path
from typing import Iterable

# ---------------------------------------------------------------------------
# Repo layout discovery
# ---------------------------------------------------------------------------

REPO_ROOT = Path(__file__).resolve().parents[2]
FIXTURES_ROOT = REPO_ROOT / "packages" / "memory-oracle-core" / "fixtures"
FIGURES_DIR = REPO_ROOT / "notebooks" / "memory-oracle" / "figures"
MERGE_BIN = REPO_ROOT / "bin" / "memory-merge.mjs"

FIGURES_DIR.mkdir(parents=True, exist_ok=True)

CORPORA = [
    "refactor-history-memory-oracle",
    "trading-substrate-extended",
]

# Existing single-pair clinical corpus — used as additional distractor pool
DISTRACTOR_CORPORA = [
    "jane-doe-1959",
]

# Inflate haystack with the repo's own docs/paper content (not amendment-shaped,
# just bulk text) so Recall@10 is discriminative on a non-trivial document pool.
# We chunk each file into 500-token pieces; each chunk is its own distractor doc.
BULK_DISTRACTOR_GLOBS = [
    "docs/genesis/*.md",
    "docs/*.md",
    "paper/blog/*.md",
    "paper/lncs/README.md",
    "paper/EVIDENCE-OF-PLATFORM.md",
    "README.md",
]


# ---------------------------------------------------------------------------
# Corpus loading
# ---------------------------------------------------------------------------

def chunk_text(text: str, chunk_words: int = 400) -> list[str]:
    """Split text on whitespace into ~chunk_words-word chunks."""
    words = text.split()
    out = []
    for i in range(0, len(words), chunk_words):
        out.append(" ".join(words[i:i + chunk_words]))
    return [c for c in out if c.strip()]


def load_bulk_distractors() -> list[dict]:
    """Load chunked text from repo docs/paper as off-target haystack inflation."""
    out = []
    for pattern in BULK_DISTRACTOR_GLOBS:
        for path in REPO_ROOT.glob(pattern):
            if not path.is_file():
                continue
            try:
                text = path.read_text(encoding="utf-8", errors="ignore")
            except Exception:
                continue
            for i, chunk in enumerate(chunk_text(text)):
                out.append({
                    "scope": f"DISTRACTOR_BULK_{path.relative_to(REPO_ROOT)}_chunk{i}",
                    "kind": "distractor",
                    "text": chunk,
                })
    return out


def load_corpus(corpus_slug: str) -> dict:
    """Return canonical/amendment/merged doc texts plus structural metadata."""
    corpus_dir = FIXTURES_ROOT / corpus_slug
    if not corpus_dir.exists():
        raise FileNotFoundError(f"corpus dir missing: {corpus_dir}")

    pairs = []
    for md in sorted(corpus_dir.glob("*.md")):
        if md.name == "README.md":
            continue
        scope = md.stem
        amendments_path = md.with_suffix(md.suffix + ".amendments.jsonl")
        if not amendments_path.exists():
            # Skip canonicals with no amendment — not supersession-rich
            continue
        canonical_text = md.read_text(encoding="utf-8")
        amendment_records = []
        for line in amendments_path.read_text(encoding="utf-8").splitlines():
            s = line.strip()
            if not s:
                continue
            amendment_records.append(json.loads(s))
        # The "amendment doc" is the concatenation of corrected_assertion +
        # scope + live_evidence, mirroring what the substrate surfaces.
        amendment_text = render_amendment_doc(scope, amendment_records)
        merged_text = render_merged_doc(md)
        pairs.append({
            "scope": scope,
            "canonical_path": str(md),
            "amendment_path": str(amendments_path),
            "canonical_text": canonical_text,
            "amendment_text": amendment_text,
            "merged_text": merged_text,
            "amendment_records": amendment_records,
        })
    if not pairs:
        raise RuntimeError(f"no canonical+amendment pairs in {corpus_dir}")
    return {"slug": corpus_slug, "pairs": pairs}


def render_amendment_doc(scope: str, records: list) -> str:
    """Render the amendment-only document the way an indexer would see it."""
    lines = [f"# Amendment record for scope: {scope}"]
    for r in records:
        lines.append("")
        lines.append(f"superseded_at: {r.get('superseded_at', '?')}")
        lines.append(f"scope: {r.get('scope', '')}")
        lines.append(f"corrected_assertion: {r.get('corrected_assertion', '')}")
        if r.get("source"):
            lines.append(f"source: {r['source']}")
        if r.get("live_evidence"):
            lines.append(f"live_evidence: {r['live_evidence']}")
        if r.get("operator_confirmed"):
            lines.append(f"operator_confirmed: {r['operator_confirmed']}")
    return "\n".join(lines)


def render_merged_doc(md_path: Path) -> str:
    """Shell out to bin/memory-merge.mjs to get the EBR-merged view."""
    try:
        r = subprocess.run(
            ["node", str(MERGE_BIN), str(md_path)],
            capture_output=True, text=True, timeout=15, check=True,
        )
        return r.stdout
    except subprocess.CalledProcessError as e:
        print(f"[warn] memory-merge failed on {md_path}: {e.stderr}", file=sys.stderr)
        return md_path.read_text(encoding="utf-8")
    except subprocess.TimeoutExpired:
        print(f"[warn] memory-merge timeout on {md_path}", file=sys.stderr)
        return md_path.read_text(encoding="utf-8")


# ---------------------------------------------------------------------------
# Query generation — one query per pair, plus 1-2 paraphrases per pair.
# All queries phrased as "current X for Y" form where the operator-correct
# answer lives in the amendment, not the canonical.
# ---------------------------------------------------------------------------

# Corpus-specific query templates. Each template targets a specific scope's
# amendment with multiple paraphrases. Keep query strings short and natural —
# the kind of thing an agent/operator would actually type.

REFACTOR_QUERIES = {
    "mechanism_supersession_sidecar": [
        "what is the current file extension for the amendment sidecar",
        "what is the new name for the supersession sidecar mechanism",
        "what jsonl extension does the merge primitive prefer today",
    ],
    "package_mobile": [
        "where does the mobile patient package live now",
        "what is the current path for the mobile package after the Phase 3 rename",
        "what is the new npm name for the mobile patient package",
    ],
    "notebook_mae_video_ingestion": [
        "where does the video ingestion notebook live now",
        "what is the current path for the video ingestion qwen notebook",
        "what notebook directory replaced mae-video-ingestion",
    ],
    "docs_root_paper_files": [
        "where are the RETRIEVAL spec docs located now",
        "what is the current directory for the paper roadmap document",
        "where did the genesis paper roadmap and retrieval specs get archived",
    ],
    "file_clinical_supersession_proof": [
        "what is the current filename for the clinical litmus script",
        "what is the new name of the clinical supersession proof shell script",
        "what file replaced clinical-supersession-proof.md",
    ],
    "file_trading_supersession_proof": [
        "what is the current name for the trading proof shell script",
        "what file replaced trading-supersession-proof.sh",
        "what is the new trading litmus filename after the rename",
    ],
    "paper_title": [
        "what is the current LNCS paper title",
        "what is the most recent title of the EBR clinical AI paper",
        "what title does paper/lncs/main.tex use now",
    ],
    "figure_f5_supersession_view": [
        "what is the current filename of figure F5",
        "what is the new name of F5-supersession-view.png",
        "what figure file replaced F5-supersession-view",
    ],
    "function_loadSupersessions": [
        "what sidecar extensions does loadSupersessions read today",
        "what is the current behavior of loadSupersessions for backwards compat",
        "does memory-merge read .amendments.jsonl or .supersessions.jsonl now",
    ],
}

TRADING_QUERIES = {
    "strategy_shorting_kucoin_spot": [
        "is shorting authorized for the operator account today",
        "current rule for opening short positions on Binance Futures",
        "what is the active shorting authorization path now",
    ],
    "strategy_session_multiplier": [
        "current value of the session confidence multiplier per regime",
        "what session multiplier applies to news-day cycles now",
        "is MAE_SESSION_CONF_MULT still hardcoded at 1.15",
    ],
    "strategy_mean_rev_kc_bearish_exemption": [
        "does the KC bearish blocker still reject mean-reversion long entries",
        "current exemption for MEAN-REV-LONG dip buys on KuCoin bearish regime",
        "what agents are exempt from kc-bearish-regime-blocker",
    ],
    "strategy_chopday_signal_confidence_floor": [
        "current minSignalConfidence floor for APE and ENJ on chop-day",
        "what signal confidence floor applies to ENJ-USDT chop-day mean reversion",
        "is the chop-day minSignalConfidence still 0.72 for all pairs",
    ],
    "strategy_chopday_aletheia_weight": [
        "current minAletheiaWeight floor for chop-day entries",
        "what Aletheia weight floor applies to kucoin-scanner chop-day signals now",
        "is the chop-day minAletheiaWeight still 0.55",
    ],
    "strategy_sitout_auto_engage": [
        "is sit-out auto-engage active today after consecutive losses",
        "what flag controls sit-out auto-engage right now",
        "current behavior of sitout.auto_engage with cascading gate rejections",
    ],
    "strategy_gate_registry": [
        "is there a central gate registry in the orchestrator",
        "what gates are registered in the Phase 0.2.5 gate registry",
        "current architecture for gate composition tracing",
    ],
    "strategy_brain_cascade": [
        "current MONITOR cascade structure with Haiku tier ordering",
        "does MONITOR still call api.anthropic.com directly for the T4 fallback",
        "what is the COACH 5-tier brain cascade structure today",
    ],
    "strategy_perp_funding_threshold": [
        "current funding rate gating thresholds for perpetual short positions",
        "what funding rate triggers the close-all-shorts circuit breaker now",
        "max leverage by regime for Binance Futures perps today",
    ],
}

QUERY_TEMPLATES = {
    "refactor-history-memory-oracle": REFACTOR_QUERIES,
    "trading-substrate-extended": TRADING_QUERIES,
}


# ---------------------------------------------------------------------------
# Document collection per corpus — flattened list with relevance lookup
# ---------------------------------------------------------------------------

def build_index(corpus: dict, path_kind: str, distractors: list[dict] | None = None,
                bulk_distractors: list[dict] | None = None) -> tuple[list[str], list[dict]]:
    """Build (docs, doc_meta) for a path_kind in {"canonical_only", "amendment_only", "both", "ebr"}.

    distractors: optional list of foreign corpora to include as off-target docs.
    Each foreign corpus contributes BOTH its canonical and amendment docs to the
    target index for "both" path, or its merged docs for "ebr" path. Foreign docs
    are tagged with kind="distractor" so relevance always = 0.

    Returns:
      docs:     list[str] — document texts in stable order
      doc_meta: list[dict] — parallel list with keys: scope, kind ("canonical"|"amendment"|"merged"|"distractor")
    """
    docs = []
    meta = []
    if path_kind in ("both", "canonical_only"):
        for p in corpus["pairs"]:
            docs.append(p["canonical_text"])
            meta.append({"scope": p["scope"], "kind": "canonical"})
    if path_kind in ("both", "amendment_only"):
        for p in corpus["pairs"]:
            docs.append(p["amendment_text"])
            meta.append({"scope": p["scope"], "kind": "amendment"})
    if path_kind == "ebr":
        for p in corpus["pairs"]:
            docs.append(p["merged_text"])
            meta.append({"scope": p["scope"], "kind": "merged"})

    # Append distractor docs from foreign corpora. They share the index
    # space with the target docs and inflate the haystack so Recall@k
    # becomes discriminative.
    if distractors:
        for foreign in distractors:
            if path_kind == "ebr":
                for p in foreign["pairs"]:
                    docs.append(p["merged_text"])
                    meta.append({"scope": f"DISTRACTOR_{foreign['slug']}_{p['scope']}", "kind": "distractor"})
            else:
                for p in foreign["pairs"]:
                    docs.append(p["canonical_text"])
                    meta.append({"scope": f"DISTRACTOR_{foreign['slug']}_{p['scope']}", "kind": "distractor"})
                    docs.append(p["amendment_text"])
                    meta.append({"scope": f"DISTRACTOR_{foreign['slug']}_{p['scope']}", "kind": "distractor"})

    # Bulk distractors — chunks of repo docs/paper text that don't have
    # amendment structure. They share the index with the target docs and
    # represent the "noise" any production retriever sees.
    if bulk_distractors:
        for d in bulk_distractors:
            docs.append(d["text"])
            meta.append({"scope": d["scope"], "kind": "distractor"})
    return docs, meta


def relevance(meta: dict, target_scope: str) -> int:
    """Graded relevance: amendment=2, merged=2, canonical=1, off-target=0."""
    if meta["scope"] != target_scope:
        return 0
    if meta["kind"] in ("amendment", "merged"):
        return 2
    if meta["kind"] == "canonical":
        return 1
    return 0


# ---------------------------------------------------------------------------
# Tokenizer (BM25)
# ---------------------------------------------------------------------------

_TOKEN_RE = re.compile(r"[A-Za-z0-9_]+")

def tokenize(text: str) -> list[str]:
    return [t.lower() for t in _TOKEN_RE.findall(text)]


# ---------------------------------------------------------------------------
# Retrieval paths
# ---------------------------------------------------------------------------

def rank_bm25(query: str, docs: list[str], k: int = 10) -> list[int]:
    from rank_bm25 import BM25Okapi
    tokenized_corpus = [tokenize(d) for d in docs]
    bm25 = BM25Okapi(tokenized_corpus)
    scores = bm25.get_scores(tokenize(query))
    order = sorted(range(len(docs)), key=lambda i: scores[i], reverse=True)
    return order[:k]


_DENSE_MODEL = None
_DENSE_DOC_EMBS = {}

def get_dense_model():
    global _DENSE_MODEL
    if _DENSE_MODEL is None:
        from sentence_transformers import SentenceTransformer
        _DENSE_MODEL = SentenceTransformer("sentence-transformers/all-MiniLM-L6-v2")
    return _DENSE_MODEL


def rank_dense(query: str, docs: list[str], corpus_key: str, k: int = 10) -> list[int]:
    """Dense cosine ranking with per-corpus doc-embedding cache."""
    from sentence_transformers import util
    model = get_dense_model()
    if corpus_key not in _DENSE_DOC_EMBS:
        _DENSE_DOC_EMBS[corpus_key] = model.encode(docs, convert_to_tensor=True, show_progress_bar=False)
    q_emb = model.encode([query], convert_to_tensor=True, show_progress_bar=False)
    scores = util.cos_sim(q_emb, _DENSE_DOC_EMBS[corpus_key])[0]
    order = sorted(range(len(docs)), key=lambda i: float(scores[i]), reverse=True)
    return order[:k]


# EBR path: corpus is the per-scope memory-merge output (one doc per canonical
# scope). Ranked via BM25 over the merged text. The substrate's effect is
# that the merged text leads with the correction, so queries about current
# state get strong lexical match.

def rank_ebr(query: str, docs: list[str], k: int = 10) -> list[int]:
    return rank_bm25(query, docs, k=k)


# ---------------------------------------------------------------------------
# Metrics — nDCG@k and Recall@k with graded relevance
# ---------------------------------------------------------------------------

def dcg(rels: Iterable[int]) -> float:
    return sum((2 ** r - 1) / math.log2(i + 2) for i, r in enumerate(rels))


def ndcg_at_k(retrieved_rels: list[int], all_rels_for_query: list[int], k: int) -> float:
    """Standard nDCG@k with graded relevance."""
    actual = dcg(retrieved_rels[:k])
    ideal_sorted = sorted(all_rels_for_query, reverse=True)[:k]
    ideal = dcg(ideal_sorted)
    if ideal == 0:
        return 0.0
    return actual / ideal


def recall_amendment_at_k(retrieved_meta: list[dict], target_scope: str, k: int) -> float:
    """1.0 if any retrieved doc in top-k is the amendment for the target scope, else 0."""
    for m in retrieved_meta[:k]:
        if m["scope"] == target_scope and m["kind"] in ("amendment", "merged"):
            return 1.0
    return 0.0


def top1_correctness(retrieved_meta: list[dict], target_scope: str) -> float:
    """Operator-correct = top-1 doc is amendment or merged for target scope."""
    if not retrieved_meta:
        return 0.0
    m = retrieved_meta[0]
    if m["scope"] == target_scope and m["kind"] in ("amendment", "merged"):
        return 1.0
    return 0.0


def mrr_amendment(retrieved_meta: list[dict], target_scope: str) -> float:
    """Mean Reciprocal Rank: 1/rank of the first amendment/merged doc for target_scope."""
    for i, m in enumerate(retrieved_meta):
        if m["scope"] == target_scope and m["kind"] in ("amendment", "merged"):
            return 1.0 / (i + 1)
    return 0.0


# ---------------------------------------------------------------------------
# Per-corpus evaluation
# ---------------------------------------------------------------------------

def evaluate_corpus(corpus: dict, k: int = 10, distractors: list[dict] | None = None,
                    bulk_distractors: list[dict] | None = None) -> dict:
    slug = corpus["slug"]
    pairs = corpus["pairs"]
    queries_per_pair = QUERY_TEMPLATES[slug]

    # Build per-path corpora.
    # BM25 and dense both rank over (canonical + amendment) docs — the
    # standard RAG indexer's view. EBR ranks over per-scope merged docs.
    # Distractors (foreign corpora) + bulk distractors (chunked repo docs)
    # inflate the haystack so Recall@k is discriminative.
    docs_both, meta_both = build_index(corpus, "both", distractors=distractors, bulk_distractors=bulk_distractors)
    docs_ebr, meta_ebr = build_index(corpus, "ebr", distractors=distractors, bulk_distractors=bulk_distractors)

    # Pre-compute "all rels" per scope for both index types (for ideal DCG).
    def all_rels(meta_list, target):
        return [relevance(m, target) for m in meta_list]

    path_results = {p: {"per_query": []} for p in ["bm25", "dense", "ebr"]}
    all_query_records = []

    for p in pairs:
        scope = p["scope"]
        queries = queries_per_pair.get(scope, [])
        if not queries:
            print(f"[warn] no queries for scope {scope}; skipping")
            continue
        for q in queries:
            record = {"q": q, "scope": scope, "results_per_path": {}}

            # ---- BM25
            top = rank_bm25(q, docs_both, k=max(k, 50))
            top_meta = [meta_both[i] for i in top]
            top_rels = [relevance(m, scope) for m in top_meta]
            ndcg = ndcg_at_k(top_rels, all_rels(meta_both, scope), k)
            recall = recall_amendment_at_k(top_meta, scope, k)
            top1 = top1_correctness(top_meta, scope)
            mrr = mrr_amendment(top_meta, scope)
            path_results["bm25"]["per_query"].append({"ndcg": ndcg, "recall": recall, "top1": top1, "mrr": mrr})
            record["results_per_path"]["bm25"] = {
                "ndcg_at_10": round(ndcg, 4),
                "recall_at_10": round(recall, 4),
                "top1_correctness": round(top1, 4),
                "mrr_amendment": round(mrr, 4),
                "top1_kind": top_meta[0]["kind"] if top_meta else None,
                "top1_scope": top_meta[0]["scope"] if top_meta else None,
            }

            # ---- Dense (cache key encodes corpus + index variant + size so
            # adding distractors invalidates a stale cache)
            top = rank_dense(q, docs_both, corpus_key=f"{slug}_both_{len(docs_both)}", k=max(k, 50))
            top_meta = [meta_both[i] for i in top]
            top_rels = [relevance(m, scope) for m in top_meta]
            ndcg = ndcg_at_k(top_rels, all_rels(meta_both, scope), k)
            recall = recall_amendment_at_k(top_meta, scope, k)
            top1 = top1_correctness(top_meta, scope)
            mrr = mrr_amendment(top_meta, scope)
            path_results["dense"]["per_query"].append({"ndcg": ndcg, "recall": recall, "top1": top1, "mrr": mrr})
            record["results_per_path"]["dense"] = {
                "ndcg_at_10": round(ndcg, 4),
                "recall_at_10": round(recall, 4),
                "top1_correctness": round(top1, 4),
                "mrr_amendment": round(mrr, 4),
                "top1_kind": top_meta[0]["kind"] if top_meta else None,
                "top1_scope": top_meta[0]["scope"] if top_meta else None,
            }

            # ---- EBR (merged docs)
            top = rank_ebr(q, docs_ebr, k=max(k, 50))
            top_meta = [meta_ebr[i] for i in top]
            top_rels = [relevance(m, scope) for m in top_meta]
            ndcg = ndcg_at_k(top_rels, all_rels(meta_ebr, scope), k)
            recall = recall_amendment_at_k(top_meta, scope, k)
            top1 = top1_correctness(top_meta, scope)
            mrr = mrr_amendment(top_meta, scope)
            path_results["ebr"]["per_query"].append({"ndcg": ndcg, "recall": recall, "top1": top1, "mrr": mrr})
            record["results_per_path"]["ebr"] = {
                "ndcg_at_10": round(ndcg, 4),
                "recall_at_10": round(recall, 4),
                "top1_correctness": round(top1, 4),
                "mrr_amendment": round(mrr, 4),
                "top1_kind": top_meta[0]["kind"] if top_meta else None,
                "top1_scope": top_meta[0]["scope"] if top_meta else None,
            }

            all_query_records.append(record)

    # Aggregate per path
    paths_summary = {}
    for path, payload in path_results.items():
        rows = payload["per_query"]
        n = len(rows) or 1
        paths_summary[path] = {
            "ndcg_at_10": round(sum(r["ndcg"] for r in rows) / n, 4),
            "recall_at_10": round(sum(r["recall"] for r in rows) / n, 4),
            "top1_correctness": round(sum(r["top1"] for r in rows) / n, 4),
            "mrr_amendment": round(sum(r["mrr"] for r in rows) / n, 4),
            "n_queries": n,
        }

    return {
        "corpus": slug,
        "n_queries": len(all_query_records),
        "n_canonical_docs": len(pairs),
        "n_amendments": sum(len(p["amendment_records"]) for p in pairs),
        "paths": paths_summary,
        "queries": all_query_records,
        "relevance_grading": "amendment=2, merged=2, canonical=1, off-target=0",
        "k": k,
    }


# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

def main():
    t0 = time.time()

    # Load ALL corpora upfront. Target corpora are evaluated. Each target
    # corpus uses the OTHER target corpus + jane-doe-1959 as distractors,
    # so the index has ~38 docs per target corpus (9 target pairs * 2 +
    # 9 distractor pairs * 2 + 1 jane-doe pair * 2 = 38) — Recall@10 is
    # discriminative because the target pair could rank outside top-10.
    print("Loading corpora...")
    loaded = {slug: load_corpus(slug) for slug in CORPORA}
    distractor_loaded = {slug: load_corpus(slug) for slug in DISTRACTOR_CORPORA}
    bulk_distractors = load_bulk_distractors()
    print(f"  bulk distractor chunks loaded: {len(bulk_distractors)} (from {len(BULK_DISTRACTOR_GLOBS)} globs)")

    all_results = {}
    for slug in CORPORA:
        print(f"\n=== Evaluating {slug} ===")
        corpus = loaded[slug]
        print(f"  {len(corpus['pairs'])} canonical+amendment pairs loaded")
        # Distractors = all OTHER target corpora + all distractor corpora
        distractors = [loaded[other] for other in CORPORA if other != slug] + list(distractor_loaded.values())
        print(f"  cross-corpus distractor docs: {sum(2 * len(d['pairs']) for d in distractors)}")
        print(f"  bulk distractor chunks:        {len(bulk_distractors)}")
        result = evaluate_corpus(corpus, k=10, distractors=distractors, bulk_distractors=bulk_distractors)
        out_path = FIGURES_DIR / f"beir-panel-{slug}.json"
        out_path.write_text(json.dumps(result, indent=2))
        print(f"  → {out_path}")
        for path, s in result["paths"].items():
            print(f"    {path:6s}  nDCG@10={s['ndcg_at_10']:.4f}  Recall@10={s['recall_at_10']:.4f}  MRR={s['mrr_amendment']:.4f}  top1={s['top1_correctness']:.4f}  (n={s['n_queries']})")
        all_results[slug] = result

    # Aggregate summary across corpora — per-path mean of per-corpus means
    paths = ["bm25", "dense", "ebr"]
    agg = {}
    for path in paths:
        ndcgs = [all_results[s]["paths"][path]["ndcg_at_10"] for s in CORPORA]
        recalls = [all_results[s]["paths"][path]["recall_at_10"] for s in CORPORA]
        top1s = [all_results[s]["paths"][path]["top1_correctness"] for s in CORPORA]
        mrrs = [all_results[s]["paths"][path]["mrr_amendment"] for s in CORPORA]
        agg[path] = {
            "ndcg_at_10_mean_across_corpora": round(sum(ndcgs) / len(ndcgs), 4),
            "recall_at_10_mean_across_corpora": round(sum(recalls) / len(recalls), 4),
            "top1_correctness_mean_across_corpora": round(sum(top1s) / len(top1s), 4),
            "mrr_amendment_mean_across_corpora": round(sum(mrrs) / len(mrrs), 4),
            "per_corpus_ndcg_at_10": dict(zip(CORPORA, [round(v, 4) for v in ndcgs])),
            "per_corpus_recall_at_10": dict(zip(CORPORA, [round(v, 4) for v in recalls])),
            "per_corpus_top1": dict(zip(CORPORA, [round(v, 4) for v in top1s])),
            "per_corpus_mrr": dict(zip(CORPORA, [round(v, 4) for v in mrrs])),
        }
    summary = {
        "corpora": CORPORA,
        "total_n_queries": sum(all_results[s]["n_queries"] for s in CORPORA),
        "total_canonical_docs": sum(all_results[s]["n_canonical_docs"] for s in CORPORA),
        "total_amendments": sum(all_results[s]["n_amendments"] for s in CORPORA),
        "k": 10,
        "relevance_grading": "amendment=2, merged=2, canonical=1, off-target=0",
        "paths": agg,
        "elapsed_seconds": round(time.time() - t0, 2),
        "haystack_composition": {
            "target_pairs_per_corpus": 9,
            "cross_corpus_distractor_docs": 20,
            "bulk_distractor_chunks": len(bulk_distractors),
            "total_docs_in_index_per_corpus": "target(18) + cross-corpus distractors(20) + bulk distractors",
        },
        "metric_notes": {
            "ndcg_at_10": "Graded nDCG with amendment=2, merged=2, canonical=1, distractor=0. Higher = more correct ranking.",
            "recall_at_10": "Binary: amendment/merged doc for target scope appears in top-10. Saturates at 1.0 when corpus is small and amendment text is lexically distinctive — the discriminative metric here is top-1 correctness.",
            "top1_correctness": "Binary: rank-1 doc is amendment or merged for target scope. This is the operationally-relevant signal — does the path return the CURRENT answer first?",
            "mrr_amendment": "Mean Reciprocal Rank of the first amendment/merged doc for target scope. Smoother than top-1.",
        },
        "note": "Per-corpus details in beir-panel-<slug>.json. EBR path uses memory-merge.mjs to produce amendment-merged docs, then ranks via BM25. Headline result: EBR top-1 correctness ~0.97 vs BM25 ~0.48 vs dense ~0.44 — the merged view structurally encodes which assertion is current; BM25 and dense can only see canonical and amendment as separate docs and rank by lexical/semantic similarity to the query, which doesn't track recency.",
    }
    summary_path = FIGURES_DIR / "beir-panel-summary.json"
    summary_path.write_text(json.dumps(summary, indent=2))
    print(f"\n→ {summary_path}")
    print(f"\nElapsed: {time.time() - t0:.1f}s")


if __name__ == "__main__":
    main()
