# From Forgetting to Amending

> *Evidence-Bound Retrieval as Episodic Memory for Language Agents — a short companion to the position paper.*

There's a moment about eight minutes into IBM Technology's [most recent video on AI agent memory](https://youtu.be/BacJ6sEhqMo) where Tom, the presenter, lays out Princeton's CoALA framework — working, semantic, procedural, episodic — and then pauses on the last one.

> *"Episodic memory is also the hardest type of these to get right because what do you delete? When does information become obsolete?"*

A beat later he says the line that should make anyone shipping production agents stop scrolling:

> *"Humans are actually pretty good at forgetting … but for agents, forgetting is an engineering problem."*

I think Tom is right that forgetting is hard. I think he's wrong that forgetting is the problem to engineer.

## The wrong question

The CoALA framework ([Sumers, Yao, Narasimhan, Griffiths, 2024](https://arxiv.org/abs/2309.02427)) gave us the cleanest vocabulary we have for talking about agent memory. Working = the context window. Semantic = the durable knowledge files (your `CLAUDE.md`, your project README). Procedural = the skills (`skill.md` folders). Episodic = the record of what happened across sessions and what should be remembered.

The framework also flagged episodic as the hardest, and production systems landed on one answer: **distillation**. Don't save the whole transcript. Compress each session into a remembered shape. Decide what's worth keeping. Throw the rest away.

That answer puts the substrate in the position of having to *choose* between past evidence and present evidence — and choose irreversibly, and choose by a heuristic. When a fact you summarised three months ago turns out to be wrong today, the distillation framing offers two moves: edit the summary in place (destroying the audit trail) or store the new fact and hope retrieval picks the right one (it won't, reliably — embeddings rank by similarity, not by recency, and the canonical document is usually the higher-similarity match).

This is the wrong question. The hard part isn't *what to forget*. The hard part is *what should still be believed when two facts disagree.*

## The right question, and the boring answer

The answer to "what should still be believed" doesn't need a model. It needs a file-layout convention and a merge order.

```
~/.claude/projects/your-project/memory/
├── medication_anticoagulant.md                       ← canonical, never edited
└── medication_anticoagulant.md.amendments.jsonl     ← corrections, append-only
```

Every time an operator (a clinician, a trader, a senior engineer) discovers that a fact has changed, they write an **amendment record** — one JSON line, dated and signed, with the new assertion and a pointer to the live evidence:

```json
{
  "amended_at":         "2026-03-14T11:02:00Z",
  "amended_by":         "Dr. Reyes, MD",
  "superseded_assertion": "Patient is on warfarin 5 mg/day.",
  "corrected_assertion":  "Patient transitioned to apixaban 5 mg BID on 2026-03-12.",
  "live_evidence":      "EHR/encounter/E-71412/note-2.txt#L42",
  "operator_confirmed": true
}
```

The substrate's merge routine reads the canonical and the sidecar together. The amendments are sorted descending by date and **prepended** to the canonical body before the text reaches the agent. That's the whole mechanism. The structural precedence is read off the merge code in one inspection. No critic forward pass. No similarity tiebreak. No prayer that the embedding happens to rank the right document.

I call this property **Evidence-Bound Retrieval (EBR)**: every retrieval is bound to the most recent operator-authored evidence by construction. The position paper formalises the invariant and shows how EBR slots into CoALA's episodic layer.

## Why this matters in concrete terms

Two examples:

**Clinical.** A patient is on warfarin per the 2008 chart note. The 2024 cardiology consult switched her to apixaban; vitamin K does not reverse apixaban (you need andexanet alfa). She bleeds, the team asks the AI-augmented EHR what to give. Vector RAG ranks the 2008 note higher than the 2024 consult because the older note is longer and the lexical overlap is stronger. The team orders FFP and vitamin K. Neither works. EBR returns the 2024 amendment first — by construction.

**Trading.** A trading agent on KuCoin spot saw a bearish signal and tried to short DUCK-USDT, dropping $206 in seven minutes against a hard no-shorting rule the operator had written *that morning.* The rule lived in the memory file. The agent didn't read it first because the canonical strategy document outranked the new rule under similarity scoring. With EBR, the new rule is the amendment — it's at the top of the merged retrieval. The agent never gets to "sell DUCK."

Both scenarios resolve the same way: when the operator writes a correction, the correction wins.

## The numbers, briefly

On a synthetic stress test of N=1,000 queries across clinical and trading vaults, EBR returned the post-amendment assertion on 100% of queries. Vector-RAG returned it on 10%. A control LLM with no retrieval scored 0%. The 100% is not because EBR is clever — it's because Theorem 1 in the position paper says it has to be 100%. The merge is deterministic.

On my own live substrate — 239 documents across 21 projects over 108 days of normal work — six known cross-session corrections were probed. All 6/6 were retrievable in keyword search with median latency 257ms. The substrate works on operator-authored content the way the synthetic vaults predict.

## What the position paper does

The full [position paper](../coala-extension/main.tex) makes the argument in academic shape:

- It cites CoALA explicitly and positions EBR as **extension, not replacement** — EBR slots into CoALA's episodic layer; the other three layers (working / semantic / procedural) are untouched.
- It states the precedence invariant as a theorem and gives a proof sketch (the proof is one paragraph because the invariant is structural).
- It summarises the empirical evidence from the companion clinical-AI [manuscript](../lncs/main.tex) without re-running the experiments.
- It outlines open problems: multi-author amendment provenance, cryptographic signing of amendment chains, cross-substrate amendment portability, index hygiene for long amendment histories.

It's a workshop-length paper — ~6 pages, intended for the NeurIPS workshops on Foundation Models for Decision Making, ICLR workshop tracks, or the ACL position-paper track. It's a direct response to the question Sumers et al. left open.

## Three asks

If you're working in CoALA-aligned agent architectures:

1. **Read the position paper** ([`paper/coala-extension/main.tex`](../coala-extension/main.tex)) and tell me where the argument breaks.
2. **Adopt the amendment-record convention** in your substrate. The file layout is two paths and a JSONL schema; nothing else needs to change. If you ship one, [open an issue](https://github.com/ramene/memory-oracle/issues) with a pointer and I'll link it from the repo.
3. **Extend the invariant.** The current spec handles single-author precedence by timestamp. Multi-author co-signed amendments, cryptographically signed amendment chains, and cross-substrate portability are open and citeable problems.

## The substrate is small on purpose

The reference implementation is a file-layout convention plus a deterministic merge routine. That's it. No model. No trained critic. No reinforcement loop. The whole substrate is auditable by reading the merge code once.

That smallness is the argument. Episodic memory under CoALA does not need to be a model. It can be a discipline about how files are laid out and read.

The repo is [`ramene/memory-oracle`](https://github.com/ramene/memory-oracle), MIT-licensed. The position paper lives at `paper/coala-extension/`. The main clinical-AI manuscript that produced the empirical numbers is at `paper/lncs/`. The Jupyter notebooks that produced the figures run on Colab Free.

If forgetting is the engineering problem you're trying to solve — I'd argue you're solving the wrong one. Solve *amending* instead.

---

**Position paper:** *Evidence-Bound Retrieval: A Substrate for CoALA's Episodic Memory Layer.* [`paper/coala-extension/main.tex`](../coala-extension/main.tex)

**Companion manuscript:** *Evidence-Bound Retrieval for Clinical AI: An Accretive Memory Substrate with Patient-Owned Keys.* [`paper/lncs/main.tex`](../lncs/main.tex)

**Reference implementation:** [`github.com/ramene/memory-oracle`](https://github.com/ramene/memory-oracle)

**CoALA source:** Sumers, Yao, Narasimhan, Griffiths. *Cognitive Architectures for Language Agents.* TMLR 2024. [arXiv:2309.02427](https://arxiv.org/abs/2309.02427)
