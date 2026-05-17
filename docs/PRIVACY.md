# Privacy + PII threat model for memory-oracle

> The retrieval substrate is dual-use. Operator notes about software architecture are low-stakes. Clinical notes about patient anticoagulation regimens are not. This document scopes the threat model and the encryption layer that must precede any clinical or PHI-bearing deployment.

## Threat model

memory-oracle today stores **plaintext markdown + plaintext SQLite FTS5 index** on the operator's local filesystem. Three classes of risk:

| Threat | Today's exposure |
|---|---|
| **Local-disk access** (laptop theft, malware, multi-user system) | Full plaintext readable by anyone with `~/.claude/projects/` access |
| **Backup / sync leakage** (Time Machine, Google Drive, rsync to backup) | Backup destination has plaintext copies |
| **Git-tracked corpus** (multi-machine sync via git push/pull) | GitHub/GitLab sees plaintext in commits and history forever |
| **API consumer leakage** (REST endpoint returns PII to an authenticated caller) | Token compromise = full corpus exfiltration |
| **Index DB persistence** | Even if source markdown is deleted, the FTS5 index retains the content in `merged_body` until rebuilt |

For the personal-developer use case, none of this matters — the operator owns the data, the laptop, the backups, the git remote. For the **clinical use case** in the paper, every one of these is a HIPAA breach surface.

## Architecture for the encrypted variant

### Layer 1 — File-at-rest encryption via git-crypt-revived

`git-crypt-revived` (your existing implementation) encrypts files transparently inside git, using GPG keys + an AES-256 file key:

```
# .gitattributes
memory/*.md filter=git-crypt diff=git-crypt
memory/*.supersessions.jsonl filter=git-crypt diff=git-crypt
```

Consequences:
- Memory files are **plaintext on disk** when git-crypt is unlocked (working copy)
- **Encrypted at rest** in `.git/` and when pushed to any remote
- Decryption requires possession of a GPG key in `git-crypt key-share`'d list
- Working-copy plaintext is the **only attack surface** — and only while the operator has the key loaded

memory-oracle reads from working-copy plaintext, so retrieval works unchanged. The SQLite index DB is rebuildable from source — never commit it (already in `.gitignore`).

### Layer 2 — Per-patient namespace + ephemeral working-copy

Clinical extension: each patient's data lives in its own namespace, encrypted with a per-patient key:

```
~/.clinical-memory/
├── patient-abc123/
│   ├── memory/medication_anticoagulant.md       (encrypted)
│   └── memory/medication_anticoagulant.md.supersessions.jsonl  (encrypted)
└── patient-xyz789/
    └── ...
```

Per-patient encryption keys are NOT stored on the clinician's device — they're derived at runtime from:
- The clinician's institutional GPG key (proof of role + employment)
- A per-patient secret (delivered via the patient-contact decryption flow below)

The working-copy plaintext exists ONLY in tmpfs / RAM-disk while the clinician is actively treating the patient. When the encounter ends, working copy is shredded.

### Layer 3 — Patient-contact decryption (the QR + mobile flow)

**The vision**: clinician arrives at bedside, scans the patient's wristband QR, mobile app verifies identity + match, derives the per-patient decryption key, forwards to the clinician's terminal for the duration of the encounter.

Mechanically:

```
Patient wristband        Clinician's phone           Clinician's terminal
─────────────────        ──────────────────          ─────────────────────
QR encodes patient_id  →  Scan QR
                          App auth: biometric + PIN
                          Pull clinician's GPG key
                          Pull patient_id from QR
                          Request session token
                          from institutional KMS  →
                                                     KMS verifies clinician
                                                     is on-shift, on-floor,
                                                     and patient is on
                                                     the clinician's roster
                          KMS returns session_key  ←
                            encrypted with
                            clinician's GPG pubkey
                          Decrypt session_key
                            with biometric-locked
                            private key on phone
                          Forward session_key
                            via Bluetooth LE        →  Open ephemeral
                                                       tmpfs at /tmp/clinical
                                                       Decrypt patient namespace
                                                       Mount at ~/.clinical-memory
                                                       Set 30-min TTL
                                                       memory-oracle queries proceed
                          Encounter ends            →  Shred tmpfs
                          (manual or 30-min TTL)       Revoke session_key
                                                       Audit log entry
```

