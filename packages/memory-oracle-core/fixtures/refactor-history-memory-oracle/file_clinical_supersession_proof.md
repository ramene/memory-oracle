---
name: CLINICAL-SUPERSESSION-PROOF-FILES
description: Clinical case-study litmus script and companion markdown.
metadata:
  type: file
  authored_at: 2026-05-01T11:00:00Z
  files:
    - docs/examples/clinical-supersession-proof.md
    - docs/examples/clinical-supersession-proof.sh
---

# docs/examples/clinical-supersession-proof.{md,sh}

The clinical-supersession-proof litmus script + markdown companion
demonstrate the core paper claim on the synthetic jane-doe-1959 vault:
the warfarin → apixaban anticoagulant switch is correctly surfaced as
the current truth via the supersession sidecar mechanism.

Files:
- `docs/examples/clinical-supersession-proof.sh` — executable litmus
- `docs/examples/clinical-supersession-proof.md` — companion writeup

These files are cited from §5 of the paper as the canonical demonstration
of the substrate's clinical correctness invariant.
