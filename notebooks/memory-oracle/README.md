# memory-oracle notebooks

Companion notebooks to the Springer LNCS paper *Memory That Argues With Itself: Accretive Supersession for AI Agent Retrieval* (Ramene, 2026). **Public — anonymous Colab clicks work.**

## Three notebooks, two case studies, one substrate

| Notebook | Paper section | Open in Colab |
|---|---|---|
| **`clinical-case-study.ipynb`** — the canonical case study: synthetic Jane Doe patient vault + N=1000 precedence verification + ER-reversal vector-RAG baseline + dual-device demo trace + clinical-required three-path correctness | §5 Clinical Case Study | [![Open in Colab](https://colab.research.google.com/assets/colab-badge.svg)](https://colab.research.google.com/github/ramene/memory-oracle/blob/main/notebooks/memory-oracle/clinical-case-study.ipynb) |
| **`trading-case-study.ipynb`** — the second case study: synthetic Alex Cohen trader vault + N=1000 precedence verification + shorting-required three-path correctness + live cross-session correction trace | §6 Cross-Domain Generalization | [![Open in Colab](https://colab.research.google.com/assets/colab-badge.svg)](https://colab.research.google.com/github/ramene/memory-oracle/blob/main/notebooks/memory-oracle/trading-case-study.ipynb) |
| **`empirical-evaluation.ipynb`** — substrate-level measurements (latency, precedence invariant, vector-RAG baseline against operator corpus, cross-session capture, self-improvement trail, three-tier comparison, lock-contention recovery) | §8 Empirical Evaluation | [![Open in Colab](https://colab.research.google.com/assets/colab-badge.svg)](https://colab.research.google.com/github/ramene/memory-oracle/blob/main/notebooks/memory-oracle/empirical-evaluation.ipynb) |

## Three run modes (auto-detected)

The setup cell of each notebook auto-detects which environment it's in:

| Mode | Detection | What it does |
|---|---|---|
| **Local** | `~/.local/share/journal/.memory-index.db` exists AND `~/.bin/memory-search.mjs` exists | Uses the operator's live index + binaries. All sections runnable, including §5-§6 (which need operator corpus). |
| **Google Colab** | `google.colab` is importable | Installs Node 20 LTS via NodeSource, `git clone memory-oracle`, builds isolated index against the synthetic vault, mounts Google Drive for output persistence (`/content/drive/MyDrive/memory-oracle-figures/`). Operator-corpus sections skipped. |
| **Deepnote / generic CI** | neither of the above | Same bootstrap as Colab without Drive. Operator-corpus sections skipped. |

## Local execution

```bash
git clone https://github.com/ramene/memory-oracle
cd memory-oracle/notebooks/memory-oracle
python3 -m venv .venv && source .venv/bin/activate
pip install pandas matplotlib jupyter sentence-transformers
jupyter nbconvert --to notebook --execute empirical-evaluation.ipynb --output empirical-evaluation.executed.ipynb
jupyter nbconvert --to notebook --execute trading-case-study.ipynb --output trading-case-study.executed.ipynb
```

## Paper-quality run checklist

- [x] N=1000 in precedence cells (both notebooks)
- [x] `sentence-transformers/all-MiniLM-L6-v2` baseline (both notebooks)
- [x] Colab badges live, three-mode auto-detect
- [x] Public repo so anonymous Colab clicks work for paper readers
- [ ] Re-execute both notebooks end-to-end
- [ ] Commit produced `figures/*.png` + `figures/*.json`
- [ ] Copy PNG figures into `../../paper/figures/`
- [ ] Transcribe JSON values into §6 + §8 prose of `../../paper/lncs/main.tex`

## Provenance

Both notebooks moved here from `ramene/mae-notebooks` (private) on 2026-05-24 so the paper's reproducibility badges work for anonymous reviewers. The earlier moves: `empirical-evaluation.ipynb` was originally at `memory-oracle/paper/notebook/` (2026-05-15), moved to `mae-notebooks/memory-oracle/` (2026-05-17) for Deepnote sync, now back to `memory-oracle/notebooks/memory-oracle/` (this file). `trading-case-study.ipynb` was authored 2026-05-24 as the second case study (the trading parallel of the clinical warfarin → apixaban). Deepnote Teams subscription cancelled in favor of Colab Free, saving $50/mo.