**Properties**:
1. **No standing access** — clinician cannot read patient X's data outside an active encounter
2. **Physical-proximity gating** — Bluetooth LE has ~10m range; QR requires line-of-sight to the wristband
3. **Identity verification** — biometric on phone + institutional KMS check
4. **Audit trail** — every decryption event logged to institutional audit log (timestamp, clinician, patient, session length, queries run)
5. **Break-glass override** — emergency access (unconscious patient, no QR available) requires senior physician dual-signoff and triggers immediate audit alert

### Layer 4 — API-level access control

The REST API today uses a single bearer token. For clinical deployment:

- **Per-clinician JWT** signed by institutional CA
- **Patient-scoped JWT claims** — `aud: patient_abc123` — query results filtered by claim
- **Audit logging on every request** — clinician_id, patient_id, query, byte size returned, IP, user-agent
- **Rate limiting + anomaly detection** — alert on bulk query patterns suggesting exfiltration
- **TLS pinning** to institutional certificate, no public-CA fallback

### Layer 5 — Index-DB encryption

SQLite FTS5 doesn't natively encrypt. Options:
- **SQLCipher** — page-level AES encryption, drop-in replacement for SQLite. Adds ~5% latency, no schema changes. Recommended.
- **Ephemeral in-tmpfs DB** — index rebuilds on every clinician session, lives only in RAM, never persisted. Slower start (a few seconds for a per-patient corpus) but stronger guarantees.

For clinical deployment, both: SQLCipher for the long-running cross-patient analytics index, ephemeral tmpfs for per-encounter working index.

## What we ship today vs what we'd need to ship for clinical

| Component | Today (v0.1) | Clinical (v1.0+) |
|---|---|---|
| File-at-rest encryption | None — plaintext on disk | git-crypt-revived for markdown + sidecars |
| Index encryption | None — plaintext SQLite | SQLCipher OR ephemeral tmpfs |
| API auth | Bearer token | Per-clinician JWT with patient-scoped claims |
| Decryption flow | git-crypt unlock at terminal | QR + mobile app + institutional KMS |
| Audit logging | None | Per-query log to institutional audit system |
| Break-glass | None | Dual-signoff emergency override |
| Backup encryption | Depends on backup tool | Verify Time Machine FileVault, git remote treats as ciphertext |
| Memory wipe | Manual | Automatic tmpfs shred on encounter end |
| HIPAA compliance review | No | Required before any PHI touches the system |

## What this means for the paper

The paper should present memory-oracle as a **retrieval primitive** that's correct for the cross-session-stale-assertion problem AND acknowledge that deploying it on PHI requires the full encryption stack above. Otherwise the clinical scenario reads as naive about the deployment realities.

The deployment architecture is **not invented** — it's the standard "break-glass with audit" pattern used in EHRs today (Epic, Cerner, athenahealth all have it). What's new is layering the supersession-aware retrieval substrate underneath that access pattern, so the corruption-of-truth problem is solved at the same time as the access-control problem.

## Open questions for the paper section on deployment

1. Does the per-patient-namespace key derivation get audited by the institution, or is it cryptographically opaque to them? (Trade-off: clinician privacy vs institutional oversight.)
2. How does the patient consent flow surface in this architecture? Patient must opt-in to having an AI-augmented EHR retrieval layer on their record.
3. Multi-institution patients (transfer of care): how do supersession sidecars from one hospital's clinicians reach the receiving hospital's clinicians? This is the FHIR exchange problem layered on top of the supersession problem.
4. Cross-jurisdiction (state, country) — GDPR vs HIPAA vs Canadian PIPEDA reconciliation.

These are not memory-oracle problems per se — they're standard EHR deployment problems. But the paper should reference them so reviewers don't think we're glossing over them.

## Implementation roadmap (board items)

See GH project board for the tracked work:
- `git-crypt-revived integration` — file-at-rest encryption for memory/*.md + sidecars
- `SQLCipher index variant` — encrypted FTS5 alternative
- `Per-clinician JWT auth on REST API` — replaces bearer token
- `QR + mobile decryption flow spec` — design doc + reference implementation
- `Audit logging spec` — what gets logged, what's retained, who can see it
- `HIPAA compliance review` — engage compliance consultant before clinical pilot
