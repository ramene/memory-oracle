import { createServer, type IncomingMessage, type ServerResponse } from 'node:http';
import type { PairingDeviceClaim, AgeFileDelivery, PairRecord } from './types.ts';

// ── pair-relay ──────────────────────────────────────────────────────────────
// Lean fork of @memory-oracle/encounter-relay for the verum device-pairing
// handshake (desktop `verum pair-device` ⇄ verum-ios). Same raw-node:http,
// zero-dep, ephemeral-routing pattern; the clinical /ebr-alert route + EBR-core
// imports are intentionally NOT carried over.
//
// State is an in-memory Map<nonce, PairRecord>, ephemeral across restarts.
// Deployed on GAE with `manual_scaling: instances: 1` — EXACTLY one instance,
// because a second instance would not see the first's Map (a claim POSTed to
// instance A would be invisible to a poll routed to instance B). manual_scaling
// pins one always-on instance, so store-and-forward holds within a TTL window.
//
// Online pairing flow (relay transport):
//   1. desktop emits PairingOffer (QR/--text) carrying nonce N + relay URL      [off-relay]
//   2. phone   POST /pair/claim            { ...PairingDeviceClaim, nonce: N }  → record[N].claim
//   3. desktop GET  /pair/claim?nonce=N    → reads claim (learns device_recipient)
//   4. desktop POST /pair                  { nonce: N, for, age_file_b64 }      → record[N].ageFileB64
//   5. phone   GET  /pair?for=&nonce=N     → { age_file_b64 } (204 until step 4)

const pairings = new Map<string, PairRecord>();

const PORT = Number(process.env.PORT ?? 8080);
const TTL_SWEEP_MS = 30_000;
const DEFAULT_TTL_SECONDS = 900;          // 15 min — matches PairingOffer default ttl_seconds
const MAX_BODY_BYTES = 64 * 1024;         // claim + base64 age file fit comfortably

// ── TTL sweeper ──
setInterval(() => {
  const now = Date.now();
  for (const [nonce, rec] of pairings) {
    if (rec.expiresAt < now) pairings.delete(nonce);
  }
}, TTL_SWEEP_MS).unref();

// ── Helpers ──
function json(res: ServerResponse, status: number, body: unknown): void {
  res.writeHead(status, {
    'Content-Type': 'application/json',
    'Cache-Control': 'no-store',
    'Access-Control-Allow-Origin': '*',
    'Access-Control-Allow-Methods': 'GET, POST, DELETE, OPTIONS',
    'Access-Control-Allow-Headers': 'Content-Type',
  });
  res.end(JSON.stringify(body));
}

function noContent(res: ServerResponse, status: number): void {
  res.writeHead(status, {
    'Cache-Control': 'no-store',
    'Access-Control-Allow-Origin': '*',
  });
  res.end();
}

async function readJson(req: IncomingMessage): Promise<unknown> {
  return new Promise((resolve, reject) => {
    let total = 0;
    const chunks: Buffer[] = [];
    req.on('data', (chunk: Buffer) => {
      total += chunk.length;
      if (total > MAX_BODY_BYTES) {
        reject(new Error(`body exceeds ${MAX_BODY_BYTES} bytes`));
        req.destroy();
        return;
      }
      chunks.push(chunk);
    });
    req.on('end', () => {
      try {
        resolve(JSON.parse(Buffer.concat(chunks).toString('utf8')));
      } catch (e) {
        reject(e);
      }
    });
    req.on('error', reject);
  });
}

function bad(res: ServerResponse, status: number, message: string): void {
  json(res, status, { error: message });
}

/** Fetch a live (unexpired) record by nonce, or null. */
function liveRecord(nonce: string): PairRecord | null {
  const rec = pairings.get(nonce);
  if (!rec) return null;
  if (rec.expiresAt < Date.now()) {
    pairings.delete(nonce);
    return null;
  }
  return rec;
}

