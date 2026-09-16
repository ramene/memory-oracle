import { createServer, type IncomingMessage, type ServerResponse } from 'node:http';
import { randomUUID } from 'node:crypto';

/*
 * verum-signin-relay — the PUBLIC, hardened, ZERO-KNOWLEDGE relay for relay.verum.sh.
 * Generalizes the clinical encounter-relay (server.ts) into a bare opaque router for the
 * "Sign in with verum" QR/relay handshake (payload = an opaque vcap). It NEVER sees a plaintext
 * secret/key and NEVER interprets, verifies, or logs the vcap — it only routes the ciphertext-
 * to-the-relay envelope from phone → web, bound to session_id+nonce, single-use, short-TTL.
 *
 * Distinct from server.ts on purpose: NO clinical/EBR routes, NO memory-oracle-core imports —
 * the public product must not carry the conflict engine or any PHI surface.
 *
 * Routes:
 *   GET  /healthz
 *   POST /encounter                 web creates a signin session  {kind:"verum-signin",nonce,ttl<=90,ask?}
 *                                     -> {session_id, expiresAt}
 *   POST /encounter/<id>/approval   phone posts the approval      {nonce, vcap:"vcap1.…"}  (nonce MUST match)
 *                                     -> {ok:true}
 *   GET  /encounter/<id>/approval   web polls -> 404 until approved, then {vcap} ONCE (single-use, then purged)
 *   DELETE /encounter/<id>          cleanup
 *
 * Hardening: zero-knowledge (opaque vcap only), session_id+nonce binding (anti-replay), <=90s TTL +
 * SINGLE-USE, per-IP rate-limit, 64KB body cap, CORS scoped to *.karve.ai, no-store. TLS is terminated
 * by the platform (GAE/Cloud Run) — run this HTTP server behind it, never expose it raw.
 */

const PORT = Number(process.env.PORT ?? 8080);
const MAX_BODY_BYTES = 64 * 1024;
const MAX_TTL_S = 90;                 // spec cap
const SWEEP_MS = 15_000;
const RATE_MAX = 60;                  // requests / window / IP
const RATE_WINDOW_MS = 60_000;
const MAX_VCAP_BYTES = 8 * 1024;      // a vcap is small; reject anything larger

interface Session {
  nonce: string;
  ask: unknown;                       // opaque; echoed to no one — the phone already scanned it in the QR
  approval: string | null;            // the opaque vcap, once posted
  expiresAt: number;
}
const sessions = new Map<string, Session>();
const rate = new Map<string, { count: number; resetAt: number }>();

setInterval(() => {
  const now = Date.now();
  for (const [id, s] of sessions) if (s.expiresAt < now) sessions.delete(id);
  for (const [ip, e] of rate) if (e.resetAt < now) rate.delete(ip);
}, SWEEP_MS).unref();

function rateOk(ip: string): boolean {
  const now = Date.now();
  const e = rate.get(ip);
  if (!e || e.resetAt < now) { rate.set(ip, { count: 1, resetAt: now + RATE_WINDOW_MS }); return true; }
  if (e.count >= RATE_MAX) return false;
  e.count++;
  return true;
}

// CORS: echo the Origin ONLY for our first-party identity/property hosts; never a wildcard.
// Allowed: karve.ai + *.karve.ai (studio), verum.sh + *.verum.sh (id.verum.sh — the Verum ID
// login home), noodles.haus + *.noodles.haus (tailnet properties, e.g. docs.noodles.haus).
const CORS_HOSTS = ['karve.ai', 'verum.sh', 'noodles.haus'];
function corsOrigin(origin: string | undefined): string | null {
  if (!origin) return null;
  try {
    const h = new URL(origin).hostname;
    if (CORS_HOSTS.some((d) => h === d || h.endsWith('.' + d))) return origin;
  } catch { /* ignore */ }
  return null;
}

function head(res: ServerResponse, status: number, origin: string | null): void {
  res.writeHead(status, {
    'Content-Type': 'application/json',
    'Cache-Control': 'no-store',
    ...(origin ? { 'Access-Control-Allow-Origin': origin, 'Vary': 'Origin' } : {}),
    'Access-Control-Allow-Methods': 'GET, POST, DELETE, OPTIONS',
    'Access-Control-Allow-Headers': 'Content-Type',
  });
}
function json(res: ServerResponse, status: number, body: unknown, origin: string | null): void {
  head(res, status, origin);
  res.end(JSON.stringify(body));
}

