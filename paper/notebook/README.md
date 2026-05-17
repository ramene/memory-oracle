# Empirical evaluation notebook

> Produces all measurements + figures for §8 of the LNCS paper.

## Run locally with Jupyter

```bash
cd paper/notebook
python3 -m venv .venv && source .venv/bin/activate
pip install pandas matplotlib jupyter notebook
jupyter notebook empirical-evaluation.ipynb
```

Run cells top-to-bottom. Figures land in `../figures/F4-latency.png` etc.

## Run on Deepnote

1. Create a new Deepnote project, upload `empirical-evaluation.ipynb`
2. Add a Python integration; install `pandas matplotlib`
3. Mount the operator's memory-oracle install via SSH (or symlink) so the
   notebook can reach `~/.bin/memory-search.mjs` + the live SQLite index
4. Run cells

## Run on the operator's machine (fastest)

```bash
cd paper/notebook
jupyter nbconvert --to notebook --execute empirical-evaluation.ipynb --output empirical-evaluation.executed.ipynb
```

## What needs filling in for the final paper run

| Cell | Status | Action |
|---|---|---|
| Corpus overview | ✅ works against live index | none |
| Latency Figure 4 | ✅ works | bump trials to 100+ for tighter CIs |
| Precedence invariant | ✅ works at N=200 | bump to N=1000 |
| pgvector baseline | ⏳ stub | install sentence-transformers OR call OpenAI API |
| Self-extension rate | ✅ works | none |

## Cite-from-here in the paper

The notebook's outputs feed §8 of `main.tex`:
- `F4-latency.png` → Figure 4
- Precedence invariant percentage → table or inline number in §8.3
- pgvector baseline number → §8.4 paragraph
- Self-extension count → §8.5 paragraph
