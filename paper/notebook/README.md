# Empirical evaluation notebook

The runnable notebooks now live in this repository at
[`notebooks/memory-oracle/`](../../notebooks/memory-oracle/) — see the README
there for the three-mode auto-detect setup (local, Colab, Deepnote) and the
Colab badges that resolve anonymously.

This directory retains only the produced figures (`../figures/`) that the
LaTeX build needs via `\includegraphics{}`. To regenerate them:

```bash
# from the memory-oracle repo root
cd notebooks/memory-oracle
jupyter nbconvert --to notebook --execute empirical-evaluation.ipynb \
  --output empirical-evaluation.executed.ipynb
cp figures/F3-latency.png ../../paper/figures/
```

See [`notebooks/memory-oracle/README.md`](../../notebooks/memory-oracle/README.md)
for the full instructions.
