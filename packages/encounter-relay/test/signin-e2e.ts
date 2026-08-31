// Full-flow e2e proof of "Sign in with verum" — the pieces I own, wired to the REAL crypto:
//
//   mint (verum mint-cap --nonce <QR nonce>)  ->  relay (verum-signin-relay.ts)
//     ->  RelayClient (signin-client.ts)  ->  guard (bindVerumSignin, @mae/verumauth)  ->  200 signed in
//
// Proves: (1) happy path admits + returns the tenant handle; (2) the GUARD binds the QR nonce
// end-to-end (a validly-signed cap minted for a DIFFERENT nonce is rejected at the guard, not just
// by the relay); (3) issuer-pin (rc=5); (4) the relay's routing-layer nonce match (defense in depth).
//
// Run:  node --experimental-strip-types test/signin-e2e.ts
// Requires: node 22+, a built `verum` with --nonce (repo binary, resolved below).

import { spawn, execFileSync } from 'node:child_process';
import { createServer } from 'node:net';
import { mkdtempSync, writeFileSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { createSigninSession, submitApproval, pollForVcap, randomNonce } from '../signin-client.ts';
// Cross-repo (dev tree): the guard lives in @mae/verumauth (substrate). Same-machine relative path.
import { bindVerumSignin } from '../../../../substrate/pkg/verumauth-ts/signin-guard.ts';

const VERUM = '/Users/ramene/.remote/github.com/@ramene/verum/verum';
const ASK = { server: 'rightsizer', tools: ['viability', 'intake'] };

let fails = 0;
function ok(cond: boolean, label: string) { console.log(`  ${cond ? '✓' : '✗'} ${label}`); if (!cond) fails++; }
function freePort(): Promise<number> {
  return new Promise((res) => { const s = createServer(); s.listen(0, () => { const p = (s.address() as any).port; s.close(() => res(p)); }); });
}
function issuerOf(token: string): string { return JSON.parse(Buffer.from(token.split('.')[1], 'base64url').toString()).issuer; }
const sleep = (ms: number) => new Promise((r) => setTimeout(r, ms));

async function main() {
  const port = await freePort();
  const base = `http://127.0.0.1:${port}`;
  const dir = mkdtempSync(join(tmpdir(), 'verum-signin-e2e-'));
  const keyPath = join(dir, 'op.key');
  // Throwaway operator key — never touches the real ~/.verum. mint --issuer-key avoids any HOME override.
  execFileSync('openssl', ['genpkey', '-algorithm', 'ed25519', '-out', keyPath], { stdio: 'ignore' });
  const mint = (nonce: string) =>
    execFileSync(VERUM, ['mint-cap', '--server', 'rightsizer', '--tools', 'viability,intake', '--nonce', nonce, '--issuer-key', keyPath], { encoding: 'utf8' }).trim();

  const relay = spawn('node', ['--experimental-strip-types', 'verum-signin-relay.ts'], {
    cwd: join(import.meta.dirname, '..'), env: { ...process.env, PORT: String(port) }, stdio: 'ignore',
  });
  const cleanup = () => { relay.kill(); rmSync(dir, { recursive: true, force: true }); };

  try {
    for (let i = 0; i < 40; i++) { try { if ((await fetch(`${base}/healthz`)).ok) break; } catch {} await sleep(100); }

    console.log('════ Sign in with verum — full-flow e2e ════');

    // ── happy path ──
    console.log('── [1] web creates session + QR ──');
    const nonce = randomNonce();
    const session = await createSigninSession(base, { ask: ASK, nonce });
    ok(session.qrPayload.kind === 'verum-signin', 'QR kind=verum-signin');
    ok(session.qrPayload.session_id === session.session_id && session.qrPayload.nonce === nonce, 'QR carries session_id+nonce');
    ok(session.qrPayload.ask.server === 'rightsizer', 'QR ask.server=rightsizer');

    console.log('── [2] phone mints a vcap carrying the QR nonce, posts approval ──');
    const token = mint(nonce);
    const trustedIssuer = issuerOf(token);
    ok(issuerOf(token).length > 0, `minted vcap, issuer=${trustedIssuer.slice(0, 12)}…`);
    await submitApproval(base, session.session_id, nonce, token);

    console.log('── [3] web polls relay → vcap (single-use) ──');
    const got = await pollForVcap(base, session.session_id, { timeoutMs: 8000, intervalMs: 250 });
    ok(got === token, 'RelayClient received the exact vcap');

    console.log('── [4] guard admits: bindVerumSignin → 200 signed in ──');
    const r = bindVerumSignin(got, { challenge: nonce, trustedIssuer, expectedServer: 'rightsizer', requiredTools: ['viability', 'intake'] });
    ok(r.ok && r.rc === 0, `admitted (rc=${r.rc}, ${r.reason})`);
    ok(r.tenantId === trustedIssuer, 'tenantId = verified issuer (issuer IS the tenant handle)');

    // ── adversarial ──
    console.log('── [5] E2E ANTI-REPLAY: a validly-signed cap for a DIFFERENT nonce → guard REJECTS ──');
    const otherNonce = randomNonce();
    const foreign = mint(otherNonce); // legit signature by the SAME trusted issuer, wrong session
    const rReplay = bindVerumSignin(foreign, { challenge: nonce, trustedIssuer, expectedServer: 'rightsizer' });
    ok(!rReplay.ok && /challenge mismatch/.test(rReplay.reason), `guard binds the nonce → rejected (${rReplay.reason})`);

    console.log('── [6] issuer-pin: pin to a different issuer → rc=5 UNTRUSTED_ISSUER ──');
    const otherIssuer = Buffer.alloc(32, 7).toString('base64url'); // valid shape, wrong key
    const rPin = bindVerumSignin(got, { challenge: nonce, trustedIssuer: otherIssuer });
    ok(!rPin.ok && rPin.rc === 5, `untrusted issuer → rc=5 (${rPin.reason})`);

    console.log('── [7] relay routing-layer replay: POST approval with wrong nonce → rejected ──');
    const s2 = await createSigninSession(base, { ask: ASK });
    let rejected = false;
    try { await submitApproval(base, s2.session_id, 'WRONG-NONCE', mint(s2.nonce)); } catch { rejected = true; }
    ok(rejected, 'relay rejected foreign-nonce approval (defense in depth)');

    console.log(`\n════ ${fails === 0 ? '✓✓✓ all e2e checks green' : '✗ ' + fails + ' FAILED'} ════`);
  } finally {
    cleanup();
  }
  process.exit(fails === 0 ? 0 : 1);
}

main().catch((e) => { console.error(e); process.exit(1); });
