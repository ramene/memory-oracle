# Prompt Profile Library

Canonical store for Qwen2.5-VL extraction prompt profiles used by the
video-ingestion notebook. One YAML file per archetype.

## Why this exists

Cell 14 of the notebook used to hold a hardcoded `PROMPT_PROFILES = {...}`
Python dict. Past ~5 profiles, the cell became unwieldy. This directory
moves the canonical store to disk so each profile is one file, diffable,
versionable, and importable from any consumer (the notebook today, the
`mae` CLI tomorrow).

## File shape

Each YAML profile MUST have these top-level keys:

```yaml
name: <kebab-case profile id, matches filename minus .yaml>
applies_to_archetype: <one of: paper-companion-explainer | paper-author-talk |
                       coding-tutorial | product-announcement |
                       trading-education | trading-intelligence | general>
output_schema_version: 1
created_at: YYYY-MM-DD
description: <one-line summary>
tested_against_channels: []  # list of YouTube channel names where this
                             # profile produced populated extraction fields

prompt: |
  <full prompt body the notebook passes to Qwen for each video segment>

channel_hints:                # OPTIONAL — keys are YouTube uploader names
  "Channel Name":             #   matched case-insensitively as substring
    note: |                   #   against the video metadata's `uploader`
      <text appended to the prompt at runtime if uploader matches>
```

## Adding a new profile

1. Copy an existing YAML file as a starting point
2. Pick a fresh kebab-case `name` (must match filename)
3. Write the prompt — STRICT JSON output, no preamble, schema fields tuned
   to the archetype
4. Decide channel_hints if any (don't speculate — seed only channels you've
   actually validated)
5. Commit to memory-oracle
6. Re-import the `.deepnote` file to pick up the new profile (notebook
   loads this directory at runtime)

## The 7 profiles currently shipping

| Profile | Archetype | When to use |
|---|---|---|
| `ai-systems-research.yaml` | paper-companion-explainer | Two Minute Papers, AI Coffee Break, paper explainer videos |
| `paper-author-talk.yaml` | paper-author-talk | NeurIPS / ICML conference talks by the paper's authors themselves |
| `coding-tutorial.yaml` | coding-tutorial | Karpathy-style hands-on walkthroughs, code-is-the-content videos |
| `product-announcement.yaml` | product-announcement | Launch / capability / demo videos from AI labs |
| `trading-education.yaml` | trading-education | Pedagogical trading videos (Warrior, López QuantCon) |
| `trading-intelligence.yaml` | trading-intelligence | Market intel / signal extraction from financial-content videos |
| `general-summary.yaml` | general | Fallback when no archetype matches — short narrative summary |

## Override mechanism

The notebook also supports a `PROMPT_OVERRIDE` Deepnote input block. When
non-empty, it bypasses the profile lookup entirely and uses the override
text verbatim as the prompt. Use this for one-off experiments without
committing a new profile.

## Refs

- Task #117 (this architecture overhaul, 2026-06-05)
- Task #115 (lesson framing template that consumes profile output)
- session 2d097fa8 — AlphaProof Nexus extraction failure with wrong profile that motivated this work
