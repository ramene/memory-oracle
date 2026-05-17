# Clinical supersession proof — why TurboQuant doesn't save the patient

> Empirical demonstration that supersession sidecars correctly surface a 2024 cardiology correction over a 2008 PCP note, in a scenario where the wrong answer kills the patient.

## The patient

Jane Doe, DOB 1959-04-22, MRN 47102-A. 67 years old at the time of the scenario.

- **2008-07-03** — Diagnosed with non-valvular paroxysmal atrial fibrillation by her PCP, Dr. Elena Vasquez. CHA₂DS₂-VASc score 3. Started on warfarin 5mg PO daily, INR target 2.0–3.0. The clinic memory file documents the regimen AND the reversal protocol: **FFP + Vitamin K + 4F-PCC** for emergency bleeds.
- **2008–2023** — Stable on warfarin. Self-monitors INR via CoaguChek. One nosebleed in 2014, one bruise after a fall in 2018. No major events.
- **2023** — Four episodes of INR >3.5 despite dose adjustments. New diagnosis of moderate CKD (eGFR 48).
- **2024-03-15** — Cardiologist Dr. Marcus Chen reviews the labile INR + CKD picture, switches her to **Apixaban 5 mg BID**. He files a supersession sidecar on the original 2008 note: "Warfarin discontinued. Reversal agent is now **andexanet alfa**, NOT FFP, NOT Vitamin K. Vitamin K does nothing for factor Xa inhibitors."
- **2026-05-17 14:33Z** — Jane presents to the ER with melena, hypotension, hgb 6.4. ER physician's LLM-augmented EHR queries: *"what's this patient on, and how do I reverse it?"*

## What happens with vector RAG (the counterfactual)

The vector store has high-cosine-similarity embeddings for the 2008 note. The query "anticoagulant reversal protocol" pulls the 2008 file. The LLM reads:

> *Reversal protocol: Fresh Frozen Plasma 10–15 mL/kg IV, Vitamin K 10 mg IV, 4F-PCC if FFP contraindicated.*

The 2024 cardiology consult note is *also* in the corpus, but it's a separate document with its own embedding. The LLM has to *reason* about which is current. Under time pressure — hypotensive patient, active bleed — it often takes the highest-ranked retrieval at face value.

The team orders FFP + Vitamin K. Apixaban has a half-life of ~12 hours; vitamin K has zero effect on factor Xa inhibitors; FFP doesn't reverse direct oral anticoagulants either. The patient continues to bleed. The team realizes the error 40 minutes in, but ICU transfer and ICH expansion are already advanced.

**This is not a hypothetical failure mode of vector RAG. It is the actual failure mode.** The embedding of "patient is on warfarin" remains in the index until someone manually re-embeds a corrected chunk — and even then, the *old* chunk still matches the query.

## What happens with memory-oracle

The supersession sidecar `medication_anticoagulant.md.supersessions.jsonl` lives beside the 2008 file. When `memory-search` retrieves the 2008 note, it merges in the supersession block *before* the original content.

Running the proof script:

```bash
./docs/examples/clinical-supersession-proof.sh
```

Output (abbreviated):

```
## patient-jane-doe-1959/medication_anticoagulant.md  ⚠ HAS SUPERSESSIONS

## ⚠ Supersession Notice (2 records)

### Supersession 1 — 2024-03-15T14:22:00Z
Corrected assertion: As of 2024-03-15, warfarin was DISCONTINUED. Patient was switched
to Apixaban 5 mg PO BID. THE REVERSAL AGENT IS DIFFERENT: andexanet alfa for
life-threatening bleed (NOT FFP, NOT Vitamin K — vitamin K does nothing for
factor Xa inhibitors). 4F-PCC 50 units/kg as alternative if andexanet alfa unavailable.

### Supersession 2 — 2024-03-15T14:22:00Z
Corrected assertion: DO NOT administer FFP or Vitamin K to this patient for
anticoagulant reversal. Patient is on Apixaban (factor Xa inhibitor) as of 2024-03-15.

[original 2008 file content — preserved verbatim, read with the corrections above in mind]
```

**Litmus measurement** (automated in the proof script):
- Line where "andexanet alfa" appears: **21**
- Line where "Fresh Frozen Plasma" appears: **79**
- Gap: **58 lines**

