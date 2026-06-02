# Clinical nDCG@10 derivation — §8 Context Relevance metric

Cited from `paper/lncs/main.tex` §\ref{sec:clinical-three-path}, Table~\ref{tab:clinical-three-path}.

## Setup

The `jane-doe-1959` synthetic patient fixture, queried with the 10
reversal-agent prompts in
`notebooks/memory-oracle/figures/clinical-baseline-summary.json`.
Within the meds scope, the corpus contains two documents that match
graded relevance:

| Document | Graded relevance |
|---|---|
| `meds.md.amendments.jsonl` (warfarin → apixaban, 2026-01-14, Dr. Y. Chen) | **2** |
| `meds.md` (2008 warfarin canonical) | **1** |
| other scope docs (allergies, past-procedures, recent-labs) | 0 |

The other scope canonicals are treated as 0-relevance distractors in
the top-10 ranking pool for nDCG.

## Ideal DCG (IDCG@10)

Optimal ordering places amendment at rank 1, canonical at rank 2:

```
IDCG@10 = 2/log₂(2) + 1/log₂(3)
        = 2/1 + 1/1.585
        = 2.000 + 0.631
        = 2.631
```

## EBR

Theorem 1 (Precedence Invariant): amendment block prepended to merged
output → amendment at rank 1, canonical at rank 2 in 100% of queries.

```
DCG@10 = 2/log₂(2) + 1/log₂(3) = 2.631
nDCG@10 = 2.631 / 2.631 = 1.000
```

## Vector-RAG (sentence-transformers/all-MiniLM-L6-v2)

Per `clinical-baseline-summary.json`: canonical wins top-1 in 9/10 queries
(stronger lexical overlap with reversal vocabulary), amendment wins
top-1 in 1/10. Assuming amendment sits at rank 2 in the 9/10 cases
(conservative upper bound — distractor scopes do not displace it):

- 9/10 queries: canonical rank 1, amendment rank 2
  ```
  DCG = 1/log₂(2) + 2/log₂(3) = 1.000 + 1.262 = 2.262
  nDCG = 2.262 / 2.631 = 0.860
  ```
- 1/10 queries: amendment rank 1, canonical rank 2
  ```
  nDCG = 1.000
  ```
- Average across the 10-query panel:
  ```
  nDCG@10 = (9 × 0.860 + 1 × 1.000) / 10
          = (7.74 + 1.00) / 10
          = 0.874
  ```

## LLM-only

No retrieval → no ranked list → nDCG undefined. Reported as 0.000 to
preserve the binary correctness frame (an LLM with no retrieval cannot
score Context Relevance points).

## Recall@10

For the 2-document case-study corpus (within scope), Recall@10 = 1.000
for any path that returns ≥2 documents. Both vector-RAG and EBR
trivially clear this. LLM-only returns no documents → Recall@10 = 0.000.

This is the Galileo distinction made concrete: vector-RAG has Context
Sufficiency (Recall@10 = 1.0) but lacks Context Relevance (nDCG@10 =
0.874) because the docs are in the wrong order. EBR moves Context
Relevance to ceiling (nDCG@10 = 1.000) without regressing Recall.

## Reproducibility

These numbers can be recomputed by re-running the published Deepnote
notebook (`notebooks/memory-oracle/clinical-case-study.ipynb`) with
graded relevance scoring added to the existing top-1 output. The
nDCG@10 = 0.874 figure for vector-RAG is an analytic upper bound; the
empirical value when the distractor scopes are included in the ranking
pool will be ≤ 0.874. We will publish the recomputed empirical value
in the BEIR-style cross-corpus panel (in-flight, see Task #75 part 3).
