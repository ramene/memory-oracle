# encounter-relay (Phase 3c-iii)

> Stateless HTTP relay for the dual-device clinical demo. Routes
> `EncounterRequest` from clinician iPad → patient iPhone, and the
> resulting `EncounterApproval` (wrapped session keys) back.

## Status

3c-iii — **shipped + curl-validated**. Lives at
[`packages/encounter-relay/`](.) in memory-oracle. Zero dependencies;
runs on Node 22+ via native type-stripping.

## Wire format

See [`types.ts`](./types.ts). JSON-LD style for paper-figure friendliness.

```jsonc
// Clinician → relay → patient
{
  "@type": "EncounterRequest",
  "encounterId": "<server-assigned uuid>",
  "clinicianRecipient": "age1se1...",  // iPad's SE recipient
  "clinicianName": "Dr. Y. Chen",
  "patientRecipient":  "age1se1...",   // patient's SE recipient
  "requestedScopes": ["allergies", "meds"],
  "ttlSeconds": 900,
  "issuedAt": "2026-05-31T19:00:00Z"
}

// Patient → relay → clinician (after Face ID approval)
{
  "@type": "EncounterApproval",
  "encounterId": "<same uuid>",
  "wrappedKeys": {
    "allergies": "<base64 of age-encrypted blob>",
    "meds":       "<base64 of age-encrypted blob>"
  },
  "expiresAt": "2026-05-31T19:15:00Z",
  "auditEntryId": "<memory-oracle audit ref, optional>"
}
```

## Routes

| Method | Path                              | Used by   | Effect |
|--------|-----------------------------------|-----------|--------|
| GET    | `/healthz`                        | both      | Liveness check |
| POST   | `/encounter`                      | clinician | Submit `EncounterRequest`; returns `encounterId` |
| GET    | `/encounter?for=<recipient>`      | patient   | Poll pending requests addressed to this patient |
| POST   | `/encounter/<id>/approval`        | patient   | Submit `EncounterApproval` |
| GET    | `/encounter/<id>/approval`        | clinician | Poll for approval; 404 until present |
| DELETE | `/encounter/<id>`                 | either    | Cleanup |

In-memory state, swept every 30 seconds for expired records. Ephemeral
across restarts — that's fine for the demo. Production would use real
persistence + signed envelopes.

## Run locally for the demo

```bash
cd packages/encounter-relay
PORT=8080 npm start
# → listening on http://0.0.0.0:8080
```

Both iPhone and iPad need to reach this. On the Sequoia Mac (running the
relay), find the local IP and use it in the patient's QR + clinician's
config:

```bash
ipconfig getifaddr en0    # e.g., 192.168.1.42
```

iPhone scans the patient QR which encodes
`{"v":1,"recipient":"age1se1...","relay":"http://192.168.1.42:8080"}`.
Clinician iPad POSTs to `http://192.168.1.42:8080/encounter`.

## Validate

```bash
bash test/curl-test.sh
```

Runs the full request → poll → approve → retrieve cycle through 7 assertion
steps. Uses fake recipient strings; the real cryptographic round-trip
involves the iPhone + iPad and lands in 3c-iv + 3c-v.

## Deployment options (post-paper)

- **Cloud Run** — `gcloud run deploy --source .` with min-instances=1
  to avoid cold-start lag in demo recordings
- **Fly.io** — single-region machine, `fly launch --no-deploy && fly deploy`
- **ngrok** — `ngrok http 8080` for ad-hoc remote testing without infra

For the LNCS §7.4 demo: local Mac is the simplest path. Production
hardening (auth between patient/clinician/relay, signed envelopes,
durable storage, rate limiting) is post-paper.