// ── Routes ──
const server = createServer(async (req, res) => {
  try {
    const url = new URL(req.url ?? '/', `http://${req.headers.host ?? 'localhost'}`);
    const method = req.method ?? 'GET';

    // CORS preflight
    if (method === 'OPTIONS') {
      res.writeHead(204, {
        'Access-Control-Allow-Origin': '*',
        'Access-Control-Allow-Methods': 'GET, POST, DELETE, OPTIONS',
        'Access-Control-Allow-Headers': 'Content-Type',
      });
      res.end();
      return;
    }

    // Health check
    if (url.pathname === '/' || url.pathname === '/healthz') {
      json(res, 200, { ok: true, pairings: pairings.size, ts: new Date().toISOString() });
      return;
    }

    // POST /pair/claim — phone submits a PairingDeviceClaim (creates record by nonce)
    if (url.pathname === '/pair/claim' && method === 'POST') {
      const body = await readJson(req).catch(() => null);
      if (!body || typeof body !== 'object') return bad(res, 400, 'invalid JSON');
      const c = body as Partial<PairingDeviceClaim>;
      for (const f of ['v', 'kind', 'nonce', 'device_recipient', 'device_label', 'issued_at'] as const) {
        if (c[f] === undefined) return bad(res, 400, `missing field: ${f}`);
      }
      if (c.kind !== 'verum-pair-claim') return bad(res, 400, `unexpected kind: ${c.kind}`);
      const now = Date.now();
      const existing = liveRecord(c.nonce!);
      const rec: PairRecord = existing ?? {
        nonce: c.nonce!,
        claim: null,
        ageFileB64: null,
        createdAt: now,
        expiresAt: now + DEFAULT_TTL_SECONDS * 1000,
      };
      rec.claim = c as PairingDeviceClaim;
      pairings.set(rec.nonce, rec);
      json(res, 201, { ok: true, expiresAt: new Date(rec.expiresAt).toISOString() });
      return;
    }

    // GET /pair/claim?nonce=<nonce> — desktop reads the claim (learns device_recipient)
    if (url.pathname === '/pair/claim' && method === 'GET') {
      const nonce = url.searchParams.get('nonce');
      if (!nonce) return bad(res, 400, "missing query param 'nonce'");
      const rec = liveRecord(nonce);
      if (!rec || rec.claim === null) return noContent(res, 204);   // not claimed yet
      json(res, 200, rec.claim);
      return;
    }

    // POST /pair — desktop delivers the wrapped sub-key (age file) for a nonce
    if (url.pathname === '/pair' && method === 'POST') {
      const body = await readJson(req).catch(() => null);
      if (!body || typeof body !== 'object') return bad(res, 400, 'invalid JSON');
      const d = body as Partial<AgeFileDelivery>;
      for (const f of ['nonce', 'for', 'age_file_b64'] as const) {
        if (d[f] === undefined) return bad(res, 400, `missing field: ${f}`);
      }
      const rec = liveRecord(d.nonce!);
      if (!rec) return bad(res, 404, 'nonce not found or expired');
      if (rec.claim === null) return bad(res, 409, 'no claim for this nonce yet');
      if (rec.claim.device_recipient !== d.for) return bad(res, 400, "'for' does not match the claim's device_recipient");
      rec.ageFileB64 = d.age_file_b64!;
      json(res, 200, { ok: true });
      return;
    }

    // GET /pair?for=<device_recipient>&nonce=<nonce> — phone polls for the age file
    if (url.pathname === '/pair' && method === 'GET') {
      const forRecipient = url.searchParams.get('for');
      const nonce = url.searchParams.get('nonce');
      if (!forRecipient || !nonce) return bad(res, 400, "missing query params 'for' and/or 'nonce'");
      const rec = liveRecord(nonce);
      if (!rec) return bad(res, 404, 'nonce not found or expired');
      // Only the recipient named in the claim may retrieve the age file.
      if (rec.claim !== null && rec.claim.device_recipient !== forRecipient) {
        return bad(res, 403, "'for' does not match the claim's device_recipient");
      }
      if (rec.ageFileB64 === null) return noContent(res, 204);      // not delivered yet — keep polling
      json(res, 200, { age_file_b64: rec.ageFileB64 });
      return;
    }

    // DELETE /pair?nonce=<nonce> — cleanup after a completed pairing
    if (url.pathname === '/pair' && method === 'DELETE') {
      const nonce = url.searchParams.get('nonce');
      if (!nonce) return bad(res, 400, "missing query param 'nonce'");
      const ok = pairings.delete(nonce);
      json(res, ok ? 200 : 404, { deleted: ok });
      return;
    }

    // GET /inbox?for=<recipient> — V2 stub for post-pairing ShareEnvelope delivery.
    // MVP is poll-on-open: the app GETs pending envelopes here when it foregrounds.
    // Returns an empty list for now; the envelope store + APNs push is the V2 build.
    if (url.pathname === '/inbox' && method === 'GET') {
      const forRecipient = url.searchParams.get('for');
      if (!forRecipient) return bad(res, 400, "missing query param 'for'");
      json(res, 200, { envelopes: [], note: 'inbox V2 stub — envelope store + APNs not yet implemented' });
      return;
    }

    bad(res, 404, `no route for ${method} ${url.pathname}`);
  } catch (e) {
    bad(res, 500, e instanceof Error ? e.message : String(e));
  }
});

server.listen(PORT, () => {
  console.log(`[pair-relay] listening on http://0.0.0.0:${PORT}`);
  console.log(`[pair-relay] in-memory state — ephemeral across restarts; deploy with manual_scaling: instances: 1`);
  console.log(`[pair-relay] routes:`);
  console.log(`  GET  /healthz`);
  console.log(`  POST /pair/claim                       (phone   → relay)`);
  console.log(`  GET  /pair/claim?nonce=<nonce>         (desktop polls claim)`);
  console.log(`  POST /pair                             (desktop → relay: age_file_b64)`);
  console.log(`  GET  /pair?for=<recipient>&nonce=<n>   (phone polls age file)`);
  console.log(`  DEL  /pair?nonce=<nonce>               (cleanup)`);
  console.log(`  GET  /inbox?for=<recipient>            (V2 stub — envelope delivery)`);
});
