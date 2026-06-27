# @memory-oracle/pair-relay

Lean stateless relay for the **verum device-pairing handshake** — desktop
`verum pair-device` ⇄ `verum-ios`. A fork of `encounter-relay` with the clinical
`/ebr-alert` route and EBR-core imports removed; same raw-`node:http`, zero-dep,
ephemeral-routing pattern.

Implements the relay half of
`architecture-notes/docs/architecture/verum-pairing-protocol-2026-06-26.md`
(task #165 follow-on). iOS side: `verum-ios` `PairingService.swift` /
`PairingPayload.swift`.

## Run / test

```bash
npm start          # node --experimental-strip-types server.ts   (PORT=8080)
npm run test:curl  # full offer→claim→deliver→poll round-trip on a free port
```

## Online pairing flow

```
1. desktop emits PairingOffer (QR/--text): nonce N + relay URL + eph P-256 pubkey   [off-relay]
2. phone   POST /pair/claim         { ...PairingDeviceClaim, nonce: N }   → store claim
3. desktop GET  /pair/claim?nonce=N → reads claim, learns device_recipient
4. desktop POST /pair               { nonce: N, for, age_file_b64 }       → store age file
5. phone   GET  /pair?for=&nonce=N  → { age_file_b64 }   (204 until step 4 lands)
```

The phone-facing routes (`POST /pair/claim`, `GET /pair`) are the published
contract; the desktop-facing routes (`GET /pair/claim`, `POST /pair`) are the
symmetric counterparts the contract implies. State is keyed by `nonce`. A
mismatched `for` vs the claim's `device_recipient` is rejected (400 on deliver,
403 on retrieve) to prevent cross-retrieval.

## Routes

| method | path | who | returns |
|---|---|---|---|
| GET | `/healthz` | — | `{ ok, pairings, ts }` |
| POST | `/pair/claim` | phone | `201 { ok, expiresAt }` |
| GET | `/pair/claim?nonce=` | desktop | claim JSON · `204` until claimed |
| POST | `/pair` | desktop | `200 { ok }` · `404`/`409`/`400` guards |
| GET | `/pair?for=&nonce=` | phone | `{ age_file_b64 }` · `204` until delivered |
| DELETE | `/pair?nonce=` | either | `{ deleted }` |
| GET | `/inbox?for=` | app | `{ envelopes: [] }` — **V2 stub** (poll-on-open envelope delivery; APNs + store TBD) |

## Deploy (GAE, mae-stack-prod)

`manual_scaling: instances: 1` is **load-bearing** — the in-memory `Map` means
exactly one instance must exist (see `app.yaml`).

```bash
gcloud app deploy app.yaml --project=mae-stack-prod
```

Route `relay.verum.sh` to this service via `dispatch.yaml` in the **verum.sh**
repo (sibling to the existing verum-sh / mae-sh / appmaestro-ai routes):

```yaml
dispatch:
  - url: "relay.verum.sh/*"
    service: pair-relay
```

`relay.verum.sh` must be added as a mapped custom domain on the GAE app (managed
SSL), and the priority-1 DENY-all firewall on mae-stack-prod opened for the pair
routes — otherwise the online path is blocked at the edge.

## Not in scope here

- `verum pair-device` desktop CLI (C++; emits the offer, computes SAS, mints +
  age-encrypts the sub-key, delivers via `POST /pair`).
- The `/inbox` envelope store + APNs push (V2).
