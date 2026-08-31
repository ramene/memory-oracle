// signin-client — the "Sign in with verum" RelayClient (framework-agnostic; runs in the
// browser and in Node). Talks to the verum-signin relay (verum-signin-relay.ts). The web
// mints a session, renders the QR, then polls for the phone's opaque vcap approval.
//
// Zero trust decisions here: this client never verifies the vcap — it only transports it.
// The guard (bindVerumSignin, @mae/verumauth) verifies + binds the nonce, server-side.

export interface SigninAsk {
  server: string;
  tools: string[];
}

export interface SigninQrPayload {
  v: 1;
  kind: 'verum-signin';
  relay: string;
  session_id: string;
  nonce: string;
  ttl: number;
  ask: SigninAsk;
}

export interface SigninSession {
  session_id: string;
  nonce: string;
  expiresAt: string;
  qrPayload: SigninQrPayload;
}

// 128-bit URL/JSON-safe nonce, [A-Za-z0-9._-]-clean so `verum mint-cap --nonce` accepts it verbatim.
export function randomNonce(): string {
  const b = new Uint8Array(16);
  (globalThis.crypto ?? require('node:crypto').webcrypto).getRandomValues(b);
  let hex = '';
  for (const x of b) hex += x.toString(16).padStart(2, '0');
  return 'sn-' + hex;
}

async function postJson(url: string, body: unknown, signal?: AbortSignal): Promise<Response> {
  return fetch(url, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify(body),
    signal,
  });
}

/** Web side: create a signin session on the relay and get the QR payload to render. */
export async function createSigninSession(
  relay: string,
  opts: { ask: SigninAsk; ttl?: number; nonce?: string; signal?: AbortSignal },
): Promise<SigninSession> {
  const nonce = opts.nonce ?? randomNonce();
  const ttl = Math.min(opts.ttl ?? 90, 90);
  const res = await postJson(`${relay}/encounter`, { kind: 'verum-signin', nonce, ttl, ask: opts.ask }, opts.signal);
  if (res.status !== 201) throw new Error(`relay POST /encounter -> ${res.status}: ${await res.text()}`);
  const { session_id, expiresAt } = await res.json() as { session_id: string; expiresAt: string };
  return {
    session_id,
    nonce,
    expiresAt,
    qrPayload: { v: 1, kind: 'verum-signin', relay, session_id, nonce, ttl, ask: opts.ask },
  };
}

/** Phone side (also used by the e2e harness to stand in for the iOS app): post the approval. */
export async function submitApproval(
  relay: string,
  session_id: string,
  nonce: string,
  vcap: string,
  signal?: AbortSignal,
): Promise<void> {
  const res = await postJson(`${relay}/encounter/${session_id}/approval`, { nonce, vcap }, signal);
  if (res.status !== 200) throw new Error(`relay POST approval -> ${res.status}: ${await res.text()}`);
}

/**
 * Web side: poll the relay until the phone posts the approval, then return the opaque vcap ONCE
 * (the relay purges it — single-use). Rejects on timeout or if the session expires.
 */
export async function pollForVcap(
  relay: string,
  session_id: string,
  opts: { timeoutMs?: number; intervalMs?: number; signal?: AbortSignal } = {},
): Promise<string> {
  const timeoutMs = opts.timeoutMs ?? 90_000;
  const intervalMs = opts.intervalMs ?? 1500;
  const deadline = Date.now() + timeoutMs;
  for (;;) {
    if (opts.signal?.aborted) throw new Error('aborted');
    const res = await fetch(`${relay}/encounter/${session_id}/approval`, { signal: opts.signal });
    if (res.status === 200) {
      const { vcap } = await res.json() as { vcap: string };
      return vcap;
    }
    if (res.status === 404) {
      // 404 is either "awaiting" (keep polling) or "expired/gone" (stop once past the deadline).
      if (Date.now() >= deadline) throw new Error('sign-in timed out / session expired');
    } else {
      throw new Error(`relay GET approval -> ${res.status}: ${await res.text()}`);
    }
    await new Promise((r) => setTimeout(r, intervalMs));
  }
}
