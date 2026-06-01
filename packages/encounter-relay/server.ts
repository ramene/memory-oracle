import { createServer, type IncomingMessage, type ServerResponse } from 'node:http';
import { randomUUID } from 'node:crypto';
import type { EncounterRequest, EncounterApproval, EncounterRecord } from './types.ts';

// In-memory Map<encounterId, EncounterRecord>. Stateless across restarts —
// that's fine for the demo. Production would use a real persistence layer
// + signed envelopes; this relay handles only ephemeral routing.
const encounters = new Map<string, EncounterRecord>();

const PORT = Number(process.env.PORT ?? 8080);
const TTL_SWEEP_MS = 30_000;
const MAX_BODY_BYTES = 64 * 1024;   // wrapped keys + metadata easily fit

// ── TTL sweeper ──
setInterval(() => {
  const now = Date.now();
  for (const [id, rec] of encounters) {
    if (rec.expiresAt < now) encounters.delete(id);
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
      json(res, 200, { ok: true, encounters: encounters.size, ts: new Date().toISOString() });
      return;
    }

    // POST /encounter — clinician submits an EncounterRequest
    if (url.pathname === '/encounter' && method === 'POST') {
      const body = await readJson(req).catch(() => null);
      if (!body || typeof body !== 'object') return bad(res, 400, 'invalid JSON');
      const req0 = body as Partial<EncounterRequest>;
      for (const f of ['clinicianRecipient', 'clinicianName', 'patientRecipient', 'requestedScopes', 'ttlSeconds', 'issuedAt'] as const) {
        if (req0[f] === undefined) return bad(res, 400, `missing field: ${f}`);
      }
      const encounterId = randomUUID();
      const now = Date.now();
      const record: EncounterRecord = {
        request: { ...(req0 as EncounterRequest), '@type': 'EncounterRequest', encounterId },
        approval: null,
        createdAt: now,
        expiresAt: now + req0.ttlSeconds! * 1000,
      };
      encounters.set(encounterId, record);
      json(res, 201, {
        encounterId,
        expiresAt: new Date(record.expiresAt).toISOString(),
      });
      return;
    }

    // GET /encounter?for=<patientRecipient> — patient polls pending requests
    if (url.pathname === '/encounter' && method === 'GET') {
      const forPatient = url.searchParams.get('for');
      if (!forPatient) return bad(res, 400, "missing query param 'for'");
      const now = Date.now();
      const pending: EncounterRequest[] = [];
      for (const rec of encounters.values()) {
        if (rec.request.patientRecipient !== forPatient) continue;
        if (rec.approval !== null) continue;
        if (rec.expiresAt < now) continue;
        pending.push(rec.request);
      }
      json(res, 200, { requests: pending });
      return;
    }

    // /encounter/<id>/approval
    const m = url.pathname.match(/^\/encounter\/([0-9a-f-]+)\/approval$/);
    if (m) {
      const encounterId = m[1]!;
      const record = encounters.get(encounterId);
      if (!record) return bad(res, 404, 'encounter not found or expired');

      // POST: patient submits approval
      if (method === 'POST') {
        const body = await readJson(req).catch(() => null);
        if (!body || typeof body !== 'object') return bad(res, 400, 'invalid JSON');
        const ap0 = body as Partial<EncounterApproval>;
        if (ap0.encounterId !== encounterId) return bad(res, 400, 'encounterId mismatch');
        if (!ap0.wrappedKeys || typeof ap0.wrappedKeys !== 'object') {
          return bad(res, 400, 'missing wrappedKeys');
        }
        record.approval = {
          '@type': 'EncounterApproval',
          encounterId,
          wrappedKeys: ap0.wrappedKeys as Record<string, string>,
          expiresAt: ap0.expiresAt ?? new Date(record.expiresAt).toISOString(),
          ...(ap0.auditEntryId ? { auditEntryId: ap0.auditEntryId } : {}),
        };
        json(res, 200, { ok: true });
        return;
      }

      // GET: clinician polls for approval
      if (method === 'GET') {
        if (record.approval === null) {
          json(res, 404, { error: 'awaiting patient approval' });
          return;
        }
        json(res, 200, record.approval);
        return;
      }
    }

    // DELETE /encounter/<id>
    const dm = url.pathname.match(/^\/encounter\/([0-9a-f-]+)$/);
    if (dm && method === 'DELETE') {
      const ok = encounters.delete(dm[1]!);
      json(res, ok ? 200 : 404, { deleted: ok });
      return;
    }

    bad(res, 404, `no route for ${method} ${url.pathname}`);
  } catch (e) {
    bad(res, 500, e instanceof Error ? e.message : String(e));
  }
});

server.listen(PORT, () => {
  console.log(`[encounter-relay] listening on http://0.0.0.0:${PORT}`);
  console.log(`[encounter-relay] in-memory state — ephemeral across restarts`);
  console.log(`[encounter-relay] routes:`);
  console.log(`  GET  /healthz`);
  console.log(`  POST /encounter                   (clinician → relay)`);
  console.log(`  GET  /encounter?for=<recipient>   (patient polls pending)`);
  console.log(`  POST /encounter/<id>/approval     (patient → relay)`);
  console.log(`  GET  /encounter/<id>/approval     (clinician polls approval)`);
  console.log(`  DEL  /encounter/<id>              (cleanup)`);
});