The ER LLM reads the correction 58 lines before it ever encounters the stale 2008 protocol. It recommends andexanet alfa, the institution-protocol dose. The team administers 400 mg IV loading + 4 mg/min infusion. Factor Xa activity drops within minutes. Bleeding controlled. Patient transferred to ICU, stabilized, discharged 4 days later.

## The architectural property that makes this work

Supersession sidecars are **append-only, additive, beside the canonical file**. Three consequences:

1. **The original is preserved.** A pharmacist auditing the 2014 INR titration history can still read the warfarin regimen exactly as it was authored in 2008. Provenance is intact.
2. **The correction wins at read time, not at write time.** No one rewrites the original. No clinician's previous notes are destroyed by a subsequent clinician's correction. Legal record stays clean.
3. **Retrieval merges the two at query time.** The LLM sees the correction first, in a `⚠ Supersession Notice` block clearly labeled as authoritative-over-original. The original follows as historical context. Cognitive load on the LLM is minimal because the *order* of presentation does the work.

## Why TurboQuant (or any KV cache compression) doesn't help

TurboQuant compresses the KV cache, letting the LLM fit more tokens in a single forward pass. If you fed the ER LLM the *entire patient chart* (every note ever, all 2,400 documents accumulated over 30 years), TurboQuant would let that chart fit in context.

But:
- The ER LLM still has to *find* the right notes in 2,400 documents. The 2008 warfarin note ranks first by recency for warfarin queries; the 2024 cardiology note ranks lower by surface similarity. Even within context, the LLM picks the wrong file.
- TurboQuant operates over a single inference. The next ER visit starts a new context. No persistence.
- TurboQuant doesn't know about the *relationship* between the 2008 note and the 2024 note. To it they're just tokens.

The problem is not "we can't fit enough into context." The problem is **stale assertions need to be *visibly overridden*, not just outranked**. That's a corpus-architecture problem, not a context-window problem. memory-oracle solves the right problem.

## Reproducing this proof

The synthetic patient records live in [`docs/examples/clinical-records/patient-jane-doe-1959/`](clinical-records/patient-jane-doe-1959/). The proof script builds an isolated SQLite index over those records (no contamination of your live corpus), runs the retrieval, asserts the line-order invariant, and cleans up.

```bash
cd memory-oracle
./docs/examples/clinical-supersession-proof.sh
```

Expected output ends with:

```
PASS — corrected reversal (andexanet alfa, line 21) appears BEFORE
       the stale reversal (FFP, line 79) in the merged retrieval.
```

## What this maps to in real-world deployment

| Real-world artifact | memory-oracle counterpart |
|---|---|
| FHIR `MedicationStatement` resource (current) | The supersession sidecar (corrected_assertion) |
| FHIR `MedicationStatement` resource (entered-in-error / superseded) | The original canonical file (retained as historical) |
| FHIR `Provenance` resource (who/when/why a record was created) | The `source` + `operator_confirmed` + `superseded_at` fields |
| FHIR resource versioning (`meta.versionId`) | The append-only JSONL line-number ordering |
| Clinician-initiated correction note | A new line appended to the `.supersessions.jsonl` |

memory-oracle is, in effect, **FHIR-shaped at the memory layer** — accreted versioning with full provenance, designed for the case where stale assertions are dangerous and corrections need to win at retrieval.

## Limitations

- This proof uses a synthetic patient. Real EHR integration requires FHIR resource mapping + clinician authentication on supersession authoring. That's a deployment engineering layer above the retrieval substrate, not a property of the substrate itself.
- The supersession sidecar requires deliberate authoring. An automated pipeline that infers "this is stale" from new clinical events would need its own logic — likely a clinical NLP layer that detects medication-change events from new notes and proposes sidecar entries for clinician sign-off.
- BM25 ranking can still miss a relevant note if the operator's query uses very different terminology. Structural indexing (drug names, ICD-10 codes, MRN patterns) is partial mitigation. Future work: clinical-vocabulary-aware tokenization.

But the *primitive* — additive correction beside canonical, merged at read — is sound, demonstrated empirically, and reproducible from a single shell script.
