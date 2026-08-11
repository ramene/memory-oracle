# EBR proof notebook (Demo B)

The executed proof notebook demonstrating EBR / substrate memory — the "Demo B"
of the coalescence campaign (see `arch-notes/coalescence-parallels-campaign-2026-07-13`
and `arch-notes/ex-ebr-proof-board`).

## Contents
- `ebr-proof.executed.ipynb` — the executed proof notebook.
- `final.executed.ipynb` — final executed variant.
- `ebr_cells.py` — the cell source.
- `build_ipynb.py` — generator that assembles the notebook from `ebr_cells.py`.

## Provenance
Built 2026-07-14. Recovered 2026-08-10 from `~/.local/state/agent-scratch/ebr-notebook/`
(no-git, byte md5 `96ef70a64ef3637685cbaa755254d8ca`) during an agent-scratch
divergence audit — it was never in version control. Landed here per the law
[[feedback_work_stranded_in_agent_scratch_is_not_shipped]]: a working artifact
that lives only in scratch is not shipped.
