# Trust model — who holds what, who can do what

> This is the architectural commitment that distinguishes memory-oracle from every existing EHR. The patient holds their master key. The clinician holds a per-encounter session key derived from the patient's consent. No vendor, no hospital, no insurer holds anything that grants standing access to your records.

## The three parties

| Party | Holds | Cannot do |
|---|---|---|
| **Patient** | Master encryption key (in iOS Secure Enclave / Android TEE), full plaintext of own records, wristband QR generator, encounter revoke power, audit log of every read | Modify their own canonical records (only clinicians + the patient's authorized scribes can write — patient writes are supersessions, not edits) |
| **Clinician** | Per-encounter session key (derived from QR + their own institutional key), ephemeral working-copy of patient records during the encounter, write capability for new memory files and supersession sidecars | Read patient records outside an active, patient-consented encounter; persist plaintext after encounter ends; share session key with another clinician |
| **Institution / EHR vendor** | Encrypted ciphertext of records (for backup + multi-clinician handoff scenarios), audit log of which clinicians accessed which patients when, x402 license records for clinical access tokens | Decrypt any patient's records without that patient initiating an encounter; modify the canonical record (only clinicians-with-active-encounter can write); see plaintext at any point in the storage lifecycle |

## The encryption stack — exact mechanism

### Layer 1: Patient master key (at rest, lifetime: patient's life)

When a patient enrolls in memory-oracle:

1. Patient's device generates an **age X25519 keypair** in the Secure Enclave (iOS) / Trusted Execution Environment (Android). Private key NEVER leaves the device.
2. The age **public key** is published to the institutional patient directory (paired with patient_id).
3. All of the patient's clinical records are stored encrypted via [age](https://age-encryption.org/) using **this public key + Shamir's Secret Sharing** (the `git-crypt-revived` integration uses age natively, so we inherit the SSS support).
4. Storage location: encrypted blobs in any standard EHR backend (Epic, Cerner, athenahealth) OR institutional cloud storage OR the patient's own pgvector / Cloud SQL instance. **The storage layer never sees plaintext.**

### Layer 2: Wristband QR (consent token, lifetime: one encounter)

When a patient wants to share their records with a clinician:

1. Patient's app generates a random 128-bit **per-encounter salt**
2. QR payload: `{v:1, patient_id, salt, expires_at, scope}`
   - `scope` declares what's shareable: `"full"` / `"medications-only"` / `"allergies+labs"` / etc.
3. Patient shows the QR to the clinician (physical proximity is the consent gesture)
4. The QR itself contains NO encryption material — it's a *pointer* + *salt*, not a key

### Layer 3: Session key (per-encounter decryption, lifetime: 30 min default)

When the clinician scans the QR:

1. Clinician's app reads the QR payload
2. Clinician's app contacts the patient's app over a short-lived ECDH channel (Bluetooth LE in production, REST API for POC) to negotiate the session
3. **Key derivation**: `session_key = HKDF(patient_master_secret, salt, info="encounter:" + clinician_id + ":" + scope)`
   - The patient's app does this — the master secret never leaves the patient device
   - Output is the AES-256 key for that specific encounter's record decryption
4. Patient's app delivers `session_key` to the clinician's app over the same short-lived channel
5. Clinician's app uses `session_key` to decrypt the patient's records into tmpfs working memory
6. Working memory has a 30-min hard TTL — shredded on encounter end OR TTL expiry OR revocation

### Layer 4: Write-back (clinician's new notes + supersessions)

When the clinician authors new content during the encounter (a supersession sidecar correcting a prior med):

1. Clinician's app encrypts the new content using the patient's **public** age key (or the session_key for symmetric, depending on retention scope)
2. Ciphertext is pushed to the storage layer
3. The patient retains decryption power (because they hold the master secret)
4. The clinician retains NO copy after encounter ends

This is why the architecture is patient-owned: **only the patient can decrypt the corpus.** The clinician decrypts derivatively, time-bounded, and per-consent.

### Layer 5: Audit (forever)

Every access generates an audit entry:
- Patient device: `{ts, clinician_id, encounter_id, scope, duration, supersessions_authored}`
- Institutional audit log: same, plus IP, device fingerprint, KMS verification trace
- Audit log itself is hash-chained (per `git-crypt-revived`'s SHA-256 audit trail) and optionally on-chain anchored for tamper-evidence

## Who ends an encounter?

**Either party** can end an encounter. Both have UI for it.

### Patient revokes (active withdrawal of consent)

Patient taps "Revoke" in their app:
1. Patient's app sends a signed revocation to the clinician's app via the same channel that delivered the session key
2. Clinician's app immediately shreds the tmpfs working copy + displays "Encounter ended by patient"
3. Audit entry: `{event: "revoked_by_patient", ts, partial: true/false}` — `partial: true` means the clinician had already authored supersessions during the encounter (those persist because they're part of the canonical record now)
4. Patient's UI shows: "You ended the encounter with Dr. X. They no longer have access."

### Clinician ends (normal completion)

Clinician taps "End Encounter" in their app:
1. Clinician's app sends "encounter_complete" to the patient's app
2. Working copy shredded
3. Audit entry: `{event: "ended_by_clinician", ts, supersessions_authored: N, queries_run: M}`
4. Patient's UI shows: "Dr. X ended the encounter. They retained no records. Their notes are saved to your file."

### TTL expiry (no action)

After 30 min (default) of clinician inactivity:
1. Session key auto-expires in clinician's app
2. Working copy shredded
3. Audit entry: `{event: "ttl_expired", ts, duration}`
4. Patient sees: "Encounter with Dr. X timed out."

## What the patient OWNS (versus what they merely have access to in legacy EHRs)

| Legacy EHR (Epic, Cerner, etc.) | memory-oracle |
|---|---|
| Hospital owns the records, you have right-of-access via HIPAA request | **You own the records — they're encrypted to YOUR key** |
| You can request a copy (CCD/CCDA export); the hospital still has the original + can share without your knowledge | You **grant** copies via the QR + ECDH handshake; the hospital storage has only ciphertext |
| Changing providers means a chart fax or HIE handoff with provider-to-provider trust | You generate a QR for the new provider; they decrypt the same canonical corpus; no chart re-faxing |
| Corrections happen via a clinician edit (destructive) or addendum (separate document, often not retrieved during emergencies) | Supersessions layer additively next to canonical files; retrieval **merges** them — the warfarin-vs-apixaban scenario is resolved at read time |
| Patient cannot see who has read their records without a formal audit log request | Patient's app shows real-time + historical audit of every read |
| Death/incapacity = institutional decision about records | Patient nominates Shamir-share recipients (next of kin + lawyer + designated physician) — M-of-N can decrypt in break-glass scenarios |

## What the patient is RESPONSIBLE for

1. **Guarding their master key.** It's in the Secure Enclave, but if they lose the device with no Shamir-share backup nominated, those records are permanently sealed. This is the same trade-off as self-custody crypto wallets — empowering, but the responsibility is real. Mitigation: at enrollment, **mandatory Shamir-share setup with at least 3-of-5 recipients** (e.g., spouse, sibling, primary doctor, lawyer, secure backup service).
2. **Generating wristband QRs deliberately.** Don't generate a "full-scope, 24-hour" QR and leave it on the fridge. The default UX should be: short-scope, 30-min, generated at point of care.
3. **Reviewing the audit log.** Patient's app surfaces unusual access patterns. Patient is the last line of defense against compromised clinician accounts.
4. **Authorizing supersessions written by clinicians.** When a doctor writes a new supersession ("patient discontinued warfarin"), the patient gets a notification with the supersession content + the doctor's identity. Patient can confirm OR challenge (initiates an institutional review). Production may auto-approve if the clinician role is verified — that's a configurable policy.

## What the clinician is RESPONSIBLE for

1. **Initiating encounters only at point of care with patient consent.** The QR scan is the contract.
2. **Authoring supersessions truthfully.** Per HIPAA + medical board, deliberately false supersessions are malpractice. The audit chain makes them irrefutable.
3. **Ending the encounter when consultation is complete.** Letting the TTL expire is acceptable; deliberately holding encounters open to scrape data is malpractice + a session-key replay attack.
4. **NEVER sharing a session_key with another clinician.** Each clinician must scan the patient's QR themselves. The session key is bound to the clinician's institutional identity.

## What this enables that current EHRs cannot

1. **Cross-institution transfer** — patient walks into ER 3000 miles from home, presents QR, ER has full history (encrypted in ciphertext at any cloud, decrypted to ER's session key, supersession-aware so the warfarin-vs-apixaban problem is resolved). No HIE delays.
2. **Patient revocation** — patient leaves a relationship with a clinician (or trusts a particular doctor less than they used to), revoke access in their app. Encrypted storage means the ex-clinician's access is *cryptographically* gone, not just policy-gone.
3. **End-of-life and incapacity** — Shamir-share governance handles death, dementia, custody-of-care transitions without institutional override.
4. **Auditability** — patient sees every read, in real time, in their own pocket. Compare to legacy EHRs where you need a HIPAA audit request that takes 30+ days.
5. **The clinical correction problem (this is the showstopper)** — supersessions surface BEFORE stale assertions at retrieval. Vector RAG cannot do this. Standard EHRs require the clinician to *find* the right note among thousands. memory-oracle returns "andexanet alfa" before "FFP" because the retrieval contract makes it so.

## Why this is enterprise-grade and not "yet another health app"

| Health/fitness app pattern | memory-oracle pattern |
|---|---|
| Data lives in vendor cloud, vendor holds keys | Data lives encrypted to patient key, vendor sees ciphertext only |
| "Export your data" returns a CSV of last 30 days | Patient holds the full canonical corpus — the export IS the corpus |
| Account compromise = total data breach | Account compromise affects only encounters within that account's session-key window |
| You're the product (data sold to insurers, advertisers) | Cryptographic ownership means even an insider at the vendor cannot sell data they cannot decrypt |
| Vendor goes out of business = data goes with them | Patient retains the encrypted corpus + master key; just import to a new memory-oracle instance |
| HIPAA "compliance" via policy + access control | HIPAA compliance via mathematics — encryption keys + audit chains, not just policies |

This is the architecture that should have existed for the last 20 years. The reason it didn't is that nobody combined accretive supersession (the retrieval-correctness primitive) with patient-owned keys (the access-correctness primitive) with mobile point-of-care UX (the consent-correctness primitive) into one substrate.

We're not building a new EHR. We're building the **memory layer underneath every EHR** that solves three problems simultaneously: stale assertions, vendor lock-in, and patient ownership.
