# Empirical evaluation notebook — moved

The runnable notebook now lives in [`ramene/mae-notebooks`](https://github.com/ramene/mae-notebooks) at `memory-oracle/empirical-evaluation.ipynb` — that repo is Deepnote-synced and is the source of truth for research code.

This directory retains only the produced figures (`../figures/`) that the LaTeX build needs via `\includegraphics{}`. To regenerate them:

```bash
cd ~/.remote/github.com/@ramene/mae-notebooks/memory-oracle
jupyter nbconvert --to notebook --execute empirical-evaluation.ipynb \
  --output empirical-evaluation.executed.ipynb
cp figures/F3-latency.png ../../memory-oracle/paper/figures/
```

See `mae-notebooks/memory-oracle/README.md` for full instructions.