async function readJson(req: IncomingMessage): Promise<unknown> {
  return new Promise((resolve, reject) => {
    let total = 0;
    const chunks: Buffer[] = [];
    req.on('data', (c: Buffer) => {
      total += c.length;
      if (total > MAX_BODY_BYTES) { reject(new Error('body too large')); req.destroy(); return; }
      chunks.push(c);
    });
    req.on('end', () => { try { resolve(JSON.parse(Buffer.concat(chunks).toString('utf8'))); } catch (e) { reject(e); } });
    req.on('error', reject);
  });
}

const ID_RE = /^[0-9a-f-]{36}$/;

const server = createServer(async (req, res) => {
  const ip = req.socket.remoteAddress ?? '?';
  const origin = corsOrigin(req.headers.origin as string | undefined);
  try {
    const url = new URL(req.url ?? '/', `http://${req.headers.host ?? 'localhost'}`);
    const method = req.method ?? 'GET';

    if (method === 'OPTIONS') { head(res, 204, origin); res.end(); return; }
    if (!rateOk(ip)) return json(res, 429, { error: 'rate limited' }, origin);
    if (url.pathname === '/' || url.pathname === '/healthz') return json(res, 200, { ok: true, sessions: sessions.size, ts: new Date().toISOString() }, origin);

    // POST /encounter — web creates a signin session (opaque offer).
    if (url.pathname === '/encounter' && method === 'POST') {
      const b = await readJson(req).catch(() => null) as Record<string, unknown> | null;
      if (!b || typeof b !== 'object') return json(res, 400, { error: 'invalid JSON' }, origin);
      if (b.kind !== 'verum-signin') return json(res, 400, { error: 'unsupported kind' }, origin);
      const nonce = String(b.nonce ?? '');
      if (nonce.length < 8 || nonce.length > 128) return json(res, 400, { error: 'bad nonce (8..128 chars)' }, origin);
      let ttl = Number(b.ttl ?? MAX_TTL_S);
      if (!Number.isFinite(ttl) || ttl <= 0) return json(res, 400, { error: 'bad ttl' }, origin);
      ttl = Math.min(ttl, MAX_TTL_S);
      const id = randomUUID();
      const now = Date.now();
      sessions.set(id, { nonce, ask: b.ask ?? null, approval: null, expiresAt: now + ttl * 1000 });
      return json(res, 201, { session_id: id, expiresAt: new Date(now + ttl * 1000).toISOString() }, origin);
    }

    // /encounter/<id>/approval
    const m = url.pathname.match(/^\/encounter\/([0-9a-f-]+)\/approval$/);
    if (m) {
      const id = m[1]!;
      if (!ID_RE.test(id)) return json(res, 400, { error: 'bad id' }, origin);
      const now = Date.now();
      const s = sessions.get(id);
      if (!s || s.expiresAt < now) return json(res, 404, { error: 'session not found or expired' }, origin);

      if (method === 'POST') {                 // phone posts the approval (opaque vcap)
        const b = await readJson(req).catch(() => null) as Record<string, unknown> | null;
        if (!b || typeof b !== 'object') return json(res, 400, { error: 'invalid JSON' }, origin);
        if (String(b.nonce ?? '') !== s.nonce) return json(res, 400, { error: 'nonce mismatch' }, origin);  // anti-replay: bind to THIS session
        const vcap = String(b.vcap ?? '');
        if (!vcap.startsWith('vcap1.') || vcap.length > MAX_VCAP_BYTES) return json(res, 400, { error: 'bad vcap' }, origin); // opaque shape only — zero-knowledge, no verify
        if (s.approval !== null) return json(res, 409, { error: 'already approved' }, origin);
        s.approval = vcap;
        return json(res, 200, { ok: true }, origin);
      }
      if (method === 'GET') {                   // web polls; deliver ONCE then purge (single-use)
        if (s.approval === null) return json(res, 404, { error: 'awaiting approval' }, origin);
        const vcap = s.approval;
        sessions.delete(id);
        return json(res, 200, { vcap }, origin);
      }
      return json(res, 405, { error: 'method not allowed' }, origin);
    }

    // DELETE /encounter/<id>
    const dm = url.pathname.match(/^\/encounter\/([0-9a-f-]+)$/);
    if (dm && method === 'DELETE') {
      const id = dm[1]!;
      if (!ID_RE.test(id)) return json(res, 400, { error: 'bad id' }, origin);
      return json(res, sessions.delete(id) ? 200 : 404, { deleted: true }, origin);
    }

    return json(res, 404, { error: `no route for ${method} ${url.pathname}` }, origin);
  } catch (e) {
    return json(res, 500, { error: e instanceof Error ? e.message : String(e) }, origin);
  }
});

server.listen(PORT, () => {
  console.log(`[verum-signin-relay] :${PORT}  zero-knowledge · *.karve.ai CORS · <=${MAX_TTL_S}s single-use · rate ${RATE_MAX}/min`);
});
