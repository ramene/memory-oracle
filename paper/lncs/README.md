# Springer LNCS paper — build instructions

> Target venue: **ICAIMH 2026** (https://2026.icaimh.org/call-papers)

## Files

- `main.tex` — full paper skeleton with all 10 sections drafted
- `references.bib` — bibliography (some entries marked TODO for final citation polish)
- `../figures/` — figure PNGs referenced by `\includegraphics{}`
- `../notebook/` — Deepnote notebook producing the empirical figures

## Build locally

Requires TeX Live (or MacTeX, MikTeX) with the Springer `llncs.cls` and
`splncs04.bst` files. These are distributed by Springer; download from:
https://www.springer.com/gp/computer-science/lncs/conference-proceedings-guidelines

Place `llncs.cls` and `splncs04.bst` alongside `main.tex`, then:

```bash
cd paper/lncs
latexmk -pdf main.tex
# or:
pdflatex main.tex && bibtex main && pdflatex main.tex && pdflatex main.tex
```

Output: `main.pdf` (~15-18 pages).

## Build on Overleaf (recommended for review/co-authors)

1. Create new project on https://www.overleaf.com
2. Choose template: **Springer LNCS** (Overleaf has it pre-installed)
3. Replace the template's `main.tex` with this one
4. Upload `references.bib`
5. Upload `../figures/F1-consent-gesture.png`, etc. (paths in `main.tex` use
   `\includegraphics{../figures/...}` — adjust to flat layout if Overleaf
   needs it)
6. Compile

## Figure regeneration

The four figures referenced in the paper are produced by the Deepnote
notebook at `../notebook/empirical-evaluation.ipynb`. Re-run that notebook
to refresh figures with current measurements.

## What's drafted vs what's TODO

| Section | Status |
|---|---|
| Abstract | drafted |
| §1 Introduction | drafted |
| §2 Related Work | drafted, bib TODO on TurboQuant + Karpathy URLs |
| §3 Architecture | drafted with code snippets |
| §4 Trust Model | drafted with table + equation |
| §5 Clinical Case Study | drafted with Theorem 1 (precedence invariant) |
| §6 Cross-Domain Generalization | drafted |
| §7 Implementation | drafted, figures F1/F2/F3 placeholder PNGs needed |
| §8 Empirical Evaluation | drafted, figure F4 + 1000-query measurement pending notebook |
| §9 Discussion | drafted |
| §10 Conclusion | drafted |

## Co-authors needed

Section authors-of-record. Tentative slots:
- Clinical co-author for §5 + §6 (verification of clinical accuracy + EHR
  framing in §2)
- Privacy/crypto co-author for §4 + §7.7 (formal review of key derivation + SSS
  integration)
- (Optional) Systems co-author for §3 + §7 (BM25 vs vector RAG framing)

## Submission timeline

| Milestone | Target |
|---|---|
| Skeleton + abstract (this) | 2026-05-17 |
| Deepnote notebook + figure generation | 2026-05-19 |
| Co-author drafts circulated | 2026-05-25 |
| Internal revisions | 2026-05-30 |
| ICAIMH 2026 submission | per their CFP (verify exact date) |
